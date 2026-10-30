import Foundation
import Testing
@testable import ZCCareCore

@Test func receiptsSkipAppleAndOptionLikeIds() {
    #expect(Receipts.ids("com.apple.pkg.Keynote14\norg.nodejs.node.pkg\n--forget\nus.zoom.pkg.videomeeting\nbad id\n")
        == ["org.nodejs.node.pkg", "us.zoom.pkg.videomeeting"])
    #expect(Receipts.ids("com.\u{0430}pple.x\n").isEmpty)
}

@Test func receiptPathsCannotClimbOut() throws {
    let files = ["Foo.app/../../etc/hosts"]
    var checked: [String] = []
    let receipt = try #require(Receipts.receipt(id: "f", version: "1", installed: nil, root: "/Applications", files: files) {
        checked.append($0)
        return true
    })
    #expect(checked == ["/etc/hosts"] && receipt.anchor == "/Applications/Foo.app")
}

@Test func receiptInfoJoinsVolumeAndLocation() throws {
    let plist = try PropertyListSerialization.data(fromPropertyList: ["install-location": "Applications", "volume": "/",
                                                                      "install-time": 1_770_295_517, "pkg-version": "6.1"],
                                                   format: .xml, options: 0)
    let info = try #require(Receipts.info(plist))
    #expect(info.version == "6.1" && info.root == "/Applications" && info.installed == Date(timeIntervalSince1970: 1_770_295_517))
    #expect(Receipts.info(Data("nope".utf8)) == nil)
}

@Test func receiptStateFollowsTheFiles() throws {
    let files = ["zoom.us.app/Contents/Info.plist", "zoom.us.app/Contents/MacOS/zoom.us"]
    let gone = try #require(Receipts.receipt(id: "z", version: "1", installed: nil, root: "/Applications", files: files) { _ in false })
    #expect(gone.state == .gone && gone.anchor == "/Applications/zoom.us.app" && gone.files == 2)
    let partly = try #require(Receipts.receipt(id: "z", version: "1", installed: nil, root: "/Applications", files: files) {
        $0.hasSuffix("Info.plist")
    })
    #expect(partly.state == .partly)
    let node = try #require(Receipts.receipt(id: "n", version: "1", installed: nil, root: "/",
                                             files: ["usr/local/bin/node", "usr/local/include/node/v8.h"]) { _ in true })
    #expect(node.state == .installed && node.anchor == "/usr/local")
    #expect(Receipts.anchor(["/Library/Java/JavaVirtualMachines/jdk-21.jdk/Contents/Home/bin/java",
                             "/Library/Java/JavaVirtualMachines/jdk-21.jdk/Contents/Info.plist"]) == "/Library/Java/JavaVirtualMachines/jdk-21.jdk")
    #expect(Receipts.receipt(id: "s", version: "1", installed: nil, root: "/", files: []) == nil)
}
