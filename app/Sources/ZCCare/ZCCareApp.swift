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
    private var welcome: HostWindow<WelcomeView>?
    private var apps: HostWindow<AppPickerView>?

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
        store.hotkeyChanged = { [weak self] on in on ? self?.hotkey.register() : self?.hotkey.unregister() }
        if store.hotkey { hotkey.register() }
        Task { await store.start() }
        care.care.startSchedule()
        if !UserDefaults.standard.bool(forKey: Self.welcomed) { showWelcome() }
    }

    /// A clicked alert opens where its fix is: a full disk Cleanup, the
    /// other vitals their tile in the panel.
    private func openAlert(_ id: String) {
        switch id {
        case _ where id.hasPrefix("care"): care.show()
        case "vitals disk": care.show(.cleanup)
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
        apps?.close()
        let window = HostWindow(title: "Choose Apps", size: NSSize(width: 620, height: 700), themed: true) { [unowned self] in
            AppPickerView(store: store) { [weak self] in self?.apps?.close() }
        }
        apps = window
        window.show()
    }

    @objc private func open(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let url = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue.flatMap(URL.init(string:)),
              let host = url.host() else { return }
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
            } else if store.expanded != parts[1] {
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
