import AppKit
import SwiftUI
import ZCCareCore

// MARK: Smart Care

struct SmartCareView: View {
    @Bindable var care: Care

    var body: some View {
        VStack(spacing: 0) {
            CareHeader(title: "Smart Care", subtitle: care.scanning ? "Looking over your Mac…" : summary)
            HStack(spacing: 14) {
                VStack(spacing: 14) {
                    CleanupCard(care: care)
                    PerformanceCard(care: care)
                }
                .frame(minWidth: 170, idealWidth: 230, maxWidth: 230)
                HealthCard(care: care)
                    .frame(minWidth: 220)
                    .layoutPriority(1)
                VStack(spacing: 14) {
                    UpdatesCard(care: care)
                    ClutterCard(care: care)
                }
                .frame(minWidth: 170, idealWidth: 230, maxWidth: 230)
            }
            .padding(.horizontal, 28)
            TuneUp(care: care)
            HStack(spacing: 18) {
                RoundButton(title: care.scanning ? "" : canRun ? "Run" : "Scan", colors: Care.Module.smartCare.look.tint,
                            working: care.scanning || care.store.busy != nil) {
                    Task { canRun ? await care.run() : await care.scan() }
                }
                .disabled(care.scanning || care.store.busy != nil)
            }
            .padding(.top, 10)
            Text(trust).font(.caption).foregroundStyle(.secondary).padding(.top, 6)
            .padding(.bottom, 12)
        }
        .onAppear { if care.maintenance.isEmpty { care.loadMaintenance() } }
    }

    private var canRun: Bool {
        care.scannedAt != nil && (care.junk + care.aiBeyondJunk > 0 || !(care.store.snapshot?.outdated.isEmpty ?? true))
    }

    /// What Run does to files, said before it is pressed: each step asks first.
    private var trust: String {
        "Nothing changes until you confirm each step. "
            + (care.store.deletesPermanently ? "Cleanup deletes for good." : "Cleanup goes to the Trash; My Activity puts it back.")
    }

    private var summary: String {
        canRun ? "Run cleans up \(Store.bytes(care.junk + care.aiBeyondJunk)) and updates \(Store.counted(care.store.snapshot?.outdated.count ?? 0, "package"))."
            : care.scannedAt != nil && care.allUpdates > 0 ? "Your Mac is in good shape; \(Store.counted(care.allUpdates, "update")) waiting in Applications."
            : "Your Mac is in good shape."
    }
}

/// Routine maintenance that is due, a click each; every task still asks
/// before it runs.
private struct TuneUp: View {
    @Bindable var care: Care

    var body: some View {
        let due = Maintenance.due(care.maintenance, log: care.store.activity)
        if !due.isEmpty {
            // Icons alone when the titles do not fit the window's width.
            ViewThatFits(in: .horizontal) {
                row(Array(due.prefix(4)), titled: true, small: false)
                row(Array(due.prefix(4)), titled: true, small: true)
                row(Array(due.prefix(4)), titled: false, small: false)
            }
            .disabled(care.store.busy != nil)
            .padding(.top, 12)
            .padding(.horizontal, 28)
        }
    }

