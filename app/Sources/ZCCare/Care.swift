import AppKit
import IOKit.ps
import Observation
import ZCCareCore

/// The Care window's state: one Smart Care scan over the whole Mac, and the
/// modules it sums up. Changes go through the Store, which asks first.
@MainActor @Observable
final class Care {
    enum Module: String, CaseIterable, Identifiable {
        case smartCare = "Smart Care", cleanup = "Cleanup", protection = "Protection", performance = "Performance"
        case apps = "Applications", clutter = "My Clutter", spaceLens = "Space Lens", cloud = "Cloud Cleanup"
        case developer = "Developer"
        case workstation = "My Workstation", tools = "My Tools", activity = "My Activity"

        /// The sidebar's two groups, as CleanMyMac splits them.
        static let modules: [Module] = [.smartCare, .cleanup, .protection, .performance, .apps, .clutter, .spaceLens, .cloud,
                                        .developer]
        static let extras: [Module] = [.workstation, .tools, .activity]

        var id: String { rawValue }

        /// The module a URL names by the start of its name, spaces and a
        /// leading "My" optional: clutter, myclutter and space all work.
        static func named(_ name: String) -> Module? {
            let name = name.lowercased().replacingOccurrences(of: " ", with: "")
            guard !name.isEmpty else { return nil }
            return allCases.first { module in
                let full = module.rawValue.lowercased().replacingOccurrences(of: " ", with: "")
                return full.hasPrefix(name) || (full.hasPrefix("my") && full.dropFirst(2).hasPrefix(name))
            }
        }

        var symbol: String {
            switch self {
            case .smartCare: "sparkles"
            case .cleanup: "trash.fill"
            case .clutter: "doc.on.doc.fill"
            case .developer: "hammer.fill"
            case .apps: "square.grid.2x2.fill"
            case .performance: "gauge.with.dots.needle.67percent"
            case .protection: "lock.shield.fill"
            case .spaceLens: "chart.pie.fill"
            case .cloud: "icloud.fill"
            case .workstation: "desktopcomputer"
            case .tools: "square.grid.3x3.fill"
            case .activity: "chart.bar.xaxis"
            }
        }
    }

    let store: Store
    var module: Module = .smartCare
    var scanning = false
    var scannedAt: Date?
    var largeFiles: [LargeFile] = []
    var duplicates: [DuplicateGroup] = []
    /// Nil until looked for: comparing every photo takes a while.
    var similar: [SimilarGroup]?
    var scanningImages = false
    var oldDownloads: [LargeFile] = []
    var diskImages: [LargeFile] = []
    /// node_modules and the like in projects left alone for 90 days.
    var dependencies: [LargeFile] = []
    var models: [AIModel] = []
    /// Caches, logs, temp files and old versions AI tools leave.
    var aiJunk: [AIJunk] = []
    var scanningAI = false
    var scanningDeveloper = false
    /// Nil until looked for: what removed apps left in the Library.
    var orphans: [Orphan]?
    var loadingOrphans = false
    var maintenance: [MaintenanceTask] = []
    var scanningFiles = false
    /// Hashing for duplicates outlasts the rest of the file scan.
    var findingDuplicates = false
    /// Each app bundle's cask, from Homebrew's index: what an app installed
    /// by hand can be adopted as.
    var casks: [String: String] = [:]
    var backgroundItems: [BackgroundItem] = []
    var assessments: [String: Assessment] = [:]
    var gatekeeper: Bool?
    /// Nil until read; the TCC databases need Full Disk Access.
    var permissions: [Permission]?
    var loadingProtection = false
    /// History, cookies and caches per browser; nil until read.
    var browserTraces: [BrowserTrace]?
    var loadingBackground = false
    /// What each cloud folder keeps downloaded; nil until looked for.
    var cloud: [CloudScan]?
    var scanningCloud = false
    var space: SpaceScan?
    var scanningSpace = false
    var apps: [InstalledApp] = []
    var loadingApps = false
    var icons: [String: NSImage] = [:]
    var agents: [LaunchAgent] = []
    var background: [NSRunningApplication] = []
    /// False until a scan runs in this launch: what shows before came from disk.
    var fresh = false
    /// Modules past their intro in this launch.
    var entered: Set<Module> = []

    /// Large Files lists files from this size up.
    nonisolated static let largeFile: Int64 = 200_000_000
    /// Duplicates are looked for from this size up: hashing smaller files
    /// costs more than they waste.
    nonisolated static let duplicateFile: Int64 = 10_000_000

    init(store: Store) {
        self.store = store
        restore()
        store.ignoreListChanged = { [weak self] in self?.applyIgnoreList() }
        // Files back from the Trash belong in the lists again.
        store.putBackDone = { [weak self] in
            guard let self, !scanning else { return }
            Task { await self.scan() }
        }
    }

    /// Drops what the ignore list names from every list. A path taken off
    /// the list shows again after the next scan.
    func applyIgnoreList() {
        let list = store.ignoreList
        largeFiles = list.keep(largeFiles)
        oldDownloads = list.keep(oldDownloads)
        diskImages = list.keep(diskImages)
        dependencies = list.keep(dependencies)
        duplicates = list.keep(duplicates)
        similar = similar.map(list.keep)
        models.removeAll { $0.paths.contains(where: list.covers) }
        apps.removeAll { list.covers($0.url) }
        orphans = orphans?.filter { !$0.paths.contains(where: list.covers) }
        aiJunk.removeAll { $0.paths.allSatisfy(list.covers) }
        cloud = cloud?.map { scan in
            var scan = scan
            scan.files = list.keep(scan.files)
            return scan
        }
    }

    /// The last check before a change: nothing on the ignore list goes.
    private func allowed(_ urls: [URL]) -> Bool {
        guard let hit = urls.first(where: store.ignoreList.covers) else { return true }
        store.message = Store.Message(text: "\(hit.lastPathComponent) is on the ignore list, so it stays.", failed: true)
        return false
    }

    var monitor: Monitor { store.monitor }
    var junk: Int64 { monitor.junk.values.reduce(0, +) }
    /// Large files, old downloads and installers, each once, and what duplicates waste.
    var clutter: Int64 {
        let files = Dictionary((largeFiles + oldDownloads + diskImages).map { ($0.id, $0.size) }, uniquingKeysWith: { a, _ in a })
        return files.values.reduce(0, +) + duplicates.reduce(0) { $0 + $1.wasted }
    }
    var adoptable: [InstalledApp] {
        apps.filter { $0.declared == nil && $0.source == .other && casks[$0.url.lastPathComponent] != nil }
    }
    var untrusted: [InstalledApp] { apps.filter { assessments[$0.id].map { !$0.trusted } ?? false } }
    var undeclared: [InstalledApp] { apps.filter { $0.declared == nil } }
    var unused: [InstalledApp] { apps.filter { $0.unused() } }
    var ai: Int64 { aiJunk.reduce(0) { $0 + $1.size } }
    var developer: Int64 { dependencies.reduce(0) { $0 + $1.size } + models.reduce(0) { $0 + $1.size } }
    var startup: [LaunchAgent] { agents.filter { $0.enabled && ($0.runAtLoad || $0.keepAlive) } }

