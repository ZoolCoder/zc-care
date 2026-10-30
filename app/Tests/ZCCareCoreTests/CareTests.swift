import Foundation
import ImageIO
import Testing
@testable import ZCCareCore

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("zccare-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ url: URL, bytes: Int) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 7, count: bytes).write(to: url)
}

@Test func largeFilesSkipLibraryHiddenAndSmallFiles() throws {
    let home = try tempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    try write(home.appendingPathComponent("Movies/big.mov"), bytes: 400_000)
    try write(home.appendingPathComponent("Downloads/mid.zip"), bytes: 200_000)
    try write(home.appendingPathComponent("Downloads/tiny.txt"), bytes: 10)
    try write(home.appendingPathComponent("Library/Caches/huge.bin"), bytes: 500_000)
    try write(home.appendingPathComponent(".cache/hidden.bin"), bytes: 500_000)
    try write(home.appendingPathComponent("Code/app/node_modules/x/bin"), bytes: 500_000)
    try write(home.appendingPathComponent("go/pkg/mod/m@v1/big.db"), bytes: 500_000)

    let paths = ["Movies/big.mov", "Downloads/mid.zip", "Downloads/tiny.txt", "Library/Caches/huge.bin",
                 ".cache/hidden.bin", "Code/app/node_modules/x/bin", "go/pkg/mod/m@v1/big.db",
                 "Gone/missing.bin"].map { home.path + "/" + $0 } + ["/elsewhere/x.bin"]
    let found = LargeFiles.files(paths: paths, home: home.path, minimum: 100_000)

    #expect(found.map(\.name) == ["big.mov", "mid.zip"])
}

@Test func caskAppsMapsBundlesToTokens() {
    let json = """
    {"casks":[{"token":"visual-studio-code","artifacts":[{"uninstall":[{"quit":"com.microsoft.VSCode"}]},
      {"app":["Visual Studio Code.app"],"target":"/Applications/Visual Studio Code.app"}]},
     {"token":"font-x","artifacts":[{"font":["x.ttf"]}]}]}
    """
    #expect(AppCatalog.caskApps(brewInfo: Data(json.utf8)) == ["Visual Studio Code.app": "visual-studio-code"])
}

@Test func declaredMatchesCaskTokenAndAppStorePrefix() {
    var keynote = Item(name: "Keynote", kind: "mas", state: "in place")
    keynote.app = "Keynote"
    let code = Item(name: "visual-studio-code", kind: "cask", state: "in place")
    let items = [keynote, code]

    #expect(AppCatalog.declared(name: "Visual Studio Code", source: .cask("visual-studio-code"), items: items) == code)
    #expect(AppCatalog.declared(name: "Keynote Creator Studio", source: .appStore, items: items) == keynote)
    #expect(AppCatalog.declared(name: "AnyDesk", source: .cask("anydesk"), items: items) == nil)
    #expect(AppCatalog.declared(name: "Keynote", source: .other, items: items) == nil)
}

@Test func leftoversListOnlyWhatExists() throws {
    let home = try tempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    try write(home.appendingPathComponent("Library/Caches/com.x.app/c"), bytes: 1)
    try write(home.appendingPathComponent("Library/Preferences/com.x.app.plist"), bytes: 1)
    try write(home.appendingPathComponent("Library/Application Support/X/data"), bytes: 1)
    try write(home.appendingPathComponent("Library/LaunchAgents/com.x.app.helper.plist"), bytes: 1)
    try write(home.appendingPathComponent("Library/LaunchAgents/com.x.apple.plist"), bytes: 1)
    try write(home.appendingPathComponent("Library/Preferences/ByHost/com.x.app.ABC.plist"), bytes: 1)

    let found = Leftovers.paths(bundleID: "com.x.app", name: "X", home: home.path)

    #expect(Set(found.map { URL(fileURLWithPath: $0).lastPathComponent })
        == ["X", "com.x.app", "com.x.app.plist", "com.x.app.helper.plist", "com.x.app.ABC.plist"])
    #expect(Leftovers.agents(in: found).map { URL(fileURLWithPath: $0).lastPathComponent } == ["com.x.app.helper.plist"])
}

@Test func leftoversStayInsideTheLibrary() throws {
    let home = try tempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    try write(home.appendingPathComponent("Documents/keep"), bytes: 1)
    try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Caches"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Application Support"), withIntermediateDirectories: true)

    // A planted app's Info.plist names a folder outside the Library.
    for id in ["../../Documents", "", ".", "com.x/../../../Documents", "com.\u{0430}pple.x"] {
        #expect(Leftovers.paths(bundleID: id, name: "Y", home: home.path).isEmpty, "\(id)")
    }
    for name in ["", ".", ".."] {
        #expect(Leftovers.paths(bundleID: nil, name: name, home: home.path).isEmpty, "\(name)")
    }
    #expect(Leftovers.isBundleID("com.x-y.app_2"))
}

@Test func duplicateKeeperIsTheOldestCopy() {
    let old = LargeFile(url: URL(fileURLWithPath: "/u/Downloads/a/b/x.mov"), size: 1, modified: Date(timeIntervalSince1970: 10))
    let new = LargeFile(url: URL(fileURLWithPath: "/u/x.mov"), size: 1, modified: Date(timeIntervalSince1970: 20))
    let group = DuplicateGroup(files: [new, old], size: 1)
    #expect(group.keeper == old)
    #expect(group.others == [new])
    let tied = DuplicateGroup(files: [LargeFile(url: URL(fileURLWithPath: "/u/long/x.mov"), size: 1), LargeFile(url: URL(fileURLWithPath: "/u/x.mov"), size: 1)], size: 1)
    #expect(tied.keeper.url.path == "/u/x.mov")
}

@Test func stillSameDropsCopiesEditedSinceTheScan() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let names = ["a", "b", "c"]
    for name in names { try Data("same".utf8).write(to: dir.appendingPathComponent(name)) }
    try Data("edit".utf8).write(to: dir.appendingPathComponent("c"))
    let files = names.enumerated().map { i, name in
        LargeFile(url: dir.appendingPathComponent(name), size: 4, modified: Date(timeIntervalSince1970: Double(i)))
    }
    #expect(Duplicates.stillSame(DuplicateGroup(files: files, size: 4)).map(\.url.lastPathComponent) == ["b"])
}

@Test func workingInNamesCommandsWhoseFolderIsInside() {
    let out = "p1\nczsh\nfcwd\nn/Users/u/dev/app/src\np2\ncnode\nfcwd\nn/Users/u/dev/app\np3\ncvim\nfcwd\nn/Users/u/dev/apple\n"
    #expect(OpenFile.workingIn("/Users/u/dev/app", out) == ["zsh", "node"])
    #expect(OpenFile.workingIn("/Users/u/dev/other", out).isEmpty)
}

