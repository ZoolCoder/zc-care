import Foundation

public enum ExtensionKind: String, Codable, Sendable, CaseIterable {
    case safari = "Safari"
    case share = "Share"
    case finderSync = "Finder"
    case quickLook = "Quick Look"
    case spotlight = "Spotlight"
    case notificationCenter = "Notification Center"
    case action = "Action"
    case photoEditing = "Photos"
    case system = "System"

    /// The `pluginkit -p` protocols whose extensions belong to this kind.
    var protocols: [String] {
        switch self {
        case .safari: ["com.apple.Safari.extension", "com.apple.Safari.web-extension", "com.apple.Safari.content-blocker"]
        case .share: ["com.apple.share-services"]
        case .finderSync: ["com.apple.FinderSync"]
        case .quickLook: ["com.apple.quicklook.preview", "com.apple.quicklook.thumbnail"]
        case .spotlight: ["com.apple.spotlight.import"]
        case .notificationCenter: ["com.apple.widget-extension"]
        case .action: ["com.apple.ui-services"]
        case .photoEditing: ["com.apple.photo-editing"]
        case .system: []
        }
    }
}

public struct AppExtension: Codable, Sendable, Equatable, Identifiable {
    public var id: String { kind.rawValue + "/" + identifier }
    public var identifier: String
    public var name: String
    public var kind: ExtensionKind
    public var enabled: Bool
    public var version: String?
    /// Team id for a system extension; nil when the developer is not identified.
    public var teamID: String?
    public var path: String?
    public var hostName: String?
    public var hostPath: String?
    public var hostGone = false
    /// What the extension does, such as the system extension's category.
    public var detail: String?

    /// A system extension with no team id comes from no identified developer.
    public var unidentified: Bool { kind == .system && teamID == nil }
}

public enum Extensions {
    /// The extensions Apple ships live here or carry its identifier prefix,
    /// Xcode's among them, and are not worth an audit.
    static let appleRoots = ["/System/", "/usr/"]
    static let applePrefix = "com.apple."

    /// Every extension on the Mac, by kind; a command that fails counts as none.
    public static func load(runner: Runner, env: [String: String] = [:],
                            hostExists: @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) async -> [AppExtension] {
        var found: [AppExtension] = []
        for kind in ExtensionKind.allCases {
            for proto in kind.protocols {
                guard let result = try? await runner.run("/usr/bin/pluginkit", ["-mvv", "-p", proto], env: env),
                      result.status == 0 else { continue }
                found += parsePluginkit(result.output, kind: kind)
            }
        }
        found = found.filter { item in
            !item.identifier.hasPrefix(applePrefix) && !appleRoots.contains { item.path?.hasPrefix($0) ?? false }
        }
        if let result = try? await runner.run("/usr/bin/systemextensionsctl", ["list"], env: env), result.status == 0 {
            found += parseSystemExtensions(result.output)
        }
        // One bundle can answer two protocols of the same kind; it is one row.
        var seen = Set<String>()
        return found.filter { seen.insert($0.id).inserted }.map { item in
            var item = item
            if let host = item.hostPath { item.hostGone = !hostExists(host) }
            return item
        }
    }

    /// The blocks of `pluginkit -mvv`: a `+`, `-` or `!` election mark and
    /// `id(version)`, then indented `Key = value` lines.
    public static func parsePluginkit(_ text: String, kind: ExtensionKind) -> [AppExtension] {
        var items: [AppExtension] = []
        var current: AppExtension?
        for substring in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let raw = String(substring)
            if raw.isEmpty || raw.allSatisfy(\.isWhitespace) {
                if let c = current { items.append(c) }
                current = nil
            } else if let c = current, let (key, value) = field(raw) {
                current = apply(key, value, to: c)
            } else if current == nil, let header = header(raw, kind: kind) {
                current = header
            }
        }
        if let c = current { items.append(c) }
        return items
    }

    private static func header(_ line: String, kind: ExtensionKind) -> AppExtension? {
        guard let mark = line.first, "+-! ".contains(mark), !line.contains(" = ") else { return nil }
        var identifier = line.dropFirst().trimmingCharacters(in: .whitespaces)
        guard identifier.contains("."), !identifier.contains(" ") else { return nil }
        var version: String?
        if identifier.hasSuffix(")"), let open = identifier.lastIndex(of: "(") {
            version = String(identifier[identifier.index(after: open)...].dropLast())
            identifier = String(identifier[..<open])
        }
        return AppExtension(identifier: identifier, name: identifier, kind: kind, enabled: mark != "-" && mark != "!", version: version)
    }

    private static func field(_ line: String) -> (String, String)? {
        guard let eq = line.range(of: " = ") else { return nil }
        return (line[..<eq.lowerBound].trimmingCharacters(in: .whitespaces),
                line[eq.upperBound...].trimmingCharacters(in: .whitespaces))
    }

    private static func apply(_ key: String, _ value: String, to item: AppExtension) -> AppExtension {
        var item = item
        switch key {
        case "Path": item.path = value
        case "Display Name": item.name = value
        case "Parent Bundle": item.hostPath = value
        case "Parent Name": item.hostName = value
        default: break
        }
        return item
    }

    /// The table of `systemextensionsctl list`: a `--- category` line, then one
    /// tab-separated row per extension: enabled, active, team id,
    /// `bundle id (version)`, name, `[state]`. The first two columns hold
    /// `*`, `-` or nothing.
    public static func parseSystemExtensions(_ text: String) -> [AppExtension] {
        var category: String?
        var items: [AppExtension] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("--- ") {
                // "--- com.apple.system_extension.x (Go to 'System Settings > …' to modify these system extension(s))"
                let name = line.dropFirst(4).split(separator: " (", maxSplits: 1).first.map(String.init) ?? ""
                category = name.replacingOccurrences(of: "com.apple.system_extension.", with: "")
                    .replacingOccurrences(of: "_", with: " ")
                continue
            }
            let columns = raw.split(separator: "\t", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard columns.count >= 6, ["*", "-", ""].contains(columns[0]), let item = systemExtension(columns, category: category)
            else { continue }
            items.append(item)
        }
        return items
    }

    private static func systemExtension(_ c: [String], category: String?) -> AppExtension? {
        guard let open = c[3].firstIndex(of: "("), c[3].hasSuffix(")") else { return nil }
        let team = c[2]
        let state = c[5].trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return AppExtension(identifier: c[3][..<open].trimmingCharacters(in: .whitespaces), name: c[4], kind: .system,
                            enabled: c[0] == "*" && c[1] == "*", version: String(c[3][c[3].index(after: open)...].dropLast()),
                            teamID: ["", "-", "0"].contains(team) ? nil : team, detail: [category, state].compactMap { $0 }.joined(separator: " · "))
    }
}
