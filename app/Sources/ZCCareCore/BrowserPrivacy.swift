import Foundation

/// One kind of trace one browser keeps: its history, cookies or cache.
public struct BrowserTrace: Sendable, Equatable, Identifiable {
    public var browser: String
    public var bundleID: String
    public var kind: String
    /// What clearing removes: database files, or a cache folder's entries.
    public var paths: [URL]
    public var size: Int64

    public var id: String { bundleID + " " + kind }
}

public enum BrowserPrivacy {
    struct Browser {
        var name: String
        var bundleID: String
        var history: [String] = []
        var cookies: [String] = []
        var caches: [String] = []
    }

    public static let history = "History", cookies = "Cookies", cache = "Cache"

    /// Each browser's traces that hold data, by browser, then history,
    /// cookies, cache. Safari's need Full Disk Access to read, so without it
    /// they come back empty and are left out. Firefox keeps history and
    /// bookmarks in one database, so only its cookies and cache are offered.
    public static func find(home: String) -> [BrowserTrace] {
        browsers(home: home).flatMap { b in
            [(history, b.history), (cookies, b.cookies), (cache, b.caches)].compactMap { kind, paths -> BrowserTrace? in
                let urls = kind == cache ? paths.flatMap(entries) : paths.flatMap(withSidecars)
                let size = urls.reduce(0) { $0 + DiskUsage.allocated($1) }
                return size > 0 ? BrowserTrace(browser: b.name, bundleID: b.bundleID, kind: kind, paths: urls, size: size) : nil
            }
        }
    }

    /// Removes a trace's files; returns how many would not go.
    public static func clear(_ trace: BrowserTrace) -> Int {
        trace.paths.filter { (try? FileManager.default.removeItem(at: $0)) == nil }.count
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
                               caches: [caches + dir]))
        }
        let firefox = subfolders(support + "Firefox/Profiles")
        all.append(Browser(name: "Firefox", bundleID: "org.mozilla.firefox",
                           cookies: firefox.map { $0 + "/cookies.sqlite" },
                           caches: [caches + "Firefox/Profiles"]))
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

    private static func entries(_ path: String) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil)) ?? []
    }
}
