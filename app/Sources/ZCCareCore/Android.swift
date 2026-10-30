import Foundation

/// A system image or virtual device the Android tools keep on disk.
public struct AndroidItem: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable { case systemImage = "System image", device = "Virtual device" }

    public var url: URL
    public var name: String
    public var kind: Kind
    public var size: Int64

    public var id: String { url.path }
}

public enum Android {
    /// The SDK folder: $ANDROID_HOME if set and there, else Android Studio's default.
    public static func sdkRoot(home: String, environment: [String: String]) -> String? {
        [environment["ANDROID_HOME"], home + "/Library/Android/sdk"]
            .compactMap { $0 }
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    /// System images (system-images/<api>/<variant>/<abi>) and virtual
    /// devices (<avdHome>/*.avd), biggest first.
    public static func items(sdk: String, avdHome: String) -> [AndroidItem] {
        (systemImages(sdk: sdk) + devices(avdHome: avdHome)).sorted { $0.size > $1.size }
    }

    private static func systemImages(sdk: String) -> [AndroidItem] {
        let root = URL(fileURLWithPath: sdk).appendingPathComponent("system-images")
        return subfolders(root).flatMap { api in
            subfolders(api).flatMap { variant in
                subfolders(variant).map { abi in
                    item(abi, name: "\(api.lastPathComponent) · \(variant.lastPathComponent) · \(abi.lastPathComponent)", kind: .systemImage)
                }
            }
        }
    }

    private static func devices(avdHome: String) -> [AndroidItem] {
        subfolders(URL(fileURLWithPath: avdHome))
            .filter { $0.pathExtension == "avd" }
            .map { item($0, name: $0.deletingPathExtension().lastPathComponent, kind: .device) }
    }

    private static func item(_ url: URL, name: String, kind: AndroidItem.Kind) -> AndroidItem {
        AndroidItem(url: url, name: name, kind: kind, size: DiskUsage.allocated(url))
    }

    private static func subfolders(_ folder: URL) -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return all.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
    }
}
