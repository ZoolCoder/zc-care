import Foundation

/// What a permanent delete left behind, and why each item stayed.
public struct Removal: Sendable, Equatable {
    public init() {}

    public enum Reason: Sendable, Equatable {
        case permissionDenied, inUse, protected
        case other(String)

        public var label: String {
            switch self {
            case .permissionDenied: "permission denied"
            case .inUse: "in use"
            case .protected: "protected"
            case .other(let why): why
            }
        }
    }

    public struct Failure: Sendable, Equatable {
        public var name: String
        public var reason: Reason
    }

    public var failures: [Failure] = []
    /// What went to the Trash and where it landed, for Put Back.
    public var trashed: [Trashed] = []

    public var stayed: Int { failures.count }

    /// Deletes each item for good. One already gone counts as deleted.
    public static func delete(_ urls: [URL]) -> Removal {
        delete(urls, home: NSHomeDirectory())
    }

    static func delete(_ urls: [URL], home: String) -> Removal {
        each(urls, home: home) { try FileManager.default.removeItem(at: $0) }
    }

    /// Moves each item to the Trash, noting where it went.
    public static func trash(_ urls: [URL]) -> Removal {
        var moved: [Trashed] = []
        var removal = each(urls) { url in
            var binned: NSURL?
            let identity = Trashed.prepare(url.path)
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: &binned)
            } catch {
                Trashed.untag(url.path)
                throw error
            }
            if let binned { moved.append(Trashed(original: url, inTrash: binned as URL, identity: identity)) }
        }
        removal.trashed = moved
        return removal
    }

    /// To the Trash, or for good when the user chose that in Settings.
    public static func remove(_ urls: [URL], permanently: Bool) -> Removal {
        permanently ? delete(urls) : trash(urls)
    }

    private static func each(_ urls: [URL], home: String = NSHomeDirectory(), _ step: (URL) throws -> Void) -> Removal {
        var removal = Removal()
        for url in urls {
            if isProtected(url.path, home: home) {
                removal.failures.append(Failure(name: url.lastPathComponent, reason: .protected))
                continue
            }
            do {
                try step(url)
            } catch {
                if isGone(error) { continue }
                removal.failures.append(Failure(name: url.lastPathComponent, reason: reason(for: error)))
            }
        }
        return removal
    }

    /// The floor under every removal, whatever a scanner listed: the top of
    /// the disk, of a volume and of a home folder, the folders a home keeps
    /// its files in, and the system's own. The folder the item really lies
    /// in counts as well, so a link in its path cannot lead to one of them.
    /// Names compare without case, as the disk does.
    public static func isProtected(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        let parts = path.split(separator: "/").map { $0.lowercased() }
        let home = home.split(separator: "/").map { $0.lowercased() }
        guard path.hasPrefix("/"), let name = parts.last, !parts.contains(".."), !parts.contains("."),
              parts.first != ".vol" else { return true }
        if isFloor(parts, home: home) { return true }
        // Not there: the removal finds nothing. Any other failure hides where the path leads.
        guard let parent = real(parts.dropLast()) else { return errno != ENOENT }
        return isFloor(parent + [name], home: real(home[...]) ?? [])
    }

    private static func isFloor(_ parts: [String], home: [String]) -> Bool {
        if !home.isEmpty, parts.starts(with: home) {
            let below = Array(parts.dropFirst(home.count))
            switch below.count {
            case 0: return true
            case 1: return homeFolders.contains(below[0])
            case 2: return below[0] == "library" && libraryFolders.contains(below[1]) || below[1].hasSuffix(".photoslibrary")
            case 3: return below[0] == "library" && cloudFolders.contains(below[1])
            default: return false
            }
        }
        if parts.count < 2 { return true }
        if ["system", "bin", "sbin"].contains(parts[0]) || (parts[0] == "usr" && parts[1] != "local") { return true }
        if parts.count == 3, parts[0] == "opt", parts[1] == "homebrew" { return true }
        return parts.count == 2 && parts[0] != "applications"
    }

    private static let homeFolders: Set = ["applications", "desktop", "documents", "downloads", "library", "movies", "music",
                                           "pictures", "public", "developer", ".ssh", ".gnupg", ".config", ".aws", ".kube"]
    private static let cloudFolders: Set = ["mobile documents", "cloudstorage"]
    private static let libraryFolders: Set = cloudFolders.union(
        ["application support", "caches", "containers", "group containers", "keychains", "launchagents", "mail", "messages",
         "preferences", "developer", "logs", "safari", "calendars", "accounts", "photos"])

    /// The parts of the path with every link followed, in lower case; nil,
    /// with errno saying why, when it cannot be read.
    private static func real(_ parts: ArraySlice<String>) -> [String]? {
        guard let resolved = realpath("/" + parts.joined(separator: "/"), nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved).split(separator: "/").map { $0.lowercased() }
    }

    /// Already gone: Cocoa's "no such file" (4, or 260 when reading), or POSIX ENOENT, also as the underlying error.
    static func isGone(_ error: any Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, [CocoaError.fileNoSuchFile, .fileReadNoSuchFile].contains(where: { $0.rawValue == ns.code }) {
            return true
        }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOENT) { return true }
        return (ns.userInfo[NSUnderlyingErrorKey] as? NSError).map(isGone) ?? false
    }

    static func reason(for error: any Error) -> Reason {
        let ns = error as NSError
        let posix = ns.domain == NSPOSIXErrorDomain ? ns : ns.userInfo[NSUnderlyingErrorKey] as? NSError
        switch posix.flatMap({ $0.domain == NSPOSIXErrorDomain ? Int32($0.code) : nil }) {
        case EACCES, EPERM: return .permissionDenied
        case EBUSY, ETXTBSY: return .inUse
        default: break
        }
        if ns.domain == NSCocoaErrorDomain,
           [CocoaError.fileWriteNoPermission, .fileReadNoPermission].contains(where: { $0.rawValue == ns.code }) {
            return .permissionDenied
        }
        return .other(ns.localizedDescription)
    }

    /// What closes a message about the deletion: a full stop, or why some stayed.
    public var ending: String { failures.isEmpty ? "." : "; \(summary)." }

    /// For a message: "2 stayed (1 permission denied, 1 in use)"; empty when nothing stayed.
    public var summary: String {
        guard !failures.isEmpty else { return "" }
        var counts: [(label: String, count: Int)] = []
        for failure in failures {
            if let i = counts.firstIndex(where: { $0.label == failure.reason.label }) {
                counts[i].count += 1
            } else {
                counts.append((failure.reason.label, 1))
            }
        }
        return "\(stayed) stayed (" + counts.map { "\($0.count) \($0.label)" }.joined(separator: ", ") + ")"
    }
}
