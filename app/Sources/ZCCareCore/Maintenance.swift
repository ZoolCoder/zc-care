import Foundation

/// A one-off job that tidies macOS: CleanMyMac's maintenance scripts.
public struct MaintenanceTask: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var detail: String
    public var symbol: String
    /// Run in order; the first that fails stops the rest.
    public var steps: [[String]]
    /// Needs an administrator: runs through osascript, which asks for the password.
    public var admin = false
    /// How often Smart Care suggests it; nil for a task run only when
    /// something is wrong.
    public var every: TimeInterval?
}

public enum Maintenance {
    static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    /// Every task this Mac can run: Homebrew, Docker and Xcode ones only
    /// when the tool is there.
    public static func tasks(brew: String?, docker: String?, xcode: Bool) -> [MaintenanceTask] {
        var tasks = [
            MaintenanceTask(id: "ram", title: "Free Up RAM", detail: "Purges the disk cache from memory.",
                            symbol: "memorychip.fill", steps: [["/usr/sbin/purge"]], admin: true),
            MaintenanceTask(id: "dns", title: "Flush DNS Cache", detail: "Fixes sites that moved but still resolve to the old address.",
                            symbol: "network", steps: [["/usr/bin/dscacheutil", "-flushcache"], ["/usr/bin/killall", "-HUP", "mDNSResponder"]],
                            admin: true),
            MaintenanceTask(id: "snapshots", title: "Thin Time Machine Snapshots",
                            detail: "Deletes local snapshots of the startup disk; backups on the backup disk stay.",
                            symbol: "clock.arrow.circlepath", steps: [["/usr/bin/tmutil", "thinlocalsnapshots", "/", "9999999999999", "4"]], admin: true),
            MaintenanceTask(id: "spotlight", title: "Reindex Spotlight",
                            detail: "Rebuilds the search index; search is slow for a while after.",
                            symbol: "magnifyingglass", steps: [["/usr/bin/mdutil", "-E", "/"]], admin: true),
            MaintenanceTask(id: "launchservices", title: "Repair Open With Menus",
                            detail: "Drops apps that are gone and registers those in /Applications again.",
                            symbol: "contextualmenu.and.cursorarrow",
                            steps: [[lsregister, "-gc"], [lsregister, "-r", "/Applications"]], every: 30 * day),
        ]
        if let brew {
            tasks.append(MaintenanceTask(id: "brew", title: "Clean Up Homebrew", detail: "Removes old versions and every cached download.",
                                         symbol: "mug.fill", steps: [[brew, "cleanup", "--prune=all"]], every: 14 * day))
        }
        if xcode {
            tasks.append(MaintenanceTask(id: "simulators", title: "Delete Unavailable Simulators",
                                         detail: "Simulators whose runtime Xcode no longer has.",
                                         symbol: "iphone", steps: [["/usr/bin/xcrun", "simctl", "delete", "unavailable"]],
                                         every: 30 * day))
        }
        // Stopped containers stay: one may hold a dev database's only copy.
        if let docker {
            tasks.append(MaintenanceTask(id: "docker", title: "Prune Docker",
                                         detail: "Dangling images, unused networks and build cache; containers stay.",
                                         symbol: "shippingbox.fill",
                                         steps: [[docker, "image", "prune", "-f"], [docker, "network", "prune", "-f"],
                                                 [docker, "builder", "prune", "-f"]],
                                         every: 14 * day))
        }
        return tasks
    }

    static let day: TimeInterval = 86400

    /// Smart Care's tune-up: the routine tasks the log has not seen run
    /// for their interval. Tasks that need a password are never routine.
    public static func due(_ tasks: [MaintenanceTask], log: ActivityLog, now: Date = .now) -> [MaintenanceTask] {
        tasks.filter { task in
            guard let every = task.every, !task.admin else { return false }
            let last = log.entries.last { $0.kind == .maintenance && $0.title == task.title }?.date
            return last.map { now.timeIntervalSince($0) >= every } ?? true
        }
    }

