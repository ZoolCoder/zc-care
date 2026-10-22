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
        "security automatic update checks", "security File Sharing off", "security Guest account off",
        "security Touch ID for sudo", "security automatic login off",
    ]

    /// The line the doctor's table gives Touch ID for sudo: one `sh -c`
    /// body that uncomments pam_tid.so or appends it. Tests use it.
    static let touchIDLine = #"sudo /bin/sh -c 'f=/etc/pam.d/sudo_local; if grep -Eq "^#*[[:space:]]*auth[[:space:]]+sufficient[[:space:]]+pam_tid\.so" $f 2>/dev/null; then sed -i "" "s/^#[[:space:]]*\(auth[[:space:]][[:space:]]*sufficient[[:space:]][[:space:]]*pam_tid\.so\)/\1/" $f; else [ -s $f ] && [ -n "$(tail -c1 $f)" ] && echo >> $f; printf "auth       sufficient     pam_tid.so\n" >> $f; fi'"#

    /// The `sh -c` lines the doctor's table holds, in full: the only shell
    /// bodies that may run as root, since a body is otherwise free text.
    static let rootShellLines: Set<String> = [
        touchIDLine,
        "sudo /bin/sh -c 'launchctl disable system/com.apple.smbd; launchctl bootout system/com.apple.smbd 2>/dev/null; true'",
        "sudo /bin/sh -c 'rm -f /etc/kcpassword; defaults delete /Library/Preferences/com.apple.loginwindow autoLoginUser'",
    ]

    /// The programs a root fix may start, by full path and by name.
    static let rootPrograms: Set<String> = [
        "/usr/libexec/ApplicationFirewall/socketfilterfw", "socketfilterfw",
        "/usr/sbin/spctl", "spctl", "/usr/sbin/softwareupdate", "softwareupdate",
        "/usr/bin/defaults", "defaults", "/bin/launchctl", "launchctl",
        "/usr/sbin/sysadminctl", "sysadminctl", "/bin/sh", "sh",
    ]

    /// What a plain argument may hold: no glob, brace, tilde, quote, `$` or
    /// operator for the shell to act on.
    private static let plainArgument = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -_./:=,@+")

    /// The detail, when it is exactly one `sudo <program> ...` line of a
    /// listed program with nothing a shell would act on: prose around a
    /// command, or a second command, must not reach the password dialog.
    /// `sh -c '<body>'` passes only as one of the doctor's own lines, with
    /// a single-quoted body the outer shell leaves alone.
    static func rootCommand(in detail: String) -> String? {
        let line = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("sudo "), !line.contains(where: \.isNewline) else { return nil }
        let command = String(line.dropFirst("sudo ".count))
        guard let program = command.split(separator: " ").first.map(String.init), rootPrograms.contains(program) else { return nil }
        if program == "sh" || program == "/bin/sh" {
            return isQuotedShell(command, program: program) && rootShellLines.contains(line) ? command : nil
        }
        return command.allSatisfy(plainArgument.contains) ? command : nil
    }

    private static func isQuotedShell(_ command: String, program: String) -> Bool {
        let opening = program + " -c '"
        guard command.hasPrefix(opening), command.hasSuffix("'"), command.count > opening.count else { return false }
        return !command.dropFirst(opening.count).dropLast().contains("'")
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
