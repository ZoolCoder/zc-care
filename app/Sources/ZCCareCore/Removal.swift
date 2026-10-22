import Foundation

/// What a permanent delete left behind, and why each item stayed.
public struct Removal: Sendable, Equatable {
    public init() {}

    public enum Reason: Sendable, Equatable {
        case permissionDenied, inUse
        case other(String)

        var label: String {
            switch self {
            case .permissionDenied: "permission denied"
            case .inUse: "in use"
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
        each(urls) { try FileManager.default.removeItem(at: $0) }
    }

    /// Moves each item to the Trash, noting where it went.
    public static func trash(_ urls: [URL]) -> Removal {
        var moved: [Trashed] = []
        var removal = each(urls) { url in
            var binned: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &binned)
            if let binned { moved.append(Trashed(original: url, inTrash: binned as URL)) }
        }
        removal.trashed = moved
        return removal
    }

    /// To the Trash, or for good when the user chose that in Settings.
    public static func remove(_ urls: [URL], permanently: Bool) -> Removal {
        permanently ? delete(urls) : trash(urls)
    }

    private static func each(_ urls: [URL], _ step: (URL) throws -> Void) -> Removal {
        var removal = Removal()
        for url in urls {
            do {
                try step(url)
            } catch {
                if isGone(error) { continue }
                removal.failures.append(Failure(name: url.lastPathComponent, reason: reason(for: error)))
            }
        }
        return removal
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
