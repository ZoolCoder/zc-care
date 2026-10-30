import Foundation
import Testing
@testable import ZCCareCore

private let banner = """
Software Update Tool

Finding available software
"""

@Test func macUpdatesNoneAvailable() {
    #expect(MacUpdate.parse(banner + "\nNo new software available.\n").isEmpty)
}

@Test func macUpdatesOneUpdate() {
    let text = banner + """

Software Update found the following new or updated software:
* Label: Safari18.1-18.1
\tTitle: Safari, Version: 18.1, Size: 123456KiB, Recommended: YES,

"""
    #expect(MacUpdate.parse(text) == [
        MacUpdate(label: "Safari18.1-18.1", title: "Safari", version: "18.1", sizeKiB: 123_456, recommended: true),
    ])
}

@Test func macUpdatesKeepACommaInTheTitle() {
    let text = "* Label: Pro-1\n\tTitle: Pro Video Formats, Legacy, Version: 2.3, Size: 10KiB, Recommended: NO,\n"
    let update = MacUpdate.parse(text).first
    #expect(update?.title == "Pro Video Formats, Legacy")
    #expect(update?.version == "2.3")
    #expect(update?.recommended == false)
}

@Test func macUpdatesTwoWithARestart() {
    let text = """
    Software Update found the following new or updated software:
    * Label: Command Line Tools for Xcode-16.0
    \tTitle: Command Line Tools for Xcode, Version: 16.0, Size: 700000KiB, Recommended: YES,
    * Label: macOS Sequoia 15.1-24B83
    \tTitle: macOS Sequoia 15.1, Version: 15.1, Size: 3000000KiB, Recommended: YES, Action: restart,
    """
    let updates = MacUpdate.parse(text)
    #expect(updates.map(\.label) == ["Command Line Tools for Xcode-16.0", "macOS Sequoia 15.1-24B83"])
    #expect(updates[0].restart == false)
    #expect(updates[1].restart)
    #expect(updates[1].title == "macOS Sequoia 15.1")
    #expect(updates[1].sizeKiB == 3_000_000)
}

@Test func macUpdatesIgnoreGarbage() {
    #expect(MacUpdate.parse("").isEmpty)
    #expect(MacUpdate.parse("Title: orphan, Version: 1\nrandom * Label: text\n\u{0}\u{1}").isEmpty)
}

@Test func macUpdatesListReadsEitherStream() async throws {
    let quiet = FakeRunner(outputs: ["-l": CommandResult(status: 0, stderr: "No new software available.")])
    #expect(try await MacUpdate.list(runner: quiet).isEmpty)
    let one = FakeRunner(outputs: ["-l": ok("* Label: X-1\n\tTitle: X, Version: 1, Size: 10KiB, Recommended: NO,\n")])
    #expect(try await MacUpdate.list(runner: one).count == 1)
}

@Test func macUpdatesListFailsWithTheLastErrorLine() async {
    let down = FakeRunner(outputs: ["-l": CommandResult(status: 1, stderr: "Software Update Tool\nCan't connect")])
    await #expect(throws: CLIError.self) { try await MacUpdate.list(runner: down) }
}
