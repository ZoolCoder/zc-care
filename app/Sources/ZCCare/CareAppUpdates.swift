import AppKit
import SwiftUI
import ZCCareCore

extension Care {
    /// Reads the update feed of every app that names one, and asks zc-care
    /// again for Homebrew and App Store updates. App Store and Homebrew
    /// apps are left to `mas` and `brew`. Only on the owner's word: each
    /// feed server learns this Mac has its app.
    func checkUpdates() async {
        guard !checkingUpdates else { return }
        checkingUpdates = true
        defer { checkingUpdates = false }
        // A load already running would leave apps empty and the check blank.
        while loadingApps {
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
        }
        if apps.isEmpty { await loadApps() }
        async let refresh: Void = store.refresh()
        let urls = apps.filter { $0.source != .appStore }.map(\.url)
        let feedApps = await Task.detached { AppUpdates.feedApps(urls) }.value
        let result = await AppUpdates.check(feedApps)
        await refresh
        guard let result else { return }
        feedUpdates = result.updates
        // Dropped for good: once Homebrew updates such an app it leaves
        // `outdated`, and its row would come back with an old version.
        feedUpdates = shownFeedUpdates
        feedFailures = result.unreachable
        feedUnreadable = result.unreadable
        updatesCheckedAt = .now
    }

    /// Outdated apps zc-care can update itself: casks and App Store apps.
    var outdatedApps: [Item] {
        (store.snapshot?.outdated ?? []).filter { $0.kind == "cask" || $0.kind == "mas" }
    }

    /// Feed updates that Homebrew does not already offer.
    var shownFeedUpdates: [AppUpdate] {
        let casks = outdatedApps.filter { $0.kind == "cask" }
        let byPath = Dictionary(apps.map { ($0.url.path, $0) }, uniquingKeysWith: { a, _ in a })
        return (feedUpdates ?? []).filter { update in
            var token: String?
            if case .cask(let cask)? = byPath[update.app.url.path]?.source { token = cask }
            return !casks.contains { AppUpdates.sameApp($0, token: token, name: update.app.name) }
        }
    }

    /// Everything waiting: formulae and runtimes have no row in the list. A
    /// release for another macOS is listed but not counted.
    var allUpdates: Int { shownFeedUpdates.filter(\.supported).count + (store.snapshot?.outdated.count ?? 0) }
}

