import Foundation

/// An app of the user's waiting for TCP connections on a port, and whether
/// other machines can reach it or only this Mac.
public struct Listener: Sendable, Equatable, Identifiable {
    public var command: String
    public var pid: Int32
    public var port: Int
    /// Open on an address other machines can try: every interface (`*`)
    /// or one that is not loopback.
    public var reachable: Bool

    public init(command: String, pid: Int32, port: Int, reachable: Bool) {
        self.command = command
        self.pid = pid
        self.port = port
        self.reachable = reachable
    }

    public var id: String { "\(pid):\(port)" }

    /// `lsof -nP -iTCP -sTCP:LISTEN -Fpcn`. One row per process and port: a
    /// port open on IPv4 and IPv6 is one listener, reachable when either is.
    /// Sorted reachable first, then by port.
    public static func parse(_ output: String) -> [Listener] {
        var found: [Listener] = []
        var pid: Int32?
        var command = ""
        for line in output.split(whereSeparator: \.isNewline) {
            let value = String(line.dropFirst())
            switch line.first {
            case "p":
                pid = Int32(value)
                command = ""
            case "c": command = value
            case "n":
                guard let pid, let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]) else { continue }
                let reachable = !isLoopback(String(value[..<colon]))
                if let i = found.firstIndex(where: { $0.pid == pid && $0.port == port }) {
                    found[i].reachable = found[i].reachable || reachable
                } else {
                    found.append(Listener(command: command.isEmpty ? "pid \(pid)" : command, pid: pid, port: port,
                                          reachable: reachable))
                }
            default: continue
            }
        }
        return found.sorted {
            ($0.reachable ? 0 : 1, $0.port, $0.command, $0.pid) < ($1.reachable ? 0 : 1, $1.port, $1.command, $1.pid)
        }
    }

    /// Lists the listeners; nil when lsof fails. `-w` keeps warnings, such
    /// as a stale network mount, out of stderr. lsof exits 1 with nothing
    /// written when no socket matches, which is an empty list; what it did
    /// write is kept whatever the status.
    public static func read(runner: any Runner) async -> [Listener]? {
        guard let r = try? await runner.run("/usr/sbin/lsof", ["-nPw", "-iTCP", "-sTCP:LISTEN", "-Fpcn"], env: [:]) else { return nil }
        if r.output.split(whereSeparator: \.isNewline).contains(where: { $0.hasPrefix("p") }) { return parse(r.output) }
        return r.status == 0 || (r.status == 1 && r.stderr.isEmpty) ? [] : nil
    }

    /// 127/8, ::1, the same as IPv4-mapped addresses, and link-local on lo0,
    /// which lsof prints with a `%lo0` zone or the scope in the second group.
    private static func isLoopback(_ host: String) -> Bool {
        let parts = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).split(separator: "%", maxSplits: 1)
        var bare = parts.first.map { $0.lowercased() } ?? ""
        if parts.count > 1, parts[1] == "lo0" { return true }
        if bare.hasPrefix("::ffff:") { bare.removeFirst("::ffff:".count) }
        return bare.hasPrefix("127.") || bare == "::1" || bare.hasPrefix("fe80:1::")
    }
}
