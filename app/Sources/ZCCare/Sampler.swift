import CoreWLAN
import Darwin
import Foundation
import IOKit
import IOKit.ps
import SystemConfiguration
import ZCCareCore

/// Reads the vitals the kernel and IOKit give for free. Load and throughput
/// are rates, so each read compares with the one before.
struct Sampler {
    private var lastTicks: (busy: UInt64, total: UInt64)?
    private var lastBytes: (interface: String, down: UInt64, up: UInt64, at: Date)?
    private var lastDisk: (drives: [UInt64: DiskIO.Counter], at: Date)?
    /// Made once: a dynamic store is a connection to configd.
    private let store = SCDynamicStoreCreate(nil, "ZCCare" as CFString, nil, nil)
    /// Wi-Fi interface names, asked of CoreWLAN once.
    private let wifiNames = Set(CWWiFiClient.shared().interfaceNames() ?? [])

    mutating func cpuLoad() -> Double? {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let ok = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard ok == KERN_SUCCESS else { return nil }
        let t = load.cpu_ticks
        let busy = UInt64(t.0) + UInt64(t.1) + UInt64(t.3)
        let total = busy + UInt64(t.2)
        defer { lastTicks = (busy, total) }
        guard let last = lastTicks, total > last.total, busy >= last.busy else { return nil }
        return Double(busy - last.busy) / Double(total - last.total)
    }

