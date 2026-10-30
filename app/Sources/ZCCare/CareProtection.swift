import AppKit
import SwiftUI
import ZCCareCore

// MARK: Protection

struct ProtectionView: View {
    @Bindable var care: Care

    var body: some View {
        VStack(spacing: 0) {
            CareHeader(title: "Protection", subtitle: subtitle, busy: care.loadingProtection,
                   action: ("Rescan", { Task { care.assessments = [:]; await care.loadProtection() } }))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SecuritySummary(care: care)
                    CareSection("Security Settings") {
                        CareRow(icon: SymbolTile(symbol: "checkmark.shield.fill", colors: care.gatekeeper == false ? Tint.red : care.gatekeeper == nil ? Tint.gray : Tint.green, size: 32),
                            title: "Gatekeeper",
                            detail: "Only apps from identified developers open without a warning.",
                            value: state(care.gatekeeper)) { EmptyView() }
                        ForEach(care.securityChecks) { check in
                            CareRow(icon: SymbolTile(symbol: check.on == false ? "exclamationmark.shield.fill" : "checkmark.shield.fill",
                                                 colors: check.on == false ? Tint.red : check.on == nil ? Tint.gray : Tint.green, size: 32),
                                title: check.name, detail: check.detail, value: state(check.on)) {
                                if check.on == false, let pane = check.pane {
                                    Button("Turn On…") { care.openSettings(pane) }
                                        .controlSize(.small)
                                        .help("Open the System Settings pane that turns on \(check.name)")
                                }
                            }
                        }
                        ForEach(care.untrusted) { app in
                            CareRow(icon: icon(app), title: app.name,
                                detail: care.assessments[app.id]?.source ?? "No signature Gatekeeper accepts",
                                value: care.assessments[app.id]?.accepted == true ? "Not notarized" : "Rejected",
                                flag: "Unverified") {
                                Button { NSWorkspace.shared.activateFileViewerSelecting([app.url]) } label: {
                                    Image(systemName: "magnifyingglass").accessibilityLabel("Show in Finder")
                                }
                                .controlSize(.small)
                                .help("Show in Finder")
                            }
                        }
                    }
                    CareSection("Login Items & Background Tasks") {
                        ForEach(care.backgroundItems) { item in
                            CareRow(icon: SymbolTile(symbol: item.kind == "login item" ? "person.crop.circle.fill" : "gearshape.2.fill",
                                                 colors: item.enabled ? Tint.orange : Tint.gray, size: 32),
                                title: item.name,
                                detail: [item.developer ?? "Unidentified developer", item.kind, item.executable]
                                    .compactMap { $0 }.joined(separator: " · "),
                                value: item.enabled ? "Allowed" : "Off",
                                flag: care.isNew(background: item) ? appearedFlag : item.developer == nil && item.enabled ? "Unidentified" : nil,
                                flagColor: care.isNew(background: item) ? Theme.accent : Theme.warning) { EmptyView() }
                        }
                        HStack {
                            Text(care.backgroundItems.isEmpty
                                 ? "macOS's list asks for your password to read. Switch items in System Settings."
                                 : "Switch these in System Settings; launch agents also in Performance.")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if care.loadingBackground { ProgressView().controlSize(.small) }
                            Button(care.backgroundItems.isEmpty ? "Read List…" : "Read Again…") {
                                Task { await care.loadBackgroundItems() }
                            }
                            .controlSize(.small)
                            .disabled(care.loadingBackground)
                            Button("Open Login Items") { care.openSettings("com.apple.LoginItems-Settings.extension") }
                                .controlSize(.small)
                        }
                        .padding(10)
                    }
                    ExtensionsSection()
                    CareSection("Browser Privacy") {
                        if let traces = care.browserTraces {
                            if traces.isEmpty {
                                Text("No browser keeps history, cookies or caches ZC Care can read.").foregroundStyle(.secondary).padding(10)
                            }
                            ForEach(traces) { trace in
                                let open = care.isRunning(trace.bundleID)
                                CareRow(icon: SymbolTile(symbol: symbol(trace.kind), colors: open ? Tint.gray : Tint.violet, size: 32),
                                    title: "\(trace.browser) \(trace.kind)",
                                    detail: open ? "Quit \(trace.browser) to clear it" : Store.counted(trace.paths.count, "item"),
                                    value: Store.bytes(trace.size)) {
                                    Button("Clear") { Task { await care.clearBrowser(trace) } }
                                        .controlSize(.small)
                                        .help(open ? "Quit \(trace.browser) first" : "Clear \(trace.browser) \(trace.kind) (\(removalVerb(care.store)))")
                                        .disabled(open || care.store.busy != nil)
                                }
                            }
                        } else {
                            ProgressView().controlSize(.small).padding(10)
                        }
                        Text("Browsers keep history and cookies from apps without Full Disk Access; ZC Care lists what it can read. A browser clears only while it is closed.")
                            .font(.caption).foregroundStyle(.secondary).padding(10)
                    }
                    RecentItemsSection(care: care)
                    WiFiSection(care: care)
                    CareSection("Privacy Permissions") {
                        if let permissions = care.permissions {
                            if permissions.isEmpty {
                                Text("No app holds a permission.").foregroundStyle(.secondary).padding(10)
                            }
                            ForEach(permissions) { p in
                                CareRow(icon: SymbolTile(symbol: "hand.raised.fill", colors: p.allowed ? Tint.violet : Tint.gray, size: 32),
                                    title: p.client, detail: p.service, value: p.allowed ? "Allowed" : "Denied") {
                                    if p.resetName != nil {
                                        Button("Reset") { Task { await care.resetPermission(p) } }
                                            .controlSize(.small)
                                            .help("macOS asks \(p.client) again next time")
                                            .disabled(care.store.busy != nil)
                                    }
                                }
                            }
                        } else if let error = care.permissionsError {
                            Text("Permissions not read: \(error)").foregroundStyle(.secondary).padding(10)
                        } else {
                            HStack(alignment: .top, spacing: 12) {
                                SymbolTile(symbol: "lock.fill", colors: Tint.gray, size: 32)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("ZC Care needs Full Disk Access to list permissions").font(.body.weight(.medium))
                                    Text("macOS keeps its privacy database from apps without it. ZC Care is signed ad hoc, so each new build asks again.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Open Settings") { care.openSettings("com.apple.preference.security?Privacy_AllFiles") }
                                    .controlSize(.small)
                            }
                            .padding(10)
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 70)
            }
        }
        .task { if care.gatekeeper == nil { await care.loadProtection() } }
    }

