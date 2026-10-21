import AppKit
import SwiftUI
import ZCCareCore

/// Sets up a Mac in a few steps, no terminal needed: who it is for, a
/// starter config made for that, the security checks that fail, and for a
/// developer git, an SSH key and GitHub. Nothing installs here; Choose
/// Apps does that, after the owner's pick.
struct SetupView: View {
    @Bindable var store: Store
    let close: () -> Void
    @State private var step = Step.who
    @State private var catalog: StarterCatalog?
    @State private var picked: Set<String> = []
    @State private var role = "personal"
    @State private var keepApps = true
    @State private var error: String?
    @State private var made: InitResult?

    enum Step { case who, secure, identity, done }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 8) {
                    switch step {
                    case .who: who
                    case .secure: SecureStep(store: store)
                    case .identity: IdentityStep(store: store)
                    case .done: done
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.warning).font(.callout)
                    }
                }
                .padding(.horizontal, 32)
            }
            footer
        }
        .frame(minWidth: 580, maxWidth: .infinity, minHeight: 680, maxHeight: .infinity)
        .themed()
        .ignoresSafeArea()
        .task { await load() }
    }

    private var title: (String, String) {
        switch step {
        case .who:
            ("Set up this Mac", store.needsConfig
                ? "Pick who it is for. ZC Care writes a config for that; you choose the apps next, and nothing changes without your yes."
                : "Pick who it is for. Your config keeps its targets; those for other profiles stop applying here.")
        case .secure: ("Make it safe", "The checks this Mac fails. Fix All asks for your password once.")
        case .identity: ("Your developer identity", "Who your commits are from, a key that signs them, and GitHub.")
        case .done: ("This Mac is set up", made.map(summary) ?? "Choose its apps, or run Smart Care.")
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text(title.0).font(.system(size: 26, weight: .bold))
            Text(title.1).font(.callout).foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 34)
        .padding(.horizontal, 40)
        .padding(.bottom, 18)
    }

    @ViewBuilder private var who: some View {
        ForEach(catalog?.profiles ?? []) { profile in
            Button { toggle(profile.name) } label: {
                ProfileCard(profile: profile, on: picked.contains(profile.name))
            }
            .buttonStyle(.plain)
        }
        HStack {
            Text("Used for").font(.callout)
            Picker("Used for", selection: $role) {
                ForEach(catalog?.roles ?? [], id: \.self) { Text($0.capitalized).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 220)
            Spacer()
        }
        .padding(.top, 6)
        if store.needsConfig {
            Toggle("Keep the apps this Mac already has in the config", isOn: $keepApps)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("I already have a zc-care.yaml…") { store.chooseConfig() }
                .buttonStyle(.link)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let path = store.configPath {
            Text("Config: " + (path as NSString).abbreviatingWithTildeInPath)
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var done: some View {
        NextCard(symbol: "square.grid.2x2.fill", colors: Tint.blue, title: "Choose apps",
                 detail: "Your profiles' apps are ticked. Untick what this Mac does not need, then install.") {
            Button("Choose Apps…") { store.openApps?(); close() }
        }
        NextCard(symbol: "sparkles", colors: Tint.violet, title: "Smart Care",
                 detail: "Clean up, update and check this Mac in one scan.") {
            Button("Start") { store.openCare?(nil); close() }
        }
    }

    private var footer: some View {
        HStack {
            if let busy = store.busy {
                ProgressView().controlSize(.small)
                Text(busy).font(.callout).foregroundStyle(.secondary)
            } else if step == .who {
                Button("Later", action: close).keyboardShortcut(.cancelAction)
            }
            Spacer()
            switch step {
            case .who:
                Button(store.needsConfig ? "Create My Config" : "Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(picked.isEmpty || store.busy != nil)
            case .secure:
                Button("Next") { step = picked.contains("developer") ? .identity : .done }
                    .keyboardShortcut(.defaultAction)
            case .identity:
                Button("Next") { step = .done }.keyboardShortcut(.defaultAction)
            case .done:
                Button("Close", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 20)
    }

    private func toggle(_ name: String) {
        if picked.remove(name) == nil { picked.insert(name) }
    }

    private func summary(_ r: InitResult) -> String {
        var text = "Your config is in " + ((r.config as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath + "."
        if r.kept > 0 { text += " It keeps the \(r.kept) apps this Mac had." }
        return text + " Choose its apps next."
    }

    /// Reads the profiles on offer, and who the Mac is for already.
    private func load() async {
        await store.connected()
        guard let cli = store.setupCLI else {
            error = store.setupProblem
            return
        }
        do {
            catalog = try await cli.starter()
            let mine = try await cli.machineProfiles()
            picked = Set(mine).intersection(catalog?.profiles.map(\.name) ?? [])
            if let r = mine.first(where: { catalog?.roles.contains($0) == true }) { role = r }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Writes the starter config, or with one in place saves who the Mac
    /// is for; then on to the security checks.
    private func save() async {
        error = nil
        let profiles = (catalog?.profiles ?? []).map(\.name).filter(picked.contains)
        do {
            if store.needsConfig {
                made = try await store.createConfig(profiles: profiles, role: role, fromMac: keepApps)
            } else if let cli = store.setupCLI {
                _ = try await cli.setMachineProfiles(profiles + [role])
                await store.refresh()
            }
            step = .secure
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct ProfileCard: View {
    let profile: StarterCatalog.Profile
    let on: Bool

    var body: some View {
        HStack(spacing: 12) {
            SymbolTile(symbol: symbol, colors: colors, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.title).font(.body.weight(.semibold))
                Text(profile.about).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(on ? Theme.good : .secondary)
        }
        .padding(12)
        .contentShape(Rectangle())
        .modifier(Card())
    }

    private var symbol: String {
        switch profile.name {
        case "developer": "chevron.left.forwardslash.chevron.right"
        case "creative": "paintpalette.fill"
        default: "house.fill"
        }
    }

    private var colors: [Color] {
        switch profile.name {
        case "developer": Tint.cyan
        case "creative": Tint.pink
        default: Tint.orange
        }
    }
}

/// A step's row: what it is, and what to do about it.
private struct NextCard<Trailing: View>: View {
    let symbol: String
    let colors: [Color]
    let title: String
    let detail: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            SymbolTile(symbol: symbol, colors: colors, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            trailing.controlSize(.small)
        }
        .padding(12)
        .modifier(Card())
    }
}

/// The security checks this Mac fails, each with its fix, and one button
/// for every fix that runs as root.
private struct SecureStep: View {
    @Bindable var store: Store
    @State private var loaded = false
    @State private var previewing = false

    private var failing: [Check] { (store.snapshot?.security ?? []).filter { !$0.isOK } }

    var body: some View {
        Group {
            if !loaded {
                ProgressView("Checking this Mac…").padding(.top, 40)
            } else if failing.isEmpty {
                NextCard(symbol: "checkmark.shield.fill", colors: Tint.green, title: "Every check passes",
                         detail: "Disk encryption, firewall, updates, sharing and backups are as they should be.") {
                    EmptyView()
                }
            } else {
                if Fix.rootCommands(for: failing) != nil {
                    HStack {
                        Spacer()
                        Button("Fix All as Administrator…") { previewing = true }
                            .disabled(store.busy != nil)
                    }
                }
                ForEach(failing) { check in
                    NextCard(symbol: "exclamationmark.shield.fill", colors: Tint.red, title: check.title,
                             detail: check.detail ?? check.status) {
                        Button(label(check)) { Task { await store.fix(check) } }
                            .disabled(store.busy != nil)
                    }
                }
            }
        }
        .task {
            await store.refresh()
            loaded = true
        }
        .sheet(isPresented: $previewing) {
            RootPreview(steps: Fix.rootSteps(for: failing)) { Task { await store.secureAll() } }
        }
    }

    private func label(_ check: Check) -> String {
        switch Fix(for: check) {
        case .command: "Fix…"
        case .settings: "Open Settings"
        case .info: "Details"
        }
    }
}

/// Each fix and the exact command that runs as root, before the password
/// dialog.
private struct RootPreview: View {
    let steps: [Fix.RootStep]
    let confirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Fix \(Store.counted(steps.count, "check")) as administrator?").font(.headline)
            Text("macOS asks for your password once, then runs these as root:")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(steps) { step in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.title).font(.body.weight(.semibold))
                            Text(step.command).font(.caption.monospaced()).textSelection(.enabled)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Fix") {
                    dismiss()
                    confirm()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460, height: 340)
    }
}

/// Apple's command line tools, git's name and email, and a Terminal script
/// for the SSH key, signing and GitHub, which ask for a passphrase and a
/// sign-in the app must not handle.
private struct IdentityStep: View {
    @Bindable var store: Store
    @State private var id: DevIdentity?
    @State private var name = ""
    @State private var email = ""
    @State private var error: String?

    var body: some View {
        Group {
            if let id {
                NextCard(symbol: "hammer.fill", colors: Tint.gray, title: "Command line tools",
                         detail: id.tools ? "Installed: git, clang and make." : "Apple's git, clang and make. Homebrew needs them.") {
                    if id.tools { done } else { Button("Install…") { Task { await installTools() } } }
                }
                NextCard(symbol: "person.text.rectangle.fill", colors: Tint.blue, title: "Name and email",
                         detail: "Every commit carries them.") {
                    EmptyView()
                }
                HStack {
                    TextField("Name", text: $name)
                    TextField("Email", text: $email)
                    Button("Save") { Task { await saveGit() } }
                        .disabled(!id.tools || name.isEmpty || !email.contains("@"))
                }
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 12)
                NextCard(symbol: "key.fill", colors: Tint.orange, title: "SSH key, signing and GitHub",
                         detail: keyDetail(id)) {
                    if id.key != nil && id.signing && id.github {
                        done
                    } else {
                        Button("Set Up in Terminal…") { openScript() }.disabled(!id.tools || !email.contains("@"))
                    }
                }
                HStack {
                    if let error { Text(error).font(.caption).foregroundStyle(Theme.warning) }
                    Spacer()
                    Button("Check Again") { Task { await read() } }
                }
            } else {
                ProgressView("Reading git and SSH…").padding(.top, 40)
            }
        }
        .task { await read() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await read() }
        }
    }

    private var done: some View {
        Label("Done", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.good).font(.callout)
    }

    private func keyDetail(_ id: DevIdentity) -> String {
        var have: [String] = []
        if id.key != nil { have.append("a key") }
        if id.signing { have.append("signing") }
        if id.github { have.append("GitHub") }
        let missing = have.isEmpty ? "" : " Has " + have.joined(separator: ", ") + "."
        return "Terminal asks for a passphrase, then GitHub in your browser." + missing
    }

    private func read() async {
        let new = await DevIdentity.read(env: store.loginEnv, home: NSHomeDirectory())
        if name.isEmpty { name = new.name }
        if email.isEmpty { email = new.email }
        id = new
    }

    /// xcode-select opens Apple's installer and returns; it exits non-zero
    /// when the tools are there already, or no installer could start.
    private func installTools() async {
        do {
            let r = try await ProcessRunner(timeout: 30).run("/usr/bin/xcode-select", ["--install"], env: [:])
            error = r.status == 0 ? nil : lastLine(r.stderr) ?? "xcode-select exited \(r.status)"
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func saveGit() async {
        do {
            try await DevIdentity.setGit(name: name, email: email, env: store.loginEnv)
            error = nil
            await read()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func openScript() {
        do {
            NSWorkspace.shared.open(try DevIdentity.writeScript(email: email))
        } catch {
            self.error = error.localizedDescription
        }
    }
}
