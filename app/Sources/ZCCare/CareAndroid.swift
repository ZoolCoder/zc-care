import AppKit
import SwiftUI
import ZCCareCore

/// Android system images and virtual devices, shown for finding only:
/// sdkmanager and avdmanager own their removal.
struct AndroidSection: View {
    let care: Care
    @State private var items: [AndroidItem] = []

    var body: some View {
        Group {
            if !items.isEmpty { section }
        }
        // Once on appear and once when a scan ends, not when it starts.
        .task(id: care.scanningDeveloper) { if !care.scanningDeveloper { await load() } }
    }

    private var section: some View {
        CareSection("Android") {
            ForEach(items) { item in
                CareRow(icon: SymbolTile(symbol: "smartphone", colors: Tint.green, size: 32),
                    title: item.name, detail: item.kind.rawValue, value: Store.bytes(item.size)) {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: {
                        Image(systemName: "magnifyingglass").accessibilityLabel("Show in Finder")
                    }
                    .controlSize(.small)
                    .help("Show in Finder")
                }
            }
            Text("Remove them with sdkmanager or avdmanager, which keep their lists in step.")
                .font(.caption).foregroundStyle(.secondary).padding(10)
        }
    }

    private func load() async {
        let home = NSHomeDirectory()
        guard let sdk = Android.sdkRoot(home: home, environment: ProcessInfo.processInfo.environment) else {
            items = []
            return
        }
        let avdHome = ProcessInfo.processInfo.environment["ANDROID_AVD_HOME"] ?? home + "/.android/avd"
        items = await Task.detached(priority: .utility) { Android.items(sdk: sdk, avdHome: avdHome) }.value
    }
}
