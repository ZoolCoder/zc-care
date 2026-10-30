import Foundation

/// A macOS update that `softwareupdate -l` offers.
public struct MacUpdate: Equatable, Identifiable, Sendable {
    public var label: String
    public var title: String
    public var version: String?
    public var sizeKiB: Int?
    public var recommended: Bool
    public var restart: Bool

    public var id: String { label }

    public init(label: String, title: String, version: String? = nil, sizeKiB: Int? = nil,
                recommended: Bool = false, restart: Bool = false) {
        self.label = label
        self.title = title
        self.version = version
        self.sizeKiB = sizeKiB
        self.recommended = recommended
        self.restart = restart
    }

    /// Reads the list: a `* Label: ...` line, then a `Title: ..., Version: ...,
    /// Size: ...KiB, Recommended: YES, Action: restart` line. Anything else
    /// (the banner, "No new software available.") is skipped.
    public static func parse(_ text: String) -> [MacUpdate] {
        var updates: [MacUpdate] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("* Label:") {
                let label = line.dropFirst("* Label:".count).trimmingCharacters(in: .whitespaces)
                if !label.isEmpty { updates.append(MacUpdate(label: label, title: label)) }
            } else if line.hasPrefix("Title:"), !updates.isEmpty {
                updates[updates.count - 1].read(details: line)
            }
        }
        return updates
    }

    private mutating func read(details line: String) {
        var named: [String: String] = [:]
        var key: String?
        for part in line.trimmingCharacters(in: CharacterSet(charactersIn: ", ")).components(separatedBy: ", ") {
            let pair = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2, ["Title", "Version", "Size", "Recommended", "Action"].contains(pair[0]) {
                key = pair[0]
                named[pair[0]] = pair[1]
            } else if let key {
                // A comma inside a value, such as a title.
                named[key, default: ""] += ", " + part.trimmingCharacters(in: .whitespaces)
            }
        }
        if let name = named["Title"], !name.isEmpty { title = name }
        version = named["Version"].flatMap { $0.isEmpty ? nil : $0 }
        sizeKiB = named["Size"].flatMap { Int($0.filter(\.isNumber)) }
        recommended = named["Recommended"]?.uppercased() == "YES"
        restart = named["Action"]?.lowercased() == "restart"
    }

    /// Asks Apple's servers, which takes 20 to 40 seconds. Run with a
    /// timeout; the tool writes its verdict to either stream.
    public static func list(runner: any Runner = ProcessRunner(timeout: 90)) async throws -> [MacUpdate] {
        let r = try await runner.run("/usr/sbin/softwareupdate", ["-l"], env: ["LANG": "C"])
        guard r.status == 0 else {
            throw CLIError(message: lastLine(r.stderr) ?? "softwareupdate exited \(r.status)")
        }
        return parse(r.output + "\n" + r.stderr)
    }
}
