import Foundation

/// Where the vitals alerts fire, as Settings sets them.
public struct VitalLimits: Codable, Sendable, Equatable {
    public var diskFreeGB = 20
    public var memoryPressure = 80
    public var cpuTemp = 95
    public var batteryCapacity = 80
    public var trashGB = 5
    /// A Bluetooth device's battery, in percent.
    public var deviceBattery = 20
    /// One app's CPU, in percent of a core, and its memory in GB.
    public var appCPU = 100
    public var appMemoryGB = 8

    public init() {}

    // Settings saved by an older version lack the newer limits: those take
    // their default, and the rest are kept.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        diskFreeGB = try c.decodeIfPresent(Int.self, forKey: .diskFreeGB) ?? diskFreeGB
        memoryPressure = try c.decodeIfPresent(Int.self, forKey: .memoryPressure) ?? memoryPressure
        cpuTemp = try c.decodeIfPresent(Int.self, forKey: .cpuTemp) ?? cpuTemp
        batteryCapacity = try c.decodeIfPresent(Int.self, forKey: .batteryCapacity) ?? batteryCapacity
        trashGB = try c.decodeIfPresent(Int.self, forKey: .trashGB) ?? trashGB
        deviceBattery = try c.decodeIfPresent(Int.self, forKey: .deviceBattery) ?? deviceBattery
        appCPU = try c.decodeIfPresent(Int.self, forKey: .appCPU) ?? appCPU
        appMemoryGB = try c.decodeIfPresent(Int.self, forKey: .appMemoryGB) ?? appMemoryGB
    }
}

/// Turns vitals samples into alerts. Memory and heat must hold for a few
/// checks in a row, so a spike stays quiet, and each alert keeps still for
/// a while once posted.
public struct VitalsWatch: Sendable {
    public var limits: VitalLimits
    private var streaks: [String: Int] = [:]
    private var posted: [String: Date] = [:]
    private var lastCheck: Date?

    /// Checks in a row before memory or heat counts.
    static let sustained = 3
    static let quiet: [String: TimeInterval] = [
        "disk": 6 * 3600, "memory": 3600, "heat": 3600, "battery": 7 * 86400, "trash": 86400,
    ]
    /// Each device keeps still this long once it has warned.
    static let deviceQuiet: TimeInterval = 6 * 3600
    /// Checks in a row before one app counts as hogging: ten minutes, so a
    /// build or an export stays quiet.
    static let hogging = 10
    /// Each app keeps still this long once it has warned.
    static let appQuiet: TimeInterval = 3 * 3600

    private static func quiet(_ kind: String) -> TimeInterval {
        if kind.hasPrefix("device ") { return deviceQuiet }
        if kind.hasPrefix("cpu ") || kind.hasPrefix("ram ") { return appQuiet }
        return quiet[kind, default: 3600]
    }

    public init(limits: VitalLimits = VitalLimits()) {
        self.limits = limits
    }

