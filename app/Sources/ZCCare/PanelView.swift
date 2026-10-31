import AppKit
import SwiftUI
import ZCCareCore

/// The panel under the bar. Its home is the Mac's vitals, with nothing above
/// the grade, as CleanMyMac's menu draws it; coverage, updates, the doctor's
/// findings and services are pages the footer's Mac menu opens.
struct PanelView: View {
    @Bindable var store: Store

    var body: some View {
        let home = store.setupProblem == nil && store.snapshot != nil && store.tab == .mac
        VStack(alignment: .leading, spacing: 10) {
            if !home { Header(store: store) }
            if let problem = store.setupProblem {
                SetupCard(problem: problem, setup: store.needsConfig ? store.openSetup : nil, choose: store.chooseConfig)
            } else if let snapshot = store.snapshot {
                if !home { Tabs(store: store, snapshot: snapshot, system: store.system) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(snapshot.errors, id: \.self) { Text($0).font(.caption).foregroundStyle(Theme.bad) }
                        switch store.tab {
                        case .mac: MacTab(store: store, snapshot: snapshot)
                        case .overview: OverviewTab(store: store, snapshot: snapshot)
                        case .updates: UpdatesTab(store: store, system: store.system, items: snapshot.outdated, unknown: snapshot.updatesUnknown)
                        case .health: HealthTab(store: store)
                        case .services: ServicesTab(store: store, services: snapshot.services, unknown: snapshot.servicesUnknown)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // The home has the header's and the tabs' room too.
                .frame(height: home ? 540 : 440)
            } else {
                ProgressView("Reading this Mac…").frame(maxWidth: .infinity, minHeight: 200)
            }
            StatusLine(store: store)
            Rectangle().fill(Theme.rim).frame(height: 1).padding(.horizontal, -14)
            Footer(store: store, home: home)
        }
        .padding(14)
        .frame(width: 430)
        .themed()
        .onAppear { store.refreshIfStale() }
        // Not .task: closing the panel would cancel a check that takes up to 40 s.
        .onAppear { Task { await store.system.refreshIfStale() } }
    }
}

// MARK: Frame

private struct Header: View {
    let store: Store

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("ZC Care").font(.headline)
                    Image(systemName: icon).font(.caption).foregroundStyle(tint)
                }
                Text(store.statusSummary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Smart Care") { store.openCare?(nil) }
                .controlSize(.small)
                .disabled(store.setupProblem != nil)
                .help("Open ZC Care's Smart Care")
            RefreshButton(store: store)
        }
    }

    private var icon: String {
        if store.setupProblem != nil { return "exclamationmark.circle.fill" }
        return store.attention == 0 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
    }

    private var tint: Color {
        if store.setupProblem != nil { return .secondary }
        return store.attention == 0 ? Theme.good : Theme.warning
    }

}

private struct RefreshButton: View {
    let store: Store

    var body: some View {
        Button {
            Task { await store.refresh() }
        } label: {
            Image(systemName: "arrow.clockwise").accessibilityLabel("Refresh")
        }
        .buttonStyle(.icon)
        .keyboardShortcut("r")
        .disabled(store.setupProblem != nil || store.refreshing)
        .spinning(store.refreshing)
        .help("Read this Mac again (⌘R). " + store.statusSummary)
    }
}

extension Store {
    /// How the workstation stands and when it was read, as the header says it.
    var statusSummary: String {
        if refreshing { return "Reading…" }
        guard let at = refreshedAt else { return "" }
        let n = attention
        let state = n == 0 ? "Everything in place" : "\(n) need\(n == 1 ? "s" : "") attention"
        var line = state + " · " + at.formatted(.relative(presentation: .named))
        // The daily check, which ran even while this panel was closed.
        if let d = snapshot?.drift, d.error == nil, d.changes > 0 {
            line += " · drift \(d.changes) since " + d.at.formatted(date: .omitted, time: .shortened)
        }
        return line
    }
}

