import Foundation
import Testing
@testable import ZCCareCore

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("zccare-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ url: URL, _ text: String = "x") throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

private func age(_ url: URL, days: Double) throws {
    try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-days * 86400)], ofItemAtPath: url.path)
}

@Test func leftoversSkipAgentsOfAnotherInstalledApp() throws {
    let home = try tempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    try write(home.appendingPathComponent("Library/LaunchAgents/com.google.Chrome.helper.plist"))
    try write(home.appendingPathComponent("Library/LaunchAgents/com.google.Chrome.canary.plist"))
    try write(home.appendingPathComponent("Library/LaunchAgents/com.google.Chrome.canary.update.plist"))
    let found = Leftovers.paths(bundleID: "com.google.Chrome", name: "Chrome", home: home.path,
                                installed: ["com.google.Chrome", "com.google.Chrome.canary"])
    #expect(found.map { ($0 as NSString).lastPathComponent } == ["com.google.Chrome.helper.plist"])
}

@Test func leftoversListNothingInsideAnIgnoredChild() throws {
    let home = try tempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    let support = home.appendingPathComponent("Library/Application Support/Gone")
    try write(support.appendingPathComponent("keep/me.db"))
    try write(support.appendingPathComponent("other.db"))
    let app = InstalledApp(name: "Gone", url: home.appendingPathComponent("Gone.app"), bundleID: nil, source: .other)
    let files = Leftovers.files(of: app, home: home.path, ignoring: IgnoreList([support.appendingPathComponent("keep").path]))
    #expect(!files.contains { $0.url.lastPathComponent == "Gone" })
}

@Test func claudeTempStaysWhileNestedFilesChange() throws {
    let temp = try tempDir()
    defer { try? FileManager.default.removeItem(at: temp) }
    let busy = temp.appendingPathComponent("session-busy"), idle = temp.appendingPathComponent("session-idle")
    try write(busy.appendingPathComponent("a/b/log.txt"))
    try write(idle.appendingPathComponent("a/b/log.txt"))
    for url in [busy, idle] { try age(url, days: 3) }
    try age(idle.appendingPathComponent("a/b/log.txt"), days: 3)
    try age(idle.appendingPathComponent("a/b"), days: 3)
    try age(idle.appendingPathComponent("a"), days: 3)
    #expect(!AIClutter.untouched(busy, for: 1, now: .now, deep: true))
    #expect(AIClutter.untouched(idle, for: 1, now: .now, deep: true))
}

@Test func usedReadsAnyNonPathCharacterAsBoundary() {
    let url = URL(fileURLWithPath: "/tmp/claude-501/s1")
    for tail in ["\"", "'", "\t", "=x", " --flag", "/inner", ""] {
        #expect(AIClutter.used(url, by: ["node " + url.path + tail]))
    }
    #expect(!AIClutter.used(url, by: ["node " + url.path + "2"]))
}

@Test func dockerMaintenanceRunsThroughDockerRun() {
    let docker = Maintenance.tasks(brew: nil, docker: "/d", xcode: false).first { $0.id == "docker" }
    #expect(docker?.docker == true)
}

@Test func busyProjectBeyondTheEntryCapIsNotIdle() throws {
    let project = try tempDir()
    defer { try? FileManager.default.removeItem(at: project) }
    for i in 0...ProjectDependencies.touchedEntryCap { try write(project.appendingPathComponent("src/f\(i).txt")) }
    try age(project.appendingPathComponent("src"), days: 400)
    let touched = ProjectDependencies.lastTouched(project: project, skipping: "node_modules")
    #expect(Date.now.timeIntervalSince(touched) < 60)
}

@Test func undecodableOllamaManifestListsNoModels() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let digest = "sha256:" + String(repeating: "a", count: 64)
    try write(root.appendingPathComponent("manifests/r/library/fine/latest"), #"{"layers":[{"digest":"\#(digest)","size":5}]}"#)
    #expect(AIModels.ollama(root: root).count == 1)
    try write(root.appendingPathComponent("manifests/r/library/broken/latest"), "not json")
    #expect(AIModels.ollama(root: root).isEmpty)
}

@Test func corruptActivityLogIsMovedAside() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("activity.json")
    try write(file, "{broken")
    #expect(ActivityLog.load(from: file).entries.isEmpty)
    let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    #expect(names.contains { $0.hasPrefix("activity.json.broken-") })
    #expect(!names.contains("activity.json"))
}