    private func row(_ tasks: [MaintenanceTask], titled: Bool, small: Bool) -> some View {
        HStack(spacing: small ? 6 : 10) {
            Text("Tune-up").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(tasks) { task in
                Button { Task { await care.run(task) } } label: {
                    if titled {
                        Label(task.title, systemImage: task.symbol).font(small ? .caption : .callout)
                    } else {
                        Image(systemName: task.symbol).font(.callout).accessibilityLabel(task.title)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(small ? .small : .regular)
                .help(titled ? task.detail : task.title + ": " + task.detail)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// A module before its scan, as CleanMyMac opens each: the art on the
/// left, what it does on the right, Scan below.
struct ModuleIntro: View {
    @Bindable var care: Care
    let module: Care.Module

    var body: some View {
        let look = module.look
        VStack(spacing: 0) {
            Spacer()
            HStack(spacing: 40) {
                GlassPlate(symbol: module.symbol, look: look)
                    .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 0) {
                    Text(look.title).font(.system(size: 40, weight: .regular))
                    Text(look.pitch).font(.title3).foregroundStyle(.white.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                        .padding(.bottom, 26)
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(look.features, id: \.title) { f in
                            HStack(spacing: 14) {
                                SymbolTile(symbol: f.symbol, colors: look.tint, size: 28)
                                Text(f.title).font(.headline)
                            }
                        }
                    }
                }
                .frame(maxWidth: 380, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 40)
            Spacer()
            RoundButton(title: "Scan", colors: look.tint) { Task { await care.enter(module) } }
                .keyboardShortcut(.defaultAction)
                .padding(.bottom, 36)
        }
        .id(module)
        .transition(.opacity)
    }
}

/// CleanMyMac's 3D art: a frosted plate lit in the module's colour, the
/// symbol raised on it.
private struct GlassPlate: View {
    let symbol: String
    let look: ModuleLook
    var size: CGFloat = 230

    var body: some View {
        let plate = RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [look.glow.opacity(0.45), .clear], center: .center,
                                     startRadius: 0, endRadius: size * 0.75))
                .frame(width: size * 1.5, height: size * 1.5)
            plate
                .fill(LinearGradient(colors: [look.glow.opacity(0.55), (look.floor.last ?? .clear).opacity(0.85)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(plate.fill(LinearGradient(colors: [Color.white.opacity(0.35), .clear], startPoint: .top, endPoint: .center)))
                .overlay(plate.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.6), Color.white.opacity(0.08)],
                                                           startPoint: .top, endPoint: .bottom), lineWidth: 2))
                .frame(width: size, height: size)
                .rotation3DEffect(.degrees(14), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
                .shadow(color: .black.opacity(0.35), radius: 24, y: 18)
            Image(systemName: symbol)
                .font(.system(size: size * 0.36, weight: .semibold))
                .foregroundStyle(LinearGradient(colors: [.white, .white.opacity(0.7)], startPoint: .top, endPoint: .bottom))
                .shadow(color: (look.tint.last ?? .clear).opacity(0.8), radius: 12, y: 6)
        }
    }
}

/// A large glossy symbol, CleanMyMac's 3D card art.
struct HeroArt: View {
    let symbol: String
    let colors: [Color]
    var size: CGFloat = 96

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [(colors.first ?? .white).opacity(0.55), .clear],
                                     center: .center, startRadius: 0, endRadius: size * 0.7))
                .frame(width: size * 1.4, height: size * 1.4)
            RoundedRectangle(cornerRadius: size * 0.28)
                .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size, height: size)
                .overlay(RoundedRectangle(cornerRadius: size * 0.28)
                    .fill(LinearGradient(colors: [Color.white.opacity(0.45), .clear], startPoint: .top, endPoint: .center))
                    .padding(2))
                .overlay(RoundedRectangle(cornerRadius: size * 0.28).strokeBorder(Color.white.opacity(0.35)))
                .shadow(color: (colors.last ?? .clear).opacity(0.6), radius: size / 6, y: size / 14)
            Image(systemName: symbol)
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
        }
    }
}

/// One Smart Care result: an icon, a big figure and a link to the module.
/// Callers set working only while there is no figure yet: a rescan keeps
/// the last one up.
struct ResultCard: View {
    let title: String
    let symbol: String
    let colors: [Color]
    let figure: String
    let detail: String
    var working = false
    var link: (title: String, run: () -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                SymbolTile(symbol: symbol, colors: colors, size: 40)
            }
            Spacer(minLength: 0)
            Text(figure).font(.title.weight(.bold)).lineLimit(1).minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .spinning(working)
            Text(working ? "Looking…" : detail).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let link {
                Button(link.title, action: link.run).buttonStyle(.zcLink).font(.callout.weight(.semibold))
            }
        }
        .modifier(Glass())
    }
}

private struct CleanupCard: View {
    @Bindable var care: Care

    var body: some View {
        ResultCard(title: "Cleanup", symbol: "trash.fill", colors: Tint.cyan,
                   figure: Store.bytes(care.junk + care.aiBeyondJunk), detail: "of caches, logs and AI clutter",
                   working: (care.monitor.scanning || care.scanningAI) && care.junk + care.aiBeyondJunk == 0,
                   link: ("Review", { care.module = .cleanup }))
    }
}

