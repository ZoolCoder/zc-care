import Foundation

/// Files and folders ZC Care leaves alone: never listed, cleaned or trashed,
/// nor anything inside them.
public struct IgnoreList: Sendable, Equatable {
    public private(set) var paths: [String]

    public init(_ paths: [String] = []) {
        self.paths = []
        for path in paths { add(path) }
    }

    public mutating func add(_ path: String) {
        let path = Self.clean(path)
        guard !path.isEmpty, path != "/", !paths.contains(path) else { return }
        paths.append(path)
        paths.sort()
    }

    public mutating func remove(_ path: String) {
        paths.removeAll { $0 == path }
    }

    /// Whether the path is on the list or inside a folder that is. Symlinks
    /// resolve first: temp folders come back as /private/var.
    public func covers(_ path: String) -> Bool {
        let path = Self.clean(path)
        return paths.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    public func covers(_ url: URL) -> Bool { covers(url.path) }

    /// The names inside `folder` that are on the list, for Junk's keep set.
    public func names(in folder: String) -> Set<String> {
        let folder = Self.clean(folder)
        return Set(paths.compactMap { path in
            let name = (path as NSString).lastPathComponent
            return Self.clean((path as NSString).deletingLastPathComponent) == folder ? name : nil
        })
    }

    public func keep(_ files: [LargeFile]) -> [LargeFile] {
        files.filter { !covers($0.url) }
    }

    /// A group stays while two of its files are not ignored.
    public func keep(_ groups: [DuplicateGroup]) -> [DuplicateGroup] {
        groups.compactMap { group in
            var group = group
            group.files = keep(group.files)
            return group.files.count > 1 ? group : nil
        }
    }

    public func keep(_ groups: [SimilarGroup]) -> [SimilarGroup] {
        groups.compactMap { group in
            var group = group
            group.files = keep(group.files)
            return group.files.count > 1 ? group : nil
        }
    }

    private static func clean(_ path: String) -> String {
        let path = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).resolvingSymlinksInPath().path
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
