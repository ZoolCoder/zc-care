import Foundation

/// An app that names its own Sparkle update feed in Info.plist.
public struct FeedApp: Sendable, Equatable {
    public var name: String
    public var url: URL
    /// CFBundleShortVersionString, what the app shows.
    public var version: String
    /// CFBundleVersion, what Sparkle compares.
    public var build: String
    public var feed: URL

    public init(name: String, url: URL, version: String, build: String, feed: URL) {
        self.name = name
        self.url = url
        self.version = version
        self.build = build
        self.feed = feed
    }
}

/// One release in an appcast.
public struct FeedRelease: Sendable, Equatable {
    public var version = ""
    public var shortVersion: String?
    public var minimumSystem: String?
    public var maximumSystem: String?
    public var date: Date?
    public var size: Int64?
    /// Where release notes live: a link, or the item's own text, already
    /// plain.
    public var notesLink: URL?
    public var notes: String?

    public init(version: String = "", shortVersion: String? = nil, minimumSystem: String? = nil, maximumSystem: String? = nil) {
        self.version = version
        self.shortVersion = shortVersion
        self.minimumSystem = minimumSystem
        self.maximumSystem = maximumSystem
    }

    /// Whether this Mac's macOS is within the release's range.
    public func runs(on system: OperatingSystemVersion) -> Bool {
        let os = AppUpdates.systemString(system)
        if let minimumSystem, AppUpdates.compare(os, minimumSystem) == .orderedAscending { return false }
        if let maximumSystem, AppUpdates.compare(os, maximumSystem) == .orderedDescending { return false }
        return true
    }
}

/// A feed app with a newer release than the one installed.
public struct AppUpdate: Sendable, Equatable, Identifiable {
    public var app: FeedApp
    public var release: FeedRelease
    /// False when the release needs another macOS than this Mac runs.
    public var supported: Bool

    public var id: String { app.url.path }
    public var available: String { release.shortVersion ?? release.version }
}

/// What a check found: updates, feeds that did not answer and feeds that
/// answered with something that is not an appcast.
public struct UpdateCheck: Sendable, Equatable {
    public var updates: [AppUpdate] = []
    public var unreachable: [String] = []
    public var unreadable: [String] = []
}

public enum AppUpdates {
    /// The feed an app declares, when it is https on a public host: Sparkle
    /// 2 refuses a plain http feed, and so does this.
    public static func feedApp(at url: URL, info: [String: Any]) -> FeedApp? {
        guard let feedText = info["SUFeedURL"] as? String,
              let feed = URL(string: feedText.trimmingCharacters(in: .whitespaces)), isPublic(feed),
              let build = info["CFBundleVersion"] as? String, !build.isEmpty else { return nil }
        let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? url.deletingPathExtension().lastPathComponent
        return FeedApp(name: name, url: url, version: (info["CFBundleShortVersionString"] as? String) ?? build, build: build, feed: feed)
    }

    /// The releases meant for everyone: items on a named channel (beta and
    /// the like) or for another OS are left out. Nil when it is not XML.
    public static func releases(in appcast: Data) -> [FeedRelease]? {
        let reader = AppcastReader()
        let parser = XMLParser(data: appcast)
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse(), reader.isAppcast else { return nil }
        return reader.items.filter { !$0.version.isEmpty }
    }

    /// The update for an app, as Sparkle would offer it: the newest release
    /// this Mac can run. When only releases for another macOS are newer,
    /// the newest of those, marked unsupported.
    public static func update(for app: FeedApp, releases: [FeedRelease], system: OperatingSystemVersion) -> AppUpdate? {
        let newer = releases.filter { compare($0.version, app.build) == .orderedDescending }
        func newest(_ list: [FeedRelease]) -> FeedRelease? { list.max { compare($0.version, $1.version) == .orderedAscending } }
        if let release = newest(newer.filter { $0.runs(on: system) }) { return AppUpdate(app: app, release: release, supported: true) }
        // One only for an older macOS is never offered, as Sparkle never
        // would; one for a newer macOS is, marked.
        let os = systemString(system)
        let later = newer.filter { r in r.maximumSystem.map { compare(os, $0) != .orderedDescending } ?? true }
        return newest(later).map { AppUpdate(app: app, release: $0, supported: false) }
    }

