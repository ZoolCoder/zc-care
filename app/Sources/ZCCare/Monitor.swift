import AppKit
import Observation
import ZCCareCore

/// Samples the Mac's vitals every two seconds while the Mac tab or the menu
/// bar's readings show: rates from the kernel each time and the disk every
/// ten seconds. For the Mac tab only, sensors every ten seconds, and devices
/// and battery health, which system_profiler is slow to give, each minute.
/// Each sample lands as one change, and only when something moved, so the
/// panel redraws at most once a tick.
@MainActor @Observable
final class Monitor {
    var vitals = Vitals()
    /// Set by the Store; what it names stays in the Free Up folders.
    var ignore = IgnoreList()
    var model = "Mac"
    /// The busiest processes, while the memory or CPU tile is open.
    var top: [Proc] = []
    /// Rows readTop keeps: six for the panel's tiles, more while Performance shows.
    var topCount = 6
    var order: Order? {
        didSet {
            guard order != oldValue else { return }
            top = []
            Task { await readTop() }
        }
    }
    var speed: SpeedTest?
    var testingSpeed = false
    /// What each Free Up folder takes, once scanned.
    var junk: [String: Int64] = [:]
    var scanning = false

    enum Order { case memory, cpu }

    /// Who reads the samples: the Mac tab wants them all, the menu bar only
    /// the cheap ones.
    enum Reader { case panel, bar }

    private var sampler = Sampler()
    private var loop: Task<Void, Never>?
    private var readers: Set<Reader> = []
    private var tick = 0
    private let macmon = ["/opt/homebrew/bin/macmon", "/usr/local/bin/macmon"].first(where: FileManager.default.isExecutableFile)

