import SwiftUI
import ZCCareCore

/// Picks which of the config's packages this Mac installs, installs them,
/// then shows the first things to try with each. What is left out goes on
/// the Mac's skip list; the config stays as it is.
struct AppPickerView: View {
    @Bindable var store: Store
    let close: () -> Void
    @State private var phase = Phase.loading
    @State private var choice: AppChoice?
    /// The profiles the picks started from; none is everything.
    @State private var profiles: Set<String> = []

    enum Phase: Equatable {
        case loading, picking, installing, done
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            switch phase {
            case .loading:
                Spacer()
                ProgressView("Reading your config…")
                Spacer()
            case .picking, .installing:
                if let choice {
                    if !choice.profiles.isEmpty { profilePicker(choice) }
                    PickList(choice: binding(choice)).disabled(phase == .installing)
                }
            case .done:
                if let choice { TipList(items: tipItems(choice)) }
            case .failed(let text):
                Spacer()
                Label(text, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warning)
                    .padding(.horizontal, 32)
                Spacer()
            }
            footer
        }
        .frame(minWidth: 620, maxWidth: .infinity, minHeight: 700, maxHeight: .infinity)
        .themed()
        .ignoresSafeArea()
        .task { await load() }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text(phase == .done ? "Make the most of them" : "Choose your apps").font(.system(size: 24, weight: .bold))
            Text(phase == .done
                 ? "A few keys and commands to start with. The guide link opens the whole page in the manual."
                 : "Pick who this Mac is for, then untick what it does not need. Left-out apps stay in your config for other Macs.")
                .font(.callout).foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 34)
        .padding(.horizontal, 40)
        .padding(.bottom, 16)
    }

    private var footer: some View {
        HStack {
            switch phase {
            case .done:
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            case .installing:
                ProgressView().controlSize(.small)
                Text(store.busy ?? "Installing").font(.callout).foregroundStyle(.secondary)
                Spacer()
                if let cancel = store.cancelBusy {
                    Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                }
            default:
                Button("Later", action: close).keyboardShortcut(.cancelAction)
                Spacer()
                if let choice, phase == .picking {
                    Text(summary(choice)).font(.caption).foregroundStyle(.secondary)
                    Button(choice.toInstall.isEmpty ? "Save" : "Install \(choice.toInstall.count)") {
                        Task { await install(choice) }
                    }
                    .keyboardShortcut(.defaultAction)
                } else if case .failed = phase {
                    Button("Try Again") { Task { await load() } }
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 20)
    }

    /// Who this Mac is for, one or several; each change re-ticks the
    /// list, which stays editable.
    private func profilePicker(_ choice: AppChoice) -> some View {
        HStack(spacing: 6) {
            chip("Everything", on: profiles.isEmpty) { profiles = [] }
            ForEach(choice.profiles, id: \.self) { name in
                chip(name.capitalized, on: profiles.contains(name)) {
                    if profiles.remove(name) == nil { profiles.insert(name) }
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 14)
    }

    private func chip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            choice?.choose(profiles: profiles)
        } label: {
            Label(title, systemImage: on ? "checkmark.circle.fill" : "circle")
        }
        .buttonStyle(.bordered)
        .tint(on ? Theme.good : nil)
    }

    private func summary(_ choice: AppChoice) -> String {
        let skipped = choice.choosable.count - choice.toInstall.count
        return skipped == 0 ? "" : "\(skipped) left out"
    }

    private func binding(_ choice: AppChoice) -> Binding<AppChoice> {
        Binding { self.choice ?? choice } set: { self.choice = $0 }
    }

    private func load() async {
        phase = .loading
        do {
            guard let loaded = try await store.appChoice() else {
                phase = .failed(store.setupProblem ?? "zc-care is not ready yet.")
                return
            }
            choice = loaded
            // The skip list already holds the Mac's pick: the chips show
            // who it is for without re-ticking.
            let mine = (try? await store.setupCLI?.machineProfiles()) ?? []
            profiles = Set(mine).intersection(loaded.profiles)
            phase = loaded.items.isEmpty ? .failed("Your config declares no packages.") : .picking
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func install(_ picked: AppChoice) async {
        phase = .installing
        if await store.install(picked) {
            phase = .done
        } else {
            phase = .failed(store.message?.text ?? "The install did not finish.")
        }
    }

    /// What was just installed comes first, then what was already there.
    private func tipItems(_ choice: AppChoice) -> [Item] {
        let new = choice.toInstall
        let had = choice.items.filter(AppChoice.isInstalled)
        return (new + had).filter { Tips.tip(for: $0) != nil }
    }
}

private struct PickList: View {
    @Binding var choice: AppChoice

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(choice.sections) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(section.name).font(.headline)
                            Spacer()
                            let open = section.items.filter { !AppChoice.isInstalled($0) }
                            if !open.isEmpty {
                                let all = open.allSatisfy(choice.isPicked)
                                Button(all ? "None" : "All") { choice.set(section, picked: !all) }
                                    .buttonStyle(.zcLink).font(.caption)
                            }
                        }
                        VStack(spacing: 0) {
                            ForEach(section.items) { item in
                                Row(item: item, picked: choice.isPicked(item)) { choice.toggle(item) }
                            }
                        }
                        .modifier(Card())
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 8)
        }
    }

    private struct Row: View {
        let item: Item
        let picked: Bool
        let toggle: () -> Void

        var body: some View {
            let installed = AppChoice.isInstalled(item)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Toggle("", isOn: Binding { installed || picked } set: { _ in toggle() })
                    .toggleStyle(.checkbox).labelsHidden()
                    .disabled(installed)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.app ?? item.name).font(.body.weight(.medium))
                        Text(item.kind).font(.caption2).foregroundStyle(.secondary)
                    }
                    if let why = item.why, !why.isEmpty {
                        Text(why).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                if installed {
                    Text("Installed").font(.caption).foregroundStyle(Theme.good)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture { if !installed { toggle() } }
        }
    }
}

private struct TipList: View {
    let items: [Item]

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if items.isEmpty {
                    Text("Nothing to show here; the manual's Toolbox has a page per tool.")
                        .foregroundStyle(.secondary)
                }
                ForEach(items) { item in
                    if let tip = Tips.tip(for: item) { TipCard(item: item, tip: tip) }
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 8)
        }
    }

    private struct TipCard: View {
        let item: Item
        let tip: Tip

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(item.app ?? item.name).font(.headline)
                    Spacer()
                    if let guide = tip.guide {
                        Link("Guide", destination: guide).font(.caption)
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(tip.uses, id: \.self) { use in
                        GridRow {
                            Text(use.keys).font(.system(.callout, design: .monospaced)).foregroundStyle(Theme.accent)
                            Text(use.does).font(.callout).foregroundStyle(.white.opacity(0.85))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(Card())
        }
    }
}
