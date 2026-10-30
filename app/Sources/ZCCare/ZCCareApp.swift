import AppKit
import SwiftUI

@main
struct ZCCareApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            PanelView(store: delegate.store)
        } label: {
            StatusLabel(store: delegate.store)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store: Store
    private lazy var window = PanelWindow(store: store)
    private lazy var care = CareWindow(store: store)
    private lazy var hotkey = HotKey { [weak self] in self?.window.toggle() }
    private lazy var settings = HostWindow(title: "ZC Care Settings", size: NSSize(width: 480, height: 600)) { [unowned self] in
        SettingsView(store: store) { [weak self] in self?.showWelcome() }
    }
    private var toldHotkeyTaken = false
    private var welcome: HostWindow<WelcomeView>?
    private var apps: HostWindow<AppPickerView>?
    private var setup: HostWindow<SetupView>?

    override init() {
        store = Store()
        super.init()
    }

    /// SwiftUI takes URL events for itself, so the handler replaces its own
    /// before launch ends, when the URL that launched the app arrives:
    /// zccare://panel, from SketchyBar's item, toggles the floating panel.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(open(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.notifier.onOpen = { [weak self] id in self?.openAlert(id) }
        store.openCare = { [weak self] in self?.care.show($0) }
        store.openSettings = { [weak self] in self?.settings.show() }
        store.openApps = { [weak self] in self?.showApps() }
        store.openSetup = { [weak self] in self?.showSetup() }
        store.hotkeyChanged = { [weak self] on in on ? self?.registerHotkey() : self?.hotkey.unregister() }
        if store.hotkey { registerHotkey() }
        Task { await store.start() }
        care.care.startSchedule()
        // A Mac without a config starts in the Setup Assistant; the welcome
        // waits for a launch that has one.
        Task {
            await store.connected()
            if store.needsConfig {
                showSetup()
            } else if !UserDefaults.standard.bool(forKey: Self.welcomed) {
                showWelcome()
            }
        }
    }

    /// Registers ⌃⌥Z; when another app holds it, the owner is told once.
    private func registerHotkey() {
        let status = hotkey.register()
        guard status != noErr else { return }
        NSLog("ZC Care: the ⌃⌥Z shortcut could not be registered (OSStatus \(status))")
        guard !toldHotkeyTaken else { return }
        toldHotkeyTaken = true
        store.message = Store.Message(text: "The ⌃⌥Z shortcut is taken by another app (error \(status)).", failed: true)
    }

    /// A clicked alert opens where its fix is: a full disk Cleanup, the
    /// other vitals their tile in the panel.
    private func openAlert(_ id: String) {
        switch id {
        case _ where id.hasPrefix("care"): care.show()
        case "vitals disk", "vitals trash": care.show(.cleanup)
        case _ where id.hasPrefix("leftovers "):
            care.care.removedIDs.insert(String(id.dropFirst("leftovers ".count)))
            care.care.orphans = nil
            care.care.showLeftovers = true
            care.show(.apps)
        case "vitals memory", "vitals heat", "vitals battery":
            store.tab = .mac
            store.macDetail = id == "vitals memory" ? .memory : id == "vitals heat" ? .cpu : nil
            window.show()
        default: window.show()
        }
    }

    private static let welcomed = "welcomed"

    /// Shown once on its own; Settings shows it again.
    private func showWelcome() {
        UserDefaults.standard.set(true, forKey: Self.welcomed)
        welcome?.close()
        let window = HostWindow(title: "Welcome to ZC Care", size: NSSize(width: 560, height: 690), themed: true) { [unowned self] in
            WelcomeView(store: store,
                        start: { [weak self] in
                            self?.welcome?.close()
                            self?.care.show()
                        },
                        close: { [weak self] in self?.welcome?.close() })
        }
        welcome = window
        window.show()
    }

    /// A new picker each time, so it reads what the Mac has now.
    private func showApps() {
        // An install in flight keeps its window; the picker comes forward.
        if store.busy != nil, let apps { apps.show(); return }
        apps?.close()
        let window = HostWindow(title: "Choose Apps", size: NSSize(width: 620, height: 700), themed: true,
                                allowsClose: { [unowned self] in store.busy == nil }) { [unowned self] in
            AppPickerView(store: store) { [weak self] in self?.apps?.close() }
        }
        apps = window
        window.show()
    }

    private func showSetup() {
        if store.busy != nil, let setup { setup.show(); return }
        setup?.close()
        let window = HostWindow(title: "Set Up This Mac", size: NSSize(width: 580, height: 680), themed: true,
                                allowsClose: { [unowned self] in store.busy == nil }) { [unowned self] in
            SetupView(store: store) { [weak self] in self?.setup?.close() }
        }
        setup = window
        window.show()
    }

    @objc private func open(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let url = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue.flatMap(URL.init(string:)),
              let host = url.host()?.lowercased() else { return }
        let parts = url.pathComponents.filter { $0 != "/" }
        // zccare://care opens the Care window, zccare://care/applications a module.
        if host == "care" {
            care.show(parts.first.flatMap(Care.Module.named))
            return
        }
        if host == "settings" {
            settings.show()
            return
        }
        // zccare://apps, from bootstrap.sh, picks what a new Mac installs.
        if host == "apps" {
            showApps()
            return
        }
        if host == "setup" {
            showSetup()
            return
        }
        guard host == "panel" else { return }
        // zccare://panel/updates opens a tab, zccare://panel/overview/home a
        // target in it, zccare://panel/mac/disk a tile.
        guard let name = parts.first, let tab = Store.Tab.allCases.first(where: { $0.rawValue.lowercased() == name }) else {
            window.toggle()
            return
        }
        store.tab = tab
        if parts.count > 1 {
            if tab == .mac {
                store.macDetail = Store.MacDetail(rawValue: parts[1])
            } else if tab == .overview, store.expanded != parts[1] {
                store.toggle(parts[1])
            }
        }
        window.show()
    }

    @objc func showPanel() {
        window.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
    }
}

