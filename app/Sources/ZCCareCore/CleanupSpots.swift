import Foundation

/// Preference files macOS can no longer read: an app writes a fresh one
/// on its next launch, and until then it may fail to start or lose its
/// settings anyway.
public enum BrokenPreferences {
    public static func find(home: String) -> [LargeFile] {
        let root = URL(fileURLWithPath: home + "/Library/Preferences")
        let folders = [root, root.appendingPathComponent("ByHost")]
        return folders.flatMap { folder -> [LargeFile] in
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            return files.filter { $0.pathExtension == "plist" && isBroken($0) }.map {
                LargeFile(url: $0, size: DiskUsage.allocated($0),
                          modified: (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate)
            }
        }
        .sorted { $0.url.path < $1.url.path }
    }

    /// Empty, or not a property list in any format. A file that cannot be
    /// read at all is left alone: that is permissions, not damage.
    static func isBroken(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        if data.isEmpty { return true }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) == nil
    }
}

/// Attachments Mail keeps beside each message of an online account. The
/// message on the server keeps the original, so Mail fetches one again
/// when it is opened. Mailboxes On My Mac are left alone: they have no
/// server copy.
public enum MailAttachments {
    public static func find(home: String, minimum: Int64 = 0) -> [LargeFile] {
        let mail = URL(fileURLWithPath: home + "/Library/Mail")
        let versions = ((try? FileManager.default.contentsOfDirectory(at: mail, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("V") }
        var found: [LargeFile] = []
        for version in versions {
            let accounts = ((try? FileManager.default.contentsOfDirectory(at: version, includingPropertiesForKeys: nil)) ?? [])
                .filter { !["Mailboxes", "MailData"].contains($0.lastPathComponent) }
            for account in accounts { found += attachments(under: account, minimum: minimum) }
        }
        // Years of mail can hold tens of thousands; the biggest are worth a look.
        return Array(found.sorted { $0.size > $1.size }.prefix(1000))
    }

    /// Walks by hand: Mail's .mbox folders are packages, which an
    /// enumerator would skip, and only what sits under Attachments counts.
    static func attachments(under folder: URL, minimum: Int64) -> [LargeFile] {
        var found: [LargeFile] = []
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey]
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys))) ?? []
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: keys)
            if values?.isDirectory == true {
                found += attachments(under: entry, minimum: minimum)
            } else if values?.isRegularFile == true, entry.deletingLastPathComponent().path.contains("/Attachments/") {
                let size = DiskUsage.allocated(entry)
                if size >= minimum { found.append(LargeFile(url: entry, size: size, modified: values?.contentModificationDate)) }
            }
        }
        return found
    }
}

/// A Trash on one volume, and what it holds.
public struct TrashBin: Sendable, Equatable, Identifiable {
    public var name: String
    public var url: URL
    public var size: Int64

    public var id: String { url.path }
}

/// The Trash of the startup disk and of each mounted volume. The Finder
/// empties them all together; this only says how big they are.
public enum TrashBins {
    public static func find(home: String, volumes: [URL], uid: uid_t = getuid()) -> [TrashBin] {
        var bins = [TrashBin(name: "Macintosh HD", url: URL(fileURLWithPath: home + "/.Trash"), size: 0)]
        bins += volumes.map { TrashBin(name: $0.lastPathComponent, url: $0.appendingPathComponent(".Trashes/\(uid)"), size: 0) }
        return bins.compactMap { bin in
            guard let entries = try? FileManager.default.contentsOfDirectory(at: bin.url, includingPropertiesForKeys: nil) else { return nil }
            var bin = bin
            bin.size = entries.reduce(0) { $0 + DiskUsage.allocated($1) }
            return bin
        }
    }

    /// The volumes under /Volumes other than the startup disk's own link.
    public static func mountedVolumes() -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsRootFileSystemKey, .volumeIsInternalKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.filter { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return values?.volumeIsRootFileSystem != true && url.path.hasPrefix("/Volumes/")
        }
    }
}