    /// A module opens on its intro until its Scan is pressed; those Smart
    /// Care fills skip it once any scan has run.
    func showsIntro(_ m: Module) -> Bool {
        guard !entered.contains(m) else { return false }
        switch m {
        case .smartCare, .cleanup, .clutter, .apps, .performance, .developer: return scannedAt == nil && !scanning
        case .spaceLens: return space == nil && !scanningSpace
        case .cloud: return cloud == nil && !scanningCloud
        case .protection: return true
        case .workstation, .tools, .activity: return false
        }
    }

    /// The intro's Scan: leaves the intro and reads what the module shows.
    /// Protection and Performance read on appearing.
    func enter(_ m: Module) async {
        entered.insert(m)
        switch m {
        case .smartCare: await scan()
        case .cleanup:
            async let junk: Void = monitor.scan()
            async let ai: Void = scanAI()
            _ = await (junk, ai)
        case .clutter: await scanFiles()
        case .developer: await scanDeveloper()
        case .apps: await loadApps()
        case .spaceLens: await scanSpace()
        case .cloud: await scanCloud()
        case .protection, .performance, .workstation, .tools, .activity: break
        }
    }

    // MARK: Scan

    /// Reads everything the cards show at once.
    func scan() async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }
        await store.connected()
        async let junk: Void = monitor.scan()
        async let state: Void = store.refresh()
        async let files: Void = scanFiles()
        async let apps: Void = loadApps()
        async let agents: Void = loadAgents()
        async let developer: Void = scanDeveloper()
        async let ai: Void = scanAI()
        _ = await (junk, state, files, apps, agents, developer, ai)
        scannedAt = .now
        fresh = true
        save()
    }

    // MARK: Last scan

    private static let saved = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("dev.zoolcoder.zccare/care.json")

    /// Shows the last scan at once; the window starts a fresh one.
    private func restore() {
        guard let last = CareScan.load(from: Self.saved) else { return }
        scannedAt = last.scannedAt
        if monitor.junk.isEmpty { monitor.junk = last.junk }
        // What went since the scan, by hand or another app, leaves the lists.
        let here = { (url: URL) in FileManager.default.fileExists(atPath: url.path) }
        largeFiles = last.largeFiles.filter { here($0.url) }
        duplicates = (last.duplicates ?? []).compactMap { group in
            var group = group
            group.files = group.files.filter { here($0.url) }
            return group.files.count > 1 ? group : nil
        }
        oldDownloads = (last.oldDownloads ?? []).filter { here($0.url) }
        diskImages = (last.diskImages ?? []).filter { here($0.url) }
        dependencies = (last.dependencies ?? []).filter { here($0.url) }
        models = (last.models ?? []).filter { $0.paths.contains(where: here) }
        apps = last.apps.filter { here($0.url) }
        agents = last.agents
        for app in apps { icons[app.id] = NSWorkspace.shared.icon(forFile: app.url.path) }
        readBackground()
        space = SpaceScan.load(from: Self.savedSpace)
        applyIgnoreList()
    }

    private func save() {
        guard let scannedAt else { return }
        var scan = CareScan(scannedAt: scannedAt, junk: monitor.junk, largeFiles: largeFiles, apps: apps, agents: agents)
        scan.duplicates = duplicates
        scan.oldDownloads = oldDownloads
        scan.diskImages = diskImages
        scan.dependencies = dependencies
        scan.models = models
        try? scan.save(to: Self.saved)
    }

    // MARK: Weekly scan

    /// Looks every hour whether a week has passed since the last scan, and
    /// scans then; what it finds worth knowing becomes a notification.
    func startSchedule() {
        guard schedule == nil else { return }
        schedule = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            while !Task.isCancelled {
                await self?.scheduledScan()
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    private var schedule: Task<Void, Never>?

    /// A scan nobody asked for waits for mains power and a cool Mac; the
    /// hourly check tries again.
    private static var canWorkUnasked: Bool {
        let info = ProcessInfo.processInfo
        let source = IOPSGetProvidingPowerSourceType(nil)?.takeUnretainedValue() as String?
        return !info.isLowPowerModeEnabled && info.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue
            && source != kIOPMBatteryPowerKey
    }

    private func scheduledScan() async {
        guard store.weeklyScan, !scanning, CareSchedule.due(last: scannedAt), Self.canWorkUnasked else { return }
        await scan()
        guard store.notifies else { return }
        store.notifier.post(CareSchedule.alerts(junk: junk, outdated: store.snapshot?.outdated.count ?? 0,
                                                findings: store.findings.count))
    }

    /// Smart Care's Run: cleans up, then updates, each after its question.
    func run() async {
        if junk > 0 { await store.cleanAll() }
        if !(store.snapshot?.outdated.isEmpty ?? true) { await store.updateAll() }
    }

    // MARK: Large files

    /// Large files and duplicates come from one Spotlight query, old
    /// downloads from the folder itself.
    func scanFiles() async {
        guard !scanningFiles, !findingDuplicates else { return }
        scanningFiles = true
        let home = NSHomeDirectory()
        let args = ["-onlyin", home, LargeFiles.query(minimum: Self.duplicateFile)]
        guard let r = try? await ProcessRunner(timeout: 120).run("/usr/bin/mdfind", args, env: [:]) else {
            scanningFiles = false
            return
        }
        let paths = r.output.split(whereSeparator: \.isNewline).map(String.init)
        let downloads = URL(fileURLWithPath: home + "/Downloads")
        let installers = [downloads, URL(fileURLWithPath: home + "/Desktop")]
        let same = Task.detached(priority: .utility) { Duplicates.groups(paths: paths, home: home, minimum: Self.duplicateFile) }
        async let large = Task.detached { LargeFiles.files(paths: paths, home: home, minimum: Self.largeFile) }.value
        async let old = Task.detached { OldDownloads.files(in: downloads) }.value
        async let images = Task.detached { DiskImages.files(in: installers) }.value
        (largeFiles, oldDownloads, diskImages) = await (large, old, images)
        applyIgnoreList()
        scanningFiles = false
        findingDuplicates = true
        defer { findingDuplicates = false }
        duplicates = store.ignoreList.keep(await same.value)
    }

    func trash(_ file: LargeFile) async {
        guard store.busy == nil, allowed([file.url]) else { return }
        // A disk image a VM runs from or a video in an editor stays put.
        if let r = try? await ProcessRunner(timeout: 10).run("/usr/sbin/lsof", ["+c", "0", "-Fc", "--", file.url.path], env: [:]),
           let app = OpenFile.holders(r.output).first {
            store.message = Store.Message(text: "\(file.name) is open in \(app). Close it first.", failed: true)
            return
        }
        // A folder from Space Lens: a project with a server or a shell in it.
        if (try? file.url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let cwds = try? await ProcessRunner(timeout: 10).run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-Fcn"], env: [:])
            let using = OpenFile.workingIn(file.url.path, cwds?.output ?? "")
            let commands = await Task.detached { Monitor.commands() }.value
            if let app = using.first ?? (AIClutter.used(file.url, by: commands) ? "a running command" : nil) {
                store.message = Store.Message(text: "\(file.name) is in use by \(app). Stop it first.", failed: true)
                return
            }
        }
        guard store.busy == nil, Alerts.confirm("Move \(file.name) to the Trash?",
                                                "\(Store.bytes(file.size)) in \(file.url.deletingLastPathComponent().path).",
                                                button: "Move to Trash") else { return }
        do {
            var binned: NSURL?
            try FileManager.default.trashItem(at: file.url, resultingItemURL: &binned)
            largeFiles.removeAll { $0.id == file.id }
            oldDownloads.removeAll { $0.id == file.id }
            diskImages.removeAll { $0.id == file.id }
            dependencies.removeAll { $0.id == file.id }
            duplicates = duplicates.compactMap { group in
                var group = group
                group.files.removeAll { $0.id == file.id }
                return group.files.count > 1 ? group : nil
            }
            drop([file.id])
            if let scan = space, scan.root.find(file.url.path) != nil {
                space?.root = scan.root.removing(file.url.path)
                try? space?.save(to: Self.savedSpace)
            }
            monitor.readDisk()
            store.record(.files, file.name, freed: file.size,
                         trashed: (binned as URL?).map { [Trashed(original: file.url, inTrash: $0)] })
            store.message = Store.Message(text: "\(file.name) is in the Trash.", failed: false)
        } catch {
            store.message = Store.Message(text: error.localizedDescription, failed: true)
        }
    }

    // MARK: Similar images

    /// Photos in Pictures, Desktop, Downloads and Documents, grouped by how
    /// alike Vision finds them.
    func scanImages() async {
        guard !scanningImages else { return }
        scanningImages = true
        defer { scanningImages = false }
        let home = NSHomeDirectory()
        let args = SimilarImages.folders(home: home).flatMap { ["-onlyin", $0] } + [SimilarImages.query]
        guard let r = try? await ProcessRunner(timeout: 120).run("/usr/bin/mdfind", args, env: [:]) else { return }
        let paths = r.output.split(whereSeparator: \.isNewline).map(String.init)
        similar = await Task.detached(priority: .utility) { SimilarImages.groups(paths: paths, home: home) }.value
        applyIgnoreList()
    }

    /// Moves every image but the best of a group to the Trash.
    func trashOthers(_ group: SimilarGroup) {
        let others = group.others
        guard store.busy == nil, allowed(others.map(\.url)), Alerts.confirm("Move \(Store.counted(others.count, "similar image")) to the Trash?",
                                                "\(Store.bytes(group.wasted)). \(group.best.name) stays.",
                                                button: "Move to Trash") else { return }
        var moved: [LargeFile] = []
        var trashed: [Trashed] = []
        for file in others {
            var binned: NSURL?
            guard (try? FileManager.default.trashItem(at: file.url, resultingItemURL: &binned)) != nil else { continue }
            moved.append(file)
            if let binned { trashed.append(Trashed(original: file.url, inTrash: binned as URL)) }
        }
        drop(Set(moved.map(\.id)))
        monitor.readDisk()
        let freed = moved.reduce(0) { $0 + $1.size }
        store.record(.files, "Similar to \(group.best.name)", freed: freed, trashed: trashed)
        store.message = Store.Message(text: "\(moved.count) of \(Store.counted(others.count, "image")) in the Trash.", failed: moved.count < others.count)
    }

    func keepOldest(_ group: DuplicateGroup) async {
        guard store.busy == nil else { return }
        let keeper = group.keeper
        store.busy = "Comparing copies of \(keeper.name)"
        let others = await Task.detached { Duplicates.stillSame(group) }.value
        store.busy = nil
        guard !others.isEmpty else {
            store.message = Store.Message(text: "The copies of \(keeper.name) changed since the scan; Rescan to compare them again.", failed: true)
            return
        }
        guard allowed(others.map(\.url)),
              Alerts.confirm("Move \(Store.counted(others.count, "copy", "copies")) of \(keeper.name) to the Trash?",
                             "\(Store.bytes(group.size * Int64(others.count))). \((keeper.url.path as NSString).abbreviatingWithTildeInPath) stays.\n\n"
                                 + Alerts.lines(others.map { ($0.url.path as NSString).abbreviatingWithTildeInPath }),
                             button: "Move to Trash") else { return }
        var moved: [LargeFile] = []
        var trashed: [Trashed] = []
        for file in others {
            var binned: NSURL?
            guard (try? FileManager.default.trashItem(at: file.url, resultingItemURL: &binned)) != nil else { continue }
            moved.append(file)
            if let binned { trashed.append(Trashed(original: file.url, inTrash: binned as URL)) }
        }
        let gone = Set(moved.map(\.id))
        duplicates = duplicates.compactMap { group in
            var group = group
            group.files.removeAll { gone.contains($0.id) }
            return group.files.count > 1 ? group : nil
        }
        monitor.readDisk()
        store.record(.files, "Copies of \(keeper.name)", freed: moved.reduce(0) { $0 + $1.size }, trashed: trashed)
        store.message = Store.Message(text: "\(moved.count) of \(Store.counted(others.count, "copy", "copies")) in the Trash.", failed: moved.count < others.count)
    }

    private func drop(_ ids: Set<String>) {
        similar = similar?.compactMap { group in
            var group = group
            group.files.removeAll { ids.contains($0.id) }
            return group.files.count > 1 ? group : nil
        }
    }

    // MARK: Developer

    /// Stale project dependencies and local AI models: both walk folders,
    /// so they run off the main actor.
    func scanDeveloper() async {
        guard !scanningDeveloper else { return }
        scanningDeveloper = true
        defer { scanningDeveloper = false }
        let home = NSHomeDirectory()
        async let stale = Task.detached(priority: .utility) {
            let found = ProjectDependencies.find(roots: ProjectDependencies.roots(home: home))
            let running = Set(ProjectDependencies.running(found, commands: Monitor.commands()).map(\.id))
            return found.filter { !running.contains($0.id) }
        }.value
        async let found = Task.detached(priority: .utility) { AIModels.find(home: home) }.value
        (dependencies, models) = await (stale, found)
        applyIgnoreList()
    }

    func trashDependencies(_ folders: [LargeFile]) async {
        guard store.busy == nil, !folders.isEmpty, allowed(folders.map(\.url)) else { return }
        // A project may have started since the scan, or have a shell open in it.
        let cwds = (try? await ProcessRunner(timeout: 10).run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-Fcn"], env: [:]))?.output ?? ""
        let running = ProjectDependencies.running(folders, commands: await Task.detached { Monitor.commands() }.value)
            + folders.filter { !OpenFile.workingIn($0.url.deletingLastPathComponent().path, cwds).isEmpty }
        if !running.isEmpty {
            let ids = Set(running.map(\.id))
            dependencies.removeAll { ids.contains($0.id) }
            store.message = Store.Message(text: "\(Store.counted(ids.count, "project")) in use now; "
                                              + "\(ids.count == 1 ? "its" : "their") dependencies stay.", failed: false)
            return
        }
        let total = folders.reduce(0) { $0 + $1.size }
        guard Alerts.confirm("Move \(Store.counted(folders.count, "dependency folder")) to the Trash?",
                             "\(Store.bytes(total)). The next install in each project brings them back.\n\n"
                                 + Alerts.lines(folders.map { ($0.url.path as NSString).abbreviatingWithTildeInPath }),
                             button: "Move to Trash") else { return }
        store.busy = "Moving dependencies to the Trash"
        defer { store.busy = nil }
        let (failure, trashed) = await recycle(folders.map(\.url))
        let gone = Set(folders.map(\.id))
        dependencies.removeAll { gone.contains($0.id) && !FileManager.default.fileExists(atPath: $0.url.path) }
        if failure == nil { store.record(.developer, "Project Dependencies", freed: total, trashed: trashed) }
        store.message = failure.map { Store.Message(text: $0, failed: true) }
            ?? Store.Message(text: "\(Store.bytes(total)) of dependencies are in the Trash.", failed: false)
        monitor.readDisk()
    }

    func trash(_ model: AIModel) async {
        guard store.busy == nil, allowed(model.paths), Alerts.confirm("Move \(model.name) to the Trash?",
                                                "\(Store.bytes(model.size)) of \(model.source.rawValue) model files. "
                                                    + "Pulling the model again downloads it.",
                                                button: "Move to Trash") else { return }
        store.busy = "Removing \(model.name)"
        defer { store.busy = nil }
        let (failure, trashed) = await recycle(model.paths)
        if let failure {
            store.message = Store.Message(text: "\(model.name): \(failure)", failed: true)
        } else {
            models.removeAll { $0.id == model.id }
            store.record(.developer, model.name, freed: model.size, trashed: trashed)
            store.message = Store.Message(text: "\(model.name) is in the Trash.", failed: false)
        }
        monitor.readDisk()
    }

    // MARK: Recommendations

    struct Recommendation: Identifiable {
        let symbol: String
        let title: String
        let module: Module
        var id: String { title }
    }

    /// What the last scan found worth doing, for My Activity.
    var recommendations: [Recommendation] {
        var r: [Recommendation] = []
        if scannedAt.map({ Date.now.timeIntervalSince($0) > 7 * 86400 }) ?? true {
            r.append(Recommendation(symbol: "sparkles", title: "Run Smart Care: no scan this week", module: .smartCare))
        }
        if junk > 500_000_000 { r.append(Recommendation(symbol: "trash.fill", title: "Clean \(Store.bytes(junk)) of system junk", module: .cleanup)) }
        if ai > 200_000_000 { r.append(Recommendation(symbol: "brain.head.profile", title: "Clear \(Store.bytes(ai)) of AI clutter", module: .cleanup)) }
        let outdated = store.snapshot?.outdated.count ?? 0
        if outdated > 0 { r.append(Recommendation(symbol: "arrow.down.circle.fill", title: "Update " + Store.counted(outdated, "package"), module: .apps)) }
        let findings = store.findings.count
        if findings > 0 { r.append(Recommendation(symbol: "stethoscope", title: findings == 1 ? "Look at 1 health finding" : "Look at \(findings) health findings", module: .smartCare)) }
        if !untrusted.isEmpty {
            r.append(Recommendation(symbol: "exclamationmark.shield.fill", title: "Check \(Store.counted(untrusted.count, "app")) Gatekeeper rejects", module: .protection))
        }
        let idle = dependencies.reduce(0) { $0 + $1.size }
        if idle > 1_000_000_000 {
            r.append(Recommendation(symbol: "shippingbox.fill", title: "Remove \(Store.bytes(idle)) of idle dependencies", module: .developer))
        }
        if clutter > 1_000_000_000 { r.append(Recommendation(symbol: "doc.on.doc.fill", title: "Review \(Store.bytes(clutter)) of large files", module: .clutter)) }
        if !unused.isEmpty { r.append(Recommendation(symbol: "square.grid.2x2.fill", title: "Uninstall \(Store.counted(unused.count, "unused app"))", module: .apps)) }
        let broken = agents.filter(\.broken).count
        if broken > 0 { r.append(Recommendation(symbol: "bolt.slash.fill", title: "Remove " + Store.counted(broken, "broken launch agent"), module: .performance)) }
        if startup.count > 10 { r.append(Recommendation(symbol: "power", title: "Review \(startup.count) login items", module: .performance)) }
        return r
    }

    /// Opens a module, past its intro, scanning what it shows if nothing has.
    func open(_ m: Module) {
        module = m
        if showsIntro(m) { Task { await enter(m) } }
    }

    // MARK: AI Clutter

    func scanAI() async {
        scanningAI = true
        defer { scanningAI = false }
        let home = NSHomeDirectory()
        let temp = "/private/tmp/claude-\(getuid())"
        let open = monitor.runningApps()
        aiJunk = await Task.detached(priority: .utility) {
            AIClutter.find(home: home, claudeTemp: temp, open: open, commands: Monitor.commands())
        }.value
        applyIgnoreList()
    }

    /// Deletes the picked junk for good, as Cleanup clears caches: each tool
    /// makes it again when it needs it.
    func cleanAI(_ picked: [AIJunk]) async {
        guard store.busy == nil, !picked.isEmpty else { return }
        let total = picked.reduce(0) { $0 + $1.size }
        let list = picked.map { "\($0.tool), \($0.kind): \(Store.bytes($0.size))" }.joined(separator: "\n")
            + "\n\n" + Alerts.lines(picked.flatMap(\.paths).map { ($0.path as NSString).abbreviatingWithTildeInPath })
        guard Alerts.confirm("Clear \(Store.bytes(total)) of AI clutter?",
                             list + "\n\nChats, settings, sessions and whatever is running stay.",
                             button: "Clear") else { return }
        store.busy = "Clearing AI clutter"
        defer { store.busy = nil }
        let home = NSHomeDirectory()
        let temp = "/private/tmp/claude-\(getuid())"
        let ignored = store.ignoreList
        let open = monitor.runningApps()
        let stuck = await Task.detached {
            AIClutter.stillJunk(picked, in: AIClutter.find(home: home, claudeTemp: temp, open: open, commands: Monitor.commands()))
                .filter { !ignored.covers($0) }
                .filter { (try? FileManager.default.removeItem(at: $0)) == nil }.count
        }.value
        await scanAI()
        let freed = max(total - picked.reduce(0) { sum, p in sum + (aiJunk.first { $0.id == p.id }?.size ?? 0) }, 0)
        store.record(.ai, picked.count == 1 ? picked[0].tool : "AI Clutter", freed: freed)
        monitor.readDisk()
        store.message = Store.Message(text: "AI clutter: freed \(Store.bytes(freed))" + (stuck > 0 ? "; \(stuck) in use stayed." : "."),
                                      failed: false)
    }

    // MARK: Applications

    /// Lists the apps, then fills in sizes and last use as each is read.
    func loadApps() async {
        loadingApps = true
        defer { loadingApps = false }
        await store.connected()
        var caskApps: [String: String] = [:]
        if let brew = store.program("brew"),
           let r = try? await ProcessRunner(timeout: 120).run(brew, ["info", "--json=v2", "--installed", "--cask"], env: store.loginEnv) {
            caskApps = AppCatalog.caskApps(brewInfo: r.stdout)
        }
        let items = (try? await store.cli?.items()) ?? []
        self.items = items
        if casks.isEmpty { casks = await Task.detached { Self.readCaskIndex() }.value }
        let folder = URL(fileURLWithPath: "/Applications")
        let found = await Task.detached { AppCatalog.apps(in: folder, caskApps: caskApps, items: items) }.value
        let old = Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        apps = found.map { app in
            var app = app
            app.size = old[app.id]?.size
            app.lastUsed = old[app.id]?.lastUsed
            app.added = old[app.id]?.added
            return app
        }
        applyIgnoreList()
        for app in apps where icons[app.id] == nil {
            icons[app.id] = NSWorkspace.shared.icon(forFile: app.url.path)
        }
        // An open app is in use now, whatever Spotlight recorded.
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.standardizedFileURL.path })
        await withTaskGroup(of: (String, Int64, Date?, Date?).self) { group in
            for url in found.map(\.url) {
                group.addTask(priority: .utility) {
                    let item = NSMetadataItem(url: url)
                    let used = item?.value(forAttribute: "kMDItemLastUsedDate") as? Date
                    let added = item?.value(forAttribute: "kMDItemDateAdded") as? Date
                    return (url.path, DiskUsage.allocated(url), used, added)
                }
            }
            for await (id, size, used, added) in group {
                guard let i = apps.firstIndex(where: { $0.id == id }) else { continue }
                apps[i].size = size
                apps[i].lastUsed = running.contains(URL(fileURLWithPath: id).standardizedFileURL.path) ? .now : used
                apps[i].added = added
            }
        }
    }

    /// Removes the app and what it left in the Library. A Brewfile app goes
    /// through zc-care remove, which drops it from the manifest too;
    /// the rest go to the Trash, where they can be put back.
    func uninstall(_ app: InstalledApp) async {
        guard store.busy == nil, allowed([app.url]), canTouch(app) else { return }
        // What the ignore list names stays behind; the rest still goes.
        let leftovers = Leftovers.paths(bundleID: app.bundleID, name: app.name, home: NSHomeDirectory())
            .filter { !store.ignoreList.covers($0) }
        let method = Uninstall.method(declared: app.declared, source: app.source)
        var how: String
        switch method {
        case .remove(_, let resource): how = "zc-care removes \(resource) and drops it from the Brewfile."
        case .cask(let token): how = "Homebrew uninstalls the cask \(token)."
        case .trash: how = "The app moves to the Trash."
        }
        if !leftovers.isEmpty {
            how += "\n\nIts files move to the Trash:\n" + Alerts.lines(leftovers.map { ($0 as NSString).abbreviatingWithTildeInPath })
        }
        // Again: the app may have opened while the alert was up.
        guard Alerts.confirm("Uninstall \(app.name)?", how, button: "Uninstall"), canTouch(app) else { return }
        store.busy = "Uninstalling \(app.name)"
        defer { store.busy = nil }
        var failure: String?
        var trashed: [Trashed] = []
        switch method {
        case .remove(let target, let resource):
            if let cli = store.cli {
                let r = try? await cli.run(["remove", "-target", target, resource])
                if r?.status != 0 { failure = lastLine(r?.stderr) ?? "remove failed" }
            } else {
                failure = "zc-care is not installed"
            }
        case .cask(let token):
            if let brew = store.program("brew") {
                let r = try? await ProcessRunner().run(brew, ["uninstall", "--cask", token], env: store.loginEnv)
                if r?.status != 0 { failure = lastLine(r?.stderr) ?? "brew uninstall failed" }
            } else {
                failure = "Homebrew is not installed"
            }
        case .trash:
            (failure, trashed) = await recycle([app.url])
        }
        if failure == nil, !leftovers.isEmpty {
            await bootOut(Leftovers.agents(in: leftovers))
            let left: [Trashed]
            (failure, left) = await recycle(leftovers.map(URL.init(fileURLWithPath:)))
            trashed += left
        }
        if let failure {
            store.message = Store.Message(text: "\(app.name): \(failure)", failed: true)
        } else {
            apps.removeAll { $0.id == app.id }
            // Only an app that went to the Trash comes back whole; a
            // Homebrew or zc-care removal has nothing there to restore.
            store.record(.apps, app.name, freed: app.size ?? 0, trashed: trashed.isEmpty ? nil : trashed)
            store.message = Store.Message(text: "\(app.name) is uninstalled.", failed: false)
        }
        monitor.readDisk()
    }

    /// Not ZC Care itself, and not while the app runs: it would write its
    /// files straight back.
    /// Stops the agents so they do not run on from the Trash.
    private func bootOut(_ agents: [String]) async {
        for agent in agents {
            _ = try? await ProcessRunner(timeout: 10).run("/bin/launchctl", ["bootout", "gui/\(getuid())", agent], env: [:])
        }
    }

    private func canTouch(_ app: InstalledApp) -> Bool {
        if app.bundleID == Bundle.main.bundleIdentifier {
            store.message = Store.Message(text: "ZC Care cannot do that to itself.", failed: true)
            return false
        }
        // By id too: a copy running from elsewhere uses the same settings.
        if NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleURL?.standardizedFileURL == app.url.standardizedFileURL || ($0.bundleIdentifier != nil && $0.bundleIdentifier == app.bundleID)
        }) {
            store.message = Store.Message(text: "Quit \(app.name) first.", failed: true)
            return false
        }
        return true
    }

    /// The app as on its first launch: its settings, caches and data go to
    /// the Trash, and the app stays.
    func reset(_ app: InstalledApp) async {
        guard store.busy == nil, canTouch(app) else { return }
        let data = Leftovers.paths(bundleID: app.bundleID, name: app.name, home: NSHomeDirectory())
            .filter { !store.ignoreList.covers($0) }
        guard !data.isEmpty else {
            store.message = Store.Message(text: "\(app.name) keeps no settings or data to reset.", failed: false)
            return
        }
        let urls = data.map(URL.init(fileURLWithPath:))
        guard Alerts.confirm("Reset \(app.name)?",
                                            "It opens as on its first launch. These move to the Trash:\n"
                                                + Alerts.lines(data.map { ($0 as NSString).abbreviatingWithTildeInPath }),
                                            button: "Reset"), canTouch(app) else { return }
        store.busy = "Resetting \(app.name)"
        defer { store.busy = nil }
        await bootOut(Leftovers.agents(in: data))
        let (failure, trashed) = await recycle(urls)
        // cfprefsd keeps the settings in memory and would write them back.
        _ = try? await ProcessRunner(timeout: 10).run("/usr/bin/killall", ["cfprefsd"], env: [:])
        if let failure {
            store.message = Store.Message(text: "\(app.name): \(failure)", failed: true)
        } else {
            store.record(.apps, "Reset \(app.name)", trashed: trashed)
            store.message = Store.Message(text: "\(app.name) is reset.", failed: false)
        }
    }

    // MARK: Leftovers

    /// Library entries named for apps Launch Services no longer knows. A
    /// launch agent or a running process with the id is no leftover: tools
    /// without an app bundle keep their settings under it too.
    func loadOrphans() async {
        guard !loadingOrphans else { return }
        loadingOrphans = true
        defer { loadingOrphans = false }
        let home = NSHomeDirectory()
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        orphans = await Task.detached(priority: .utility) {
            let folders = [home + "/Library/LaunchAgents", "/Library/LaunchAgents", "/Library/LaunchDaemons"]
            let inUse = running.union(LaunchAgent.read(folders: folders).map(\.label))
            let apps = ["/Applications", "/Applications/Utilities", home + "/Applications"].flatMap { folder in
                ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.hasSuffix(".app") }
                    .map { folder + "/" + $0 }
            }
            let vendors = Set(apps.compactMap { Bundle(path: $0)?.bundleIdentifier }.map(Leftovers.vendor))
            return Leftovers.orphans(home: home, vendors: vendors) {
                inUse.contains($0) || NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
            }
        }.value
        applyIgnoreList()
    }

    func trashOrphans(_ picked: [Orphan]) async {
        guard store.busy == nil, !picked.isEmpty,
              allowed(picked.flatMap(\.paths).map { URL(fileURLWithPath: $0) }) else { return }
        let total = picked.reduce(0) { $0 + $1.size }
        guard Alerts.confirm("Move what \(Store.counted(picked.count, "removed app")) left to the Trash?",
                             "\(Store.bytes(total)) in caches, settings and support files:\n\n"
                                 + Alerts.lines(picked.map(\.bundleID), max: 10),
                             button: "Move to Trash") else { return }
        store.busy = "Removing leftovers"
        defer { store.busy = nil }
        let (failure, trashed) = await recycle(picked.flatMap { $0.paths.map(URL.init(fileURLWithPath:)) })
        let gone = Set(picked.map(\.id))
        orphans?.removeAll { o in gone.contains(o.id) && !o.paths.contains(where: FileManager.default.fileExists) }
        if failure == nil { store.record(.apps, "App Leftovers", freed: total, trashed: trashed) }
        store.message = failure.map { Store.Message(text: $0, failed: true) }
            ?? Store.Message(text: "Leftovers of \(Store.counted(picked.count, "app")) are in the Trash.", failed: false)
        monitor.readDisk()
    }

    // MARK: Adopting

    private var items: [Item] = []

    private nonisolated static func readCaskIndex() -> [String: String] {
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Homebrew/api/internal")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []
        guard let name = files.first(where: { $0.hasPrefix("packages.") && $0.hasSuffix(".jws.json") }),
              let data = try? Data(contentsOf: cache.appendingPathComponent(name)) else { return [:] }
        return CaskIndex.apps(jws: data)
    }

    /// Hands an app installed by hand to Homebrew, which takes over the copy
    /// in place, and declares the cask so the Brewfile knows it.
    func adopt(_ app: InstalledApp) async {
        guard store.busy == nil, let token = casks[app.url.lastPathComponent],
              let brew = store.program("brew"), let cli = store.cli else { return }
        guard let target = CaskIndex.target(items: items) else {
            store.message = Store.Message(text: "No target declares casks to adopt \(app.name) into.", failed: true)
            return
        }
        guard Alerts.confirm("Adopt \(app.name) as cask \(token)?",
                             "Homebrew takes over the app in /Applications, and zc-care adds cask:\(token) to the \(target) target.",
                             button: "Adopt") else { return }
        store.busy = "Adopting \(app.name)"
        defer { store.busy = nil }
        let install = try? await ProcessRunner().run(brew, ["install", "--cask", "--adopt", token], env: store.loginEnv)
        guard install?.status == 0 else {
            store.message = Store.Message(text: "\(app.name): \(lastLine(install?.stderr) ?? "brew install failed")", failed: true)
            return
        }
        let add = try? await cli.run(["add", "-target", target, "-why", "Adopted from /Applications by ZC Care", "cask:" + token])
        store.message = add?.status == 0
            ? Store.Message(text: "\(app.name) is now cask \(token) in \(target).", failed: false)
            : Store.Message(text: "Homebrew adopted \(app.name), but add failed: \(lastLine(add?.stderr) ?? "")", failed: true)
        await loadApps()
    }

    /// Moves to the Trash; the Finder asks for a password when the app
    /// belongs to the system, as App Store apps do.
    private func recycle(_ urls: [URL]) async -> (failure: String?, trashed: [Trashed]) {
        do {
            let moved = try await NSWorkspace.shared.recycle(urls)
            return (nil, moved.map { Trashed(original: $0.key, inTrash: $0.value) })
        } catch {
            return (error.localizedDescription, [])
        }
    }

    private func lastLine(_ text: String?) -> String? {
        text?.split(whereSeparator: \.isNewline).last.map(String.init)
    }

    // MARK: Performance

    private var domain: String { "gui/\(getuid())" }

    func loadAgents() async {
        let home = NSHomeDirectory()
        var found = await Task.detached {
            LaunchAgent.read(folders: [home + "/Library/LaunchAgents", "/Library/LaunchAgents"])
        }.value
        async let disabledOut = try? ProcessRunner(timeout: 30).run("/bin/launchctl", ["print-disabled", domain], env: [:])
        async let listOut = try? ProcessRunner(timeout: 30).run("/bin/launchctl", ["list"], env: [:])
        let disabled = Launchd.parseDisabled(await disabledOut?.output ?? "")
        let running = Launchd.parseRunning(await listOut?.output ?? "")
        for i in found.indices {
            if let off = disabled[found[i].label] { found[i].enabled = !off }
            found[i].running = running.contains(found[i].label)
        }
        // Broken ones first: they are the ones to act on.
        agents = found.filter(\.broken) + found.filter { !$0.broken }
        readBackground()
    }

    /// Apps that run without a Dock icon, such as menu bar extras; macOS's
    /// own helpers are left out.
    func readBackground() {
        let me = Bundle.main.bundleIdentifier
        background = NSWorkspace.shared.runningApplications
            .filter { app in
                guard app.activationPolicy == .accessory, app.bundleIdentifier != me,
                      let path = app.bundleURL?.path else { return false }
                return !["/System/", "/usr/", "/Library/Apple/"].contains(where: path.hasPrefix)
            }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    /// Turns an agent off for good, or back on: launchctl's override
    /// outlives the plist, and the agent stops or starts now too.
    func setEnabled(_ agent: LaunchAgent, _ on: Bool) async {
        guard store.busy == nil else { return }
        if !on, managed(agent) {
            guard Alerts.confirm("Turn off \(agent.label)?",
                                 "Your zc-care config declares it, so this shows as drift and the next apply "
                                     + "turns it back on. To stop it for good, remove it from the config.",
                                 button: "Turn Off") else { return }
        }
        store.busy = "\(on ? "Enabling" : "Disabling") \(agent.label)"
        defer { store.busy = nil }
        var failed: String?
        for args in Launchd.toggleSteps(domain: domain, label: agent.label, plist: agent.path, on: on) {
            let r = try? await ProcessRunner(timeout: 30).run("/bin/launchctl", args, env: [:])
            if r?.status != 0, Launchd.mustSucceed(args) { failed = lastLine(r?.stderr) ?? "launchctl failed" }
        }
        store.message = failed.map { Store.Message(text: "\(agent.label): \($0)", failed: true) }
            ?? Store.Message(text: "\(agent.label) is \(on ? "on" : "off").", failed: false)
        await loadAgents()
    }

    func managed(_ agent: LaunchAgent) -> Bool {
        Launchd.managed(agent.label, services: store.snapshot?.services ?? [])
    }

    /// Boots out an agent whose program is gone and moves its plist to the
    /// Trash. Only the user's own: /Library's need an administrator.
    func remove(_ agent: LaunchAgent) async {
        guard store.busy == nil, agent.path.hasPrefix(NSHomeDirectory() + "/"), allowed([URL(fileURLWithPath: agent.path)]),
              Alerts.confirm("Remove \(agent.label)?",
                             "It runs \((agent.program as NSString).abbreviatingWithTildeInPath), which is gone. "
                                 + "Its plist moves to the Trash.", button: "Remove") else { return }
        store.busy = "Removing \(agent.label)"
        defer { store.busy = nil }
        await bootOut([agent.path])
        let (failure, trashed) = await recycle([URL(fileURLWithPath: agent.path)])
        if failure == nil { store.record(.maintenance, "Broken Launch Agent", freed: 0, trashed: trashed) }
        store.message = failure.map { Store.Message(text: "\(agent.label): \($0)", failed: true) }
            ?? Store.Message(text: "\(agent.label) is in the Trash.", failed: false)
        await loadAgents()
    }

    func quit(_ app: NSRunningApplication) {
        app.terminate()
        Task {
            try? await Task.sleep(for: .seconds(1))
            readBackground()
        }
    }

    // MARK: Maintenance

    func loadMaintenance() {
        let xcode = FileManager.default.fileExists(atPath: "/Applications/Xcode.app")
        maintenance = Maintenance.tasks(brew: store.program("brew"), docker: store.program("docker"), xcode: xcode)
    }

    /// Runs one task after asking; admin tasks go through osascript, which
    /// asks for the password itself.
    func run(_ task: MaintenanceTask) async {
        guard store.busy == nil,
              Alerts.confirm("\(task.title)?", task.detail + (task.admin ? "\n\nmacOS asks for your password." : ""),
                             button: "Run") else { return }
        store.busy = task.title
        defer { store.busy = nil }
        var failure: String?
        if task.admin {
            let r = try? await ProcessRunner().run("/usr/bin/osascript", ["-e", Maintenance.adminScript(task.steps)], env: [:])
            if r?.status != 0 { failure = lastLine(r?.stderr) ?? "osascript failed" }
        } else {
            for step in task.steps {
                let r = try? await ProcessRunner().run(step[0], Array(step.dropFirst()), env: store.loginEnv)
                if r?.status != 0 { failure = lastLine(r?.stderr) ?? "\(step[0]) failed"; break }
            }
        }
        if failure == nil { store.record(.maintenance, task.title) }
        store.message = failure.map { Store.Message(text: "\(task.title): \($0)", failed: true) }
            ?? Store.Message(text: "\(task.title): done.", failed: false)
        monitor.readDisk()
    }

    // MARK: Protection

    /// How Gatekeeper sees each app, and the privacy permissions apps
    /// hold, all read-only.
    func loadProtection() async {
        guard !loadingProtection else { return }
        loadingProtection = true
        defer { loadingProtection = false }
        if apps.isEmpty { await loadApps() }
        async let status = try? ProcessRunner(timeout: 30).run("/usr/sbin/spctl", ["--status"], env: [:])
        async let tcc = readPermissions()
        gatekeeper = await status.map { $0.output.contains("assessments enabled") }
        permissions = await tcc
        await loadBrowserTraces()
        await withTaskGroup(of: (String, Assessment).self) { group in
            for app in apps where assessments[app.id] == nil {
                group.addTask {
                    let r = try? await ProcessRunner(timeout: 60).run("/usr/sbin/spctl", ["--assess", "-v", app.url.path], env: [:])
                    return (app.id, Assessment.parse(r?.stderr ?? ""))
                }
            }
            for await (id, a) in group { assessments[id] = a }
        }
    }

    func loadBrowserTraces() async {
        let home = NSHomeDirectory()
        browserTraces = await Task.detached(priority: .utility) { BrowserPrivacy.find(home: home) }.value
    }

    func isRunning(_ bundleID: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    /// Deletes one browser's history, cookies or cache, only while that
    /// browser is closed: an open one holds the databases and writes them back.
    func clearBrowser(_ trace: BrowserTrace) async {
        guard store.busy == nil else { return }
        guard !isRunning(trace.bundleID) else {
            store.message = Store.Message(text: "Quit \(trace.browser) first, then clear its \(trace.kind.lowercased()).", failed: true)
            return
        }
        let effect = switch trace.kind {
        case BrowserPrivacy.cookies: "You will be signed out of websites in \(trace.browser)."
        case BrowserPrivacy.history: "\(trace.browser) forgets the pages you visited; bookmarks and passwords stay."
        default: "\(trace.browser) downloads pages again as you visit them."
        }
        guard Alerts.confirm("Clear \(trace.browser)'s \(trace.kind.lowercased())?",
                             "This deletes \(Store.counted(trace.paths.count, "item")), \(Store.bytes(trace.size)).\n\n" + effect,
                             button: "Clear") else { return }
        store.busy = "Clearing \(trace.browser) \(trace.kind.lowercased())"
        defer { store.busy = nil }
        let stuck = await Task.detached { BrowserPrivacy.clear(trace) }.value
        await loadBrowserTraces()
        let left = browserTraces?.first { $0.id == trace.id }?.size ?? 0
        store.record(.privacy, "\(trace.browser) \(trace.kind)", freed: max(trace.size - left, 0))
        monitor.readDisk()
        store.message = Store.Message(text: "\(trace.browser) \(trace.kind.lowercased()) cleared" + (stuck > 0 ? "; " + Store.counted(stuck, "item") + " stayed." : "."),
                                      failed: stuck > 0)
    }

    /// What runs with the session, as Background Task Management keeps it.
    /// sfltool asks for an administrator's password when an app runs it,
    /// so this waits for a click.
    func loadBackgroundItems() async {
        guard !loadingBackground else { return }
        loadingBackground = true
        defer { loadingBackground = false }
        guard let r = try? await ProcessRunner(timeout: 120).run("/usr/bin/sfltool", ["dumpbtm"], env: [:]), r.status == 0 else {
            store.message = Store.Message(text: "Background items not read: the password was not given.", failed: true)
            return
        }
        backgroundItems = BackgroundItems.parse(r.output, uid: getuid())
            .sorted { ($0.developer ?? "~", $0.name) < ($1.developer ?? "~", $1.name) }
    }

    /// Nil without Full Disk Access: macOS keeps both databases from apps
    /// that lack it.
    private func readPermissions() async -> [Permission]? {
        let dbs = [NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db",
                   "/Library/Application Support/com.apple.TCC/TCC.db"]
        var rows: [Permission]?
        for db in dbs {
            guard let r = try? await ProcessRunner(timeout: 30).run("/usr/bin/sqlite3", ["-readonly", "-separator", "|", db, Privacy.query], env: [:]),
                  r.status == 0 else { continue }
            rows = (rows ?? []) + Privacy.parse(r.output)
        }
        return rows?.sorted { ($0.service, $0.client) < ($1.service, $1.client) }
    }

    func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:" + pane) { NSWorkspace.shared.open(url) }
    }

    // MARK: Space Lens

    private static let savedSpace = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("dev.zoolcoder.zccare/space.json")

    /// du over the home folder, three levels down, on this volume only: it
    /// takes minutes, so the last one stays on disk.
    func scanSpace() async {
        guard !scanningSpace else { return }
        scanningSpace = true
        defer { scanningSpace = false }
        let home = NSHomeDirectory()
        guard let r = try? await ProcessRunner(timeout: 900).run("/usr/bin/du", SpaceLens.arguments(root: home), env: [:]) else {
            store.message = Store.Message(text: "Space Lens took too long to measure \(home).", failed: true)
            return
        }
        let text = r.output
        guard let root = await Task.detached(operation: { SpaceLens.parse(du: text, root: home) }).value else {
            store.message = Store.Message(text: "Space Lens could not read \(home).", failed: true)
            return
        }
        let scan = SpaceScan(scannedAt: .now, root: root)
        space = scan
        try? scan.save(to: Self.savedSpace)
    }

    // MARK: Cloud Cleanup

    struct CloudScan: Identifiable {
        var drive: CloudDrive
        var downloaded: Int64
        var files: [LargeFile]

        var id: String { drive.id }
    }

    /// Cloud files from this size up are listed one by one.
    nonisolated static let cloudFile: Int64 = 50_000_000

    func scanCloud() async {
        guard !scanningCloud else { return }
        scanningCloud = true
        defer { scanningCloud = false }
        let drives = CloudDrives.found(home: FileManager.default.homeDirectoryForCurrentUser)
        let list = store.ignoreList
        cloud = await Task.detached(priority: .utility) {
            drives.map { drive in
                let found = CloudDrives.downloaded(in: drive.url, minimum: Self.cloudFile)
                return CloudScan(drive: drive, downloaded: found.total, files: list.keep(found.files))
            }
        }.value
    }

    /// Frees the space a downloaded file takes and keeps it in the cloud:
    /// the Finder downloads it again on opening.
    func removeDownload(_ file: LargeFile, from drive: CloudDrive) {
        guard store.busy == nil else { return }
        guard allowed([file.url]) else { return }
        guard FileManager.default.fileExists(atPath: file.url.path) else {
            dropCloudFile(file, from: drive, freed: 0)
            store.message = Store.Message(text: "\(file.name) moved or went since the scan.", failed: true)
            return
        }
        guard Alerts.confirm("Remove the download of \(file.name)?",
                             "It stays in \(drive.name) and downloads again when you open it. Frees \(Store.bytes(file.size)).",
                             button: "Remove Download") else { return }
        do {
            try FileManager.default.evictUbiquitousItem(at: file.url)
            dropCloudFile(file, from: drive, freed: file.size)
            monitor.readDisk()
            store.record(.cloud, file.name, freed: file.size)
            store.message = Store.Message(text: "\(file.name) is now in \(drive.name) only.", failed: false)
        } catch {
            // Only iCloud lets another app evict; the Finder can for every provider.
            NSWorkspace.shared.activateFileViewerSelecting([file.url])
            store.message = Store.Message(text: "\(drive.name) keeps \(file.name) itself: in the Finder, Control-click it and choose Remove Download.",
                                          failed: true)
        }
    }

    private func dropCloudFile(_ file: LargeFile, from drive: CloudDrive, freed: Int64) {
        guard let i = cloud?.firstIndex(where: { $0.id == drive.id }) else { return }
        cloud?[i].files.removeAll { $0.id == file.id }
        cloud?[i].downloaded -= freed
    }
}
