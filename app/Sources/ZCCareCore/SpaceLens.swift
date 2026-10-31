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
    /// The path must be written plainly (no `..`, `.` or doubled or
    /// trailing slash) and no part of it below home may be a symlink, which
    /// could lead out of the folder it seems to be in.
    public static func canTrash(_ path: String, home: String) -> Bool {
        let home = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !home.isEmpty, home != "/", (path as NSString).standardizingPath == path,
              path.hasPrefix(home + "/") else { return false }
        let parts = path.dropFirst(home.count + 1).split(separator: "/").map(String.init)
        var walked = home
        for part in parts {
            walked += "/" + part
            if isSymlink(walked) { return false }
        }
        guard let top = parts.first, !top.hasPrefix("."),
              !["Dropbox", "Google Drive", "OneDrive", "iCloud", "Box", "Creative Cloud Files", "pCloud"]
                  .contains(where: { top.hasPrefix($0) }) else { return false }
        if parts.count == 1 {
            return !["Applications", "Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures", "Public",
                     "Developer"].contains(top)
        }
        return top != "Library"
    }

    private static func isSymlink(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
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
/// It keeps the scan before it too, to show what grew since.
public struct SpaceScan: Codable, Sendable, Equatable {
    public var scannedAt: Date
    public var root: SpaceNode
    public var previousAt: Date?
    public var previousRoot: SpaceNode?

    public init(scannedAt: Date, root: SpaceNode, previousAt: Date? = nil, previousRoot: SpaceNode? = nil) {
        self.scannedAt = scannedAt
        self.root = root
        self.previousAt = previousAt
        self.previousRoot = previousRoot
    }

    /// Scans closer together than this are one baseline: a rescan an hour
    /// later must not wipe out the week it should be compared with.
    static let baselineGap: TimeInterval = 86400
    /// Growth below this is noise: files come and go all day.
    public static let noticeable: Int64 = 50_000_000

    /// A new scan after this one. It compares with this one, or with the
    /// baseline this one already had, when this one is newer than the gap.
    public func followed(by root: SpaceNode, at date: Date = .now) -> SpaceScan {
        if date.timeIntervalSince(scannedAt) < Self.baselineGap, previousRoot != nil {
            return SpaceScan(scannedAt: date, root: root, previousAt: previousAt, previousRoot: previousRoot)
        }
        return SpaceScan(scannedAt: date, root: root, previousAt: scannedAt, previousRoot: self.root)
    }

    /// How much a folder grew since the previous scan; nil when either
    /// scan did not reach it.
    public func growth(of path: String) -> Int64? {
        guard let before = previousRoot?.find(path), let now = root.find(path) else { return nil }
        return now.size - before.size
    }

    /// The folders under `path` (the whole scan by default) that grew most,
    /// biggest first. A folder whose growth is mostly one child's gives way
    /// to that child, the better place to look.
    public func growers(under path: String? = nil, from minimum: Int64 = noticeable, limit: Int = 5) -> [Grower] {
        guard previousRoot != nil else { return [] }
        var found: [Grower] = []
        let start: SpaceNode
        if let path {
            guard let node = root.find(path) else { return [] }
            start = node
        } else {
            start = root
        }
        func walk(_ node: SpaceNode) {
            for child in node.children {
                if let grew = growth(of: child.path), grew >= minimum { found.append(Grower(path: child.path, grew: grew)) }
                walk(child)
            }
        }
        walk(start)
        let grew = Dictionary(found.map { ($0.path, $0.grew) }, uniquingKeysWith: { a, _ in a })
        return found
            .filter { grower in
                !(root.find(grower.path)?.children ?? []).contains { (grew[$0.path] ?? 0) * 2 >= grower.grew }
            }
            .sorted { $0.grew > $1.grew }
            .prefix(limit).map { $0 }
    }

    public static func load(from url: URL) -> SpaceScan? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SpaceScan.self, from: data)
    }

    public func save(to url: URL) throws {
        try PrivateFile.write(JSONEncoder().encode(self), to: url)
    }
}

/// A folder that grew since the previous Space Lens scan.
public struct Grower: Sendable, Equatable, Identifiable {
    public var path: String
    public var grew: Int64

    public var id: String { path }
}

/// The Care module that handles a kind of folder Space Lens only measures.
public enum SpaceDestination: String, Sendable {
    case clutter, developer, cloud

    public static func of(_ path: String, home: String) -> SpaceDestination? {
        guard path.hasPrefix(home + "/") else { return nil }
        let rest = String(path.dropFirst(home.count + 1))
        func within(_ folders: [String]) -> Bool { folders.contains { rest == $0 || rest.hasPrefix($0 + "/") } }
        if within(["Library/Mobile Documents", "Library/CloudStorage"]) { return .cloud }
        if within(["Library/Developer", "Library/Containers/com.docker.docker", "Developer", ".gradle", ".npm", ".cargo"]) {
            return .developer
        }
        if within(["Downloads", "Documents", "Desktop"]) { return .clutter }
        return nil
    }
}
