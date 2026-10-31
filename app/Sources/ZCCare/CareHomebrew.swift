import SwiftUI
import ZCCareCore

/// Homebrew's own housekeeping: dependencies nothing needs, what cleanup
/// would free, and what `brew doctor` warns about. Reading runs dry runs
/// only; removing asks first.
struct HomebrewSection: View {
    let care: Care
    @State private var unneeded: [String] = []
    /// Kept because the config names them, or because a kept one needs them.
    @State private var kept: [String] = []
    @State private var needed: [String] = []
    @State private var reclaimable: Int64?
    @State private var warnings: [BrewWarning] = []
    @State private var open: String?
    @State private var loaded = false
    @State private var configUnread = false
    @State private var aliases: [String: Set<String>] = [:]
    /// The dry runs that failed, so their rows do not read as all clear.
    @State private var unread: Set<String> = []
    /// Bumped by each load; a load that finds a newer one leaves the state alone.
    @State private var generation = 0

    private var brew: String? { care.store.program("brew") }

    var body: some View {
        // A stack, not a Group: SwiftUI starts no task on a Group with nothing in it.
        VStack(spacing: 0) {
            if brew != nil && loaded { section }
        }
        .task(id: care.scanningDeveloper) { if !care.scanningDeveloper { await load() } }
    }

    private var section: some View {
        CareSection("Homebrew") {
            CareRow(icon: SymbolTile(symbol: "puzzlepiece.extension.fill", colors: Tint.orange, size: 32),
                    title: "Unneeded Dependencies",
                    detail: unneededDetail,
                    value: unneeded.isEmpty ? "" : Store.counted(unneeded.count, "formula", "formulae")) {
                if !unneeded.isEmpty {
                    Button("Remove…") { Task { await remove() } }
                        .controlSize(.small)
                        .help("Uninstall the formulae nothing installed depends on")
                        .gatedOnBusy(care.store)
                }
            }
            CareRow(icon: SymbolTile(symbol: "mug.fill", colors: Tint.orange, size: 32),
                    title: "Downloads and Old Versions",
                    detail: unread.contains("cleanup") ? "Homebrew could not be read."
                        : reclaimable == nil ? "Nothing to clean up." : "Cached downloads and versions newer ones replaced.",
                    value: reclaimable.map { Store.bytes($0) } ?? "") {
                if reclaimable != nil, let task = care.maintenance.first(where: { $0.id == "brew" }) {
                    Button("Clean Up…") { Task { await care.run(task); await load() } }
                        .controlSize(.small)
                        .gatedOnBusy(care.store)
                }
            }
            CareRow(icon: SymbolTile(symbol: "stethoscope", colors: warnings.isEmpty ? Tint.green : Tint.orange, size: 32),
                    title: "Doctor",
                    detail: unread.contains("doctor") ? "brew doctor could not run."
                        : warnings.isEmpty ? "Homebrew reports no problems." : "Homebrew's own checks; ZC Care changes nothing here.",
                    value: warnings.isEmpty ? "" : Store.counted(warnings.count, "warning")) {}
            ForEach(warnings) { warning in warningRow(warning) }
        }
    }

    private var unneededDetail: String {
        if unread.contains("autoremove") { return "Homebrew could not be read." }
        // Unsure what the config names or needs, nothing is offered.
        if unread.contains("info") || unread.contains("deps") { return "Homebrew could not tell what your config needs." }
        var parts: [String] = []
        if !unneeded.isEmpty || (kept.isEmpty && needed.isEmpty) {
            parts.append(unneeded.isEmpty ? "Every installed dependency is still needed." : unneeded.joined(separator: ", "))
        }
        if !kept.isEmpty {
            parts.append((configUnread ? "Kept, the config could not be read: " : "Kept, your config names them: ") + kept.joined(separator: ", "))
        }
        if !needed.isEmpty { parts.append("Kept, a formula your config names needs them: " + needed.joined(separator: ", ")) }
        return parts.joined(separator: ". ")
    }

