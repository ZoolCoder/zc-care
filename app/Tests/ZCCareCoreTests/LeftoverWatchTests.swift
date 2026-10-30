import Foundation
import Testing
@testable import ZCCareCore

@Test func leftoverWatchWaitsForASecondCheck() {
    var watch = LeftoverWatch()
    let size: (String, String) -> Int64 = { _, _ in 50_000_000 }
    let before = ["com.x.app": "X", "com.y.app": "Y"]
    #expect(watch.alerts(installed: before, elsewhere: { _ in false }, size: size).isEmpty)
    // An updater swaps the bundle: gone for one check, then back.
    #expect(watch.alerts(installed: ["com.y.app": "Y"], elsewhere: { _ in false }, size: size).isEmpty)
    #expect(watch.alerts(installed: before, elsewhere: { _ in false }, size: size).isEmpty)
    // Gone for good.
    #expect(watch.alerts(installed: ["com.y.app": "Y"], elsewhere: { _ in false }, size: size).isEmpty)
    let alerts = watch.alerts(installed: ["com.y.app": "Y"], elsewhere: { _ in false }, size: size)
    #expect(alerts.map(\.id) == ["leftovers com.x.app"])
    #expect(alerts.first?.title == "X left 50 MB behind")
    // Told once.
    #expect(watch.alerts(installed: ["com.y.app": "Y"], elsewhere: { _ in false }, size: size).isEmpty)
}

@Test func leftoverWatchSkipsMovedAndSmallLeftovers() {
    var watch = LeftoverWatch()
    let all = ["com.moved.app": "Moved", "com.small.app": "Small", "com.gone.app": "Gone"]
    let size: (String, String) -> Int64 = { id, _ in id == "com.small.app" ? 4096 : 50_000_000 }
    let moved: (String) -> Bool = { $0 == "com.moved.app" }
    _ = watch.alerts(installed: all, elsewhere: moved, size: size)
    _ = watch.alerts(installed: [:], elsewhere: moved, size: size)
    #expect(watch.alerts(installed: [:], elsewhere: moved, size: size).map(\.id) == ["leftovers com.gone.app"])
}

@Test func leftoverWatchReadsAppBundles() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let contents = dir.appendingPathComponent("Foo.app/Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let plist = ["CFBundleIdentifier": "com.foo.app", "CFBundlePackageType": "APPL"]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: contents.appendingPathComponent("Info.plist"))
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("Notes"), withIntermediateDirectories: true)
    #expect(LeftoverWatch.installed(in: [dir]) == ["com.foo.app": "Foo"])
}

@Test func leftoverWatchKeepsNamesShortAndPlain() {
    #expect(LeftoverWatch.shown("Foo\nWarning: update now") == "FooWarning: update now")
    #expect(LeftoverWatch.shown(String(repeating: "a", count: 60)).count == 40)
    #expect(Leftovers.inTrash("/Users/me/.Trash/Foo.app") && Leftovers.inTrash("/Volumes/X/.Trashes/501/Foo.app"))
    #expect(!Leftovers.inTrash("/Applications/My.Trash Tool.app"))
}

@Test func orphanPathsMatchWhatLeftoversLists() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let fm = FileManager.default
    for path in ["Library/Caches/com.gone.app", "Library/Caches/com.gone.app.helper", "Library/Application Support/Gone",
                 "Library/Caches/com.apple.iMovieApp"] {
        try fm.createDirectory(at: home.appendingPathComponent(path), withIntermediateDirectories: true)
    }
    try fm.createDirectory(at: home.appendingPathComponent("Library/Preferences"), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: home.appendingPathComponent("Library/Preferences/com.gone.app.plist"))
    #expect(Leftovers.orphanPaths(of: "com.gone.app", home: home.path).map { ($0 as NSString).lastPathComponent }
        == ["com.gone.app", "com.gone.app.plist"])
    #expect(Leftovers.orphanPaths(of: "com.apple.iMovieApp", home: home.path).isEmpty)
}
