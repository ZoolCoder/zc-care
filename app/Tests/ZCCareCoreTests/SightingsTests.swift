import Foundation
import Testing
@testable import ZCCareCore

private let t0 = Date(timeIntervalSince1970: 1_000_000)
private let day: TimeInterval = 86400

@Test func theFirstReadOfAListMarksNothingNew() {
    var s = Sightings()
    s.record("agent", ids: ["a", "b"], at: t0)
    #expect(!s.isNew("agent", "a", at: t0))
    #expect(!s.isNew("agent", "b", at: t0 + 30 * day))
}

@Test func anItemThatAppearsLaterIsNewForAWeek() {
    var s = Sightings()
    s.record("agent", ids: ["a"], at: t0)
    s.record("agent", ids: ["a", "b"], at: t0 + 2 * day)
    #expect(!s.isNew("agent", "a", at: t0 + 2 * day))
    #expect(s.isNew("agent", "b", at: t0 + 2 * day))
    s.record("agent", ids: ["a", "b"], at: t0 + 8 * day)
    #expect(s.isNew("agent", "b", at: t0 + 8 * day))
    #expect(!s.isNew("agent", "b", at: t0 + 9 * day))
}

@Test func anItemThatLeavesAndReturnsIsNewAgain() {
    var s = Sightings()
    s.record("agent", ids: ["a"], at: t0)
    s.record("agent", ids: [], at: t0 + day)
    s.record("agent", ids: ["a"], at: t0 + 20 * day)
    #expect(s.isNew("agent", "a", at: t0 + 20 * day))
}

@Test func listsAreKeptApart() {
    var s = Sightings()
    s.record("agent", ids: ["x"], at: t0)
    s.record("background", ids: ["x"], at: t0 + day)
    #expect(!s.isNew("background", "x", at: t0 + day))
    s.record("background", ids: ["x", "y"], at: t0 + 2 * day)
    #expect(s.isNew("background", "y", at: t0 + 2 * day))
    #expect(!s.isNew("agent", "y", at: t0 + 2 * day))
}

@Test func sightingsSurviveASaveAndLoad() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("zccare-sightings-" + UUID().uuidString + "/s.json")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    var s = Sightings()
    s.record("agent", ids: ["a"], at: t0)
    s.record("agent", ids: ["a", "b"], at: t0 + day)
    try s.save(to: url)
    let back = Sightings.load(from: url)
    #expect(back == s)
    #expect(back.isNew("agent", "b", at: t0 + day))
    #expect(Sightings.load(from: url.appendingPathExtension("missing")) == Sightings())
}
