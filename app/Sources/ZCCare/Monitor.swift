import AppKit
import Observation
import ZCCareCore

/// Samples the Mac's vitals every two seconds while the Mac tab or the menu
/// bar's readings show: rates from the kernel each time and the disk every
/// ten seconds. For the Mac tab only, sensors every ten seconds, and devices
/// and battery health, which system_profiler is slow to give, each minute,
/// and the connection's addresses each time.
/// Each sample lands as one change, and only when something moved, so the
/// panel redraws at most once a tick.
@MainActor @Observable
final class Monitor {
    var vitals = Vitals()
    /// Set by the Store; what it names stays in the Free Up folders.
    var ignore = IgnoreList()
    var model = "Mac"
    /// The busiest processes, while the memory, CPU or battery detail is open.
    var top: [Proc] = []
    /// Rows readTop keeps for the panel's tiles.
    private let topCount = 6
    var order: Order? {
        didSet {
            guard order != oldValue else { return }
            top = []
            Task { await readTop() }
        }
    }
    /// Performance's own list, apart from the panel's, so each keeps its
    /// order when both show.
    var performanceTop: [Proc] = []
    /// What Performance shows, while it does: the order and how many rows.
    var performance: (order: Order, count: Int)?
    /// External drives, disk images and shares, while the panel shows.
    var volumes: [Volume] = []
    /// Volumes being ejected, by path.
    var ejecting: Set<String> = []
    var speed: SpeedTest?
    /// The primary service's addresses, router and DNS, for the Network
    /// detail.
    var connection: Connection?
    /// CPU load and the share of memory used over the last five minutes,
    /// one reading a tick, for the CPU and Memory details.
    var cpuHistory = Recent(capacity: 150)
    var memoryHistory = Recent(capacity: 150)
    /// False until the panel's first read, when no connection still means
    /// unknown rather than offline.
    var connectionRead = false
    var testingSpeed = false
    /// What each Free Up folder takes, once scanned.
    var junk: [String: Int64] = [:]
    var scanning = false

    enum Order { case memory, cpu }

    /// Who reads the samples: the Mac tab wants them all, the menu bar only
    /// the cheap ones.
    enum Reader { case panel, bar }

    /// Where a Mac tab shows: the menu bar's window and the floating panel
    /// can both show one, and one closing must not stop the other's.
    enum Host: Hashable { case menu, window }

    private var sampler = Sampler()
    private var loop: Task<Void, Never>?
    private(set) var readers: Set<Reader> = []
    private var hosts: Set<Host> = []
    /// While the Mac or its displays sleep nothing samples, as no one sees
    /// the readings; waking starts again afresh. Two flags, as the Mac can
    /// wake for upkeep with its displays still off.
    private var systemAsleep = false
    private var screensAsleep = false
    private var tick = 0
    private let macmon = ["/opt/homebrew/bin/macmon", "/usr/local/bin/macmon"].first(where: FileManager.default.isExecutableFile)