@Test func spaceLensTrashesOnlyBelowTheHomeFoldersOwn() {
    let home = "/Users/u"
    #expect(SpaceLens.canTrash("/Users/u/Developer/old-project", home: home))
    #expect(SpaceLens.canTrash("/Users/u/Movies/raw", home: home))
    #expect(SpaceLens.canTrash("/Users/u/VirtualBox VMs", home: home))
    #expect(!SpaceLens.canTrash("/Users/u", home: home))
    #expect(!SpaceLens.canTrash("/Users/u/Documents", home: home))
    #expect(!SpaceLens.canTrash("/Users/u/.ssh", home: home))
    #expect(!SpaceLens.canTrash("/Users/u/.config/gh", home: home))
    #expect(!SpaceLens.canTrash("/Users/u/Library/Mobile Documents/com~apple~CloudDocs", home: home))
    #expect(!SpaceLens.canTrash("/Users/other/Movies/raw", home: home))
    #expect(!SpaceLens.canTrash("/Users/u/Dropbox (Personal)/old", home: home))
    #expect(!SpaceLens.canTrash("/Users/u/OneDrive - Work/big", home: home))
}

@Test func spaceNodeRemovingShrinksEachFolderAbove() {
    let tree = SpaceNode(path: "/h", size: 100, children: [
        SpaceNode(path: "/h/a", size: 60, children: [SpaceNode(path: "/h/a/x", size: 40, children: [])]),
        SpaceNode(path: "/h/b", size: 30, children: []),
    ])
    let left = tree.removing("/h/a/x")
    #expect(left.size == 60)
    #expect(left.find("/h/a")?.size == 20)
    #expect(left.find("/h/a/x") == nil)
    #expect(left.find("/h/b")?.size == 30)
    #expect(tree.removing("/h/none") == tree)
}

@Test func appFilesAreTheAppAndItsLeftoversLessIgnored() throws {
    let home = try tempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    let bundle = home.appendingPathComponent("Applications/X.app")
    try write(bundle.appendingPathComponent("Contents/MacOS/X"), bytes: 5000)
    try write(home.appendingPathComponent("Library/Caches/com.x.app/c"), bytes: 1)
    try write(home.appendingPathComponent("Library/Preferences/com.x.app.plist"), bytes: 1)
    let app = InstalledApp(name: "X", url: bundle, bundleID: "com.x.app", source: .other)

    let files = Leftovers.files(of: app, home: home.path,
                                ignoring: IgnoreList([home.appendingPathComponent("Library/Preferences/com.x.app.plist").path]))

    #expect(files.map(\.name) == ["X.app", "com.x.app"])
    #expect(files[0].size >= 5000)
}

@Test func unusedAfterNinetyDaysOrNever() {
    var app = InstalledApp(name: "X", url: URL(fileURLWithPath: "/Applications/X.app"), bundleID: nil, source: .other)
    #expect(app.unused())
    app.lastUsed = .now.addingTimeInterval(-10 * 86400)
    #expect(!app.unused())
    app.lastUsed = .now.addingTimeInterval(-100 * 86400)
    #expect(app.unused())
    app.lastUsed = nil
    app.added = .now.addingTimeInterval(-1 * 86400)
    #expect(!app.unused(), "a fresh install without a use date is not unused")
    app.added = .now.addingTimeInterval(-100 * 86400)
    #expect(app.unused())
}

@Test func launchAgentParsesProgramAndFlags() {
    let agent = LaunchAgent.parse(plist: ["Label": "sh.brew.borders", "ProgramArguments": ["/opt/homebrew/bin/borders", "-x"],
                                          "RunAtLoad": true, "KeepAlive": ["SuccessfulExit": false], "Disabled": true],
                                  path: "/p.plist")
    #expect(agent?.program == "/opt/homebrew/bin/borders")
    #expect(agent?.runAtLoad == true)
    #expect(agent?.keepAlive == true)
    #expect(agent?.enabled == false)
    #expect(LaunchAgent.parse(plist: ["Program": "/x"], path: "/p.plist") == nil)
    #expect(LaunchAgent(label: "a", path: "/p", program: "/no/such/tool", runAtLoad: true, keepAlive: false).broken)
    #expect(!LaunchAgent(label: "a", path: "/p", program: "/bin/sh", runAtLoad: true, keepAlive: false).broken)
    #expect(!LaunchAgent(label: "a", path: "/p", program: "sh", runAtLoad: true, keepAlive: false).broken)
}

@Test func launchctlDisabledAndRunning() {
    let disabled = """
    \tdisabled services = {
    \t\t"com.docker.helper" => enabled
    \t\t"com.apple.enrollagent" => disabled
    \t}
    """
    #expect(Launchd.parseDisabled(disabled) == ["com.docker.helper": false, "com.apple.enrollagent": true])
    let list = "PID\tStatus\tLabel\n-\t0\tcom.apple.idle\n2269\t0\tcom.apple.progressd\n"
    #expect(Launchd.parseRunning(list) == ["com.apple.progressd"])
}

@Test func careScanRoundTripsThroughDisk() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    var app = InstalledApp(name: "Ghostty", url: URL(fileURLWithPath: "/Applications/Ghostty.app"), bundleID: "com.mitchellh.ghostty",
                           source: .cask("ghostty"), declared: Item(name: "ghostty", kind: "cask", state: "ok"))
    app.size = 120
    let agent = LaunchAgent(label: "local.x", path: "/p.plist", program: "/bin/sh", runAtLoad: true, keepAlive: false)
    let scan = CareScan(scannedAt: Date(timeIntervalSince1970: 1_700_000_000), junk: ["caches": 42],
                        largeFiles: [LargeFile(url: URL(fileURLWithPath: "/tmp/big.mov"), size: 9, modified: nil)],
                        apps: [app], agents: [agent])
    let url = dir.appendingPathComponent("sub/care.json")

    try scan.save(to: url)

    #expect(CareScan.load(from: url) == scan)
    #expect(CareScan.load(from: dir.appendingPathComponent("none.json")) == nil)
}

@Test func duplicatesGroupSameBytesOnly() throws {
    let home = try tempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    try write(home.appendingPathComponent("Downloads/a.zip"), bytes: 300_000)
    try write(home.appendingPathComponent("Documents/a copy.zip"), bytes: 300_000)
    try write(home.appendingPathComponent("Movies/b.mov"), bytes: 300_000)
    try Data(repeating: 9, count: 300_000).write(to: home.appendingPathComponent("Movies/b.mov"))
    try write(home.appendingPathComponent("Movies/c.mov"), bytes: 200_000)

    let paths = ["Downloads/a.zip", "Documents/a copy.zip", "Movies/b.mov", "Movies/c.mov"].map { home.path + "/" + $0 }
    let groups = Duplicates.groups(paths: paths, home: home.path, minimum: 100_000)

    #expect(groups.count == 1)
    #expect(Set(groups[0].files.map(\.name)) == ["a.zip", "a copy.zip"])
    #expect(groups[0].wasted == 300_000)

    try write(home.appendingPathComponent("Developer/site/.git/HEAD"), bytes: 10)
    try write(home.appendingPathComponent("Developer/site/public/a.zip"), bytes: 300_000)
    let withRepo = Duplicates.groups(paths: paths + [home.path + "/Developer/site/public/a.zip"], home: home.path, minimum: 100_000)
    #expect(withRepo.map(\.files.count) == [2])
}

