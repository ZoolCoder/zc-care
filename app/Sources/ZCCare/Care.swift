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
    /// Files came back from the Trash while a scan ran, which may not have seen them.
    private var rescanAfterScan = false
    /// Held from the first check to the end of a removal that asks first, so
    /// a second click cannot start the same flow while the first checks.
    private var removing = false
    /// The sheets the window shows for a removal: the last look at what
    /// goes, the apps to quit first, and how the run went.
    var review: Prompt<Review, Bool>?
    var quitRequest: Prompt<QuitRequest, Bool>?
    var completed: RunLog?
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
    /// Nil when Docker is not installed or its daemon does not answer.
    var docker: [DockerUsage]?
    var xcodeSpots: [XcodeSpot] = []
    /// Caches, logs, temp files and old versions AI tools leave.
    var aiJunk: [AIJunk] = []
    var scanningAI = false
    /// Preference files macOS cannot read, attachments Mail keeps beside
    /// online mail, and the Trash of each volume, for Cleanup.
    var brokenPrefs: [LargeFile] = []
    var mailAttachments: [LargeFile] = []
    var trashBins: [TrashBin] = []
    var scanningCleanup = false
    var scanningDeveloper = false
    /// Whether a developer scan has finished: before one, a nil `docker`
    /// means unknown, not down.
    var scannedDeveloper = false
    /// Nil until looked for: what removed apps left in the Library.
    var orphans: [Orphan]?
    var loadingOrphans = false
    /// Nil until read: the installer packages macOS keeps a receipt of.
    var receipts: [PackageReceipt]?
    var loadingReceipts = false
    var receiptsUnread = false
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
    var securityChecks: [SecurityCheck] = []
    /// Apps whose own update feed offers a newer release, and those whose
    /// feed could not be read; nil until checked.
    var feedUpdates: [AppUpdate]?
    var feedFailures: [String] = []
    var feedUnreadable: [String] = []
    var updatesCheckedAt: Date?
    var checkingUpdates = false
    /// The startup disk's health, its APFS volumes, the space macOS can
    /// purge on its own and the local Time Machine snapshots; nil until read.
    var diskHealth: DiskHealth?
    var containerSpace: ContainerSpace?
    var purgeable: Int64?
    var localSnapshots: [String] = []
    var loadingDisk = false
    /// Set to open Applications on its Updates list.
    var showUpdates = false
    /// Set to open Applications on its Leftovers list.
    var showLeftovers = false
    /// Apps a notification said were removed: Leftovers lists what they
    /// left even when their vendor has another app installed.
    var removedIDs: Set<String> = []
    /// Asks Space Lens to open on the startup disk rather than the home folder.
    var showStartupDisk = false
    /// When the startup disk was last read, failed or not.
    var diskReadAt: Date?
    var protectionCheckedAt: Date?
    /// Nil until read; the TCC databases need Full Disk Access.
    var permissions: [Permission]?
    /// Why the permissions could not be read, when it was not Full Disk Access.
    var permissionsError: String?
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
    /// Ids of Setapp and other-volume apps, read once per scan.
    var externalIDs: Set<String> = []
    var loadingApps = false
    var icons: [String: NSImage] = [:]
    var agents: [LaunchAgent] = []
    /// When each launch agent and background item first appeared.
    var sightings = Sightings.load(from: Care.savedSightings)
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
    /// Past this many groups a list is too long to review.
    static let duplicateGroups = 500
    /// Mail attachments under this are not worth the row.
    nonisolated static let mailAttachment: Int64 = 1_000_000

    init(store: Store) {
        self.store = store
        restore()
        store.ignoreListChanged = { [weak self] in self?.applyIgnoreList() }
        // Files back from the Trash belong in the lists again.
        store.putBackDone = { [weak self] in
            guard let self else { return }
            if scanning { rescanAfterScan = true } else { Task { await self.scan() } }
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
        models.removeAll { $0.paths.contains(where: list.touches) }
        apps.removeAll { list.touches($0.url) }
        orphans = orphans?.filter { !$0.paths.contains(where: list.touches) }
        aiJunk.removeAll { $0.paths.contains(where: list.touches) }
        cloud = cloud?.map { scan in
            var scan = scan
            scan.files = list.keep(scan.files)
            return scan
        }
    }

    /// The last check before a change: nothing on the ignore list goes.
    private func allowed(_ urls: [URL]) -> Bool {
        guard let hit = urls.first(where: store.ignoreList.touches) else { return true }
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
    var adoptable: [InstalledApp] { apps.filter(canAdopt) }
    /// Homebrew adopts a copy in /Applications only; one in ~/Applications
    /// would get a second, new copy beside it.
    func canAdopt(_ app: InstalledApp) -> Bool {
        app.inApplications && app.declared == nil && app.source == .other && casks[app.url.lastPathComponent] != nil
    }
    var untrusted: [InstalledApp] { apps.filter { assessments[$0.id].map { !$0.trusted } ?? false } }
    /// A second copy in ~/Applications is flagged as such, not as missing from the Brewfile.
    var undeclared: [InstalledApp] {
        let copies = copies
        return apps.filter { $0.declared == nil && !(copies.contains($0.id) && !$0.inApplications) }
    }
    var unused: [InstalledApp] { apps.filter { $0.unused() } }
    var intelOnly: [InstalledApp] { apps.filter { $0.intelOnly == true } }
    var copies: Set<String> { AppCatalog.copies(apps) }
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
            async let rest: Void = scanCleanup()
            _ = await (junk, ai, rest)
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
        defer {
            scanning = false
            if rescanAfterScan {
                rescanAfterScan = false
                Task { await scan() }
            }
        }
        await store.connected()
        async let junk: Void = monitor.scan()
        async let state: Void = store.refresh()
        async let files: Void = scanFiles()
        async let apps: Void = loadApps()
        async let agents: Void = loadAgents()
        async let developer: Void = scanDeveloper()
        async let ai: Void = scanAI()
        async let disk: Void = loadDisk()
        _ = await (junk, state, files, apps, agents, developer, ai, disk)
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
                                                findings: store.findings.count, drive: diskHealth))
    }

    /// Smart Care's Run: cleans up, then updates, each after its question.
    func run() async {
        if junk > 0 { await store.cleanAll() }
        if ai > 0 { await cleanAI(aiJunk) }
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
        guard let paths = await spotlight(args, for: "Large files") else {
            scanningFiles = false
            return
        }
        let downloads = URL(fileURLWithPath: home + "/Downloads")
        let installers = [downloads, URL(fileURLWithPath: home + "/Desktop")]
        let same = Task.detached(priority: .utility) { Duplicates.groups(paths: paths, home: home, minimum: Self.duplicateFile, limit: .max) }
        async let large = Task.detached { LargeFiles.files(paths: paths, home: home, minimum: Self.largeFile) }.value
        async let old = Task.detached { OldDownloads.files(in: downloads) }.value
        async let images = Task.detached { DiskImages.files(in: installers) }.value
        (largeFiles, oldDownloads, diskImages) = await (large, old, images)
        // Something trashed while the scan ran must not come back.
        let exists = { (file: LargeFile) in FileManager.default.fileExists(atPath: file.url.path) }
        largeFiles = largeFiles.filter(exists)
        oldDownloads = oldDownloads.filter(exists)
        diskImages = diskImages.filter(exists)
        applyIgnoreList()
        scanningFiles = false
        findingDuplicates = true
        defer { findingDuplicates = false }
        // Capped once ignored and vanished copies are out, so they take no place.
        duplicates = Array(store.ignoreList.keep(await same.value).compactMap { group in
            var group = group
            group.files.removeAll { !FileManager.default.fileExists(atPath: $0.url.path) }
            return group.files.count > 1 ? group : nil
        }.prefix(Self.duplicateGroups))
    }

    /// The paths Spotlight finds; nil, with why in a message, when mdfind fails.
    private func spotlight(_ args: [String], for what: String) async -> [String]? {
        do {
            let r = try await ProcessRunner(timeout: 120).run("/usr/bin/mdfind", args, env: [:])
            guard r.status == 0 else { throw CLIError(message: lastLine(r.stderr) ?? "mdfind exited \(r.status)") }
            return r.output.split(whereSeparator: \.isNewline).map(String.init)
        } catch {
            store.message = Store.Message(text: "\(what) not scanned: \(error.localizedDescription)", failed: true)
            return nil
        }
    }

    /// Whether something has any of the files open, which then stay put; a
    /// disk image a VM runs from or a video in an editor. Apps are offered
    /// to quit in a sheet; a command that is no app is named.
    private func openInApp(_ urls: [URL]) async -> Bool {
        guard let r = try? await ProcessRunner(timeout: 10).run("/usr/sbin/lsof", ["+c", "0", "-Fc", "--"] + urls.map(\.path), env: [:]) else { return false }
        let holders = OpenFile.holders(r.output)
        guard !holders.isEmpty else { return false }
        let apps = NSWorkspace.shared.runningApplications.filter { app in
            holders.contains(app.localizedName ?? "") || holders.contains(app.executableURL?.lastPathComponent ?? "")
        }
        let what = urls.count == 1 ? "\(urls[0].lastPathComponent) is" : "\(Store.counted(urls.count, "of these files")) may be"
        if apps.count < holders.count, let command = holders.first(where: { name in !apps.contains { $0.localizedName == name || $0.executableURL?.lastPathComponent == name } }) {
            store.message = Store.Message(text: "\(what) open in \(command). Close it first.", failed: true)
            return true
        }
        let name = urls.count == 1 ? urls[0].lastPathComponent : Store.counted(urls.count, "file")
        return await !closed(apps, toDo: "remove \(name)")
    }

    // MARK: Sheets

    /// Shows what a removal is about to do, and waits for the answer.
    func confirm(_ review: Review) async -> Bool {
        await withCheckedContinuation { continuation in
            self.review = Prompt(review) { [weak self] ok in
                self?.review = nil
                continuation.resume(returning: ok)
            }
        }
    }

    /// Lists the apps in the way with Quit and Force Quit, and waits until
    /// they are gone or the user skips. True when none is left running.
    func closed(_ apps: [NSRunningApplication], toDo what: String) async -> Bool {
        let running = apps.filter { !$0.isTerminated }
        guard !running.isEmpty else { return true }
        return await withCheckedContinuation { continuation in
            quitRequest = Prompt(QuitRequest(apps: running, toDo: what)) { [weak self] ok in
                self?.quitRequest = nil
                continuation.resume(returning: ok)
            }
        }
    }

    /// Not ZC Care itself, and not while the app runs: it would write its
    /// files straight back. A running copy is offered to quit.
    private func closed(_ app: InstalledApp, toDo what: String) async -> Bool {
        if app.bundleID == Bundle.main.bundleIdentifier {
            store.message = Store.Message(text: "ZC Care cannot do that to itself.", failed: true)
            return false
        }
        // By id too: a copy running from elsewhere uses the same settings.
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.bundleURL?.standardizedFileURL == app.url.standardizedFileURL || ($0.bundleIdentifier != nil && $0.bundleIdentifier == app.bundleID)
        }
        return await closed(running, toDo: what)
    }

    /// Shows how a run went, and logs what went for My Activity.
    private func finish(_ log: RunLog, kind: ActivityEntry.Kind, trashed: [Trashed]) {
        var log = log
        log.end()
        if !log.done.isEmpty || !trashed.isEmpty {
            store.record(kind, log.title, freed: log.freed, trashed: trashed)
        }
        monitor.readDisk()
        store.message = nil
        completed = log
    }

    /// Removes the files picked in a list, each on its own, after a last look.
    func trashFiles(_ files: [LargeFile], title: String) async {
        guard store.busy == nil, !removing, !files.isEmpty, allowed(files.map(\.url)) else { return }
        removing = true
        defer { removing = false }
        guard await !openInApp(files.map(\.url)), store.busy == nil else { return }
        let review = Review(title: store.removeQuestion(Store.counted(files.count, "file")), items: files.map(ReviewItem.init),
                            button: store.removeButton)
        guard await confirm(review), store.busy == nil else { return }
        store.busy = "Removing \(Store.counted(files.count, "file"))"
        defer { store.busy = nil }
        let (log, trashed) = await removeEach(files, title: title)
        forget(Set(log.done.map(\.path)))
        finish(log, kind: .files, trashed: trashed)
    }

    /// Drops files that went from every list that showed them.
    private func forget(_ ids: Set<String>) {
        largeFiles.removeAll { ids.contains($0.id) }
        oldDownloads.removeAll { ids.contains($0.id) }
        brokenPrefs.removeAll { ids.contains($0.id) }
        mailAttachments.removeAll { ids.contains($0.id) }
        diskImages.removeAll { ids.contains($0.id) }
        dependencies.removeAll { ids.contains($0.id) }
        duplicates = duplicates.compactMap { group in
            var group = group
            group.files.removeAll { ids.contains($0.id) }
            return group.files.count > 1 ? group : nil
        }
        drop(ids)
        if let scan = space {
            let shown = ids.filter { scan.root.find($0) != nil }
            guard !shown.isEmpty else { return }
            space?.root = shown.reduce(scan.root) { $0.removing($1) }
            try? space?.save(to: Self.savedSpace)
        }
    }

    /// The working directory of every process, from lsof. Nil, with a
    /// message, when lsof fails: what is in use is then unknown, and
    /// nothing may be taken for unused.
    private func workingDirectories() async -> String? {
        let r = try? await ProcessRunner(timeout: 10).run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-Fcn"], env: [:])
        guard let output = r?.output, !output.isEmpty else {
            store.message = Store.Message(text: "Could not tell which folders are in use (lsof failed). Nothing was removed.", failed: true)
            return nil
        }
        return output
    }

    /// `within` names the folder a Space Lens pick must still be safe in:
    /// its saved tree may be days old, and a part of the path a symlink since.
    func trash(_ file: LargeFile, within home: String? = nil) async {
        // Mail keeps indexing its attachments while it runs.
        if file.url.path.hasPrefix(NSHomeDirectory() + "/Library/Mail/") {
            await trashMailAttachments([file])
            return
        }
        guard store.busy == nil, !removing, allowed([file.url]) else { return }
        removing = true
        defer { removing = false }
        guard await !openInApp([file.url]) else { return }
        // A folder from Space Lens: a project with a server or a shell in it.
        if (try? file.url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            guard let cwds = await workingDirectories() else { return }
            let using = OpenFile.workingIn(file.url.path, cwds)
            let commands = await Monitor.commands()
            if let app = using.first ?? (AIClutter.used(file.url, by: commands) ? "a running command" : nil) {
                store.message = Store.Message(text: "\(file.name) is in use by \(app). Stop it first.", failed: true)
                return
            }
        }
        // Space Lens sizes come from its saved scan; the folder may have grown since.
        var file = file
        if home != nil {
            let url = file.url
            file.size = await Task.detached(priority: .userInitiated) { DiskUsage.allocated(url) }.value
        }
        guard store.busy == nil, Alerts.confirm(store.removeQuestion(file.name),
                                                "\(Store.bytes(file.size)) in \(file.url.deletingLastPathComponent().path).",
                                                button: store.removeButton) else { return }
        if let home, !SpaceLens.canTrash(file.url.path, home: home) {
            store.message = Store.Message(text: "\(file.name) moved or became a link since the scan; Rescan first. Nothing was removed.", failed: true)
            return
        }
        store.busy = "Removing \(file.name)"
        defer { store.busy = nil }
        let removal = await remove([file.url])
        if removal.failures.isEmpty {
            forget([file.id])
            monitor.readDisk()
            store.record(.files, file.name, freed: file.size, trashed: removal.trashed)
            store.message = Store.Message(text: "\(file.name) is \(store.removed).", failed: false)
        } else {
            store.message = Store.Message(text: "\(file.name): \(removal.summary).", failed: true)
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
        guard let paths = await spotlight(args, for: "Similar images") else { return }
        similar = await Task.detached(priority: .utility) { SimilarImages.groups(paths: paths, home: home) }.value
        applyIgnoreList()
    }

    /// Moves every image but the best of a group to the Trash.
    func trashOthers(_ group: SimilarGroup) async {
        let others = group.others
        guard store.busy == nil, !removing else { return }
        removing = true
        defer { removing = false }
        guard allowed(others.map(\.url)), await !openInApp(others.map(\.url)), store.busy == nil,
              await confirm(Review(title: store.removeQuestion(Store.counted(others.count, "similar image")),
                                   note: "\(group.best.name) stays.", items: others.map(ReviewItem.init), button: store.removeButton)),
              store.busy == nil else { return }
        store.busy = "Removing similar images"
        defer { store.busy = nil }
        let (log, trashed) = await removeEach(others, title: "Similar to \(group.best.name)")
        drop(Set(log.done.map(\.path)))
        finish(log, kind: .files, trashed: trashed)
    }

    func keepOldest(_ group: DuplicateGroup) async {
        guard store.busy == nil, !removing else { return }
        removing = true
        defer { removing = false }
        let keeper = group.keeper
        let others = await stillSame(group)
        guard !others.isEmpty else {
            store.message = Store.Message(text: "The copies of \(keeper.name) changed since the scan; Rescan to compare them again.", failed: true)
            return
        }
        guard allowed(others.map(\.url)), await !openInApp(others.map(\.url)),
              await confirm(Review(title: store.removeQuestion("\(Store.counted(others.count, "copy", "copies")) of \(keeper.name)"),
                                   note: "\((keeper.url.path as NSString).abbreviatingWithTildeInPath) stays.",
                                   items: others.map(ReviewItem.init), button: store.removeButton)) else { return }
        // Again: a copy may have changed while the sheet was up.
        let confirmed = Set(others.map(\.id))
        let unchanged = await stillSame(group).filter { confirmed.contains($0.id) }
        guard unchanged.count == others.count else {
            store.message = Store.Message(text: "The copies of \(keeper.name) changed while you decided; Rescan to compare them again.", failed: true)
            return
        }
        store.busy = "Removing copies of \(keeper.name)"
        defer { store.busy = nil }
        let (log, trashed) = await removeEach(others, title: "Copies of \(keeper.name)")
        let gone = Set(log.done.map(\.path))
        duplicates = duplicates.compactMap { group in
            var group = group
            group.files.removeAll { gone.contains($0.id) }
            return group.files.count > 1 ? group : nil
        }
        finish(log, kind: .files, trashed: trashed)
    }

    /// Removes each file on its own, so one that stays does not hold back
    /// the rest, and logs how each went.
    private func removeEach(_ files: [LargeFile], title: String) async -> (log: RunLog, trashed: [Trashed]) {
        var log = RunLog(title: title, permanent: store.deletesPermanently)
        var trashed: [Trashed] = []
        for file in files {
            let removal = await remove([file.url])
            log.add(file.url, size: file.size, removal: removal)
            trashed += removal.trashed
        }
        return (log, trashed)
    }

    /// The copies still byte for byte the same as the keeper.
    private func stillSame(_ group: DuplicateGroup) async -> [LargeFile] {
        store.busy = "Comparing copies of \(group.keeper.name)"
        defer { store.busy = nil }
        return await Task.detached { Duplicates.stillSame(group) }.value
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
            let running = Set(ProjectDependencies.running(found, commands: await Monitor.commands()).map(\.id))
            return found.filter { !running.contains($0.id) }
        }.value
        async let found = Task.detached(priority: .utility) { AIModels.find(home: home) }.value
        async let xcode = Task.detached(priority: .utility) { XcodeSpots.find(home: home) }.value
        async let usage: Void = scanDocker()
        (dependencies, models, xcodeSpots) = await (stale, found, xcode)
        await usage
        scannedDeveloper = true
        applyIgnoreList()
    }

    private var dockerProgram: String? {
        store.program("docker") ?? ["/usr/local/bin/docker", "/Applications/Docker.app/Contents/Resources/bin/docker"]
            .first(where: FileManager.default.isExecutableFile)
    }

    private func scanDocker() async {
        guard let program = dockerProgram else { docker = nil; return }
        docker = await Docker.usage(docker: program, env: store.loginEnv)
    }

    /// Runs a Docker prune after asking; `what` says what it removes.
    func pruneDocker(_ title: String, arguments: [String], what: String) async {
        guard store.busy == nil, let program = dockerProgram,
              Alerts.confirm("\(title)?", what, button: "Prune") else { return }
        store.busy = title
        defer { store.busy = nil }
        let before = docker?.reduce(0) { $0 + $1.size } ?? 0
        let failed = await store.failure("docker exited with an error") {
            try await Docker.run(program, arguments, env: store.loginEnv, runner: ProcessRunner(timeout: 300))
        }
        await scanDocker()
        let freed = max(before - (docker?.reduce(0) { $0 + $1.size } ?? before), 0)
        if let failed {
            store.message = Store.Message(text: "\(title): \(failed)", failed: true)
        } else {
            store.record(.developer, title, freed: freed)
            store.message = Store.Message(text: "\(title): freed \(Store.bytes(freed)).", failed: false)
        }
        monitor.readDisk()
    }

    /// Moves an Xcode folder to the Trash, unless Xcode or the Simulator
    /// has it open.
    func trash(_ spot: XcodeSpot) async {
        guard store.busy == nil, !removing, allowed([spot.url]) else { return }
        removing = true
        defer { removing = false }
        let open = spot.busyBundleIDs.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
        guard await closed(open, toDo: "remove \(spot.title)"), store.busy == nil else { return }
        guard Alerts.confirm(store.removeQuestion(spot.title),
                             "\(Store.bytes(spot.size)) in \((spot.url.path as NSString).abbreviatingWithTildeInPath). \(spot.detail)",
                             button: store.removeButton) else { return }
        store.busy = "Removing \(spot.title)"
        defer { store.busy = nil }
        let (failure, trashed) = await recycle([spot.url])
        recordRemoval(.developer, spot.title, freed: spot.size, failure: failure, trashed: trashed)
        if let failure {
            store.message = Store.Message(text: "\(spot.title): \(failure)", failed: true)
        } else {
            xcodeSpots.removeAll { $0.id == spot.id }
            store.message = Store.Message(text: "\(spot.title) is \(store.removed).", failed: false)
        }
        monitor.readDisk()
    }

    func trashDependencies(_ folders: [LargeFile]) async {
        guard store.busy == nil, !removing, !folders.isEmpty, allowed(folders.map(\.url)) else { return }
        removing = true
        defer { removing = false }
        // A project may have started since the scan, have a shell open in it,
        // or have been worked on again since a list restored from days ago.
        guard let cwds = await workingDirectories() else { return }
        let resumed = await Task.detached(priority: .userInitiated) { ProjectDependencies.touched(folders) }.value
        let running = ProjectDependencies.running(folders, commands: await Monitor.commands())
            + folders.filter { !OpenFile.workingIn($0.url.deletingLastPathComponent().path, cwds).isEmpty }
            + resumed
        if !running.isEmpty {
            let ids = Set(running.map(\.id))
            dependencies.removeAll { ids.contains($0.id) }
            store.message = Store.Message(text: "\(Store.counted(ids.count, "project")) in use or worked on since the scan; "
                                              + "\(ids.count == 1 ? "its" : "their") dependencies stay.", failed: false)
            return
        }
        guard store.busy == nil,
              await confirm(Review(title: store.removeQuestion(Store.counted(folders.count, "dependency folder")),
                                   note: "The next install in each project brings them back.",
                                   items: folders.map(ReviewItem.init), button: store.removeButton)),
              store.busy == nil else { return }
        store.busy = "Removing dependencies"
        defer { store.busy = nil }
        let (failure, trashed) = await recycle(folders.map(\.url))
        let gone = Set(folders.map(\.id))
        dependencies.removeAll { gone.contains($0.id) && !FileManager.default.fileExists(atPath: $0.url.path) }
        var log = RunLog(title: "Project Dependencies", permanent: store.deletesPermanently)
        log.add(folders.map { ($0.url, $0.size) }, trashed: trashed, failure: failure)
        finish(log, kind: .developer, trashed: trashed)
    }

    func trash(_ model: AIModel) async {
        guard store.busy == nil, !removing, allowed(model.paths) else { return }
        removing = true
        defer { removing = false }
        guard await !openInApp(model.paths), store.busy == nil,
              Alerts.confirm(store.removeQuestion(model.name),
                             "\(Store.bytes(model.size)) of \(model.source.rawValue) model files. "
                                 + "Pulling the model again downloads it.",
                             button: store.removeButton) else { return }
        store.busy = "Removing \(model.name)"
        defer { store.busy = nil }
        // The list may be days old: a model pulled since can share a blob
        // this one owned then, so only what it still owns alone goes.
        let home = NSHomeDirectory()
        let fresh = await Task.detached(priority: .userInitiated) { AIModels.find(home: home) }.value
        guard let paths = AIModels.stillOwned(model, in: fresh) else {
            models = fresh
            applyIgnoreList()
            store.message = Store.Message(text: "\(model.name) is gone or changed since the scan; Rescan first. Nothing was removed.", failed: true)
            return
        }
        // A pull may be taking a blob this model owns alone into a new one.
        if await Monitor.commands().contains(where: AIModels.isOllamaWriting) {
            store.message = Store.Message(text: "Ollama is pulling or creating a model; try again when it is done. Nothing was removed.", failed: true)
            return
        }
        let freed = await Task.detached { paths.reduce(Int64(0)) { $0 + DiskUsage.allocated($1) } }.value
        let (failure, trashed) = await recycle(paths)
        recordRemoval(.developer, model.name, freed: freed, failure: failure, trashed: trashed)
        if let failure {
            store.message = Store.Message(text: "\(model.name): \(failure)", failed: true)
        } else {
            models.removeAll { $0.id == model.id }
            store.message = Store.Message(text: "\(model.name) is \(store.removed).", failed: false)
        }
        monitor.readDisk()
    }

    // MARK: Recommendations

    struct Recommendation: Identifiable {
        let symbol: String
        let title: String
        let module: Module
        /// Picks the view inside the module the title names.
        var prepare: (@MainActor (Care) -> Void)?
        var id: String { title }
    }

    /// What the last scan found worth doing, for My Activity.
    var recommendations: [Recommendation] {
        var r: [Recommendation] = []
        if scannedAt.map({ Date.now.timeIntervalSince($0) > 7 * 86400 }) ?? true {
            r.append(Recommendation(symbol: "sparkles", title: "Run Smart Care: no scan this week", module: .smartCare))
        }
        if let health = diskHealth, health.verdict == .failing || health.verdict == .watch {
            r.append(Recommendation(symbol: "internaldrive.fill", title: health.verdict == .failing ? "Back up now: the startup drive is failing"
                                    : "Check the startup drive's health", module: .spaceLens) { $0.showStartupDisk = true })
        }
        if junk > 500_000_000 { r.append(Recommendation(symbol: "trash.fill", title: "Clean \(Store.bytes(junk)) of system junk", module: .cleanup)) }
        if ai > 200_000_000 { r.append(Recommendation(symbol: "brain.head.profile", title: "Clear \(Store.bytes(ai)) of AI clutter", module: .cleanup)) }
        let outdated = store.snapshot?.outdated.count ?? 0
        if outdated > 0 { r.append(Recommendation(symbol: "arrow.down.circle.fill", title: "Update " + Store.counted(outdated, "package"), module: .apps)) }
        let feeds = shownFeedUpdates.filter(\.supported).count
        if feeds > 0 {
            r.append(Recommendation(symbol: "arrow.triangle.2.circlepath", title: "Open \(Store.counted(feeds, "app")) with an update", module: .apps) {
                $0.showUpdates = true
            })
        }
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
        let copies = copies
        let twice = Set(apps.filter { copies.contains($0.id) }.compactMap(\.bundleID)).count
        if twice > 0 { r.append(Recommendation(symbol: "square.on.square", title: "Remove the extra copy of \(Store.counted(twice, "app"))", module: .apps)) }
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
        guard !scanningAI else { return }
        scanningAI = true
        defer { scanningAI = false }
        let home = NSHomeDirectory()
        let temp = "/private/tmp/claude-\(getuid())"
        let open = monitor.runningApps()
        let commands = await Monitor.commands()
        aiJunk = await Task.detached(priority: .utility) {
            AIClutter.find(home: home, claudeTemp: temp, open: open, commands: commands)
        }.value
        applyIgnoreList()
    }

    /// Reads what Cleanup lists beside the junk folders.
    func scanCleanup() async {
        guard !scanningCleanup else { return }
        scanningCleanup = true
        defer { scanningCleanup = false }
        let home = NSHomeDirectory()
        let minimum = Self.mailAttachment
        (brokenPrefs, mailAttachments, trashBins) = await Task.detached(priority: .utility) {
            (BrokenPreferences.find(home: home), MailAttachments.find(home: home, minimum: minimum),
             TrashBins.find(home: home, volumes: TrashBins.mountedVolumes()))
        }.value
        applyIgnoreList()
    }

    /// Clears every junk folder Clean All covers, after a look at the list.
    func cleanAll() async {
        guard store.busy == nil, !removing, !monitor.scanning else { return }
        removing = true
        defer { removing = false }
        let spots = store.spotsToCleanAll
        guard !spots.isEmpty else { return }
        let items = spots.map { spot in
            ReviewItem(id: spot.id, name: spot.title, detail: (spot.path as NSString).abbreviatingWithTildeInPath,
                       size: monitor.junk[spot.id] ?? 0, icon: NSWorkspace.shared.icon(forFile: spot.path))
        }
        let review = Review(title: "Clean up \(Store.bytes(items.reduce(0) { $0 + $1.size }))?",
                            note: "All of it comes back on its own when needed.", items: items, button: "Clean Up")
        guard await confirm(review), store.busy == nil, !monitor.scanning else { return }
        store.busy = "Cleaning up"
        defer { store.busy = nil }
        let (log, trashed) = await store.clean(spots, title: "System Junk")
        finish(log, kind: .junk, trashed: trashed)
    }

    /// Mail must be closed first: it writes an attachment back from its
    /// own index as long as it runs.
    func trashMailAttachments(_ files: [LargeFile]) async {
        guard store.busy == nil, !removing else { return }
        let mail = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail")
        removing = true
        let quit = await closed(mail, toDo: "remove \(Store.counted(files.count, "attachment"))")
        // trashFiles takes the flag again before its first wait.
        removing = false
        guard quit else { return }
        await trashFiles(files, title: "Mail Attachments")
    }

    /// Clears the picked junk as Cleanup clears caches: each tool makes it
    /// again when it needs it. It goes to the Trash unless Settings says to delete.
    func cleanAI(_ picked: [AIJunk]) async {
        guard store.busy == nil, !picked.isEmpty else { return }
        let total = picked.reduce(0) { $0 + $1.size }
        let list = picked.map { "\($0.tool), \($0.kind): \(Store.bytes($0.size))" }.joined(separator: "\n")
            + "\n\n" + Alerts.lines(picked.flatMap(\.paths).map { ($0.path as NSString).abbreviatingWithTildeInPath })
        guard Alerts.confirm("Clear \(Store.bytes(total)) of AI clutter?",
                             list + "\n\nChats, settings, sessions and whatever is running stay. "
                                 + (store.deletesPermanently ? "The rest is deleted for good, not moved to the Trash."
                                                             : "The rest moves to the Trash; My Activity can put it back."),
                             button: "Clear") else { return }
        store.busy = "Clearing AI clutter"
        defer { store.busy = nil }
        let home = NSHomeDirectory()
        let temp = "/private/tmp/claude-\(getuid())"
        let ignored = store.ignoreList
        let open = monitor.runningApps()
        let commands = await Monitor.commands()
        let permanently = store.deletesPermanently
        let removal = await Task.detached {
            Removal.remove(AIClutter.stillJunk(picked, in: AIClutter.find(home: home, claudeTemp: temp, open: open, commands: commands))
                .filter { !ignored.touches($0) }, permanently: permanently)
        }.value
        await scanAI()
        let freed = max(total - picked.reduce(0) { sum, p in sum + (aiJunk.first { $0.id == p.id }?.size ?? 0) }, 0)
        store.record(.ai, picked.count == 1 ? picked[0].tool : "AI Clutter", freed: freed, trashed: removal.trashed)
        monitor.readDisk()
        store.message = Store.Message(text: "AI clutter: freed \(Store.bytes(freed))" + removal.ending,
                                      failed: !removal.failures.isEmpty)
    }

    // MARK: Applications

    /// Lists the apps, then fills in sizes and last use as each is read.
    func loadApps() async {
        guard !loadingApps else { return }
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
        let home = URL(fileURLWithPath: NSHomeDirectory() + "/Applications")
        let found = await Task.detached {
            (AppCatalog.apps(in: folder, caskApps: caskApps, items: items)
                + AppCatalog.apps(in: home, caskApps: caskApps, items: items, managed: false))
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }.value
        externalIDs = await Task.detached { Leftovers.externalAppIDs() }.value
        let old = Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        apps = found.map { app in
            var app = app
            app.size = old[app.id]?.size
            app.lastUsed = old[app.id]?.lastUsed
            app.added = old[app.id]?.added
            app.intelOnly = old[app.id]?.intelOnly
            return app
        }
        applyIgnoreList()
        for app in apps where icons[app.id] == nil {
            icons[app.id] = NSWorkspace.shared.icon(forFile: app.url.path)
        }
        // An open app is in use now, whatever Spotlight recorded.
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.standardizedFileURL.path })
        await forEachConcurrently(found.map(\.url)) { url in
            let item = NSMetadataItem(url: url)
            let used = item?.value(forAttribute: "kMDItemLastUsedDate") as? Date
            let added = item?.value(forAttribute: "kMDItemDateAdded") as? Date
            return (url.path, DiskUsage.allocated(url), used, added, Architectures.intelOnly(url))
        } each: { id, size, used, added, intel in
            guard let i = apps.firstIndex(where: { $0.id == id }) else { return }
            apps[i].size = size
            apps[i].intelOnly = intel
            apps[i].lastUsed = running.contains(URL(fileURLWithPath: id).standardizedFileURL.path) ? .now : used
            apps[i].added = added
        }
    }

    /// Apps in /Applications plus Setapp's and other volumes': a sibling there keeps its agents.
    var installedIDs: Set<String> { Set(apps.compactMap(\.bundleID)).union(externalIDs) }

    /// Removes the app and what it left in the Library. A Brewfile app goes
    /// through zc-care remove, which drops it from the manifest too;
    /// the rest go to the Trash, where they can be put back.
    /// How one uninstall ended, so a run over several apps knows whether
    /// to go on and what to report at the end.
    enum UninstallOutcome { case declined, busy, skipped, failed, done }

    @discardableResult
    func uninstall(_ app: InstalledApp) async -> UninstallOutcome {
        guard store.busy == nil, !removing else { return .busy }
        guard allowed([app.url]) else { return .skipped }
        removing = true
        defer { removing = false }
        guard await closed(app, toDo: "uninstall \(app.name)") else { return .skipped }
        guard store.busy == nil else { return .busy }
        // What the ignore list names stays behind; the rest still goes. With
        // another copy installed, its settings and data are that copy's too.
        let leftovers = copies.contains(app.id) ? []
            : Leftovers.paths(bundleID: app.bundleID, name: app.name, home: NSHomeDirectory(), installed: installedIDs)
                .filter { !store.ignoreList.touches($0) }
        let method = Uninstall.method(declared: app.declared, source: app.source)
        var how: String
        switch method {
        case .remove(_, let resource): how = "zc-care removes \(resource) and drops it from the Brewfile."
        case .cask(let token): how = "Homebrew uninstalls the cask \(token)."
        case .trash: how = store.deletesPermanently ? "The app is deleted for good." : "The app moves to the Trash."
        }
        if !leftovers.isEmpty {
            how += (store.deletesPermanently ? "\n\nIts files are deleted for good:\n" : "\n\nIts files move to the Trash:\n") + Alerts.lines(leftovers.map { ($0 as NSString).abbreviatingWithTildeInPath })
        }
        // Again: the app may have opened while the alert was up.
        guard Alerts.confirm("Uninstall \(app.name)?", how, button: "Uninstall") else { return .declined }
        guard await closed(app, toDo: "uninstall \(app.name)") else { return .skipped }
        guard store.busy == nil else { return .busy }
        store.busy = "Uninstalling \(app.name)"
        defer { store.busy = nil }
        var failure: String?
        var trashed: [Trashed] = []
        switch method {
        case .remove(let target, let resource):
            if let cli = store.cli {
                failure = await store.cancellable {
                    await self.store.failure("remove failed") { try await cli.run(["remove", "-target", target, resource]) }
                }
            } else {
                failure = "zc-care is not installed"
            }
        case .cask(let token):
            if let brew = store.program("brew") {
                failure = await store.cancellable {
                    await self.store.failure("brew uninstall failed") {
                        try await ProcessRunner().run(brew, ["uninstall", "--cask", token], env: self.store.loginEnv)
                    }
                }
            } else {
                failure = "Homebrew is not installed"
            }
        case .trash:
            (failure, trashed) = await recycle([app.url])
        }
        let removed = failure == nil
        var leftoverFailure: String?
        if removed, !leftovers.isEmpty {
            await bootOut(Leftovers.agents(in: leftovers))
            let left: [Trashed]
            (leftoverFailure, left) = await recycle(leftovers.map(URL.init(fileURLWithPath:)))
            trashed += left
        }
        if removed {
            apps.removeAll { $0.id == app.id }
            await store.configChanged()
            // Only an app that went to the Trash comes back whole; a
            // Homebrew or zc-care removal has nothing there to restore.
            store.record(.apps, app.name, freed: app.size ?? 0, trashed: trashed.isEmpty ? nil : trashed)
        } else if !trashed.isEmpty {
            store.record(.apps, app.name, trashed: trashed)
        }
        if let failure {
            store.message = Store.Message(text: "\(app.name): \(failure)", failed: true)
        } else if let leftoverFailure {
            store.message = Store.Message(text: "\(app.name) is uninstalled, but its files stayed: \(leftoverFailure)", failed: true)
        } else {
            store.message = Store.Message(text: "\(app.name) is uninstalled.", failed: false)
        }
        monitor.readDisk()
        return failure == nil && leftoverFailure == nil ? .done : .failed
    }

    /// Uninstalls each app in turn, each asking first. No, or something
    /// else taking over, stops the rest; one message sums up the run so a
    /// later app's success does not hide an earlier failure.
    func uninstall(_ chosen: [InstalledApp]) async {
        let before = apps.count
        var done = 0
        var problems: [String] = []
        var stopped = false
        for app in chosen {
            let outcome = await uninstall(app)
            if outcome == .done { done += 1 }
            if outcome == .failed || outcome == .skipped, let message = store.message, message.failed { problems.append(message.text) }
            if outcome == .declined || outcome == .busy { stopped = true; break }
        }
        // An app gone, even with files that stayed, changes what counts as left over.
        if apps.count < before { orphans = nil }
        guard chosen.count > 1 else { return }
        var text = "\(Store.counted(done, "app")) uninstalled"
        if stopped { text += ", the rest left alone" }
        if !problems.isEmpty { text += ". " + problems.joined(separator: " ") }
        store.message = Store.Message(text: text + (problems.isEmpty ? "." : ""), failed: !problems.isEmpty)
    }

    /// Stops the agents so they do not run on from the Trash.
    private func bootOut(_ agents: [String]) async {
        for agent in agents {
            _ = try? await ProcessRunner(timeout: 10).run("/bin/launchctl", ["bootout", "gui/\(getuid())", agent], env: [:])
        }
    }

    /// The app as on its first launch: its settings, caches and data go to
    /// the Trash, and the app stays.
    func reset(_ app: InstalledApp) async {
        guard store.busy == nil, !removing else { return }
        removing = true
        defer { removing = false }
        guard await closed(app, toDo: "reset \(app.name)"), store.busy == nil else { return }
        let data = Leftovers.paths(bundleID: app.bundleID, name: app.name, home: NSHomeDirectory(), installed: installedIDs)
            .filter { !store.ignoreList.touches($0) }
        guard !data.isEmpty else {
            store.message = Store.Message(text: "\(app.name) keeps no settings or data to reset.", failed: false)
            return
        }
        let urls = data.map(URL.init(fileURLWithPath:))
        guard Alerts.confirm("Reset \(app.name)?",
                                            "It opens as on its first launch. " + (store.deletesPermanently ? "These are deleted for good:\n" : "These move to the Trash:\n")
                                                + Alerts.lines(data.map { ($0 as NSString).abbreviatingWithTildeInPath }),
                                            button: "Reset"), await closed(app, toDo: "reset \(app.name)"), store.busy == nil else { return }
        store.busy = "Resetting \(app.name)"
        defer { store.busy = nil }
        await bootOut(Leftovers.agents(in: data))
        let (failure, trashed) = await recycle(urls)
        recordRemoval(.apps, "Reset \(app.name)", freed: 0, failure: failure, trashed: trashed)
        if let failure {
            store.message = Store.Message(text: "\(app.name): \(failure)", failed: true)
        } else {
            // cfprefsd keeps the settings in memory and would write them back.
            _ = try? await ProcessRunner(timeout: 10).run("/usr/bin/killall", ["cfprefsd"], env: [:])
            store.message = Store.Message(text: "\(app.name) is reset.", failed: false)
        }
    }

    // MARK: Leftovers

    /// Library entries named for apps Launch Services no longer knows. A
    /// launch agent or a running process with the id is no leftover: tools
    /// without an app bundle keep their settings under it too.
    /// Launch Services still knows an app in the Trash until it is emptied:
    /// only a copy outside it counts.
    nonisolated static func installedOutsideTrash(_ id: String) -> Bool {
        // Launch Services also keeps records of bundles deleted since.
        NSWorkspace.shared.urlsForApplications(withBundleIdentifier: id)
            .contains { !Leftovers.inTrash($0.path) && FileManager.default.fileExists(atPath: $0.path) }
    }

    /// What tells a leftover from an app's own files: apps on other volumes
    /// and in Setapp, the vendors of installed apps, and whether an id is
    /// running, a launch agent's, or installed outside the Trash.
    nonisolated static func owners(home: String, running: Set<String>)
        -> (external: Set<String>, vendors: Set<String>, owns: @Sendable (String) -> Bool) {
        let external = Leftovers.externalAppIDs()
        let folders = [home + "/Library/LaunchAgents", "/Library/LaunchAgents", "/Library/LaunchDaemons"]
        let inUse = running.union(LaunchAgent.read(folders: folders).map(\.label))
        let apps = ["/Applications", "/Applications/Utilities", home + "/Applications"].flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.hasSuffix(".app") }
                .map { folder + "/" + $0 }
        }
        let vendors = Set(apps.compactMap { Bundle(path: $0)?.bundleIdentifier }.map(Leftovers.vendor))
            .union(external.map(Leftovers.vendor))
        return (external, vendors, { inUse.contains($0) || external.contains($0) || installedOutsideTrash($0) })
    }

    func loadOrphans() async {
        guard !loadingOrphans else { return }
        loadingOrphans = true
        defer { loadingOrphans = false }
        let home = NSHomeDirectory()
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let removed = removedIDs
        let found = await Task.detached(priority: .utility) {
            let owners = Self.owners(home: home, running: running)
            return (owners.external, Leftovers.orphans(home: home, vendors: owners.vendors, removed: removed, isInstalled: owners.owns))
        }.value
        externalIDs = found.0
        orphans = found.1
        // Told about once listed: an app back since, or cleared, is no longer news.
        removedIDs.subtract(removed.subtracting(orphans?.map(\.bundleID) ?? []))
        applyIgnoreList()
        // A notification clicked while this ran named an app it missed.
        if !removedIDs.isSubset(of: removed) {
            loadingOrphans = false
            await loadOrphans()
        }
    }

    func trashOrphans(_ picked: [Orphan]) async {
        guard store.busy == nil, !removing, !picked.isEmpty,
              allowed(picked.flatMap(\.paths).map { URL(fileURLWithPath: $0) }) else { return }
        removing = true
        defer { removing = false }
        guard await !openInApp(picked.flatMap(\.paths).map { URL(fileURLWithPath: $0) }), store.busy == nil else { return }
        let items = picked.map { orphan in
            ReviewItem(id: orphan.id, name: orphan.bundleID,
                       detail: orphan.paths.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: " · "),
                       size: orphan.size, icon: NSImage(systemSymbolName: "folder.badge.questionmark", accessibilityDescription: nil))
        }
        guard await confirm(Review(title: store.removeQuestion("what \(Store.counted(picked.count, "removed app")) left"),
                                   note: "Caches, settings and support files.", items: items, button: store.removeButton)),
              store.busy == nil else { return }
        store.busy = "Removing leftovers"
        defer { store.busy = nil }
        // An app reinstalled or started since the list was read owns its folders again.
        let home = NSHomeDirectory()
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let removed = removedIDs
        let (still, files) = await Task.detached(priority: .userInitiated) {
            let owners = Self.owners(home: home, running: running)
            let still = Leftovers.stillOrphaned(picked, vendors: owners.vendors, removed: removed, isInstalled: owners.owns)
            return (still, still.flatMap { orphan in orphan.paths.map { (URL(fileURLWithPath: $0), DiskUsage.allocated(URL(fileURLWithPath: $0))) } })
        }.value
        let skipped = picked.filter { orphan in !still.contains { $0.id == orphan.id } }
        let back = skipped.filter { $0.paths.contains(where: FileManager.default.fileExists) }
        orphans?.removeAll { o in skipped.contains { $0.id == o.id } }
        let note = back.isEmpty ? nil
            : "\(back.map(\.bundleID).joined(separator: ", ")) came back since the scan; \(back.count == 1 ? "its" : "their") files stay."
        guard !files.isEmpty else {
            store.message = Store.Message(text: note ?? "Those leftovers are gone already.", failed: false)
            return
        }
        let (failure, trashed) = await recycle(files.map(\.0))
        let gone = Set(picked.map(\.id))
        orphans?.removeAll { o in gone.contains(o.id) && !o.paths.contains(where: FileManager.default.fileExists) }
        var log = RunLog(title: "App Leftovers", permanent: store.deletesPermanently)
        log.add(files, trashed: trashed, failure: failure)
        finish(log, kind: .apps, trashed: trashed)
        // finish shows the run; the apps skipped are told beside it.
        if let note { store.message = Store.Message(text: note, failed: false) }
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
        let installFailure = await store.cancellable {
            await self.store.failure("brew install failed") {
                try await ProcessRunner().run(brew, ["install", "--cask", "--adopt", token], env: self.store.loginEnv)
            }
        }
        if let installFailure {
            store.message = Store.Message(text: "\(app.name): \(installFailure)", failed: true)
            return
        }
        var addFailure: String?
        do {
            let add = try await cli.run(["add", "-target", target, "-why", "Adopted from /Applications by ZC Care", "cask:" + token])
            if add.status != 0 { addFailure = lastLine(add.stderr) ?? "exit status \(add.status)" }
        } catch {
            addFailure = error.localizedDescription
        }
        store.message = addFailure.map { Store.Message(text: "Homebrew adopted \(app.name), but add failed: \($0)", failed: true) }
            ?? Store.Message(text: "\(app.name) is now cask \(token) in \(target).", failed: false)
        await loadApps()
        if addFailure == nil { await store.configChanged() }
    }

    /// Removes by the choice in Settings: to the Trash, or for good.
    private func remove(_ urls: [URL]) async -> Removal {
        let permanently = store.deletesPermanently
        return await Task.detached { Removal.remove(urls, permanently: permanently) }.value
    }

    /// Moves to the Trash, where the Finder asks for a password when the
    /// app belongs to the system, as App Store apps do; or deletes for good
    /// when Settings says so. A batch that stops midway still reports what
    /// moved, so Put Back has it.
    private func recycle(_ urls: [URL]) async -> (failure: String?, trashed: [Trashed]) {
        if store.deletesPermanently {
            let removal = await remove(urls)
            return (removal.failures.isEmpty ? nil : removal.summary, [])
        }
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.recycle(urls) { moved, error in
                continuation.resume(returning: (error?.localizedDescription,
                                                moved.map { Trashed(original: $0.key, inTrash: $0.value) }))
            }
        }
    }

    /// Logs a removal, and what moved before one that failed, which Put Back can still return.
    private func recordRemoval(_ kind: ActivityEntry.Kind, _ title: String, freed: Int64,
                               failure: String?, trashed: [Trashed]) {
        guard failure == nil || !trashed.isEmpty else { return }
        store.record(kind, title, freed: failure == nil ? freed : 0, trashed: trashed)
    }

    private func lastLine(_ text: String?) -> String? {
        text?.split(whereSeparator: \.isNewline).last.map(String.init)
    }

    // MARK: Performance

    private var domain: String { "gui/\(getuid())" }

    private func launchctl(_ args: [String]) async throws -> String {
        let r = try await ProcessRunner(timeout: 30).run("/bin/launchctl", args, env: [:])
        guard r.status == 0 else { throw CLIError(message: lastLine(r.stderr) ?? "launchctl \(args[0]) exited \(r.status)") }
        return r.output
    }

    func loadAgents() async {
        let home = NSHomeDirectory()
        var found = await Task.detached {
            LaunchAgent.read(folders: [home + "/Library/LaunchAgents", "/Library/LaunchAgents"])
        }.value
        do {
            let disabled = Launchd.parseDisabled(try await launchctl(["print-disabled", domain]))
            let running = Launchd.parseRunning(try await launchctl(["list"]))
            for i in found.indices {
                if let off = disabled[found[i].label] { found[i].enabled = !off }
                found[i].running = running.contains(found[i].label)
            }
        } catch {
            store.message = Store.Message(text: "Launch agents: could not read which are on or running: \(error.localizedDescription)",
                                          failed: true)
        }
        // Broken ones first: they are the ones to act on.
        agents = found.filter(\.broken) + found.filter { !$0.broken }
        noteSightings("agent", ids: found.map(\.label))
        readBackground()
    }

    private static let savedSightings = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("dev.zoolcoder.zccare/sightings.json")

    private func noteSightings(_ kind: String, ids: [String]) {
        sightings.record(kind, ids: ids)
        try? sightings.save(to: Self.savedSightings)
    }

    /// Whether the agent or background item first showed up in the last week.
    func isNew(agent: LaunchAgent) -> Bool { sightings.isNew("agent", agent.label) }
    func isNew(background item: BackgroundItem) -> Bool { sightings.isNew("background", item.id) }

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
        guard store.busy == nil, agent.path.hasPrefix(NSHomeDirectory() + "/"), allowed([URL(fileURLWithPath: agent.path)]) else { return }
        let drift = managed(agent) ? " Your zc-care config declares it, so this shows as drift and the next apply recreates it; remove it from the config too." : ""
        guard Alerts.confirm("Remove \(agent.label)?",
                             "It runs \((agent.program as NSString).abbreviatingWithTildeInPath), which is gone. "
                                 + (store.deletesPermanently ? "Its plist is deleted for good." : "Its plist moves to the Trash.") + drift, button: "Remove") else { return }
        store.busy = "Removing \(agent.label)"
        defer { store.busy = nil }
        await bootOut([agent.path])
        let (failure, trashed) = await recycle([URL(fileURLWithPath: agent.path)])
        recordRemoval(.maintenance, "Broken Launch Agent", freed: 0, failure: failure, trashed: trashed)
        store.message = failure.map { Store.Message(text: "\(agent.label): \($0)", failed: true) }
            ?? Store.Message(text: "\(agent.label) is \(store.removed).", failed: false)
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

    /// Runs the task's steps; why one failed, if one did.
    private func steps(of task: MaintenanceTask) async -> String? {
        if task.admin {
            return await store.failure("osascript failed") {
                try await ProcessRunner().run("/usr/bin/osascript", ["-e", Maintenance.adminScript(task.steps)], env: [:])
            }
        }
        for step in task.steps {
            let failed = await store.failure("\(step[0]) failed") {
                let arguments = Array(step.dropFirst())
                let env = self.store.loginEnv.merging(task.env) { $1 }
                if task.docker {
                    return try await Docker.run(step[0], arguments, env: env, runner: ProcessRunner())
                }
                return try await ProcessRunner().run(step[0], arguments, env: env)
            }
            if let failed { return failed }
        }
        return nil
    }

    /// Runs one task after asking; admin tasks go through osascript, which
    /// asks for the password itself.
    func run(_ task: MaintenanceTask) async {
        guard store.busy == nil,
              Alerts.confirm("\(task.title)?", task.detail + (task.admin ? "\n\nmacOS asks for your password." : ""),
                             button: "Run") else { return }
        store.busy = task.title
        defer { store.busy = nil }
        let failure = await store.cancellable { await self.steps(of: task) }
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
        async let checks = readSecurityChecks()
        gatekeeper = await status.map { $0.output.contains("assessments enabled") }
        securityChecks = await checks
        protectionCheckedAt = Date()
        permissions = await tcc
        await loadBrowserTraces()
        let unassessed = apps.filter { assessments[$0.id] == nil }.map { (id: $0.id, path: $0.url.path) }
        await forEachConcurrently(unassessed) { app in
            let r = try? await ProcessRunner(timeout: 60).run("/usr/sbin/spctl", ["--assess", "-v", app.path], env: [:])
            return (app.id, Assessment.parse(r?.stderr ?? ""))
        } each: { id, a in
            assessments[id] = a
        }
    }

    private func readSecurityChecks() async -> [SecurityCheck] {
        let runner = ProcessRunner(timeout: 20)
        async let fv = try? runner.run(SecurityChecks.fileVault.path, SecurityChecks.fileVault.args, env: [:])
        async let fw = try? runner.run(SecurityChecks.firewall.path, SecurityChecks.firewall.args, env: [:])
        async let sip = try? runner.run(SecurityChecks.integrity.path, SecurityChecks.integrity.args, env: [:])
        let prefs = NSDictionary(contentsOfFile: SecurityChecks.updates) as? [String: Any]
        return await SecurityChecks.checks(fileVault: fv?.output, firewall: fw?.output, integrity: sip?.output, updates: prefs)
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
        guard store.busy == nil, !removing else { return }
        removing = true
        defer { removing = false }
        let what = "clear \(trace.browser)'s \(trace.kind.lowercased())"
        guard await closed(NSRunningApplication.runningApplications(withBundleIdentifier: trace.bundleID), toDo: what),
              store.busy == nil else { return }
        let effect = switch trace.kind {
        case BrowserPrivacy.cookies: "You will be signed out of websites in \(trace.browser)."
        case BrowserPrivacy.history: "\(trace.browser) forgets the pages you visited; bookmarks and passwords stay."
        case BrowserPrivacy.siteData: "Sites forget the databases they keep in \(trace.browser), such as offline data; you may be signed out of some. Extensions keep theirs."
        case BrowserPrivacy.sessions: "\(trace.browser) no longer reopens the tabs and windows it saved; bookmarks stay."
        default: "\(trace.browser) downloads pages again as you visit them."
        }
        guard Alerts.confirm("Clear \(trace.browser)'s \(trace.kind.lowercased())?",
                             (store.deletesPermanently
                                 ? "This permanently deletes \(Store.counted(trace.paths.count, "item")), \(Store.bytes(trace.size)); nothing goes to the Trash.\n\n"
                                 : "This moves \(Store.counted(trace.paths.count, "item")), \(Store.bytes(trace.size)), to the Trash; My Activity can put it back.\n\n") + effect,
                             button: "Clear") else { return }
        // Again: the browser may have opened while the alert was up.
        guard await closed(NSRunningApplication.runningApplications(withBundleIdentifier: trace.bundleID), toDo: what),
              store.busy == nil else { return }
        store.busy = "Clearing \(trace.browser) \(trace.kind.lowercased())"
        defer { store.busy = nil }
        let permanently = store.deletesPermanently
        let removal = await Task.detached { BrowserPrivacy.clear(trace, permanently: permanently) }.value
        await loadBrowserTraces()
        let left = browserTraces?.first { $0.id == trace.id }?.size ?? 0
        store.record(.privacy, "\(trace.browser) \(trace.kind)", freed: max(trace.size - left, 0), trashed: removal.trashed)
        monitor.readDisk()
        store.message = Store.Message(text: "\(trace.browser) \(trace.kind.lowercased()) cleared" + removal.ending,
                                      failed: removal.stayed > 0)
    }

    /// What runs with the session, as Background Task Management keeps it.
    /// sfltool asks for an administrator's password when an app runs it,
    /// so this waits for a click.
    func loadBackgroundItems() async {
        guard !loadingBackground else { return }
        loadingBackground = true
        defer { loadingBackground = false }
        let r: CommandResult
        do {
            r = try await ProcessRunner(timeout: 120).run("/usr/bin/sfltool", ["dumpbtm"], env: [:])
        } catch {
            let why = (error as? CLIError)?.timedOut == true ? "no password was given in time" : error.localizedDescription
            store.message = Store.Message(text: "Background items not read: \(why).", failed: true)
            return
        }
        guard r.status == 0 else {
            store.message = Store.Message(text: "Background items not read: \(lastLine(r.stderr) ?? "the password was not given").", failed: true)
            return
        }
        backgroundItems = BackgroundItems.parse(r.output, uid: getuid())
            .sorted { ($0.developer ?? "~", $0.name) < ($1.developer ?? "~", $1.name) }
        noteSightings("background", ids: backgroundItems.map(\.id))
    }

    /// Nil without Full Disk Access: macOS keeps both databases from apps
    /// that lack it.
    private func readPermissions() async -> [Permission]? {
        let dbs = [NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db",
                   "/Library/Application Support/com.apple.TCC/TCC.db"]
        var rows: [Permission]?
        var failure: String?
        for db in dbs {
            do {
                let r = try await ProcessRunner(timeout: 30).run("/usr/bin/sqlite3", ["-readonly", "-separator", "|", db, Privacy.query], env: [:])
                if r.status == 0 {
                    rows = (rows ?? []) + Privacy.parse(r.output)
                } else if !Privacy.lacksFullDiskAccess(stderr: r.stderr) {
                    failure = lastLine(r.stderr) ?? "sqlite3 exited \(r.status)"
                }
            } catch {
                failure = error.localizedDescription
            }
        }
        permissionsError = rows == nil ? failure : nil
        return rows?.sorted { ($0.service, $0.client) < ($1.service, $1.client) }
    }

    /// Forgets one app's answer for one service: macOS asks the app again
    /// the next time it wants it. Nothing to put back, so it asks first.
    func resetPermission(_ p: Permission) async {
        guard store.busy == nil, let args = Privacy.resetArguments(p),
              Alerts.confirm("Reset \(p.service) for \(p.client)?",
                             "macOS forgets that you \(p.allowed ? "allowed" : "denied") it; the app asks again the next time it needs \(p.service).",
                             button: "Reset") else { return }
        store.busy = "Resetting \(p.service)"
        defer { store.busy = nil }
        do {
            let r = try await ProcessRunner(timeout: 20).run("/usr/bin/tccutil", args, env: [:])
            guard r.status == 0 else { throw CLIError(message: lastLine(r.stderr) ?? "tccutil exited \(r.status)") }
            // tccutil without root can leave answers kept in the system database: read them again to know.
            permissions = await readPermissions()
            guard !(permissions?.contains { $0.id == p.id } ?? false) else {
                throw CLIError(message: "macOS keeps this answer in the system database; change it in System Settings")
            }
            store.record(.privacy, "Reset \(p.service) for \(p.client)")
            store.message = Store.Message(text: "\(p.client) asks for \(p.service) again next time.", failed: false)
        } catch {
            store.message = Store.Message(text: "\(p.service) not reset: \(error.localizedDescription)", failed: true)
        }
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
        let r: CommandResult
        do {
            r = try await ProcessRunner(timeout: 900).run("/usr/bin/du", SpaceLens.arguments(root: home), env: [:])
        } catch {
            let why = (error as? CLIError)?.timedOut == true ? "took too long to measure \(home)" : "could not measure \(home): \(error.localizedDescription)"
            store.message = Store.Message(text: "Space Lens \(why).", failed: true)
            return
        }
        let text = r.output
        guard let root = await Task.detached(operation: { SpaceLens.parse(du: text, root: home) }).value else {
            store.message = Store.Message(text: "Space Lens could not read \(home).", failed: true)
            return
        }
        let scan = space?.followed(by: root) ?? SpaceScan(scannedAt: .now, root: root)
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
        // A download being removed would come back in a scan read meanwhile.
        guard !scanningCloud, store.busy == nil else { return }
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
    func removeDownload(_ file: LargeFile, from drive: CloudDrive) async {
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
        store.busy = "Removing the download of \(file.name)"
        // Eviction waits on the provider's file coordination: not on the main thread.
        let url = file.url
        let evicted = await Task.detached(priority: .userInitiated) { () -> Bool in
            (try? FileManager.default.evictUbiquitousItem(at: url)) != nil
        }.value
        store.busy = nil
        if evicted {
            dropCloudFile(file, from: drive, freed: file.size)
            monitor.readDisk()
            store.record(.cloud, file.name, freed: file.size)
            store.message = Store.Message(text: "\(file.name) is now in \(drive.name) only.", failed: false)
        } else {
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
