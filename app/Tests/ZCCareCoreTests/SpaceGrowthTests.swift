import Foundation
import Testing
@testable import ZCCareCore

private let MB: Int64 = 1_000_000

private func tree(_ downloads: Int64, _ library: Int64 = 100 * MB, extra: [SpaceNode] = []) -> SpaceNode {
    let dl = SpaceNode(path: "/h/Downloads", size: downloads, children: extra)
    let lib = SpaceNode(path: "/h/Library", size: library, children: [])
    return SpaceNode(path: "/h", size: downloads + library, children: [dl, lib])
}

private let day: TimeInterval = 86400

@Test func firstRescanKeepsTheScanBeforeAsBaseline() {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let first = SpaceScan(scannedAt: t0, root: tree(100 * MB))
    let second = first.followed(by: tree(300 * MB), at: t0 + 3 * day)
    #expect(second.previousAt == t0)
    #expect(second.growth(of: "/h/Downloads") == 200 * MB)
}

@Test func aRescanWithinADayKeepsTheOlderBaseline() {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let second = SpaceScan(scannedAt: t0, root: tree(100 * MB))
        .followed(by: tree(300 * MB), at: t0 + 3 * day)
    let third = second.followed(by: tree(310 * MB), at: t0 + 3 * day + 3600)
    #expect(third.previousAt == t0)
    #expect(third.growth(of: "/h/Downloads") == 210 * MB)
    let fourth = third.followed(by: tree(320 * MB), at: t0 + 5 * day)
    #expect(fourth.previousAt == third.scannedAt)
}

@Test func aSecondScanWithinADayOfTheFirstStillComparesWithIt() {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let second = SpaceScan(scannedAt: t0, root: tree(100 * MB)).followed(by: tree(200 * MB), at: t0 + 60)
    #expect(second.growth(of: "/h/Downloads") == 100 * MB)
}

@Test func growthIsNilWithoutAPreviousScanOrWhereItDidNotReach() {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let only = SpaceScan(scannedAt: t0, root: tree(100 * MB))
    #expect(only.growth(of: "/h/Downloads") == nil)
    #expect(only.growers().isEmpty)
    let deeper = only.followed(by: tree(200 * MB, extra: [SpaceNode(path: "/h/Downloads/new", size: 10, children: [])]), at: t0 + 2 * day)
    #expect(deeper.growth(of: "/h/Downloads/new") == nil)
}

@Test func growersListsTheBiggestAndSkipsNoise() {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let scan = SpaceScan(scannedAt: t0, root: tree(100 * MB, 100 * MB))
        .followed(by: tree(400 * MB, 110 * MB), at: t0 + 2 * day)
    #expect(scan.growers() == [Grower(path: "/h/Downloads", grew: 300 * MB)])
}

@Test func aFolderWhoseGrowthIsOneChildsGivesWayToIt() {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let before = tree(100 * MB, extra: [SpaceNode(path: "/h/Downloads/iso", size: 50 * MB, children: [])])
    let after = tree(400 * MB, extra: [SpaceNode(path: "/h/Downloads/iso", size: 340 * MB, children: [])])
    let scan = SpaceScan(scannedAt: t0, root: before).followed(by: after, at: t0 + 2 * day)
    #expect(scan.growers().map(\.path) == ["/h/Downloads/iso"])
    #expect(scan.growers(under: "/h/Downloads").map(\.path) == ["/h/Downloads/iso"])
}

@Test func oldSavedScansWithoutAPreviousStillDecode() throws {
    let json = #"{"scannedAt":0,"root":{"path":"/h","size":1,"children":[]}}"#
    let scan = try JSONDecoder().decode(SpaceScan.self, from: Data(json.utf8))
    #expect(scan.previousRoot == nil)
    #expect(scan.previousAt == nil)
}

@Test func foldersMapToTheModuleThatCleansThem() {
    #expect(SpaceDestination.of("/h/Downloads/a", home: "/h") == .clutter)
    #expect(SpaceDestination.of("/h/Library/Developer/Xcode", home: "/h") == .developer)
    #expect(SpaceDestination.of("/h/.gradle/caches", home: "/h") == .developer)
    #expect(SpaceDestination.of("/h/Library/CloudStorage/Dropbox", home: "/h") == .cloud)
    #expect(SpaceDestination.of("/h/Movies", home: "/h") == nil)
    #expect(SpaceDestination.of("/other/Downloads", home: "/h") == nil)
    #expect(SpaceDestination.of("/h/DownloadsExtra", home: "/h") == nil)
}
