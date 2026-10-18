import Foundation

/// A launch agent that runs on a calendar, such as the weekly upkeep.
public struct Job: Sendable, Equatable, Identifiable {
    public var label: String
    public var schedule: [DateComponents]
    public var running = false
    /// nil until the job has exited once since it was loaded.
    public var lastExit: Int?
    public var lastRun: Date?
    public var log: URL?

    public init(label: String, schedule: [DateComponents]) {
        self.label = label
        self.schedule = schedule
    }

    public var id: String { label }
    public var failed: Bool { (lastExit ?? 0) != 0 }

    public func next(after date: Date, calendar: Calendar = .current) -> Date? {
        schedule.compactMap { calendar.nextDate(after: date, matching: $0, matchingPolicy: .nextTime) }.min()
    }
}

/// Reads and drives launch agents and brew services.
public enum Launchd {
    /// Whether the config declares the agent with this label: as an agent
    /// of its own, or as a brew service, which brew loads under its prefix.
    public static func managed(_ label: String, services: [Item]) -> Bool {
        services.contains { s in
            switch s.kind {
            case "agent": return s.name == label
            case "brew": return label == "homebrew.mxcl." + s.name || label == "sh.brew." + s.name
            default: return false
            }
        }
    }

    /// StartCalendarInterval, one dict or a list of them. launchd counts
    /// weekdays from Sunday as 0 (or 7), Calendar from Sunday as 1.
    public static func schedule(plist: [String: Any]) -> [DateComponents] {
        let raw = plist["StartCalendarInterval"]
        let dicts = (raw as? [[String: Int]]) ?? (raw as? [String: Int]).map { [$0] } ?? []
        return dicts.map { d in
            var c = DateComponents()
            c.minute = d["Minute"] ?? 0
            c.hour = d["Hour"]
            c.day = d["Day"]
            c.month = d["Month"]
            c.weekday = d["Weekday"].map { $0 % 7 + 1 }
            return c
        }
    }

    /// `launchctl print`'s state and last exit code.
    public static func parsePrint(_ text: String) -> (running: Bool, lastExit: Int?) {
        var running = false, lastExit: Int?
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "state": running = running || parts[1] == "running"
            case "last exit code": lastExit = Int(parts[1].prefix { $0 == "-" || $0.isNumber })
            default: break
            }
        }
        return (running, lastExit)
    }

    public static func plistPath(_ label: String, home: String) -> String {
        home + "/Library/LaunchAgents/" + label + ".plist"
    }

    /// Where the job writes: its StandardOutPath, or the state log the
    /// config's own scripts keep.
    public static func log(label: String, plist: [String: Any], home: String) -> String {
        if let out = plist["StandardOutPath"] as? String { return out }
        let name = label.hasPrefix("local.") ? String(label.dropFirst(6)) : label
        return home + "/.local/state/zc-care/" + name + ".log"
    }

    /// The command for a service action: brew services for brew, launchctl
    /// for an agent. Only an agent can run now; it restarts by reloading.
    public static func command(_ action: ServiceAction, for item: Item, uid: UInt32, home: String,
                               brew: String) -> (String, [String])? {
        let domain = "gui/\(uid)"
        switch (item.kind, action) {
        case ("brew", .run): return nil
        case ("brew", _): return (brew, ["services", action.rawValue, item.name])
        case ("agent", .start): return ("/bin/launchctl", ["bootstrap", domain, plistPath(item.name, home: home)])
        case ("agent", .stop): return ("/bin/launchctl", ["bootout", domain, plistPath(item.name, home: home)])
        case ("agent", .restart):
            // Reload: unload, then load. kickstart -k would run a calendar job.
            let plist = plistPath(item.name, home: home)
            return ("/bin/sh", ["-c", "/bin/launchctl bootout \(domain) \"$1\"; /bin/launchctl bootstrap \(domain) \"$1\"", "sh", plist])
        case ("agent", .run): return ("/bin/launchctl", ["kickstart", domain + "/" + item.name])
        default: return nil
        }
    }
}

public enum ServiceAction: String, Sendable, CaseIterable {
    case start, stop, restart, run
}
