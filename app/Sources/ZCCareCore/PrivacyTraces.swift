import Foundation

/// The lists macOS keeps of what was opened lately: the Apple menu's
/// Recent Items, Go > Recent Servers, and each app's Open Recent menu.
public struct RecentList: Sendable, Equatable, Identifiable {
    public var name: String
    public var files: [URL]

    public var id: String { name }
}

public enum RecentItems {
    static let folder = "/Library/Application Support/com.apple.sharedfilelist"
    static let prefix = "com.apple.LSSharedFileList."

    /// The shared lists by their name in the folder. Favorites, the sidebar
    /// and iCloud lists live beside them and are never touched.
    static let lists: [(file: String, name: String)] = [
        ("RecentApplications", "Recent Applications"),
        ("RecentDocuments", "Recent Documents"),
        ("RecentServers", "Recent Servers"),
        ("RecentHosts", "Recent Hosts"),
    ]

    /// Each list that holds a file, then the apps' Open Recent lists as one.
    /// macOS writes .sfl2, .sfl3 or .sfl4 by version; any of them counts.
    public static func find(home: String) -> [RecentList] {
        let root = home + folder
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        var found = lists.compactMap { list -> RecentList? in
            let files = names.filter { isList($0, named: prefix + list.file) }.sorted()
                .map { URL(fileURLWithPath: root + "/" + $0) }
            return files.isEmpty ? nil : RecentList(name: list.name, files: files)
        }
        let perApp = root + "/" + prefix + "ApplicationRecentDocuments"
        let apps = ((try? FileManager.default.contentsOfDirectory(atPath: perApp)) ?? [])
            .filter { $0.range(of: #"\.sfl[0-9]$"#, options: .regularExpression) != nil }.sorted()
            .map { URL(fileURLWithPath: perApp + "/" + $0) }
        if !apps.isEmpty { found.append(RecentList(name: "Apps' Open Recent", files: apps)) }
        return found
    }

    private static func isList(_ file: String, named name: String) -> Bool {
        file.hasPrefix(name + ".sfl") && file.dropFirst(name.count + 4).allSatisfy(\.isNumber) && file.count > name.count + 4
    }
}

/// A Wi-Fi network this Mac joins on its own, from `networksetup`.
public struct KnownNetwork: Sendable, Equatable, Identifiable {
    public var ssid: String
    public var device: String

    public var id: String { device + " " + ssid }
}

public enum WiFiNetworks {
    /// The Wi-Fi device, from `networksetup -listallhardwareports`: the
    /// Device line after the Wi-Fi (or AirPort) port.
    public static func device(in text: String) -> String? {
        var wifi = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Hardware Port:") {
                let port = line.dropFirst("Hardware Port:".count).trimmingCharacters(in: .whitespaces)
                wifi = port == "Wi-Fi" || port == "AirPort"
            } else if wifi, line.hasPrefix("Device:") {
                let device = line.dropFirst("Device:".count).trimmingCharacters(in: .whitespaces)
                return device.isEmpty ? nil : device
            }
        }
        return nil
    }

    /// `networksetup -listpreferredwirelessnetworks <device>`: a header,
    /// then one tab-indented name per line. Names keep inner spaces. Nil
    /// without the header: networksetup prints its errors and still exits 0.
    public static func parse(_ text: String, device: String) -> [KnownNetwork]? {
        guard text.hasPrefix("Preferred networks on") else { return nil }
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            guard line.hasPrefix("\t") else { return nil }
            let ssid = String(line.dropFirst())
            return ssid.isEmpty ? nil : KnownNetwork(ssid: ssid, device: device)
        }
    }

    /// The command that forgets a network, as root: networksetup needs an
    /// administrator for it. The name is a plain argument, quoted.
    public static func forgetSteps(_ network: KnownNetwork) -> [[String]] {
        [["/usr/sbin/networksetup", "-removepreferredwirelessnetwork", network.device, network.ssid]]
    }
}
