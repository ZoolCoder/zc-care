import Foundation
import Testing
@testable import ZCCareCore

@Test func machOHeadersNameTheirCPUs() {
    let thinArm: [UInt8] = [0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0x00, 0x00, 0x01]
    let thinIntel: [UInt8] = [0xcf, 0xfa, 0xed, 0xfe, 0x07, 0x00, 0x00, 0x01]
    #expect(Architectures.parse(thinArm) == [.arm64])
    #expect(Architectures.parse(thinIntel) == [.x86_64])
    var fat: [UInt8] = [0xca, 0xfe, 0xba, 0xbe, 0, 0, 0, 2]
    fat += [0x01, 0, 0, 0x07] + Array(repeating: 0, count: 16)
    fat += [0x01, 0, 0, 0x0c] + Array(repeating: 0, count: 16)
    #expect(Architectures.parse(fat) == [.x86_64, .arm64])
    #expect(Architectures.parse([0x7f, 0x45, 0x4c, 0x46, 0, 0, 0, 0]) == nil)
    #expect(Architectures.parse([0xca, 0xfe, 0xba, 0xbe, 0, 0, 0, 0]) == nil)
    #expect(Architectures.of(URL(fileURLWithPath: "/usr/bin/true"))?.contains(.arm64) == true)
    #expect(Architectures.intelOnly(URL(fileURLWithPath: "/System/Applications/Calculator.app")) == false)
}

@Test func machOFatHeadersOfEveryShape() throws {
    // 64-bit fat entries are 32 bytes apart.
    var fat64: [UInt8] = [0xca, 0xfe, 0xba, 0xbf, 0, 0, 0, 2]
    fat64 += [0x01, 0, 0, 0x07] + Array(repeating: 0, count: 28)
    fat64 += [0x01, 0, 0, 0x0c] + Array(repeating: 0, count: 28)
    #expect(Architectures.parse(fat64) == [.x86_64, .arm64])
    // A Java class shares the magic; its version sits where the count would.
    #expect(Architectures.parse([0xca, 0xfe, 0xba, 0xbe, 0, 0, 0, 0x41]) == nil)
    // Cut short after one of two entries: what was read.
    let cut: [UInt8] = [0xca, 0xfe, 0xba, 0xbe, 0, 0, 0, 2, 0x01, 0, 0, 0x0c] + Array(repeating: 0, count: 16)
    #expect(Architectures.parse(cut) == [.arm64])
    // A FIFO named as the executable is not opened.
    let fifo = FileManager.default.temporaryDirectory.appendingPathComponent("arch-\(UUID().uuidString)")
    #expect(mkfifo(fifo.path, 0o600) == 0)
    defer { try? FileManager.default.removeItem(at: fifo) }
    #expect(Architectures.of(fifo) == nil)
}

@Test func appsInstalledTwiceAreFoundByBundleID() {
    let a = InstalledApp(name: "ZCCare", url: URL(fileURLWithPath: "/Applications/ZCCare.app"), bundleID: "dev.x.zc", source: .cask("zc"))
    let b = InstalledApp(name: "ZCCare", url: URL(fileURLWithPath: "/Users/me/Applications/ZCCare.app"), bundleID: "dev.x.zc", source: .other)
    let c = InstalledApp(name: "Other", url: URL(fileURLWithPath: "/Applications/Other.app"), bundleID: nil, source: .other)
    let d = InstalledApp(name: "Odd", url: URL(fileURLWithPath: "/Applications/Odd.app"), bundleID: nil, source: .other)
    #expect(AppCatalog.copies([a, b, c, d]) == [a.id, b.id])
    // Outside the folders brew installs into, a cask's file name means nothing.
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("apps-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: home.appendingPathComponent("ZCCare.app"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let found = AppCatalog.apps(in: home, caskApps: ["ZCCare.app": "zc-care"], items: [], managed: false)
    #expect(found.map(\.source) == [.other] && found.first?.declared == nil)
}
