import Foundation
import Testing
@testable import ZCCareCore

@Test func recentItemsListsOnlyTheRecentListsNeverFavorites() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("zccare-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let root = home.appendingPathComponent("Library/Application Support/com.apple.sharedfilelist")
    let perApp = root.appendingPathComponent("com.apple.LSSharedFileList.ApplicationRecentDocuments")
    try FileManager.default.createDirectory(at: perApp, withIntermediateDirectories: true)
    for name in ["com.apple.LSSharedFileList.RecentDocuments.sfl4", "com.apple.LSSharedFileList.RecentDocuments.sfl3",
                 "com.apple.LSSharedFileList.RecentServers.sfl4", "com.apple.LSSharedFileList.FavoriteItems.sfl4",
                 "com.apple.LSSharedFileList.RecentDocuments.sfl4.bak", "com.apple.LSSharedFileList.RecentDocumentsX.sfl4"] {
        FileManager.default.createFile(atPath: root.appendingPathComponent(name).path, contents: Data())
    }
    for name in ["com.apple.textedit.sfl4", "notes.txt"] {
        FileManager.default.createFile(atPath: perApp.appendingPathComponent(name).path, contents: Data())
    }

    let lists = RecentItems.find(home: home.path)
    #expect(lists.map(\.name) == ["Recent Documents", "Recent Servers", "Apps' Open Recent"])
    #expect(lists[0].files.map(\.lastPathComponent) == ["com.apple.LSSharedFileList.RecentDocuments.sfl3",
                                                       "com.apple.LSSharedFileList.RecentDocuments.sfl4"])
    #expect(lists[2].files.map(\.lastPathComponent) == ["com.apple.textedit.sfl4"])
    #expect(RecentItems.find(home: home.path + "/nowhere").isEmpty)
}

@Test func wifiFindsTheDeviceAndKeepsNamesWhole() throws {
    let ports = """
    Hardware Port: Ethernet
    Device: en1
    Ethernet Address: aa

    Hardware Port: Wi-Fi
    Device: en0
    Ethernet Address: bb
    """
    #expect(WiFiNetworks.device(in: ports) == "en0")
    #expect(WiFiNetworks.device(in: "Hardware Port: Ethernet\nDevice: en1\n") == nil)

    let list = "Preferred networks on en0:\n\tHome Net\n\tCafé 'Free'\n\t\n"
    let networks = try #require(WiFiNetworks.parse(list, device: "en0"))
    #expect(WiFiNetworks.parse("AuthorizationCreate() failed: -60008\n", device: "en0") == nil)
    #expect(networks.map(\.ssid) == ["Home Net", "Café 'Free'"])

    // A quote in the name stays inside one shell argument.
    let script = Maintenance.adminScript(WiFiNetworks.forgetSteps(networks[1]))
    #expect(script.contains(#"'Café '\\''Free'\\'''"#))

    // Double quotes and backslashes are escaped for AppleScript; $( ) stays inside the shell quotes.
    let hostile = Maintenance.adminScript(WiFiNetworks.forgetSteps(KnownNetwork(ssid: #"a"b\c$(id)"#, device: "en0")))
    #expect(hostile.contains(#"'a\"b\\c$(id)'"#))
}

@Test func browserPrivacyOffersSiteDataAndSavedTabs() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("zccare-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let profile = home.appendingPathComponent("Library/Application Support/BraveSoftware/Brave-Browser/Default")
    let site = profile.appendingPathComponent("IndexedDB/https_example.com_0.indexeddb.leveldb")
    let wallet = profile.appendingPathComponent("IndexedDB/chrome-extension_abc_0.indexeddb.leveldb")
    for folder in [site, wallet, profile.appendingPathComponent("Sessions"), profile.appendingPathComponent("Local Storage/leveldb")] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    try Data(count: 10).write(to: profile.appendingPathComponent("Preferences"))
    try Data(count: 9000).write(to: site.appendingPathComponent("data"))
    try Data(count: 9000).write(to: wallet.appendingPathComponent("vault"))
    try Data(count: 9000).write(to: profile.appendingPathComponent("Local Storage/leveldb/000003.log"))
    try Data(count: 9000).write(to: profile.appendingPathComponent("Sessions/Session_1"))
    try Data(count: 9000).write(to: profile.appendingPathComponent("Bookmarks"))

    let traces = BrowserPrivacy.find(home: home.path)
    #expect(traces.map(\.kind) == [BrowserPrivacy.siteData, BrowserPrivacy.sessions])
    #expect(traces.flatMap(\.paths).map(\.lastPathComponent) == ["https_example.com_0.indexeddb.leveldb", "Sessions"])
    #expect(BrowserPrivacy.clear(traces[0], permanently: true).stayed == 0)
    #expect(FileManager.default.fileExists(atPath: wallet.path))
    #expect(FileManager.default.fileExists(atPath: profile.appendingPathComponent("Local Storage/leveldb").path))
    #expect(FileManager.default.fileExists(atPath: profile.appendingPathComponent("Bookmarks").path))
}

@Test func firefoxSiteDataLeavesExtensionStorage() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("zccare-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let storage = home.appendingPathComponent("Library/Application Support/Firefox/Profiles/x.default/storage/default")
    let site = storage.appendingPathComponent("https+++example.com/idb")
    let addon = storage.appendingPathComponent("moz-extension+++1234^userContextId=4294967295/idb")
    for folder in [site, addon] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    try Data(count: 9000).write(to: site.appendingPathComponent("a.sqlite"))
    try Data(count: 9000).write(to: addon.appendingPathComponent("b.sqlite"))

    let traces = BrowserPrivacy.find(home: home.path).filter { $0.kind == BrowserPrivacy.siteData }
    #expect(traces.flatMap(\.paths).map(\.lastPathComponent) == ["https+++example.com"])
}

@Test func vivaldiSessionsAreNotOffered() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("zccare-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let profile = home.appendingPathComponent("Library/Application Support/Vivaldi/Default")
    try FileManager.default.createDirectory(at: profile.appendingPathComponent("Sessions"), withIntermediateDirectories: true)
    try Data(count: 10).write(to: profile.appendingPathComponent("Preferences"))
    try Data(count: 9000).write(to: profile.appendingPathComponent("Sessions/Work.bin"))
    #expect(BrowserPrivacy.find(home: home.path).isEmpty)
}