/// The menu bar icon: the ZoolCoder mark, with a count when something needs
/// attention, or ! when the CLI cannot run.
struct StatusLabel: View {
    let store: Store

    var body: some View {
        HStack(spacing: 2) {
            Image(nsImage: BrandMark.template)
            if let title {
                title.monospacedDigit()
            }
        }
    }

    /// The menu bar keeps one image and one text, so the attention count and
    /// the readings picked in Settings share a single text.
    private var title: Text? {
        let count = store.attention
        let flag = store.setupProblem != nil ? "!" : count > 0 ? "\(count)" : nil
        let parts = (flag.map { [Text($0)] } ?? [])
            + Store.BarStat.allCases.filter(store.barStats.contains).compactMap(reading)
        guard let first = parts.first else { return nil }
        return parts.dropFirst().reduce(first) { $0 + Text("  ") + $1 }
    }

    private func reading(_ stat: Store.BarStat) -> Text? {
        let v = store.monitor.vitals
        switch stat {
        case .cpu:
            return v.cpuLoad.map { Text("\(Image(systemName: "cpu")) \(Int(($0 * 100).rounded()))%") }
        case .memory:
            return v.memory.flatMap { m in
                m.total > 0 ? Text("\(Image(systemName: "memorychip")) \(Int(m.used * 100 / m.total))%") : nil
            }
        case .disk:
            return v.disk.map { Text("\(Image(systemName: "internaldrive")) \(Store.compact(Double($0.available)))") }
        case .network:
            return v.network.map {
                Text("\(Image(systemName: "arrow.down")) \(Store.compact($0.down)) \(Image(systemName: "arrow.up")) \(Store.compact($0.up))")
            }
        case .battery:
            return v.battery.map {
                Text("\(Image(systemName: $0.charging ? "battery.100percent.bolt" : "battery.75percent")) \($0.percent)%")
            }
        }
    }
}
