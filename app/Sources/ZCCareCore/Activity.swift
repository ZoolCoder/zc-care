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
    public var canPutBack: Bool { canPutBack(home: NSHomeDirectory()) }

    public func canPutBack(home: String) -> Bool {
        guard putBack == nil, let trashed else { return false }
        return trashed.contains { $0.canRestore(home: home) }
    }

    /// Moves back what can go. What stayed remains in the entry for another
    /// try, and the bytes of what came back stop counting as freed. Returns
    /// the names of the items still in the Trash.
    @discardableResult
    public mutating func putBackFromTrash(home: String = NSHomeDirectory()) -> [String] {
        let items = trashed ?? []
        let restored = items.filter { $0.restore(home: home) }
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
///
/// The activity log holds these paths, and any program running as the user
/// can write it, so a record is checked before anything moves: the item
/// must still be the one trashed, sit directly in a real Trash folder, and
/// go back to a path with no link or `..` in it.
public struct Trashed: Codable, Sendable, Equatable {
    public var original: String
    public var inTrash: String
    /// The item's file and volume numbers once in the Trash: after an empty,
    /// another item can take the same name there. A record without them,
    /// from an older log or not written by ZC Care, never moves.
    public var inode: UInt64?
    public var device: Int64?

    /// `identity` is read before the move when given: without Full Disk
    /// Access the Trash is closed to the app. A move keeps both numbers.
    public init(original: URL, inTrash: URL, identity: Identity? = nil) {
        self.original = original.path
        self.inTrash = inTrash.path
        let found = identity ?? Self.identity(of: inTrash.path)
        inode = found?.inode
        device = found?.device
    }

    /// Still in the Trash as the same item, and nothing took its old place.
    public var canRestore: Bool { canRestore(home: NSHomeDirectory()) }

    public func canRestore(home: String) -> Bool {
        guard let inode, let device, Self.identity(of: inTrash) == Identity(inode: inode, device: device),
              Self.inTrashFolder(inTrash, home: home), Self.safeDestination(original) else { return false }
        return Self.identity(of: original) == nil
    }

    func restore(home: String) -> Bool {
        guard canRestore(home: home) else { return false }
        let to = URL(fileURLWithPath: original)
        do {
            try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.moveItem(at: URL(fileURLWithPath: inTrash), to: to)
            return true
        } catch {
            return false
        }
    }

    /// Moves the items back; returns the names that could not go.
    public static func putBack(_ items: [Trashed], home: String = NSHomeDirectory()) -> [String] {
        items.filter { !$0.restore(home: home) }.map { URL(fileURLWithPath: $0.original).lastPathComponent }
    }

    public struct Identity: Equatable, Sendable {
        var inode: UInt64
        var device: Int64
    }

    /// What is at `path`, a link itself rather than what it points to; nil
    /// when nothing is there.
    public static func identity(of path: String) -> Identity? {
        var info = stat()
        return lstat(path, &info) == 0 ? Identity(inode: UInt64(info.st_ino), device: Int64(info.st_dev)) : nil
    }

    /// Directly in the home folder's Trash or this user's Trash on a
    /// volume, with every link resolved.
    static func inTrashFolder(_ path: String, home: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty, name != ".", name != "..",
              let folder = real((path as NSString).deletingLastPathComponent) else { return false }
        if folder == real(home + "/.Trash") { return true }
        let parts = (folder as NSString).pathComponents
        return parts.count == 5 && parts[1] == "Volumes" && parts[3] == ".Trashes" && parts[4] == String(getuid())
    }

    /// An absolute path with no `.`, `..` or link on the way, outside the
    /// privacy database's folder.
    static func safeDestination(_ path: String) -> Bool {
        let parts = (path as NSString).pathComponents
        guard path.hasPrefix("/"), !parts.contains("."), !parts.contains(".."),
              !parts.contains(where: { $0.caseInsensitiveCompare("com.apple.TCC") == .orderedSame }) else { return false }
        // The deepest folder that exists must be where the path says.
        var folder = (path as NSString).deletingLastPathComponent
        while identity(of: folder) == nil, folder != "/" { folder = (folder as NSString).deletingLastPathComponent }
        return real(folder) == firmlinked(folder)
    }

    /// /var, /tmp and /etc are links into /private on macOS.
    private static func firmlinked(_ path: String) -> String {
        ["/var", "/tmp", "/etc"].contains { path == $0 || path.hasPrefix($0 + "/") } ? "/private" + path : path
    }

    static func real(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// Everything ZC Care did, kept on disk, newest last.
public struct ActivityLog: Codable, Sendable, Equatable {
    public var entries: [ActivityEntry] = []
    /// Set when a corrupt file could not be moved aside: saving would overwrite it.
    public private(set) var readOnly = false

    private enum CodingKeys: String, CodingKey { case entries }

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
        if let log = try? JSONDecoder().decode(ActivityLog.self, from: data) { return log }
        // The next save would overwrite what Put Back still needs: keep the file.
        let stamp = Int(Date.now.timeIntervalSince1970)
        var log = ActivityLog()
        do {
            try FileManager.default.moveItem(at: url, to: url.appendingPathExtension("broken-\(stamp)"))
        } catch {
            log.readOnly = true
        }
        return log
    }

    public func save(to url: URL) throws {
        guard !readOnly else { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
