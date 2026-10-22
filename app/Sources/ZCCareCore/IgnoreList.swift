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
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let path = Self.clean(path)
        guard !path.isEmpty, path != "/", !paths.contains(where: { Self.same($0, path) }) else { return }
        paths.append(path)
        paths.sort()
    }

    public mutating func remove(_ path: String) {
        let path = Self.clean(path)
        paths.removeAll { Self.same($0, path) }
    }

    /// Whether the path is on the list or inside a folder that is. Symlinks
    /// resolve first: temp folders come back as /private/var. Case does not
    /// matter, as on a default APFS volume.
    public func covers(_ path: String) -> Bool {
        let path = Self.clean(path)
        return paths.contains { Self.same(path, $0) || Self.relative(path, to: $0) != nil }
    }

    public func covers(_ url: URL) -> Bool { covers(url.path) }

    /// Whether removing the path would remove something on the list: it is
    /// covered, or an ignored path lies inside it. Such a folder is not
    /// trashed whole.
    public func touches(_ path: String) -> Bool {
        let path = Self.clean(path)
        return covers(path) || paths.contains { Self.relative($0, to: path) != nil }
    }

    public func touches(_ url: URL) -> Bool { touches(url.path) }

    /// The names directly inside `folder` that are on the list or hold
    /// something that is, for Junk's keep set; every name when the folder
    /// itself is ignored.
    public func names(in folder: String) -> Set<String> {
        let folder = Self.clean(folder)
        if covers(folder) {
            return Set((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [])
        }
        return Set(paths.compactMap { path in
            Self.relative(path, to: folder)?.split(separator: "/").first.map(String.init)
        })
    }

    public func keep(_ files: [LargeFile]) -> [LargeFile] {
        files.filter { !touches($0.url) }
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

    private static func same(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: .caseInsensitive) == .orderedSame
    }

    /// What follows `folder/` in `path`, ignoring case; nil when the path is not inside the folder.
    private static func relative(_ path: String, to folder: String) -> String? {
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        guard let found = path.range(of: prefix, options: [.anchored, .caseInsensitive]) else { return nil }
        let rest = String(path[found.upperBound...])
        return rest.isEmpty ? nil : rest
    }
}
