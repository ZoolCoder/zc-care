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
                    CareSection("Gatekeeper") {
                        CareRow(icon: SymbolTile(symbol: "checkmark.shield.fill", colors: care.gatekeeper == false ? Tint.pink : Tint.green, size: 32),
                            title: care.gatekeeper == false ? "Gatekeeper is off" : "Gatekeeper is on",
                            detail: "Only apps from identified developers open without a warning.",
                            value: care.gatekeeper == nil ? "…" : "") { EmptyView() }
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
                    CareSection("Privacy Permissions") {
                        if let permissions = care.permissions {
                            if permissions.isEmpty {
                                Text("No app holds a permission.").foregroundStyle(.secondary).padding(10)
                            }
                            ForEach(permissions) { p in
                                CareRow(icon: SymbolTile(symbol: "hand.raised.fill", colors: p.allowed ? Tint.violet : Tint.gray, size: 32),
                                    title: p.client, detail: p.service, value: p.allowed ? "Allowed" : "Denied") { EmptyView() }
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
        default: "internaldrive.fill"
        }
    }

    private var subtitle: String {
        let bad = care.untrusted.count
        if care.loadingProtection { return "Asking Gatekeeper about each app…" }
        return bad > 0 ? Store.counted(bad, "app") + " not verified by Apple" : "Every app is verified by Apple"
    }

    @ViewBuilder private func icon(_ app: InstalledApp) -> some View {
        if let image = care.icons[app.id] {
            Image(nsImage: image).resizable().frame(width: 34, height: 34)
        } else {
            SymbolTile(symbol: "app.fill", colors: Tint.gray, size: 32)
        }
    }
}
