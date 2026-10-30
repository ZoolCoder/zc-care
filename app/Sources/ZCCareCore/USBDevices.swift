import Foundation

/// The devices plugged into the Mac's USB ports, hubs included.
public enum USBDevices {
    /// `system_profiler -json <type>`: the Mac's own buses on top, each
    /// holding what is plugged in, nested below hubs. Nil when there is no
    /// bus: system_profiler answers an empty list for a type it does not
    /// know, and a Mac always has buses. Devices built into the Mac, which
    /// SPUSBDataType lists on Intel Macs, are left out; what they hold is not.
    public static func parse(_ json: Data, type: String) -> [String]? {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let buses = root[type] as? [[String: Any]], !buses.isEmpty else { return nil }
        var names: [String] = []
        func walk(_ items: [[String: Any]]) {
            for item in items {
                if let name = item["_name"] as? String, item["Built-in_Device"] as? String != "Yes" { names.append(name) }
                walk(item["_items"] as? [[String: Any]] ?? [])
            }
        }
        for bus in buses { walk(bus["_items"] as? [[String: Any]] ?? []) }
        return names
    }

    /// What is plugged in; nil when system_profiler fails. SPUSBHostDataType
    /// is the newer type; macOS 14 may only know SPUSBDataType.
    public static func read(runner: any Runner) async -> [String]? {
        for type in ["SPUSBHostDataType", "SPUSBDataType"] {
            guard let r = try? await runner.run("/usr/sbin/system_profiler", ["-json", type], env: [:]),
                  r.status == 0 else { return nil }
            if let names = parse(r.stdout, type: type) { return names }
        }
        return nil
    }
}