@Test func oldDownloadsGoByAge() throws {
    let folder = try tempDir()
    defer { try? FileManager.default.removeItem(at: folder) }
    try write(folder.appendingPathComponent("old.dmg"), bytes: 1000)
    try write(folder.appendingPathComponent("new.dmg"), bytes: 1000)
    try write(folder.appendingPathComponent(".hidden"), bytes: 1000)

    let later = Date.now.addingTimeInterval(31 * 86400)
    #expect(OldDownloads.files(in: folder, now: .now).isEmpty)
    #expect(Set(OldDownloads.files(in: folder, now: later).map(\.name)) == ["old.dmg", "new.dmg"])
}

@Test func junkEmptiesOnlyThePickedEntries() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try write(dir.appendingPathComponent("a/x.bin"), bytes: 50_000)
    try write(dir.appendingPathComponent("b.bin"), bytes: 10_000)
    try write(dir.appendingPathComponent("kept/y.bin"), bytes: 10_000)
    let spot = Junk(id: "t", title: "T", detail: "", path: dir.path, keep: ["kept"])

    #expect(spot.contents().map(\.name) == ["a", "b.bin"])
    spot.empty(only: ["b.bin"], permanently: true)
    #expect(spot.contents().map(\.name) == ["a"])
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("kept/y.bin").path))
}

@Test func backgroundItemsReadTheUsersRunningRecords() {
    let dump = """
     Records for UID 501 : X
     Items:
     #1:
                     Name: (null)
                     Type: developer (0x20)
              Disposition: [disabled, allowed, not notified] (0x2)
               Identifier: Unknown Developer
     #2:
                     Name: CleanMyMac Menu
           Developer Name: MacPaw Way Ltd
                     Type: login item (0x4)
              Disposition: [enabled, allowed, notified] (0xb)
               Identifier: 4.com.macpaw.CleanMyMac5.Menu
        Parent Identifier: 2.com.macpaw.CleanMyMac5
     #3:
                     Name: GoogleUpdater
                     Type: legacy agent (0x10008)
              Disposition: [disabled, allowed, notified] (0xa)
               Identifier: 8.com.google.GoogleUpdater.wake
          Executable Path: /x/GoogleUpdater
     Records for UID 502 : Y
     #1:
                     Name: Other
                     Type: login item (0x4)
              Disposition: [enabled, allowed, notified] (0xb)
               Identifier: 4.other
    """
    let items = BackgroundItems.parse(dump, uid: 501)

    #expect(items.map(\.name) == ["CleanMyMac Menu", "GoogleUpdater"])
    #expect(items[0].enabled && items[0].developer == "MacPaw Way Ltd" && items[0].parent == "2.com.macpaw.CleanMyMac5")
    #expect(!items[1].enabled && items[1].kind == "legacy agent" && items[1].executable == "/x/GoogleUpdater")
}

@Test func gatekeeperAssessment() {
    let ok = Assessment.parse("/Applications/A.app: accepted\nsource=Notarized Developer ID\n")
    let bad = Assessment.parse("/Applications/B.app: rejected\nsource=no usable signature\n")
    let adhoc = Assessment.parse("/Applications/C.app: accepted\nsource=Unnotarized Developer ID\n")

    #expect(ok.trusted && ok.source == "Notarized Developer ID")
    #expect(!bad.accepted && !bad.trusted)
    #expect(adhoc.accepted && !adhoc.trusted)
}

@Test func privacyRowsKeepKnownServices() {
    let rows = Privacy.parse("""
    kTCCServiceCamera|us.zoom.xos|0|2
    kTCCServiceMicrophone|us.zoom.xos|0|0
    kTCCServiceUbiquity|com.apple.x|0|2
    kTCCServiceCamera|us.zoom.xos|0|2
    kTCCServiceSystemPolicyAllFiles|/usr/local/bin/tool|1|2
    kTCCServiceBluetoothAlways|-bad id|0|2
    """)

    #expect(rows == [Permission(service: "Camera", client: "us.zoom.xos", allowed: true, resetName: "Camera"),
                     Permission(service: "Microphone", client: "us.zoom.xos", allowed: false, resetName: "Microphone"),
                     Permission(service: "Full Disk Access", client: "/usr/local/bin/tool", allowed: true),
                     Permission(service: "Bluetooth", client: "-bad id", allowed: true)])
    #expect(Privacy.resetArguments(rows[0]) == ["reset", "Camera", "us.zoom.xos"])
    // A path, or a name that would read as a flag, is never handed to tccutil.
    #expect(Privacy.resetArguments(rows[2]) == nil)
    #expect(Privacy.resetArguments(rows[3]) == nil)
}

@Test func spaceLensBuildsATreeOfTheBiggest() {
    let du = """
    10\t/h/a/tiny
    4000\t/h/a/big
    5000\t/h/a
    3000\t/h/b
    9000\t/h
    """
    let root = SpaceLens.parse(du: du, root: "/h")

    #expect(root?.size == Int64(9000 * 1024))
    #expect(root?.children.map(\.name) == ["a", "b"])
    #expect(root?.find("/h/a")?.children.map(\.name) == ["big"])
    #expect(SpaceLens.parse(du: du, root: "/elsewhere") == nil)
}

@Test func spaceLensStaysOutOfMediaLibraries() {
    let args = SpaceLens.arguments(root: "/h")
    #expect(args.last == "/h")
    #expect(args.contains("*.photoslibrary"))
    #expect(args.contains("*.musiclibrary"))
}

@Test func uninstallRoutes() {
    var item = Item(name: "raycast", kind: "cask", state: "ok")
    item.target = "apps"

    #expect(Uninstall.method(declared: item, source: .cask("raycast")) == .remove(target: "apps", resource: "cask:raycast"))
    #expect(Uninstall.method(declared: nil, source: .cask("zoom")) == .cask("zoom"))
    #expect(Uninstall.method(declared: nil, source: .appStore) == .trash)
    #expect(Uninstall.method(declared: nil, source: .other) == .trash)
}

@Test func launchdToggleSteps() {
    let off = Launchd.toggleSteps(domain: "gui/501", label: "a.b", plist: "/p.plist", on: false)
    let on = Launchd.toggleSteps(domain: "gui/501", label: "a.b", plist: "/p.plist", on: true)

    #expect(off == [["bootout", "gui/501/a.b"], ["disable", "gui/501/a.b"]])
    #expect(on == [["enable", "gui/501/a.b"], ["bootstrap", "gui/501", "/p.plist"]])
    #expect(off.map(Launchd.mustSucceed) == [false, true])
    #expect(on.map(Launchd.mustSucceed) == [true, false])
}

