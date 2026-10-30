import CryptoKit
import Foundation

/// Files with the same bytes in more than one place, for My Clutter.
public struct DuplicateGroup: Codable, Sendable, Equatable, Identifiable {
    public var files: [LargeFile]
    /// Each copy's size; the copies past the first are what it wastes.
    public var size: Int64

    public var id: String { files.map(\.id).joined(separator: "\n") }
    public var wasted: Int64 { size * Int64(max(files.count - 1, 0)) }

    /// The oldest copy, likely the original; the shorter path when dates tie.
    public var keeper: LargeFile {
        files.min { a, b in
            let (x, y) = (a.modified ?? .distantFuture, b.modified ?? .distantFuture)
            return x != y ? x < y : a.url.path.count < b.url.path.count
        }!
    }

    public var others: [LargeFile] { files.filter { $0 != keeper } }
}

public enum Duplicates {
    /// Same-size files first, the cheap test, then their SHA-256: hashing
    /// runs only where sizes collide. Biggest waste first. A file in a git
    /// working tree is the project's own copy, so it is never one. The
    /// `limit` biggest wastes return.
    public static func groups(paths: [String], home: String, minimum: Int64, limit: Int = .max) -> [DuplicateGroup] {
        let candidates = outsideRepos(LargeFiles.candidates(paths: paths, home: home, minimum: minimum), home: home)
        var bySize: [Int64: [LargeFile]] = [:]
        for file in candidates {
            let length = (try? file.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            bySize[Int64(length), default: []].append(file)
        }
        var groups: [DuplicateGroup] = []
        for (size, files) in bySize where files.count > 1 && size > 0 {
            var byHash: [String: [LargeFile]] = [:]
            for file in files {
                if let hash = sha256(file.url) { byHash[hash, default: []].append(file) }
            }
            for same in byHash.values where same.count > 1 {
                groups.append(DuplicateGroup(files: same.sorted { $0.id < $1.id }, size: size))
            }
        }
        return Array(groups.sorted { $0.wasted > $1.wasted }.prefix(limit))
    }

    /// The other copies that still hold the keeper's bytes: a scan may be
    /// days old, and a copy edited since is no longer a duplicate.
    public static func stillSame(_ group: DuplicateGroup) -> [LargeFile] {
        guard let kept = sha256(group.keeper.url) else { return [] }
        return group.others.filter { sha256($0.url) == kept }
    }

    static func outsideRepos(_ files: [LargeFile], home: String) -> [LargeFile] {
        var repos: [String: Bool] = [:]
        return files.filter { !inRepo($0.url.deletingLastPathComponent(), home: home, cache: &repos) }
    }

    /// Whether the folder or one above it, up to the home folder, holds .git.
    static func inRepo(_ folder: URL, home: String, cache: inout [String: Bool]) -> Bool {
        let path = folder.path
        guard path.hasPrefix(home + "/") else { return false }
        if let known = cache[path] { return known }
        let found = FileManager.default.fileExists(atPath: path + "/.git")
            || inRepo(folder.deletingLastPathComponent(), home: home, cache: &cache)
        cache[path] = found
        return found
    }

    static func sha256(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public enum OldDownloads {
    /// What sat in the folder for longer than `days`, by when it arrived:
    /// a download keeps the date its server gave it as its modified date.
    public static func files(in folder: URL, olderThan days: Int = 30, now: Date = .now) -> [LargeFile] {
        let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .contentModificationDateKey]
        let all = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                options: [.skipsHiddenFiles])) ?? []
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        return all.compactMap { url -> LargeFile? in
            let v = try? url.resourceValues(forKeys: Set(keys))
            guard let added = v?.addedToDirectoryDate ?? v?.contentModificationDate, added < cutoff else { return nil }
            return LargeFile(url: url, size: DiskUsage.allocated(url), modified: added)
        }
        .sorted { $0.size > $1.size }
    }
}
