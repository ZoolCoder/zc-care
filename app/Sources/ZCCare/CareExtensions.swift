import AppKit
import SwiftUI
import ZCCareCore

struct ExtensionsSection: View {
    @State private var loading = false
    @State private var extensions: [AppExtension]?

    var body: some View {
        CareSection("Extensions") {
            if let extensions {
                if extensions.isEmpty {
                    Text("No third-party extensions found.").foregroundStyle(.secondary).padding(10)
                }
                ForEach(ExtensionKind.allCases, id: \.self) { kind in
                    let group = extensions.filter { $0.kind == kind }
                    if !group.isEmpty {
                        Text(kind.rawValue).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 10).padding(.top, 8)
                        ForEach(group) { row($0) }
                    }
                }
            } else {
                ProgressView().controlSize(.small).padding(10)
            }
            HStack {
                Text("Switch extensions in System Settings > General > Login Items & Extensions.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Rescan") { Task { await scan() } }
                    .controlSize(.small)
                    .disabled(loading)
                Button("Open Extensions Settings") { NSWorkspace.shared.open(Self.settingsURL) }
                    .controlSize(.small)
            }
            .padding(10)
        }
        .task { if extensions == nil { await scan() } }
    }

    private static var settingsURL: URL {
        let pane = if #available(macOS 15, *) { "com.apple.LoginItems-Settings.extension" } else { "com.apple.ExtensionsPreferences" }
        return URL(string: "x-apple.systempreferences:" + pane)!
    }

    private func scan() async {
        loading = true
        let found = await Extensions.load(runner: ProcessRunner(timeout: 20))
        loading = false
        // Leaving the module cancels the commands, which then report nothing; the next visit scans again.
        guard !Task.isCancelled else { return }
        extensions = found
    }

    private func row(_ item: AppExtension) -> some View {
        CareRow(icon: SymbolTile(symbol: symbol(item.kind), colors: item.enabled ? Tint.violet : Tint.gray, size: 32),
            title: item.name,
            detail: [item.identifier, item.hostName.map { "in \($0)" }, item.detail].compactMap { $0 }.joined(separator: " · "),
            value: item.enabled ? "On" : "Off",
            flag: item.hostGone ? "Host app gone" : item.unidentified ? "Unidentified" : nil) { EmptyView() }
    }

    private func symbol(_ kind: ExtensionKind) -> String {
        switch kind {
        case .safari: "safari.fill"
        case .share: "square.and.arrow.up.fill"
        case .finderSync: "folder.fill"
        case .quickLook: "eye.fill"
        case .spotlight: "magnifyingglass"
        case .notificationCenter: "bell.fill"
        case .action: "wand.and.stars"
        case .photoEditing: "photo.fill"
        case .system: "cpu.fill"
        }
    }
}