@Test func careScheduleAndAlerts() {
    let now = Date.now
    #expect(CareSchedule.due(last: nil, now: now))
    #expect(!CareSchedule.due(last: now.addingTimeInterval(-6 * 86400), now: now))
    #expect(CareSchedule.due(last: now.addingTimeInterval(-7 * 86400), now: now))

    #expect(CareSchedule.alerts(junk: 1024, outdated: 0, findings: 0).isEmpty)
    var failing = DiskHealth()
    failing.smart = "Failing"
    #expect(CareSchedule.alerts(junk: 0, outdated: 0, findings: 0, drive: failing).map(\.id) == ["care drive"])
    failing.smart = "Verified"
    #expect(CareSchedule.alerts(junk: 0, outdated: 0, findings: 0, drive: failing).isEmpty)
    let alerts = CareSchedule.alerts(junk: 3 * 1024 * 1024 * 1024, outdated: 2, findings: 1)
    #expect(alerts.map(\.id) == ["care junk", "care updates", "care health"])
    #expect(alerts.allSatisfy { $0.id.hasPrefix("care") })
}

@Test func caskIndexMapsAppsToCasks() throws {
    let payload = #"{"casks":{"raycast":{"raw_artifacts":[[":uninstall",{":quit":"x"}],[":app",["Raycast.app"]]]},"#
        + #""zoom":{"raw_artifacts":[[":pkg",["zoom.pkg"]]]},"vscode":{"raw_artifacts":[[":app",["Visual Studio Code.app",{"target":"x"}]]]}}}"#
    let jws = try JSONSerialization.data(withJSONObject: ["payload": payload, "signature": "s"])

    #expect(CaskIndex.apps(jws: jws) == ["Raycast.app": "raycast", "Visual Studio Code.app": "vscode"])

    var a = Item(name: "a", kind: "cask", state: "ok"); a.target = "apps"
    var b = Item(name: "b", kind: "cask", state: "ok"); b.target = "apps"
    var c = Item(name: "c", kind: "cask", state: "ok"); c.target = "dev"
    var d = Item(name: "d", kind: "brew", state: "ok"); d.target = "dev"
    #expect(CaskIndex.target(items: [a, b, c, d]) == "apps")
    #expect(CaskIndex.target(items: [d]) == nil)
}

@Test func openFileNamesEachHolderOnce() {
    #expect(OpenFile.holders("p501\ncUTM\np502\ncQEMULauncher\np503\ncUTM\n") == ["UTM", "QEMULauncher"])
    #expect(OpenFile.holders("").isEmpty)
}

@Test func idleProjectDependenciesOnly() throws {
    let root = try tempDir()
    let old = Date.now.addingTimeInterval(-200 * 86400)
    try write(root.appendingPathComponent("idle/node_modules/a/index.js"), bytes: 4096)
    try write(root.appendingPathComponent("idle/package.json"), bytes: 10)
    try write(root.appendingPathComponent("busy/node_modules/b/index.js"), bytes: 4096)
    try write(root.appendingPathComponent("busy/package.json"), bytes: 10)
    try write(root.appendingPathComponent("rusty/target/debug/x"), bytes: 4096)
    try write(root.appendingPathComponent("rusty/Cargo.toml"), bytes: 10)
    try write(root.appendingPathComponent("plain/target/x"), bytes: 4096)
    try write(root.appendingPathComponent("plain/notes.txt"), bytes: 10)
    try write(root.appendingPathComponent("edited/node_modules/c/index.js"), bytes: 4096)
    try write(root.appendingPathComponent("edited/package.json"), bytes: 10)
    try write(root.appendingPathComponent("edited/src/app.ts"), bytes: 10)
    for path in ["idle/package.json", "rusty/Cargo.toml", "plain/notes.txt", "edited/package.json", "edited/src"] {
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: root.appendingPathComponent(path).path)
    }
    let found = ProjectDependencies.find(roots: [root]).map { $0.url.pathComponents.suffix(2).joined(separator: "/") }
    #expect(Set(found) == ["idle/node_modules", "rusty/target"])

    let deps = ProjectDependencies.find(roots: [root])
    let idle = try #require(deps.first { $0.url.lastPathComponent == "node_modules" }).url.deletingLastPathComponent().path
    let serving = ["node \(idle)/node_modules/.bin/vite --port 5173", "/bin/zsh -l"]
    #expect(ProjectDependencies.running(deps, commands: serving).map { $0.url.lastPathComponent } == ["node_modules"])
    #expect(ProjectDependencies.running(deps, commands: ["cat \(idle)r/x"]).isEmpty)
}

@Test func ollamaModelsKeepSharedBlobs() throws {
    let root = try tempDir()
    func manifest(_ path: String, _ digests: [String]) throws {
        let layers = digests.map { "{\"digest\":\"\($0)\",\"size\":100}" }.joined(separator: ",")
        let url = root.appendingPathComponent("manifests/registry.ollama.ai/" + path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"layers\":[\(layers)]}".utf8).write(to: url)
    }
    try manifest("library/llama3/latest", ["sha256:" + String(repeating: "a", count: 64), "sha256:" + String(repeating: "c", count: 64)])
    try manifest("someone/coder/7b", ["sha256:" + String(repeating: "b", count: 64), "sha256:" + String(repeating: "c", count: 64)])
    let models = AIModels.ollama(root: root).sorted { $0.name < $1.name }
    #expect(models.map(\.name) == ["llama3:latest", "someone/coder:7b"])
    #expect(models[0].size == 200)
    #expect(models[0].paths.map(\.lastPathComponent) == ["latest", "sha256-" + String(repeating: "a", count: 64)])
}

@Test func huggingFaceFoldersNameModels() throws {
    let hub = try tempDir()
    try write(hub.appendingPathComponent("models--org--tiny-model/blobs/x"), bytes: 4096)
    try write(hub.appendingPathComponent("datasets--org--set/blobs/x"), bytes: 4096)
    #expect(AIModels.huggingFace(hub: hub).map(\.name) == ["org/tiny-model"])
}

@Test func diskImagesByExtension() throws {
    let dir = try tempDir()
    try write(dir.appendingPathComponent("App.dmg"), bytes: 4096)
    try write(dir.appendingPathComponent("Tool.PKG"), bytes: 8192)
    try write(dir.appendingPathComponent("notes.txt"), bytes: 4096)
    #expect(DiskImages.files(in: [dir]).map(\.name) == ["Tool.PKG", "App.dmg"])
}

@Test func orphansSkipInstalledAppleAndHelpers() throws {
    let home = try tempDir()
    try write(home.appendingPathComponent("Library/Caches/com.gone.app/x"), bytes: 4096)
    try write(home.appendingPathComponent("Library/Preferences/com.gone.app.plist"), bytes: 10)
    try write(home.appendingPathComponent("Library/Caches/com.here.app.helper/x"), bytes: 10)
    try write(home.appendingPathComponent("Library/Caches/com.apple.Safari/x"), bytes: 10)
    try write(home.appendingPathComponent("Library/Caches/Firefox/x"), bytes: 10)
    let orphans = Leftovers.orphans(home: home.path) { $0 == "com.here.app" }
    #expect(orphans.map(\.bundleID) == ["com.gone.app"])
    #expect(orphans[0].paths.count == 2)
    #expect(Leftovers.bundleID("Some.Thing.app") == nil)
    #expect(Leftovers.bundleID("org.x.y.savedState") == "org.x.y")
}

