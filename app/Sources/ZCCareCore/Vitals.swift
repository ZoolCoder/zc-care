import Foundation

/// How the Mac itself is doing, as the Mac tab shows it: disk, memory, CPU,
/// battery, network and what is connected.
public struct Vitals: Sendable, Equatable {
    public var disk: Disk?
    public var memory: Memory?
    /// The share of CPU time busy since the last sample, 0 to 1.
    public var cpuLoad: Double?
    public var sensors: Sensors?
    public var battery: Battery?
    public var network: Throughput?
    public var devices: [Device] = []

    public init() {}
}

public struct Disk: Sendable, Equatable {
    public var name: String
    public var total: Int64
    public var available: Int64

    public init(name: String, total: Int64, available: Int64) {
        self.name = name
        self.total = total
        self.available = available
    }

    /// Under a tenth free, or under 20 GB.
    public var isLow: Bool { available < 20_000_000_000 || Double(available) < Double(total) * 0.1 }
}

public struct Memory: Sendable, Equatable {
    /// What macOS calls memory pressure, in percent: 100 less the free level.
    public var pressure: Int
    public var used: Int64
    public var total: Int64

    public init(pressure: Int, used: Int64, total: Int64) {
        self.pressure = pressure
        self.used = used
        self.total = total
    }
}

/// CPU temperature and fans, which only macmon reads without sudo.
public struct Sensors: Sendable, Equatable {
    public var cpuTemp: Double
    public var fans: [Int]

    public init(cpuTemp: Double, fans: [Int] = []) {
        self.cpuTemp = cpuTemp
        self.fans = fans
    }

    /// One sample of `macmon pipe`.
    public static func parse(macmon data: Data) -> Sensors? {
        guard let line = data.split(separator: UInt8(ascii: "\n")).first,
              let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let temp = ((obj["temp"] as? [String: Any])?["cpu_temp_avg"] as? NSNumber)?.doubleValue
        else { return nil }
        let fans = (obj["fans"] as? [[String: Any]] ?? []).compactMap { ($0["rpm"] as? NSNumber)?.intValue }
        return Sensors(cpuTemp: temp, fans: fans)
    }
}

public struct Battery: Sendable, Equatable {
    public var percent: Int
    public var charging: Bool
    public var onAC: Bool
    public var charged: Bool
    /// From System Information: Good or Service Recommended, the capacity
    /// left against new, and charge cycles.
    public var health: String?
    public var capacity: Int?
    public var cycles: Int?

    public init(percent: Int, charging: Bool = false, onAC: Bool = false, charged: Bool = false) {
        self.percent = percent
        self.charging = charging
        self.onAC = onAC
        self.charged = charged
    }

    public var state: String {
        if charged || (onAC && percent >= 100) { return "Fully charged" }
        if charging { return "Charging" }
        return onAC ? "Not charging" : "On battery"
    }

    public var needsService: Bool {
        (health.map { $0 != "Good" } ?? false) || (capacity.map { $0 < 80 } ?? false)
    }

    /// Takes health, capacity and cycles from `system_profiler -json
    /// SPPowerDataType`.
    public mutating func read(systemProfiler data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let power = root["SPPowerDataType"] as? [[String: Any]] else { return }
        for entry in power {
            guard let info = entry["sppower_battery_health_info"] as? [String: Any] else { continue }
            health = info["sppower_battery_health"] as? String
            capacity = percentValue(info["sppower_battery_health_maximum_capacity"])
            cycles = (info["sppower_battery_cycle_count"] as? NSNumber)?.intValue
        }
    }
}

/// Bytes a second through the interface that carries the default route.
public struct Throughput: Sendable, Equatable {
    public var interface: String
    public var wifi: Bool
    public var down: Double
    public var up: Double

    public init(interface: String, wifi: Bool, down: Double, up: Double) {
        self.interface = interface
        self.wifi = wifi
        self.down = down
        self.up = up
    }
}

/// A connected Bluetooth device; battery is the lowest of its parts, such
/// as each earbud.
public struct Device: Sendable, Equatable, Identifiable {
    public var name: String
    public var kind: String
    public var battery: Int?

    public var id: String { name }

    public init(name: String, kind: String, battery: Int? = nil) {
        self.name = name
        self.kind = kind
        self.battery = battery
    }

    /// The connected devices in `system_profiler -json SPBluetoothDataType`.
    public static func parse(systemProfiler data: Data) -> [Device] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let bluetooth = (root["SPBluetoothDataType"] as? [[String: Any]])?.first,
              let connected = bluetooth["device_connected"] as? [[String: Any]] else { return [] }
        let levels = ["device_batteryLevelMain", "device_batteryLevel", "device_batteryLevelLeft", "device_batteryLevelRight"]
        return connected.flatMap { entry in
            entry.map { name, value in
                let props = value as? [String: Any] ?? [:]
                return Device(name: name, kind: props["device_minorType"] as? String ?? "",
                              battery: levels.compactMap { percentValue(props[$0]) }.min())
            }
        }
        .sorted { $0.name < $1.name }
    }
}

/// `networkQuality -c`: throughput in bits a second, latency in ms.
public struct SpeedTest: Sendable, Equatable {
    public var down: Double
    public var up: Double
    public var latency: Double?

    public static func parse(_ data: Data) -> SpeedTest? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let down = (obj["dl_throughput"] as? NSNumber)?.doubleValue,
              let up = (obj["ul_throughput"] as? NSNumber)?.doubleValue else { return nil }
        return SpeedTest(down: down, up: up, latency: (obj["base_rtt"] as? NSNumber)?.doubleValue)
    }
}

/// A process from `ps -Aceo pid=,pcpu=,rss=,comm=`.
public struct Proc: Sendable, Equatable, Identifiable {
    public var pid: Int32
    public var cpu: Double
    /// Resident memory in bytes.
    public var memory: Int64
    public var name: String

    public var id: Int32 { pid }

    public static func parse(ps: String) -> [Proc] {
        ps.split(whereSeparator: \.isNewline).compactMap { line in
            // The name may hold spaces, so it takes the rest of the line.
            let f = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard f.count == 4, let pid = Int32(f[0]), let cpu = Double(f[1]), let rss = Int64(f[2]) else { return nil }
            return Proc(pid: pid, cpu: cpu, memory: rss * 1024, name: String(f[3]))
        }
    }
}

func percentValue(_ value: Any?) -> Int? {
    if let n = value as? NSNumber { return n.intValue }
    return (value as? String).flatMap { Int($0.prefix { $0.isNumber }) }
}
