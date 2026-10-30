import AppKit
import SwiftUI
import ZCCareCore

/// The Care window: CleanMyMac's Smart Care, over this Mac and its
/// zc-care config. A sidebar of modules, glass cards, a round button.
@MainActor
final class CareWindow: NSObject, NSWindowDelegate {
    let care: Care
    private var window: NSWindow?

    init(store: Store) {
        care = Care(store: store)
    }

    func show(_ module: Care.Module? = nil) {
        if let module { care.module = module }
        let window = self.window ?? make()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        if !care.fresh, !care.scanning { Task { await care.scan() } }
    }

    private func make() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 660),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.title = "ZC Care"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 900, height: 600)
        let host = NSHostingController(rootView: CareView(care: care))
        // The window keeps the size its owner gives it, whatever a module holds.
        host.sizingOptions = []
        window.contentViewController = host
        window.setContentSize(NSSize(width: 1000, height: 660))
        window.center()
        window.setFrameAutosaveName("ZCCare")
        return window
    }
}

struct CareView: View {
    @Bindable var care: Care

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(care: care)
            ZStack(alignment: .bottom) {
                Group {
                    if care.showsIntro(care.module) {
                        ModuleIntro(care: care, module: care.module)
                    } else {
                        switch care.module {
                        case .smartCare: SmartCareView(care: care)
                        case .cleanup: CleanupView(care: care)
                        case .clutter: ClutterView(care: care)
                        case .developer: DeveloperView(care: care)
                        case .apps: ApplicationsView(care: care)
                        case .performance: PerformanceView(care: care)
                        case .protection: ProtectionView(care: care)
                        case .spaceLens: SpaceLensView(care: care)
                        case .cloud: CloudCleanupView(care: care)
                        case .workstation: MyWorkstation(care: care)
                        case .tools: MyTools(care: care)
                        case .activity: MyActivity(care: care)
                        }
                    }
                }
                // minHeight 0: a module taller than the window must not push the window's content.
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
                Toast(store: care.store).padding(.bottom, 14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
        .sheet(item: $care.review) { ReviewSheet(prompt: $0) }
        .sheet(item: $care.quitRequest) { QuitSheet(prompt: $0) }
        .sheet(isPresented: Binding(get: { care.completed != nil }, set: { if !$0 { care.completed = nil } })) {
            if let log = care.completed { CompletionSheet(log: log) { care.completed = nil } }
        }
        .tint(Theme.accent)
        .buttonStyle(PillButtonStyle())
        .background(CareBackground(look: care.module.look).ignoresSafeArea())
        .animation(.easeInOut(duration: 0.35), value: care.module)
        .ignoresSafeArea()
    }
}

/// The same navy floor in every module; the module's colour shows only
/// as a faint light from the top right.
private struct CareBackground: View {
    let look: ModuleLook

    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.floor, Theme.hex(0x0C1538)], startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [look.glow.opacity(0.10), .clear], center: .topTrailing, startRadius: 0, endRadius: 560)
        }
        .drawingGroup()
    }
}

/// How a module looks: its floor, its tint and what its intro says.
struct ModuleLook {
    var floor: [Color]
    var glow: Color
    var tint: [Color]
    var title: String
    var pitch: String
    var features: [(symbol: String, title: String)]
}

