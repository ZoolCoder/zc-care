import Foundation

/// One thing ZC Care cleaned or ran, for My Activity.
public struct ActivityEntry: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case junk = "System Junk", ai = "AI Clutter", files = "Personal Files", developer = "Developer"
        case apps = "Applications", maintenance = "Maintenance Tasks", privacy = "Browser Privacy"
        case cloud = "Cloud Downloads"
    }

    public var date: Date
    public var kind: Kind
    public var title: String
    public var bytes: Int64
    /// What went to the Trash, for Put Back; logs before it have none.
    public var trashed: [Trashed]?
    public var putBack: Date?

    public init(date: Date = .now, kind: Kind, title: String, bytes: Int64, trashed: [Trashed]? = nil) {
        self.date = date
        self.kind = kind
        self.title = title
        self.bytes = bytes
        self.trashed = trashed
    }

    /// Whether every item is still in the Trash and nothing took its old
    /// place, so Put Back can move them all.
    public var canPutBack: Bool {
        guard putBack == nil, let trashed, !trashed.isEmpty else { return false }
        let fm = FileManager.default
        return trashed.allSatisfy { fm.fileExists(atPath: $0.inTrash) && !fm.fileExists(atPath: $0.original) }
    }
}

/// Where one item was and where the Trash put it.
public struct Trashed: Codable, Sendable, Equatable {
    public var original: String
    public var inTrash: String

    public init(original: URL, inTrash: URL) {
        self.original = original.path
        self.inTrash = inTrash.path
    }

    /// Moves the items back; returns the names that could not go.
    public static func putBack(_ items: [Trashed]) -> [String] {
        let fm = FileManager.default
        return items.compactMap { item in
            let to = URL(fileURLWithPath: item.original)
            do {
                try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: URL(fileURLWithPath: item.inTrash), to: to)
                return nil
            } catch {
                return to.lastPathComponent
            }
        }
    }
}

/// Everything ZC Care did, kept on disk, newest last.
public struct ActivityLog: Codable, Sendable, Equatable {
    public var entries: [ActivityEntry] = []

    public init(entries: [ActivityEntry] = []) {
        self.entries = entries
    }

    /// Put Back stops after this long: macOS can empty the Trash at 30 days.
    static let putBackDays: TimeInterval = 30 * 86400
    static let most = 5000

    /// Adds the entry, then keeps the file small: older entries lose their
    /// Trash paths, and the oldest go past `most`.
    public mutating func add(_ entry: ActivityEntry, now: Date = .now) {
        entries.append(entry)
        for i in entries.indices where entries[i].trashed != nil && now.timeIntervalSince(entries[i].date) > Self.putBackDays {
            entries[i].trashed = nil
        }
        if entries.count > Self.most { entries.removeFirst(entries.count - Self.most) }
    }

    public var freed: Int64 { entries.reduce(0) { $0 + $1.bytes } }
    public var since: Date? { entries.first?.date }

    /// Bytes freed by each kind, biggest first; kinds with none are left out.
    public var freedByKind: [(kind: ActivityEntry.Kind, bytes: Int64)] {
        ActivityEntry.Kind.allCases
            .map { k in (k, entries.filter { $0.kind == k }.reduce(0) { $0 + $1.bytes }) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
    }

    /// How often each kind ran, most first.
    public var runsByKind: [(kind: ActivityEntry.Kind, count: Int)] {
        ActivityEntry.Kind.allCases
            .map { k in (k, entries.filter { $0.kind == k }.count) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
    }

    /// Freed in the `days` before `now`.
    public func freed(lastDays days: Int, now: Date = .now) -> Int64 {
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        return entries.filter { $0.date >= cutoff }.reduce(0) { $0 + $1.bytes }
    }

    public static func load(from url: URL) -> ActivityLog {
        guard let data = try? Data(contentsOf: url) else { return ActivityLog() }
        return (try? JSONDecoder().decode(ActivityLog.self, from: data)) ?? ActivityLog()
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
