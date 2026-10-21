import AppKit
import SwiftUI
import ZCCareCore

// MARK: Cleanup

struct CleanupView: View {
    @Bindable var care: Care

    var body: some View {
        VStack(spacing: 0) {
            CareHeader(title: "Cleanup", subtitle: "Caches, logs, build output and what AI tools leave behind",
                   busy: care.monitor.scanning || care.scanningAI,
                   action: ("Rescan", { Task { await care.enter(.cleanup) } }))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("There are \(Store.bytes(care.junk + care.ai)) of junk files on your Mac.")
                        .font(.system(size: 26, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    HStack(spacing: 14) {
                        ResultCard(title: "System Junk", symbol: "trash.fill", colors: Tint.green,
                                   figure: Store.bytes(care.junk), detail: "Caches, logs and build output",
                                   working: care.monitor.scanning && care.junk == 0,
                                   link: care.junk > 0 ? ("Clean All", { Task { await care.store.cleanAll() } }) : nil)
                        ResultCard(title: "AI Clutter", symbol: "brain.head.profile", colors: Tint.violet,
                                   figure: Store.bytes(care.ai), detail: "Temp files, old versions, caches and logs of AI tools",
                                   working: care.scanningAI && care.ai == 0,
                                   link: care.ai > 0 ? ("Clean All", { Task { await care.cleanAI(care.aiJunk) } }) : nil)
                    }
                    .frame(height: 170)
                    if !care.aiJunk.isEmpty {
                        CareSection("AI Clutter") {
                            ForEach(aiTools, id: \.tool) { tool, junk in
                                AIJunkRow(care: care, tool: tool, junk: junk)
                            }
                        }
                    }
                    CareSection("System Junk") {
                        ForEach(Junk.spots(home: NSHomeDirectory()).filter { FileManager.default.fileExists(atPath: $0.path) }) { spot in
                            JunkRow(care: care, spot: spot)
                        }
                        CareRow(icon: SymbolTile(symbol: "trash.fill", colors: Tint.gray, size: 32),
                            title: "Trash", detail: "Emptied by the Finder", value: "") {
                            Button("Empty") { Task { await care.store.emptyTrash() } }.controlSize(.small)
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 70)
            }
        }
    }

    /// Each tool's junk together, biggest tool first.
    private var aiTools: [(tool: String, junk: [AIJunk])] {
        Dictionary(grouping: care.aiJunk, by: \.tool)
            .map { ($0.key, $0.value) }
            .sorted { $0.1.reduce(0) { $0 + $1.size } > $1.1.reduce(0) { $0 + $1.size } }
    }
}

/// One AI tool's junk; its chevron lists every path clearing deletes.
private struct AIJunkRow: View {
    @Bindable var care: Care
    let tool: String
    let junk: [AIJunk]
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CareRow(icon: AIToolIcon(tool: tool), title: tool,
                detail: junk.map { "\($0.kind) \(Store.bytes($0.size))" }.joined(separator: " · "),
                value: Store.bytes(junk.reduce(0) { $0 + $1.size })) {
                Button { open.toggle() } label: { Image(systemName: open ? "chevron.up" : "chevron.down").accessibilityLabel("Show what is cleared") }
                    .controlSize(.small)
                    .help("Show what is cleared")
                Button("Clear") { Task { await care.cleanAI(junk) } }
                    .controlSize(.small)
                    .disabled(care.store.busy != nil)
            }
            if open {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(junk) { kind in
                        Text(kind.kind).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
                        ForEach(kind.paths.prefix(20), id: \.self) { url in
                            HStack {
                                Text((url.path as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "magnifyingglass") }
                                    .buttonStyle(.borderless)
                                    .help("Show in Finder")
                            }
                        }
                        if kind.paths.count > 20 {
                            Text("and \(kind.paths.count - 20) more").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.callout)
                .padding(.leading, 56)
                .padding(.trailing, 14)
                .padding(.bottom, 8)
            }
        }
    }
}

/// The tool's app icon when the app is installed, a symbol for the CLIs.
private struct AIToolIcon: View {
    let tool: String

