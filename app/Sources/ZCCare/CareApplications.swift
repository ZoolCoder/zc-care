import AppKit
import SwiftUI
import ZCCareCore

// MARK: Applications

struct ApplicationsView: View {
    @Bindable var care: Care
    @State private var filter = Filter.all
    @State private var expanded: String?

    enum Filter: String, CaseIterable { case all = "All", undeclared = "Not in Brewfile", unused = "Unused", leftovers = "Leftovers" }

    var body: some View {
        VStack(spacing: 0) {
            CareHeader(title: "Applications", subtitle: "\(Store.counted(care.apps.count, "app")), \(Store.bytes(total)) in all",
                   busy: care.loadingApps, action: ("Rescan", { care.orphans = nil; Task { await care.loadApps() } }))
            HStack {
                Picker("", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 440)
                Spacer()
                let outdated = care.store.snapshot?.outdated.count ?? 0
                if outdated > 0 {
                    Button("Update \(outdated) Packages") { Task { await care.store.updateAll() } }
                        .disabled(care.store.busy != nil)
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 12)
            if filter == .leftovers {
                LeftoverList(care: care)
            } else {
            ScrollView {
                CareSection(filter.rawValue) {
                    ForEach(shown) { app in
                        VStack(alignment: .leading, spacing: 0) {
                        CareRow(icon: icon(app), title: app.name, detail: detail(app),
                            value: app.size.map { Store.bytes($0) } ?? "…",
                            flag: app.declared == nil ? "Not in Brewfile" : nil) {
                            Button { expanded = expanded == app.id ? nil : app.id } label: {
                                Image(systemName: expanded == app.id ? "chevron.up" : "chevron.down")
                                    .accessibilityLabel("Show what uninstalling removes")
                            }
                            .controlSize(.small)
                            .help("Show what uninstalling removes")
                            if app.source == .other, app.declared == nil, let token = care.casks[app.url.lastPathComponent] {
                                Button("Adopt") { Task { await care.adopt(app) } }
                                    .controlSize(.small)
                                    .help("Install as cask \(token) over this copy, and add it to the Brewfile")
                                    .gatedOnBusy(care.store)
                            }
                            Button("Uninstall") { Task { await care.uninstall(app); care.orphans = nil } }
                                .controlSize(.small)
                                .help("Uninstall (\(removalVerb(care.store)))")
                                .gatedOnBusy(care.store)
                            Menu {
                                Button("Reset \(app.name)…") { Task { await care.reset(app) } }
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }
                            } label: {
                                Image(systemName: "ellipsis.circle").accessibilityLabel("More")
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .help("Reset \(app.name) (\(care.store.deletesPermanently ? "deletes" : "trashes") its settings, caches and data, and keeps the app) or Show in Finder")
                            .gatedOnBusy(care.store)
                        }
                        if expanded == app.id { AppFiles(care: care, app: app) }
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 70)
            }
            }
        }
    }

    private var total: Int64 { care.apps.reduce(0) { $0 + ($1.size ?? 0) } }

    private var shown: [InstalledApp] {
        let list = switch filter {
        case .all: care.apps
        case .undeclared: care.undeclared
        case .unused: care.unused
        case .leftovers: [InstalledApp]()
        }
        return list.sorted { ($0.size ?? 0) > ($1.size ?? 0) }
    }

    @ViewBuilder private func icon(_ app: InstalledApp) -> some View {
        if let image = care.icons[app.id] {
            Image(nsImage: image).resizable().frame(width: 34, height: 34)
        } else {
            SymbolTile(symbol: "app.fill", colors: Tint.gray, size: 32)
        }
    }

    private func detail(_ app: InstalledApp) -> String {
        let source = switch (app.source, app.declared) {
        case (_, let item?): "Brewfile · \(item.resource)"
        case (.cask(let token), nil): "Homebrew cask \(token)"
        case (.appStore, nil): "App Store"
        default: "Installed by hand"
        }
        // Spotlight keeps no use date for some apps in daily use.
        let when = app.lastUsed.map { " · last used " + relativeDate($0) } ?? app.added.map { " · added " + relativeDate($0) } ?? ""
        return source + when
    }
}

/// The app and every file of its that uninstalling moves to the Trash,
/// each with its size, as CleanMyMac's uninstaller lists them.
private struct AppFiles: View {
    @Bindable var care: Care
    let app: InstalledApp
    @State private var files: [LargeFile]?

    var body: some View {
        Group {
            if let files {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(files) { file in
                        HStack {
                            Text((file.url.path as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(Store.bytes(file.size)).monospacedDigit().foregroundStyle(.secondary)
                            Button { NSWorkspace.shared.activateFileViewerSelecting([file.url]) } label: { Image(systemName: "magnifyingglass") }
                                .buttonStyle(.borderless)
                                .help("Show in Finder")
                                .accessibilityLabel("Show in Finder")
                        }
                        .contextMenu { if file.url != app.url { IgnoreMenu(store: care.store, url: file.url) } }
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .font(.callout)
        .padding(.leading, 56)
        .padding(.trailing, 14)
        .padding(.bottom, 8)
        .task(id: [app.id] + care.store.ignoreList.paths) {
            let app = app, home = NSHomeDirectory(), ignore = care.store.ignoreList, installed = care.installedIDs
            let found = await Task.detached(priority: .userInitiated) {
                Leftovers.files(of: app, home: home, ignoring: ignore, installed: installed)
            }.value
            // A newer task owns `files` once this one is cancelled.
            guard !Task.isCancelled else { return }
            files = found
        }
    }
}

/// What removed apps left in the Library, to pick and trash.
private struct LeftoverList: View {
    @Bindable var care: Care
    @State private var picked: Set<String> = []

    var body: some View {
        ScrollView {
            CareSection("Leftovers of Removed Apps") {
                if let orphans = care.orphans {
                    if orphans.isEmpty {
                        Text("No app left files behind.").foregroundStyle(.secondary).padding(10)
                    }
                    ForEach(orphans) { o in
                        HStack(spacing: 10) {
                            Toggle("", isOn: Binding(get: { picked.contains(o.id) },
                                                     set: { on in if on { picked.insert(o.id) } else { picked.remove(o.id) } }))
                                .toggleStyle(.checkbox)
                                .labelsHidden()
                            CareRow(icon: SymbolTile(symbol: "folder.badge.questionmark", colors: Tint.gray, size: 32),
                                title: o.bundleID,
                                detail: o.paths.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: " · "),
                                value: Store.bytes(o.size)) {
                                Button { NSWorkspace.shared.activateFileViewerSelecting(o.paths.map(URL.init(fileURLWithPath:))) } label: {
                                    Image(systemName: "magnifyingglass").accessibilityLabel("Show in Finder")
                                }
                                .controlSize(.small)
                                .help("Show in Finder")
                            }
                        }
                        .padding(.leading, 8)
                    }
                    HStack {
                        Text("Named for apps macOS no longer knows. Check before removing: a command-line tool may still use its settings.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(care.store.deletesPermanently ? "Delete \(picked.count)" : "Move \(picked.count) to Trash") {
                            Task {
                                await care.trashOrphans(orphans.filter { picked.contains($0.id) })
                                picked.formIntersection(care.orphans?.map(\.id) ?? [])
                            }
                        }
                        .controlSize(.small)
                        .disabled(picked.isEmpty || care.store.busy != nil)
                    }
                    .padding(10)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking through the Library…").foregroundStyle(.secondary)
                    }
                    .padding(10)
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 70)
        }
        .task(id: care.orphans == nil) { if care.orphans == nil { await care.loadOrphans() } }
    }
}
