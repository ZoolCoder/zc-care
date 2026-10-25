import Foundation
import Testing
@testable import ZCCareCore

/// Records the arguments of the last run.
private final class Recorder: Runner, @unchecked Sendable {
    private let result: CommandResult
    private(set) var args: [String] = []

    init(_ result: CommandResult) { self.result = result }

    func run(_ executable: String, _ args: [String], env: [String: String]) async throws -> CommandResult {
        self.args = args
        return result
    }
}

private let wget = Item(name: "wget", kind: "brew", state: "not declared")

@Test func addBuildsTheArgumentsWithoutASection() async throws {
    let recorder = Recorder(CommandResult(status: 0, stdout: Data("added brew:wget\n".utf8)))
    let cli = CareCLI(binary: "/zc", config: "/c.yaml", env: [:], runner: recorder)
    let line = try await cli.add(target: "packages", item: wget, why: "Added from this Mac by ZC Care")
    #expect(recorder.args == ["add", "-target", "packages", "-why", "Added from this Mac by ZC Care", "brew:wget"])
    #expect(line == "added brew:wget")
}

@Test func addPassesTheSectionWhenGiven() async throws {
    let recorder = Recorder(ok("done"))
    let cli = CareCLI(binary: "/zc", config: "/c.yaml", env: [:], runner: recorder)
    try await cli.add(target: "packages", item: wget, why: "w", section: "Tools")
    #expect(recorder.args == ["add", "-target", "packages", "-why", "w", "-section", "Tools", "brew:wget"])
}

@Test func addSurfacesTheLastStderrLine() async {
    let fake = FakeRunner(outputs: ["add": CommandResult(status: 1, stderr: "warning\nerror: choose a section: Tools\n")])
    let cli = CareCLI(binary: "/zc", config: "/c.yaml", env: [:], runner: fake)
    await #expect(throws: CLIError.self) { try await cli.add(target: "packages", item: wget, why: "w") }
    do { try await cli.add(target: "packages", item: wget, why: "w") } catch {
        #expect(error.localizedDescription == "error: choose a section: Tools")
    }
}
