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
            Junk(id: "npx", title: "npx packages", detail: "Tools npx and MCP servers fetch; running ones keep theirs, the rest npx fetches again.",
                 path: home + "/.npm/_npx"),
            Junk(id: "mail", title: "Mail downloads", detail: "Copies of attachments Mail saved on opening; the mail keeps the originals.",
                 path: home + "/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"),
            Junk(id: "logs", title: "Logs", detail: "What apps logged; ZC Care keeps its own.",
                 path: home + "/Library/Logs", keep: ["ZCCare"]),
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

    /// Removes every entry but those kept, or only the named ones, and
    /// returns how many would not go: some caches belong to the system.
    @discardableResult
    public func empty(keeping extra: Set<String> = [], only: Set<String>? = nil) -> Int {
        entries(keeping: extra)
            .filter { only?.contains($0.lastPathComponent) ?? true }
            .filter { (try? FileManager.default.removeItem(at: $0)) == nil }.count
    }

    /// The entries running commands point into: an MCP server npx started
    /// runs from its folder in _npx until it quits.
    public func inUse(commands: [String]) -> Set<String> {
        let folder = path.hasSuffix("/") ? path : path + "/"
        var names = Set<String>()
        for command in commands {
            var rest = command[...]
            while let found = rest.range(of: folder) {
                let name = rest[found.upperBound...].prefix { $0 != "/" && $0 != " " }
                if !name.isEmpty { names.insert(String(name)) }
                rest = rest[found.upperBound...]
            }
        }
        return names
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
