import AppKit
import SwiftUI

/// The first launch: what ZC Care is, the access it works best with, and
/// a way straight into Smart Care. Every step can be skipped.
struct WelcomeView: View {
    @Bindable var store: Store
    let start: () -> Void
    let close: () -> Void
    @State private var fullDisk = Access.fullDisk

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
                Text("Welcome to ZC Care").font(.system(size: 28, weight: .bold))
                Text("Smart Care for this Mac and its zc-care config. It lives in the menu bar; nothing changes without your yes.")
                    .font(.callout).foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 36)
            .padding(.horizontal, 40)
            VStack(spacing: 8) {
                Step(symbol: "person.crop.circle.badge.checkmark", colors: Tint.green, title: "Set up this Mac",
                     detail: "Who it is for, its security, and for developers git and GitHub.") {
                    Button("Start…") { store.openSetup?() }.controlSize(.small)
                }
                Step(symbol: "square.grid.2x2.fill", colors: Tint.blue, title: "Your apps",
                     detail: "Pick what this Mac installs from your config, with tips for each.") {
                    Button("Choose…") { store.openApps?() }.controlSize(.small)
                }
                Step(symbol: "lock.shield.fill", colors: Tint.pink, title: "Full Disk Access",
                     detail: "Lets ZC Care list privacy permissions and clear Safari's history.") {
                    if fullDisk {
                        Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.good).font(.callout)
                    } else {
                        Button("Open Settings") { Access.openFullDiskSettings() }.controlSize(.small)
                    }
                }
                Step(symbol: "power", colors: Tint.orange, title: "Open at login",
                     detail: "Keep the menu bar icon and the weekly scan running.") {
                    Toggle("Open at login", isOn: $store.opensAtLogin).toggleStyle(.switch).labelsHidden()
                }
                Step(symbol: "bell.badge.fill", colors: Tint.violet, title: "Notifications",
                     detail: store.notifies && store.notificationsBlocked
                        ? "macOS is holding them back: allow ZC Care in Notifications."
                        : "Hear about a full disk, a hot Mac and the weekly scan.") {
                    if store.notifies, store.notificationsBlocked {
                        Button("Open Settings") { Notifier.openSettings() }.controlSize(.small)
                    } else {
                        Toggle("Notifications", isOn: $store.notifies).toggleStyle(.switch).labelsHidden()
                    }
                }
                Step(symbol: "menubar.rectangle", colors: Tint.cyan, title: "The menu bar panel",
                     detail: "Click the icon, or press ⌃⌥Z, for vitals and quick fixes.") {
                    Toggle("The menu bar panel", isOn: $store.hotkey).toggleStyle(.switch).labelsHidden()
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 22)
            Spacer(minLength: 16)
            HStack {
                Button("Later", action: close).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Start Smart Care", action: start).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
        .frame(minWidth: 560, maxWidth: .infinity, minHeight: 690, maxHeight: .infinity)
        .themed()
        .ignoresSafeArea()
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            fullDisk = Access.fullDisk
            store.recheckNotifications()
        }
    }
}

private struct Step<Trailing: View>: View {
    let symbol: String
    let colors: [Color]
    let title: String
    let detail: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            SymbolTile(symbol: symbol, colors: colors, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            trailing
        }
        .padding(12)
        .modifier(Card())
    }
}
