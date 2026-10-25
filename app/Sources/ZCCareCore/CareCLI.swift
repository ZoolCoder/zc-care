import Foundation

public struct CommandResult: Sendable {
    public var status: Int32
    public var stdout: Data
    public var stderr: String

    public init(status: Int32, stdout: Data = Data(), stderr: String = "") {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }

    public var output: String { String(decoding: stdout, as: UTF8.self) }
}

/// Runs a program; tests swap in a fake.
public protocol Runner: Sendable {
    func run(_ executable: String, _ args: [String], env: [String: String]) async throws -> CommandResult
}

public struct ProcessRunner: Runner {
    /// Stops a program still running after this many seconds, and its
    /// children, which could hold the pipes open. Nil waits for ever, unless
    /// the task is cancelled: for installs, and anything that asks the user.
    public var timeout: TimeInterval?

    public init(timeout: TimeInterval? = nil) {
        self.timeout = timeout
    }

    public func run(_ executable: String, _ args: [String], env: [String: String]) async throws -> CommandResult {
        let child = Child()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard child.begin(continuation) else { return }
                DispatchQueue.global().async { launch(executable, args, env: env, child: child) }
            }
        } onCancel: {
            child.stop(CancellationError(), gracefully: true)
        }
    }

    private func launch(_ executable: String, _ args: [String], env: [String: String], child: Child) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return child.finish(throwing: error) }
        guard child.launched(p) else { return }
        let timer = timeout.map { seconds in
            let item = DispatchWorkItem {
                let name = (executable as NSString).lastPathComponent
                child.stop(CLIError(message: "\(name) did not finish in \(Int(seconds)) seconds", timedOut: true))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: item)
            return item
        }
        // Both pipes drain at once: a full one would stall the child.
        let outData = Drain(out.fileHandleForReading), errData = Drain(err.fileHandleForReading)
        p.waitUntilExit()
        timer?.cancel()
        // A grandchild could still hold the pipes: take what came, and let go.
        outData.finish(within: 2)
        errData.finish(within: 2)
        child.finish(returning: CommandResult(status: p.terminationStatus, stdout: outData.data,
                                              stderr: String(decoding: errData.data, as: UTF8.self)))
    }
}

/// Reads a pipe as it fills, without a thread blocked on it: a grandchild
/// that keeps the pipe open cannot strand one.
private final class Drain: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private let eof = DispatchSemaphore(value: 0)
    private var buffer = Data()

    init(_ handle: FileHandle) {
        self.handle = handle
        handle.readabilityHandler = { [self] h in
            let chunk = h.availableData
            if chunk.isEmpty {
                h.readabilityHandler = nil
                eof.signal()
            } else {
                lock.withLock { buffer.append(chunk) }
            }
        }
    }

    var data: Data { lock.withLock { buffer } }

    /// Waits for the end of the pipe, for this many seconds at most, then stops reading.
    func finish(within seconds: TimeInterval) {
        _ = eof.wait(timeout: .now() + seconds)
        handle.readabilityHandler = nil
    }
}

/// One run of a program. The exit, the timeout and a cancelled task race to
/// end it; the first wins, and a stop also kills the program.
private final class Child: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CommandResult, any Error>?
    private var process: Process?
    private var stopped: (any Error)?

    /// False when the run was stopped before it began.
    func begin(_ continuation: CheckedContinuation<CommandResult, any Error>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let stopped {
            continuation.resume(throwing: stopped)
            return false
        }
        self.continuation = continuation
        return true
    }

    /// False, and the program killed, when a stop came while it started.
    func launched(_ p: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if stopped != nil {
            Self.kill(p)
            return false
        }
        process = p
        return true
    }

    /// A graceful stop sends SIGINT and keeps waiting for the exit, up to
    /// ten seconds, so the program can cancel what is left and write its
    /// records; then it is killed. Any other stop ends the wait at once.
    func stop(_ error: any Error, gracefully: Bool = false) {
        lock.lock()
        guard stopped == nil else { return lock.unlock() }
        stopped = error
        let p = process
        if gracefully, let p {
            lock.unlock()
            Foundation.kill(p.processIdentifier, SIGINT)
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) { Self.kill(p) }
            return
        }
        let waiting = continuation
        continuation = nil
        process = nil
        lock.unlock()
        waiting?.resume(throwing: error)
        if let p { DispatchQueue.global().async { Self.kill(p) } }
    }

    func finish(returning result: CommandResult) {
        let stopped = lock.withLock { () -> (any Error)? in
            process = nil
            return self.stopped
        }
        // A graceful stop waited for this exit: report the stop, not the result.
        if let stopped { take()?.resume(throwing: stopped) } else { take()?.resume(returning: result) }
    }

    func finish(throwing error: any Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<CommandResult, any Error>? {
        lock.withLock {
            defer { continuation = nil }
            return continuation
        }
    }

    /// Children first, while they still have this parent; whatever ignores
    /// the TERM gets a KILL.
    private static func kill(_ p: Process) {
        guard p.isRunning else { return }
        let pid = p.processIdentifier
        let children = try? Process.run(URL(fileURLWithPath: "/usr/bin/pkill"), arguments: ["-TERM", "-P", "\(pid)"])
        children?.waitUntilExit()
        Foundation.kill(pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if p.isRunning { Foundation.kill(pid, SIGKILL) }
        }
    }
}

public struct CLIError: LocalizedError, Sendable {
    public var message: String
    /// The program was stopped for running too long.
    public var timedOut: Bool

    public init(message: String, timedOut: Bool = false) {
        self.message = message
        self.timedOut = timedOut
    }

    public var errorDescription: String? { message }
}