    public mutating func alerts(for v: Vitals, now: Date = .now) -> [Alert] {
        var alerts: [Alert] = []
        // Streaks count checks a minute apart; after sleep, or alerts turned
        // off and on, the count starts again.
        if let lastCheck, now.timeIntervalSince(lastCheck) > 180 { streaks = [:] }
        lastCheck = now
        func check(_ kind: String, _ over: Bool, needs streak: Int = 1, _ alert: () -> Alert) {
            // Nil, not 0, when under: every running app passes through here.
            streaks[kind] = over ? streaks[kind, default: 0] + 1 : nil
            guard over, streaks[kind, default: 0] >= streak else { return }
            if let last = posted[kind], now.timeIntervalSince(last) < Self.quiet(kind) { return }
            posted[kind] = now
            alerts.append(alert())
        }
        if let disk = v.disk {
            check("disk", disk.available < Int64(limits.diskFreeGB) * 1_000_000_000) {
                Alert(id: "vitals disk", title: "\(disk.name) is almost full",
                      body: "\(Self.gb(disk.available)) left. Cleanup can free space.")
            }
        }
        if let memory = v.memory {
            check("memory", memory.pressure >= limits.memoryPressure, needs: Self.sustained) {
                Alert(id: "vitals memory", title: "Memory pressure is high",
                      body: "\(memory.pressure)% for a few minutes. Quitting a heavy app frees memory.")
            }
        }
        if let sensors = v.sensors {
            check("heat", sensors.cpuTemp >= Double(limits.cpuTemp), needs: Self.sustained) {
                Alert(id: "vitals heat", title: "The CPU is running hot",
                      body: "\(Int(sensors.cpuTemp.rounded())) °C for a few minutes. Check what is busy in the panel.")
            }
        }
        if let battery = v.battery, let capacity = battery.capacity {
            check("battery", capacity < limits.batteryCapacity || battery.health.map { $0 != "Good" } ?? false) {
                Alert(id: "vitals battery", title: "The battery is wearing out",
                      body: "\(capacity)% of its new capacity" + (battery.health.map { ", \($0)." } ?? "."))
            }
        }
        if let trash = v.trash {
            check("trash", trash >= Int64(limits.trashGB) * 1_000_000_000) {
                Alert(id: "vitals trash", title: "The Trash holds \(Self.gb(trash))",
                      body: "Files in the Trash still take space until it is emptied. Cleanup can empty it.")
            }
        }
        // Devices that share a name count as one, at the lowest level.
        let levels = v.devices.reduce(into: [String: Int]()) { levels, device in
            guard let level = device.battery else { return }
            levels[device.name] = min(level, levels[device.name] ?? level)
        }
        if !v.devices.isEmpty { forget("device ", except: Set(levels.keys), now: now) }
        for (name, level) in levels.sorted(by: { $0.key < $1.key }) {
            check("device " + name, level <= limits.deviceBattery) {
                // Quoted: a device chooses its own name.
                let shown = LeftoverWatch.shown(name)
                return Alert(id: "vitals device " + shown, title: "“\(shown)” is low on battery",
                             body: "\(level)% left. Charge it soon.")
            }
        }
        // An app that holds a core, or a lot of memory, for ten minutes; by
        // name, so its helpers count at the heaviest of them.
        let heaviest = v.processes.reduce(into: [String: (cpu: Double, memory: Int64)]()) { apps, proc in
            let seen = apps[proc.name] ?? (0, 0)
            apps[proc.name] = (max(seen.cpu, proc.cpu), max(seen.memory, proc.memory))
        }
        if !v.processes.isEmpty {
            forget("cpu ", except: Set(heaviest.keys), now: now)
            forget("ram ", except: Set(heaviest.keys), now: now)
        }
        for (name, use) in heaviest.sorted(by: { $0.key < $1.key }) {
            let shown = LeftoverWatch.shown(name)
            check("cpu " + name, use.cpu >= Double(limits.appCPU), needs: Self.hogging) {
                Alert(id: "vitals app cpu " + shown, title: "“\(shown)” is keeping the CPU busy",
                      body: "\(Int(use.cpu.rounded()))% of a core for ten minutes. Quit it from the panel if it is stuck.")
            }
            check("ram " + name, use.memory >= Int64(limits.appMemoryGB) * 1_000_000_000, needs: Self.hogging) {
                Alert(id: "vitals app memory " + shown, title: "“\(shown)” is using \(Self.gb(use.memory)) of memory",
                      body: "For ten minutes. Quitting and opening it again gives the memory back.")
            }
        }
        return alerts
    }

    /// Drops what the watch keeps for devices or apps no longer there, once
    /// their quiet time is over, so names seen once do not pile up.
    private mutating func forget(_ prefix: String, except present: Set<String>, now: Date) {
        let gone = { (key: String) in key.hasPrefix(prefix) && !present.contains(String(key.dropFirst(prefix.count))) }
        streaks = streaks.filter { !gone($0.key) }
        posted = posted.filter { !gone($0.key) || now.timeIntervalSince($0.value) < Self.quiet($0.key) }
    }

    private static func gb(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