    func start(_ reader: Reader = .panel) {
        readers.insert(reader)
        // The tab opening reads the slow parts at once.
        if reader == .panel { tick = 0 }
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sample()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop(_ reader: Reader = .panel) {
        readers.remove(reader)
        guard readers.isEmpty else { return }
        loop?.cancel()
        loop = nil
    }

    private func sample() async {
        var v = vitals
        if let load = sampler.cpuLoad() { v.cpuLoad = load }
        v.memory = sampler.memory()
        v.network = sampler.network()
        var battery = sampler.battery()
        battery?.health = v.battery?.health
        battery?.capacity = v.battery?.capacity
        battery?.cycles = v.battery?.cycles
        v.battery = battery
        let panel = readers.contains(.panel)
        if tick % 5 == 0 {
            v.disk = sampler.disk()
            if panel, let macmon, let r = try? await ProcessRunner(timeout: 15).run(macmon, ["pipe", "-s", "1", "-i", "200"], env: [:]) {
                v.sensors = Sensors.parse(macmon: r.stdout) ?? v.sensors
            }
        }
        if panel, tick % 30 == 0 { await readSystemProfile(into: &v) }
        if v != vitals { vitals = v }
        if order != nil, tick % 2 == 1 { await readTop() }
        tick += 1
    }

    /// The model name never changes, so the hardware is read only once.
    private func readSystemProfile(into v: inout Vitals) async {
        let hardware = model == "Mac" ? ["SPHardwareDataType"] : []
        let args = ["-json"] + hardware + ["SPPowerDataType", "SPBluetoothDataType"]
        guard let r = try? await ProcessRunner(timeout: 60).run("/usr/sbin/system_profiler", args, env: [:]) else { return }
        v.devices = Device.parse(systemProfiler: r.stdout)
        v.battery?.read(systemProfiler: r.stdout)
        guard !hardware.isEmpty else { return }
        let root = try? JSONSerialization.jsonObject(with: r.stdout) as? [String: Any]
        if let name = ((root?["SPHardwareDataType"] as? [[String: Any]])?.first?["machine_name"] as? String) {
            model = name
        }
    }

    func readTop() async {
        guard let order else { return }
        let args = ["-Aceo", "pid=,pcpu=,rss=,uid=,ppid=,stat=,comm=", order == .memory ? "-m" : "-r"]
        guard let r = try? await ProcessRunner(timeout: 15).run("/bin/ps", args, env: [:]), self.order == order else { return }
        let next = Array(Proc.parse(ps: r.output, detailed: true).prefix(topCount))
        if next != top { top = next }
    }

    /// Sizes every Free Up folder at once, off the main thread: caches run
    /// to gigabytes in many small files.
    func scan() async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }
        let open = runningApps()
        await withTaskGroup(of: (String, Int64).self) { group in
            for spot in Junk.spots(home: NSHomeDirectory()) {
                let keep = await self.keep(spot, open: open)
                group.addTask(priority: .utility) { (spot.id, spot.size(keeping: keep)) }
            }
            for await (id, size) in group { junk[id] = size }
        }
    }

    /// What clearing a folder leaves: open apps' caches, what running
    /// commands use, and what the ignore list names in it.
    func keep(_ spot: Junk, open: Set<String>) async -> Set<String> {
        let running = spot.id == "npx" ? spot.inUse(commands: await Self.commands()) : []
        return (spot.id == "caches" ? open : []).union(ignore.names(in: spot.path)).union(running)
    }

    /// Every running process's command line, from ps.
    nonisolated static func commands() async -> [String] {
        guard let r = try? await ProcessRunner(timeout: 15).run("/bin/ps", ["-Ao", "command"], env: [:]) else { return [] }
        return r.output.split(separator: "\n").map(String.init)
    }

    /// Open apps' bundle ids, names and vendors: their caches stay while
    /// they run. Chrome keeps its cache in Caches/Google, not its bundle id.
    func runningApps() -> Set<String> {
        var names = Set<String>()
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if let name = app.localizedName { names.insert(name) }
            if let id = app.bundleIdentifier {
                let parts = id.split(separator: ".")
                if parts.count > 2 { names.insert(String(parts[1])) }
            }
        }
        return names.union(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    func readDisk() { vitals.disk = sampler.disk() }

    /// What the health grade reads, for the Care window while the panel,
    /// which samples it all, is shut.
    func readHealth() async {
        let v = await watchSample(battery: vitals.battery?.capacity == nil)
        vitals.disk = v.disk
        vitals.memory = v.memory
        vitals.sensors = v.sensors ?? vitals.sensors
        if let battery = v.battery { vitals.battery = battery }
    }

    /// The vitals the background alerts need, read apart from the panel's
    /// loop; battery health only when asked, as system_profiler is slow.
    func watchSample(battery: Bool) async -> Vitals {
        var v = Vitals()
        v.disk = sampler.disk()
        v.memory = sampler.memory()
        if let macmon, let r = try? await ProcessRunner(timeout: 15).run(macmon, ["pipe", "-s", "1", "-i", "200"], env: [:]) {
            v.sensors = Sensors.parse(macmon: r.stdout)
        }
        if battery, var b = sampler.battery(),
           let r = try? await ProcessRunner(timeout: 60).run("/usr/sbin/system_profiler", ["-json", "SPPowerDataType"], env: [:]) {
            b.read(systemProfiler: r.stdout)
            v.battery = b
        }
        return v
    }
}

// MARK: Actions

extension Store {
    /// Outside Caches: clearing caches must not clear the record of it.
    static let activityFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("dev.zoolcoder.zccare/activity.json")

    func record(_ kind: ActivityEntry.Kind, _ title: String, freed bytes: Int64 = 0, trashed: [Trashed]? = nil) {
        activity.add(ActivityEntry(kind: kind, title: title, bytes: bytes, trashed: trashed?.isEmpty == true ? nil : trashed))
        do {
            try activity.save(to: Self.activityFile)
        } catch {
            message = Message(text: "\(title) is done, but Put Back could not be saved: \(error.localizedDescription)", failed: true)
        }
    }

