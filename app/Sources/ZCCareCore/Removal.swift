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

    public var stayed: Int { failures.count }

    /// Deletes each item for good. One already gone counts as deleted.
    public static func delete(_ urls: [URL]) -> Removal {
        var removal = Removal()
        for url in urls {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                if (error as NSError).code == CocoaError.fileNoSuchFile.rawValue { continue }
                removal.failures.append(Failure(name: url.lastPathComponent, reason: reason(for: error)))
            }
        }
        return removal
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
