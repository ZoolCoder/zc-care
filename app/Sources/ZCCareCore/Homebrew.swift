import Foundation

/// One `brew doctor` warning: its first line, and the rest as Homebrew
/// wrote it.
public struct BrewWarning: Sendable, Equatable, Identifiable {
    public var title: String
    public var detail: String
    /// Its place in doctor's output: two warnings can share a first line.
    public var index = 0
    public var id: String { "\(index) \(title)" }
}

/// Reads what Homebrew's dry runs and doctor print. Nothing here changes
/// the Mac.
public enum Homebrew {
    /// Brew that changes only what it is told: no auto-update, and no
    /// autoremove after `uninstall` or `cleanup`, which would take formulae
    /// nobody confirmed. No hints or colour either, since output is parsed.
    public static let quiet = ["HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_AUTOREMOVE": "1", "HOMEBREW_NO_ENV_HINTS": "1",
                               "HOMEBREW_NO_COLOR": "1", "HOMEBREW_NO_INSTALL_CLEANUP": "1"]

    /// The formulae `brew autoremove --dry-run` would remove: dependencies
    /// nothing installed needs any more.
    public static func unneeded(_ output: String) -> [String] {
        var names: [String] = []
        var listing = false
        for line in output.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("==>") {
                listing = line.contains("Would autoremove")
            } else if listing, isName(line) {
                names.append(line)
            }
        }
        return names
    }

    /// What `brew cleanup --dry-run` says it would free; nil when nothing.
    /// Homebrew counts in thousands: 1.4GB is 1.4 billion bytes.
    public static func reclaimable(_ output: String) -> Int64? {
        guard let line = output.split(whereSeparator: \.isNewline).last(where: { $0.contains("would free approximately") }),
              let match = line.firstMatch(of: /approximately ([0-9.]+)(B|KB|MB|GB|TB) of/),
              let value = Double(match.1) else { return nil }
        let scale: Double = switch match.2 {
        case "KB": 1e3
        case "MB": 1e6
        case "GB": 1e9
        case "TB": 1e12
        default: 1
        }
        return Int64(value * scale)
    }

    /// The warnings in `brew doctor`'s output; empty when the system is
    /// ready to brew.
    public static func warnings(_ output: String) -> [BrewWarning] {
        var out: [BrewWarning] = []
        var title: String?
        var body: [Substring] = []
        func flush() {
            if let title {
                out.append(BrewWarning(title: title, detail: body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
                                       index: out.count))
            }
            body = []
        }
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("Warning: ") {
                flush()
                title = String(line.dropFirst("Warning: ".count))
            } else if title != nil {
                body.append(line)
            }
        }
        flush()
        return out
    }

    /// The unneeded formulae the config does not declare: one it names is
    /// wanted even when nothing depends on it, by any name brew knows it by.
    /// Names match without case, and a tap's formula by its full or short
    /// name on either side.
    public static func removable(_ names: [String], declared: Set<String>, aliases: [String: Set<String>] = [:]) -> [String] {
        let wanted = Set(declared.flatMap { [$0.lowercased(), short($0)] })
        return names.filter { name in
            let known = [name.lowercased(), short(name)] + (aliases[name] ?? []).map { $0.lowercased() }
            return !known.contains(where: wanted.contains)
        }
    }

    /// Drops what a kept formula still needs, from `brew deps` of the kept
    /// ones: brew refuses an uninstall that names such a dependency, and
    /// then removes nothing at all.
    public static func sparing(_ names: [String], dependencies: String) -> [String] {
        let needed = Set(dependencies.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        return names.filter { !needed.contains($0.lowercased()) }
    }

    static func short(_ name: String) -> String { String(name.split(separator: "/").last ?? "").lowercased() }

    /// Each formula's other names, from `brew info --json=v2`, keyed by
    /// the full name autoremove prints: aliases and names it had before.
    public static func aliases(_ json: Data) -> [String: Set<String>] {
        struct Info: Decodable {
            struct Formula: Decodable {
                var name: String
                var full_name: String
                var aliases: [String]?
                var oldnames: [String]?
            }
            var formulae: [Formula]
        }
        guard let info = try? JSONDecoder().decode(Info.self, from: json) else { return [:] }
        return Dictionary(info.formulae.map { f in (f.full_name, Set([f.name] + (f.aliases ?? []) + (f.oldnames ?? []))) },
                          uniquingKeysWith: { $0.union($1) })
    }

    /// A formula name as brew prints it, never an option: it goes to
    /// `brew uninstall` as an argument.
    static func isName(_ s: String) -> Bool {
        // Brew reads a path or a .rb name as a formula file and runs it.
        !s.isEmpty && !s.hasPrefix("-") && !s.hasPrefix(".") && !s.hasPrefix("/") && !s.contains("..") && !s.hasSuffix(".rb")
            && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "@+._/-".contains($0)) }
    }
}
