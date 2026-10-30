import Foundation

/// What the startup disk says of its own health: the SMART verdict and,
/// on NVMe drives, the wear and error counters `diskutil info` passes on.
public struct DiskHealth: Sendable, Equatable {
    public enum Verdict: Sendable { case good, watch, failing, unknown }

    public var model: String?
    /// "Verified", "Failing" or "Not Supported".
    public var smart: String?
    /// Share of the rated write endurance used, in percent; can pass 100.
    public var wear: Int?
    public var spare: Int?
    public var spareThreshold: Int?
    public var celsius: Int?
    public var powerOnHours: Int?
    public var powerCycles: Int?
    public var written: Int64?
    public var read: Int64?
    public var mediaErrors: Int?
    public var unsafeShutdowns: Int?
    /// NVMe's critical warning bits: spare low, too hot, reliability
    /// degraded, read-only or backup failed. Any set bit is bad.
    public var criticalWarning: Int?

    public init() {}

    /// Reads `diskutil info -plist` of the whole disk.
    public init?(diskInfo: Data) {
        guard let info = try? PropertyListSerialization.propertyList(from: diskInfo, format: nil) as? [String: Any] else { return nil }
        model = (info["MediaName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        smart = info["SMARTStatus"] as? String
        let keys = info["SMARTDeviceSpecificKeysMayVaryNotGuaranteed"] as? [String: Any] ?? [:]
        // NVMe counters are 128 bits, split in a low _0 and high _1 half.
        func counter(_ name: String) -> Int64? {
            guard let low = (keys[name + "_0"] as? NSNumber)?.int64Value else { return nil }
            let high = (keys[name + "_1"] as? NSNumber)?.int64Value ?? 0
            return high == 0 && low >= 0 ? low : nil
        }
        func value(_ name: String) -> Int? { (keys[name] as? NSNumber)?.intValue }
        wear = value("PERCENTAGE_USED")
        spare = value("AVAILABLE_SPARE")
        spareThreshold = value("AVAILABLE_SPARE_THRESHOLD")
        // NVMe gives Kelvin; zero means the drive does not report it.
        celsius = value("TEMPERATURE").flatMap { $0 > 0 ? $0 - 273 : nil }
        powerOnHours = counter("POWER_ON_HOURS").map { Int($0) }
        powerCycles = counter("POWER_CYCLES").map { Int($0) }
        // A data unit is a thousand 512-byte blocks.
        written = counter("DATA_UNITS_WRITTEN").map { $0.multipliedReportingOverflow(by: 512_000) }.flatMap { $0.overflow ? nil : $0.partialValue }
        read = counter("DATA_UNITS_READ").map { $0.multipliedReportingOverflow(by: 512_000) }.flatMap { $0.overflow ? nil : $0.partialValue }
        mediaErrors = counter("MEDIA_ERRORS").map { Int($0) }
        unsafeShutdowns = counter("UNSAFE_SHUTDOWNS").map { Int($0) }
        criticalWarning = value("CRITICAL_WARNING")
    }

    /// NVMe critical warning bit 1 is temperature: a hot drive, not a dying one.
    private var hot: Bool { (criticalWarning ?? 0) & 0x02 != 0 }
    private var critical: Bool { (criticalWarning ?? 0) & ~0x02 != 0 }

    public var verdict: Verdict {
        if smart == "Failing" || critical { return .failing }
        if let spare, let spareThreshold, spare < spareThreshold { return .failing }
        if (wear ?? 0) >= 90 || (mediaErrors ?? 0) > 0 || hot { return .watch }
        return smart == "Verified" || wear != nil ? .good : .unknown
    }

    /// What needs the owner's eye, in words; empty when all is well.
    public var concerns: [String] {
        var out: [String] = []
        if smart == "Failing" { out.append("The drive reports a SMART failure: back up now.") }
        let lowSpare = spare.flatMap { s in spareThreshold.map { s < $0 } } ?? false
        // Low spare also sets warning bit 0: one cause, said once.
        if critical, !lowSpare || (criticalWarning ?? 0) & ~0x03 != 0 { out.append("The drive raised a critical warning: back up now.") }
        if hot { out.append("The drive reported running too hot; give the Mac some air.") }
        if lowSpare { out.append("Spare blocks are below the drive's own threshold: back up now.") }
        if let wear, wear >= 90 { out.append("The drive has used \(wear)% of its rated write endurance.") }
        if let mediaErrors, mediaErrors > 0 { out.append("The drive logged \(mediaErrors) media error\(mediaErrors == 1 ? "" : "s").") }
        return out
    }
}

/// The APFS container of the startup disk: what each volume in it holds,
/// including the ones Finder never shows (System, VM, Preboot, Recovery).
public struct ContainerSpace: Sendable, Equatable {
    public struct Volume: Sendable, Equatable, Identifiable {
        public var name: String
        public var role: String?
        public var used: Int64
        public var uuid: String?
        public var id: String { uuid ?? name + (role ?? "") }
    }

    public var size: Int64
    public var free: Int64
    public var volumes: [Volume]

    /// Reads `diskutil apfs list -plist` and keeps the named container.
    public init?(apfsList: Data, container: String) {
        guard let root = try? PropertyListSerialization.propertyList(from: apfsList, format: nil) as? [String: Any],
              let containers = root["Containers"] as? [[String: Any]],
              let match = containers.first(where: { $0["ContainerReference"] as? String == container }),
              let size = (match["CapacityCeiling"] as? NSNumber)?.int64Value,
              let free = (match["CapacityFree"] as? NSNumber)?.int64Value else { return nil }
        self.size = size
        self.free = free
        volumes = (match["Volumes"] as? [[String: Any]] ?? []).compactMap { v in
            guard let name = v["Name"] as? String, let used = (v["CapacityInUse"] as? NSNumber)?.int64Value else { return nil }
            return Volume(name: name, role: (v["Roles"] as? [String])?.first, used: used, uuid: v["APFSVolumeUUID"] as? String)
        }
        .sorted { $0.used > $1.used }
    }

    /// Space in use that no volume accounts for: snapshots and metadata.
    public var unaccounted: Int64 { max(0, size - free - volumes.reduce(0) { $0 + $1.used }) }

    /// Plain words for a volume role.
    public static func describe(_ role: String?) -> String {
        switch role {
        case "Data": "Your files, apps and settings"
        case "System": "macOS itself, sealed and read-only"
        case "VM": "Swap and the sleep image"
        case "Preboot": "What the Mac needs to start up"
        case "Recovery": "macOS Recovery"
        case "Update": "Staged software updates"
        default: "Volume"
        }
    }
}

public enum DiskInfo {
    /// The whole disk behind the startup volume's APFS container, from
    /// `diskutil info -plist /`: "disk0" for physical store "disk0s2".
    public static func startup(_ info: Data) -> (container: String, physical: String)? {
        guard let dict = try? PropertyListSerialization.propertyList(from: info, format: nil) as? [String: Any],
              let container = dict["APFSContainerReference"] as? String,
              let store = (dict["APFSPhysicalStores"] as? [[String: Any]])?.first?["APFSPhysicalStore"] as? String else { return nil }
        return (container, wholeDisk(store))
    }

    static func wholeDisk(_ device: String) -> String {
        guard let r = device.range(of: #"^disk\d+"#, options: .regularExpression) else { return device }
        return String(device[r])
    }

    /// Names in `tmutil listlocalsnapshots /`.
    public static func snapshots(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("com.apple.TimeMachine.") }
    }
}
