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

    /// Whether some item is still in the Trash with nothing in its old
    /// place, so Put Back can move it.
    public var canPutBack: Bool {
        guard putBack == nil, let trashed else { return false }
        return trashed.contains(where: \.canRestore)
    }

    /// Moves back what can go. What stayed remains in the entry for another
    /// try, and the bytes of what came back stop counting as freed. Returns
    /// the names of the items still in the Trash.
    @discardableResult
    public mutating func putBackFromTrash() -> [String] {
        let items = trashed ?? []
        let restored = items.filter { $0.canRestore && $0.restore() }
        let remaining = items.filter { !restored.contains($0) }
        if remaining.isEmpty {
            putBack = .now
            bytes = 0
        } else {
            trashed = remaining
            bytes = max(bytes - restored.reduce(0) { $0 + DiskUsage.allocated(URL(fileURLWithPath: $1.original)) }, 0)
        }
        return remaining.map { URL(fileURLWithPath: $0.original).lastPathComponent }
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

    /// Still in the Trash, and nothing took its old place.
    public var canRestore: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: inTrash) && !fm.fileExists(atPath: original)
    }

    func restore() -> Bool {
        let to = URL(fileURLWithPath: original)
        do {
            try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: URL(fileURLWithPath: inTrash), to: to)
            return true
        } catch {
            return false
        }
    }

    /// Moves the items back; returns the names that could not go.
    public static func putBack(_ items: [Trashed]) -> [String] {
        items.filter { !$0.restore() }.map { URL(fileURLWithPath: $0.original).lastPathComponent }
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
