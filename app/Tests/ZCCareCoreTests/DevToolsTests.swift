import Foundation
import Testing
@testable import ZCCareCore

private let df = """
{"Active":"2","Reclaimable":"1.2GB (50%)","Size":"2.4GB","TotalCount":"5","Type":"Images"}
{"Active":"1","Reclaimable":"0B (0%)","Size":"12.5kB","TotalCount":"1","Type":"Containers"}
{"Active":"0","Reclaimable":"512MB","Size":"512MB","TotalCount":"7","Type":"Build Cache"}
"""

@Test func dockerDfParsesEachKind() {
    let usage = Docker.parse(df: df)
    #expect(usage.map(\.type) == ["Images", "Containers", "Build Cache"])
    #expect(usage[0] == DockerUsage(type: "Images", total: 5, active: 2, size: 2_400_000_000, reclaimable: 1_200_000_000))
    #expect(usage[1].size == 12_500)
    #expect(usage[1].reclaimable == 0)
    #expect(usage[2].reclaimable == 512_000_000)
}

@Test func dockerDfSkipsLinesItCannotRead() {
    #expect(Docker.parse(df: "Cannot connect to the Docker daemon\n").isEmpty)
    #expect(Docker.parse(df: "").isEmpty)
}

@Test func dockerUsageIsNilWhenTheDaemonDoesNotAnswer() async {
    let down = FakeRunner(outputs: ["system": CommandResult(status: 1, stderr: "Cannot connect to the Docker daemon")])
    #expect(await Docker.usage(docker: "docker", env: [:], runner: down) == nil)
    let up = FakeRunner(outputs: ["system": ok(df)])
    #expect(await Docker.usage(docker: "docker", env: [:], runner: up)?.count == 3)
}

@Test func dockerPrunesTakeNoPromptsAndTouchOnlyWhatIsUnused() {
    #expect(Docker.pruneBuildCache == ["builder", "prune", "--force"])
    #expect(Docker.pruneDanglingImages == ["image", "prune", "--force"])
}

@Test func xcodeSpotsListWhatExistsBiggestFirst() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("zccare-xcode-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    func fill(_ path: String, bytes: Int) throws {
        let folder = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(count: bytes).write(to: folder.appendingPathComponent("f"))
    }
    try fill("Library/Developer/Xcode/DerivedData", bytes: 10_000)
    try fill("Library/Developer/Xcode/Archives", bytes: 200_000)
    try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Developer/Xcode/iOS DeviceSupport"),
                                            withIntermediateDirectories: true)
    let spots = XcodeSpots.find(home: home.path)
    #expect(spots.map(\.id) == ["archives", "xcode"])
    #expect(spots[0].busyBundleIDs == ["com.apple.dt.Xcode"])
    #expect(spots[0].size > spots[1].size)
}