    var body: some View {
        let app = "/Applications/\(tool == "Claude Code" ? "Claude" : tool).app"
        if FileManager.default.fileExists(atPath: app) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app)).resizable().frame(width: 32, height: 32)
        } else {
            SymbolTile(symbol: "terminal.fill", colors: Tint.violet, size: 32)
        }
    }
}

/// A Junk folder; its chevron opens what is inside, to clear only some.
private struct JunkRow: View {
    @Bindable var care: Care
    let spot: Junk
    @State private var open = false
    @State private var entries: [JunkEntry]?
    @State private var picked: Set<String> = []

    var body: some View {
        let size = care.monitor.junk[spot.id]
        VStack(alignment: .leading, spacing: 0) {
            CareRow(icon: SymbolTile(symbol: "folder.fill", colors: Tint.cyan, size: 32),
                title: spot.title, detail: spot.detail, value: size.map { Store.bytes($0) } ?? "…") {
                Button { toggle() } label: { Image(systemName: open ? "chevron.up" : "chevron.down").accessibilityLabel("Choose what to clear") }
                    .controlSize(.small)
                    .help("Choose what to clear")
                    .disabled((size ?? 0) == 0)
                Button(open ? "Clear Selected" : "Clear") { Task { await clear() } }
                    .controlSize(.small)
                    .disabled((size ?? 0) == 0 || care.store.busy != nil || (open && picked.isEmpty))
            }
            if open {
                if let entries {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(entries.prefix(40)) { entry in
                            Toggle(isOn: Binding(get: { picked.contains(entry.id) },
                                                 set: { on in if on { picked.insert(entry.id) } else { picked.remove(entry.id) } })) {
                                HStack {
                                    JunkEntryLabel(name: entry.name)
                                    Spacer()
                                    Text(Store.bytes(entry.size)).monospacedDigit().foregroundStyle(.secondary)
                                    Button { reveal(entry) } label: { Image(systemName: "magnifyingglass") }
                                        .buttonStyle(.borderless)
                                        .help("Show in Finder")
                                        .accessibilityLabel("Show \(entry.name) in Finder")
                                }
                            }
                            .toggleStyle(.checkbox)
                            .padding(.vertical, 3)
                            .contextMenu {
                                Button("Show in Finder") { reveal(entry) }
                                Button("Always Keep \(entry.name)") { keep(entry) }
                            }
                        }
                        // The small ones are ticked or not together, and say
                        // so: nothing is cleared that the list does not show.
                        if entries.count > 40 {
                            let rest = entries.dropFirst(40)
                            Toggle(isOn: Binding(get: { rest.allSatisfy { picked.contains($0.id) } },
                                                 set: { on in rest.forEach { if on { picked.insert($0.id) } else { picked.remove($0.id) } } })) {
                                HStack {
                                    Text("\(rest.count) smaller items")
                                    Spacer()
                                    Text(Store.bytes(rest.reduce(0) { $0 + $1.size })).monospacedDigit().foregroundStyle(.secondary)
                                    Button { NSWorkspace.shared.open(URL(fileURLWithPath: spot.path)) } label: { Image(systemName: "magnifyingglass") }
                                        .buttonStyle(.borderless)
                                        .help("Open the folder in Finder")
                                        .accessibilityLabel("Open \(spot.title) in Finder")
                                }
                            }
                            .toggleStyle(.checkbox)
                            .padding(.vertical, 3)
                        }
                    }
                    .font(.callout)
                    .padding(.leading, 56)
                    .padding(.trailing, 14)
                    .padding(.bottom, 8)
                } else {
                    ProgressView().controlSize(.small).padding(.leading, 56).padding(.bottom, 8)
                }
            }
        }
    }

    private func toggle() {
        open.toggle()
        guard open else { return }
        entries = nil
        let spot = spot
        Task {
            let keep = await care.monitor.keep(spot, open: care.monitor.runningApps())
            let found = await Task.detached { spot.contents(keeping: keep) }.value
            entries = found
            picked = Set(found.map(\.id))
        }
    }

    /// Puts the entry on the ignore list: no clean clears it again.
    private func keep(_ entry: JunkEntry) {
        care.store.ignore(URL(fileURLWithPath: spot.path).appendingPathComponent(entry.name))
        entries?.removeAll { $0.id == entry.id }
        picked.remove(entry.id)
    }

    private func reveal(_ entry: JunkEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: spot.path).appendingPathComponent(entry.name)])
    }

    private func clear() async {
        if open, let entries {
            await care.store.clean(spot, only: entries.filter { picked.contains($0.id) })
        } else {
            await care.store.clean(spot)
        }
        open = false
    }
}

