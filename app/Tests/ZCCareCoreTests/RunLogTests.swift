import Foundation
import Testing
@testable import ZCCareCore

private let when = Date(timeIntervalSince1970: 1_700_000_000)

@Test func runLogCountsOnlyWhatWent() {
    var log = RunLog(title: "Large Files", permanent: false, started: when)
    log.add(RunLog.Line(name: "a.mov", detail: "/Users/me/Movies", size: 1000))
    log.add(RunLog.Line(name: "b.mov", detail: "/Users/me/Movies", size: 500, failure: "in use"))
    log.end(at: when)
    #expect(log.freed == 1000)
    #expect(log.done.map(\.name) == ["a.mov"])
    #expect(log.failed.map(\.name) == ["b.mov"])
    #expect(!log.allDone)
    #expect(log.summary == "1 of 2 items moved to the Trash, 1 KB freed; 1 stayed.")
}

@Test func runLogSummaryWhenAllWent() {
    var log = RunLog(title: "Installers", permanent: true, started: when)
    log.add(RunLog.Line(name: "x.dmg", detail: "/Users/me/Downloads", size: 2_000_000))
    #expect(log.allDone)
    #expect(log.summary == "1 item deleted, 2 MB freed.")
}

@Test func runLogReadsAnItemRemoval() {
    var removal = Removal()
    removal.failures = [Removal.Failure(name: "locked.pdf", reason: .permissionDenied)]
    var log = RunLog(title: "Old Downloads", permanent: false)
    log.add(URL(fileURLWithPath: "/Users/me/Downloads/locked.pdf"), size: 10, removal: removal)
    log.add(URL(fileURLWithPath: "/Users/me/Downloads/free.pdf"), size: 20, removal: removal)
    #expect(log.lines.map(\.failure) == ["permission denied", nil])
    #expect(log.lines[0].detail == "/Users/me/Downloads")
    #expect(log.freed == 20)
}

@Test func runLogReadsABatchTrash() {
    let a = URL(fileURLWithPath: "/Users/me/Library/Caches/com.a")
    let b = URL(fileURLWithPath: "/Users/me/Library/Caches/com.b")
    var log = RunLog(title: "Leftovers", permanent: false)
    log.add([(a, 5), (b, 7)], trashed: [Trashed(original: a, inTrash: URL(fileURLWithPath: "/Users/me/.Trash/com.a"), identity: nil)],
            failure: "The operation couldn’t be completed.")
    #expect(log.lines[0].done)
    #expect(log.lines[1].failure == "The operation couldn’t be completed.")
    #expect(log.freed == 5)
    var clean = RunLog(title: "Leftovers", permanent: false)
    clean.add([(a, 5), (b, 7)], trashed: [], failure: nil)
    #expect(clean.allDone)
}

@Test func runLogTextListsEveryLine() {
    var log = RunLog(title: "Large Files", permanent: false, started: when)
    log.add(RunLog.Line(name: "a.mov", detail: "/Users/me/Movies", size: 1000))
    log.add(RunLog.Line(name: "b.mov", detail: "/Users/me/Movies", size: 500, failure: "in use"))
    log.end(at: when)
    let lines = log.text.components(separatedBy: "\n")
    #expect(lines[0].hasPrefix("Large Files · 2023-11-14T22:13:20Z"))
    #expect(lines[1] == log.summary)
    #expect(lines[3] == "ok    /Users/me/Movies/a.mov (1 KB)")
    #expect(lines[4] == "stayed /Users/me/Movies/b.mov: in use")
}
