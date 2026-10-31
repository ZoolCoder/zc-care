import AppKit
import SwiftUI
import ZCCareCore

// MARK: My Workstation

/// What the config declares and what is in place: each target's coverage,
/// every item to search, and what was applied.
struct MyWorkstation: View {
    @Bindable var care: Care
    @State private var search = ""
    @State private var open: String?

    var body: some View {
        let store = care.store
        let targets = store.snapshot?.targets ?? []
        VStack(spacing: 0) {
            CareHeader(title: "My Workstation", subtitle: "What your config declares, and what is in place right now",
                   busy: store.loadingWorkstation,
                   action: ("Refresh", { Task { await refresh(store) } }))
            if let error = store.workstationError {
                Text("Could not read your workstation. \(error)").font(.callout).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 28).padding(.top, 8)
            }
            ScrollView {
                VStack(spacing: 14) {
                    HStack(alignment: .top, spacing: 14) {
                        Coverage(targets: targets, drift: store.snapshot?.drift)
                        Actions(store: store, missing: targets.map(\.gaps).reduce(0, +))
                    }
                    .frame(height: 190)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Targets").font(.headline)
                        ForEach(targets) { t in
                            TargetRow(store: store, target: t, items: items(of: t.target), open: $open)
                        }
                    }
                    .modifier(Glass())
                    NotInConfig(store: store, items: undeclared(), targets: targets)
                    Inventory(items: store.inventory ?? [], search: $search)
                    History(entries: store.history)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 70)
            }
        }
        .task(id: store.snapshot) { await store.loadWorkstation() }
    }

    /// A failed load is not retried by a new snapshot, so Refresh retries it.
    private func refresh(_ store: Store) async {
        await store.refresh()
        if store.workstationError != nil { await store.loadWorkstation() }
    }

    private func undeclared() -> [Item] {
        (care.store.inventory ?? []).filter { $0.state == "not declared" }
    }

    private func items(of target: String) -> [Item] {
        (care.store.inventory ?? []).filter { $0.target == target && $0.state != "not declared" }
    }
}

private struct Coverage: View {
    let targets: [TargetStatus]
    let drift: Drift?

    var body: some View {
        let declared = targets.map(\.declared).reduce(0, +)
        let inPlace = targets.map(\.inPlace).reduce(0, +)
        let share = Double(inPlace) / Double(max(declared, 1))
        VStack(alignment: .leading, spacing: 10) {
            Text("Coverage").font(.headline)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(Int((share * 100).rounded()))%").font(.largeTitle.weight(.bold))
                Text("\(inPlace) of \(declared) declared items in place").font(.callout).foregroundStyle(.secondary)
            }
            ShareBar(share: share, colors: inPlace == declared ? Tint.green : Tint.orange)
            Spacer(minLength: 0)
            let synced = targets.filter { $0.gaps == 0 && $0.error == nil }.count
            Text("\(synced) of \(targets.count) targets in sync").font(.callout)
            if let drift {
                Text(drift.changes == 0 ? "No drift at the last check, \(drift.at.formatted(.relative(presentation: .named)))"
                                        : "\(drift.changes) change(s) outstanding at the last check, \(drift.at.formatted(.relative(presentation: .named)))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .modifier(Glass())
    }
}

private struct Actions: View {
    let store: Store
    let missing: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(missing == 0 ? "All Clear" : "\(missing) to Put in Place").font(.headline)
            Text(missing == 0 ? "Everything declared for this Mac is in place."
                              : "Review the plan, then apply it. Nothing changes before you say yes.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack {
                Button("Choose Apps…") { store.openApps?() }
                if missing > 0 {
                    Button("Apply All…") { Task { await store.apply() } }
                }
            }
            .disabled(store.busy != nil)
        }
        .modifier(Glass())
    }
}

private struct TargetRow: View {
    let store: Store
    let target: TargetStatus
    let items: [Item]
    @Binding var open: String?

