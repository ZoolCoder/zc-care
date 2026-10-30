import Foundation

/// An installer package macOS keeps a receipt for, and whether what it
/// installed is still on disk.
public struct PackageReceipt: Sendable, Equatable, Identifiable {
    public enum State: Sendable, Equatable { case installed, partly, gone }

    public var id: String
    public var version: String
    public var installed: Date?
    public var files: Int
    public var state: State
    /// The app it put in place, or the folder its files share.
    public var anchor: String
}

/// Reads `pkgutil`'s receipts. Apple's own packages are left out, and
/// nothing here changes a receipt: forgetting one needs an administrator
/// and leaves the files where they are.
public enum Receipts {
    /// Package ids from `pkgutil --pkgs`, without Apple's. An id that
    /// could pass for an option is dropped before it reaches pkgutil.
    public static func ids(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).map(String.init).filter { id in
            // ASCII only, so a look-alike letter cannot pass for com.apple.
            !id.hasPrefix("com.apple.") && id.first.map { $0.isASCII && ($0.isLetter || $0.isNumber) } == true
                && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0)) }
        }
    }

    /// Version, install date and where its paths start, from
    /// `pkgutil --pkg-info-plist`.
    public static func info(_ plist: Data) -> (version: String, installed: Date?, root: String)? {
        guard let dict = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any] else { return nil }
        let volume = dict["volume"] as? String ?? "/"
        let location = dict["install-location"] as? String ?? "/"
        let time = (dict["install-time"] as? NSNumber)?.doubleValue
        return (dict["pkg-version"] as? String ?? "", time.map { Date(timeIntervalSince1970: $0) },
                join(volume, location))
    }

    /// What became of a package's files: a sample is checked, since some
    /// install thousands.
    public static func receipt(id: String, version: String, installed: Date?, root: String, files: [String],
                               exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> PackageReceipt? {
        guard !files.isEmpty else { return nil }
        let step = max(files.count / 64, 1)
        let sample = stride(from: 0, to: files.count, by: step).map { join(root, files[$0]) }
        let found = sample.filter(exists).count
        let state: PackageReceipt.State = found == 0 ? .gone : found == sample.count ? .installed : .partly
        return PackageReceipt(id: id, version: version, installed: installed, files: files.count, state: state,
                              anchor: join(root, anchor(files)))
    }

    /// The first app bundle among the files, else the folder they all share.
    static func anchor(_ files: [String]) -> String {
        // The first bundle a file sits in: an app first, then the bundles
        // packages put in the Library, a JDK or an audio driver.
        for ext in ["app", "jdk", "driver", "kext", "plugin", "prefPane", "bundle"] {
            for file in files {
                if let range = file.range(of: "." + ext + "/") { return String(file[..<range.lowerBound]) + "." + ext }
            }
        }
        var shared = files[0].split(separator: "/").dropLast()
        for file in files.dropFirst() {
            let parts = file.split(separator: "/").dropLast()
            shared = shared.prefix(zip(shared, parts).prefix { $0 == $1 }.count)
        }
        return shared.joined(separator: "/")
    }

    static func join(_ base: String, _ path: String) -> String {
        let tail = path.hasPrefix("./") ? String(path.dropFirst(2)) : path
        let head = base.hasSuffix("/") ? String(base.dropLast()) : base
        let joined = tail.isEmpty ? (head.isEmpty ? "/" : head) : head + "/" + tail.drop { $0 == "/" }
        // A receipt is written by the package: `..` in it must not point the
        // check or Show in Finder somewhere else.
        return (joined as NSString).standardizingPath
    }
}