/// The tab bar; each tab's count is what it holds that needs doing.
private struct Tabs: View {
    @Bindable var store: Store
    let snapshot: Snapshot
    let system: SystemUpdates

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Store.Tab.allCases, id: \.self) { tab in
                Button { store.tab = tab } label: {
                    HStack(spacing: 4) {
                        Text(tab.rawValue)
                        if let n = count(tab), n > 0 {
                            Text("\(n)")
                                .font(.caption2.monospacedDigit().weight(.bold))
                                .foregroundStyle(Theme.warning)
                        }
                    }
                    .font(.callout.weight(store.tab == tab ? .semibold : .regular))
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(store.tab == tab ? Color.white : Color.white.opacity(0.65))
                    .background(RoundedRectangle(cornerRadius: 7).fill(store.tab == tab ? Theme.selected : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .modifier(Card())
    }

    private func count(_ tab: Store.Tab) -> Int? {
        store.pending(tab, snapshot: snapshot)
    }
}

extension Store {
    /// What a page holds that needs doing.
    func pending(_ tab: Tab, snapshot: Snapshot) -> Int {
        switch tab {
        case .mac: monitor.vitals.concerns(insecure: 0).count
        case .overview: snapshot.targets.map(\.gaps).reduce(0, +)
        case .updates: snapshot.outdated.count + system.updates.count
        case .health: findings.count
        case .services: snapshot.services.filter { !$0.isRunning }.count
        }
    }
}

private struct SetupCard: View {
    let problem: String
    let setup: (() -> Void)?
    let choose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(problem).font(.callout)
            HStack {
                if let setup { Button("Set Up This Mac…", action: setup).keyboardShortcut(.defaultAction) }
                Button("Choose Config…", action: choose)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(Card())
    }
}

struct SectionTitle: View {
    let title: String
    var count: Int?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(.headline)
            if let count { Text("\(count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary) }
        }
        .padding(.leading, 2)
    }
}

struct EmptyNote: View {
    let text: String
    var symbol = "checkmark.circle"

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 80)
    }
}

/// A row that lights up under the mouse, like a menu item.
struct Hover: ViewModifier {
    @State private var over = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(over ? Color.white.opacity(0.07) : .clear))
            .onHover { over = $0 }
    }
}

// MARK: Overview

private struct OverviewTab: View {
    let store: Store
    let snapshot: Snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !snapshot.targets.isEmpty {
                SectionTitle(title: "Targets")
                ListCard {
                    ForEach(snapshot.targets) { t in
                        TargetBlock(store: store, target: t)
                    }
                }
            } else if snapshot.errors.isEmpty {
                EmptyNote(text: "This config declares no targets.", symbol: "square.dashed")
            }
        }
        if !store.jobs.isEmpty {
            UpkeepSection(store: store)
        }
        if let plan = store.plan {
            PlanSection(plan: plan) { store.plan = nil }
        }
    }
}

/// A target's coverage bar; a click opens what is not in place.
private struct TargetBlock: View {
    let store: Store
    let target: TargetStatus

    private var open: Bool { store.expanded == target.target }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { store.toggle(target.target) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Text(target.target).frame(width: 74, alignment: .leading).lineLimit(1)
                    Meter(value: target.fraction, tint: tint)
                    Text(count).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .trailing)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(Hover())
            .help(target.error ?? target.summary)
            if open {
                TargetDetail(store: store, target: target)
                    .padding(.leading, 22)
            }
        }
    }

    private var count: String {
        target.error != nil ? "error" : "\(target.inPlace)/\(target.declared)"
    }

    private var tint: Color {
        if target.error != nil { return Theme.bad }
        return target.gaps == 0 ? Theme.good : Theme.warning
    }
}