extension Care.Module {
    var look: ModuleLook {
        switch self {
        case .smartCare:
            ModuleLook(floor: [rgb(0.22, 0.05, 0.36), rgb(0.42, 0.08, 0.52), rgb(0.62, 0.12, 0.58)], glow: rgb(1, 0.35, 0.8),
                       tint: Tint.pink, title: "Smart Care", pitch: "Quick maintenance that takes care of the essentials.",
                       features: [("magnifyingglass", "Junk and Clutter Scan"), ("arrow.down.circle.fill", "Homebrew Updates"),
                                  ("checkmark.shield.fill", "Health Check")])
        case .cleanup:
            ModuleLook(floor: [rgb(0.03, 0.22, 0.12), rgb(0.06, 0.36, 0.16), rgb(0.22, 0.42, 0.08)], glow: rgb(0.3, 0.9, 0.45),
                       tint: Tint.green, title: "Junk Cleanup", pitch: "Clear caches, logs and build output to win back free space.",
                       features: [("trash.fill", "System Junk"), ("brain.head.profile", "AI Clutter"),
                                  ("hammer.fill", "Developer Caches"), ("xmark.bin.fill", "Trash Bins")])
        case .protection:
            ModuleLook(floor: [rgb(0.40, 0.04, 0.32), rgb(0.58, 0.10, 0.48), rgb(0.36, 0.02, 0.22)], glow: rgb(1, 0.35, 0.75),
                       tint: Tint.pink, title: "Protection", pitch: "Check your Mac for risky settings and apps that run unseen.",
                       features: [("checkmark.shield.fill", "Security Settings"), ("gearshape.2.fill", "Background Items"),
                                  ("lock.fill", "Application Permissions")])
        case .performance:
            ModuleLook(floor: [rgb(0.62, 0.24, 0.06), rgb(0.70, 0.18, 0.08), rgb(0.42, 0.07, 0.05)], glow: rgb(1, 0.55, 0.2),
                       tint: Tint.orange, title: "Performance", pitch: "Keep your Mac in top shape with recommended maintenance.",
                       features: [("wrench.and.screwdriver.fill", "Maintenance Tasks"), ("power", "Login Items"),
                                  ("cpu", "Background Apps")])
        case .apps:
            ModuleLook(floor: [rgb(0.04, 0.10, 0.36), rgb(0.08, 0.20, 0.55), rgb(0.26, 0.14, 0.55)], glow: rgb(0.25, 0.55, 1),
                       tint: Tint.blue, title: "Applications", pitch: "Uninstall, update and adopt apps, and clear what old ones left.",
                       features: [("xmark.app.fill", "App Uninstaller"), ("arrow.up.circle.fill", "Homebrew Updater"),
                                  ("puzzlepiece.extension.fill", "File Leftovers"), ("shippingbox.fill", "Brewfile Adoption")])
        case .clutter:
            ModuleLook(floor: [rgb(0.0, 0.22, 0.26), rgb(0.02, 0.34, 0.34), rgb(0.0, 0.20, 0.28)], glow: rgb(0.15, 0.8, 0.65),
                       tint: Tint.cyan, title: "My Clutter", pitch: "Sort through your files and reduce the mess in a few clicks.",
                       features: [("folder.fill", "Large Files"), ("doc.on.doc.fill", "Duplicates"),
                                  ("arrow.down.circle.fill", "Old Downloads"), ("opticaldiscdrive.fill", "Installers")])
        case .spaceLens:
            ModuleLook(floor: [rgb(0.14, 0.04, 0.36), rgb(0.24, 0.06, 0.50), rgb(0.32, 0.10, 0.58)], glow: rgb(0.55, 0.35, 1),
                       tint: Tint.violet, title: "Space Lens", pitch: "See what fills your home folder and clear the biggest at once.",
                       features: [("chart.pie.fill", "Visual Storage Map"), ("folder.fill", "Large Folders Overview")])
        case .cloud:
            ModuleLook(floor: [rgb(0.05, 0.16, 0.42), rgb(0.10, 0.30, 0.62), rgb(0.16, 0.42, 0.72)], glow: rgb(0.4, 0.7, 1),
                       tint: Tint.blue, title: "Cloud Cleanup", pitch: "Free the space your cloud files take here and keep them in the cloud.",
                       features: [("icloud.fill", "iCloud Drive"), ("externaldrive.fill.badge.icloud", "Google Drive"),
                                  ("cloud.fill", "OneDrive"), ("shippingbox.fill", "Dropbox")])
        case .developer:
            ModuleLook(floor: [rgb(0.04, 0.10, 0.18), rgb(0.06, 0.20, 0.30), rgb(0.08, 0.28, 0.36)], glow: rgb(0.2, 0.75, 0.95),
                       tint: Tint.cyan, title: "Developer", pitch: "Win back what idle projects and local AI models hold.",
                       features: [("shippingbox.fill", "Idle Project Dependencies"), ("brain.fill", "Local AI Models")])
        case .workstation:
            ModuleLook(floor: [rgb(0.03, 0.10, 0.14), rgb(0.05, 0.20, 0.24), rgb(0.07, 0.30, 0.30)], glow: rgb(0.3, 0.9, 0.8),
                       tint: Tint.green, title: "My Workstation", pitch: "What your config declares, and what is in place.", features: [])
        case .tools:
            ModuleLook(floor: [rgb(0.08, 0.07, 0.20), rgb(0.16, 0.11, 0.32), rgb(0.26, 0.13, 0.40)], glow: rgb(0.6, 0.45, 1),
                       tint: Tint.violet, title: "My Tools", pitch: "Every tool in one place.", features: [])
        case .activity:
            ModuleLook(floor: [rgb(0.03, 0.08, 0.24), rgb(0.06, 0.16, 0.40), rgb(0.12, 0.10, 0.42)], glow: rgb(0.35, 0.6, 1),
                       tint: Tint.blue, title: "My Activity", pitch: "How your Mac is doing and what ZC Care did.", features: [])
        }
    }
}