    init() {
        let center = NSWorkspace.shared.notificationCenter
        let names = [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification]
        for name in names {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let name = note.name
                MainActor.assumeIsolated { self?.power(name) }
            }
        }
    }

    func start(_ reader: Reader = .panel, host: Host = .menu) {
        readers.insert(reader)
        if reader == .panel {
            // The menu bar's loop does not read the disk: its last count is
            // from when the tab last showed.
            if hosts.isEmpty {
                sampler.forgetDisk()
                vitals.diskIO = nil
            }
            hosts.insert(host)
            // The tab opening reads the slow parts at once, and the
            // connection before them, so the Network detail never shows the
            // last one.
            tick = 0
            connection = sampler.connection()
            connectionRead = true
        }
        run()
    }

    func stop(_ reader: Reader = .panel, host: Host = .menu) {
        if reader == .panel {
            hosts.remove(host)
            guard hosts.isEmpty else { return }
            connectionRead = false
        }
        readers.remove(reader)
        guard readers.isEmpty else { return }
        halt()
    }

    private func run() {
        guard loop == nil, !systemAsleep, !screensAsleep, !readers.isEmpty else { return }
        // Rates are differences from the last read: one from before a stop
        // would average over the whole gap.
        sampler.forgetRates()
        vitals.diskIO = nil
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sample()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func halt() {
        loop?.cancel()
        loop = nil
        // A gap would join two times as one line.
        cpuHistory.clear()
        memoryHistory.clear()
    }

    private func power(_ name: NSNotification.Name) {
        switch name {
        case NSWorkspace.willSleepNotification: systemAsleep = true
        case NSWorkspace.didWakeNotification: systemAsleep = false
        case NSWorkspace.screensDidSleepNotification: screensAsleep = true
        default: screensAsleep = false
        }
        if systemAsleep || screensAsleep {
            halt()
        } else if loop == nil {
            tick = 0
            run()
        }
    }

    private func sample() async {
        var v = vitals
        let now = Date.now
        var cpu = cpuHistory, memoryUsed = memoryHistory
        if let load = sampler.cpuLoad() {
            v.cpuLoad = load
            cpu.append(load, at: now)
        }
        v.memory = sampler.memory()
        if let memory = v.memory, memory.total > 0, memory.used > 0 {
            memoryUsed.append(Double(memory.used) / Double(memory.total), at: now)
        }
        v.network = sampler.network()
        var battery = sampler.battery()
        battery?.health = v.battery?.health
        battery?.capacity = v.battery?.capacity
        battery?.cycles = v.battery?.cycles
        v.battery = battery
        let panel = readers.contains(.panel)
        // Keeps the last rate through a read that gives none, so the row
        // does not blink.
        v.diskIO = panel ? sampler.diskIO() ?? v.diskIO : nil
        if panel, case let now = sampler.connection(), now != connection { connection = now }
        if tick % 5 == 0 {
            v.disk = sampler.disk()
            if panel, let macmon, let r = try? await ProcessRunner(timeout: 15).run(macmon, ["pipe", "-s", "1", "-i", "200"], env: [:]) {
                v.sensors = Sensors.parse(macmon: r.stdout) ?? v.sensors
            }
        }
        if panel, tick % 30 == 0 { await readSystemProfile(into: &v) }
        // A stop while it waited cleared the history: writing the copies
        // back would bring it back, or overwrite a newer loop's readings.
        guard !Task.isCancelled else { return }
        // Written beside the vitals, so a tick stays one redraw.
        cpuHistory = cpu
        memoryHistory = memoryUsed
        if v != vitals { vitals = v }
        // Apart from the copy above, which would bring back a drive ejected
        // while it waited.
        if panel, tick % 5 == 0 { await readVolumes() }
        if panel, order != nil, tick % 2 == 1 { await readTop() }
        // A loop started since counts from 0; this one must not move it on.
        guard !Task.isCancelled else { return }
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

    func readVolumes() async {
        let next = await Task.detached { Sampler.volumes() }.value
        if next != volumes { volumes = next }
    }

    func readTop() async {
        guard let order, let next = await Self.busiest(order, count: topCount), self.order == order else { return }
        if next != top { top = next }
    }

    func readPerformanceTop() async {
        guard let wanted = performance,
              let next = await Self.busiest(wanted.order, count: wanted.count),
              performance?.order == wanted.order else { return }
        if next != performanceTop { performanceTop = next }
    }

    private static func busiest(_ order: Order, count: Int) async -> [Proc]? {
        let args = ["-Aceo", "pid=,pcpu=,rss=,uid=,ppid=,stat=,comm=", order == .memory ? "-m" : "-r"]
        guard let r = try? await ProcessRunner(timeout: 15).run("/bin/ps", args, env: [:]) else { return nil }
        return Array(Proc.parse(ps: r.output, detailed: true).prefix(count))
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
    /// loop; battery health, Bluetooth devices, the Trash and running apps
    /// only when asked, as the first three are slow.
    func watchSample(battery: Bool, trash: Bool = false, devices: Bool = false, apps: Bool = false) async -> Vitals {
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
        let args = ["-Aceo", "pid=,pcpu=,rss=,uid=,ppid=,stat=,comm="]
        if apps, let r = try? await ProcessRunner(timeout: 15).run("/bin/ps", args, env: [:]) {
            let user = getuid()
            v.processes = Proc.parse(ps: r.output, detailed: true).filter { $0.uid == user }
        }
        if devices, let r = try? await ProcessRunner(timeout: 60).run("/usr/sbin/system_profiler", ["-json", "SPBluetoothDataType"], env: [:]) {
            v.devices = Device.parse(systemProfiler: r.stdout)
        }
        if trash {
            v.trash = await Task.detached(priority: .utility) {
                TrashBins.find(home: NSHomeDirectory(), volumes: TrashBins.mountedVolumes()).reduce(0) { $0 + $1.size }
            }.value
        }
        return v
    }
}

// MARK: Actions

extension Store {
    /// Unmounts a volume and, for a drive, ejects it; Finder's own call,
    /// off the main thread as it waits for the disk.
    func eject(_ volume: Volume) async {
        guard !monitor.ejecting.contains(volume.path) else { return }
        monitor.ejecting.insert(volume.path)
        defer { monitor.ejecting.remove(volume.path) }
        let url = URL(fileURLWithPath: volume.path)
        let failure = await Task.detached { () -> NSError? in
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                return nil
            } catch {
                return error as NSError
            }
        }.value
        if let failure {
            let busy = failure.code == fBsyErr ? " An app is still using it." : ""
            message = Message(text: "“\(volume.name)” was not ejected: \(failure.localizedDescription)\(busy)", failed: true)
        }
        // A drive's other volumes go with it.
        await monitor.readVolumes()
    }

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

    /// The Free Up folders Clean All clears: those with something in them,
    /// less the ones cleared by hand only.
    var spotsToCleanAll: [Junk] {
        Junk.spots(home: NSHomeDirectory()).filter { !$0.optional && (monitor.junk[$0.id] ?? 0) > 0 }
    }

    /// Clears every Free Up folder after one question, for Smart Care.
    func cleanAll() async {
        guard !monitor.scanning else { return busyScanning() }
        let spots = spotsToCleanAll
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
        let (log, trashed) = await clean(spots, title: "System Junk")
        monitor.readDisk()
        record(.junk, "System Junk", freed: log.freed, trashed: trashed)
        message = Message(text: "Freed \(Self.bytes(log.freed))" + (log.allDone ? "." : "; \(Self.counted(log.failed.count, "item")) stayed."),
                          failed: !log.allDone)
    }

    /// Clears the folders one after another and logs each: a line for what
    /// a folder freed, and one per entry that stayed, with why.
    func clean(_ spots: [Junk], title: String) async -> (log: RunLog, trashed: [Trashed]) {
        let open = monitor.runningApps()
        var log = RunLog(title: title, permanent: deletesPermanently)
        var trashed: [Trashed] = []
        let permanently = deletesPermanently
        for spot in spots {
            let keep = await monitor.keep(spot, open: open)
            let size = monitor.junk[spot.id] ?? 0
            let result = await Task.detached { spot.empty(keeping: keep, permanently: permanently) }.value
            let left = await Task.detached { spot.size(keeping: keep) }.value
            monitor.junk[spot.id] = left
            trashed += result.trashed
            log.add(RunLog.Line(name: spot.title, detail: spot.path, size: max(size - left, 0)))
            for failure in result.failures {
                log.add(RunLog.Line(name: failure.name, detail: spot.path, size: 0, failure: failure.reason.label))
            }
        }
        return (log, trashed)
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
