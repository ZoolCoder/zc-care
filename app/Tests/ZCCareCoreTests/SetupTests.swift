import Foundation
import Testing
@testable import ZCCareCore

/// Answers by program and arguments, such as "git config --global user.name".
struct ScriptRunner: Runner {
    var outputs: [String: CommandResult]

    func run(_ executable: String, _ args: [String], env: [String: String]) async throws -> CommandResult {
        let name = (executable as NSString).lastPathComponent
        return outputs[([name] + args).joined(separator: " ")] ?? CommandResult(status: 1)
    }
}

@Test func initPassesTheProfilesAndDecodesWhatItWrote() async throws {
    let cli = CareCLI(binary: "/bin/zc-care", config: "", env: [:], runner: FakeRunner(outputs: [
        "init": ok(#"{"config":"/h/.config/zc-care/zc-care.yaml","files":["a"],"skip":["cask:figma"],"kept":2,"profiles":["developer","work"]}"#),
    ]))
    let res = try await cli.initConfig(profiles: ["developer"], role: "work", fromMac: true)
    #expect(res.config == "/h/.config/zc-care/zc-care.yaml")
    #expect(res.kept == 2 && res.skip == ["cask:figma"] && res.profiles == ["developer", "work"])
}

@Test func oneRootCommandFixesEveryFailedRootCheck() {
    let checks = [
        Check(name: "security firewall", status: "fail", detail: "sudo socketfilterfw --setglobalstate on"),
        Check(name: "security Gatekeeper", status: "ok"),
        Check(name: "security automatic update checks", status: "fail", detail: "sudo softwareupdate --schedule on"),
        Check(name: "security Time Machine backups", status: "fail", detail: "System Settings, General, Time Machine: add a backup disk"),
    ]
    #expect(Fix.rootCommands(for: checks) == "socketfilterfw --setglobalstate on; softwareupdate --schedule on")
    #expect(Fix.rootCommands(for: [checks[1], checks[3]]) == nil)
    #expect(Fix.pane(for: checks[3].detail!).absoluteString.hasSuffix("Time-Machine-Settings.extension"))
}

@Test func rootStepsNameEachCheckAndItsExactCommand() {
    let checks = [
        Check(name: "security firewall", status: "fail", detail: "sudo socketfilterfw --setglobalstate on"),
        Check(name: "security Gatekeeper", status: "ok", detail: "sudo spctl --master-enable"),
        Check(name: "security Time Machine backups", status: "fail", detail: "System Settings, General, Time Machine: add a backup disk"),
        Check(name: "security automatic update checks", status: "fail", detail: "sudo softwareupdate --schedule on"),
    ]
    let steps = Fix.rootSteps(for: checks)
    #expect(steps.map(\.command) == ["socketfilterfw --setglobalstate on", "softwareupdate --schedule on"])
    #expect(steps.map(\.title) == [checks[0].title, checks[3].title])
    #expect(Fix.rootSteps(for: [checks[1], checks[2]]).isEmpty)
}

@Test func devIdentityReadsGitOnlyOnceTheToolsAreIn() async {
    let none = await DevIdentity.read(runner: ScriptRunner(outputs: [
        "git config --global user.name": ok("Ada\n"),
    ]), env: [:], home: "/h", exists: { _ in false })
    #expect(!none.tools && none.name.isEmpty && none.key == nil)

    let all = await DevIdentity.read(runner: ScriptRunner(outputs: [
        "xcode-select -p": ok("/Library/Developer/CommandLineTools\n"),
        "git config --global user.name": ok("Ada Lovelace\n"),
        "git config --global user.email": ok("ada@example.com\n"),
        "git config --global gpg.format": ok("ssh\n"),
        "git config --global user.signingkey": ok("/h/.ssh/id_ed25519.pub\n"),
        "env gh auth status": ok(""),
    ]), env: [:], home: "/h", exists: { $0 == "/h/.ssh/id_ed25519.pub" })
    #expect(all.complete && all.name == "Ada Lovelace" && all.key == "/h/.ssh/id_ed25519.pub")
}

@Test func theIdentityScriptQuotesTheEmailAndUploadsBothKeys() {
    let script = DevIdentity.script(email: "o'neil@example.com")
    #expect(script.contains(#"ssh-keygen -t ed25519 -C 'o'\''neil@example.com' -f "$key""#))
    #expect(script.contains("--type authentication") && script.contains("--type signing"))
    #expect(script.contains("ssh-add --apple-use-keychain"))
}