@Test func orphansKeepAppleGroupsAndInstalledVendors() throws {
    let home = try tempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    try write(home.appendingPathComponent("Library/Caches/systemgroup.com.apple.icloud.x/a"), bytes: 10)
    try write(home.appendingPathComponent("Library/Application Support/com.microsoft.shared/a"), bytes: 10)
    try write(home.appendingPathComponent("Library/Caches/com.gone.app/a"), bytes: 10)
    let orphans = Leftovers.orphans(home: home.path, vendors: [Leftovers.vendor("com.Microsoft.teams2")]) { _ in false }
    #expect(orphans.map(\.bundleID) == ["com.gone.app"])
}

@Test func orphansListAnAppSeenRemovedWhateverItsVendor() throws {
    let home = try tempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    try write(home.appendingPathComponent("Library/Caches/com.microsoft.teams2/a"), bytes: 10)
    try write(home.appendingPathComponent("Library/Caches/com.microsoft.shared/a"), bytes: 10)
    let orphans = Leftovers.orphans(home: home.path, vendors: ["com.microsoft"], removed: ["com.microsoft.teams2"]) { _ in false }
    #expect(orphans.map(\.bundleID) == ["com.microsoft.teams2"])
    // Seen removed, yet installed somewhere: its data stays off the list.
    let installed = Leftovers.orphans(home: home.path, vendors: ["com.microsoft"], removed: ["com.microsoft.teams2"]) {
        $0 == "com.microsoft.teams2"
    }
    #expect(installed.isEmpty)
}

@Test func maintenanceQuotesAdminSteps() {
    let script = Maintenance.adminScript([["/usr/bin/killall", "-HUP", "it's"], ["/bin/echo", "a \"b\""]])
    #expect(script == #"do shell script "'/usr/bin/killall' '-HUP' 'it'\\''s' && '/bin/echo' 'a \"b\"'" with administrator privileges"#)
    #expect(Maintenance.tasks(brew: nil, docker: nil, xcode: false).allSatisfy { $0.id != "brew" && $0.id != "docker" })
    let verify = Maintenance.tasks(brew: nil, docker: nil, xcode: false).first { $0.id == "verify" }
    #expect(verify?.steps == [["/usr/sbin/diskutil", "verifyVolume", "/"]] && verify?.admin == false && verify?.every == nil)
    let tasks = Maintenance.tasks(brew: nil, docker: nil, xcode: false)
    #expect(tasks.first { $0.id == "quicklook" }?.admin == false && tasks.first { $0.id == "fonts" }?.admin == false)
    let docker = Maintenance.tasks(brew: "/b", docker: "/d", xcode: true).first { $0.id == "docker" }
    #expect(docker != nil)
    #expect(docker?.steps.allSatisfy { !$0.contains("system") && !$0.contains("container") } == true)
}

@Test func devCachesStayOutOfAppCaches() {
    let spots = Junk.spots(home: "/h")
    let caches = spots.first { $0.id == "caches" }!
    for spot in spots where spot.path.hasPrefix("/h/Library/Caches/") {
        #expect(caches.keep.contains((spot.path as NSString).lastPathComponent))
    }
}

@Test func aiClutterFindsJunkAndKeepsTheRunningVersion() throws {
    let home = try tempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    let versions = home.appendingPathComponent(".local/share/claude/versions")
    try write(versions.appendingPathComponent("2.1.0"), bytes: 300_000)
    try write(versions.appendingPathComponent("2.2.0"), bytes: 200_000)
    try FileManager.default.createDirectory(at: home.appendingPathComponent(".local/bin"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: home.path + "/.local/bin/claude", withDestinationPath: versions.path + "/2.2.0")
    let temp = home.appendingPathComponent("tmp/claude-501")
    try write(temp.appendingPathComponent("old/x"), bytes: 100_000)
    try write(temp.appendingPathComponent("busy/x"), bytes: 100_000)
    for inside in ["old/x", "old"] {
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3 * 86400)],
                                              ofItemAtPath: temp.appendingPathComponent(inside).path)
    }
    try write(home.appendingPathComponent("Library/Application Support/Cursor/Cache/a"), bytes: 50_000)
    try write(home.appendingPathComponent("Library/Application Support/Cursor/User/settings.json"), bytes: 50_000)

    let found = AIClutter.find(home: home.path, claudeTemp: temp.path)

    #expect(found.map(\.id) == ["Claude Code Stale Versions", "Claude Code Temp Files", "Cursor Caches"])
    #expect(found[0].paths.map(\.lastPathComponent) == ["2.1.0"])
    #expect(found[1].paths.map(\.lastPathComponent) == ["old"])
}

@Test func aiClutterSkipsATempFolderThatIsALink() throws {
    let home = try tempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    let documents = home.appendingPathComponent("Documents")
    try write(documents.appendingPathComponent("thesis/x"), bytes: 100_000)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3 * 86400)],
                                          ofItemAtPath: documents.appendingPathComponent("thesis").path)
    let temp = home.appendingPathComponent("claude-501")
    try FileManager.default.createSymbolicLink(at: temp, withDestinationURL: documents)

    #expect(AIClutter.find(home: home.path, claudeTemp: temp.path).isEmpty)
    #expect(Junk(id: "t", title: "T", detail: "", path: temp.path).contents().isEmpty)
}

@Test func aiClutterCallsNoVersionStaleWithoutTheLink() throws {
    let home = try tempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    try write(home.appendingPathComponent(".local/share/claude/versions/2.1.0"), bytes: 300_000)

    #expect(AIClutter.find(home: home.path, claudeTemp: home.path + "/none").isEmpty)
}

@Test func aiClutterKeepsWhatRunsAndOpenAppsCaches() throws {
    let home = try tempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    try write(home.appendingPathComponent(".cache/chrome-devtools-mcp/chrome-profile/a"), bytes: 50_000)
    try write(home.appendingPathComponent("Library/Application Support/Cursor/Cache/a"), bytes: 50_000)
    try write(home.appendingPathComponent("Library/Application Support/Cursor/logs/a"), bytes: 50_000)
    let profile = home.path + "/.cache/chrome-devtools-mcp/chrome-profile"

    let found = AIClutter.find(home: home.path, claudeTemp: home.path + "/none", open: ["Cursor"],
                               commands: ["Chrome --user-data-dir=" + profile + " --x"])

    #expect(found.map(\.id) == ["Cursor Logs"])
    #expect(!AIClutter.used(URL(fileURLWithPath: "/a/b"), by: ["x /a/bc"]))
}

@Test func aiClutterDeletesOnlyWhatIsStillJunk() {
    let busy = URL(fileURLWithPath: "/tmp/claude-501/busy")
    let idle = URL(fileURLWithPath: "/tmp/claude-501/idle")
    let picked = [AIJunk(tool: "Claude Code", kind: "Temp files", paths: [busy, idle], size: 2)]
    let fresh = [AIJunk(tool: "Claude Code", kind: "Temp files", paths: [URL(fileURLWithPath: "/tmp/claude-501/./idle")], size: 1)]

    #expect(AIClutter.stillJunk(picked, in: fresh) == [idle])
    #expect(AIClutter.stillJunk(picked, in: []).isEmpty)
}