    var body: some View {
        let isOpen = open == target.target
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right").font(.caption).frame(width: 12)
                Text(target.target).font(.body.weight(.medium))
                Text(target.provider).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let error = target.error {
                    Text(error).font(.caption).foregroundStyle(Theme.bad).lineLimit(1)
                } else {
                    Text("\(target.inPlace) of \(target.declared)").font(.callout.monospacedDigit())
                        .foregroundStyle(target.gaps == 0 ? Theme.good : Theme.warning)
                }
                if target.gaps > 0 {
                    Button("Apply…") { Task { await store.fixTarget(target.target) } }
                        .controlSize(.small)
                        .disabled(store.busy != nil)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { open = isOpen ? nil : target.target }
            if isOpen {
                if items.isEmpty {
                    Text("Nothing listed.").font(.caption).foregroundStyle(.secondary).padding(.leading, 22)
                }
                ForEach(items) { ItemLine(item: $0).padding(.leading, 22) }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Item kinds each provider can write into its manifest with `add`.
private let addableKinds: [String: Set<String>] = [
    "packages": ["brew", "cask", "mas"],
    "tools": ["runtime"],
]

/// A batch waiting for its why line.
private struct PendingAdd: Identifiable {
    let id = UUID()
    let target: String
    let items: [Item]
}

private struct NotInConfig: View {
    let store: Store
    let items: [Item]
    let targets: [TargetStatus]
    @State private var selected: Set<String> = []
    @State private var pending: PendingAdd?

    var body: some View {
        let groups = addable
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Not in Your Config").font(.headline)
                    Text("\(groups.map(\.items.count).reduce(0, +))").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    let batch = nextBatch(groups)
                    Button(batch.map { "Add \($0.items.count) to \($0.target)…" } ?? "Add Selected…") { pending = batch }
                        .disabled(store.busy != nil || batch == nil)
                }
                Text("Installed on this Mac, but no target declares them.").font(.caption).foregroundStyle(.secondary)
                ForEach(groups, id: \.target) { group in
                    Text(group.target).font(.subheadline.weight(.medium)).padding(.top, 4)
                    ForEach(group.items) { item in row(item, target: group.target) }
                }
            }
            .modifier(Glass())
            .sheet(item: $pending) { batch in
                WhySheet(batch: batch) { why, section in
                    pending = nil
                    Task { await add(batch, why: why, section: section) }
                } cancel: { pending = nil }
            }
        }
    }

    private func row(_ item: Item, target: String) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: binding(for: key(target, item))).labelsHidden().toggleStyle(.checkbox)
            Text(item.app ?? item.name).font(.callout).lineLimit(1)
            Text(item.kind).font(.caption2).foregroundStyle(.secondary)
            Spacer()
            if let version = item.version { Text(version).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            Button("Add to Config…") { pending = PendingAdd(target: target, items: [item]) }
                .controlSize(.small)
                .disabled(store.busy != nil)
        }
    }

    /// Undeclared items grouped by the target whose provider can add them.
    private var addable: [(target: String, items: [Item])] {
        targets.compactMap { t in
            guard let kinds = addableKinds[t.provider] else { return nil }
            let mine = items.filter { $0.target == t.target && kinds.contains($0.kind) }
            return mine.isEmpty ? nil : (t.target, mine)
        }
    }

    private func key(_ target: String, _ item: Item) -> String { target + "|" + item.resource }

    private func binding(for key: String) -> Binding<Bool> {
        Binding(get: { selected.contains(key) },
                set: { if $0 { selected.insert(key) } else { selected.remove(key) } })
    }

    private func chosen(in groups: [(target: String, items: [Item])]) -> [(target: String, item: Item)] {
        groups.flatMap { g in g.items.filter { selected.contains(key(g.target, $0)) }.map { (g.target, $0) } }
    }

    /// The selected items of the first target that has any: the CLI adds into
    /// one manifest at a time, and the rest stay ticked for the next click.
    private func nextBatch(_ groups: [(target: String, items: [Item])]) -> PendingAdd? {
        let picks = chosen(in: groups)
        guard let target = picks.first?.target else { return nil }
        return PendingAdd(target: target, items: picks.filter { $0.target == target }.map(\.item))
    }

    private func add(_ batch: PendingAdd, why: String, section: String) async {
        guard store.busy == nil, let cli = store.cli else { return }
        let label = batch.items.count == 1 ? batch.items[0].resource : "\(batch.items.count) items"
        store.busy = "Adding \(label)"
        defer { store.busy = nil }
        var added = 0
        do {
            for item in batch.items {
                try await cli.add(target: batch.target, item: item, why: why, section: section)
                selected.remove(key(batch.target, item))
                added += 1
            }
        } catch {
            let progress = batch.items.count > 1 ? " (\(added) of \(batch.items.count) added)" : ""
            store.message = Store.Message(text: "Could not add to \(batch.target)\(progress): \(error.localizedDescription)", failed: true)
            if added > 0 { await store.configChanged() }
            return
        }
        store.message = Store.Message(text: "Added \(label) to \(batch.target).", failed: false)
        await store.configChanged()
    }
}

