import AppKit
import SwiftUI

/// What macOS lets ZC Care read.
enum Access {
    /// The user's TCC database opens only with Full Disk Access; opening,
    /// not access(2), is what macOS checks.
    static var fullDisk: Bool {
        let db = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db")
        guard let handle = try? FileHandle(forReadingFrom: db) else { return false }
        try? handle.close()
        return true
    }

    static func openFullDiskSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }
}

/// Keeps a window open while its closure says no, as the title-bar button asks.
private final class CloseGate: NSObject, NSWindowDelegate {
    let allowsClose: @MainActor () -> Bool

    init(allowsClose: @escaping @MainActor () -> Bool) { self.allowsClose = allowsClose }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        MainActor.assumeIsolated { allowsClose() }
    }
}

/// A small window that hosts one SwiftUI view, made on first show and kept.
@MainActor
final class HostWindow<Content: View> {
    private var window: NSWindow?
    private let gate: CloseGate?
    private let title: String
    private let size: NSSize
    /// Dark, its content under a clear title bar, as the Care window is.
    private let themed: Bool
    private let content: () -> Content

    init(title: String, size: NSSize, themed: Bool = false, allowsClose: (@MainActor () -> Bool)? = nil,
         content: @escaping () -> Content) {
        gate = allowsClose.map(CloseGate.init)
        self.title = title
        self.size = size
        self.themed = themed
        self.content = content
    }

    func show() {
        let window = self.window ?? make()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    private func make() -> NSWindow {
        let style: NSWindow.StyleMask = themed ? [.titled, .closable, .fullSizeContentView] : [.titled, .closable]
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style,
                              backing: .buffered, defer: true)
        window.title = title
        if themed {
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.appearance = NSAppearance(named: .darkAqua)
            window.isMovableByWindowBackground = true
        }
        window.isReleasedWhenClosed = false
        window.delegate = gate
        window.contentViewController = NSHostingController(rootView: content())
        window.setContentSize(size)
        window.center()
        return window
    }
}

/// Settings: what the panel's gear menu held, with the config, ignored
/// checks and Full Disk Access beside it.
struct SettingsView: View {
    @Bindable var store: Store
    var showWelcome: () -> Void
    @State private var fullDisk = Access.fullDisk
    @State private var confirmsDelete = false

