import Foundation

/// What the menu shows: every target's coverage, pending updates, and the
/// doctor's findings, read together.
public struct Snapshot: Sendable, Equatable {
    public var targets: [TargetStatus]
    public var outdated: [Item]
    /// What the services targets run: brew services and launch agents.
    public var services: [Item] = []
    /// The doctor checks that are not ok.
    public var findings: [Check]
    /// Every security check, passing or not: the Mac tab's protection.
    public var security: [Check] = []
    /// The last daily drift check; nil before the first one.
    public var drift: Drift?
    /// A part that could not be read, so the rest still shows.
    public var errors: [String]

    public init(targets: [TargetStatus] = [], outdated: [Item] = [], findings: [Check] = [], errors: [String] = []) {
        self.targets = targets
        self.outdated = outdated
        self.findings = findings
        self.errors = errors
    }

    /// `list` failed, so no pending update does not mean there are none. A
    /// target that never has updates, like dotfiles, changes nothing here.
    public var updatesUnknown: Bool {
        errors.contains { line in
            line.hasPrefix("list: ") && !targets.contains { t in
                !["packages", "tools"].contains(t.provider) && line.hasPrefix("list: \(t.target): ")
            }
        }
    }

    /// A services target could not be read, or there is no telling if any exist.
    public var servicesUnknown: Bool {
        statusError != nil || errors.contains { $0.hasPrefix("services: ") }
    }

    var doctorUnknown: Bool { errors.contains { $0.hasPrefix("doctor: ") } }

    /// Why `status` could not be read.
    public var statusError: String? {
        errors.first { $0.hasPrefix("status: ") }.map { String($0.dropFirst("status: ".count)) }
    }

    /// No targets because none could be read must not pass for all clear.
    public var targetsUnknown: Bool { targets.isEmpty && statusError != nil }

    /// The findings the owner has not chosen to ignore. A target's own check
    /// repeats its coverage bar, so it is left out.
    public func findings(ignoring ignored: Set<String>) -> [Check] {
        findings.filter { !ignored.contains($0.name) && !$0.name.hasPrefix("target ") }
    }

    /// The number on the icon: missing things, findings, and one for all
    /// pending updates, which would otherwise drown the rest.
    public func attention(ignoring ignored: Set<String>) -> Int {
        targets.map(\.gaps).reduce(0, +) + (outdated.isEmpty ? 0 : 1) + findings(ignoring: ignored).count + failures
    }

    /// One failure counts once: each read of a target meets the same one,
    /// and a target's status row is a gap already.
    private var failures: Int {
        var seen = Set<String>()
        for line in errors {
            let read = ["list: ", "services: "].first(where: line.hasPrefix)
            let part = read.map { String(line.dropFirst($0.count)) } ?? line
            if read != nil, targets.contains(where: { $0.error != nil && part.hasPrefix($0.target + ": ") }) { continue }
            seen.insert(part)
        }
        return seen.count
    }
}
