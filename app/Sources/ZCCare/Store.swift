import AppKit
import Observation
import ServiceManagement
import UniformTypeIdentifiers
import ZCCareCore

/// The app's state and every action the menu offers. All work goes through
/// the CLI; the app only reads its JSON and asks before it changes anything.
@MainActor @Observable
final class Store {
    var snapshot: Snapshot? {
        didSet { publish() }
    }
    var refreshedAt: Date?
    var refreshing = false
    /// What a running change is doing, such as "Updating tmux".
    var busy: String?
    /// Set while a change that can hang runs: the busy banner's Cancel.
    var cancelBusy: (() -> Void)?
    /// The outcome of the last change, or why it failed.
    var message: Message?
    /// The plan Plan last showed.
    var plan: PlanDoc?
    /// Why the CLI cannot run: no binary, or no config.
    var setupProblem: String? {
        didSet { publish() }
    }
    var ignored: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(ignored).sorted(), forKey: Keys.ignored)
            publish()
        }
    }

    var tab: Tab = .mac
    /// Disk, memory, CPU and the rest, for the Mac tab.
    let monitor = Monitor()
    /// The Mac tab's open tile: what Free Up clears, or the busiest apps.
    var macDetail: MacDetail? {
        didSet {
            monitor.order = macDetail == .memory ? .memory : macDetail == .cpu ? .cpu : nil
            if macDetail == .disk, monitor.junk.isEmpty { Task { await monitor.scan() } }
        }
    }

    enum MacDetail: String { case disk, memory, cpu }
    /// The target whose items the overview shows, and what they are.
    var expanded: String?
    var targetItems: [String: [Item]] = [:]
    /// Every declared item, and the apply log; nil until My Workstation
    /// reads them.
    var inventory: [Item]?
    var history: [HistoryEntry]?
    /// What ZC Care cleaned and ran, for My Activity.
    var activity = ActivityLog.load(from: Store.activityFile)
    /// Launch agents that run on a calendar, such as the weekly upkeep.
    var jobs: [Job] = []

    enum Tab: String, CaseIterable {
        case mac = "Mac", overview = "Overview", updates = "Updates", health = "Health", services = "Services"
    }

    struct Message: Equatable {
        var text: String
        var failed: Bool
        var log: URL?
    }

    private enum Keys {
        static let config = "configPath"
        static let ignored = "ignoredChecks"
        static let notifies = "notifies"
        static let hotkey = "hotkey"
        static let weeklyScan = "weeklyScan"
        static let ignoreList = "ignoreList"
        static let vitalsAlerts = "vitalsAlerts"
        static let vitalLimits = "vitalLimits"
        static let barStats = "barStats"
        static let deletesPermanently = "deletesPermanently"
    }

    /// A reading the menu bar can show beside the mark.
    enum BarStat: String, CaseIterable {
        case cpu, memory, disk, network, battery

        var title: String {
            switch self {
            case .cpu: "CPU load"
            case .memory: "Memory used"
            case .disk: "Free disk space"
            case .network: "Network speed"
            case .battery: "Battery charge"
            }
        }
    }

    private var careCLI: CareCLI?
    /// The zc-care found, config or not, for the Setup Assistant.
    private var binary: String?
    private var env: [String: String] = [:]
    private var ticker: Task<Void, Never>?
    private var discovery: Task<Void, Never>?
    private var watcher: Task<Void, Never>?
    private var watch = VitalsWatch()
    private let planFile = FileManager.default.temporaryDirectory.appendingPathComponent("zccare-plan.json").path
    let notifier = Notifier()
    /// Set by the app delegate, which owns the hotkey.
    var hotkeyChanged: ((Bool) -> Void)?
    /// Set by the app delegate, which owns the Care window.
    var openCare: ((Care.Module?) -> Void)?
    /// Set by the app delegate, which owns the Settings window.
    var openSettings: (() -> Void)?
    /// Set by the app delegate, which owns the app picker.
    var openApps: (() -> Void)?
    /// Set by the app delegate, which owns the Setup Assistant.
    var openSetup: (() -> Void)?
    /// Set by Care, which drops what the list names from its own lists.
    var ignoreListChanged: (() -> Void)?
    /// Set by Care, whose lists are stale once files come back.
    var putBackDone: (() -> Void)?

    init() {
        ignored = Set(UserDefaults.standard.stringArray(forKey: Keys.ignored) ?? [])
        UserDefaults.standard.register(defaults: [Keys.notifies: true, Keys.hotkey: true, Keys.weeklyScan: true,
                                                  Keys.vitalsAlerts: true, Keys.barStats: ["cpu", "memory"]])
        notifies = UserDefaults.standard.bool(forKey: Keys.notifies)
        hotkey = UserDefaults.standard.bool(forKey: Keys.hotkey)
        weeklyScan = UserDefaults.standard.bool(forKey: Keys.weeklyScan)
        ignoreList = IgnoreList(UserDefaults.standard.stringArray(forKey: Keys.ignoreList) ?? [])
        vitalsAlerts = UserDefaults.standard.bool(forKey: Keys.vitalsAlerts)
        deletesPermanently = UserDefaults.standard.bool(forKey: Keys.deletesPermanently)
        vitalLimits = UserDefaults.standard.data(forKey: Keys.vitalLimits)
            .flatMap { try? JSONDecoder().decode(VitalLimits.self, from: $0) } ?? VitalLimits()
        barStats = Set((UserDefaults.standard.stringArray(forKey: Keys.barStats) ?? []).compactMap(BarStat.init))
        monitor.ignore = ignoreList
        watch.limits = vitalLimits
        if !barStats.isEmpty { monitor.start(.bar) }
    }

    /// What the menu bar shows beside the mark, sampled while any shows.
    var barStats: Set<BarStat> {
        didSet {
            UserDefaults.standard.set(barStats.map(\.rawValue).sorted(), forKey: Keys.barStats)
            if barStats.isEmpty { monitor.stop(.bar) } else { monitor.start(.bar) }
        }
    }

    /// macOS turned the notifications down: Settings says so, as nothing
    /// else would.
    var notificationsBlocked = false

    /// Asks again on coming back from System Settings.
    func recheckNotifications() {
        guard notifies else { return }
        Task { notificationsBlocked = !(await notifier.authorize()) }
    }

    /// Notifies of a full disk, memory pressure, heat and battery wear,
    /// checked each minute whether the panel shows or not.
    var vitalsAlerts: Bool {
        didSet { UserDefaults.standard.set(vitalsAlerts, forKey: Keys.vitalsAlerts) }
    }

    /// Every removal goes to the Trash, where My Activity can put it back,
    /// unless this is on: then it is deleted for good.
    var deletesPermanently: Bool {
        didSet { UserDefaults.standard.set(deletesPermanently, forKey: Keys.deletesPermanently) }
    }

    /// Where a removed item is, for a message: "in the Trash" or "deleted".
    var removed: String { deletesPermanently ? "deleted" : "in the Trash" }
    var removeButton: String { deletesPermanently ? "Delete" : "Move to Trash" }

    func removeQuestion(_ what: String) -> String {
        deletesPermanently ? "Delete \(what) for good?" : "Move \(what) to the Trash?"
    }

    var vitalLimits: VitalLimits {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(vitalLimits), forKey: Keys.vitalLimits)
            watch.limits = vitalLimits
        }
    }

    private func watchVitals() {
        watcher = Task { [weak self] in
            var check = 0
            while !Task.isCancelled {
                guard let self else { return }
                if notifies, vitalsAlerts {
                    let vitals = await monitor.watchSample(battery: check % 60 == 0)
                    notifier.post(watch.alerts(for: vitals))
                    check += 1
                }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// Files and folders ZC Care never lists, cleans or trashes.
    var ignoreList: IgnoreList {
        didSet {
            UserDefaults.standard.set(ignoreList.paths, forKey: Keys.ignoreList)
            monitor.ignore = ignoreList
            ignoreListChanged?()
        }
    }

    func ignore(_ url: URL) {
        ignoreList.add(url.path)
        message = Message(text: "\(url.lastPathComponent) is on the ignore list; Settings takes it off.", failed: false)
    }

    /// Smart Care scans by itself once a week.
    var weeklyScan: Bool {
        didSet { UserDefaults.standard.set(weeklyScan, forKey: Keys.weeklyScan) }
    }

    var notifies: Bool {
        didSet {
            UserDefaults.standard.set(notifies, forKey: Keys.notifies)
            if notifies { Task { notificationsBlocked = !(await notifier.authorize()) } }
        }
    }

    /// ⌃⌥Z opens the panel from anywhere.
    var hotkey: Bool {
        didSet {
            UserDefaults.standard.set(hotkey, forKey: Keys.hotkey)
            hotkeyChanged?(hotkey)
        }
    }

    var attention: Int { snapshot?.attention(ignoring: ignored) ?? 0 }
    var findings: [Check] { snapshot?.findings(ignoring: ignored) ?? [] }
    var ignoredFindings: [Check] { snapshot?.findings.filter { ignored.contains($0.name) } ?? [] }
    var configPath: String? { careCLI?.config }
    /// The CLI and the login environment, for the Care window.
    var cli: CareCLI? { careCLI }
    var loginEnv: [String: String] { env }

    /// A program on the login PATH, or in Homebrew's folder.
    func program(_ name: String) -> String? {
        let dirs = (env["PATH"] ?? "").split(separator: ":").map(String.init) + ["/opt/homebrew/bin"]
        return dirs.map { $0 + "/" + name }.first(where: FileManager.default.isExecutableFile)
    }

    // MARK: Refresh

    func start() async {
        if notifies { notificationsBlocked = !(await notifier.authorize()) }
        watchVitals()
        await connected()
        await refresh()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30 * 60))
                await self?.refresh()
            }
        }
    }

    /// Finds the CLI and the config, then reads the machine.
    func connect() async {
        await discover()
        await refresh()
    }

    /// Waits for the first look for the CLI and the login PATH, which the
    /// Care window's scans need: a link can open it before the app is up.
    func connected() async {
        if discovery == nil { discovery = Task { await discover() } }
        await discovery?.value
    }

    private func discover() async {
        env = await Discovery.loginEnvironment()
        let home = NSHomeDirectory()
        guard let binary = Discovery.binary(env: env, home: home) else {
            setupProblem = "zc-care is missing. Install ZC Care again with brew reinstall --cask zc-care."
            return
        }
        self.binary = binary
        let chosen = UserDefaults.standard.string(forKey: Keys.config)
        guard let config = Discovery.config(chosen: chosen, env: env, home: home) else {
            setupProblem = "Set up this Mac, or choose the zc-care.yaml you have."
            return
        }
        setupProblem = nil
        careCLI = CareCLI(binary: binary, config: config, env: env)
    }

    func refresh() async {
        guard let careCLI, !refreshing else { return }
        refreshing = true
        let old = snapshot
        let new = await careCLI.snapshot()
        snapshot = new
        refreshedAt = .now
        jobs = await readJobs(new.services)
        targetItems = [:]
        if let expanded { await loadItems(expanded) }
        refreshing = false
        // The first read has nothing to compare with: what is already
        // outstanding at launch is the badge's to show.
        if notifies, let old { notifier.post(new.alerts(since: old, ignoring: ignored)) }
    }

    /// Opening the menu reads again once the last read is a few minutes old.
    func refreshIfStale() {
        guard let refreshedAt, Date.now.timeIntervalSince(refreshedAt) > 120 else { return }
        Task { await refresh() }
    }

    func chooseConfig() {
        let panel = NSOpenPanel()
        panel.title = "Choose your zc-care config"
        panel.allowedContentTypes = [.yaml]
        panel.canChooseDirectories = false
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: Keys.config)
        Task { await connect() }
    }

    // MARK: Setup

    /// The CLI is here but no config is: the Setup Assistant can make one.
    var needsConfig: Bool { careCLI == nil && binary != nil }

    /// The CLI, without a config until there is one; nil when zc-care is
    /// missing.
    var setupCLI: CareCLI? {
        careCLI ?? binary.map { CareCLI(binary: $0, config: "", env: env) }
    }

    /// Writes the starter config for who the Mac is for, then reads the
    /// Mac with it. Nothing is installed yet.
    func createConfig(profiles: [String], role: String?, fromMac: Bool) async throws -> InitResult {
        await connected()
        guard let cli = setupCLI else { throw CLIError(message: setupProblem ?? "zc-care is missing.") }
        busy = "Writing your config"
        defer { busy = nil }
        let result = try await cli.initConfig(profiles: profiles, role: role, fromMac: fromMac)
        UserDefaults.standard.set(result.config, forKey: Keys.config)
        await connect()
        return result
    }

    /// Runs body so the busy banner can cancel it; the programs it runs stop.
    func cancellable<T: Sendable>(_ body: @escaping @MainActor () async -> T) async -> T {
        let task = Task { await body() }
        cancelBusy = { task.cancel() }
        defer { cancelBusy = nil }
        return await task.value
    }

    /// Why a program failed, or nil when it exited 0: its last line of
    /// error, else fallback. A cancelled run and a launch error say so.
    func failure(_ fallback: String, of run: () async throws -> CommandResult) async -> String? {
        do {
            let r = try await run()
            return r.status == 0 ? nil : (ZCCareCore.lastLine(r.stderr) ?? fallback)
        } catch is CancellationError {
            return "Cancelled."
        } catch {
            return error.localizedDescription
        }
    }

    /// Runs the command as root behind the password dialog; why it failed, if it did.
    private func asRoot(_ command: String) async -> String? {
        await cancellable {
            await self.failure("osascript failed") {
                try await ProcessRunner().run("/usr/bin/osascript", ["-e", adminScript(command)], env: [:])
            }
        }
    }

    /// Fixes every failed check that runs as root, behind one password
    /// dialog. The caller has shown the commands and had them confirmed.
    func secureAll() async {
        guard busy == nil, let command = Fix.rootCommands(for: snapshot?.security ?? []) else { return }
        busy = "Securing this Mac"
        defer { busy = nil }
        let failed = await asRoot(command)
        message = failed.map { Message(text: "This Mac: not changed. \($0)", failed: true) }
            ?? Message(text: "This Mac: fixed.", failed: false)
        await refresh()
    }

    // MARK: Targets

    /// Opens or closes a target's list of what is not in place.
    func toggle(_ target: String) {
        expanded = expanded == target ? nil : target
        if let expanded, targetItems[expanded] == nil { Task { await loadItems(expanded) } }
    }

    func loadItems(_ target: String) async {
        guard let careCLI else { return }
        do {
            targetItems[target] = try await careCLI.items(targets: [target], states: ["missing", "differs", "manual"])
        } catch {
            message = Message(text: error.localizedDescription, failed: true)
        }
    }

    // MARK: Changes

    /// Upgrades one package, which its Update button already asked for.
    func update(_ item: Item) async {
        await changeItem(item, upgrade: true, label: "Updating \(item.name)")
    }

    /// Puts one missing or differing item in place.
    func fix(_ item: Item) async {
        await changeItem(item, upgrade: false, label: "Fixing \(item.name)")
    }

    func fixTarget(_ target: String) async {
        await change("Applying \(target)", confirm: true) {
            (try await $0.plan(targets: [target], savingTo: self.planFile), false)
        }
    }

    func updateAll() async {
        await change("Updating " + Self.counted(snapshot?.outdated.count ?? 0, "package"), confirm: true) {
            (try await $0.plan(upgrade: true, savingTo: self.planFile), false)
        }
    }

    func apply() async {
        await change("Applying", confirm: true) { (try await $0.plan(savingTo: self.planFile), false) }
    }

    /// Plans just the item. When no change carries one of its names, the
    /// whole target is planned instead, and the owner sees what that holds.
    private func changeItem(_ item: Item, upgrade: Bool, label: String) async {
        guard let target = item.target else { return }
        await change(label, confirm: false) { ws in
            let doc = try await ws.plan(upgrade: upgrade, targets: [target], only: item.planNames, savingTo: self.planFile)
            if doc.actions.contains(where: { $0.manual != true }) { return (doc, false) }
            return (try await ws.plan(upgrade: upgrade, targets: [target], savingTo: self.planFile), true)
        }
    }

    /// Shows what apply would change, without changing anything.
    func showPlan() async {
        guard let careCLI else { return }
        busy = "Planning"
        defer { busy = nil }
        do {
            plan = try await careCLI.plan(savingTo: planFile)
        } catch {
            message = Message(text: error.localizedDescription, failed: true)
        }
    }

    /// Plans, asks when confirm is set, the plan widened, or it deletes,
    /// then applies exactly the plan that was shown.
    private func change(_ label: String, confirm: Bool,
                        plan make: @escaping (CareCLI) async throws -> (PlanDoc, widened: Bool)) async {
        guard let careCLI, busy == nil else { return }
        busy = label
        defer { busy = nil }
        do {
            let (doc, widened) = try await make(careCLI)
            let executable = doc.actions.filter { $0.manual != true }
            guard !executable.isEmpty else {
                message = Message(text: "Nothing to change.", failed: false)
                return
            }
            if confirm || widened || doc.deletes, !Alerts.confirm(plan: doc) { return }
            let result = try await careCLI.apply(saved: planFile)
            let log = writeLog(result)
            plan = nil
            message = result.status == 0
                ? Message(text: "\(label): done and verified.", failed: false, log: log)
                : Message(text: lastLine(of: result) ?? "\(label) failed.", failed: true, log: log)
        } catch {
            message = Message(text: error.localizedDescription, failed: true)
        }
        await refresh()
    }

    private func lastLine(of r: CommandResult?) -> String? {
        guard let r else { return nil }
        return (r.output + r.stderr).split(whereSeparator: \.isNewline).last { $0.contains("fail") || $0.contains("error") }
            .map(String.init)
    }

    /// Keeps the last change's whole output, for the Show log link.
    private func writeLog(_ r: CommandResult) -> URL? {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ZCCare")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("last-change.log")
        let text = r.output + (r.stderr.isEmpty ? "" : "\n--- stderr\n" + r.stderr)
        return (try? text.write(to: file, atomically: true, encoding: .utf8)) == nil ? nil : file
    }

    // MARK: Apps

    /// The targets that install packages on this Mac.
    private var packageTargets: [String] {
        snapshot?.targets.filter { $0.provider == "packages" }.map(\.target) ?? []
    }

    /// Every package the config declares, for the app picker; nil until
    /// the CLI can run.
    func appChoice() async throws -> AppChoice? {
        guard let careCLI else { return nil }
        if snapshot == nil { await refresh() }
        return AppChoice(items: try await careCLI.items(targets: packageTargets))
    }

    /// Puts what the owner left out on the skip list, takes what they picked
    /// again off it, then installs the rest. True when the apply went through.
    func install(_ choice: AppChoice) async -> Bool {
        guard let careCLI, busy == nil else { return false }
        do {
            try await careCLI.skip(choice.toSkip)
            try await careCLI.skip(choice.toUnskip, undo: true)
        } catch {
            message = Message(text: error.localizedDescription, failed: true)
            return false
        }
        let targets = packageTargets
        message = nil
        await change("Installing apps", confirm: false) {
            (try await $0.plan(targets: targets, savingTo: self.planFile), false)
        }
        return message?.failed == false
    }

    // MARK: Services

    func service(_ item: Item, _ action: ServiceAction) async {
        let brew = program("brew") ?? "/opt/homebrew/bin/brew"
        guard busy == nil,
              let (program, args) = Launchd.command(action, for: item, uid: getuid(), home: NSHomeDirectory(), brew: brew)
        else { return }
        busy = "\(action.rawValue.capitalized) \(item.name)"
        defer { busy = nil }
        let r = try? await ProcessRunner().run(program, args, env: env)
        message = r?.status == 0
            ? Message(text: "\(item.name): \(action == .run ? "started" : action.rawValue + " done").", failed: false)
            : Message(text: "\(item.name): \(lastLine(of: r) ?? "\(action.rawValue) failed").", failed: true)
        await refresh()
    }

    func run(_ job: Job) async {
        await service(Item(name: job.label, kind: "agent", state: "in place"), .run)
    }

    /// The scheduled agents among the services, with what launchd says of
    /// their last run; launchctl is asked about every agent at once.
    private func readJobs(_ services: [Item]) async -> [Job] {
        var jobs: [Job] = []
        let home = NSHomeDirectory()
        var plists: [(String, [String: Any], [DateComponents])] = []
        for agent in services where agent.kind == "agent" {
            let path = Launchd.agentPath(agent.name, home: home)
            guard let data = FileManager.default.contents(atPath: path),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { continue }
            let schedule = Launchd.schedule(plist: plist)
            if !schedule.isEmpty { plists.append((agent.name, plist, schedule)) }
        }
        let uid = getuid()
        let prints = await withTaskGroup(of: (String, String?).self) { group in
            for (label, _, _) in plists {
                group.addTask {
                    let r = try? await ProcessRunner(timeout: 30).run("/bin/launchctl", ["print", "gui/\(uid)/\(label)"], env: [:])
                    return (label, r?.output)
                }
            }
            var outputs: [String: String] = [:]
            for await (label, output) in group { outputs[label] = output }
            return outputs
        }
        for (label, plist, schedule) in plists {
            var job = Job(label: label, schedule: schedule)
            if let output = prints[label] {
                (job.running, job.lastExit) = Launchd.parsePrint(output)
            }
            let log = Launchd.log(label: label, plist: plist, home: home)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: log) {
                job.log = URL(fileURLWithPath: log)
                job.lastRun = attrs[.modificationDate] as? Date
            }
            jobs.append(job)
        }
        return jobs
    }

    // MARK: Findings

    func fix(_ check: Check) async {
        guard busy == nil else { return }
        switch Fix(for: check) {
        case .command(let command):
            guard Alerts.confirm(fix: command, for: check.title) else { return }
            busy = "Fixing \(check.title)"
            defer { busy = nil }
            let failed = await asRoot(command)
            message = failed.map { Message(text: "\(check.title): not changed. \($0)", failed: true) }
                ?? Message(text: "\(check.title): fixed.", failed: false)
            await refresh()
        case .settings(let url, let what):
            NSWorkspace.shared.open(url)
            message = Message(text: what, failed: false)
        case .info(let text):
            Alerts.info(check.title, text)
        }
    }

    func ignore(_ check: Check) { ignored.insert(check.name) }
    func unignoreAll() { ignored.removeAll() }

    // MARK: My Workstation

    /// Reads every item the config declares, and what was applied, for My
    /// Workstation.
    func loadWorkstation() async {
        guard let careCLI else { return }
        async let items = careCLI.items()
        async let log = careCLI.history()
        do {
            inventory = try await items
            history = try await log
        } catch {
            message = Message(text: error.localizedDescription, failed: true)
        }
    }

    func stop() {
        ticker?.cancel()
        watcher?.cancel()
    }

    // MARK: SketchyBar

    /// Hands the count to SketchyBar's zccare item, which reads it from a file
    /// when the zccare_changed event says it changed.
    private func publish() {
        let value = setupProblem != nil ? "setup" : snapshot.map { String($0.attention(ignoring: ignored)) }
        guard let value else { return }
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = support.appendingPathComponent("ZCCare")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? value.write(to: dir.appendingPathComponent("attention"), atomically: true, encoding: .utf8)
        guard let bar = program("sketchybar") else { return }
        // sketchybar finds its server by $USER, so it gets the login environment.
        let env = env
        Task.detached {
            _ = try? await ProcessRunner(timeout: 10).run(bar, ["--trigger", "zccare_changed"], env: env)
        }
    }

    // MARK: Login item

    var opensAtLogin = SMAppService.mainApp.status == .enabled {
        didSet {
            guard opensAtLogin != oldValue else { return }
            do {
                if opensAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                message = Message(text: "Open at login: \(error.localizedDescription)", failed: true)
                opensAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }
}