/// Apps with a newer version: from each app's own feed, the App Store and
/// Homebrew. A feed app updates itself once opened; zc-care updates the rest.
struct UpdateList: View {
    @Bindable var care: Care
    let query: String
    @State private var notes: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                summary
                CareSection("Updates") {
                    if feed.isEmpty && packages.isEmpty {
                        Text(emptyText).foregroundStyle(.secondary).padding(10)
                    }
                    ForEach(feed) { update in feedRow(update) }
                    ForEach(packages) { item in packageRow(item) }
                }
                if !care.feedFailures.isEmpty {
                    note("Feed not reachable: " + care.feedFailures.joined(separator: ", "))
                }
                if !care.feedUnreadable.isEmpty {
                    note("Feed not readable: " + care.feedUnreadable.joined(separator: ", "))
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
        }
    }

    private var summary: some View {
        HStack(spacing: 14) {
            SymbolTile(symbol: "arrow.triangle.2.circlepath", colors: care.allUpdates > 0 ? Tint.orange : Tint.green, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Group {
                    if let at = care.updatesCheckedAt {
                        Text("Checked ") + Text(at, style: .relative) + Text(" ago. From each app's own feed, the App Store and Homebrew.")
                    } else {
                        Text("Checking asks each app's own update server, the App Store and Homebrew.")
                    }
                }
                .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if care.checkingUpdates { ProgressView().controlSize(.small) }
            if outdated > 0 {
                Button("Update \(Store.counted(outdated, "Package"))") { Task { await care.store.updateAll() } }
                    .disabled(care.store.busy != nil)
            }
            // Not tied to this view: leaving the list must not cancel the check.
            Button(care.updatesCheckedAt == nil ? "Check Now" : "Check Again") { Task { await care.checkUpdates() } }
                .disabled(care.checkingUpdates)
        }
        .padding(16)
        .modifier(Card())
    }

    private var outdated: Int { care.store.snapshot?.outdated.count ?? 0 }
    private var unknown: Bool { care.store.snapshot?.updatesUnknown == true }

    private var title: String {
        if care.checkingUpdates { return "Checking for updates…" }
        if care.updatesCheckedAt == nil {
            return outdated == 0 ? "Apps not checked yet" : "\(Store.counted(outdated, "update")) found, app feeds not checked yet"
        }
        if care.allUpdates > 0 { return "\(Store.counted(care.allUpdates, "update")) available" }
        return unknown ? "Packages could not be read" : "Everything is up to date"
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyText: String {
        if care.checkingUpdates { return "Reading update feeds…" }
        if !query.isEmpty { return "No update matches \u{201C}\(query)\u{201D}." }
        if care.allUpdates > 0 { return "These are packages, not apps: the Update button installs them." }
        if care.updatesCheckedAt == nil { return "Check Now reads each app's own update feed." }
        return unknown ? "No app update waiting. Packages could not be read." : "No update waiting."
    }

    private var term: String { query.trimmingCharacters(in: .whitespaces) }

    private var feed: [AppUpdate] {
        care.shownFeedUpdates.filter { term.isEmpty || $0.app.name.localizedCaseInsensitiveContains(term) }
    }

    private var packages: [Item] {
        care.outdatedApps.filter { term.isEmpty || $0.name.localizedCaseInsensitiveContains(term) || ($0.app ?? "").localizedCaseInsensitiveContains(term) }
    }

    private func feedRow(_ update: AppUpdate) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            CareRow(icon: icon(update.app.url), title: update.app.name,
                    detail: detail(update.app.version, update.available, date: update.release.date, source: "App feed"),
                    value: update.release.size.map { Store.bytes($0) } ?? "", flag: update.supported ? nil : need(update)) {
                if hasNotes(update) {
                    Button { notes = notes == update.id ? nil : update.id } label: {
                        Image(systemName: notes == update.id ? "chevron.up" : "chevron.down").accessibilityLabel("What's new")
                    }
                    .controlSize(.small)
                    .help("What's new")
                }
                Button("Open to Update") { NSWorkspace.shared.openApplication(at: update.app.url, configuration: .init()) }
                    .controlSize(.small)
                    .disabled(!update.supported)
                    .help(update.supported ? "Open \(update.app.name); it offers the update itself" : "This release does not run on this Mac's macOS")
            }
            if notes == update.id { whatsNew(update) }
        }
    }

    @ViewBuilder private func whatsNew(_ update: AppUpdate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let text = update.release.notes {
                Text(text).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let link = update.release.notesLink {
                Link("Release notes", destination: link).font(.callout)
            }
        }
        .padding(.leading, 56)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Why a release cannot install here, in a few words.
    private func need(_ update: AppUpdate) -> String {
        let os = AppUpdates.systemString(ProcessInfo.processInfo.operatingSystemVersion)
        if let minimum = update.release.minimumSystem, AppUpdates.compare(os, minimum) == .orderedAscending {
            return "Needs macOS \(minimum)"
        }
        return update.release.maximumSystem.map { "Only up to macOS \($0)" } ?? "Not for this macOS"
    }

    private func hasNotes(_ update: AppUpdate) -> Bool {
        update.release.notesLink != nil || !(update.release.notes ?? "").isEmpty
    }

    private func packageRow(_ item: Item) -> some View {
        // By the cask token first: a cask's display name often differs from
        // its app's, and the app found here is the one offered to quit.
        let app = care.apps.first { if case .cask(let token) = $0.source { item.kind == "cask" && token == item.name } else { false } }
            ?? care.apps.first { item.app != nil && $0.url.lastPathComponent == item.app }
            ?? care.apps.first { $0.name.caseInsensitiveCompare(item.app ?? item.name) == .orderedSame && (item.kind != "mas" || $0.source == .appStore) }
        return CareRow(icon: app.map { icon($0.url) } ?? AnyView(SymbolTile(symbol: "shippingbox.fill", colors: Tint.orange, size: 32)),
                       title: app?.name ?? item.name,
                       detail: detail(item.version ?? "?", item.latest ?? "?", date: nil,
                                      source: item.kind == "mas" ? "App Store" : "Homebrew cask \(item.name)"),
                       value: "", flag: nil) {
            Button("Update") { Task { await care.update(item, app: app) } }
                .controlSize(.small)
                .gatedOnBusy(care.store)
        }
    }

    private func detail(_ from: String, _ to: String, date: Date?, source: String) -> String {
        var parts = ["\(from) to \(to)", source]
        if let date { parts.append(date.formatted(date: .abbreviated, time: .omitted)) }
        return parts.joined(separator: " · ")
    }

    private func icon(_ url: URL) -> AnyView {
        if let image = care.icons[url.path] {
            return AnyView(Image(nsImage: image).resizable().frame(width: 34, height: 34))
        }
        return AnyView(Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 34, height: 34))
    }
}
