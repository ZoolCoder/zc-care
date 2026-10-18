import Foundation
import Testing
@testable import ZCCareCore

private func item(_ kind: String, _ name: String, _ state: String, section: String? = nil) -> Item {
    var i = Item(name: name, kind: kind, state: state)
    i.section = section
    return i
}

@Test func appChoiceStartsPickedExceptSkippedAndHidesTaps() {
    let choice = AppChoice(items: [
        item("tap", "felixkratz/formulae", "missing"),
        item("cask", "ghostty", "missing", section: "Terminal"),
        item("brew", "tmux", "in place", section: "Terminal"),
        item("brew", "k9s", "skipped", section: "Containers"),
        item("brew", "extra", "not declared"),
    ])
    #expect(choice.items.map(\.name) == ["ghostty", "tmux", "k9s"])
    #expect(choice.sections.map(\.name) == ["Terminal", "Containers"])
    #expect(choice.toInstall.map(\.resource) == ["cask:ghostty"])
    #expect(choice.toSkip.isEmpty && choice.toUnskip.isEmpty)
}

@Test func appChoiceSkipsWhatIsUntickedAndUnskipsWhatIsTicked() {
    var choice = AppChoice(items: [
        item("cask", "ghostty", "missing", section: "Terminal"),
        item("brew", "tmux", "in place", section: "Terminal"),
        item("brew", "k9s", "skipped", section: "Containers"),
    ])
    choice.toggle(choice.items[0])
    choice.set(choice.sections[1], picked: true)
    // An installed package cannot be left out.
    choice.set(choice.sections[0], picked: false)
    #expect(choice.isPicked(choice.items[1]))
    #expect(choice.toSkip == ["cask:ghostty"])
    #expect(choice.toUnskip == ["brew:k9s"])
    #expect(choice.toInstall.map(\.name) == ["k9s"])
}

@Test func aProfilePicksItsSectionsAndEveryonesSections() {
    var dev = item("brew", "k9s", "missing", section: "Containers")
    dev.profiles = ["developer"]
    var both = item("cask", "claude", "missing", section: "AI")
    both.profiles = ["developer", "everyday"]
    var choice = AppChoice(items: [dev, both, item("cask", "obsidian", "missing", section: "Apps")])
    #expect(choice.profiles == ["developer", "everyday"])
    choice.choose(profile: "everyday")
    #expect(choice.toSkip == ["brew:k9s"])
    choice.choose(profile: nil)
    #expect(choice.toSkip.isEmpty)
}

@Test func severalProfilesPickEachOnesSections() {
    var dev = item("brew", "k9s", "missing", section: "Containers")
    dev.profiles = ["developer"]
    var art = item("cask", "figma", "missing", section: "Creative")
    art.profiles = ["creative"]
    var home = item("cask", "spotify", "missing", section: "Everyday")
    home.profiles = ["everyday"]
    var choice = AppChoice(items: [dev, art, home, item("cask", "iina", "missing", section: "Essentials")])
    choice.choose(profiles: ["developer", "creative"])
    #expect(choice.toSkip == ["cask:spotify"])
    choice.choose(profiles: [])
    #expect(choice.toSkip.isEmpty)
}

@Test func tipsFindTappedFormulaeByShortName() {
    let tip = Tips.tip(for: Item(name: "FelixKratz/formulae/sketchybar", kind: "brew", state: "missing"))
    #expect(tip?.guide?.absoluteString == "https://zoolcoder.github.io/zc-care/toolbox/sketchybar.html")
    #expect(Tips.tip(for: Item(name: "nothing-known", kind: "brew", state: "missing")) == nil)
}

@Test func skipFailsWithTheCLIError() async throws {
    let ws = CareCLI(binary: "/zc", config: "/c.yaml", env: [:],
                         runner: FakeRunner(outputs: ["skip": CommandResult(status: 1, stderr: "error: bad item")]))
    try await ws.skip([])
    await #expect(throws: CLIError.self) { try await ws.skip(["cask:ghostty"]) }
}

@Test func aNewMacsPathGetsHomebrew() {
    #expect(Discovery.withHomebrew(["PATH": "/usr/bin:/bin"])["PATH"] == "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin")
    #expect(Discovery.withHomebrew(["PATH": "/x:/opt/homebrew/bin"])["PATH"] == "/x:/opt/homebrew/bin")
}

@Test func historyReadsGoTimes() async throws {
    let ws = CareCLI(binary: "/zc", config: "/c.yaml", env: [:], runner: FakeRunner(outputs: ["history": ok("""
    [{"at":"2026-10-18T09:15:02.123456+02:00","kind":"apply","target":"packages","detail":"1 change(s) applied from cli: cask:ghostty","ok":true},
     {"at":"2026-10-17T08:00:00Z","kind":"apply","detail":"from ui: boom","ok":false}]
    """)]))
    let h = try await ws.history()
    #expect(h.map(\.ok) == [true, false])
    #expect(h[0].target == "packages" && h[1].target == nil)
}