private struct TargetDetail: View {
    let store: Store
    let target: TargetStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = target.error {
                Text(error).font(.caption).foregroundStyle(Theme.bad)
            } else if let items = store.targetItems[target.target] {
                if items.isEmpty {
                    Text("Everything in place.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(items) { item in ItemRow(store: store, item: item) }
            } else if let failure = store.targetErrors[target.target] {
                HStack {
                    Text("Could not load: \(failure)").font(.caption).foregroundStyle(Theme.bad).lineLimit(2)
                    Spacer()
                    Button("Retry") { Task { await store.loadItems(target.target) } }
                        .controlSize(.small)
                }
            } else {
                ProgressView().controlSize(.small)
            }
            HStack {
                if target.gaps > 0 {
                    Button("Apply \(target.target)…") { Task { await store.fixTarget(target.target) } }
                        .controlSize(.small)
                        .disabled(store.busy != nil)
                }
                Spacer()
                Button("All Items") { store.openCare?(.workstation) }
                    .buttonStyle(.zcLink).font(.caption)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ItemRow: View {
    let store: Store
    let item: Item

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(item.state)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(color))
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.callout).lineLimit(1).truncationMode(.middle)
                if let note = item.why ?? item.desc {
                    Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            if item.isFixable {
                Button("Fix") { Task { await store.fix(item) } }
                    .controlSize(.small)
                    .disabled(store.busy != nil)
            }
        }
        .help(item.state == "manual" ? "zc-care cannot do this one; do it by hand." : item.name)
    }

    private var color: Color {
        switch item.state {
        case "missing": Theme.warning.opacity(0.85)
        case "differs": Color(red: 0.85, green: 0.7, blue: 0.2)
        default: .white.opacity(0.25)
        }
    }
}

/// Scheduled agents such as the weekly upkeep: when they last ran, how it
/// went, and when they run next.
private struct UpkeepSection: View {
    let store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(title: "Upkeep")
            ListCard {
                ForEach(store.jobs) { job in JobRow(store: store, job: job) }
            }
        }
    }
}

private struct JobRow: View {
    let store: Store
    let job: Job

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            SymbolTile(symbol: symbol, colors: colors)
            VStack(alignment: .leading, spacing: 1) {
                Text(job.label.replacingOccurrences(of: "local.", with: "")).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if let log = job.log {
                Button("Log") { NSWorkspace.shared.open(log) }.buttonStyle(.zcLink).font(.caption)
            }
            Button("Run Now") { Task { await store.run(job) } }
                .controlSize(.small)
                .disabled(store.busy != nil || job.running)
        }
        .modifier(Hover())
    }

    private var symbol: String {
        if job.running { return "arrow.triangle.2.circlepath" }
        return job.failed ? "xmark.circle.fill" : "clock"
    }

    private var colors: [Color] { job.failed ? Tint.red : job.running ? Tint.blue : Tint.violet }

    private var detail: String {
        var parts: [String] = []
        if job.running {
            parts.append("Running now")
        } else if let last = job.lastRun {
            parts.append((job.failed ? "Failed " : "Ran ") + last.formatted(.relative(presentation: .named)))
        } else {
            parts.append("Not run yet")
        }
        if let next = job.next(after: .now) {
            parts.append("next " + next.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
        }
        return parts.joined(separator: " · ")
    }
}

private struct PlanSection: View {
    let plan: PlanDoc
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionTitle(title: "Plan", count: plan.actions.count)
                Spacer()
                Button("Close", action: close).buttonStyle(.zcLink).font(.caption)
            }
            ListCard {
            if plan.actions.isEmpty {
                Text("Nothing to change.").foregroundStyle(.secondary).modifier(Hover())
            }
            ForEach(plan.actions) { a in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(a.op).font(.caption.monospaced().weight(.semibold)).foregroundStyle(color(a.op))
                        .frame(width: 52, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(a.resource).lineLimit(1)
                        if let d = a.detail, !d.isEmpty {
                            Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .modifier(Hover())
            }
            }
        }
    }

    private func color(_ op: String) -> Color {
        switch op {
        case "DELETE": Theme.bad
        case "UPDATE": Theme.warning
        case "MANUAL": .secondary
        default: Theme.good
        }
    }
}

// MARK: Updates

/// What `softwareupdate -l` found, kept for six hours: it asks Apple's
/// servers and takes up to 40 seconds.
@MainActor @Observable
final class SystemUpdates {
    private(set) var updates: [MacUpdate] = []
    private(set) var checking = false
    private(set) var failure: String?
    /// When the last check answered; a failed check leaves it, so the next open tries again.
    private(set) var checkedAt: Date?
    /// When the last check began. Offline, softwareupdate takes up to 40 s
    /// to fail, so opening the panel again soon after does not ask again.
    private var triedAt: Date?

    func refreshIfStale() async {
        if let checkedAt, Date.now.timeIntervalSince(checkedAt) < 6 * 3600 { return }
        if let triedAt, Date.now.timeIntervalSince(triedAt) < 15 * 60 { return }
        await check()
    }