    /// The AppleScript that runs the steps as root after asking for the
    /// password: each argument single-quoted for the shell, then the whole
    /// command escaped for an AppleScript string.
    public static func adminScript(_ steps: [[String]]) -> String {
        let command = steps.map { $0.map(shellQuote).joined(separator: " ") }.joined(separator: " && ")
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Installer files left in Downloads and on the Desktop once the app is in.
public enum DiskImages {
    static let kinds: Set<String> = ["dmg", "pkg", "mpkg", "iso", "xip"]

    public static func files(in folders: [URL]) -> [LargeFile] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .addedToDirectoryDateKey]
        return folders.flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                           options: [.skipsHiddenFiles])) ?? [])
                .filter { kinds.contains($0.pathExtension.lowercased()) }
                .map { url in
                    let v = try? url.resourceValues(forKeys: Set(keys))
                    return LargeFile(url: url, size: DiskUsage.allocated(url), modified: v?.addedToDirectoryDate ?? v?.contentModificationDate)
                }
        }
        .sorted { $0.size > $1.size }
    }
}

/// What an app left in the Library after it went without its uninstaller.
public struct Orphan: Codable, Sendable, Equatable, Identifiable {
    public var bundleID: String
    public var paths: [String]
    public var size: Int64

    public var id: String { bundleID }
}

extension Leftovers {
    /// The Library folders apps name after their bundle id.
    static let folders = ["Application Support", "Caches", "Containers", "HTTPStorages", "WebKit", "Logs",
                          "Preferences", "Saved Application State"]

    /// Entries named for a bundle id that no installed app, nor any app it
    /// could be a helper of, answers to. Apple's own are left out, and so is
    /// what a vendor with an app still installed shares between its apps,
    /// such as com.microsoft.shared: `vendors` holds those apps' vendors.
    public static func orphans(home: String, vendors: Set<String> = [], isInstalled: (String) -> Bool) -> [Orphan] {
        var byID: [String: [String]] = [:]
        for folder in folders {
            let path = home + "/Library/" + folder
            for name in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] {
                guard let id = bundleID(name), !isApple(id), !vendors.contains(vendor(id)), !owned(id, isInstalled) else { continue }
                byID[id, default: []].append(path + "/" + name)
            }
        }
        return byID.map { id, paths in
            Orphan(bundleID: id, paths: paths.sorted(),
                   size: paths.reduce(0) { $0 + DiskUsage.allocated(URL(fileURLWithPath: $1)) })
        }
        .sorted { $0.size > $1.size }
    }

    /// Apple's ids, also inside group ids such as
    /// systemgroup.com.apple.icloud.
    static func isApple(_ id: String) -> Bool {
        let id = id.lowercased()
        return id.hasPrefix("com.apple.") || id.contains(".com.apple.")
    }

    /// The first two parts of a bundle id, com.microsoft of com.microsoft.teams2.
    public static func vendor(_ id: String) -> String {
        id.lowercased().split(separator: ".").prefix(2).joined(separator: ".")
    }

    /// The bundle id an entry is named for: reverse DNS, three parts or more.
    static func bundleID(_ name: String) -> String? {
        var id = name
        for suffix in [".plist", ".savedState", ".binarycookies"] where id.hasSuffix(suffix) {
            id = String(id.dropLast(suffix.count))
        }
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } }),
              parts[0].allSatisfy(\.isLowercase) else { return nil }
        return id
    }

    /// An app owns the id, or an id it extends: com.foo.app.helper belongs
    /// to com.foo.app.
    static func owned(_ id: String, _ isInstalled: (String) -> Bool) -> Bool {
        var parts = id.split(separator: ".")
        while parts.count >= 2 {
            if isInstalled(parts.joined(separator: ".")) { return true }
            parts.removeLast()
        }
        return false
    }
}
