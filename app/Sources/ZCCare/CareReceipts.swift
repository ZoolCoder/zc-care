import AppKit
import SwiftUI
import ZCCareCore

extension Care {
    /// Reads the receipts pkgutil keeps of installer packages, Apple's left
    /// out, and checks a sample of each one's files. It changes nothing.
    func loadReceipts() async {
        guard !loadingReceipts else { return }
        loadingReceipts = true
        defer { loadingReceipts = false }
        let found = await Task.detached(priority: .utility) { () -> [PackageReceipt]? in
            let runner = ProcessRunner(timeout: 30)
            let pkgutil = "/usr/sbin/pkgutil"
            guard let list = try? await runner.run(pkgutil, ["--pkgs"], env: [:]), list.status == 0 else { return nil }
            var out: [PackageReceipt] = []
            // A Mac with hundreds of third-party packages still answers in time.
            for id in Receipts.ids(list.output).prefix(200) {
                guard let plist = try? await runner.run(pkgutil, ["--pkg-info-plist", id], env: [:]), plist.status == 0,
                      let info = Receipts.info(plist.stdout),
                      let files = try? await runner.run(pkgutil, ["--only-files", "--files", id], env: [:]), files.status == 0,
                      let receipt = Receipts.receipt(id: id, version: info.version, installed: info.installed, root: info.root,
                                                     files: files.output.split(separator: "\n").map(String.init))
                else { continue }
                out.append(receipt)
            }
            return out.sorted { ($0.installed ?? .distantPast) > ($1.installed ?? .distantPast) }
        }.value
        receiptsUnread = found == nil
        receipts = found ?? []
    }
}

/// The installer packages macOS remembers, and whether their files are
/// still there; a receipt whose files are gone is only a note in a database.
struct InstallerPackages: View {
    @Bindable var care: Care

    var body: some View {
        CareSection("Installer Packages") {
            if let receipts = care.receipts {
                if care.receiptsUnread {
                    Text("pkgutil could not list the receipts.").foregroundStyle(.secondary).padding(10)
                } else if receipts.isEmpty {
                    Text("No installer package outside Apple's left a receipt.").foregroundStyle(.secondary).padding(10)
                }
                ForEach(receipts) { r in
                    CareRow(icon: SymbolTile(symbol: "shippingbox.fill", colors: r.state == .installed ? Tint.blue : Tint.gray, size: 32),
                            title: r.id, detail: detail(r), value: Store.counted(r.files, "file"), flag: flag(r.state)) {
                        if FileManager.default.fileExists(atPath: r.anchor) {
                            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: r.anchor)]) } label: {
                                Image(systemName: "magnifyingglass").accessibilityLabel("Show in Finder")
                            }
                            .controlSize(.small)
                            .help("Show in Finder")
                        }
                    }
                }
                if receipts.contains(where: { $0.state != .installed }) {
                    Text("A receipt only records the install. `sudo pkgutil --forget <id>` drops it and leaves any files where they are.")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled).padding(10)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading installer receipts…").foregroundStyle(.secondary)
                }
                .padding(10)
            }
        }
        // Rescan clears the list, and this reads it again.
        .task(id: care.receipts == nil) { if care.receipts == nil { await care.loadReceipts() } }
    }

    private func detail(_ r: PackageReceipt) -> String {
        let place = (r.anchor as NSString).abbreviatingWithTildeInPath
        let when = r.installed.map { " · installed " + relativeDate($0) } ?? ""
        return "Version \(r.version) · \(place)" + when
    }

    private func flag(_ state: PackageReceipt.State) -> String? {
        switch state {
        case .installed: nil
        case .partly: "Partly Removed"
        case .gone: "Files Gone"
        }
    }
}
