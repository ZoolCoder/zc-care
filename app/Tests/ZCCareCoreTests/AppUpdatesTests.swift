import Foundation
import Testing
@testable import ZCCareCore

private let appcast = Data("""
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
<channel>
  <item>
    <title>2.1</title>
    <pubDate>Mon, 05 Oct 2026 10:00:00 +0000</pubDate>
    <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
    <description><![CDATA[<ul><li>Faster &amp; smaller</li></ul>]]></description>
    <enclosure url="https://example.com/a-2.1.zip" sparkle:version="210" sparkle:shortVersionString="2.1" length="1048576"/>
  </item>
  <item>
    <title>2.2 beta</title>
    <sparkle:channel>beta</sparkle:channel>
    <enclosure url="https://example.com/a-2.2b.zip" sparkle:version="220" sparkle:shortVersionString="2.2b1"/>
  </item>
  <item>
    <title>2.0</title>
    <sparkle:version>200</sparkle:version>
    <enclosure url="https://example.com/a-2.0.zip"/>
  </item>
  <item>
    <title>Windows</title>
    <enclosure url="https://example.com/a.exe" sparkle:version="999" sparkle:os="windows"/>
  </item>
</channel>
</rss>
""".utf8)

private let app = FeedApp(name: "A", url: URL(fileURLWithPath: "/Applications/A.app"), version: "2.0", build: "200",
                          feed: URL(string: "https://example.com/appcast.xml")!)

private func os(_ major: Int, _ minor: Int = 0) -> OperatingSystemVersion {
    OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: 0)
}

@Test func appcastSkipsBetaAndOtherOS() throws {
    let releases = try #require(AppUpdates.releases(in: appcast))
    #expect(releases.map(\.version) == ["210", "200"])
    let release = releases[0]
    #expect(release.shortVersion == "2.1" && release.size == 1_048_576 && release.minimumSystem == "14.0" && release.date != nil)
    #expect(release.notes == "• Faster & smaller")
    #expect(AppUpdates.releases(in: Data("not xml <".utf8)) == nil)
    // Well-formed but no appcast: a captive portal or error page.
    #expect(AppUpdates.releases(in: Data("<html><body/></html>".utf8)) == nil)
    #expect(AppUpdates.releases(in: Data("<rss><channel></channel></rss>".utf8)) == [])
}

