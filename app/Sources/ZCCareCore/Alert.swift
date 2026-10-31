import Foundation

/// When each alert was last posted, so one that comes and goes between
/// refreshes, or comes back after a relaunch, posts once a day at most.
public struct AlertLog: Codable, Sendable, Equatable {
    public var posted: [String: Date] = [:]
    public static let quiet: TimeInterval = 86400

    public init() {}

    /// The alerts not posted in the last day, which it records as posted;
    /// older entries are forgotten.
    public mutating func fresh(_ alerts: [Alert], now: Date = .now) -> [Alert] {
        posted = posted.filter { now.timeIntervalSince($0.value) < Self.quiet }
        let fresh = alerts.filter { posted[$0.id] == nil }
        for a in fresh { posted[a.id] = now }
        return fresh
    }
}

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
    /// A part read only in part, now or last time, would announce the same
    /// things again, so it waits. The other parts still speak: one target
    /// that stays unreadable must not silence the rest for good.
    public func alerts(since old: Snapshot, ignoring ignored: Set<String>) -> [Alert] {
        var alerts: [Alert] = []
        if !doctorUnknown, !old.doctorUnknown {
            let seen = Set(old.findings.map(\.name))
            for c in findings(ignoring: ignored) where !seen.contains(c.name) {
                alerts.append(Alert(id: "finding " + c.name, title: c.title, body: c.detail ?? "The doctor flags this."))
            }
        }
        if statusError == nil, old.statusError == nil {
            let before = Dictionary(old.targets.map { ($0.target, $0.gaps) }, uniquingKeysWith: max)
            // An unread row counts one gap, which says nothing about drift
            // going in or coming back; `status` exits 0 for it.
            let unread = Set(old.targets.filter { $0.error != nil }.map(\.target))
            for t in targets where t.error == nil && !unread.contains(t.target) && t.gaps > before[t.target, default: 0] {
                alerts.append(Alert(id: "target " + t.target, title: "\(t.target) drifted",
                                    body: "\(t.gaps) of \(t.declared) not in place."))
            }
        }
        let known = Set(old.outdated.map(\.resource))
        let fresh = outdated.filter { !known.contains($0.resource) }
        if !fresh.isEmpty, !updatesUnknown, !old.updatesUnknown {
            let names = fresh.prefix(3).map(\.name).joined(separator: ", ") + (fresh.count > 3 ? "…" : "")
            alerts.append(Alert(id: "updates " + fresh.map(\.resource).joined(separator: " "),
                                title: fresh.count == 1 ? "1 update available" : "\(fresh.count) updates available",
                                body: names))
        }
        return alerts
    }
}
