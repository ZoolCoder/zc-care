import Foundation

/// Something a refresh found that the one before did not: worth a
/// notification once, not on every refresh.
public struct Alert: Sendable, Equatable {
    public var id: String
    public var title: String
    public var body: String

    public init(id: String, title: String, body: String) {
        self.id = id
        self.title = title
        self.body = body
    }

    /// The id of one notification summing up these alerts: `more` and
    /// their ids, one per line.
    public static func summary(of ids: [String]) -> String {
        (["more"] + ids).joined(separator: "\n")
    }

    /// The alert ids a summary's id holds; nil for any other id.
    public static func summed(_ id: String) -> [String]? {
        guard id.hasPrefix("more\n") else { return nil }
        return id.split(separator: "\n").dropFirst().map(String.init)
    }
}

extension Snapshot {
    /// What is new since old: findings, targets that lost ground, updates.
    /// A partial read is missing whole parts, so comparing with one, or
    /// against one, would announce the same things again.
    public func alerts(since old: Snapshot, ignoring ignored: Set<String>) -> [Alert] {
        guard errors.isEmpty, old.errors.isEmpty else { return [] }
        var alerts: [Alert] = []
        let seen = Set(old.findings.map(\.name))
        for c in findings(ignoring: ignored) where !seen.contains(c.name) {
            alerts.append(Alert(id: "finding " + c.name, title: c.title, body: c.detail ?? "The doctor flags this."))
        }
        let before = Dictionary(old.targets.map { ($0.target, $0.gaps) }, uniquingKeysWith: max)
        for t in targets where t.gaps > before[t.target, default: 0] {
            alerts.append(Alert(id: "target " + t.target, title: "\(t.target) drifted",
                                body: "\(t.gaps) of \(t.declared) not in place."))
        }
        let known = Set(old.outdated.map(\.resource))
        let fresh = outdated.filter { !known.contains($0.resource) }
        if !fresh.isEmpty {
            let names = fresh.prefix(3).map(\.name).joined(separator: ", ") + (fresh.count > 3 ? "…" : "")
            alerts.append(Alert(id: "updates " + fresh.map(\.resource).joined(separator: " "),
                                title: fresh.count == 1 ? "1 update available" : "\(fresh.count) updates available",
                                body: names))
        }
        return alerts
    }
}
