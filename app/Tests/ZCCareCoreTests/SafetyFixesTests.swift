import Foundation
import Testing
@testable import ZCCareCore

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("zccare-safety-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ url: URL, bytes: Int) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 7, count: bytes).write(to: url)
}

@Test func ollamaRejectsTraversalDigest() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let good = "sha256:" + String(repeating: "a", count: 64)
    func manifest(_ path: String, _ digest: String) throws {
        let url = root.appendingPathComponent("manifests/registry.ollama.ai/" + path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"layers\":[{\"digest\":\"\(digest)\",\"size\":100}]}".utf8).write(to: url)
    }
    try manifest("library/fine/latest", good)
    try manifest("library/evil/latest", "sha256:../../../../Documents")
    try manifest("library/short/latest", "sha256:aa")
    #expect(AIModels.ollama(root: root).map(\.name) == ["fine:latest"])
}

@Test func partialPutBackKeepsRemainingRetriable() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let trash = root.appendingPathComponent(".Trash")
    let a = root.appendingPathComponent("a.txt"), b = root.appendingPathComponent("b.txt")
    let binnedA = trash.appendingPathComponent("a.txt"), binnedB = trash.appendingPathComponent("b.txt")
    try write(binnedA, bytes: 4096)
    try write(binnedB, bytes: 4096)
    try Data("new".utf8).write(to: b)
    var entry = ActivityEntry(kind: .files, title: "two", bytes: 8192,
                              trashed: [Trashed(original: a, inTrash: binnedA), Trashed(original: b, inTrash: binnedB)])
    #expect(entry.canPutBack(home: root.path))
    #expect(entry.putBackFromTrash(home: root.path) == ["b.txt"])
    #expect(FileManager.default.fileExists(atPath: a.path))
    #expect(entry.putBack == nil)
    #expect(entry.trashed?.map(\.original) == [b.path])
    #expect(entry.bytes < 8192)
    #expect(!entry.canPutBack(home: root.path))

    try FileManager.default.removeItem(at: b)
    #expect(entry.canPutBack(home: root.path))
    #expect(entry.putBackFromTrash(home: root.path).isEmpty)
    #expect(entry.putBack != nil)
}

@Test func putBackRefusesAnotherItemThatTookTheTrashName() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let original = root.appendingPathComponent("Downloads/Report.pdf")
    let binned = root.appendingPathComponent(".Trash/Report.pdf")
    try write(binned, bytes: 4096)
    let record = Trashed(original: original, inTrash: binned)
    #expect(record.canRestore(home: root.path))

    // The Trash is emptied, and another Report.pdf lands under the same name.
    try FileManager.default.removeItem(at: binned)
    try write(binned, bytes: 4096)
    #expect(!record.canRestore(home: root.path))
}

@Test func putBackMovesOnlyOutOfATrashFolder() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let elsewhere = root.appendingPathComponent("Documents/Report.pdf")
    try write(elsewhere, bytes: 4096)
    let record = Trashed(original: root.appendingPathComponent("Downloads/Report.pdf"), inTrash: elsewhere)
    #expect(!record.canRestore(home: root.path))
}

@Test func putBackRefusesAForgedRecord() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let binned = root.appendingPathComponent(".Trash/chat.db")
    try write(binned, bytes: 4096)
    let original = root.appendingPathComponent("Public/chat.db")
    var record = Trashed(original: original, inTrash: binned)
    #expect(record.canRestore(home: root.path))

    // A record without file numbers, as an older log or another program writes it.
    var legacy = record
    legacy.inode = nil
    #expect(!legacy.canRestore(home: root.path))

    // A folder named .Trash elsewhere that links into a protected folder.
    let messages = root.appendingPathComponent("Library/Messages/chat.db")
    try write(messages, bytes: 4096)
    let decoy = root.appendingPathComponent("tmp/.Trash")
    try FileManager.default.createDirectory(at: decoy.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: decoy, withDestinationURL: messages.deletingLastPathComponent())
    let lured = Trashed(original: original, inTrash: decoy.appendingPathComponent("chat.db"))
    #expect(lured.inode != nil)
    #expect(!lured.canRestore(home: root.path))

    // A way back through a link, or into the privacy database's folder.
    record.inTrash = binned.path
    let link = root.appendingPathComponent("Link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("Elsewhere"))
    record.original = link.appendingPathComponent("chat.db").path
    #expect(!record.canRestore(home: root.path))
    record.original = root.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path
    #expect(!record.canRestore(home: root.path))
    record.original = root.path + "/Public/../Library/chat.db"
    #expect(!record.canRestore(home: root.path))
}

@Test func ignoredLinkTargetKeepsTheLinkInAJunkFolder() throws {
    let home = try tempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    let caches = home.appendingPathComponent("Library/Caches")
    let target = home.appendingPathComponent("SSD/JetBrains")
    try write(target.appendingPathComponent("index.bin"), bytes: 4096)
    try write(caches.appendingPathComponent("com.bar/x.bin"), bytes: 4096)
    try FileManager.default.createSymbolicLink(at: caches.appendingPathComponent("JetBrains"), withDestinationURL: target)
    var ignore = IgnoreList()
    ignore.add(caches.appendingPathComponent("JetBrains").path)
    #expect(ignore.names(in: caches.path) == ["JetBrains"])
}