@Test func activityLogTotalsByKind() throws {
    let now = Date()
    let log = ActivityLog(entries: [
        ActivityEntry(date: now.addingTimeInterval(-10 * 86400), kind: .junk, title: "Caches", bytes: 500),
        ActivityEntry(date: now.addingTimeInterval(-86400), kind: .ai, title: "Claude Code", bytes: 300),
        ActivityEntry(date: now, kind: .junk, title: "Logs", bytes: 100),
        ActivityEntry(date: now, kind: .maintenance, title: "Flush DNS Cache", bytes: 0),
    ])

    #expect(log.freed == 900)
    #expect(log.freedByKind.map(\.kind) == [.junk, .ai])
    #expect(log.runsByKind.first?.count == 2)
    #expect(log.freed(lastDays: 7, now: now) == 400)

    let url = FileManager.default.temporaryDirectory.appendingPathComponent("zccare-\(UUID().uuidString)/activity.json")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try log.save(to: url)
    #expect(ActivityLog.load(from: url) == log)
}

@Test func browserPrivacyFindsHistoryCookiesAndCacheButNotBookmarks() throws {
    let home = try tempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    let chrome = "Library/Application Support/Google/Chrome/"
    try write(home.appendingPathComponent(chrome + "Default/Preferences"), bytes: 10)
    try write(home.appendingPathComponent(chrome + "Default/History"), bytes: 50_000)
    try write(home.appendingPathComponent(chrome + "Default/History-journal"), bytes: 5_000)
    try write(home.appendingPathComponent(chrome + "Default/Bookmarks"), bytes: 5_000)
    try write(home.appendingPathComponent(chrome + "Profile 1/Preferences"), bytes: 10)
    try write(home.appendingPathComponent(chrome + "Profile 1/Network/Cookies"), bytes: 20_000)
    try write(home.appendingPathComponent(chrome + "System Profile/History"), bytes: 20_000)
    try write(home.appendingPathComponent("Library/Caches/Google/Chrome/Default/Cache/data_0"), bytes: 80_000)
    let firefox = "Library/Application Support/Firefox/Profiles/abc.default/"
    try write(home.appendingPathComponent(firefox + "places.sqlite"), bytes: 40_000)
    try write(home.appendingPathComponent(firefox + "cookies.sqlite"), bytes: 30_000)

    let traces = BrowserPrivacy.find(home: home.path)
    #expect(traces.map(\.id) == ["com.google.Chrome History", "com.google.Chrome Cookies",
                                 "com.google.Chrome Cache", "org.mozilla.firefox Cookies"])
    let names = Set(traces.flatMap(\.paths).map(\.lastPathComponent))
    #expect(names == ["History", "History-journal", "Cookies", "Default", "cookies.sqlite"])

    let history = try #require(traces.first)
    #expect(BrowserPrivacy.clear(history, permanently: true).stayed == 0)
    #expect(!FileManager.default.fileExists(atPath: home.path + "/" + chrome + "Default/History"))
    #expect(FileManager.default.fileExists(atPath: home.path + "/" + chrome + "Default/Bookmarks"))
}

@Test func similarImagesDoNotChainIntoGroups() {
    // 0-1 close, 1-2 close, 0-2 far: 2 stays out, as it is not close to 0. 3-4 close. 5 alone.
    let close: Set<[Int]> = [[0, 1], [1, 2], [3, 4]]
    let groups = SimilarImages.cluster(count: 6) { close.contains([$0, $1]) ? 0.1 : 0.9 }
    #expect(groups == [[0, 1], [3, 4]])
    #expect(SimilarImages.cluster(count: 0) { _, _ in 0 }.isEmpty)
}

@Test func similarImagesKeepTheMostPixels() {
    let at = { (name: String, size: Int64) in LargeFile(url: URL(fileURLWithPath: "/p/" + name), size: size, modified: nil) }
    let pixels = ["small.jpg": 100, "big.jpg": 400, "heavy.png": 100]
    let ranked = SimilarImages.ranked([at("small.jpg", 10), at("heavy.png", 50), at("big.jpg", 20)]) { pixels[$0.lastPathComponent] ?? 0 }
    #expect(ranked.map(\.name) == ["big.jpg", "heavy.png", "small.jpg"])
    let group = SimilarGroup(files: ranked)
    #expect(group.best.name == "big.jpg")
    #expect(group.wasted == 60)
}

/// A JPEG of circles on a gradient; `seed` moves them, an even one makes
/// another scene, and `side` scales it.
private func picture(_ url: URL, side: Int, seed: Int) throws {
    let ctx = try #require(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let colors = seed.isMultiple(of: 2)
        ? [CGColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1), CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1)]
        : [CGColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1), CGColor(red: 0.9, green: 0.8, blue: 0.2, alpha: 1)]
    let gradient = try #require(CGGradient(colorsSpace: nil, colors: colors as CFArray, locations: nil))
    ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: side, y: side), options: [])
    let s = CGFloat(side)
    if seed.isMultiple(of: 2) {
        ctx.setFillColor(CGColor(gray: 0.95, alpha: 1))
        for i in stride(from: 0, to: side, by: side / 12) {
            ctx.fill(CGRect(x: CGFloat(i), y: 0, width: s / 40, height: s * CGFloat(i % 7 + 3) / 10))
        }
    }
    for i in 0..<5 {
        let x = CGFloat((i * 37 + seed * 53) % 100) / 100 * s, y = CGFloat((i * 61 + seed * 29) % 100) / 100 * s
        ctx.setFillColor(CGColor(red: CGFloat(i) / 5, green: 0.1, blue: CGFloat(seed % 3) / 3, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: x, y: y, width: s / 4, height: s / 4))
    }
    let image = try #require(ctx.makeImage())
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
    CGImageDestinationAddImage(dest, image, nil)
    #expect(CGImageDestinationFinalize(dest))
}

@Test func similarImagesGroupACopyAndKeepTheLargest() throws {
    let home = try tempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    let pictures = home.appendingPathComponent("Pictures")
    try picture(pictures.appendingPathComponent("beach.jpg"), side: 1600, seed: 1)
    try picture(pictures.appendingPathComponent("beach copy.jpg"), side: 900, seed: 1)
    try picture(pictures.appendingPathComponent("city.jpg"), side: 1600, seed: 4)
    try picture(home.appendingPathComponent("Pictures/Photos Library.photoslibrary/originals/beach.jpg"), side: 1600, seed: 1)
    try picture(home.appendingPathComponent("Documents/GitHub/site/img/beach.jpg"), side: 1600, seed: 1)
    try write(home.appendingPathComponent("Documents/GitHub/site/.git/HEAD"), bytes: 10)
    let paths = try FileManager.default.subpathsOfDirectory(atPath: home.path).map { home.path + "/" + $0 }

    let groups = SimilarImages.groups(paths: paths, home: home.path, minimum: 1)
    #expect(groups.map { $0.files.map(\.name) } == [["beach.jpg", "beach copy.jpg"]])
}

