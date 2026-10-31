import CryptoKit
import Foundation

/// Files with the same bytes in more than one place, for My Clutter.
public struct DuplicateGroup: Codable, Sendable, Equatable, Identifiable {
    public var files: [LargeFile]
    /// Each copy's size; the copies past the first are what it wastes.
    public var size: Int64
    /// The copy that has hard links elsewhere: removing it frees nothing.
    public var linked: String?

    public var id: String { files.map(\.id).joined(separator: "\n") }
    public var wasted: Int64 { size * Int64(max(files.count - 1, 0)) }

    /// The copy with hard links, else the oldest, likely the original; the
    /// shorter path when dates tie.
    public var keeper: LargeFile {
        files.first { $0.id == linked } ?? files.min { a, b in
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
            for rivals in sameFirstBytes(separateFiles(files), size: size) {
                var byHash: [String: [LargeFile]] = [:]
                for file in rivals {
                    if let hash = sha256(file.url) { byHash[hash, default: []].append(file) }
                }
                for same in byHash.values {
                    let linked = same.filter(hasOtherNames).map(\.id).min()
                    // One linked copy stays; a second would free nothing either.
                    let files = same.filter { !hasOtherNames($0) || $0.id == linked }
                    if files.count > 1 {
                        groups.append(DuplicateGroup(files: files.sorted { $0.id < $1.id }, size: size, linked: linked))
                    }
                }
            }
        }
        return Array(groups.sorted { $0.wasted > $1.wasted }.prefix(limit))
    }

    /// The other copies that still hold the keeper's bytes: a scan may be
    /// days old, and a copy edited since is no longer a duplicate. Equal
    /// hashes are not enough: a path that became a link, or that now leads
    /// to the keeper's own file, would take the keeper with it, and a folder
    /// that became a link leads somewhere the scan never looked.
    public static func stillSame(_ group: DuplicateGroup, home: String) -> [LargeFile] {
        guard !group.files.contains(where: { SpaceLens.passesLink($0.url.path, home: home) }),
              let keeper = regularFile(group.keeper.url), let kept = sha256(group.keeper.url) else { return [] }
        let same = group.others.compactMap { file -> (file: LargeFile, stamp: [UInt64])? in
            guard let copy = regularFile(file.url), copy != keeper, sha256(file.url) == kept else { return nil }
            return (file, copy)
        }
        // Hashing takes time: what it read must outlast it, unedited.
        guard regularFile(group.keeper.url) == keeper else { return [] }
        return same.filter { regularFile($0.file.url) == $0.stamp }.map(\.file)
    }

    /// The device, inode, size and modified time of the file a path names,
    /// nil unless it is a regular file itself rather than a link to one.
    static func regularFile(_ url: URL) -> [UInt64]? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return [UInt64(truncatingIfNeeded: info.st_dev), info.st_ino, UInt64(truncatingIfNeeded: info.st_size),
                UInt64(truncatingIfNeeded: info.st_mtimespec.tv_sec), UInt64(truncatingIfNeeded: info.st_mtimespec.tv_nsec)]
    }

    /// Hard links to one file are one file: removing a link frees nothing.
    static func separateFiles(_ files: [LargeFile]) -> [LargeFile] {
        var seen = Set<[UInt64]>()
        return files.filter { file in
            var info = stat()
            guard lstat(file.url.path, &info) == 0 else { return true }
            return seen.insert([UInt64(truncatingIfNeeded: info.st_dev), info.st_ino]).inserted
        }
    }

    static func hasOtherNames(_ file: LargeFile) -> Bool {
        var info = stat()
        return lstat(file.url.path, &info) == 0 && info.st_nlink > 1
    }

    /// Groups files by their first megabyte, so a pair of large files that
    /// differ early is told apart without reading either to the end.
    static func sameFirstBytes(_ files: [LargeFile], size: Int64) -> [[LargeFile]] {
        guard files.count > 1 else { return [] }
        guard size > prefix else { return [files] }
        var byStart: [String: [LargeFile]] = [:]
        for file in files {
            if let hash = sha256(file.url, limit: prefix) { byStart[hash, default: []].append(file) }
        }
        return byStart.values.filter { $0.count > 1 }
    }

    private static let prefix = 1 << 20

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

    /// The file's hash, or only its first `limit` bytes'. Nil when it cannot
    /// be read to the end: half a hash proves nothing.
    static func sha256(_ url: URL, limit: Int = .max) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return sha256(limit: limit) { try handle.read(upToCount: $0) }
    }

    /// What `read` gives until nil, an empty chunk or `limit` bytes; nil if
    /// it throws.
    static func sha256(limit: Int, read: (Int) throws -> Data?) -> String? {
        var hasher = SHA256()
        var left = limit
        do {
            // Nil here is the end of the file; an error throws.
            while left > 0, let chunk = try read(min(left, 1 << 20)), !chunk.isEmpty {
                hasher.update(data: chunk)
                left -= chunk.count
            }
        } catch {
            return nil
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