@Test func ignoreListIsCaseInsensitiveAndRefusesEmptyPaths() {
    var list = IgnoreList()
    list.add("")
    list.add("   ")
    #expect(list.paths.isEmpty)
    list.add("/Users/me/Keep")
    list.add("/users/me/keep")
    #expect(list.paths.count == 1)
    #expect(list.covers("/USERS/me/keep/file"))
    list.remove("/users/ME/keep/")
    #expect(list.paths.isEmpty)
}

@Test func similarImagesRequireEveryMemberCloseToTheBest() {
    let groups = SimilarImages.cluster(count: 3) { i, j in [i, j] == [0, 1] || [i, j] == [1, 2] ? 0.1 : 0.9 }
    #expect(groups == [[0, 1]])
}

@Test func ignoredDescendantKeepsJunkEntry() throws {
    let home = try tempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    let caches = home.appendingPathComponent("Library/Caches")
    try write(caches.appendingPathComponent("com.foo/keep.db"), bytes: 4096)
    try write(caches.appendingPathComponent("com.bar/x.bin"), bytes: 4096)
    let ignore = IgnoreList([caches.path + "/com.foo/keep.db"])
    #expect(ignore.touches(caches.appendingPathComponent("com.foo")))
    #expect(!ignore.covers(caches.appendingPathComponent("com.foo")))
    let spot = try #require(Junk.spots(home: home.path).first { $0.id == "caches" })
    #expect(spot.contents(keeping: ignore.names(in: caches.path)).map(\.name) == ["com.bar"])
}

@Test func rootFixRejectsGlobBraceTildeAndUnlistedPrograms() {
    func fix(_ detail: String) -> Fix {
        Fix(for: Check(name: "security firewall", status: "warn", detail: detail))
    }
    for detail in [
        "sudo chmod -R 777 /",
        "sudo defaults write /Library/x {a,b}",
        "sudo defaults write ~/x y",
        "sudo defaults write /Library/* y",
        "sudo launchctl bootout `id`",
        "sudo sh -c chmod 777 /",
        "sudo sh -c 'echo it's'",
        "sudo bash -c 'true'",
        // Quoted, but not one of the doctor's own lines: the body is free text.
        "sudo sh -c 'softwareupdate --schedule on && defaults write /Library/x y -bool true'",
    ] {
        #expect(fix(detail) == .info(detail))
    }
    guard case .command = fix(Fix.touchIDLine) else { Issue.record("the doctor's sh -c line lost its fix"); return }
    guard case .command = fix("sudo /usr/sbin/spctl --global-enable") else { Issue.record("listed program lost its fix"); return }
}

@Test func removalTreatsEnoentAsGone() {
    let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
    let cocoa = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileNoSuchFile.rawValue)
    let read = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadNoSuchFile.rawValue)
    let wrapped = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteUnknown.rawValue,
                          userInfo: [NSUnderlyingErrorKey: posix])
    for error in [posix, cocoa, read, wrapped] { #expect(Removal.isGone(error)) }
    #expect(!Removal.isGone(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
}

@Test func canTrashRejectsTraversalAndSymlinks() throws {
    let home = try tempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    let real = home.appendingPathComponent("Projects/old")
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("Projects/link"), withDestinationURL: real)
    let h = home.path
    #expect(SpaceLens.canTrash(h + "/Projects/old", home: h))
    #expect(!SpaceLens.canTrash(h + "/Projects/link", home: h))
    #expect(!SpaceLens.canTrash(h + "/Projects/../Library/x", home: h))
    #expect(!SpaceLens.canTrash(h + "/Projects//old", home: h))
    #expect(!SpaceLens.canTrash(h + "/Projects/old/", home: h))
    #expect(!SpaceLens.canTrash("/Projects/old", home: ""))
    #expect(!SpaceLens.canTrash("/x", home: "/"))
}

private final class Recorder: Runner, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(args: [String], env: [String: String])] = []
    var recorded: [(args: [String], env: [String: String])] { lock.withLock { calls } }

    func run(_ executable: String, _ args: [String], env: [String: String]) async throws -> CommandResult {
        lock.withLock { calls.append((args, env)) }
        return args.first == "context" ? CommandResult(status: 0, stdout: Data("default\ndesktop-linux\nremote\n".utf8))
                                       : CommandResult(status: 0)
    }
}

@Test func dockerPruneDropsRemoteHostEnv() async throws {
    let recorder = Recorder()
    let env = ["DOCKER_HOST": "ssh://prod", "DOCKER_CONTEXT": "remote", "PATH": "/usr/bin"]
    _ = try await Docker.run("docker", Docker.pruneBuildCache, env: env, runner: recorder)
    let calls = recorder.recorded
    #expect(calls.allSatisfy { $0.env["DOCKER_HOST"] == nil && $0.env["DOCKER_CONTEXT"] == nil && $0.env["PATH"] == "/usr/bin" })
    let prune = try #require(calls.last)
    #expect(prune.args == Docker.pruneBuildCache + ["--context", "desktop-linux"])
}
