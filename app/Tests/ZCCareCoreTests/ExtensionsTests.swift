import Foundation
import Testing
@testable import ZCCareCore

private let finderSync = """
+    com.macpaw.CleanMyMac5.FinderSyncExtension(5.7.2)
	            Path = /Applications/CleanMyMac_5.app/Contents/PlugIns/CleanMyMac_5_FinderSyncExtension.appex
	            UUID = 090FDD0B-F847-4470-87CB-D2A80D96C416
	       Timestamp = 2026-10-15 20:35:06 +0000
	             SDK = com.apple.FinderSync
	   Parent Bundle = /Applications/CleanMyMac_5.app
	    Display Name = CleanMyMac_5_FinderSyncExtension
	      Short Name = CleanMyMac_5_FinderSyncExtension
	     Parent Name = CleanMyMac
	        Platform = macOS

 (1 plug-in)
"""

private let quickLook = """
     com.apple.CalendarUI.SpotlightEventPreview(1)
	            Path = /System/Library/PrivateFrameworks/CalendarUI.framework/Versions/A/PlugIns/SpotlightEventPreview.appex
	    Display Name = SpotlightEventPreview
	        Platform = macOS

-    com.example.Preview(2.0)
	            Path = /Applications/Example.app/Contents/PlugIns/Preview.appex
	    Display Name = Example Preview
	   Parent Bundle = /Applications/Example.app
"""

private let systemTable = """
2 extension(s)
--- com.apple.system_extension.network_extension
enabled	active	teamID	bundleID (version)	name	[state]
*	*	ABCDE12345	com.example.vpn.extension (1.2/34)	Example VPN	[activated enabled]
--- com.apple.system_extension.endpoint_security (Go to 'System Settings > General > Login Items & Extensions' to modify these system extension(s))
enabled	active	teamID	bundleID (version)	name	[state]
		-	com.shady.agent (1.0/1)	Shady Agent	[activated disabled]
"""

@Test func pluginkitParsesAFinderSyncBlock() {
    let items = Extensions.parsePluginkit(finderSync, kind: .finderSync)
    #expect(items.count == 1)
    #expect(items[0].identifier == "com.macpaw.CleanMyMac5.FinderSyncExtension")
    #expect(items[0].version == "5.7.2")
    #expect(items[0].name == "CleanMyMac_5_FinderSyncExtension")
    #expect(items[0].enabled)
    #expect(items[0].hostName == "CleanMyMac")
    #expect(items[0].hostPath == "/Applications/CleanMyMac_5.app")
}

@Test func pluginkitReadsTheElectionMark() {
    let items = Extensions.parsePluginkit(quickLook, kind: .quickLook)
    #expect(items.map(\.enabled) == [true, false])
    #expect(items[0].hostPath == nil)
    #expect(items[1].name == "Example Preview")
}

@Test func pluginkitIgnoresEmptyAndGarbageInput() {
    #expect(Extensions.parsePluginkit("", kind: .share).isEmpty)
    #expect(Extensions.parsePluginkit("  (no matches)\n", kind: .share).isEmpty)
    #expect(Extensions.parsePluginkit("pluginkit: Connection invalid\n\n???\n", kind: .share).isEmpty)
}

@Test func systemExtensionsParseTheTable() {
    let items = Extensions.parseSystemExtensions(systemTable)
    #expect(items.count == 2)
    #expect(items[0].identifier == "com.example.vpn.extension")
    #expect(items[0].version == "1.2/34")
    #expect(items[0].teamID == "ABCDE12345")
    #expect(items[0].enabled)
    #expect(items[0].detail == "network extension · activated enabled")
    #expect(items[1].teamID == nil)
    #expect(items[1].unidentified)
    #expect(!items[1].enabled)
    #expect(items[1].detail == "endpoint security · activated disabled")
}

@Test func loadListsABundleOnTwoProtocolsOnce() async {
    let runner = ProtocolRunner(pluginkit: ["com.apple.quicklook.preview": quickLook, "com.apple.quicklook.thumbnail": quickLook])
    let items = await Extensions.load(runner: runner, hostExists: { _ in true })
    #expect(items.map(\.name) == ["Example Preview"])
}

@Test func systemExtensionsIgnoreEmptyAndGarbageInput() {
    #expect(Extensions.parseSystemExtensions("0 extension(s)\n").isEmpty)
    #expect(Extensions.parseSystemExtensions("").isEmpty)
    #expect(Extensions.parseSystemExtensions("systemextensionsctl: list command failed\n").isEmpty)
}

private struct ProtocolRunner: Runner {
    var pluginkit: [String: String]
    var system = ""

    func run(_ executable: String, _ args: [String], env: [String: String]) async throws -> CommandResult {
        if executable.hasSuffix("systemextensionsctl") { return ok(system) }
        return ok(pluginkit[args.last ?? ""] ?? "  (no matches)\n")
    }
}

@Test func loadGroupsByKindDropsAppleOnesAndFlagsAGoneHost() async {
    let runner = ProtocolRunner(pluginkit: ["com.apple.FinderSync": finderSync, "com.apple.quicklook.preview": quickLook],
                                system: systemTable)
    let items = await Extensions.load(runner: runner, hostExists: { $0 == "/Applications/CleanMyMac_5.app" })
    #expect(items.map(\.kind) == [.finderSync, .quickLook, .system, .system])
    #expect(items.first { $0.kind == .finderSync }?.hostGone == false)
    #expect(items.first { $0.kind == .quickLook }?.hostGone == true)
}

@Test func loadSurvivesFailingCommands() async {
    struct Failing: Runner {
        func run(_ executable: String, _ args: [String], env: [String: String]) async throws -> CommandResult {
            CommandResult(status: 1, stderr: "Connection invalid")
        }
    }
    #expect(await Extensions.load(runner: Failing()).isEmpty)
}