/// The zc-care CLI, run with one config.
public struct CareCLI: Sendable {
    public var binary: String
    public var config: String
    public var env: [String: String]
    var runner: any Runner

    public init(binary: String, config: String, env: [String: String], runner: any Runner = ProcessRunner()) {
        self.binary = binary
        self.config = config
        self.env = env
        self.runner = runner
    }

    public func run(_ args: [String]) async throws -> CommandResult {
        var env = env
        env["ZC_CARE_CONFIG"] = config
        return try await runner.run(binary, args, env: env)
    }

    /// Runs the command and decodes its JSON. The doctor exits non-zero when
    /// a check fails, so a document on stdout counts more than the status.
    func json<T: Decodable>(_ args: [String]) async throws -> T {
        let r = try await run(args)
        if let doc = try? JSONDecoder().decode(T.self, from: r.stdout) {
            return doc
        }
        throw CLIError(message: lastLine(r.stderr) ?? "\(args[0]) exited \(r.status)")
    }

    public func status() async throws -> [TargetStatus] { try await json(["status", "-json"]) }

    public func checks() async throws -> [Check] {
        let report: DoctorReport = try await json(["doctor", "-json"])
        return report.checks
    }

    /// The last saved drift. It never fails the snapshot: no check has run
    /// until the launchd agent is loaded.
    public func drift() async -> Drift? {
        guard let r = try? await run(["drift", "-last", "-json"]), r.status == 0 else { return nil }
        return try? Self.dated.decode(Drift.self, from: r.stdout)
    }

    /// What was applied, newest first.
    public func history(limit: Int = 50) async throws -> [HistoryEntry] {
        let r = try await run(["history", "-json", "-n", String(limit)])
        guard let doc = try? Self.dated.decode([HistoryEntry].self, from: r.stdout) else {
            throw CLIError(message: lastLine(r.stderr) ?? "history exited \(r.status)")
        }
        return doc
    }

    /// Go writes times with or without fractional seconds.
    static var dated: JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom { d in
            let s = try d.singleValueContainer().decode(String.self)
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = f.date(from: s) ?? ISO8601DateFormatter().date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: d.codingPath, debugDescription: s))
        }
        return dec
    }

    public func outdated() async throws -> [Item] { try await items(states: ["outdated"]) }

    /// What targets declare, each item knowing its target; no targets is all.
    public func items(targets: [String] = [], states: [String] = []) async throws -> [Item] {
        var args = ["list", "-json"]
        for t in targets { args += ["-target", t] }
        if !states.isEmpty { args += ["-state", states.joined(separator: ",")] }
        let groups: [ItemGroup] = try await json(args)
        return groups.flatMap { g in
            (g.items ?? []).map { var i = $0; i.target = g.target; return i }
        }
    }

    /// Plans and saves the plan to file, so apply runs what was shown.
    public func plan(upgrade: Bool = false, targets: [String] = [], only: [String] = [],
                     savingTo file: String) async throws -> PlanDoc {
        var args = ["plan", "-json", "-out", file]
        if upgrade { args.append("-upgrade") }
        for t in targets { args += ["-target", t] }
        for r in only { args += ["-only", r] }
        return try await json(args)
    }

    /// Applies a saved plan. -yes: the owner confirmed the plan in the app,
    /// deletions included, and there is no terminal to ask in.
    public func apply(saved file: String) async throws -> CommandResult {
        try await run(["apply", "-yes", file])
    }

    /// Puts packages on this Mac's skip list, or with undo takes them off.
    /// A skipped package that is missing is left out of plan and drift.
    public func skip(_ resources: [String], undo: Bool = false) async throws {
        guard !resources.isEmpty else { return }
        let r = try await run(["skip"] + (undo ? ["-undo"] : []) + resources)
        if r.status != 0 { throw CLIError(message: lastLine(r.stderr) ?? "skip exited \(r.status)") }
    }

    /// Declares an item this Mac has in the target's manifest, and returns
    /// the CLI's confirmation line.
    @discardableResult
    public func add(target: String, item: Item, why: String, section: String = "") async throws -> String {
        let args = ["add", "-target", target, "-why", why] + (section.isEmpty ? [] : ["-section", section]) + [item.resource]
        let r = try await run(args)
        if r.status != 0 { throw CLIError(message: lastLine(r.stderr) ?? "add exited \(r.status)") }
        return lastLine(r.output) ?? "added \(item.resource) to \(target)"
    }

    /// Reads everything at once; a part that fails leaves an error, not a
    /// blank menu.
    public func snapshot() async -> Snapshot {
        async let t = await Result(catching: { try await status() })
        async let o = await Result(catching: { try await outdated() })
        async let f = await Result(catching: { try await checks() })
        async let d = await drift()
        var s = Snapshot()
        var errors: [String] = []
        switch await t {
        case .success(let v): s.targets = v
        case .failure(let e): errors.append("status: " + e.localizedDescription)
        }
        switch await o {
        case .success(let v): s.outdated = v
        case .failure(let e): errors.append("list: " + e.localizedDescription)
        }
        switch await f {
        case .success(let v):
            s.findings = v.filter { !$0.isOK }
            s.security = v.filter(\.isSecurity)
        case .failure(let e): errors.append("doctor: " + e.localizedDescription)
        }
        let services = s.targets.filter { $0.provider == "services" }.map(\.target)
        if !services.isEmpty {
            do { s.services = try await items(targets: services) } catch {
                errors.append("services: " + error.localizedDescription)
            }
        }
        s.drift = await d
        s.errors = errors
        return s
    }
}

extension Result where Failure == any Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}

public func lastLine(_ s: String) -> String? {
    s.split(whereSeparator: \.isNewline).last.map(String.init)
}