@Test func cloudDrivesFindICloudFirstThenProviders() throws {
    let home = try tempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    for folder in ["Library/Mobile Documents/com~apple~CloudDocs", "Library/CloudStorage/OneDrive-Personal",
                   "Library/CloudStorage/GoogleDrive-me@example.com", "Library/CloudStorage/.hidden"] {
        try FileManager.default.createDirectory(at: home.appendingPathComponent(folder), withIntermediateDirectories: true)
    }
    let drives = CloudDrives.found(home: home)
    #expect(drives.map(\.name) == ["iCloud Drive", "Google Drive", "OneDrive"])
    #expect(drives.map(\.isICloud) == [true, false, false])
    #expect(CloudDrives.name(folder: "Dropbox") == "Dropbox")
    #expect(CloudDrives.name(folder: "pCloud-Drive") == "pCloud")
}

@Test func cloudDrivesCountDownloadedFilesButListOnlyUploadedOnes() throws {
    let folder = try tempDir()
    defer { try? FileManager.default.removeItem(at: folder) }
    try write(folder.appendingPathComponent("a/big.mov"), bytes: 400_000)
    try write(folder.appendingPathComponent("mid.zip"), bytes: 200_000)
    try write(folder.appendingPathComponent("tiny.txt"), bytes: 10)
    // Only iCloud says a file is uploaded; without that, nothing is offered for removal.
    let found = CloudDrives.downloaded(in: folder, minimum: 100_000)
    #expect(found.files.isEmpty)
    #expect(found.total >= 600_000)
}

@Test func ignoreListCoversItsPathsAndWhatIsInside() {
    var list = IgnoreList(["/Users/me/Projects/", "/Users/me/Projects", "/"])
    #expect(list.paths == ["/Users/me/Projects"])
    #expect(list.covers("/Users/me/Projects"))
    #expect(list.covers(URL(fileURLWithPath: "/Users/me/Projects/app/node_modules")))
    #expect(!list.covers("/Users/me/ProjectsOld/a.zip"))
    #expect(list.names(in: "/Users/me") == ["Projects"])
    list.remove("/Users/me/Projects")
    #expect(!list.covers("/Users/me/Projects/a"))
}

@Test func ignoreListDropsFilesAndBreaksUpGroups() {
    let file = { (path: String) in LargeFile(url: URL(fileURLWithPath: path), size: 1, modified: nil) }
    let list = IgnoreList(["/Users/me/Keep"])
    let kept = file("/Users/me/Keep/a.mov"), other = file("/Users/me/b.mov"), third = file("/Users/me/c.mov")

    #expect(list.keep([kept, other]) == [other])
    #expect(list.keep([DuplicateGroup(files: [kept, other], size: 1)]).isEmpty)
    #expect(list.keep([DuplicateGroup(files: [kept, other, third], size: 1)]).first?.files == [other, third])
}

@Test func putBackMovesTrashedItemsHome() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let trash = root.appendingPathComponent("Trash")
    try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("Downloads/report.pdf")
    let binned = trash.appendingPathComponent("report.pdf")
    try Data("x".utf8).write(to: binned)

    var entry = ActivityEntry(kind: .files, title: "report.pdf", bytes: 1,
                              trashed: [Trashed(original: home, inTrash: binned)])
    #expect(entry.canPutBack)
    #expect(Trashed.putBack(entry.trashed ?? []).isEmpty)
    #expect(FileManager.default.fileExists(atPath: home.path))
    #expect(!entry.canPutBack)

    try FileManager.default.moveItem(at: home, to: binned)
    entry.putBack = .now
    #expect(!entry.canPutBack)
}

@Test func putBackNeverOverwrites() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("a.txt")
    let binned = root.appendingPathComponent("a 2.txt")
    try Data("new".utf8).write(to: home)
    try Data("old".utf8).write(to: binned)

    let entry = ActivityEntry(kind: .files, title: "a.txt", bytes: 3, trashed: [Trashed(original: home, inTrash: binned)])
    #expect(!entry.canPutBack)
    #expect(Trashed.putBack(entry.trashed ?? []) == ["a.txt"])
    #expect(try String(contentsOf: home, encoding: .utf8) == "new")
}

@Test func oldActivityLogsStillLoad() throws {
    let json = #"{"entries":[{"date":0,"kind":"Personal Files","title":"a","bytes":1}]}"#
    let log = try JSONDecoder().decode(ActivityLog.self, from: Data(json.utf8))
    #expect(log.entries.first?.trashed == nil)
    #expect(log.entries.first?.canPutBack == false)
}

@Test func vitalsWatchWarnsOnceAboutLowDisk() {
    var watch = VitalsWatch()
    var v = Vitals()
    v.disk = Disk(name: "Macintosh HD", total: 500_000_000_000, available: 5_000_000_000)
    let now = Date(timeIntervalSince1970: 0)
    #expect(watch.alerts(for: v, now: now).map(\.id) == ["vitals disk"])
    #expect(watch.alerts(for: v, now: now.addingTimeInterval(3600)).isEmpty)
    #expect(watch.alerts(for: v, now: now.addingTimeInterval(7 * 3600)).map(\.id) == ["vitals disk"])
    v.disk?.available = 100_000_000_000
    #expect(watch.alerts(for: v, now: now.addingTimeInterval(14 * 3600)).isEmpty)
}

@Test func vitalsWatchWaitsOutSpikes() {
    var watch = VitalsWatch()
    var v = Vitals()
    let now = Date(timeIntervalSince1970: 0)
    v.memory = Memory(pressure: 95, used: 1, total: 2)
    v.sensors = Sensors(cpuTemp: 101)
    #expect(watch.alerts(for: v, now: now).isEmpty)
    #expect(watch.alerts(for: v, now: now).isEmpty)
    v.memory?.pressure = 30
    #expect(watch.alerts(for: v, now: now).map(\.id) == ["vitals heat"])
    v.memory?.pressure = 95
    #expect(watch.alerts(for: v, now: now).isEmpty)
}

@Test func vitalsWatchFollowsItsLimits() {
    var limits = VitalLimits()
    limits.batteryCapacity = 70
    var watch = VitalsWatch(limits: limits)
    var v = Vitals()
    var battery = Battery(percent: 50)
    battery.health = "Good"
    battery.capacity = 75
    v.battery = battery
    #expect(watch.alerts(for: v).isEmpty)
    watch.limits.batteryCapacity = 80
    #expect(watch.alerts(for: v).map(\.id) == ["vitals battery"])
}

@Test func vitalsWatchWarnsOfAFullTrashOncePerDay() {
    var watch = VitalsWatch()
    var v = Vitals()
    let now = Date(timeIntervalSince1970: 0)
    v.trash = 4_000_000_000
    #expect(watch.alerts(for: v, now: now).isEmpty)
    v.trash = 6_000_000_000
    #expect(watch.alerts(for: v, now: now).map(\.id) == ["vitals trash"])
    #expect(watch.alerts(for: v, now: now.addingTimeInterval(3600)).isEmpty)
    #expect(watch.alerts(for: v, now: now.addingTimeInterval(86400)).map(\.id) == ["vitals trash"])
}

