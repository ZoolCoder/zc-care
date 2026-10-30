import AppKit
import SwiftUI
import ZCCareCore

/// The Apple menu's Recent Items, Recent Servers and each app's Open Recent.
struct RecentItemsSection: View {
    @Bindable var care: Care
    @State private var lists: [RecentList]?

    var body: some View {
        CareSection("Recent Items") {
            if let lists {
                if lists.isEmpty {
                    Text("macOS keeps no recent items list.").foregroundStyle(.secondary).padding(10)
                }
                ForEach(lists) { list in
                    CareRow(icon: SymbolTile(symbol: "clock.fill", colors: Tint.cyan, size: 32),
                        title: list.name, detail: Store.counted(list.files.count, "list"), value: "") {
                        Button("Clear") { Task { await clear([list]) } }
                            .controlSize(.small)
                            .disabled(care.store.busy != nil)
                    }
                }
            } else {
                ProgressView().controlSize(.small).padding(10)
            }
            HStack {
                Text("Clearing empties the lists; the files themselves stay.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let lists, lists.count > 1 {
                    Button("Clear All") { Task { await clear(lists) } }
                        .controlSize(.small)
                        .disabled(care.store.busy != nil)
                }
            }
            .padding(10)
        }
        .task(id: care.protectionCheckedAt) { await load() }
    }

    private func load() async {
        let home = NSHomeDirectory()
        lists = await Task.detached(priority: .utility) { RecentItems.find(home: home) }.value
    }

    private func clear(_ chosen: [RecentList]) async {
        guard care.store.busy == nil else { return }
        let urls = chosen.flatMap(\.files).filter { !care.store.ignoreList.touches($0) }
        guard !urls.isEmpty else {
            care.store.message = Store.Message(text: "Those recent items lists are on the ignore list, so they stay.", failed: true)
            return
        }
        let names = chosen.map(\.name).joined(separator: ", ")
        guard Alerts.confirm("Clear \(chosen.count == 1 ? names : "every recent items list")?",
                             "macOS forgets what was opened lately in \(names). Documents and apps stay where they are.",
                             button: "Clear") else { return }
        care.store.busy = "Clearing recent items"
        defer { care.store.busy = nil }
        let permanently = care.store.deletesPermanently
        let removal = await Task.detached { Removal.remove(urls, permanently: permanently) }.value
        // The lists live in sharedfilelistd's memory too; it rereads them when it starts again.
        let restarted = (try? await ProcessRunner(timeout: 10).run("/usr/bin/killall", ["sharedfilelistd"], env: [:]))?.status == 0
        care.store.record(.privacy, "Recent Items: \(names)", trashed: removal.trashed)
        care.store.message = Store.Message(text: "Recent items cleared" + (restarted ? "" : "; menus catch up after you log out again")
                                               + removal.ending, failed: removal.stayed > 0)
        await load()
    }
}

/// The Wi-Fi networks this Mac joins on its own, with Forget.
struct WiFiSection: View {
    @Bindable var care: Care
    @State private var networks: [KnownNetwork]?
    @State private var failure: String?

    var body: some View {
        CareSection("Known Wi-Fi Networks") {
            if let networks {
                if networks.isEmpty {
                    Text("This Mac remembers no Wi-Fi network.").foregroundStyle(.secondary).padding(10)
                }
                ForEach(networks) { network in
                    CareRow(icon: SymbolTile(symbol: "wifi", colors: Tint.blue, size: 32),
                        title: network.ssid, detail: "Joins on its own", value: "") {
                        Button("Forget…") { Task { await forget(network) } }
                            .controlSize(.small)
                            .disabled(care.store.busy != nil)
                    }
                }
            } else if let failure {
                Text("Networks not read: \(failure)").foregroundStyle(.secondary).padding(10)
            } else {
                ProgressView().controlSize(.small).padding(10)
            }
            Text("A Mac joins a remembered network by name alone, so a hotspot with the same name gets in. Forget the ones you no longer use; macOS asks for your password.")
                .font(.caption).foregroundStyle(.secondary).padding(10)
        }
        .task(id: care.protectionCheckedAt) { await load() }
    }

    private func load() async {
        let runner = ProcessRunner(timeout: 20)
        // networksetup exits 0 even when it fails, so only the output tells.
        guard let ports = try? await runner.run("/usr/sbin/networksetup", ["-listallhardwareports"], env: [:]),
              ports.output.contains("Hardware Port:") else {
            return fail("networksetup did not list the network ports")
        }
        guard let device = WiFiNetworks.device(in: ports.output) else {
            networks = []
            failure = nil
            return
        }
        guard let r = try? await runner.run("/usr/sbin/networksetup", ["-listpreferredwirelessnetworks", device], env: [:]),
              let found = WiFiNetworks.parse(r.output, device: device) else {
            return fail("networksetup could not list \(device)")
        }
        networks = found
        failure = nil
    }

    private func fail(_ text: String) {
        networks = nil
        failure = text
    }

    private func forget(_ network: KnownNetwork) async {
        guard care.store.busy == nil,
              Alerts.confirm("Forget \(network.ssid)?",
                             "This Mac stops joining it on its own and forgets its password, here and on your other devices with iCloud Keychain.\n\nmacOS asks for your password.",
                             button: "Forget") else { return }
        care.store.busy = "Forgetting \(network.ssid)"
        defer { care.store.busy = nil }
        // The list may be old: networksetup exits 0 on a network it no longer knows.
        await load()
        guard let known = networks else {
            care.store.message = Store.Message(text: "\(network.ssid) not forgotten: \(failure ?? "networksetup failed")", failed: true)
            return
        }
        guard known.contains(network) else {
            care.store.message = Store.Message(text: "\(network.ssid) is not in the list any more.", failed: false)
            return
        }
        do {
            // Time for the password dialog; a wedged airportd must not hold busy for ever.
            let r = try await ProcessRunner(timeout: 300).run("/usr/bin/osascript", ["-e", Maintenance.adminScript(WiFiNetworks.forgetSteps(network))], env: [:])
            guard r.status == 0 else { throw CLIError(message: lastLine(r.stderr) ?? "networksetup exited \(r.status)") }
            // networksetup exits 0 when it fails too: only the list read again proves it.
            await load()
            guard let networks, !networks.contains(network) else {
                throw CLIError(message: lastLine(r.output) ?? failure ?? "it is still in the list")
            }
            care.store.record(.privacy, "Forgot Wi-Fi \(network.ssid)")
            care.store.message = Store.Message(text: "\(network.ssid) forgotten.", failed: false)
        } catch {
            care.store.message = Store.Message(text: "\(network.ssid) not forgotten: \(error.localizedDescription)", failed: true)
            await load()
            // A timed-out run may still have finished as root: the list says.
            if let networks, !networks.contains(network) {
                care.store.record(.privacy, "Forgot Wi-Fi \(network.ssid)")
                care.store.message = Store.Message(text: "\(network.ssid) forgotten.", failed: false)
            }
        }
    }
}
