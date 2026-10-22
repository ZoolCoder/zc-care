import Foundation

/// A cloud folder this Mac keeps in sync: iCloud Drive, or a File Provider
/// folder such as Google Drive's, OneDrive's or Dropbox's.
public struct CloudDrive: Sendable, Equatable, Identifiable {
    public var name: String
    public var url: URL

    public var id: String { url.path }
    /// iCloud items can be evicted by any app; other providers only let
    /// their own app or the Finder do it.
    public var isICloud: Bool { url.path.contains("/Mobile Documents/") }
}

/// What the cloud folders hold on this Mac. A file kept only in the cloud
/// takes no disk space, so only downloaded files count.
public enum CloudDrives {
    /// The cloud folders under the home folder, iCloud Drive first.
    public static func found(home: URL, fileManager fm: FileManager = .default) -> [CloudDrive] {
        var drives: [CloudDrive] = []
        let icloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if fm.fileExists(atPath: icloud.path) { drives.append(CloudDrive(name: "iCloud Drive", url: icloud)) }
        let storage = home.appendingPathComponent("Library/CloudStorage")
        let folders = (try? fm.contentsOfDirectory(atPath: storage.path)) ?? []
        for folder in folders.sorted() where !folder.hasPrefix(".") {
            drives.append(CloudDrive(name: name(folder: folder), url: storage.appendingPathComponent(folder)))
        }
        return drives
    }

    /// A provider's name from its folder: GoogleDrive-me@example.com is
    /// Google Drive, OneDrive-Personal is OneDrive.
    public static func name(folder: String) -> String {
        let provider = folder.split(separator: "-", maxSplits: 1).first.map(String.init) ?? folder
        switch provider {
        case "GoogleDrive": return "Google Drive"
        case "OneDrive": return "OneDrive"
        case "Dropbox": return "Dropbox"
        case "Box": return "Box"
        default: return provider
        }
    }

    /// The downloaded files of at least `minimum` bytes, biggest first, and
    /// what every downloaded file takes together. A file still waiting to
    /// upload, or one whose upload state is unknown (every non-iCloud
    /// provider), counts but is not listed: its only copy may be on this Mac.
    public static func downloaded(in folder: URL, minimum: Int64, limit: Int = 60) -> (total: Int64, files: [LargeFile]) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .contentModificationDateKey,
                                      .ubiquitousItemIsUploadedKey]
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return (0, [])
        }
        // Only iCloud reports whether a file is uploaded; for the others a listed file could be trashed in the cloud.
        let listable = !folder.path.contains("/Library/CloudStorage/")
        var total: Int64 = 0
        var files: [LargeFile] = []
        for case let url as URL in walk {
            if Task.isCancelled { break }
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                  let size = v.totalFileAllocatedSize, size > 0 else { continue }
            total += Int64(size)
            if listable, size >= minimum, v.ubiquitousItemIsUploaded == true { files.append(LargeFile(url: url, size: Int64(size), modified: v.contentModificationDate)) }
        }
        return (total, Array(files.sorted { $0.size > $1.size }.prefix(limit)))
    }
}