    /// Feed apps among the bundles at these URLs.
    public static func feedApps(_ urls: [URL]) -> [FeedApp] {
        urls.compactMap { url in
            guard let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any] else { return nil }
            return feedApp(at: url, info: info)
        }
    }

    private enum Outcome: Sendable { case read([FeedRelease]), unreachable, unreadable, cancelled }

    /// Reads each feed, at most six at once. Nil when cancelled part way,
    /// so a half-done check never stands for a whole one.
    public static func check(_ apps: [FeedApp], system: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
                             fetch: @escaping @Sendable (URL) async throws -> Data = download) async -> UpdateCheck? {
        var result = UpdateCheck()
        var cancelled = false
        await forEachConcurrently(apps, limit: 6) { app -> (FeedApp, Outcome) in
            do {
                let data = try await fetch(app.feed)
                return (app, releases(in: data).map(Outcome.read) ?? .unreadable)
            } catch {
                return (app, Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled ? .cancelled : .unreachable)
            }
        } each: { app, outcome in
            switch outcome {
            case .read(let list): if let update = update(for: app, releases: list, system: system) { result.updates.append(update) }
            case .unreachable: result.unreachable.append(app.name)
            case .unreadable: result.unreadable.append(app.name)
            case .cancelled: cancelled = true
            }
        }
        if cancelled || Task.isCancelled { return nil }
        result.updates.sort { $0.app.name.localizedCaseInsensitiveCompare($1.app.name) == .orderedAscending }
        result.unreachable.sort()
        result.unreadable.sort()
        return result
    }

    /// Release notes as plain text: tags dropped in one pass, style and
    /// script left out, entities read, blank runs folded, cut to a few
    /// hundred characters. A feed is untrusted, so no regex: a run of "<"
    /// must not stall it.
    public static func plain(_ html: String, limit: Int = 600) -> String {
        var text = ""
        var tag: String?
        var tagStart = 0
        var hidden: String?
        // Counted in scalars: one Character can carry any number of
        // combining marks, and a feed may send millions.
        let chars = Array(String(String.UnicodeScalarView(html.unicodeScalars.prefix(20_000))))
        for (i, c) in chars.enumerated() {
            if var open = tag {
                if c == ">" {
                    // "br/", "br /" and "BR" all name br.
                    var name = String(open.lowercased().prefix { $0 != " " })
                    if name.count > 1, name.hasSuffix("/") { name.removeLast() }
                    if let skip = hidden {
                        if name == "/" + skip { hidden = nil }
                    } else if name == "style" || name == "script" {
                        hidden = name
                    } else if ["br", "/p", "/li", "/ol", "/ul", "/div", "/h1", "/h2", "/h3", "/h4", "/h5", "/h6"].contains(name) {
                        text += "\n"
                    } else if name == "li" {
                        text += "\n• "
                    }
                    tag = nil
                } else if open.count < 32 {
                    open.append(c)
                    tag = open
                }
            } else if c == "<", i + 1 < chars.count, chars[i + 1].isLetter || chars[i + 1] == "/" || chars[i + 1] == "!" {
                tag = ""
                tagStart = i
            } else if hidden == nil {
                text.append(c)
            }
        }
        // A "<" that never closes was text after all: "press <Cmd-K to open".
        if tag != nil, hidden == nil { text += String(chars[tagStart...]) }
        let lines = entities(text).split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let joined = lines.joined(separator: "\n")
        let scalars = joined.unicodeScalars
        return scalars.count > limit ? String(String.UnicodeScalarView(scalars.prefix(limit))) + "…" : joined
    }

    static let named: [String: String] = ["nbsp": " ", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "amp": "&",
                                          "mdash": "—", "ndash": "–", "hellip": "…", "rsquo": "’", "lsquo": "‘",
                                          "rdquo": "”", "ldquo": "“", "bull": "•"]

    /// Named and numeric character references, read in one pass; an
    /// unknown one stays as written.
    static func entities(_ s: String) -> String {
        var out = ""
        var rest = Substring(s)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            if let semi = after.prefix(10).firstIndex(of: ";") {
                let name = after[..<semi]
                var char: String?
                if name.hasPrefix("#x") || name.hasPrefix("#X") {
                    char = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else if name.hasPrefix("#") {
                    char = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else {
                    char = named[String(name)]
                }
                if let char {
                    out += char
                    rest = after[after.index(after: semi)...]
                    continue
                }
            }
            out += "&"
            rest = after
        }
        return out + rest
    }

    /// An https address on a public host: never this Mac or the local
    /// network. Sparkle would reach a feed only from inside its app; this
    /// reads every feed.
    public static func isPublic(_ url: URL) -> Bool {
        url.scheme == "https" && url.host.map(PublicHost.named) == true
    }

    static let maxFeed = 5 << 20

    /// GET over https, no cookies, no cache. Stops reading past 5 MB rather
    /// than holding whatever a feed sends.
    @Sendable public static func download(_ url: URL) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpCookieStorage = nil
        let session = URLSession(configuration: config, delegate: HTTPSOnly(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        // A public name can still point home; look it up first.
        guard let host = url.host, isPublic(url), PublicHost.resolves(host) else { throw URLError(.cannotConnectToHost) }
        var request = URLRequest(url: url)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), response.url?.scheme == "https",
              response.expectedContentLength <= Int64(maxFeed) else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxFeed { throw URLError(.dataLengthExceedsMaximum) }
        }
        return data
    }

    public static func systemString(_ v: OperatingSystemVersion) -> String { "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" }

    /// Sparkle's comparison: digit runs compare as numbers, letter runs as
    /// text, and dots separate. When one version runs out, a text
    /// part next on the longer means a pre-release ("2.0b1" < "2.0"), and
    /// anything else a later one ("1.2" < "1.2.1").
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let x = parts(a), y = parts(b)
        for (p, q) in zip(x, y) {
            switch (p, q) {
            case let (.number(m), .number(n)):
                if m.count != n.count { return m.count < n.count ? .orderedAscending : .orderedDescending }
                if m != n { return m < n ? .orderedAscending : .orderedDescending }
            case let (.text(m), .text(n)):
                if m != n { return m < n ? .orderedAscending : .orderedDescending }
            case (.separator, .separator): continue
            case (.text, _): return .orderedAscending
            case (_, .text): return .orderedDescending
            case (.number, _): return .orderedDescending
            case (_, .number): return .orderedAscending
            }
        }
        if x.count == y.count { return .orderedSame }
        let longerIsA = x.count > y.count
        let next = longerIsA ? x[y.count] : y[x.count]
        let longerNewer: Bool = if case .text = next { false } else { true }
        return longerIsA == longerNewer ? .orderedDescending : .orderedAscending
    }

    private enum Part: Equatable { case number(String), text(String), separator }

    private static func parts(_ s: String) -> [Part] {
        var out: [Part] = []
        var run = ""
        var digits = false
        func flush() {
            guard !run.isEmpty else { return }
            // Leading zeros dropped, so "01" and "1" match; length then
            // order compares numbers of any size.
            out.append(digits ? .number(String(run.drop { $0 == "0" })) : .text(run))
            run = ""
        }
        for c in s {
            if c.isWhitespace {
                flush()
            } else if c == "." {
                flush()
                out.append(.separator)
            } else if c.isPunctuation || c.isSymbol {
                // "2.0-beta1" reads as "2.0beta1": a pre-release, not a part.
                flush()
            } else {
                let isDigit = c.isASCII && c.isNumber
                if !run.isEmpty && isDigit != digits { flush() }
                digits = isDigit
                run.append(c)
            }
        }
        flush()
        return out
    }
}

