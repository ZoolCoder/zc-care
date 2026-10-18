import Foundation

/// A folder and what it holds, for Space Lens's rings.
public struct SpaceNode: Codable, Sendable, Equatable, Identifiable {
    public var path: String
    public var size: Int64
    public var children: [SpaceNode]

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }

    /// The node at `path`, searched from here down.
    public func find(_ path: String) -> SpaceNode? {
        if self.path == path { return self }
        guard path.hasPrefix(self.path + "/") else { return nil }
        return children.lazy.compactMap { $0.find(path) }.first
    }

    /// The tree without the node at `path`, each folder above it that much smaller.
    public func removing(_ path: String) -> SpaceNode {
        guard let gone = find(path), path != self.path else { return self }
        var copy = self
        copy.size -= gone.size
        copy.children = children.compactMap { child in
            child.path == path ? nil : path.hasPrefix(child.path + "/") ? child.removing(path) : child
        }
        return copy
    }
}

public enum SpaceLens {
    /// Whether Space Lens may move the folder to the Trash. Not the home
    /// folder's own folders, nor its hidden ones, where keys and settings
    /// live, nor anything in the Library: iCloud Drive and app data are
    /// there, and Cleanup clears its caches. Nor a synced folder: what goes
    /// there goes from the cloud and every other device.
    public static func canTrash(_ path: String, home: String) -> Bool {
        guard path.hasPrefix(home + "/") else { return false }
        let parts = path.dropFirst(home.count + 1).split(separator: "/").map(String.init)
        guard let top = parts.first, !top.hasPrefix("."),
              !["Dropbox", "Google Drive", "OneDrive", "iCloud", "Box", "Creative Cloud Files", "pCloud"]
                  .contains(where: { top.hasPrefix($0) }) else { return false }
        if parts.count == 1 {
            return !["Applications", "Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures", "Public",
                     "Developer"].contains(top)
        }
        return top != "Library"
    }

    /// Folders below this share of their parent fold into nothing: a ring
    /// of slivers says less than its biggest few.
    static let smallest = 0.01

    /// The `du` that measures `root`, three folders deep. It stays out of
    /// the Photos and Music libraries: reading one makes macOS ask for
    /// media access, and every later file check waits on the answer.
    public static func arguments(root: String) -> [String] {
        ["-k", "-d", "3", "-x"] + LargeFiles.appLibraries.flatMap { ["-I", "*" + $0] } + [root]
    }

    /// `du -k -d N root`: a line per folder, in kilobytes, children before
    /// their parent. Each folder keeps its biggest children.
    public static func parse(du text: String, root: String, keep: Int = 14) -> SpaceNode? {
        var sizes: [String: Int64] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let f = line.split(separator: "\t", maxSplits: 1)
            guard f.count == 2, let kb = Int64(f[0].trimmingCharacters(in: .whitespaces)) else { continue }
            sizes[String(f[1])] = kb * 1024
        }
        guard sizes[root] != nil else { return nil }
        var kids: [String: [String]] = [:]
        for path in sizes.keys where path != root {
            kids[(path as NSString).deletingLastPathComponent, default: []].append(path)
        }
        func node(_ path: String) -> SpaceNode {
            let size = sizes[path] ?? 0
            let children = (kids[path] ?? [])
                .filter { Double(sizes[$0] ?? 0) >= Double(size) * smallest }
                .sorted { (sizes[$0] ?? 0) > (sizes[$1] ?? 0) }
                .prefix(keep)
                .map(node)
            return SpaceNode(path: path, size: size, children: Array(children))
        }
        return node(root)
    }
}

/// A Space Lens scan, kept on disk: du over the home folder takes minutes.
public struct SpaceScan: Codable, Sendable, Equatable {
    public var scannedAt: Date
    public var root: SpaceNode

    public init(scannedAt: Date, root: SpaceNode) {
        self.scannedAt = scannedAt
        self.root = root
    }

    public static func load(from url: URL) -> SpaceScan? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SpaceScan.self, from: data)
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
