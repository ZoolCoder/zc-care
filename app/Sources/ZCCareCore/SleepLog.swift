import Foundation

/// How the Mac slept over the last day, from the power management log.
public struct SleepLog: Sendable, Equatable {
    public struct Event: Sendable, Equatable {
        public var at: Date
        public var reason: String
    }

    public var lastSleep: Event?
    public var lastWake: Event?
    /// Brief wakes with the screen off, for upkeep such as Power Nap.
    public var darkWakes = 0
    /// Battery percentage points lost while asleep on battery.
    public var drained = 0

    public init(lastSleep: Event? = nil, lastWake: Event? = nil, darkWakes: Int = 0, drained: Int = 0) {
        self.lastSleep = lastSleep
        self.lastWake = lastWake
        self.darkWakes = darkWakes
        self.drained = drained
    }

    private enum Kind: String { case sleep = "Sleep", wake = "Wake", darkWake = "DarkWake" }

    /// `pmset -g log`, oldest first: one `date time zone Domain  message`
    /// line an event. The last sleep and wake are the ones the user saw, not
    /// the upkeep sleeps after a dark wake. Drain sums the drop between each
    /// two events of a sleep, from going to sleep to the full wake, when
    /// both are on battery and in the day before `now`.
    public static func parse(_ log: String, now: Date) -> SleepLog {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        let dayAgo = now.addingTimeInterval(-86_400)
        var result = SleepLog()
        var asleep = false
        var last: (at: Date, charge: Int?)?
        // Tens of thousands of lines, few of them events: the domain starts
        // after the 26 bytes of the stamp, so skip a line on its first letter.
        for bytes in log.utf8.split(separator: UInt8(ascii: "\n")) where bytes.count > 26 {
            guard [UInt8(ascii: "S"), UInt8(ascii: "W"), UInt8(ascii: "D")]
                .contains(bytes[bytes.index(bytes.startIndex, offsetBy: 26)]) else { continue }
            let line = String(decoding: bytes, as: UTF8.self)
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            // The domain column, "Wake Requests" among them, ends at a tab.
            let domain = fields.count == 4 ? fields[3].prefix { $0 != "\t" }.trimmingCharacters(in: .whitespaces) : ""
            guard let kind = Kind(rawValue: domain),
                  let at = formatter.date(from: fields[0...2].joined(separator: " ")) else { continue }
            // The Sleep domain also logs the dark wake of a closed lid on a display.
            if kind == .sleep, !line.contains("Entering Sleep state") { continue }
            let charge = onBattery(line) ? self.charge(line) : nil
            if asleep, let last, last.at >= dayAgo, let before = last.charge, let after = charge, before > after {
                result.drained += before - after
            }
            last = (at, charge)
            switch kind {
            case .sleep:
                asleep = true
                if let reason = sleepReason(line) { result.lastSleep = Event(at: at, reason: reason) }
            case .darkWake:
                if at >= dayAgo { result.darkWakes += 1 }
            case .wake:
                asleep = false
                result.lastWake = Event(at: at, reason: wakeReason(line))
            }
        }
        return result
    }

    /// Nil for the upkeep sleeps that follow a dark wake.
    static func sleepReason(_ message: String) -> String? {
        guard let start = message.range(of: "due to '"),
              let end = message[start.upperBound...].firstIndex(of: "'") else { return "Asleep" }
        let reason = message[start.upperBound..<end]
        if reason.hasPrefix("Maintenance") || reason.hasPrefix("Sleep Service") { return nil }
        if reason.hasPrefix("Clamshell") { return "Lid closed" }
        if reason.hasPrefix("Idle") { return "Idle" }
        if reason.hasPrefix("Software") { return "From the menu or an app" }
        if reason.hasPrefix("Power Button") { return "Power button" }
        if reason.hasPrefix("Low Power") { return "Battery low" }
        return String(reason)
    }

    static func wakeReason(_ message: String) -> String {
        let cause = message.range(of: "due to ").map { message[$0.upperBound...] } ?? ""
        if cause.contains(" lid ") || cause.contains("Lid") { return "Lid opened" }
        if cause.localizedCaseInsensitiveContains("pwrbtn") || cause.contains("PowerButton") { return "Power button" }
        if cause.contains("HID") || cause.contains("UserActivity") { return "Keyboard or mouse" }
        return "Awake"
    }

    private static func onBattery(_ message: String) -> Bool {
        message.range(of: "Using BATT", options: .caseInsensitive) != nil
    }

    private static func charge(_ message: String) -> Int? {
        guard let start = message.range(of: "Charge:") else { return nil }
        return Int(message[start.upperBound...].prefix { $0.isNumber })
    }

    /// The last day's sleep; nil when pmset fails. The log runs to tens of
    /// thousands of lines and takes seconds of CPU: read it on demand.
    public static func read(runner: any Runner, now: Date = .now) async -> SleepLog? {
        guard let r = try? await runner.run("/usr/bin/pmset", ["-g", "log"], env: [:]), r.status == 0 else { return nil }
        return parse(r.output, now: now)
    }
}