    /// Moves an entry's items out of the Trash to where they were. The
    /// entry stays, marked, and stops counting toward space freed. Found by
    /// value: the log can move under a row while an alert is up.
    func putBack(_ entry: ActivityEntry) {
        guard busy == nil, activity.entries.contains(entry) else { return }
        guard entry.canPutBack else {
            message = Message(text: "\(entry.title) is no longer in the Trash, or something took its place.", failed: true)
            return
        }
        guard Access.fullDisk else {
            switch Alerts.trashClosed(entry.title) {
            case .finder:
                NSWorkspace.shared.activateFileViewerSelecting((entry.trashed ?? []).map { URL(fileURLWithPath: $0.inTrash) })
            case .grant: Access.openFullDiskSettings()
            case nil: break
            }
            return
        }
        // What stays in the Trash keeps its Put Back for another try.
        var stuck: [String] = []
        if let index = activity.entries.firstIndex(of: entry) {
            stuck = activity.entries[index].putBackFromTrash()
        }
        try? activity.save(to: Self.activityFile)
        monitor.readDisk()
        putBackDone?()
        message = stuck.isEmpty
            ? Message(text: "\(entry.title) is back where it was.", failed: false)
            : Message(text: "Could not put back \(stuck.joined(separator: ", ")).", failed: true)
    }

    private func busyScanning() {
        message = Message(text: "A scan is still running. Clean up once it finishes.", failed: true)
    }

    /// Clears the folder, or only the entries picked in Cleanup's preview,
    /// whose sizes `picked` gives.
    func clean(_ spot: Junk, only picked: [JunkEntry]? = nil) async {
        guard !monitor.scanning else { return busyScanning() }
        let size = monitor.junk[spot.id] ?? 0
        let verb = deletesPermanently ? "permanently deletes" : "moves to the Trash"
        let what = picked.map {
            "This \(verb) " + Self.counted($0.count, "item") + ", \(Self.bytes($0.reduce(0) { $0 + $1.size })), in \(spot.path):\n"
                + Alerts.lines($0.map { "\($0.name) (\(Self.bytes($0.size)))" })
        } ?? "This \(verb) \(Self.bytes(size)) in \(spot.path)."
        let aftermath = deletesPermanently ? "It does not go to the Trash." : "My Activity can put it back until the Trash is emptied."
        guard busy == nil, Alerts.confirm("Clear \(spot.title)?", what + "\n\(aftermath)\n\n\(spot.detail)", button: "Clear") else { return }
        busy = "Clearing \(spot.title)"
        defer { busy = nil }
        let keep = await monitor.keep(spot, open: monitor.runningApps())
        let only = picked.map { Set($0.map(\.name)) }
        let permanently = deletesPermanently
        let removal = await Task.detached { spot.empty(keeping: keep, only: only, permanently: permanently) }.value
        let left = await Task.detached { spot.size(keeping: keep) }.value
        monitor.junk[spot.id] = left
        monitor.readDisk()
        record(.junk, spot.title, freed: max(size - left, 0), trashed: removal.trashed)
        message = Message(text: "\(spot.title): freed \(Self.bytes(max(size - left, 0)))"
                          + removal.ending, failed: !removal.failures.isEmpty)
    }

