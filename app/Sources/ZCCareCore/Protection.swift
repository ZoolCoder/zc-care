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
    /// The service as tccutil names it, for Reset; nil when the client is a
    /// path, which tccutil cannot reset.
    public var resetName: String?

    /// By tccutil's name where there is one: Accessibility and PostEvent
    /// both show as Accessibility but are two answers, reset one at a time.
    public var id: String { (resetName ?? service) + " " + client }
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
        "kTCCServiceBluetoothAlways": "Bluetooth",
        "kTCCServiceReminders": "Reminders",
        "kTCCServiceSpeechRecognition": "Speech Recognition",
        "kTCCServiceMediaLibrary": "Media & Apple Music",
        "kTCCServiceSystemPolicyAppBundles": "App Management",
        "kTCCServiceDeveloperTool": "Developer Tools",
        "kTCCServiceSystemPolicyNetworkVolumes": "Network Volumes",
        "kTCCServiceSystemPolicyRemovableVolumes": "Removable Volumes",
    ]

    /// The query `sqlite3 -separator '|'` runs on each TCC.db.
    public static let query = "select service, client, client_type, auth_value from access"

    /// Whether sqlite3's error is macOS keeping the database from an app
    /// without Full Disk Access, and not another failure.
    public static func lacksFullDiskAccess(stderr: String) -> Bool {
        let text = stderr.lowercased()
        return ["authorization denied", "not authorized", "operation not permitted", "unable to open database"]
            .contains(where: text.contains)
    }

    /// sqlite3's rows; auth_value 2 is allowed, 0 denied, client_type 0 a
    /// bundle id. Unknown services are left out; one row per service and client.
    public static func parse(_ text: String) -> [Permission] {
        var seen = Set<String>()
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 4, let name = services[f[0]] else { return nil }
            // Location answers live with locationd, which tccutil does not reset.
            let bundle = f[2] == "0" && isBundleID(f[1]) && f[0] != "kTCCServiceLocation"
            let p = Permission(service: name, client: f[1], allowed: f[3] == "2",
                               resetName: bundle ? String(f[0].dropFirst("kTCCService".count)) : nil)
            return seen.insert(p.id).inserted ? p : nil
        }
    }

    /// `tccutil reset <service> <bundle id>`: macOS forgets the answer and
    /// asks the app again next time. Needs no administrator.
    public static func resetArguments(_ p: Permission) -> [String]? {
        p.resetName.map { ["reset", $0, p.client] }
    }

    private static func isBundleID(_ s: String) -> Bool {
        !s.isEmpty && !s.hasPrefix("-") && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-._".contains($0)) }
    }
}
