import Foundation

/// What files and folders take on disk.
public enum DiskUsage {
    public static func allocated(_ url: URL) -> Int64 {
        let key = URLResourceKey.totalFileAllocatedSizeKey
        var total = Int64((try? url.resourceValues(forKeys: [key]))?.totalFileAllocatedSize ?? 0)
        guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [key],
                                                         errorHandler: { _, _ in true }) else { return total }
        for case let file as URL in files {
            if Task.isCancelled { break }
            total += Int64((try? file.resourceValues(forKeys: [key]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

/// A folder Care empties for good must be a real folder this user owns:
/// /tmp is open to every user, and a link there could point into the home
/// folder.
public enum OwnFolder {
    public static func check(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR && info.st_uid == getuid()
    }
}

/// The apps that hold a file open, read from `lsof -Fc` output.
public enum OpenFile {
    public static func holders(_ output: String) -> [String] {
        var names: [String] = []
        for line in output.split(whereSeparator: \.isNewline) where line.hasPrefix("c") {
            let name = String(line.dropFirst())
            if !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// The commands working in the folder or below it, from
    /// `lsof -a -d cwd -Fcn`: a dev server or a shell there still needs it.
    public static func workingIn(_ folder: String, _ output: String) -> [String] {
        var names: [String] = []
        var command = ""
        for line in output.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("c") { command = String(line.dropFirst()) }
            guard line.hasPrefix("n") else { continue }
            let cwd = line.dropFirst()
            if (cwd == folder || cwd.hasPrefix(folder + "/")), !names.contains(command) { names.append(command) }
        }
        return names
    }
}

/// A big file in the home folder, for Large Files.
public struct LargeFile: Codable, Sendable, Equatable, Identifiable {
    public var url: URL
    public var size: Int64
    public var modified: Date?
    /// When it was last opened, as Spotlight knows it; nil when never or
    /// not known.
    public var opened: Date?

    public init(url: URL, size: Int64, modified: Date? = nil) {
        self.url = url
        self.size = size
        self.modified = modified
    }

    public var id: String { url.path }
    public var name: String { url.lastPathComponent }
}

public enum LargeFiles {
    /// The Spotlight query for files of at least `minimum` bytes: walking
    /// the home folder takes minutes, Spotlight a moment.
    public static func query(minimum: Int64) -> String { "kMDItemFSSize >= \(minimum)" }

    /// The files Spotlight found, biggest first. Library, hidden folders and
    /// app bundles are left out: what lives there belongs to apps, and
    /// Cleanup covers their caches.
    public static func files(paths: [String], home: String, minimum: Int64, limit: Int = 60) -> [LargeFile] {
        candidates(paths: paths, home: home, minimum: minimum).sorted { $0.size > $1.size }.prefix(limit).map { file in
            var file = file
            file.opened = FileKind.lastOpened(file.url)
            return file
        }
    }

    /// Folders a package manager or build fills: what is in them comes back
    /// with the next install, and trashing it breaks the project. Go's
    /// module cache, ~/go/pkg, is one too.
    static let dependencies: Set<Substring> = ["node_modules", "vendor", "Pods", "target", "build", "DerivedData",
                                               "uv-tools", "site-packages", "venv"]

    /// Libraries an app owns: their files are the app's to remove, and
    /// macOS asks for media access the moment one is read.
    static let appLibraries = [".photoslibrary", ".photolibrary", ".musiclibrary", ".tvlibrary", ".theater"]

    /// Packages whose files make one whole: a virtual machine's disk or a
    /// Final Cut library's media, trashed alone, breaks it.
    static let packages = [".pvm", ".utm", ".vmwarevm", ".vbox", ".fcpbundle", ".imovielibrary", ".logicx", ".band",
                           ".lrlibrary", ".lrdata", ".sparsebundle", ".xcarchive", ".bundle", ".framework", ".plugin"]

    static func ownedByApp(_ parts: [Substring]) -> Bool {
        (parts.count > 1 && parts[0] == "Music" && parts[1] == "Music")
            || (parts.count > 1 && parts[0] == "Movies" && parts[1] == "TV")
            || parts.contains { part in appLibraries.contains { part.hasSuffix($0) } }
            || parts.dropLast().contains { part in packages.contains { part.lowercased().hasSuffix($0) } }
    }

    /// The paths that are the user's own regular files of at least `minimum`.
    static func candidates(paths: [String], home: String, minimum: Int64) -> [LargeFile] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .contentModificationDateKey]
        return paths.compactMap { path -> LargeFile? in
            guard path.hasPrefix(home + "/") else { return nil }
            let parts = path.dropFirst(home.count + 1).split(separator: "/")
            guard parts.first != "Library", !(parts.count > 1 && parts[0] == "go" && parts[1] == "pkg"),
                  !parts.contains(where: { $0.hasPrefix(".") || $0.hasSuffix(".app") || dependencies.contains($0) }),
                  !ownedByApp(parts) else { return nil }
            let url = URL(fileURLWithPath: path)
            guard let v = try? url.resourceValues(forKeys: keys), v.isRegularFile == true else { return nil }
            let size = Int64(v.totalFileAllocatedSize ?? 0)
            return size >= minimum ? LargeFile(url: url, size: size, modified: v.contentModificationDate) : nil
        }
    }
}

/// An app in /Applications, and how it got there.
public struct InstalledApp: Codable, Sendable, Equatable, Identifiable {
    public enum Source: Codable, Sendable, Equatable {
        case cask(String), appStore, other
    }

    public var name: String
    public var url: URL
    public var bundleID: String?
    public var source: Source
    /// The Brewfile entry that installs it; nil when nothing declares it.
    public var declared: Item?
    public var size: Int64?
    public var lastUsed: Date?
    /// When it landed in Applications; an update counts as landing again.
    public var added: Date?
    /// Its executable has Intel code only, so it needs Rosetta.
    public var intelOnly: Bool?

    /// In /Applications, where Homebrew and the App Store put apps.
    public var inApplications: Bool { url.deletingLastPathComponent().path == "/Applications" }

    public init(name: String, url: URL, bundleID: String?, source: Source, declared: Item? = nil) {
        self.name = name
        self.url = url
        self.bundleID = bundleID
        self.source = source
        self.declared = declared
    }

    public var id: String { url.path }

    /// Not opened for 90 days. Spotlight keeps no use date for some apps,
    /// so those count from when they were added.
    public func unused(now: Date = .now) -> Bool {
        guard let since = lastUsed ?? added else { return true }
        return now.timeIntervalSince(since) > 90 * 86400
    }
}

public enum AppCatalog {
    /// `brew info --json=v2 --installed --cask`: each app bundle's cask.
    public static func caskApps(brewInfo: Data) -> [String: String] {
        guard let root = try? JSONSerialization.jsonObject(with: brewInfo) as? [String: Any],
              let casks = root["casks"] as? [[String: Any]] else { return [:] }
        var apps: [String: String] = [:]
        for cask in casks {
            guard let token = cask["token"] as? String else { continue }
            for artifact in cask["artifacts"] as? [[String: Any]] ?? [] {
                for case let app as String in artifact["app"] as? [Any] ?? [] {
                    apps[app] = token
                }
            }
        }
        return apps
    }

    /// The declared item that installs the app: its cask, or the App Store
    /// app whose name it starts with, as Keynote does Keynote Creator Studio.
    public static func declared(name: String, source: InstalledApp.Source, items: [Item]) -> Item? {
        switch source {
        case .cask(let token):
            return items.first { $0.kind == "cask" && $0.name == token }
        case .appStore:
            return items.first { $0.kind == "mas" && name.hasPrefix($0.app ?? $0.name) }
        case .other:
            return nil
        }
    }

    /// Every app in the folder, sources and Brewfile entries filled in;
    /// sizes and last use are read separately, being slow.
    /// `managed` is false for a folder Homebrew and the Brewfile do not
    /// install into, such as ~/Applications: an app there is a copy of its
    /// own, so uninstalling it never runs brew on the one in /Applications.
    public static func apps(in folder: URL, caskApps: [String: String], items: [Item], managed: Bool = true) -> [InstalledApp] {
        let all = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return all.filter { $0.pathExtension == "app" }.map { url in
            let file = url.lastPathComponent
            let name = url.deletingPathExtension().lastPathComponent
            let source: InstalledApp.Source
            if managed, let token = caskApps[file] {
                source = .cask(token)
            } else if FileManager.default.fileExists(atPath: url.path + "/Contents/_MASReceipt/receipt") {
                source = .appStore
            } else {
                source = .other
            }
            return InstalledApp(name: name, url: url, bundleID: Bundle(url: url)?.bundleIdentifier, source: source,
                                declared: managed ? declared(name: name, source: source, items: items) : nil)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The apps installed more than once: each copy that shares its bundle
    /// id with another, by path.
    public static func copies(_ apps: [InstalledApp]) -> Set<String> {
        let counts = Dictionary(apps.compactMap(\.bundleID).map { ($0, 1) }, uniquingKeysWith: +)
        return Set(apps.filter { counts[$0.bundleID ?? ""] ?? 0 > 1 }.map(\.id))
    }
}

/// What an app leaves in the Library once it is gone.
public enum Leftovers {
    /// The app and every leftover uninstalling trashes, each with its size
    /// on disk; what the ignore list names stays, so it is not listed.
    public static func files(of app: InstalledApp, home: String, ignoring ignore: IgnoreList = IgnoreList(),
                             installed: Set<String> = []) -> [LargeFile] {
        let leftovers = paths(bundleID: app.bundleID, name: app.name, home: home, installed: installed)
            .filter { !ignore.touches($0) }
            .map { URL(fileURLWithPath: $0) }
        return ([app.url] + leftovers).map { LargeFile(url: $0, size: DiskUsage.allocated($0)) }
    }

    /// `installed` holds the bundle ids of the installed apps: an agent or
    /// setting that belongs to another app whose id extends this one's, as
    /// com.google.Chrome.canary does com.google.Chrome, stays.
    public static func paths(bundleID: String?, name: String, home: String, installed: Set<String> = []) -> [String] {
        let lib = home + "/Library/"
        var candidates = isFileName(name) ? [lib + "Application Support/" + name, lib + "Logs/" + name] : []
        if let id = bundleID, isBundleID(id) {
            candidates += [
                lib + "Application Support/" + id,
                lib + "Caches/" + id,
                lib + "Containers/" + id,
                lib + "HTTPStorages/" + id,
                lib + "WebKit/" + id,
                lib + "Logs/" + id,
                lib + "Preferences/" + id + ".plist",
                lib + "Saved Application State/" + id + ".savedState",
                lib + "Application Scripts/" + id,
                lib + "Cookies/" + id + ".binarycookies",
            ]
            // Agents and per-host settings carry the id with more after it,
            // com.x.app.helper.plist or com.x.app.<host id>.plist.
            for folder in ["LaunchAgents", "Preferences/ByHost"] {
                candidates += ((try? FileManager.default.contentsOfDirectory(atPath: lib + folder)) ?? [])
                    .filter { $0.hasPrefix(id + ".") && $0.hasSuffix(".plist") && !belongsToOther($0, id: id, installed) }
                    .map { lib + folder + "/" + $0 }
            }
        }
        return candidates.filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// A bundle id as macOS allows them: anything else, such as
    /// `../../Documents` in a planted app's Info.plist, would reach outside
    /// the Library folder it is joined to.
    static func isBundleID(_ id: String) -> Bool {
        id.first.map { $0.isASCII && ($0.isLetter || $0.isNumber) } == true && !id.contains("..")
            && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0)) }
    }

    static func isFileName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
    }

    private static func belongsToOther(_ file: String, id: String, _ installed: Set<String>) -> Bool {
        let own = id.lowercased() + "."
        let file = file.lowercased()
        return installed.contains { other in
            let other = other.lowercased()
            return other.hasPrefix(own) && file.hasPrefix(other + ".")
        }
    }

    /// The launch agents among the paths: launchd keeps running them until
    /// they are booted out, even with the file in the Trash.
    public static func agents(in paths: [String]) -> [String] {
        paths.filter { ($0 as NSString).deletingLastPathComponent.hasSuffix("/Library/LaunchAgents") }
    }
}

/// The last Smart Care scan, kept on disk so the window opens on it while
/// a fresh scan runs.
public struct CareScan: Codable, Sendable, Equatable {
    public var scannedAt: Date
    public var junk: [String: Int64]
    public var largeFiles: [LargeFile]
    public var apps: [InstalledApp]
    public var agents: [LaunchAgent]
    /// Optional: scans saved before My Clutter have none.
    public var duplicates: [DuplicateGroup]?
    public var oldDownloads: [LargeFile]?
    public var diskImages: [LargeFile]?
    public var dependencies: [LargeFile]?
    public var models: [AIModel]?

    public init(scannedAt: Date, junk: [String: Int64], largeFiles: [LargeFile], apps: [InstalledApp], agents: [LaunchAgent]) {
        self.scannedAt = scannedAt
        self.junk = junk
        self.largeFiles = largeFiles
        self.apps = apps
        self.agents = agents
    }

    public static func load(from url: URL) -> CareScan? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CareScan.self, from: data)
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

/// A launch agent that starts with the session: Performance lists them.
public struct LaunchAgent: Codable, Sendable, Equatable, Identifiable {
    public var label: String
    public var path: String
    public var program: String
    public var runAtLoad: Bool
    public var keepAlive: Bool
    public var enabled = true
    public var running = false

    public var id: String { label }

    /// The program it runs is gone, as an app removed without its agent
    /// leaves it: launchd tries it at each login and fails.
    public var broken: Bool {
        program.hasPrefix("/") && !FileManager.default.fileExists(atPath: program)
    }

    /// The agent's plist, or nil when it has no label.
    public static func parse(plist: [String: Any], path: String) -> LaunchAgent? {
        guard let label = plist["Label"] as? String else { return nil }
        let program = plist["Program"] as? String ?? (plist["ProgramArguments"] as? [String])?.first ?? ""
        let keepAlive = plist["KeepAlive"] as? Bool ?? (plist["KeepAlive"] is [String: Any])
        var agent = LaunchAgent(label: label, path: path, program: program,
                                runAtLoad: plist["RunAtLoad"] as? Bool ?? false, keepAlive: keepAlive)
        agent.enabled = !(plist["Disabled"] as? Bool ?? false)
        return agent
    }

    /// Reads every agent in the folders, one per label.
    public static func read(folders: [String]) -> [LaunchAgent] {
        var seen = Set<String>()
        var agents: [LaunchAgent] = []
        for folder in folders {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            for file in files.sorted() where file.hasSuffix(".plist") {
                let path = folder + "/" + file
                guard let plist = NSDictionary(contentsOfFile: path) as? [String: Any],
                      let agent = parse(plist: plist, path: path), seen.insert(agent.label).inserted else { continue }
                agents.append(agent)
            }
        }
        return agents
    }
}

extension Launchd {
    /// `launchctl print-disabled`: each label launchd overrides, and whether
    /// it is disabled.
    public static func parseDisabled(_ text: String) -> [String: Bool] {
        var out: [String: Bool] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.components(separatedBy: "=>").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0].hasPrefix("\"") else { continue }
            out[parts[0].trimmingCharacters(in: CharacterSet(charactersIn: "\""))] = parts[1] == "disabled" || parts[1] == "true"
        }
        return out
    }

    /// `launchctl list`: the labels with a running process.
    public static func parseRunning(_ text: String) -> Set<String> {
        var out = Set<String>()
        for line in text.split(whereSeparator: \.isNewline).dropFirst() {
            let f = line.split(separator: "\t")
            if f.count == 3, Int(f[0]) != nil { out.insert(String(f[2])) }
        }
        return out
    }
}