@Test func vitalLimitsKeepOldSettings() throws {
    let old = #"{"diskFreeGB":40,"memoryPressure":90,"cpuTemp":100,"batteryCapacity":60}"#
    let limits = try JSONDecoder().decode(VitalLimits.self, from: Data(old.utf8))
    #expect(limits.diskFreeGB == 40 && limits.batteryCapacity == 60 && limits.trashGB == 5)
}

@Test func largeFilesLeaveAppLibrariesAlone() {
    let home = "/Users/me"
    let owned = ["Music/Music/Media.localized/a.m4a", "Pictures/Photos Library.photoslibrary/originals/b.heic",
                 "Movies/TV/Media.localized/c.mp4", "Music/Old.musiclibrary/d.m4a",
                 "Parallels/Win.pvm/disk.hdd", "Movies/Edit.fcpbundle/Media/e.mov", "VMs/Linux.UTM/Data/f.qcow2"]
    for path in owned {
        #expect(LargeFiles.ownedByApp((home + "/" + path).dropFirst(home.count + 1).split(separator: "/")))
    }
    #expect(!LargeFiles.ownedByApp("Music/mix.mp3".split(separator: "/")))
    #expect(!LargeFiles.ownedByApp("Downloads/old.pvm".split(separator: "/")))
}

@Test func tuneUpSuggestsRoutineTasksOnceDue() {
    let now = Date()
    let tasks = Maintenance.tasks(brew: "/opt/homebrew/bin/brew", docker: nil, xcode: false)
    let fresh = ActivityLog(entries: [ActivityEntry(date: now.addingTimeInterval(-86400), kind: .maintenance,
                                                    title: "Clean Up Homebrew", bytes: 0)])
    #expect(Maintenance.due(tasks, log: fresh, now: now).map(\.id) == ["launchservices"])
    let stale = ActivityLog(entries: [ActivityEntry(date: now.addingTimeInterval(-15 * 86400), kind: .maintenance,
                                                    title: "Clean Up Homebrew", bytes: 0)])
    #expect(Maintenance.due(tasks, log: stale, now: now).map(\.id) == ["launchservices", "brew"])
    #expect(!Maintenance.due(tasks, log: ActivityLog(), now: now).contains { $0.admin })
}

@Test func processRunnerStopsWhatOutlivesItsTimeout() async throws {
    let start = Date()
    await #expect(throws: CLIError.self) {
        try await ProcessRunner(timeout: 0.5).run("/bin/sh", ["-c", "sleep 30; echo late"], env: [:])
    }
    #expect(Date().timeIntervalSince(start) < 5)
    let r = try await ProcessRunner(timeout: 5).run("/bin/echo", ["hi"], env: [:])
    #expect(r.output == "hi\n")
}

@Test func activityLogForgetsOldTrashPathsAndStaysSmall() {
    let now = Date()
    let item = Trashed(original: URL(fileURLWithPath: "/a"), inTrash: URL(fileURLWithPath: "/b"))
    var log = ActivityLog(entries: [ActivityEntry(date: now.addingTimeInterval(-40 * 86400), kind: .files, title: "old", bytes: 1, trashed: [item])])
    log.add(ActivityEntry(date: now, kind: .files, title: "new", bytes: 1, trashed: [item]), now: now)
    #expect(log.entries[0].trashed == nil)
    #expect(log.entries[1].trashed == [item])
    for _ in 0..<ActivityLog.most { log.add(ActivityEntry(date: now, kind: .junk, title: "x", bytes: 0), now: now) }
    #expect(log.entries.count == ActivityLog.most)
}

@Test func npxFoldersInUseAreFound() {
    let spot = Junk(id: "npx", title: "", detail: "", path: "/h/.npm/_npx")
    let found = spot.inUse(commands: ["node /h/.npm/_npx/ab12/node_modules/.bin/mcp --x", "/h/.npm/_npx/cd34 a /h/.npm/_npx/ef56/b",
                                      "node /h/.npm/_npxother/zz"])
    #expect(found == ["ab12", "cd34", "ef56"])
}

@Test func largeFilesSortByKindAndAge() {
    let kinds = ["a.mov": FileKind.videos, "b.MP4": .videos, "c.m4a": .music, "d.heic": .pictures, "e.zip": .archives,
                 "f.tar.gz": .archives, "g.dmg": .installers, "h.pkg": .installers, "i.pdf": .documents, "j.key": .documents,
                 "k.qqzz": .other, "noext": .other]
    for (name, kind) in kinds {
        #expect(FileKind.of(URL(fileURLWithPath: "/u/" + name)) == kind, "\(name)")
    }
    let now = Date(timeIntervalSince1970: 400 * 86400)
    var file = LargeFile(url: URL(fileURLWithPath: "/u/a.mov"), size: 1, modified: Date(timeIntervalSince1970: 0))
    #expect(FileKind.unopened(file, now: now))
    file.opened = Date(timeIntervalSince1970: 300 * 86400)
    #expect(!FileKind.unopened(file, now: now))
    #expect(!FileKind.unopened(LargeFile(url: file.url, size: 1), now: now))
}

@Test func batteryTimeLeftReadsLikeAClock() {
    var b = Battery(percent: 60)
    b.minutes = 125
    #expect(b.timeLeft == "2:05 left")
    b.charging = true
    b.onAC = true
    b.minutes = 40
    #expect(b.timeLeft == "0:40 to full")
    b.charging = false
    #expect(b.timeLeft == nil)
    b = Battery(percent: 60)
    #expect(b.timeLeft == nil)
    b.minutes = 45
    #expect(b.timeLeft == "0:45 left" && b.clock == "0:45")
    b.minutes = 0
    #expect(b.timeLeft == "0:00 left")
    b = Battery(percent: 100, onAC: true, charged: true)
    b.minutes = 30
    #expect(b.timeLeft == nil)
}

@Test func batteryTemperatureFromEitherRegistryPlace() {
    #expect(Battery.temperature(registry: ["Temperature": 3050]) == 30.5)
    #expect(Battery.temperature(registry: ["BatteryData": ["Temperature": 3750]]) == 37.5)
    #expect(Battery.temperature(registry: ["BatteryData": ["Voltage": 12000]]) == nil)
    #expect(Battery.temperature(registry: ["Temperature": 0]) == nil)
    #expect(Battery.temperature(registry: ["Temperature": 0, "BatteryData": ["Temperature": 3750]]) == 37.5)
}

@Test func batteryWearKeepsConditionAndCapacityApart() {
    var b = Battery(percent: 50)
    b.health = "Good"
    b.capacity = 78
    #expect(!b.isWorn && b.isFaded && b.needsService)
    b.capacity = 90
    b.health = "Service Recommended"
    #expect(b.isWorn && !b.isFaded && b.needsService)
}
