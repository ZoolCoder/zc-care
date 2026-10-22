import AppKit
import SwiftUI
import ZCCareCore

// MARK: My Tools

private struct Tool: Identifiable {
    let title: String
    let detail: String
    let symbol: String
    let colors: [Color]
    var button = "Open"
    var isNew = false
    let run: @MainActor () -> Void
    var id: String { title }
}

/// CleanMyMac's My Tools: every tool as a card, to search and open.
struct MyTools: View {
    @Bindable var care: Care
    @State private var search = ""

    var body: some View {
        VStack(spacing: 0) {
            CareHeader(title: "My Tools", subtitle: "Every tool in one place")
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search Tools", text: $search).textFieldStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.white.opacity(0.1)))
            .frame(maxWidth: 320)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.bottom, 14)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 14)], spacing: 14) {
                    ForEach(shown) { ToolCard(tool: $0, busy: care.store.busy != nil) }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 70)
            }
        }
    }

    private var shown: [Tool] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? tools : tools.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.detail.localizedCaseInsensitiveContains(q) }
    }

    private var tools: [Tool] {
        let care = care
        let mail = Junk.spots(home: NSHomeDirectory()).first { $0.id == "mail" }
        return [
            Tool(title: "Screen Cleaning Mode", detail: "Keyboard locks and screens go black, so nothing types while you wipe.",
                 symbol: "display", colors: Tint.blue, isNew: true) { ScreenCleaner.shared.start() },
            Tool(title: "AI Clutter", detail: "Remove AI tool caches, logs, temp files and old versions you no longer need.",
                 symbol: "brain.head.profile", colors: Tint.violet, button: "Review", isNew: true) { care.open(.cleanup) },
            Tool(title: "System Junk", detail: "Clear caches, logs and build output that come back on their own.",
                 symbol: "trash.fill", colors: Tint.green, button: "Review") { care.open(.cleanup) },
            Tool(title: "Mail Attachments", detail: "Remove attachment copies Mail saved on opening; the mail keeps them.",
                 symbol: "paperclip", colors: Tint.blue, button: "Clean", isNew: true) {
                if let mail { Task { await care.store.clean(mail) } }
                else { care.store.message = Store.Message(text: "Mail has no attachments here", failed: false) }
            },
            Tool(title: "Trash Bins", detail: "Empty the Trash; what is in it is deleted for good.", symbol: "xmark.bin.fill", colors: Tint.gray,
                 button: "Empty") { Task { await care.store.emptyTrash() } },
            Tool(title: "Large and Old Files", detail: "Find big files and downloads you have not opened in months.",
                 symbol: "folder.fill", colors: Tint.cyan, button: "Review") { care.open(.clutter) },
            Tool(title: "Duplicate Finder", detail: "Find copies of the same file and keep one.",
                 symbol: "doc.on.doc.fill", colors: Tint.cyan, button: "Review") { care.open(.clutter) },
            Tool(title: "Downloads", detail: "Review one-time files and installers left in Downloads.",
                 symbol: "arrow.down.circle.fill", colors: Tint.cyan, button: "Review") { care.open(.clutter) },
            Tool(title: "Space Lens", detail: "See what fills your home folder as a map.",
                 symbol: "chart.pie.fill", colors: Tint.violet) { care.open(.spaceLens) },
            Tool(title: "Cloud Cleanup", detail: "Remove downloads of cloud files and keep them in the cloud.",
                 symbol: "icloud.fill", colors: Tint.blue, isNew: true) { care.open(.cloud) },
            Tool(title: "App Uninstaller", detail: "Remove apps with everything they keep in the Library.",
                 symbol: "xmark.app.fill", colors: Tint.blue) { care.open(.apps) },
            Tool(title: "App Leftovers", detail: "Clear what apps you removed left behind.",
                 symbol: "puzzlepiece.extension.fill", colors: Tint.blue) { care.open(.apps) },
            Tool(title: "App Updater", detail: "Update every outdated Homebrew package.",
                 symbol: "arrow.up.circle.fill", colors: Tint.blue, button: "Update") { Task { await care.store.updateAll() } },
            Tool(title: "Maintenance Tasks", detail: "Free RAM, flush DNS, reindex Spotlight and more.",
                 symbol: "wrench.and.screwdriver.fill", colors: Tint.orange) { care.open(.performance) },
            Tool(title: "Login Items", detail: "Choose what starts with your Mac.", symbol: "power", colors: Tint.orange) { care.open(.performance) },
            Tool(title: "Time Machine Snapshots", detail: "Thin local snapshots that hold space Time Machine already backed up.",
                 symbol: "clock.arrow.circlepath", colors: Tint.orange, button: "Thin") {
                if care.maintenance.isEmpty { care.loadMaintenance() }
                if let task = care.maintenance.first(where: { $0.id == "snapshots" }) { Task { await care.run(task) } }
            },
            Tool(title: "Background Items", detail: "See what runs unseen and turn it off.",
                 symbol: "gearshape.2.fill", colors: Tint.pink) { care.open(.protection) },
            Tool(title: "Malware Finder", detail: "Check every app's signature with Gatekeeper.",
                 symbol: "ladybug.fill", colors: Tint.pink) { care.open(.protection) },
            Tool(title: "Application Permissions", detail: "Review which apps can use the camera, the screen and your files.",
                 symbol: "lock.fill", colors: Tint.pink) { care.open(.protection) },
            Tool(title: "Project Dependencies", detail: "Clear node_modules and virtualenvs of projects left alone.",
                 symbol: "shippingbox.fill", colors: Tint.cyan, button: "Review") { care.open(.developer) },
            Tool(title: "Docker", detail: "Prune the build cache and dangling images Docker keeps.",
                 symbol: "shippingbox.and.arrow.backward.fill", colors: Tint.blue, button: "Review") { care.open(.developer) },
            Tool(title: "Xcode", detail: "Clear derived data, device support and simulators.",
                 symbol: "hammer.fill", colors: Tint.blue, button: "Review") { care.open(.developer) },
            Tool(title: "Local AI Models", detail: "Remove Ollama, LM Studio and Hugging Face models you no longer run.",
                 symbol: "brain.fill", colors: Tint.cyan, button: "Review") { care.open(.developer) },
        ]
    }
}

private struct ToolCard: View {
    let tool: Tool
    let busy: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                SymbolTile(symbol: tool.symbol, colors: tool.colors, size: 44)
                Spacer()
                if tool.isNew {
                    Text("New").font(.caption2.weight(.bold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(Color.white.opacity(0.18)))
                }
            }
            Text(tool.title).font(.headline).padding(.top, 4)
            Text(tool.detail).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(tool.button, action: tool.run).disabled(busy)
        }
        .frame(height: 190)
        .modifier(Glass())
    }
}
