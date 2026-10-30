import AppKit
import SwiftUI
import ZCCareCore

// MARK: Applications

struct ApplicationsView: View {
    @Bindable var care: Care
    @State private var filter = Filter.all
    @State private var expanded: String?
    @State private var query = ""
    @State private var picked: Set<String> = []

    enum Filter: String, CaseIterable { case all = "All", updates = "Updates", undeclared = "Not in Brewfile", unused = "Unused", intel = "Intel Only", leftovers = "Leftovers" }

    var body: some View {
        let copies = care.copies
        return VStack(spacing: 0) {
            CareHeader(title: "Applications", subtitle: "\(Store.counted(care.apps.count, "app")), \(Store.bytes(total)) in all",
                   busy: care.loadingApps, action: ("Rescan", { care.orphans = nil; care.receipts = nil; Task { await care.loadApps() } }))
            HStack {
                Picker("", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text(label($0)) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                if filter != .leftovers {
                    TextField("Search", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 100, maxWidth: 200)
                }
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
            } else if filter == .updates {
                UpdateList(care: care, query: query)
            } else {
            ScrollView {
                CareSection(filter.rawValue) {
                    if shown.isEmpty {
                        Text(query.isEmpty ? "No app here." : "No app matches \u{201C}\(query)\u{201D}.")
                            .foregroundStyle(.secondary).padding(10)
                    }
                    ForEach(shown) { app in
                        VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 10) {
                        PickBox(id: app.id, picked: $picked).padding(.leading, 8)
                        CareRow(icon: icon(app), title: app.name, detail: detail(app),
                            value: app.size.map { Store.bytes($0) } ?? "…",
                            flag: copies.contains(app.id) ? "Installed Twice" : app.declared == nil ? "Not in Brewfile" : nil) {
                            Button { expanded = expanded == app.id ? nil : app.id } label: {
                                Image(systemName: expanded == app.id ? "chevron.up" : "chevron.down")
                                    .accessibilityLabel("Show what uninstalling removes")
                            }
                            .controlSize(.small)
                            .help("Show what uninstalling removes")
                            if care.canAdopt(app), let token = care.casks[app.url.lastPathComponent] {
                                Button("Adopt") { Task { await care.adopt(app) } }
                                    .controlSize(.small)
                                    .help("Install as cask \(token) over this copy, and add it to the Brewfile")
                                    .gatedOnBusy(care.store)
                            }
                            Button("Uninstall") { Task { await care.uninstall([app]) } }
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
                        }
                        if expanded == app.id { AppFiles(care: care, app: app) }
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 70)
            }
            .safeAreaInset(edge: .bottom) { if !picked.isEmpty { selectionBar } }
            }
        }
        .onChange(of: care.apps.map(\.id)) { _, ids in picked.formIntersection(ids) }
        .onAppear(perform: takeRequest)
        .onChange(of: care.showUpdates) { takeRequest() }
        .onChange(of: care.showLeftovers) { takeRequest() }
    }

    /// What is ticked, and one button that uninstalls it app by app: each
    /// still shows what goes and asks, and No stops the rest.
    private var selectionBar: some View {
        // Only what is on screen goes: a tick the filter or search hides stays put.
        let chosen = shown.filter { picked.contains($0.id) }
        let hidden = picked.count - chosen.count
        return HStack(spacing: 12) {
            Text("\(Store.counted(chosen.count, "app")) selected · \(Store.bytes(chosen.reduce(0) { $0 + ($1.size ?? 0) }))"
                 + (hidden > 0 ? " · \(hidden) hidden" : ""))
                .font(.callout.weight(.semibold))
            Spacer()
            Button("Deselect All") { picked = [] }.controlSize(.small)
            Button("Uninstall \(chosen.count)…") {
                Task {
                    await care.uninstall(chosen)
                    picked.formIntersection(care.apps.map(\.id))
                }
            }
            .gatedOnBusy(care.store)
            .disabled(chosen.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .modifier(Card())
        .padding(.horizontal, 28)
        .padding(.bottom, 54)
    }

    /// Opens the list a notification or recommendation asked for.
    private func takeRequest() {
        if care.showUpdates {
            care.showUpdates = false
            filter = .updates
        } else if care.showLeftovers {
            care.showLeftovers = false
            filter = .leftovers
        }
    }

    private var total: Int64 { care.apps.reduce(0) { $0 + ($1.size ?? 0) } }

    private var shown: [InstalledApp] {
        let list = switch filter {
        case .all: care.apps
        case .undeclared: care.undeclared
        case .unused: care.unused
        case .intel: care.intelOnly
        case .updates, .leftovers: [InstalledApp]()
        }
        let term = query.trimmingCharacters(in: .whitespaces)
        return list.filter { term.isEmpty || $0.name.localizedCaseInsensitiveContains(term) || ($0.bundleID ?? "").localizedCaseInsensitiveContains(term) }
            .sorted { ($0.size ?? 0) > ($1.size ?? 0) }
    }

    /// A filter's name with how many it holds, once the scan has counted them.
    private func label(_ f: Filter) -> String {
        let n: Int? = switch f {
        case .all: care.apps.count
        case .undeclared: care.undeclared.count
        case .unused: care.unused.count
        case .intel: care.intelOnly.count
        case .leftovers: care.orphans?.count
        case .updates: care.updatesCheckedAt == nil ? (care.outdatedApps.isEmpty ? nil : care.outdatedApps.count) : care.updateCount
        }
        guard let n, !care.apps.isEmpty else { return f.rawValue }
        return "\(f.rawValue) \(n)"
    }

    @ViewBuilder private func icon(_ app: InstalledApp) -> some View {
        if let image = care.icons[app.id] {
            Image(nsImage: image).resizable().frame(width: 34, height: 34)
        } else {
            SymbolTile(symbol: "app.fill", colors: Tint.gray, size: 32)
        }
    }

    private func detail(_ app: InstalledApp) -> String {
        let home = NSHomeDirectory() + "/Applications/"
        let place = app.url.path.hasPrefix(home) ? "~/Applications · " : ""
        let source = switch (app.source, app.declared) {
        case (_, let item?): "Brewfile · \(item.resource)"
        case (.cask(let token), nil): "Homebrew cask \(token)"
        case (.appStore, nil): "App Store"
        default: "Installed by hand"
        }
        // Spotlight keeps no use date for some apps in daily use.
        let when = app.lastUsed.map { " · last used " + relativeDate($0) } ?? app.added.map { " · added " + relativeDate($0) } ?? ""
        return place + source + when
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
                    let parts = Leftovers.breakdown(files, app: app.url)
                    if parts.count > 1 {
                        Text(parts.map { "\($0.part) \(Store.bytes($0.size))" }.joined(separator: " · "))
                            .foregroundStyle(.secondary)
                    }
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
            let shared = care.copies.contains(app.id)
            let found = await Task.detached(priority: .userInitiated) {
                // Another copy uses the same settings and data, so only the app goes.
                shared ? [LargeFile(url: app.url, size: DiskUsage.allocated(app.url))]
                    : Leftovers.files(of: app, home: home, ignoring: ignore, installed: installed)
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
            VStack(spacing: 0) {
            CareSection("Leftovers of Removed Apps") {
                if let orphans = care.orphans {
                    if orphans.isEmpty {
                        Text("No app left files behind.").foregroundStyle(.secondary).padding(10)
                    }
                    ForEach(orphans) { o in
                        HStack(spacing: 10) {
                            PickBox(id: o.id, picked: $picked)
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
                    PickBar(store: care.store, ids: orphans.map(\.id), picked: $picked,
                            size: orphans.filter { picked.contains($0.id) }.reduce(0) { $0 + $1.size },
                            note: "Named for apps macOS no longer knows. Check before removing: a command-line tool may still use its settings.") {
                        Task { await care.trashOrphans(orphans.filter { picked.contains($0.id) }) }
                    }
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking through the Library…").foregroundStyle(.secondary)
                    }
                    .padding(10)
                }
            }
            .padding(.horizontal, 28)
            InstallerPackages(care: care)
                .padding(.horizontal, 28)
                .padding(.top, 18)
                .padding(.bottom, 70)
            }
        }
        .task(id: care.orphans == nil) { if care.orphans == nil { await care.loadOrphans() } }
    }
}