    func check() async {
        guard !checking else { return }
        checking = true
        triedAt = .now
        defer { checking = false }
        do {
            updates = try await MacUpdate.list()
            failure = nil
            checkedAt = .now
        } catch {
            failure = error.localizedDescription
        }
    }
}

private struct UpdatesTab: View {
    let store: Store
    let system: SystemUpdates
    let items: [Item]
    let unknown: Bool
    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MacUpdatesSection(system: system)
            if !items.isEmpty {
                cliUpdates
            } else if unknown {
                EmptyNote(text: "Packages could not be read.", symbol: "questionmark.circle")
            } else {
                EmptyNote(text: "Packages and runtimes are up to date.")
            }
        }
    }

    /// "Update All…" applies these items only; macOS updates need Software Update.
    private var cliUpdates: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if items.count > 6 {
                    TextField("Filter", text: $filter)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                } else {
                    Spacer()
                }
                Button("Update All…") { Task { await store.updateAll() } }
                    .controlSize(.small)
                    .disabled(store.busy != nil)
            }
            ForEach(groups, id: \.0) { title, group in
                VStack(alignment: .leading, spacing: 4) {
                    SectionTitle(title: title, count: group.count)
                    ListCard {
                        ForEach(group) { item in UpdateRow(store: store, item: item) }
                    }
                }
            }
        }
    }

    /// Formulae, apps and runtimes apart: apps may ask for a password.
    private var groups: [(String, [Item])] {
        let shown = filter.isEmpty ? items : items.filter { $0.name.localizedCaseInsensitiveContains(filter) }
        let titles = ["brew": "Formulae", "cask": "Apps", "mas": "App Store", "runtime": "Runtimes"]
        let rank = ["brew", "cask", "mas", "runtime"]
        let kinds = Set(shown.map(\.kind)).sorted {
            (rank.firstIndex(of: $0) ?? rank.count, $0) < (rank.firstIndex(of: $1) ?? rank.count, $1)
        }
        return kinds.map { kind in (titles[kind] ?? kind.capitalized, shown.filter { $0.kind == kind }) }
    }
}

/// macOS updates are installed in Software Update, which needs a password
/// and a restart: the button opens it.
private struct MacUpdatesSection: View {
    let system: SystemUpdates
    private static let softwareUpdate = URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")!

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SectionTitle(title: "macOS", count: system.updates.isEmpty ? nil : system.updates.count)
                Spacer()
                if system.checking {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Check Again") { Task { await system.check() } }
                        .buttonStyle(.zcLink).font(.caption)
                }
                if !system.updates.isEmpty {
                    Button("Open Software Update") { NSWorkspace.shared.open(Self.softwareUpdate) }
                        .controlSize(.small)
                }
            }
            if let failure = system.failure {
                Text("Could not check for macOS updates: \(failure)")
                    .font(.caption).foregroundStyle(Theme.bad).lineLimit(1).help(failure)
            } else if system.updates.isEmpty, !system.checking, let checkedAt = system.checkedAt {
                Text("Up to date, checked \(checkedAt.formatted(date: .omitted, time: .shortened)).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !system.updates.isEmpty {
                ListCard {
                    ForEach(system.updates) { update in MacUpdateRow(update: update) }
                }
            }
        }
    }
}

private struct MacUpdateRow: View {
    let update: MacUpdate

    var body: some View {
        HStack(spacing: 10) {
            SymbolTile(symbol: "arrow.down.circle.fill", colors: Tint.blue)
            VStack(alignment: .leading, spacing: 1) {
                Text(update.title).lineLimit(1)
                Text(detail).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let flag {
                Text(flag)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(update.restart ? Theme.warning.opacity(0.85) : .white.opacity(0.25)))
                    .foregroundStyle(.white)
            }
        }
        .modifier(Hover())
        .help(update.label)
    }

    private var detail: String {
        let size = update.sizeKiB.map { ByteCountFormatter.string(fromByteCount: Int64($0) * 1024, countStyle: .file) }
        return [update.version, size].compactMap { $0 }.joined(separator: " · ")
    }

    private var flag: String? {
        if update.restart { return "Restart" }
        return update.recommended ? "Recommended" : nil
    }
}

private struct UpdateRow: View {
    let store: Store
    let item: Item