    private func warningRow(_ warning: BrewWarning) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { open = open == warning.id ? nil : warning.id } label: {
                HStack(spacing: 6) {
                    Image(systemName: open == warning.id ? "chevron.down" : "chevron.right").font(.caption)
                    Text(warning.title).font(.callout).multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open == warning.id, !warning.detail.isEmpty {
                Text(warning.detail)
                    .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 18)
            }
        }
        .padding(.vertical, 6)
        .padding(.leading, 56)
    }

    private var env: [String: String] { care.store.loginEnv.merging(Homebrew.quiet) { $1 } }

    private func load() async {
        guard let brew else { return }
        generation += 1
        let mine = generation
        let env = env
        async let autoremove = try? ProcessRunner(timeout: 120).run(brew, ["autoremove", "--dry-run"], env: env)
        async let cleanup = try? ProcessRunner(timeout: 120).run(brew, ["cleanup", "--dry-run", "--prune=all"], env: env)
        async let doctor = try? ProcessRunner(timeout: 120).run(brew, ["doctor"], env: env)
        let declared = await declaredFormulae()
        let auto = await autoremove, clean = await cleanup, d = await doctor
        let all = Homebrew.unneeded(auto?.output ?? "")
        var aliases: [String: Set<String>] = [:]
        var failed: Set<String> = []
        if !all.isEmpty, declared?.isEmpty == false {
            // Without aliases a formula the config names as python3 would look
            // unnamed: unread, nothing is offered.
            let info = try? await ProcessRunner(timeout: 60).run(brew, ["info", "--json=v2", "--formula", "--"] + all, env: env)
            aliases = info.flatMap { $0.status == 0 ? Homebrew.aliases($0.stdout) : nil } ?? [:]
            if aliases.isEmpty { failed.insert("info") }
        }
        let named = failed.isEmpty ? declared.map { Homebrew.removable(all, declared: $0, aliases: aliases) } ?? [] : []
        var removable = named
        let keptNames = all.filter { !named.contains($0) }
        if failed.isEmpty, !keptNames.isEmpty, !removable.isEmpty {
            // Unread, nothing is offered: brew would refuse the lot anyway.
            let deps = try? await ProcessRunner(timeout: 60).run(brew, ["deps", "--union", "--full-name", "--formula", "--"] + keptNames, env: env)
            if let deps, deps.status == 0 {
                removable = Homebrew.sparing(removable, dependencies: deps.output)
            } else {
                removable = []
                failed.insert("deps")
            }
        }
        // A newer load, or the scan that cancelled this one, owns the state.
        guard !Task.isCancelled, mine == generation else { return }
        self.aliases = aliases
        unneeded = removable
        kept = failed.isEmpty ? keptNames : []
        needed = failed.isEmpty ? named.filter { !removable.contains($0) } : []
        configUnread = declared == nil
        reclaimable = Homebrew.reclaimable(clean?.output ?? "")
        warnings = Homebrew.warnings((d?.output ?? "") + "\n" + (d?.stderr ?? ""))
        unread = failed.union([auto?.status == 0 ? nil : "autoremove", clean?.status == 0 ? nil : "cleanup", d == nil ? "doctor" : nil].compactMap { $0 })
        if loaded == false { loaded = true }
    }

    /// The formulae the config declares; empty without a config, nil when
    /// it could not be read, so nothing it may name is offered.
    private func declaredFormulae() async -> Set<String>? {
        let store = care.store
        guard store.cli != nil else { return [] }
        if store.inventory == nil || store.inventoryError != nil { await store.loadWorkstation() }
        guard store.inventoryError == nil, let inventory = store.inventory else { return nil }
        return Self.formulae(in: inventory)
    }

    private static func formulae(in inventory: [Item]) -> Set<String> {
        Set(inventory.filter { $0.kind == "brew" && $0.state != "not declared" }.map(\.name))
    }

    private func remove() async {
        let store = care.store
        // Taken before the dialog: a load finishing while it is open must
        // not change what was confirmed.
        let names = unneeded
        guard let brew, store.busy == nil, !names.isEmpty,
              Alerts.confirm("Remove \(Store.counted(names.count, "formula", "formulae"))?",
                             "Uninstalls \(names.joined(separator: ", ")). Nothing installed depends on them; `brew install` brings one back.",
                             button: "Remove") else { return }
        // The config lives outside the app and may have changed since the
        // list was read: read it again, and stop if it now names one of these.
        if let cli = store.cli {
            let fresh = try? await cli.items()
            guard let fresh, Homebrew.removable(names, declared: Self.formulae(in: fresh), aliases: aliases) == names else {
                store.message = Store.Message(text: "Your config changed or could not be read; check the list again.", failed: true)
                await load()
                return
            }
        }
        guard store.busy == nil else { return }
        store.busy = "Remove unneeded formulae"
        defer { store.busy = nil }
        let failed = await store.failure("brew uninstall failed") {
            try await ProcessRunner(timeout: 600).run(brew, ["uninstall", "--formula", "--"] + names, env: env)
        }
        if failed == nil { store.record(.developer, "Removed \(Store.counted(names.count, "unneeded formula", "unneeded formulae"))") }
        store.message = failed.map { Store.Message(text: "Remove unneeded formulae: \($0)", failed: true) }
            ?? Store.Message(text: "Removed \(names.joined(separator: ", ")).", failed: false)
        await load()
        await store.refresh()
    }
}
