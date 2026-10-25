import Foundation
import Testing
@testable import ZCCareCore

@Test func junkIdsAreUniqueAndTheDeveloperCachesAreThere() {
    let spots = Junk.spots(home: "/h")
    #expect(Set(spots.map(\.id)).count == spots.count)
    let paths = Dictionary(uniqueKeysWithValues: spots.map { ($0.id, $0.path) })
    #expect(paths["pub"] == "/h/.pub-cache/hosted")
    #expect(paths["gradlewrapper"] == "/h/.gradle/wrapper/dists")
    #expect(paths["pnpm"] == "/h/Library/pnpm/store")
    #expect(paths["pnpmxdg"] == "/h/.local/share/pnpm/store")
    #expect(paths["bun"] == "/h/.bun/install/cache")
    #expect(paths["gomod"] == "/h/go/pkg/mod/cache/download")
    #expect(paths["misedownloads"] == "/h/.local/share/mise/downloads")
}

// The shape simctl prints: an object keyed by runtime identifier.
private let runtimeList = """
{
  "9A1B2C3D-0000-0000-0000-000000000001": {
    "build": "22F77", "identifier": "9A1B2C3D-0000-0000-0000-000000000001", "kind": "Disk Image",
    "platformIdentifier": "com.apple.platform.iphonesimulator", "sizeBytes": 8400000000,
    "state": "Ready", "version": "18.5", "deletable": true
  },
  "9A1B2C3D-0000-0000-0000-000000000002": {
    "build": "23A339", "identifier": "9A1B2C3D-0000-0000-0000-000000000002", "kind": "Disk Image",
    "platformIdentifier": "com.apple.platform.iphonesimulator", "diskUsage": 7000000000,
    "state": "Unusable", "version": "26.0", "deletable": false
  },
  "9A1B2C3D-0000-0000-0000-000000000003": {
    "build": "22T250", "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.watchOS-11-5",
    "sizeBytes": 3000000000, "state": "Ready", "version": "11.5"
  }
}
"""

@Test func simulatorRuntimesParseWithSizePlatformAndState() {
    let runtimes = Simulators.parse(runtimes: Data(runtimeList.utf8))
    #expect(runtimes.map(\.title) == ["iOS 26.0", "iOS 18.5", "watchOS 11.5"])
    #expect(runtimes[0].size == 7_000_000_000)
    #expect(runtimes[0].state == "Unusable")
    #expect(!runtimes[0].deletable && runtimes[1].deletable && runtimes[2].deletable)
    #expect(runtimes[1] == SimulatorRuntime(id: "9A1B2C3D-0000-0000-0000-000000000001", platform: "iOS", version: "18.5",
                                            build: "22F77", size: 8_400_000_000, state: "Ready"))
}

@Test func simulatorRuntimesAreNoneForEmptyOrGarbage() {
    #expect(Simulators.parse(runtimes: Data("{\n\n}\n".utf8)).isEmpty)
    #expect(Simulators.parse(runtimes: Data("not json".utf8)).isEmpty)
    #expect(Simulators.parse(runtimes: Data("[1, 2]".utf8)).isEmpty)
    #expect(Simulators.parse(runtimes: Data()).isEmpty)
}

@Test func simulatorRuntimesAreNilWhenXcrunFails() async {
    let down = FakeRunner(outputs: ["simctl": CommandResult(status: 1, stderr: "unable to find utility")])
    #expect(await Simulators.runtimes(runner: down, env: [:]) == nil)
    let up = FakeRunner(outputs: ["simctl": ok(runtimeList)])
    #expect(await Simulators.runtimes(runner: up, env: [:])?.count == 3)
    #expect(Simulators.deleteRuntime("ID") == ["simctl", "runtime", "delete", "ID"])
}

@Test func androidListsSystemImagesAndDevicesBiggestFirst() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("zccare-android-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    func fill(_ path: String, bytes: Int) throws {
        let folder = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(count: bytes).write(to: folder.appendingPathComponent("f"))
    }
    try fill("sdk/system-images/android-36/google_apis_playstore/arm64-v8a", bytes: 300_000)
    try fill("avd/Pixel_8.avd", bytes: 900_000)
    try Data().write(to: root.appendingPathComponent("avd/Pixel_8.ini"))
    let items = Android.items(sdk: root.appendingPathComponent("sdk").path, avdHome: root.appendingPathComponent("avd").path)
    #expect(items.map(\.name) == ["Pixel_8", "android-36 · google_apis_playstore · arm64-v8a"])
    #expect(items.map(\.kind) == [.device, .systemImage])
    #expect(items[0].size >= 900_000)
}

@Test func androidIsEmptyWhereNothingIsInstalled() {
    #expect(Android.items(sdk: "/nonexistent-sdk", avdHome: "/nonexistent-avd").isEmpty)
    #expect(Android.sdkRoot(home: "/nonexistent-home", environment: ["ANDROID_HOME": "/nonexistent-sdk"]) == nil)
}