    /// Clears every Free Up folder after one question, for Smart Care.
    func cleanAll() async {
        guard !monitor.scanning else { return busyScanning() }
        let spots = Junk.spots(home: NSHomeDirectory()).filter { (monitor.junk[$0.id] ?? 0) > 0 }
        let total = spots.reduce(Int64(0)) { $0 + (monitor.junk[$1.id] ?? 0) }
        let list = spots.map { "\($0.title): \(Self.bytes(monitor.junk[$0.id] ?? 0))" }.joined(separator: "\n")
        guard busy == nil, !spots.isEmpty,
              Alerts.confirm("Clean up \(Self.bytes(total))?", list + "\n\n" + (deletesPermanently
                                 ? "This permanently deletes it; nothing goes to the Trash."
                                 : "This moves it to the Trash; My Activity can put it back until the Trash is emptied.")
                                 + " All of it comes back on its own when needed.",
                             button: "Clean Up") else { return }
        busy = "Cleaning up"
        defer { busy = nil }
        let open = monitor.runningApps()
        var freed: Int64 = 0, removal = Removal()
        let permanently = deletesPermanently
        for spot in spots {
            let keep = await monitor.keep(spot, open: open)
            let size = monitor.junk[spot.id] ?? 0
            let result = await Task.detached { spot.empty(keeping: keep, permanently: permanently) }.value
            removal.failures += result.failures
            removal.trashed += result.trashed
            let left = await Task.detached { spot.size(keeping: keep) }.value
            monitor.junk[spot.id] = left
            freed += max(size - left, 0)
        }
        monitor.readDisk()
        record(.junk, "System Junk", freed: freed, trashed: removal.trashed)
        message = Message(text: "Freed \(Self.bytes(freed))" + removal.ending, failed: !removal.failures.isEmpty)
    }

    /// The Finder empties the Trash: the app cannot read it without Full
    /// Disk Access. macOS asks once to let ZC Care control the Finder.
    func emptyTrash() async {
        let undoable = activity.entries.filter(\.canPutBack).count
        let lost = undoable == 0 ? "" : "\n\n\(Self.counted(undoable, "cleanup")) in My Activity can no longer be put back."
        guard busy == nil, Alerts.confirm("Empty the Trash?", "What is in the Trash is deleted for good." + lost,
                                          button: "Empty Trash") else { return }
        busy = "Emptying the Trash"
        defer { busy = nil }
        let before = monitor.vitals.disk?.available ?? 0
        let failure = await self.failure("Finder refused") {
            try await ProcessRunner().run("/usr/bin/osascript", ["-e", #"tell application "Finder" to empty trash"#], env: [:])
        }
        monitor.readDisk()
        if failure == nil { record(.junk, "Trash Bins", freed: max((monitor.vitals.disk?.available ?? 0) - before, 0)) }
        message = failure.map { Message(text: "Trash not emptied. \($0)", failed: true) }
            ?? Message(text: "The Trash is empty.", failed: false)
    }

    func testSpeed() async {
        guard !monitor.testingSpeed else { return }
        monitor.testingSpeed = true
        defer { monitor.testingSpeed = false }
        let r = try? await ProcessRunner(timeout: 120).run("/usr/bin/networkQuality", ["-c"], env: [:])
        guard let r, let result = SpeedTest.parse(r.stdout) else {
            message = Message(text: "Speed test failed. \(r?.stderr ?? "")", failed: true)
            return
        }
        monitor.speed = result
    }

    func quit(_ app: NSRunningApplication) {
        app.terminate()
        Task {
            try? await Task.sleep(for: .seconds(1))
            await monitor.readTop()
        }
    }

    /// "1 app", "2 apps"; `many` for words that do not just take an s.
    static func counted(_ n: Int, _ one: String, _ many: String? = nil) -> String {
        "\(n) " + (n == 1 ? one : many ?? one + "s")
    }

    /// A size or rate in the fewest characters, for the menu bar: 155G,
    /// 3.2M, 7K.
    static func compact(_ n: Double) -> String {
        let units = ["B", "K", "M", "G", "T"]
        var value = max(n, 0), unit = 0
        while value >= 999.5, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        let digits = value < 9.95 && unit > 0 ? String(format: "%.1f", value) : String(Int(value.rounded()))
        return digits + units[unit]
    }

    static func bytes(_ n: Int64, _ style: ByteCountFormatter.CountStyle = .file) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: style)
    }

    /// A transfer rate in KB and up, as Activity Monitor shows it: a quiet
    /// link reads 0 KB/s, not 481 bytes/s.
    static func rate(_ n: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.allowsNonnumericFormatting = false
        return f.string(fromByteCount: n) + "/s"
    }
}
