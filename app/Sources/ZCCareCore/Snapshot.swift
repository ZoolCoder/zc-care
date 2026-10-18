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

    /// The findings the owner has not chosen to ignore. A target's own check
    /// repeats its coverage bar, so it is left out.
    public func findings(ignoring ignored: Set<String>) -> [Check] {
        findings.filter { !ignored.contains($0.name) && !$0.name.hasPrefix("target ") }
    }

    /// The number on the icon: missing things, findings, and one for all
    /// pending updates, which would otherwise drown the rest.
    public func attention(ignoring ignored: Set<String>) -> Int {
        targets.map(\.gaps).reduce(0, +) + (outdated.isEmpty ? 0 : 1) + findings(ignoring: ignored).count + errors.count
    }
}