/// A cache folder named for an app's bundle id shows as that app, with
/// its icon and the folder's name under it; any other name shows as is.
private struct JunkEntryLabel: View {
    let name: String

    var body: some View {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) {
            HStack(spacing: 6) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 16, height: 16)
                Text(FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: ""))
                Text(name).font(.caption).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .truncationMode(.middle)
        } else {
            Text(name).lineLimit(1).truncationMode(.middle)
        }
    }
}

// MARK: Cloud Cleanup

/// The cloud folders' downloaded files. Removing a download keeps the file
/// in the cloud, so nothing here deletes anything.
struct CloudCleanupView: View {
    @Bindable var care: Care

    var body: some View {
        let scans = care.cloud ?? []
        VStack(spacing: 0) {
            CareHeader(title: "Cloud Cleanup", subtitle: subtitle(scans), busy: care.scanningCloud,
                   action: ("Rescan", { Task { await care.scanCloud() } }))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if scans.isEmpty, care.scanningCloud {
                        CareSection("Looking through your cloud folders") {
                            Text("macOS may ask to let ZC Care read the files iCloud Drive and other providers keep. Only sizes are read.")
                                .foregroundStyle(.secondary).padding(10)
                        }
                    }
                    if scans.isEmpty, !care.scanningCloud {
                        CareSection("No cloud folders") {
                            Text("iCloud Drive, Google Drive, OneDrive and Dropbox show here once they sync to this Mac.")
                                .foregroundStyle(.secondary).padding(10)
                        }
                    }
                    ForEach(scans) { scan in
                        CareSection("\(scan.drive.name) · \(Store.bytes(scan.downloaded)) downloaded") {
                            if scan.files.isEmpty {
                                Text("No downloaded file over \(Store.bytes(Care.cloudFile)).").foregroundStyle(.secondary).padding(10)
                            }
                            ForEach(scan.files) { file in
                                CareRow(icon: Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path)).resizable().frame(width: 32, height: 32),
                                    title: file.name, detail: folder(file, in: scan.drive) + (file.modified.map { " · modified " + relativeDate($0) } ?? ""),
                                    value: Store.bytes(file.size)) {
                                    Button { NSWorkspace.shared.activateFileViewerSelecting([file.url]) } label: {
                                        Image(systemName: "magnifyingglass").accessibilityLabel("Show in Finder")
                                    }
                                    .controlSize(.small)
                                    .help("Show in Finder")
                                    Button("Remove Download") { care.removeDownload(file, from: scan.drive) }
                                        .controlSize(.small)
                                        .disabled(care.store.busy != nil)
                                }
                                .contextMenu { IgnoreMenu(store: care.store, url: file.url) }
                            }
                        }
                    }
                    Text("Remove Download frees the space a file takes on this Mac. The file stays in the cloud and downloads again when you open it.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 70)
            }
        }
    }

    private func subtitle(_ scans: [Care.CloudScan]) -> String {
        if care.scanningCloud { return "Looking through your cloud folders…" }
        let total = scans.reduce(0) { $0 + $1.downloaded }
        return total > 0 ? "\(Store.bytes(total)) of cloud files are downloaded to this Mac" : "Nothing from the cloud takes space here"
    }

    private func folder(_ file: LargeFile, in drive: CloudDrive) -> String {
        let parent = file.url.deletingLastPathComponent().path
        let inside = parent.dropFirst(drive.url.path.count)
        return drive.name + (inside.isEmpty ? "" : String(inside))
    }
}