private func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r, green: g, blue: b) }

// MARK: Sidebar

private struct Sidebar: View {
    @Bindable var care: Care

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                BrandMark.image(size: 22).foregroundStyle(.white)
                Text("ZC Care").font(.title3.weight(.bold))
            }
            .padding(.horizontal, 10)
            .padding(.top, 44)
            .padding(.bottom, 18)
            ForEach(Array(Care.Module.modules.enumerated()), id: \.element) { i, m in
                row(m, key: KeyEquivalent(Character("\(i + 1)")))
            }
            Spacer().frame(height: 14)
            ForEach(Care.Module.extras) { row($0) }
            Spacer()
            SidebarRow(title: "Menu Panel", symbol: "menubar.rectangle", badge: nil, selected: false) {
                NSApp.sendAction(#selector(AppDelegate.showPanel), to: nil, from: nil)
            }
            SidebarRow(title: "Settings", symbol: "gearshape", badge: nil, selected: false) {
                care.store.openSettings?()
            }
        }
        .padding(10)
        .padding(.bottom, 8)
        .frame(width: 210)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar.ignoresSafeArea())
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.divider).frame(width: 1) }
    }

    /// The first nine modules open with ⌘1 to ⌘9, as tabs do.
    private func row(_ m: Care.Module, key: KeyEquivalent? = nil) -> some View {
        SidebarRow(title: m.rawValue, symbol: m.symbol, tint: m.look.tint, badge: badge(m), selected: care.module == m) {
            care.module = m
        }
        .keyboardShortcut(key.map { KeyboardShortcut($0) })
    }

    private func badge(_ m: Care.Module) -> String? {
        guard care.scannedAt != nil else { return nil }
        switch m {
        case .smartCare, .tools: return nil
        case .workstation:
            let n = care.store.snapshot?.targets.map(\.gaps).reduce(0, +) ?? 0
            return n > 0 ? "\(n)" : nil
        case .activity:
            let n = care.recommendations.count
            return n > 0 ? "\(n)" : nil
        case .cleanup: return care.junk + care.ai > 0 ? Store.bytes(care.junk + care.ai) : nil
        case .clutter: return care.clutter > 0 ? Store.bytes(care.clutter) : nil
        case .developer: return care.developer > 0 ? Store.bytes(care.developer) : nil
        case .apps:
            let n = care.store.snapshot?.outdated.count ?? 0
            return n > 0 ? "\(n)" : nil
        case .performance: return care.startup.isEmpty ? nil : "\(care.startup.count)"
        case .protection: return care.untrusted.isEmpty ? nil : "\(care.untrusted.count)"
        case .spaceLens: return care.space.map { Store.bytes($0.root.size) }
        case .cloud:
            let n = care.cloud?.reduce(0) { $0 + $1.downloaded } ?? 0
            return n > 0 ? Store.bytes(n) : nil
        }
    }
}

private struct SidebarRow: View {
    let title: String
    let symbol: String
    var tint: [Color]?
    let badge: String?
    let selected: Bool
    let action: () -> Void
    @State private var over = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if selected, let tint {
                    SymbolTile(symbol: symbol, colors: tint, size: 22).frame(width: 20)
                } else {
                    Image(systemName: symbol).frame(width: 20)
                }
                Text(title).lineLimit(1).layoutPriority(1)
                Spacer(minLength: 4)
                if let badge {
                    Text(badge).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            .font(.callout.weight(selected ? .semibold : .regular))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(selected ? Theme.selected : Color.white.opacity(over ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { over = $0 }
        .help(badge.map { "\(title): \($0)" } ?? title)
    }
}