@Test func putBackCreatesMissingFoldersPrivately() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let binned = dir.appendingPathComponent("Trash/a.txt")
    try write(binned)
    let original = dir.appendingPathComponent("gone/deeper/a.txt")
    let item = Trashed(original: original, inTrash: binned)
    #expect(Trashed.putBack([item]).isEmpty)
    let mode = try FileManager.default.attributesOfItem(atPath: original.deletingLastPathComponent().path)[.posixPermissions] as? Int
    #expect(mode == 0o700)
}

@Test func cloudStorageFilesAreNeverListedForRemoval() throws {
    let home = try tempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    let drive = home.appendingPathComponent("Library/CloudStorage/GoogleDrive-me")
    try write(drive.appendingPathComponent("big.bin"), String(repeating: "x", count: 50_000))
    let result = CloudDrives.downloaded(in: drive, minimum: 1)
    #expect(result.total > 0)
    #expect(result.files.isEmpty)
}

@Test func externalAppsCountAsInstalled() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("Setapp/Thing.app/Contents")
    try write(app.appendingPathComponent("Info.plist"),
              #"<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.setapp.thing</string></dict></plist>"#)
    let volumeApp = root.appendingPathComponent("Volumes/Disk/Applications/Other.app/Contents")
    try write(volumeApp.appendingPathComponent("Info.plist"),
              #"<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.disk.other</string></dict></plist>"#)
    let ids = Leftovers.externalAppIDs(setapp: root.path + "/Setapp", volumes: root.path + "/Volumes")
    #expect(ids == ["com.setapp.thing", "com.disk.other"])
}

@Test func runningCommandWithSpacesKeepsItsCache() throws {
    let folder = try tempDir()
    defer { try? FileManager.default.removeItem(at: folder) }
    try write(folder.appendingPathComponent("My Tool/bin/run"))
    let junk = Junk(id: "x", title: "x", detail: "", path: folder.path)
    #expect(junk.inUse(commands: ["\(folder.path)/My Tool/bin/run --x"]) == ["My Tool"])
    #expect(junk.inUse(commands: ["node \(folder.path)/My Tool"]) == ["My Tool"])
}

@Test func growersOfAnUnknownPathIsEmpty() {
    let before = SpaceNode(path: "/r", size: 0, children: [SpaceNode(path: "/r/a", size: 0, children: [])])
    let after = SpaceNode(path: "/r", size: 900_000_000, children: [SpaceNode(path: "/r/a", size: 900_000_000, children: [])])
    let scan = SpaceScan(scannedAt: .now, root: after, previousAt: .now, previousRoot: before)
    #expect(!scan.growers().isEmpty)
    #expect(scan.growers(under: "/nowhere").isEmpty)
}

@Test func ollamaIgnoresDSStoreNextToManifest() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let digest = "sha256:" + String(repeating: "a", count: 64)
    try write(root.appendingPathComponent("manifests/registry.ollama.ai/library/llama/latest"),
              #"{"layers":[{"digest":"\#(digest)","size":5}]}"#)
    try write(root.appendingPathComponent("manifests/.DS_Store"), "junk")
    try write(root.appendingPathComponent("manifests/registry.ollama.ai/.DS_Store"), "junk")
    #expect(AIModels.ollama(root: root).map(\.name) == ["llama:latest"])
}

@Test func ollamaStillStopsOnBrokenManifest() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    try write(root.appendingPathComponent("manifests/registry.ollama.ai/library/llama/latest"), "not json")
    #expect(AIModels.ollama(root: root).isEmpty)
}

@Test func corruptActivityLogMovedAsideThenSaves() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("activity.json")
    try write(file, "{broken")
    let log = ActivityLog.load(from: file)
    #expect(!log.readOnly)
    #expect(!FileManager.default.fileExists(atPath: file.path))
    try log.save(to: file)
    #expect(FileManager.default.fileExists(atPath: file.path))
}

@Test func unmovableCorruptActivityLogRefusesSave() throws {
    let dir = try tempDir()
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }
    let file = dir.appendingPathComponent("activity.json")
    try write(file, "{broken")
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
    let log = ActivityLog.load(from: file)
    #expect(log.readOnly)
    #expect(throws: (any Error).self) { try log.save(to: file) }
    #expect((try? String(contentsOf: file, encoding: .utf8)) == "{broken")
}

@Test func deepUntouchedTreatsHugeFolderAsTouched() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    for i in 0...ProjectDependencies.touchedEntryCap {
        try write(dir.appendingPathComponent("f\(i)"))
    }
    try age(dir, days: 10)
    for i in 0...ProjectDependencies.touchedEntryCap { try age(dir.appendingPathComponent("f\(i)"), days: 10) }
    #expect(!AIClutter.untouched(dir, for: 1, now: .now, deep: true))
}