private struct WhySheet: View {
    let batch: PendingAdd
    let confirm: (_ why: String, _ section: String) -> Void
    let cancel: () -> Void
    @State private var why = "Added from this Mac by ZC Care"
    @State private var section = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(batch.items.count == 1 ? "Add \(batch.items[0].resource) to \(batch.target)?"
                                        : "Add \(batch.items.count) items to \(batch.target)?")
                .font(.headline)
            Text(Alerts.lines(batch.items.map(\.resource), max: 6)).font(.caption).foregroundStyle(.secondary)
            TextField("Why it is there", text: $why)
            TextField("Section (optional)", text: $section)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Add") { confirm(why.trimmingCharacters(in: .whitespaces), section.trimmingCharacters(in: .whitespaces)) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(why.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

private struct Inventory: View {
    let items: [Item]
    @Binding var search: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Inventory").font(.headline)
                Text("\(items.count)").font(.callout).foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search Items", text: $search).textFieldStyle(.plain).findShortcut()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.white.opacity(0.1)))
                .frame(maxWidth: 260)
            }
            let shown = self.shown
            if shown.isEmpty {
                Text(search.isEmpty ? "Reading your config…" : "No item matches.").foregroundStyle(.secondary)
            }
            // Ids repeat across targets, so rows go by position.
            ForEach(Array(shown.prefix(200).enumerated()), id: \.offset) { _, item in
                ItemLine(item: item, showsTarget: true)
            }
            if shown.count > 200 {
                Text("\(shown.count - 200) more; search to narrow.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .modifier(Glass())
    }

    private var shown: [Item] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return items }
        return items.filter { item in
            [item.name, item.app, item.desc, item.why, item.target, item.state].contains { $0?.localizedCaseInsensitiveContains(q) == true }
        }
    }
}

private struct ItemLine: View {
    let item: Item
    var showsTarget = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(item.state)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(color))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.app ?? item.name).font(.callout).lineLimit(1)
                    Text(item.kind).font(.caption2).foregroundStyle(.secondary)
                    if showsTarget, let target = item.target {
                        Text(target).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if let note = item.why ?? item.desc {
                    Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if let version = item.version { Text(version).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
        }
    }

    private var color: Color {
        switch item.state {
        case "in place": Theme.good.opacity(0.6)
        case "missing", "differs", "outdated": Theme.warning.opacity(0.8)
        case "manual": Theme.bad.opacity(0.7)
        default: Color.white.opacity(0.18)
        }
    }
}

private struct History: View {
    let entries: [HistoryEntry]?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Applied").font(.headline)
            if entries?.isEmpty ?? true {
                Text(entries == nil ? "Reading the log…" : "Nothing applied yet.").foregroundStyle(.secondary)
            }
            ForEach(Array((entries ?? []).enumerated()), id: \.offset) { _, e in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: e.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(e.ok ? Theme.good : Theme.bad)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.detail).font(.callout).lineLimit(2)
                        Text([e.target, e.at.formatted(.relative(presentation: .named))].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }
        .modifier(Glass())
    }
}
