import Foundation
import Testing
@testable import ZCCareCore

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("zccare-spots-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ url: URL, _ data: Data) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}

@Test func brokenPreferencesAreTheUnreadableAndEmptyPlists() throws {
    let home = try tempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    let prefs = home.appendingPathComponent("Library/Preferences")
    let good = try PropertyListSerialization.data(fromPropertyList: ["a": 1], format: .binary, options: 0)
    try write(prefs.appendingPathComponent("com.good.plist"), good)
    try write(prefs.appendingPathComponent("com.empty.plist"), Data())
    try write(prefs.appendingPathComponent("com.garbage.plist"), Data("not a plist".utf8))
    try write(prefs.appendingPathComponent("ByHost/com.host.plist"), Data([0xff, 0x00]))
    try write(prefs.appendingPathComponent("notes.txt"), Data("junk".utf8))

    let found = BrokenPreferences.find(home: home.path).map(\.name)
    #expect(found == ["com.host.plist", "com.empty.plist", "com.garbage.plist"])
}

@Test func mailAttachmentsSkipLocalMailboxesAndSmallFiles() throws {
    let home = try tempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    let v = home.appendingPathComponent("Library/Mail/V10")
    try write(v.appendingPathComponent("ACC-1/INBOX.mbox/1/Data/Attachments/4/2/big.pdf"), Data(repeating: 1, count: 20_000))
    try write(v.appendingPathComponent("ACC-1/INBOX.mbox/1/Data/Attachments/4/3/small.png"), Data(repeating: 1, count: 10))
    try write(v.appendingPathComponent("ACC-1/INBOX.mbox/1/Data/Messages/4.emlx"), Data(repeating: 1, count: 20_000))
    try write(v.appendingPathComponent("Mailboxes/Local.mbox/1/Data/Attachments/1/2/local.pdf"), Data(repeating: 1, count: 20_000))
    try write(v.appendingPathComponent("MailData/Envelope Index"), Data(repeating: 1, count: 20_000))

    let found = MailAttachments.find(home: home.path, minimum: 5000)
    #expect(found.map(\.name) == ["big.pdf"])
    #expect(found[0].size >= 20_000)
}

@Test func trashBinsReadEachVolumesTrash() throws {
    let home = try tempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    let volume = home.appendingPathComponent("Volumes/Backup")
    try write(home.appendingPathComponent(".Trash/a.bin"), Data(repeating: 1, count: 8192))
    try write(volume.appendingPathComponent(".Trashes/\(getuid())/b.bin"), Data(repeating: 1, count: 4096))
    let missing = home.appendingPathComponent("Volumes/NoTrash")
    try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)

    let bins = TrashBins.find(home: home.path, volumes: [volume, missing])
    #expect(bins.map(\.name) == ["Macintosh HD", "Backup"])
    #expect(bins[0].size >= 8192)
    #expect(bins[1].size >= 4096)
}

@Test func iosBackupsStayOutOfCleanAll() {
    let spots = Junk.spots(home: "/h")
    #expect(spots.filter(\.optional).map(\.id) == ["iosbackups"])
    #expect(spots.contains { $0.id == "devicelogs" })
}
