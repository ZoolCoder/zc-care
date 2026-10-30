import Foundation

/// A folder Free Up empties: caches, build output and downloads, all of
/// which come back on their own when needed.
public struct Junk: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var detail: String
    public var path: String
    /// Entries inside the folder to leave alone, by name in any case.
    public var keep: Set<String> = []
    /// Cleared by hand only, never by Clean All: what it holds does not
    /// come back on its own.
    public var optional = false

    public static func spots(home: String) -> [Junk] {
        [
            Junk(id: "caches", title: "App caches", detail: "Each app rebuilds its own; open apps keep theirs.",
                 path: home + "/Library/Caches",
                 // Own spots, and what does not come back by itself: antidote's
                 // plugin clones, Playwright's and Cypress's browsers, the
                 // CLI's askpass helper. Reading Music's caches asks for the
                 // media library, a prompt a cleanup should not raise.
                 keep: ["Homebrew", "pip", "Yarn", "CocoaPods", "go-build", "antidote", "ms-playwright", "Cypress",
                        "zc-care", "com.apple.Music", "com.apple.iTunesCloud", "com.apple.itunescloudd"]),
            Junk(id: "homebrew", title: "Homebrew downloads", detail: "Bottles and casks already installed.",
                 path: home + "/Library/Caches/Homebrew"),
            Junk(id: "npm", title: "npm cache", detail: "Packages npm downloads again when needed.",
                 path: home + "/.npm/_cacache"),
            Junk(id: "gradle", title: "Gradle caches", detail: "The next build downloads its dependencies again.",
                 path: home + "/.gradle/caches"),
            Junk(id: "xcode", title: "Xcode build output", detail: "DerivedData, rebuilt on the next build.",
                 path: home + "/Library/Developer/Xcode/DerivedData"),
            Junk(id: "devicesupport", title: "Xcode device support", detail: "Symbols for each iOS a device ran; Xcode copies them again.",
                 path: home + "/Library/Developer/Xcode/iOS DeviceSupport"),
            Junk(id: "simulators", title: "Simulator caches", detail: "Dyld and runtime caches the simulators rebuild.",
                 path: home + "/Library/Developer/CoreSimulator/Caches"),
            Junk(id: "devicelogs", title: "Xcode device logs", detail: "Crash logs copied from iPhones and iPads; Xcode copies them again when a device connects.",
                 path: home + "/Library/Developer/Xcode/iOS Device Logs"),
            Junk(id: "testdevices", title: "Xcode test devices", detail: "Simulators cloned for test runs; the next run makes them again.",
                 path: home + "/Library/Developer/XCTestDevices"),
            Junk(id: "go", title: "Go build cache", detail: "Compiled packages go build makes again.",
                 path: home + "/Library/Caches/go-build"),
            Junk(id: "pip", title: "pip cache", detail: "Wheels pip downloads again when needed.",
                 path: home + "/Library/Caches/pip"),
            Junk(id: "uv", title: "uv cache", detail: "Python packages uv downloads again when needed.",
                 path: home + "/.cache/uv"),
            Junk(id: "yarn", title: "Yarn cache", detail: "Packages Yarn downloads again when needed.",
                 path: home + "/Library/Caches/Yarn"),
            Junk(id: "cargo", title: "Cargo downloads", detail: "Crate archives Cargo downloads again when needed.",
                 path: home + "/.cargo/registry/cache"),
            Junk(id: "cocoapods", title: "CocoaPods cache", detail: "Pods downloaded for iOS projects.",
                 path: home + "/Library/Caches/CocoaPods"),
            Junk(id: "pub", title: "Dart and Flutter pub cache", detail: "Hosted packages pub downloads again; a tool from dart pub global activate needs activating again.",
                 path: home + "/.pub-cache/hosted", optional: true),
            Junk(id: "gradlewrapper", title: "Gradle wrapper distributions", detail: "Gradle versions the wrapper downloads again when a project needs one.",
                 path: home + "/.gradle/wrapper/dists"),
            Junk(id: "pnpm", title: "pnpm store", detail: "Packages pnpm downloads again when needed; clear it while no install runs.",
                 path: home + "/Library/pnpm/store"),
            Junk(id: "pnpmxdg", title: "pnpm store (XDG)", detail: "Packages pnpm downloads again when needed; clear it while no install runs.",
                 path: home + "/.local/share/pnpm/store"),
            Junk(id: "bun", title: "Bun install cache", detail: "Packages Bun downloads again when needed; clear it while no install runs.",
                 path: home + "/.bun/install/cache"),
            Junk(id: "gomod", title: "Go module downloads", detail: "Module archives go downloads again while no build runs; the extracted copies in pkg/mod are read-only and stay.",
                 path: home + "/go/pkg/mod/cache/download"),
            Junk(id: "misedownloads", title: "mise downloads", detail: "Tool archives mise fetches again when it installs.",
                 path: home + "/.local/share/mise/downloads"),
            Junk(id: "npx", title: "npx packages", detail: "Tools npx and MCP servers fetch; running ones keep theirs, the rest npx fetches again.",
                 path: home + "/.npm/_npx"),
            Junk(id: "mail", title: "Mail downloads", detail: "Copies of attachments Mail saved on opening; the mail keeps the originals.",
                 path: home + "/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"),
            Junk(id: "logs", title: "Logs", detail: "What apps logged; ZC Care keeps its own.",
                 path: home + "/Library/Logs", keep: ["ZCCare"]),
            Junk(id: "iosbackups", title: "iPhone and iPad backups", detail: "Backups the Finder made of a device. A new one takes a full backup again; iCloud backups stay.",
                 path: home + "/Library/Application Support/MobileSync/Backup", optional: true),
        ]
    }

    /// The bytes the folder's entries take on disk, less those kept.
    public func size(keeping extra: Set<String> = []) -> Int64 {
        entries(keeping: extra).reduce(0) { $0 + DiskUsage.allocated($1) }
    }

    /// Each entry and its size, biggest first, for Cleanup's preview.
    public func contents(keeping extra: Set<String> = []) -> [JunkEntry] {
        entries(keeping: extra)
            .map { JunkEntry(name: $0.lastPathComponent, size: DiskUsage.allocated($0)) }
            .sorted { $0.size > $1.size }
    }

    /// Moves every entry but those kept, or only the named ones, to the Trash, or deletes them for
    /// good, and returns what would not go: some caches belong to the system.
    @discardableResult
    public func empty(keeping extra: Set<String> = [], only: Set<String>? = nil, permanently: Bool = false) -> Removal {
        Removal.remove(entries(keeping: extra).filter { only?.contains($0.lastPathComponent) ?? true }, permanently: permanently)
    }

    /// The entries running commands point into: an MCP server npx started
    /// runs from its folder in _npx until it quits.
    public func inUse(commands: [String]) -> Set<String> {
        let folder = path.hasSuffix("/") ? path : path + "/"
        var names = Set<String>()
        for command in commands {
            var rest = command[...]
            while let found = rest.range(of: folder) {
                let after = rest[found.upperBound...]
                // ps prints the command unquoted, so a name with spaces runs to the next "/" or the end.
                let name = after.prefix { $0 != "/" }
                let words = Self.candidates(String(name))
                let existing = words.filter { FileManager.default.fileExists(atPath: folder + $0) }
                names.formUnion(existing.isEmpty ? words.prefix(1) : existing[...])
                rest = after
            }
        }
        return names
    }

    /// A name ps printed may be followed by arguments: each word-boundary prefix may be the entry's name.
    private static func candidates(_ text: String) -> [String] {
        var out: [String] = []
        var end = text.startIndex
        while end < text.endIndex {
            end = text[end...].dropFirst().firstIndex(of: " ") ?? text.endIndex
            let name = text[..<end].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { out.append(name) }
        }
        return out
    }

    private func entries(keeping extra: Set<String>) -> [URL] {
        guard OwnFolder.check(path) else { return [] }
        let kept = Set(keep.union(extra).map { $0.lowercased() })
        let all = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path),
                                                                includingPropertiesForKeys: nil)) ?? []
        return all.filter { !kept.contains($0.lastPathComponent.lowercased()) }
    }
}

/// One file or folder in a Junk folder.
public struct JunkEntry: Sendable, Equatable, Identifiable {
    public var name: String
    public var size: Int64

    public var id: String { name }
}
