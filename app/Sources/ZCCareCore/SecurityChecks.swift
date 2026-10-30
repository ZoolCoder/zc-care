import Foundation

/// A macOS protection that should be on, and whether it is: nil while
/// unread or when its tool gave no answer that could be read.
public struct SecurityCheck: Sendable, Equatable, Identifiable {
    public var name: String
    public var on: Bool?
    /// What it guards against, or how to turn it on.
    public var detail: String
    /// The System Settings pane that turns it on, if one does.
    public var pane: String?

    public var id: String { name }
}

/// Reads each tool's output; none of them needs an administrator.
public enum SecurityChecks {
    public static let fileVault = (path: "/usr/bin/fdesetup", args: ["status"])
    public static let firewall = (path: "/usr/libexec/ApplicationFirewall/socketfilterfw", args: ["--getglobalstate"])
    public static let integrity = (path: "/usr/bin/csrutil", args: ["status"])
    public static let updates = "/Library/Preferences/com.apple.SoftwareUpdate.plist"

    /// "FileVault is On." or "FileVault is Off."; encryption under way
    /// counts as on.
    public static func fileVault(_ out: String) -> Bool? {
        if out.contains("FileVault is On") || out.contains("Encryption in progress") { return true }
        if out.contains("FileVault is Off") { return false }
        return nil
    }

    /// "Firewall is enabled. (State = 1)": 1 is on, 2 blocks all incoming
    /// connections, 0 is off.
    public static func firewall(_ out: String) -> Bool? {
        if let r = out.range(of: #"State = (\d)"#, options: .regularExpression) {
            return out[r].last != "0"
        }
        if out.contains("Firewall is enabled") { return true }
        if out.contains("Firewall is disabled") { return false }
        return nil
    }

    /// "System Integrity Protection status: enabled." A custom configuration
    /// leaves parts of it off, so only plain enabled counts.
    public static func integrity(_ out: String) -> Bool? {
        guard let line = out.split(whereSeparator: \.isNewline).first(where: { $0.contains("System Integrity Protection status:") })
        else { return nil }
        if line.hasSuffix("status: enabled.") { return true }
        return line.contains("enabled") || line.contains("disabled") || line.contains("unknown") ? false : nil
    }

    /// Security responses and system data files install on their own unless
    /// turned off; a key that is missing keeps macOS's default, which is on.
    public static func securityUpdates(_ prefs: [String: Any]?) -> Bool {
        func on(_ key: String) -> Bool { (prefs?[key] as? Bool) ?? (prefs?[key] as? Int).map { $0 != 0 } ?? true }
        return on("CriticalUpdateInstall") && on("ConfigDataInstall")
    }

    /// Each check, from the tools' outputs; Gatekeeper's is read elsewhere.
    public static func checks(fileVault fv: String?, firewall fw: String?, integrity sip: String?,
                              updates prefs: [String: Any]?) -> [SecurityCheck] {
        [
            SecurityCheck(name: "FileVault", on: fv.flatMap(fileVault),
                          detail: "Encrypts the disk, so a lost or stolen Mac gives nothing away.",
                          pane: "com.apple.settings.PrivacySecurity.extension?FileVault"),
            SecurityCheck(name: "Firewall", on: fw.flatMap(firewall),
                          detail: "Turns away incoming connections to apps you did not allow.",
                          pane: "com.apple.Network-Settings.extension?Firewall"),
            SecurityCheck(name: "System Integrity Protection", on: sip.flatMap(integrity),
                          detail: "Keeps even administrators from changing macOS itself. Turned back on from Recovery with csrutil enable.",
                          pane: nil),
            SecurityCheck(name: "Security Responses", on: securityUpdates(prefs),
                          detail: "Installs security fixes and system data files on its own.",
                          pane: "com.apple.Software-Update-Settings.extension"),
        ]
    }
}