@Test func appcastReadsTablePlusShape() throws {
    // TablePlus's feed: escaped HTML notes and an unprefixed minimum system.
    let feed = Data(#"""
    <rss sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel><item><enclosure xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" sparkle:version="840" sparkle:shortVersionString="27.2.0" length="159745478" url="https://files.example.com/840/A.dmg"></enclosure><description>&#xA;&lt;h2&gt;Build 840&lt;/h2&gt;&#xA;&lt;ol&gt;&lt;li&gt;New feature and bug fixes&lt;/li&gt;&lt;/ol&gt;</description><title>Build 840</title><pubDate>Wed, 28 Oct 2026 07:43:38 +0000</pubDate><minimumSystemVersion>12.0</minimumSystemVersion></item><title>A</title></channel></rss>
    """#.utf8)
    let release = try #require(AppUpdates.releases(in: feed)?.first)
    #expect(release.version == "840" && release.shortVersion == "27.2.0" && release.minimumSystem == "12.0" && release.date != nil)
    #expect(release.notes == "Build 840\n• New feature and bug fixes")
}

@Test func appcastReadsSparkleDetails() throws {
    // Enclosure beats element, deltas are patches, XHTML notes keep their text.
    let feed = Data("""
    <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
      <sparkle:version>1</sparkle:version>
      <description><p>Fixes <b>crash</b></p></description>
      <sparkle:deltas><enclosure sparkle:version="999" sparkle:deltaFrom="1"/></sparkle:deltas>
      <sparkle:maximumSystemVersion>15.9</sparkle:maximumSystemVersion>
      <enclosure sparkle:version="300" sparkle:shortVersionString="3.0"/>
    </item></channel></rss>
    """.utf8)
    let release = try #require(AppUpdates.releases(in: feed)?.first)
    #expect(release.version == "300" && release.shortVersion == "3.0" && release.maximumSystem == "15.9")
    #expect(release.notes == "Fixes crash")
}

@Test func updatePrefersReleaseThisMacRuns() throws {
    let releases = [FeedRelease(version: "300", minimumSystem: "16.0"), FeedRelease(version: "250", minimumSystem: "14.0"),
                    FeedRelease(version: "150")]
    let update = try #require(AppUpdates.update(for: app, releases: releases, system: os(15, 1)))
    #expect(update.release.version == "250" && update.supported)
    let only = try #require(AppUpdates.update(for: app, releases: [releases[0]], system: os(15)))
    #expect(only.release.version == "300" && !only.supported)
    // Only for an older macOS: never offered, as Sparkle would not.
    #expect(AppUpdates.update(for: app, releases: [FeedRelease(version: "300", maximumSystem: "14.9")], system: os(15)) == nil)
    #expect(AppUpdates.update(for: app, releases: [releases[2]], system: os(15)) == nil)
}

@Test func versionsCompareLikeSparkle() {
    #expect(AppUpdates.compare("1.10", "1.9") == .orderedDescending)
    #expect(AppUpdates.compare("1.2", "1.2.1") == .orderedAscending)
    #expect(AppUpdates.compare("2.0b2", "2.0b10") == .orderedAscending)
    #expect(AppUpdates.compare("1.0", "1.0") == .orderedSame)
    #expect(AppUpdates.compare("14.0", "14") == .orderedDescending)
    #expect(AppUpdates.compare("1.01", "1.1") == .orderedSame)
    #expect(AppUpdates.compare("2.0", "2.0b1") == .orderedDescending)
    #expect(AppUpdates.compare("2.0b1", "2.0") == .orderedAscending)
    #expect(AppUpdates.compare("1.0 (5)", "1.0 (12)") == .orderedAscending)
    #expect(AppUpdates.compare("2.0", "2.0-beta1") == .orderedDescending)
    #expect(AppUpdates.compare("2.0-beta1", "2.0") == .orderedAscending)
    #expect(AppUpdates.compare("2.0-beta2", "2.0-beta10") == .orderedAscending)
    #expect(AppUpdates.compare("99999999999999999999999", "99999999999999999999998") == .orderedDescending)
}

@Test func feedMustBeHTTPSOnAPublicHost() {
    let url = URL(fileURLWithPath: "/Applications/A.app")
    #expect(AppUpdates.feedApp(at: url, info: ["SUFeedURL": "http://example.com/a.xml", "CFBundleVersion": "1"]) == nil)
    #expect(AppUpdates.feedApp(at: url, info: ["SUFeedURL": "https://example.com/a.xml"]) == nil)
    for local in ["https://127.0.0.1/a.xml", "https://192.168.1.1/a.xml", "https://10.0.0.2/a.xml", "https://169.254.169.254/",
                  "https://172.20.0.1/", "https://localhost:8443/a.xml", "https://printer.local/a.xml", "https://[::1]/a.xml"] {
        #expect(AppUpdates.feedApp(at: url, info: ["SUFeedURL": local, "CFBundleVersion": "1"]) == nil, "\(local)")
    }
    #expect(AppUpdates.isPublic(URL(string: "https://172.32.0.1/")!))
    for sneaky in ["https://127.1/", "https://0x7f.1/", "https://2130706433/", "https://0x7f000001/", "https://10.1/",
                   "https://0xa9fea9fe/", "https://0/", "https://[::ffff:127.0.0.1]/", "https://[::ffff:7f00:1]/",
                   "https://[0:0:0:0:0:0:0:1]/", "https://[0::1]/", "https://[64:ff9b::7f00:1]/", "https://[febf::1]/",
                   "https://[fec0::1]/", "https://[fd00::1]/", "https://localhost./", "https://foo.local./"] {
        #expect(!AppUpdates.isPublic(URL(string: sneaky)!), "\(sneaky)")
    }
    #expect(AppUpdates.isPublic(URL(string: "https://[2606:4700::1111]/")!))
    #expect(AppUpdates.isPublic(URL(string: "https://8.8.8.8/")!))
    let found = AppUpdates.feedApp(at: url, info: ["SUFeedURL": " https://example.com/a.xml ", "CFBundleVersion": "7",
                                                   "CFBundleShortVersionString": "1.2", "CFBundleName": "Thing"])
    #expect(found?.name == "Thing" && found?.version == "1.2" && found?.build == "7")
}

@Test func plainTextStaysFastOnHostileNotes() {
    #expect(AppUpdates.plain("<p>One<br/>Two</p><ul><li>Three</li></ul>") == "One\nTwo\n• Three")
    let start = Date.now
    let text = AppUpdates.plain(String(repeating: "<", count: 1_000_000))
    #expect(text.count <= 601 && Date.now.timeIntervalSince(start) < 1)
    #expect(AppUpdates.plain(String(repeating: "<a", count: 500_000)).count <= 601)
    // One Character holding millions of combining marks stays capped.
    #expect(AppUpdates.plain("a" + String(repeating: "\u{301}", count: 1_000_000)).unicodeScalars.count <= 601)
    #expect(AppUpdates.plain("<style>body{color:red}</style><p>Hi</p><script>x()</script>") == "Hi")
    #expect(AppUpdates.plain("x < y fixed<br>next line") == "x < y fixed\nnext line")
    #expect(AppUpdates.plain("Fixed.<br>Press <Cmd-K to open") == "Fixed.\nPress <Cmd-K to open")
    #expect(AppUpdates.plain("It&#8217;s &#x2014; done &mdash; &bogus; &amp;") == "It’s — done — &bogus; &")
}

@Test func checkSeparatesUnreachableAndUnreadable() async throws {
    var broken = app
    broken.name = "B"
    broken.feed = URL(string: "https://example.com/missing.xml")!
    var garbled = app
    garbled.name = "C"
    garbled.feed = URL(string: "https://example.com/garbled.xml")!
    var current = app
    current.name = "D"
    current.build = "210"
    let result = try #require(await AppUpdates.check([app, broken, garbled, current], system: os(15)) { url in
        switch url.path {
        case "/appcast.xml": return appcast
        case "/garbled.xml": return Data("<html".utf8)
        default: throw URLError(.cannotFindHost)
        }
    })
    #expect(result.updates.map(\.app.name) == ["A"])
    #expect(result.unreachable == ["B"] && result.unreadable == ["C"])
}

@Test func cancelledCheckReportsNothing() async {
    let result = await AppUpdates.check([app], system: os(15)) { _ in throw CancellationError() }
    #expect(result == nil)
}
