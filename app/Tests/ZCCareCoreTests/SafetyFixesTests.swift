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
    let trash = root.appendingPathComponent("Trash")
    let a = root.appendingPathComponent("a.txt"), b = root.appendingPathComponent("b.txt")
    let binnedA = trash.appendingPathComponent("a.txt"), binnedB = trash.appendingPathComponent("b.txt")
    try write(binnedA, bytes: 4096)
    try write(binnedB, bytes: 4096)
    try Data("new".utf8).write(to: b)
    var entry = ActivityEntry(kind: .files, title: "two", bytes: 8192,
                              trashed: [Trashed(original: a, inTrash: binnedA), Trashed(original: b, inTrash: binnedB)])
    #expect(entry.canPutBack)
    #expect(entry.putBackFromTrash() == ["b.txt"])
    #expect(FileManager.default.fileExists(atPath: a.path))
    #expect(entry.putBack == nil)
    #expect(entry.trashed?.map(\.original) == [b.path])
    #expect(entry.bytes < 8192)
    #expect(!entry.canPutBack)

    try FileManager.default.removeItem(at: b)
    #expect(entry.canPutBack)
    #expect(entry.putBackFromTrash().isEmpty)
    #expect(entry.putBack != nil)
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
    ] {
        #expect(fix(detail) == .info(detail))
    }
    let quoted = "sudo sh -c 'softwareupdate --schedule on && defaults write /Library/x y -bool true'"
    guard case .command = fix(quoted) else { Issue.record("quoted sh -c lost its fix"); return }
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
