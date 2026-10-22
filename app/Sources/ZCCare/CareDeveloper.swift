import AppKit
import SwiftUI
import ZCCareCore

// MARK: Developer

struct DeveloperView: View {
    @Bindable var care: Care
    @State private var picked: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            CareHeader(title: "Developer", subtitle: subtitle, busy: care.scanningDeveloper,
                   action: ("Rescan", { Task { await care.scanDeveloper() } }))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    CareSection("Dependencies of Idle Projects") {
                        if care.dependencies.isEmpty {
                            Text(care.scanningDeveloper ? "Looking through your projects…"
                                 : "No project untouched for 90 days keeps its dependencies.")
                                .foregroundStyle(.secondary).padding(10)
                        }
                        ForEach(care.dependencies) { dep in
                            HStack(spacing: 10) {
                                Toggle("", isOn: Binding(get: { picked.contains(dep.id) },
                                                         set: { on in if on { picked.insert(dep.id) } else { picked.remove(dep.id) } }))
                                    .toggleStyle(.checkbox)
                                    .labelsHidden()
                                CareRow(icon: SymbolTile(symbol: "shippingbox.fill", colors: Tint.orange, size: 32),
                                    title: dep.url.deletingLastPathComponent().lastPathComponent + "/" + dep.name,
                                    detail: (dep.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
                                        + " · project changed " + relativeDate(dep.modified),
                                    value: Store.bytes(dep.size)) {
                                    Button { NSWorkspace.shared.activateFileViewerSelecting([dep.url]) } label: {
                                        Image(systemName: "magnifyingglass").accessibilityLabel("Show in Finder")
                                    }
                                    .controlSize(.small)
                                    .help("Show in Finder")
                                }
                            }
                            .padding(.leading, 8)
                        }
                        if !care.dependencies.isEmpty {
                            HStack {
                                Text("node_modules, Python virtualenvs and Rust or Maven target folders; an install brings them back.")
                                    .font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button(picked.count == care.dependencies.count ? "Select None" : "Select All") {
                                    picked = picked.count == care.dependencies.count ? [] : Set(care.dependencies.map(\.id))
                                }
                                .controlSize(.small)
                                Button(care.store.deletesPermanently ? "Delete \(picked.count)" : "Move \(picked.count) to Trash") {
                                    Task {
                                        await care.trashDependencies(care.dependencies.filter { picked.contains($0.id) })
                                    }
                                }
                                .controlSize(.small)
                                .disabled(picked.isEmpty || care.store.busy != nil)
                            }
                            .padding(10)
                        }
                    }
                    if !care.xcodeSpots.isEmpty { xcode }
                    if let usage = care.docker, !usage.isEmpty {
                        docker(usage)
                    } else if care.docker == nil, care.scannedDeveloper, dockerInstalled {
                        dockerDown
                    }
                    CareSection("Local AI Models") {
                        if care.models.isEmpty {
                            Text(care.scanningDeveloper ? "Looking for models…"
                                 : "No Ollama, LM Studio or Hugging Face models on this Mac.")
                                .foregroundStyle(.secondary).padding(10)
                        }
                        ForEach(care.models) { model in
                            CareRow(icon: SymbolTile(symbol: "brain.fill", colors: Tint.pink, size: 32),
                                title: model.name,
                                detail: model.source.rawValue + " · downloaded " + relativeDate(model.modified),
                                value: Store.bytes(model.size)) {
                                Button { NSWorkspace.shared.activateFileViewerSelecting(model.paths) } label: {
                                    Image(systemName: "magnifyingglass").accessibilityLabel("Show in Finder")
                                }
                                .controlSize(.small)
                                .help("Show in Finder")
                                Button(removalButton(care.store)) { Task { await care.trash(model) } }
                                    .controlSize(.small)
                                    .help(removalVerb(care.store))
                                    .gatedOnBusy(care.store)
                            }
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 70)
            }
        }
        .onChange(of: care.dependencies.map(\.id)) { _, ids in picked.formIntersection(ids) }
    }

    private var xcode: some View {
        CareSection("Xcode") {
            ForEach(care.xcodeSpots) { spot in
                CareRow(icon: SymbolTile(symbol: "hammer.fill", colors: Tint.blue, size: 32),
                    title: spot.title, detail: spot.detail, value: Store.bytes(spot.size)) {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([spot.url]) } label: {
                        Image(systemName: "magnifyingglass").accessibilityLabel("Show in Finder")
                    }
                    .controlSize(.small)
                    .help("Show in Finder")
                    Button(removalButton(care.store)) { Task { await care.trash(spot) } }
                        .controlSize(.small)
                        .help(removalVerb(care.store))
                        .gatedOnBusy(care.store)
                }
            }
        }
    }

    private func docker(_ usage: [DockerUsage]) -> some View {
        CareSection("Docker") {
            ForEach(usage) { item in
                CareRow(icon: SymbolTile(symbol: "shippingbox.fill", colors: Tint.cyan, size: 32),
                    title: item.type,
                    detail: "\(item.total) in all, \(item.active) in use · \(Store.bytes(item.reclaimable)) can be pruned",
                    value: Store.bytes(item.size)) { EmptyView() }
            }
            HStack {
                Text("Pruning deletes for good, there is no Trash for it. Build cache and dangling images come back when Docker builds or pulls.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Prune Build Cache") {
                    Task {
                        await care.pruneDocker("Prune Docker build cache", arguments: Docker.pruneBuildCache,
                                               what: "Deletes Docker's build cache for good; Docker has no Trash. The next build is slower and rebuilds it.")
                    }
                }
                .controlSize(.small)
                .disabled(care.store.busy != nil)
                Button("Prune Dangling Images") {
                    Task {
                        await care.pruneDocker("Prune dangling Docker images", arguments: Docker.pruneDanglingImages,
                                               what: "Deletes images with no tag and no container for good; Docker has no Trash. Tagged images stay.")
                    }
                }
                .controlSize(.small)
                .disabled(care.store.busy != nil)
            }
            .padding(10)
        }
    }

    /// The CLI is there; whether its daemon answers is what `care.docker` tells.
    private var dockerInstalled: Bool {
        care.store.program("docker") != nil
            || ["/usr/local/bin/docker", "/Applications/Docker.app/Contents/Resources/bin/docker"]
                .contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private var dockerDown: some View {
        CareSection("Docker") {
            CareRow(icon: SymbolTile(symbol: "shippingbox.fill", colors: Tint.gray, size: 32),
                title: "Docker is not running", detail: "Start Docker Desktop, then Rescan to see its images and build cache.",
                value: "") { EmptyView() }
        }
    }

    private var subtitle: String {
        let total = care.developer + care.xcodeSpots.reduce(0) { $0 + $1.size }
            + (care.docker ?? []).reduce(0) { $0 + $1.size }
        return total > 0 ? "\(Store.bytes(total)) in Xcode, Docker, idle project dependencies and local AI models"
            : "Xcode, Docker, idle project dependencies and local AI models"
    }
}
