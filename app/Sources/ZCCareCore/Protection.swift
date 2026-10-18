import Foundation

/// A login item, agent or background task macOS's Background Task
/// Management lists, as `sfltool dumpbtm` prints it.
public struct BackgroundItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var developer: String?
    public var kind: String
    public var enabled: Bool
    /// The app it belongs to, by its BTM identifier.
    public var parent: String?
    public var executable: String?
}

public enum BackgroundItems {
    /// The kinds that run code with the session; apps, Spotlight and Quick
    /// Look plug-ins and the developer records are left out.
    static let running = ["login item", "agent", "legacy agent", "daemon", "legacy daemon", "background tasks"]

    /// The records in the user's section: one per `#n:` block.
    public static func parse(_ text: String, uid: uid_t) -> [BackgroundItem] {
        var inUser = false
        var blocks: [[String: String]] = []
        var current: [String: String]?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Records for UID") {
                inUser = line.hasPrefix("Records for UID \(uid) ")
                if let c = current { blocks.append(c) }
                current = nil
                continue
            }
            guard inUser else { continue }
            if line.hasPrefix("#"), line.hasSuffix(":") {
                if let c = current { blocks.append(c) }
                current = [:]
            } else if current != nil, let colon = line.firstIndex(of: ":") {
                let key = String(line[..<colon])
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                current?[key] = value == "(null)" ? nil : value
            }
        }
        if inUser, let c = current { blocks.append(c) }
        return blocks.compactMap { b in
            guard let id = b["Identifier"], let type = b["Type"] else { return nil }
            let kind = type.components(separatedBy: " (").first ?? type
            guard running.contains(kind) else { return nil }
            return BackgroundItem(id: id, name: b["Name"] ?? id, developer: b["Developer Name"], kind: kind,
                                  enabled: b["Disposition"]?.hasPrefix("[enabled") ?? false,
                                  parent: b["Parent Identifier"], executable: b["Executable Path"])
        }
    }
}

/// What Gatekeeper makes of an app, from `spctl --assess -v`.
public struct Assessment: Codable, Sendable, Equatable {
    public var accepted: Bool
    /// "Notarized Developer ID", "Mac App Store", "Apple System" and so on.
    public var source: String?

    public static func parse(_ text: String) -> Assessment {
        var accepted = false, source: String?
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasSuffix(": accepted") { accepted = true }
            if line.hasPrefix("source=") { source = String(line.dropFirst("source=".count)) }
        }
        return Assessment(accepted: accepted, source: source)
    }

    /// Signed by an identified developer and checked by Apple.
    public var trusted: Bool {
        accepted && ["Notarized Developer ID", "Mac App Store", "Apple System", "Apple"].contains(source ?? "")
    }
}

/// An app's privacy permission, from the TCC databases.
public struct Permission: Codable, Sendable, Equatable, Identifiable {
    public var service: String
    public var client: String
    public var allowed: Bool

    public var id: String { service + " " + client }
}

public enum Privacy {
    /// The services worth showing, with System Settings' names.
    public static let services: [String: String] = [
        "kTCCServiceSystemPolicyAllFiles": "Full Disk Access",
        "kTCCServiceAccessibility": "Accessibility",
        "kTCCServiceScreenCapture": "Screen Recording",
        "kTCCServiceListenEvent": "Input Monitoring",
        "kTCCServicePostEvent": "Accessibility",
        "kTCCServiceCamera": "Camera",
        "kTCCServiceMicrophone": "Microphone",
        "kTCCServiceAppleEvents": "Automation",
        "kTCCServiceSystemPolicyDesktopFolder": "Desktop Folder",
        "kTCCServiceSystemPolicyDocumentsFolder": "Documents Folder",
        "kTCCServiceSystemPolicyDownloadsFolder": "Downloads Folder",
        "kTCCServiceAddressBook": "Contacts",
        "kTCCServiceCalendar": "Calendars",
        "kTCCServicePhotos": "Photos",
        "kTCCServiceLocation": "Location",
    ]

    /// The query `sqlite3 -separator '|'` runs on each TCC.db.
    public static let query = "select service, client, auth_value from access"

    /// sqlite3's rows; auth_value 2 is allowed, 0 denied. Unknown services
    /// are left out; one row per service and client.
    public static func parse(_ text: String) -> [Permission] {
        var seen = Set<String>()
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 3, let name = services[f[0]] else { return nil }
            let p = Permission(service: name, client: f[1], allowed: f[2] == "2")
            return seen.insert(p.id).inserted ? p : nil
        }
    }
}
