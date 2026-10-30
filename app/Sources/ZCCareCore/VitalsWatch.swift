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
    }
}

/// Turns vitals samples into alerts. Memory and heat must hold for a few
/// checks in a row, so a spike stays quiet, and each alert keeps still for
/// a while once posted.
public struct VitalsWatch: Sendable {
    public var limits: VitalLimits
    private var streaks: [String: Int] = [:]
    private var posted: [String: Date] = [:]

    /// Checks in a row before memory or heat counts.
    static let sustained = 3
    static let quiet: [String: TimeInterval] = [
        "disk": 6 * 3600, "memory": 3600, "heat": 3600, "battery": 7 * 86400, "trash": 86400,
    ]
    /// Each device keeps still this long once it has warned.
    static let deviceQuiet: TimeInterval = 6 * 3600

    public init(limits: VitalLimits = VitalLimits()) {
        self.limits = limits
    }

    public mutating func alerts(for v: Vitals, now: Date = .now) -> [Alert] {
        var alerts: [Alert] = []
        func check(_ kind: String, _ over: Bool, needs streak: Int = 1, _ alert: () -> Alert) {
            streaks[kind] = over ? streaks[kind, default: 0] + 1 : 0
            guard over, streaks[kind, default: 0] >= streak else { return }
            let quiet = kind.hasPrefix("device ") ? Self.deviceQuiet : Self.quiet[kind, default: 3600]
            if let last = posted[kind], now.timeIntervalSince(last) < quiet { return }
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
        if !v.devices.isEmpty { forgetDevices(except: Set(levels.keys), now: now) }
        for (name, level) in levels.sorted(by: { $0.key < $1.key }) {
            check("device " + name, level <= limits.deviceBattery) {
                // Quoted: a device chooses its own name.
                let shown = LeftoverWatch.shown(name)
                return Alert(id: "vitals device " + shown, title: "“\(shown)” is low on battery",
                             body: "\(level)% left. Charge it soon.")
            }
        }
        return alerts
    }

    /// Drops what the watch keeps for devices no longer connected, once
    /// their quiet time is over, so names seen once do not pile up.
    private mutating func forgetDevices(except connected: Set<String>, now: Date) {
        let gone = { (key: String) in key.hasPrefix("device ") && !connected.contains(String(key.dropFirst("device ".count))) }
        streaks = streaks.filter { !gone($0.key) }
        posted = posted.filter { !gone($0.key) || now.timeIntervalSince($0.value) < Self.deviceQuiet }
    }

    private static func gb(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