private struct ClutterCard: View {
    @Bindable var care: Care

    var body: some View {
        ResultCard(title: "My Clutter", symbol: "doc.on.doc.fill", colors: Tint.blue,
                   figure: care.clutter > 0 ? Store.bytes(care.clutter) : care.spotlightOff ? "Not checked" : "All clear",
                   detail: care.clutter > 0 ? detail : care.spotlightOff ? "Spotlight indexing is off" : "Nothing large, old or duplicated",
                   working: care.scanningFiles && care.clutter == 0,
                   link: ("Review Files", { care.module = .clutter }))
    }

    private var detail: String {
        [care.largeFiles.isEmpty ? nil : "\(care.largeFiles.count) large",
         care.duplicates.isEmpty ? nil : "\(care.duplicates.count) duplicated",
         care.oldDownloads.isEmpty ? nil : Store.counted(care.oldDownloads.count, "old download"),
         care.diskImages.isEmpty ? nil : Store.counted(care.diskImages.count, "installer")]
            .compactMap { $0 }.joined(separator: ", ")
    }
}

private struct UpdatesCard: View {
    @Bindable var care: Care

    var body: some View {
        let outdated = care.allUpdates
        let undeclared = care.undeclared.count
        ResultCard(title: "Applications", symbol: "square.grid.2x2.fill", colors: Tint.green,
                   figure: outdated == 0 ? "Up to date" : Store.counted(outdated, "update"),
                   detail: undeclared == 0 ? "Every app is in the Brewfile" : Store.counted(undeclared, "app") + " not in the Brewfile",
                   working: (care.store.refreshing && care.store.snapshot == nil) || (care.loadingApps && care.apps.isEmpty),
                   link: ("Manage", {
                       care.showUpdates = outdated > 0
                       care.module = .apps
                   }))
    }
}

private struct PerformanceCard: View {
    @Bindable var care: Care

    var body: some View {
        ResultCard(title: "Performance", symbol: "gauge.with.dots.needle.67percent", colors: Tint.orange,
                   figure: Store.counted(care.startup.count, "startup item"),
                   detail: care.agents.contains(where: \.broken)
                       ? Store.counted(care.agents.filter(\.broken).count, "broken launch agent")
                       : Store.counted(care.background.count, "background app") + " running",
                   link: ("Review", { care.module = .performance }))
    }
}

/// The centre card: what the doctor found, security first.
private struct HealthCard: View {
    @Bindable var care: Care

    var body: some View {
        let findings = care.store.findings
        let ok = findings.isEmpty
        // Nothing read yet is not a clean bill of health.
        let unknown = care.store.snapshot == nil
        VStack(spacing: 14) {
            Text("Health").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            HeroArt(symbol: unknown ? "shield.fill" : ok ? "checkmark.shield.fill" : "exclamationmark.shield.fill",
                    colors: unknown ? Tint.gray : ok ? Tint.green : Tint.pink, size: 110)
            Text(care.store.refreshing ? "Checking health…" : ok ? "No problems found" : "\(findings.count) to look at")
                .font(.title2.weight(.bold))
            VStack(alignment: .leading, spacing: 6) {
                ForEach(findings.prefix(4)) { c in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(c.isSecurity ? Theme.bad : Theme.warning).frame(width: 7, height: 7)
                        Text(c.title).font(.callout).lineLimit(2).help(c.title)
                        Spacer()
                        if case .info = Fix(for: c) {} else {
                            Button("Fix") { Task { await care.store.fix(c) } }
                                .controlSize(.small)
                                .help(c.detail ?? "")
                                .gatedOnBusy(care.store)
                        }
                    }
                }
            }
            .frame(maxWidth: 320)
            Spacer(minLength: 0)
        }
        .modifier(Glass())
        .background(RoundedRectangle(cornerRadius: 20)
            .fill(LinearGradient(colors: [Color(red: 0.95, green: 0.35, blue: 0.75).opacity(0.25), .clear],
                                 startPoint: .bottom, endPoint: .top)))
    }
}
