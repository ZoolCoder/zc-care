import Foundation

/// How to fix a doctor finding. The doctor's detail for a failed security
/// check is the fix: a sudo command, or where in System Settings to go.
public enum Fix: Equatable, Sendable {
    /// A shell command to run as root, sudo already taken out.
    case command(String)
    /// A System Settings pane to open, with what to do there.
    case settings(URL, String)
    /// Something to read; nothing to run.
    case info(String)

    /// The checks whose detail is a fixed sudo command in the doctor's own
    /// table. Other details carry text from outside, such as a listening
    /// process's name or an MCP server's, which must never run as root.
    static let rootFixable: Set<String> = [
        "security firewall", "security firewall stealth mode", "security Gatekeeper",
        "security automatic update checks", "security File Sharing off", "security Touch ID for sudo",
    ]

    /// The one line the doctor's table gives Touch ID for sudo, which pipes.
    static let touchIDLine = #"sed "s/^#auth/auth/" /etc/pam.d/sudo_local.template | sudo tee /etc/pam.d/sudo_local"#

    /// The detail, when it is exactly one `sudo <command>` line with nothing
    /// a shell would act on: prose around a command, or a second command,
    /// must not reach the password dialog.
    static func rootCommand(in detail: String) -> String? {
        let line = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if line == touchIDLine { return line.replacingOccurrences(of: "sudo ", with: "") }
        let shell = Set(#";&|`$<>()"'\"# + "\n\r")
        guard line.hasPrefix("sudo "), !line.contains(where: shell.contains) else { return nil }
        return String(line.dropFirst("sudo ".count))
    }

    public init(for check: Check) {
        let detail = check.detail ?? ""
        if Fix.rootFixable.contains(check.name), let command = Fix.rootCommand(in: detail) {
            self = .command(command)
        } else if check.isSecurity, detail.contains("System Settings") {
            self = .settings(Fix.pane(for: detail), detail)
        } else {
            self = .info(detail.isEmpty ? check.status : detail)
        }
    }

    static func pane(for detail: String) -> URL {
        let id = switch detail {
        case let d where d.contains("Time Machine"): "com.apple.Time-Machine-Settings.extension"
        case let d where d.contains("Lock Screen"): "com.apple.Lock-Screen-Settings.extension"
        case let d where d.contains("Software Update"): "com.apple.Software-Update-Settings.extension"
        case let d where d.contains("AirDrop & Handoff"): "com.apple.AirDrop-Handoff-Settings.extension"
        case let d where d.contains("Sharing"): "com.apple.Sharing-Settings.extension"
        case let d where d.contains("Users & Groups"): "com.apple.Users-Groups-Settings.extension"
        default: "com.apple.settings.PrivacySecurity.extension"
        }
        return URL(string: "x-apple.systempreferences:" + id)!
    }
}

/// An AppleScript that runs command as root behind the system password
/// dialog: no terminal, and no sudo the app would have to feed.
public func adminScript(_ command: String) -> String {
    let quoted = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    return "do shell script \"\(quoted)\" with administrator privileges"
}