/// Follows a redirect only to another public https address.
private final class HTTPSOnly: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let url = request.url, let host = url.host, AppUpdates.isPublic(url), PublicHost.resolves(host) else { return nil }
        return request
    }
}

/// Reads <item>s from an RSS appcast. Version and the rest come from the
/// item's own enclosure first, as Sparkle reads them, then from sparkle:
/// elements; enclosures inside sparkle:deltas are patches and are skipped.
private final class AppcastReader: NSObject, XMLParserDelegate {
    var items: [FeedRelease] = []
    /// An RSS channel was seen: an HTML error page parses too, but is not one.
    private(set) var isAppcast = false
    private var current: FeedRelease?
    private var fromEnclosure = FeedRelease()
    private var skip = false
    private var inDeltas = 0
    private var inDescription = 0
    private var text = ""

    private static let dates: [DateFormatter] = ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "dd MMM yyyy HH:mm:ss Z"].map {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = $0
        return f
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        // Raw XHTML notes: their tags are part of the description's text.
        if inDescription > 0 {
            inDescription += 1
            text += "<\(name)>"
            return
        }
        text = ""
        if name == "channel" { isAppcast = true }
        if name == "item" {
            current = FeedRelease()
            fromEnclosure = FeedRelease()
            skip = false
            inDeltas = 0
            return
        }
        guard current != nil else { return }
        switch name {
        case "description": inDescription = 1
        case "sparkle:deltas": inDeltas += 1
        case "enclosure" where inDeltas == 0:
            if let v = attributes["sparkle:version"], !v.isEmpty { fromEnclosure.version = v }
            if let v = attributes["sparkle:shortVersionString"], !v.isEmpty { fromEnclosure.shortVersion = v }
            if let v = attributes["length"].flatMap(Int64.init), v > 0 { current?.size = v }
            if let os = attributes["sparkle:os"], os != "macos" { skip = true }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, foundCDATA block: Data) { text += String(decoding: block, as: UTF8.self) }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if inDescription > 1 {
            inDescription -= 1
            text += "</\(name)>"
            return
        }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { text = "" }
        guard current != nil else { return }
        switch name {
        case "item":
            if var item = current, !skip {
                // Plain text here, off the main thread, not in a view body.
                item.notes = item.notes.map { AppUpdates.plain($0) }.flatMap { $0.isEmpty ? nil : $0 }
                if !fromEnclosure.version.isEmpty { item.version = fromEnclosure.version }
                if let short = fromEnclosure.shortVersion { item.shortVersion = short }
                items.append(item)
            }
            current = nil
        case "description":
            inDescription = 0
            if !value.isEmpty { current?.notes = value }
        case "sparkle:deltas": inDeltas -= 1
        case "sparkle:version": if !value.isEmpty { current?.version = value }
        case "sparkle:shortVersionString": if !value.isEmpty { current?.shortVersion = value }
        case "sparkle:minimumSystemVersion", "minimumSystemVersion": if !value.isEmpty { current?.minimumSystem = value }
        case "sparkle:maximumSystemVersion": if !value.isEmpty { current?.maximumSystem = value }
        case "sparkle:channel": if !value.isEmpty { skip = true }
        case "sparkle:releaseNotesLink":
            if let url = URL(string: value), AppUpdates.isPublic(url) { current?.notesLink = url }
        case "pubDate": current?.date = Self.dates.lazy.compactMap { $0.date(from: value) }.first
        default: break
        }
    }
}