    var body: some View {
        Form {
            Section("General") {
                Toggle("Open ZC Care at login", isOn: $store.opensAtLogin)
                Toggle("Open the panel with ⌃⌥Z", isOn: $store.hotkey)
                Toggle("Notify me when something needs attention", isOn: $store.notifies)
                Toggle("Notify me when a removed app leaves files behind", isOn: $store.leftoverAlerts)
                    .disabled(!store.notifies)
                if store.notifies, store.notificationsBlocked {
                    HStack {
                        Label("macOS is not showing ZC Care's notifications", systemImage: "bell.slash")
                            .foregroundStyle(Theme.warning)
                        Spacer()
                        Button("Open Notification Settings") { Notifier.openSettings() }
                    }
                }
            }
            Section {
                ForEach(Store.BarStat.allCases, id: \.self) { stat in
                    Toggle(stat.title, isOn: Binding(
                        get: { store.barStats.contains(stat) },
                        set: { on in
                            if on { store.barStats.insert(stat) } else { store.barStats.remove(stat) }
                        }))
                }
            } header: {
                Text("Menu Bar")
            } footer: {
                Text("Read every two seconds from macOS itself, with nothing else running.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                Toggle("Warn me about my Mac's vitals", isOn: $store.vitalsAlerts)
                Group {
                    Stepper("Free disk space under \(store.vitalLimits.diskFreeGB) GB",
                            value: $store.vitalLimits.diskFreeGB, in: 5...200, step: 5)
                    Stepper("Memory pressure from \(store.vitalLimits.memoryPressure)%",
                            value: $store.vitalLimits.memoryPressure, in: 50...95, step: 5)
                    Stepper("CPU from \(store.vitalLimits.cpuTemp) °C",
                            value: $store.vitalLimits.cpuTemp, in: 70...105, step: 5)
                    Stepper("Battery capacity under \(store.vitalLimits.batteryCapacity)%",
                            value: $store.vitalLimits.batteryCapacity, in: 50...95, step: 5)
                    Stepper("Trash over \(store.vitalLimits.trashGB) GB",
                            value: $store.vitalLimits.trashGB, in: 1...100, step: 1)
                    Stepper("Bluetooth device battery at \(store.vitalLimits.deviceBattery)%",
                            value: $store.vitalLimits.deviceBattery, in: 5...50, step: 5)
                }
                .disabled(!store.vitalsAlerts || !store.notifies)
            } header: {
                Text("Vitals Alerts")
            } footer: {
                Text("Checked each minute. Memory and heat must last a few minutes, and each alert waits an hour or more before it repeats."
                     + (store.notifies ? "" : " Turn on notifications in General first."))
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section("Cleanup") {
                Toggle("Delete permanently instead of moving to the Trash", isOn: Binding(
                    get: { store.deletesPermanently },
                    set: { on in
                        if on { confirmsDelete = true } else { store.deletesPermanently = false }
                    }))
                Text(store.deletesPermanently
                     ? "Cleanups are deleted at once and cannot be put back."
                     : "Cleanups go to the Trash and can be put back from My Activity. Space frees once the Trash is emptied.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Smart Care") {
                Toggle("Scan every week", isOn: $store.weeklyScan)
                Text("The weekly scan only looks and notifies; nothing is cleaned without you. It waits until the Mac is on power and not in Low Power Mode.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Full Disk Access") {
                HStack {
                    Label(fullDisk ? "Granted" : "Not granted",
                          systemImage: fullDisk ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(fullDisk ? Theme.good : Theme.warning)
                    Spacer()
                    Button("Open Privacy Settings") { Access.openFullDiskSettings() }
                }
                Text("Lets ZC Care list privacy permissions and read Safari's history and caches.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Config") {
                LabeledContent("File") {
                    Text(store.configPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "None")
                        .lineLimit(1).truncationMode(.middle)
                }
                HStack {
                    if let path = store.configPath {
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        }
                    }
                    Button("Choose…", action: store.chooseConfig)
                }
                LabeledContent("Who this Mac is for") {
                    Button("Set Up This Mac…") { store.openSetup?() }
                }
                LabeledContent("Apps on this Mac") {
                    Button("Choose Apps…") { store.openApps?() }
                }
            }
            Section {
                if store.ignoreList.paths.isEmpty {
                    Text("Nothing yet. Add a folder here, or Control-click a file in ZC Care and choose Ignore.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.ignoreList.paths, id: \.self) { path in
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 18, height: 18)
                        Text((path as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { store.ignoreList.remove(path) } label: { Image(systemName: "minus.circle.fill").accessibilityLabel("Take off the list") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Take off the list")
                    }
                }
                Button("Add…", action: addToIgnoreList)
            } header: {
                Text("Ignore List")
            } footer: {
                Text("ZC Care never lists, cleans or trashes these, nor anything inside them.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section("Health Checks") {
                LabeledContent("Ignored", value: "\(store.ignored.count)")
                Button("Stop Ignoring All", action: store.unignoreAll).disabled(store.ignored.isEmpty)
            }
            Section {
                HStack {
                    Text("ZC Care \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Show Welcome", action: showWelcome)
                    Button("Quit ZC Care") { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .frame(minHeight: 560)
        .alert("Delete cleanups for good?", isPresented: $confirmsDelete) {
            Button("Delete Permanently", role: .destructive) { store.deletesPermanently = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Cleanups skip the Trash. My Activity can no longer put them back, and Smart Care, Cleanup and the uninstaller delete at once.")
        }
        // Back from System Settings, the grant shows at once.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            fullDisk = Access.fullDisk
            store.recheckNotifications()
        }
    }

    private func addToIgnoreList() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Ignore"
        panel.message = "ZC Care will never list, clean or trash what you pick."
        guard panel.runModal() == .OK else { return }
        var list = store.ignoreList
        for url in panel.urls { list.add(url.path) }
        store.ignoreList = list
    }
}
