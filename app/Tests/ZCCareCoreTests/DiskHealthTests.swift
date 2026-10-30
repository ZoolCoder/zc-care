import Foundation
import Testing
@testable import ZCCareCore

private func plist(_ value: Any) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
}

@Test func diskHealthReadsNVMeCounters() throws {
    let data = try plist([
        "MediaName": "APPLE SSD AP0512R", "SMARTStatus": "Verified",
        "SMARTDeviceSpecificKeysMayVaryNotGuaranteed": [
            "PERCENTAGE_USED": 1, "AVAILABLE_SPARE": 100, "AVAILABLE_SPARE_THRESHOLD": 99, "TEMPERATURE": 314,
            "POWER_ON_HOURS_0": 1287, "POWER_ON_HOURS_1": 0, "DATA_UNITS_WRITTEN_0": 132_431_529, "DATA_UNITS_WRITTEN_1": 0,
            "MEDIA_ERRORS_0": 0, "MEDIA_ERRORS_1": 0, "UNSAFE_SHUTDOWNS_0": 21, "UNSAFE_SHUTDOWNS_1": 0,
        ],
    ])
    let health = try #require(DiskHealth(diskInfo: data))
    #expect(health.model == "APPLE SSD AP0512R" && health.wear == 1 && health.celsius == 41 && health.powerOnHours == 1287)
    #expect(health.written == 132_431_529 * 512_000 && health.unsafeShutdowns == 21 && health.read == nil)
    #expect(health.verdict == .good && health.concerns.isEmpty)
}

@Test func diskHealthFlagsWearAndSpare() throws {
    var health = DiskHealth()
    #expect(health.verdict == .unknown)
    health.smart = "Not Supported"
    #expect(health.verdict == .unknown)
    health.wear = 92
    #expect(health.verdict == .watch && health.concerns.count == 1)
    health.spare = 5
    health.spareThreshold = 10
    #expect(health.verdict == .failing)
    health = DiskHealth()
    health.smart = "Failing"
    #expect(health.verdict == .failing && health.concerns.first?.contains("back up") == true)
}

@Test func containerSpaceListsHiddenVolumes() throws {
    let data = try plist(["Containers": [
        ["ContainerReference": "disk1", "CapacityCeiling": 1000, "CapacityFree": 900, "Volumes": [["Name": "xART", "Roles": ["xART"], "CapacityInUse": 10]]],
        ["ContainerReference": "disk3", "CapacityCeiling": 500, "CapacityFree": 100, "Volumes": [
            ["Name": "Macintosh HD", "Roles": ["System"], "CapacityInUse": 50],
            ["Name": "Data", "Roles": ["Data"], "CapacityInUse": 300],
            ["Name": "VM", "Roles": ["VM"], "CapacityInUse": 20],
        ]],
    ]])
    let space = try #require(ContainerSpace(apfsList: data, container: "disk3"))
    #expect(space.volumes.map(\.name) == ["Data", "Macintosh HD", "VM"])
    #expect(space.unaccounted == 30)
    #expect(ContainerSpace(apfsList: data, container: "disk9") == nil)
}

@Test func startupDiskResolvesPhysicalStore() throws {
    let data = try plist(["APFSContainerReference": "disk3", "APFSPhysicalStores": [["APFSPhysicalStore": "disk0s2"]]])
    let startup = try #require(DiskInfo.startup(data))
    #expect(startup.container == "disk3" && startup.physical == "disk0")
    #expect(DiskInfo.snapshots("Snapshots for disk /:\ncom.apple.TimeMachine.2026-10-30-050000.local\n") == ["com.apple.TimeMachine.2026-10-30-050000.local"])
}

@Test func diskHealthReadsWarningsFromThePlist() throws {
    let data = try plist(["SMARTStatus": "Verified", "SMARTDeviceSpecificKeysMayVaryNotGuaranteed": [
        "AVAILABLE_SPARE": 3, "AVAILABLE_SPARE_THRESHOLD": 10, "TEMPERATURE": 0, "MEDIA_ERRORS_0": 2, "MEDIA_ERRORS_1": 0,
        "POWER_CYCLES_0": 5, "POWER_CYCLES_1": 1,
    ]])
    let health = try #require(DiskHealth(diskInfo: data))
    #expect(health.celsius == nil && health.powerCycles == nil && health.mediaErrors == 2)
    #expect(health.verdict == .failing)
    var errors = DiskHealth()
    errors.mediaErrors = 1
    #expect(errors.verdict == .watch)
    let warned = try #require(DiskHealth(diskInfo: plist(["SMARTStatus": "Verified",
                                                           "SMARTDeviceSpecificKeysMayVaryNotGuaranteed": ["CRITICAL_WARNING": 4]])))
    #expect(warned.verdict == .failing && warned.concerns == ["The drive raised a critical warning: back up now."])
    var hot = DiskHealth()
    hot.smart = "Verified"
    hot.criticalWarning = 2
    #expect(hot.verdict == .watch && hot.concerns.count == 1)
    // Low spare sets bit 0 too: one cause, one line.
    var spent = DiskHealth()
    spent.smart = "Verified"
    spent.criticalWarning = 1
    spent.spare = 5
    spent.spareThreshold = 10
    #expect(spent.verdict == .failing && spent.concerns == ["Spare blocks are below the drive's own threshold: back up now."])
    spent.criticalWarning = 5
    #expect(spent.concerns.count == 2)
}