    var body: some View {
        HStack(spacing: 10) {
            AppIcon(item: item)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.app ?? item.name).lineLimit(1)
                Text("\(short(item.version)) → \(short(item.latest))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Update") { Task { await store.update(item) } }
                .controlSize(.small)
                .disabled(store.busy != nil)
        }
        .modifier(Hover())
        .help(item.why ?? item.name)
    }

    /// A cask version carries a build id after a comma, too long for a row.
    private func short(_ v: String?) -> String {
        String((v ?? "?").split(separator: ",").first ?? "?")
    }
}

/// The app an update is for, by its own icon when it is installed.
private struct AppIcon: View {
    let item: Item

    var body: some View {
        if let icon = Self.icon(item) {
            Image(nsImage: icon).resizable().frame(width: 28, height: 28)
        } else {
            SymbolTile(symbol: item.kind == "runtime" ? "chevron.left.forwardslash.chevron.right" : "shippingbox.fill",
                       colors: item.kind == "runtime" ? Tint.violet : Tint.orange)
        }
    }

    /// Looked up once per app: NSWorkspace reads the icon from disk.
    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor private static func icon(_ item: Item) -> NSImage? {
        guard let app = item.app else { return nil }
        if let hit = cache[app] { return hit }
        let path = "/Applications/\(app).app"
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: path)
        cache[app] = icon
        return icon
    }
}

// MARK: Health

private struct HealthTab: View {
    let store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionTitle(title: "Findings", count: store.findings.count)
                Spacer()
                if !store.ignoredFindings.isEmpty {
                    Button("Stop ignoring " + Store.counted(store.ignoredFindings.count, "check")) { store.unignoreAll() }
                        .buttonStyle(.zcLink).font(.caption)
                }
            }
            if store.findings.isEmpty {
                EmptyNote(text: "Every check passes.", symbol: "checkmark.shield")
            }
            if !store.findings.isEmpty {
                ListCard {
                    ForEach(store.findings) { check in FindingRow(store: store, check: check) }
                }
            }
        }
    }
}

private struct FindingRow: View {
    let store: Store
    let check: Check

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            SymbolTile(symbol: symbol, colors: check.status == "fail" ? Tint.red : Tint.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title).lineLimit(1)
                if let detail = check.detail {
                    // A command shows on one line; the tooltip holds all of it.
                    if case .command = Fix(for: check) {
                        Text(detail).font(.caption2.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                            .help(detail)
                    } else {
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            Spacer()
            Button(fixTitle) { Task { await store.fix(check) } }
                .controlSize(.small)
                .disabled(store.busy != nil)
        }
        .modifier(Hover())
        .contextMenu {
            Button("Ignore") { store.ignore(check) }
            if let detail = check.detail {
                Button("Copy Fix") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(detail, forType: .string)
                }
            }
        }
    }

    private var symbol: String {
        let title = check.title.lowercased()
        if title.contains("firewall") { return "flame.fill" }
        if title.contains("password") || title.contains("touch id") { return "lock.fill" }
        if title.contains("network") || title.contains("server") { return "network" }
        return check.status == "fail" ? "xmark" : "exclamationmark"
    }

    private var fixTitle: String {
        switch Fix(for: check) {
        case .command: "Fix…"
        case .settings: "Open"
        case .info: "Details"
        }
    }
}

// MARK: Services

private struct ServicesTab: View {
    let store: Store
    let services: [Item]
    let unknown: Bool

    var body: some View {
        if services.isEmpty {
            EmptyNote(text: unknown ? "Services could not be read." : "No services target in this config.",
                      symbol: unknown ? "questionmark.circle" : "gearshape.2")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                SectionTitle(title: "Services", count: services.count)
                ListCard {
                    ForEach(services) { s in ServiceRow(store: store, item: s) }
                }
            }
            if !store.jobs.isEmpty {
                UpkeepSection(store: store)
            }
        }
    }
}

private struct ServiceRow: View {
    let store: Store
    let item: Item