    private func symbol(_ kind: String) -> String {
        switch kind {
        case BrowserPrivacy.history: "clock.arrow.circlepath"
        case BrowserPrivacy.cookies: "birthday.cake.fill"
        case BrowserPrivacy.siteData: "tray.full.fill"
        case BrowserPrivacy.sessions: "rectangle.stack.fill"
        default: "internaldrive.fill"
        }
    }

    private var subtitle: String {
        let bad = care.untrusted.count
        if care.loadingProtection { return "Asking Gatekeeper about each app…" }
        return bad > 0 ? Store.counted(bad, "app") + " not verified by Apple" : "Every app is verified by Apple"
    }

    /// On or off in words, never in colour alone.
    private func state(_ on: Bool?) -> String {
        on.map { $0 ? "On" : "Off" } ?? (care.loadingProtection ? "…" : "Unknown")
    }

    @ViewBuilder private func icon(_ app: InstalledApp) -> some View {
        if let image = care.icons[app.id] {
            Image(nsImage: image).resizable().frame(width: 34, height: 34)
        } else {
            SymbolTile(symbol: "app.fill", colors: Tint.gray, size: 32)
        }
    }
}

/// Three numbers over the checks: what needs a look, what passed and when.
private struct SecuritySummary: View {
    @Bindable var care: Care

    var body: some View {
        let settings = [care.gatekeeper] + care.securityChecks.map(\.on)
        let off = settings.filter { $0 == false }.count
        let passed = settings.filter { $0 == true }.count
        let unknown = settings.filter { $0 == nil }.count
        let issues = off + care.untrusted.count
        // Before the first read, and while a rescan reassesses the apps, a count of zero would be a false all-clear.
        let reading = care.protectionCheckedAt == nil || care.loadingProtection
        HStack(spacing: 12) {
            tile("Issues Found", Text(reading ? "…" : issues == 0 ? "None" : "\(issues)"),
                 reading ? .secondary : issues == 0 ? Theme.good : Theme.warning,
                 reading ? "Checking" : issues == 0 && unknown == 0 ? "Nothing needs a look"
                    : [off > 0 ? Store.counted(off, "setting") + " off" : nil,
                       care.untrusted.isEmpty ? nil : Store.counted(care.untrusted.count, "unverified app"),
                       unknown > 0 ? "\(unknown) unknown" : nil]
                    .compactMap { $0 }.joined(separator: ", "))
            tile("Checks Passed", Text(reading ? "…" : "\(passed) of \(settings.count - unknown)"),
                 reading ? .secondary : passed == settings.count - unknown ? Theme.good : Theme.warning,
                 "Security settings that are on")
            tile("Last Checked", care.protectionCheckedAt.map { Text($0, style: .relative) + Text(" ago") } ?? Text("Not yet"),
                 Theme.accent, "Rescan with ⌘R")
        }
    }

    private func tile(_ title: String, _ value: Text, _ tint: Color, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            value.font(.title2.weight(.bold)).foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.7)
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(Card())
    }
}
