import Foundation

/// One kind of trace one browser keeps: its history, cookies or cache.
public struct BrowserTrace: Sendable, Equatable, Identifiable {
    public var browser: String
    public var bundleID: String
    /// Every app that keeps these files: Firefox's channels share one
    /// profiles folder, so any of them open holds the databases.
    public var bundleIDs: [String]
    public var kind: String
    /// What clearing removes: database files, a cache folder's entries,
    /// each site's storage folder, or the saved session files.
    public var paths: [URL]
    public var size: Int64

    public var id: String { bundleID + " " + kind }
}

public enum BrowserPrivacy {
    struct Browser {
        var name: String
        var bundleID: String
        var others: [String] = []
        var history: [String] = []
        var cookies: [String] = []
        var caches: [String] = []
        /// Folders of per-site storage, one entry per site: clearing removes
        /// the sites' entries and leaves the extensions'.
        var siteData: [String] = []
        /// The saved tabs and windows a browser reopens.
        var sessions: [String] = []
    }

    public static let history = "History", cookies = "Cookies", cache = "Cache"
    public static let siteData = "Site Data", sessions = "Saved Tabs"

    /// Each browser's traces that hold data, by browser, then history,
    /// cookies, cache, site data and saved tabs. Safari's need Full Disk
    /// Access to read, so without it they come back empty and are left out.
    /// Firefox keeps history and bookmarks in one database, so its history
    /// is not offered.
    public static func find(home: String) -> [BrowserTrace] {
        browsers(home: home).flatMap { b in
            [(history, b.history), (cookies, b.cookies), (cache, b.caches), (siteData, b.siteData), (sessions, b.sessions)]
                .compactMap { kind, paths -> BrowserTrace? in
                let urls = switch kind {
                case cache: paths.flatMap(entries)
                case siteData: paths.flatMap(siteEntries)
                default: paths.flatMap(withSidecars)
                }
                let size = urls.reduce(0) { $0 + DiskUsage.allocated($1) }
                return size > 0 ? BrowserTrace(browser: b.name, bundleID: b.bundleID, bundleIDs: [b.bundleID] + b.others, kind: kind, paths: urls, size: size) : nil
            }
        }
    }

    /// Moves a trace's files to the Trash, or deletes them for good; returns what would not go.
    public static func clear(_ trace: BrowserTrace, permanently: Bool = false) -> Removal {
        Removal.remove(trace.paths, permanently: permanently)
    }

    static func browsers(home: String) -> [Browser] {
        let support = home + "/Library/Application Support/"
        let caches = home + "/Library/Caches/"
        let chromium: [(String, String, String)] = [
            ("Chrome", "com.google.Chrome", "Google/Chrome"),
            ("Brave", "com.brave.Browser", "BraveSoftware/Brave-Browser"),
            ("Edge", "com.microsoft.edgemac", "Microsoft Edge"),
            ("Arc", "company.thebrowser.Browser", "Arc/User Data"),
            ("Vivaldi", "com.vivaldi.Vivaldi", "Vivaldi"),
            ("Chromium", "org.chromium.Chromium", "Chromium"),
        ]
        let safari = home + "/Library/Containers/com.apple.Safari/Data/Library/"
        var all = [Browser(name: "Safari", bundleID: "com.apple.Safari",
                           history: [home + "/Library/Safari/History.db"],
                           cookies: [safari + "Cookies/Cookies.binarycookies"],
                           caches: [caches + "com.apple.Safari", safari + "Caches/com.apple.Safari"])]
        for (name, id, dir) in chromium {
            let profiles = chromiumProfiles(support + dir)
            all.append(Browser(name: name, bundleID: id,
                               history: profiles.flatMap { [$0 + "/History", $0 + "/Visited Links"] },
                               cookies: profiles.flatMap { [$0 + "/Cookies", $0 + "/Network/Cookies"] },
                               caches: [caches + dir],
                               siteData: profiles.map { $0 + "/IndexedDB" },
                               // Vivaldi keeps the sessions its user saved by name in Sessions too.
                               sessions: name == "Vivaldi" ? [] : profiles.flatMap {
                                   [$0 + "/Sessions", $0 + "/Current Session", $0 + "/Current Tabs", $0 + "/Last Session", $0 + "/Last Tabs"]
                               }))
        }
        let firefox = subfolders(support + "Firefox/Profiles")
        all.append(Browser(name: "Firefox", bundleID: "org.mozilla.firefox",
                           others: ["org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly"],
                           cookies: firefox.map { $0 + "/cookies.sqlite" },
                           caches: [caches + "Firefox/Profiles"],
                           siteData: firefox.map { $0 + "/storage/default" },
                           sessions: firefox.flatMap { [$0 + "/sessionstore.jsonlz4", $0 + "/sessionstore-backups"] }))
        return all
    }

    /// Chromium's profile folders: Default, Profile 1 and so on, each with
    /// a Preferences file.
    static func chromiumProfiles(_ root: String) -> [String] {
        subfolders(root).filter { FileManager.default.fileExists(atPath: $0 + "/Preferences") }
    }

    private static func subfolders(_ path: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).sorted().map { path + "/" + $0 }
    }

    /// A database and the journal and write-ahead files SQLite keeps beside it.
    private static func withSidecars(_ path: String) -> [URL] {
        ["", "-journal", "-wal", "-shm"].map { URL(fileURLWithPath: path + $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// A storage folder's per-site entries. Extensions keep their own
    /// storage beside the sites' (chrome-extension_…, moz-extension+++…),
    /// and those stay. Local Storage and service workers hold sites and
    /// extensions in one database, so they are not offered at all.
    private static func siteEntries(_ path: String) -> [URL] {
        entries(path).filter {
            let name = $0.lastPathComponent
            return !name.hasPrefix("chrome-extension") && !name.hasPrefix("moz-extension") && !name.hasPrefix(".")
        }
    }

    private static func entries(_ path: String) -> [URL] {
        guard OwnFolder.check(path) else { return [] }
        return (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil)) ?? []
    }
}