    var body: some View {
        HStack(spacing: 10) {
            SymbolTile(symbol: item.kind == "agent" ? "clock.arrow.circlepath" : "gearshape.2.fill",
                       colors: item.isRunning ? Tint.green : Tint.red)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).lineLimit(1)
                Text("\(item.kind == "agent" ? "launch agent" : "brew service") · \(item.desc ?? item.state)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if item.isRunning {
                Button(restart) { Task { await store.service(item, .restart) } }
                    .controlSize(.small)
            } else {
                Button("Start") { Task { await store.service(item, .start) } }
                    .controlSize(.small)
            }
            Menu {
                if item.kind == "agent" {
                    Button("Run Now") { Task { await store.service(item, .run) } }
                }
                Button(restart) { Task { await store.service(item, .restart) } }
                Button(item.kind == "agent" ? "Unload" : "Stop") { Task { await store.service(item, .stop) } }
            } label: {
                Image(systemName: "ellipsis").accessibilityLabel("Actions")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(item.kind == "agent" ? "Run Now, Reload or Unload" : "Restart or Stop")
        }
        .disabled(store.busy != nil)
        .modifier(Hover())
    }

    /// An agent reloads rather than restarts: kickstart -k would run a
    /// calendar job such as the weekly upkeep.
    private var restart: String { item.kind == "agent" ? "Reload" : "Restart" }
}

// MARK: Bottom

private struct StatusLine: View {
    let store: Store

    var body: some View {
        if store.busy != nil || store.message != nil {
            let failed = store.message?.failed ?? false
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(failed ? Theme.bad : Theme.good)
                    .spinning(store.busy != nil)
                Text(store.busy.map { $0 + "…" } ?? store.message?.text ?? "").font(.caption).lineLimit(3)
                Spacer()
                if let cancel = store.cancelBusy {
                    Button("Cancel", action: cancel).buttonStyle(.zcLink).font(.caption)
                }
                if store.busy == nil, let m = store.message {
                    if let log = m.log {
                        Button("Log") { NSWorkspace.shared.open(log) }.buttonStyle(.zcLink).font(.caption)
                    }
                    Button { store.message = nil } label: { Image(systemName: "xmark").accessibilityLabel("Dismiss") }
                        .buttonStyle(.borderless).font(.caption)
                }
            }
        }
    }
}

private struct Footer: View {
    @Bindable var store: Store
    /// The home has no header, so its refresh lives here.
    let home: Bool

    var body: some View {
        ZStack {
            Button("Open ZC Care") { store.openCare?(nil) }
                .buttonStyle(.plain)
                .font(.callout.weight(.medium))
                .disabled(store.busy != nil || store.setupProblem != nil)
            HStack(spacing: 6) {
                pages
                if home { RefreshButton(store: store) }
                Spacer()
                Button { store.openCare?(.smartCare) } label: {
                    Image(systemName: "sparkles").accessibilityLabel("Smart Care")
                }
                .buttonStyle(.icon)
                .disabled(store.setupProblem != nil)
                .help("Open Smart Care")
                settings
            }
        }
    }

    /// The pages beyond the Mac, with plan and apply; a dot says one needs doing.
    private var pages: some View {
        let snapshot = store.snapshot
        let waiting = snapshot.map { s in Store.Tab.allCases.contains { $0 != .mac && store.pending($0, snapshot: s) > 0 } } ?? false
        return IconTile {
            Menu {
                ForEach(Store.Tab.allCases, id: \.self) { tab in
                    let n = snapshot.map { store.pending(tab, snapshot: $0) } ?? 0
                    Button(tab == .mac ? "This Mac" : n > 0 && tab != .mac ? "\(tab.rawValue) (\(n))" : tab.rawValue) { store.tab = tab }
                        .disabled(snapshot == nil)
                }
                Divider()
                Group {
                    Button("Plan") {
                        store.tab = .overview
                        Task { await store.showPlan() }
                    }
                    Button("Apply…") { Task { await store.apply() } }
                }
                .disabled(store.busy != nil)
            } label: {
                Image(systemName: "laptopcomputer").accessibilityLabel(waiting ? "Pages, something needs doing" : "Pages")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(store.setupProblem != nil)
        }
        .overlay(alignment: .topTrailing) {
            if waiting { Circle().fill(Theme.warning).frame(width: 7, height: 7).offset(x: 2, y: -2) }
        }
        .help("Coverage, updates, health and services; plan and apply")
    }

    private var settings: some View {
        IconTile {
            Menu {
                Button("Settings…") { store.openSettings?() }.keyboardShortcut(",")
                Divider()
                Button("Quit ZC Care") { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: {
                Image(systemName: "gearshape").accessibilityLabel("Settings")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .help("Settings")
    }
}
