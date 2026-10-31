import AppKit
import SwiftUI
import ZCCareCore

/// The Simulator runtimes Xcode downloaded, each deletable through simctl.
struct SimulatorRuntimesSection: View {
    let care: Care
    @State private var runtimes: [SimulatorRuntime] = []

    var body: some View {
        // A stack, not a Group: SwiftUI starts no task on a Group with nothing in it.
        VStack(spacing: 0) {
            if !runtimes.isEmpty { section }
        }
        // Once on appear and once when a scan ends, not when it starts.
        .task(id: care.scanningDeveloper) { if !care.scanningDeveloper { await load() } }
    }

    private var section: some View {
        CareSection("Simulator Runtimes") {
            ForEach(runtimes) { runtime in
                CareRow(icon: SymbolTile(symbol: "iphone", colors: Tint.blue, size: 32),
                    title: runtime.title,
                    detail: "Build \(runtime.build) · \(runtime.state)",
                    value: Store.bytes(runtime.size)) {
                    Button("Delete") { Task { await delete(runtime) } }
                        .controlSize(.small)
                        .disabled(!runtime.deletable)
                        .help(runtime.deletable ? "Delete \(runtime.title) with simctl" : "Xcode bundles this runtime; simctl cannot delete it.")
                        .gatedOnBusy(care.store)
                }
            }
            Text("Deleting is permanent, there is no Trash for it. Xcode downloads a runtime again when a project needs it.")
                .font(.caption).foregroundStyle(.secondary).padding(10)
        }
    }

    /// xcrun alone is a shim that offers to install the developer tools; only ask it with Xcode in place.
    private var xcodeInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode") != nil
    }

    private func load() async {
        guard xcodeInstalled else { return }
        runtimes = await Simulators.runtimes(runner: ProcessRunner(timeout: 30), env: care.store.loginEnv) ?? []
    }

    private func delete(_ runtime: SimulatorRuntime) async {
        let store = care.store
        guard store.busy == nil,
              Alerts.confirm("Delete \(runtime.title)?",
                             "Deletes the \(Store.bytes(runtime.size)) runtime for good with simctl; there is no Trash for it. Simulators that use it stop working until Xcode downloads it again.",
                             button: "Delete"), store.busy == nil else { return }
        store.busy = "Delete \(runtime.title)"
        defer { store.busy = nil }
        let failed = await store.failure("simctl exited with an error") {
            try await ProcessRunner(timeout: 600).run(Simulators.xcrun, Simulators.deleteRuntime(runtime.id), env: store.loginEnv)
        }
        store.message = failed.map { Store.Message(text: "Delete \(runtime.title): \($0)", failed: true) }
            ?? Store.Message(text: "Deleted \(runtime.title).", failed: false)
        await load()
    }
}
