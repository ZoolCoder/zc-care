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
                                Button("Move \(picked.count) to Trash") {
                                    Task {
                                        await care.trashDependencies(care.dependencies.filter { picked.contains($0.id) })
                                        picked.formIntersection(care.dependencies.map(\.id))
                                    }
                                }
                                .controlSize(.small)
                                .disabled(picked.isEmpty || care.store.busy != nil)
                            }
                            .padding(10)
                        }
                    }
                    if !care.xcodeSpots.isEmpty { xcode }
                    if let usage = care.docker, !usage.isEmpty { docker(usage) }
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
                                Button("Trash") { Task { await care.trash(model) } }
                                    .controlSize(.small)
                                    .disabled(care.store.busy != nil)
                            }
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 70)
            }
        }
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
                    Button("Trash") { Task { await care.trash(spot) } }
                        .controlSize(.small)
                        .disabled(care.store.busy != nil)
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
                Text("Pruning removes what no container uses; images are pulled or built again.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Prune Build Cache") {
                    Task {
                        await care.pruneDocker("Prune Docker build cache", arguments: Docker.pruneBuildCache,
                                               what: "Removes Docker's build cache. The next build is slower and rebuilds it.")
                    }
                }
                .controlSize(.small)
                .disabled(care.store.busy != nil)
                Button("Prune Dangling Images") {
                    Task {
                        await care.pruneDocker("Prune dangling Docker images", arguments: Docker.pruneDanglingImages,
                                               what: "Removes images with no tag and no container. Tagged images stay.")
                    }
                }
                .controlSize(.small)
                .disabled(care.store.busy != nil)
            }
            .padding(10)
        }
    }

    private var subtitle: String {
        care.developer > 0 ? "\(Store.bytes(care.developer)) in idle project dependencies and local AI models"
            : "Idle project dependencies and local AI models"
    }
}
