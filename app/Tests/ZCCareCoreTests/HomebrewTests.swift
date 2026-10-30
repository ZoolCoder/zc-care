import Foundation
import Testing
@testable import ZCCareCore

@Test func autoremoveDryRunListsFormulae() {
    let output = """
    ==> Would autoremove 3 unneeded formulae:
    libyaml
    supabase/tap/thing
    python@3.12
    ==> Something else
    not-a-formula
    """
    #expect(Homebrew.unneeded(output) == ["libyaml", "supabase/tap/thing", "python@3.12"])
    #expect(Homebrew.unneeded("").isEmpty)
    #expect(Homebrew.unneeded("==> Would autoremove 1 unneeded formula:\n--force\nok") == ["ok"])
}

@Test func cleanupDryRunReadsDecimalSize() {
    let output = """
    Would remove: /opt/homebrew/Library/Homebrew/vendor/portable-ruby/4.0.7_1 (1,707 files, 34.6MB)
    ==> This operation would free approximately 1.4GB of disk space.
    """
    #expect(Homebrew.reclaimable(output) == 1_400_000_000)
    #expect(Homebrew.reclaimable("==> This operation would free approximately 512KB of disk space.") == 512_000)
    #expect(Homebrew.reclaimable("") == nil)
}

@Test func doctorWarningsSplitByHeading() {
    let output = """
    Please note that these warnings are just used to help the Homebrew maintainers
    with debugging if you file an issue.

    Warning: Some installed formulae are deprecated or disabled.
    You should find replacements for the following formulae:

      icu4c@78

    Warning: The following taps are not trusted:
      supabase/tap
    """
    let warnings = Homebrew.warnings(output)
    #expect(warnings.map(\.title) == ["Some installed formulae are deprecated or disabled.", "The following taps are not trusted:"])
    #expect(warnings[0].detail == "You should find replacements for the following formulae:\n\n  icu4c@78")
    #expect(warnings[1].detail == "supabase/tap")
    #expect(Homebrew.warnings("Your system is ready to brew.").isEmpty)
}

@Test func declaredFormulaeAreNotRemovable() {
    #expect(Homebrew.removable(["libyaml", "supabase/tap/thing", "jq"], declared: ["jq", "thing"]) == ["libyaml"])
    let json = Data(#"{"formulae":[{"name":"python@3.13","full_name":"python@3.13","aliases":["python3","python"],"oldnames":[]}]}"#.utf8)
    let aliases = Homebrew.aliases(json)
    #expect(aliases["python@3.13"]?.contains("python3") == true)
    #expect(Homebrew.removable(["python@3.13", "libyaml"], declared: ["python3"], aliases: aliases) == ["libyaml"])
    #expect(Homebrew.aliases(Data("nope".utf8)).isEmpty)
    // Without case, and a tap's formula by its full name in the config.
    #expect(Homebrew.removable(["jq", "Thing", "libyaml"], declared: ["homebrew/core/jq", "thing"]) == ["libyaml"])
    for path in ["./x.rb", "../x", ".hidden", "/tmp/x", "evil.rb", "a/../b"] { #expect(!Homebrew.isName(path), "\(path)") }
    #expect(Homebrew.isName("python@3.13") && Homebrew.isName("supabase/tap/thing"))
    // Brew refuses to uninstall what a kept formula needs.
    #expect(Homebrew.sparing(["oniguruma", "libyaml"], dependencies: "oniguruma\n") == ["libyaml"])
}

@Test func brewNeverAutoremovesBehindTheDialog() {
    #expect(Homebrew.quiet["HOMEBREW_NO_AUTOREMOVE"] == "1" && Homebrew.quiet["HOMEBREW_NO_AUTO_UPDATE"] == "1")
    let task = Maintenance.tasks(brew: "/opt/homebrew/bin/brew", docker: nil, xcode: false).first { $0.id == "brew" }
    #expect(task?.env == Homebrew.quiet)
}
