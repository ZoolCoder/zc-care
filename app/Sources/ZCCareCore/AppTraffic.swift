import Foundation

/// How fast a process receives and sends over the network, from two nettop
/// readings of what it moved since it started.
public struct AppTraffic: Sendable, Equatable, Identifiable {
    public var pid: Int32
    public var name: String
    /// Bytes a second.
    public var down: Double
    public var up: Double

    public init(pid: Int32, name: String, down: Double, up: Double) {
        self.pid = pid
        self.name = name
        self.down = down
        self.up = up
    }

    public var id: Int32 { pid }

    /// What a process received and sent since it started.
    public struct Totals: Sendable, Equatable {
        public var name: String
        public var received: Int64
        public var sent: Int64

        public init(name: String, received: Int64, sent: Int64) {
            self.name = name
            self.received = received
            self.sent = sent
        }
    }

    /// `nettop -P -L 1 -x -J bytes_in,bytes_out`: a header, then
    /// `name.pid,in,out,` a process. nettop cuts names to 15 characters.
    public static func parse(_ output: String) -> [Int32: Totals] {
        var totals: [Int32: Totals] = [:]
        for line in output.split(whereSeparator: \.isNewline) where !line.hasPrefix(",") {
            var fields = line.split(separator: ",", omittingEmptySubsequences: false)
            if fields.last?.isEmpty == true { fields.removeLast() }
            guard fields.count >= 3, let sent = Int64(fields.removeLast()), let received = Int64(fields.removeLast()) else { continue }
            let process = fields.joined(separator: ",")
            guard let dot = process.lastIndex(of: "."), let pid = Int32(process[process.index(after: dot)...]) else { continue }
            totals[pid] = Totals(name: String(process[..<dot]), received: received, sent: sent)
        }
        return totals
    }

    /// The processes that moved at least 1 KB a second between two
    /// readings, busiest first. One missing from the first reading, or whose
    /// name changed or counts went down, as when its pid was reused, waits
    /// for the next reading.
    public static func rates(from old: [Int32: Totals], to new: [Int32: Totals], over seconds: Double) -> [AppTraffic] {
        guard seconds > 0 else { return [] }
        return new.compactMap { pid, now in
            guard let before = old[pid], before.name == now.name, now.received >= before.received, now.sent >= before.sent
            else { return nil }
            let traffic = AppTraffic(pid: pid, name: now.name, down: Double(now.received - before.received) / seconds,
                                     up: Double(now.sent - before.sent) / seconds)
            return traffic.down + traffic.up >= 1000 ? traffic : nil
        }
        .sorted { ($0.down + $0.up, $1.pid) > ($1.down + $1.up, $0.pid) }
    }

    /// Every process's totals; nil when nettop fails, or lists nothing,
    /// which a changed output would do: mDNSResponder always has sockets.
    public static func read(runner: any Runner) async -> [Int32: Totals]? {
        guard let r = try? await runner.run("/usr/bin/nettop", ["-P", "-L", "1", "-x", "-J", "bytes_in,bytes_out"], env: [:]),
              r.status == 0 else { return nil }
        let totals = parse(r.output)
        return totals.isEmpty ? nil : totals
    }
}