    /// Used is what Activity Monitor calls Memory Used: app memory, wired
    /// and compressed.
    func memory() -> Memory? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0) == 0 else { return nil }
        var total: UInt64 = 0
        size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &total, &size, nil, 0)

        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let ok = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        var page: vm_size_t = 0
        host_page_size(mach_host_self(), &page)
        guard ok == KERN_SUCCESS else { return Memory(pressure: 100 - Int(level), used: 0, total: Int64(total)) }
        let pages = MemoryPages(internal: Int64(vm.internal_page_count), purgeable: Int64(vm.purgeable_count),
                                wired: Int64(vm.wire_count), compressed: Int64(vm.compressor_page_count),
                                external: Int64(vm.external_page_count))
        var memory = Memory(pressure: 100 - Int(level), total: Int64(total), pages: pages, pageSize: Int64(page))
        var swap = xsw_usage()
        size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 { memory.swapUsed = Int64(swap.xsu_used) }
        return memory
    }

    func disk() -> Disk? {
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let total = v.volumeTotalCapacity, let available = v.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return Disk(name: v.volumeName ?? "Macintosh HD", total: Int64(total), available: available)
    }

    /// Volumes that can be ejected, by name. Off the main thread: a share
    /// that stopped answering stalls the read.
    nonisolated static func volumes() -> [Volume] {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                      .volumeIsInternalKey, .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsLocalKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            let name = v.volumeLocalizedName.flatMap { $0.isEmpty ? nil : $0 } ?? url.lastPathComponent
            var volume = Volume(name: name, path: url.path,
                                total: Int64(v.volumeTotalCapacity ?? 0), available: Int64(v.volumeAvailableCapacity ?? 0))
            volume.isInternal = v.volumeIsInternal
            volume.isEjectable = v.volumeIsEjectable ?? false
            volume.isRemovable = v.volumeIsRemovable ?? false
            volume.isLocal = v.volumeIsLocal ?? true
            return volume.canEject ? volume : nil
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The internal battery, or nil on a Mac without one.
    func battery() -> Battery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int
            else { continue }
            var battery = Battery(percent: max > 0 ? current * 100 / max : current,
                                  charging: d[kIOPSIsChargingKey] as? Bool ?? false,
                                  onAC: d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                                  charged: d[kIOPSIsChargedKey] as? Bool ?? false)
            // -1 while macOS is still estimating.
            let minutes = d[battery.charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey] as? Int
            // 0 to full comes just before charged; 0 left is a flat battery.
            battery.minutes = minutes.flatMap { $0 > 0 || $0 == 0 && !battery.charging ? $0 : nil }
            battery.temperature = batteryTemperature()
            if battery.onAC, let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] {
                battery.adapterWatts = adapter[kIOPSPowerAdapterWattsKey] as? Int
            }
            return battery
        }
        return nil
    }

    /// Newer macOS moved the reading from the battery to its pack.
    private func batteryTemperature() -> Double? {
        for name in ["AppleSmartBattery", "AppleSmartBatteryPack"] {
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(name))
            guard service != 0 else { continue }
            defer { IOObjectRelease(service) }
            var registry: [String: Any] = [:]
            for key in ["Temperature", "BatteryData"] {
                registry[key] = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            if let celsius = Battery.temperature(registry: registry) { return celsius }
        }
        return nil
    }

    /// Bytes a second through the interface with the default route.
    mutating func network() -> Throughput? {
        guard let name = primaryInterface(), let (down, up) = Self.bytes(of: name) else { return nil }
        let now = Date.now
        defer { lastBytes = (name, down, up, now) }
        let wifi = wifiNames.contains(name)
        guard let last = lastBytes, last.interface == name, down >= last.down, up >= last.up,
              now.timeIntervalSince(last.at) > 0 else {
            return Throughput(interface: name, wifi: wifi, down: 0, up: 0)
        }
        let seconds = now.timeIntervalSince(last.at)
        return Throughput(interface: name, wifi: wifi,
                          down: Double(down - last.down) / seconds, up: Double(up - last.up) / seconds)
    }

    mutating func diskIO() -> DiskIO? {
        let at = Date.now
        guard let drives = Self.diskCounters() else { return nil }
        defer { lastDisk = (drives, at) }
        guard let last = lastDisk else { return nil }
        return DiskIO.rate(from: last.drives, to: drives, seconds: at.timeIntervalSince(last.at))
    }

    /// Each drive's block storage statistics, by registry ID. Disk images
    /// are left out: what they read, the drive holding the image reads too.
    /// Nil when a drive came or went while the list was read.
    private static func diskCounters() -> [UInt64: DiskIO.Counter]? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }
        var drives: [UInt64: DiskIO.Counter] = [:]
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS, !isDiskImage(service),
                  let stats = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                      .takeRetainedValue() as? [String: Any] else { continue }
            drives[id] = DiskIO.Counter(read: (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0,
                                        write: (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0)
        }
        return IOIteratorIsValid(iterator) != 0 ? drives : nil
    }

    private static func isDiskImage(_ service: io_object_t) -> Bool {
        let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        let characteristics = IORegistryEntrySearchCFProperty(service, kIOServicePlane, "Protocol Characteristics" as CFString,
                                                       kCFAllocatorDefault, options) as? [String: Any]
        return characteristics?["Physical Interconnect"] as? String == "Virtual Interface"
    }

    func connection() -> Connection? {
        let value = { (key: String) in SCDynamicStoreCopyValue(self.store, key as CFString) as? [String: Any] }
        // An IPv6-only network has no IPv4 global state.
        let global = value("State:/Network/Global/IPv4") ?? value("State:/Network/Global/IPv6")
        let service = global?["PrimaryService"] as? String
        var read = Connection(global: global,
                              ipv4: service.flatMap { value("State:/Network/Service/\($0)/IPv4") },
                              ipv6: service.flatMap { value("State:/Network/Service/\($0)/IPv6") },
                              dns: value("State:/Network/Global/DNS"),
                              setup: service.flatMap { value("Setup:/Network/Service/\($0)") })
        read?.proxies = Connection.proxies(SCDynamicStoreCopyProxies(store) as? [String: Any])
        if let primary = read?.interface {
            // One round trip to configd for every service's state and setup.
            let patterns = ["State:/Network/Service/[^/]+/IPv4", "Setup:/Network/Service/[^/]+"] as CFArray
            let all = SCDynamicStoreCopyMultiple(store, nil, patterns) as? [String: [String: Any]] ?? [:]
            let services = all.compactMap { key, state -> (name: String?, interface: String)? in
                guard key.hasPrefix("State:"), let interface = state["InterfaceName"] as? String else { return nil }
                let id = key.split(separator: "/")[3]
                return (all["Setup:/Network/Service/\(id)"]?["UserDefinedName"] as? String, interface)
            }
            read?.tunnels = Connection.tunnels(services, primary: primary)
        }
        return read
    }

    private func primaryInterface() -> String? {
        let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        return global?["PrimaryInterface"] as? String
    }

    /// The interface's byte counters, 64-bit: getifaddrs's wrap at 4 GB.
    private static func bytes(of name: String) -> (UInt64, UInt64)? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return nil }
        let index = if_nametoindex(name)
        return buffer.withUnsafeBytes { raw -> (UInt64, UInt64)? in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= length {
                    let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if UInt32(info.ifm_index) == index { return (info.ifm_data.ifi_ibytes, info.ifm_data.ifi_obytes) }
                }
                guard header.ifm_msglen > 0 else { break }
                offset += Int(header.ifm_msglen)
            }
            return nil
        }
    }
}
