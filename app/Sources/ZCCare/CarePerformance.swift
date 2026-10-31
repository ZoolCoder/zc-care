import AppKit
import SwiftUI
import ZCCareCore

// MARK: Performance

struct PerformanceView: View {
    @Bindable var care: Care
    @State private var order = Monitor.Order.cpu
    @State private var showMore = false
    @State private var part = Part.all

    /// The segments over the page: all of it, or one section alone.
    enum Part: String, CaseIterable { case all = "All", maintenance = "Maintenance", agents = "Launch Agents", background = "Background Apps", processes = "Processes" }

    var body: some View {
        VStack(spacing: 0) {
            CareHeader(title: "Performance", subtitle: care.startup.count == 1 ? "1 item starts with your session" : "\(care.startup.count) items start with your session",
                   action: ("Rescan", { Task { await care.loadAgents() } }))
            Picker("Show", selection: $part) {
                ForEach(Part.allCases, id: \.self) { Text(label($0)) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 620)
            .padding(.horizontal, 28)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if shows(.maintenance) {
                    CareSection("Maintenance") {
                        ForEach(care.maintenance) { task in
                            CareRow(icon: SymbolTile(symbol: task.symbol, colors: Tint.violet, size: 32),
                                title: task.title, detail: task.detail, value: task.admin ? "Needs password" : "") {
                                Button("Run") { Task { await care.run(task) } }
                                    .controlSize(.small)
                                    .disabled(care.store.busy != nil)
                            }
                        }
                    }
                    }
                    if shows(.agents) {
                    CareSection("Launch Agents") {
                        ForEach(care.agents) { agent in
                            CareRow(icon: SymbolTile(symbol: agent.broken ? "bolt.slash.fill" : "bolt.fill",
                                                 colors: agent.broken ? Tint.red : agent.enabled ? Tint.orange : Tint.gray, size: 32),
                                title: agent.label,
                                detail: (agent.broken ? "Program gone: " : care.managed(agent) ? "In your config: " : "")
                                    + (agent.program as NSString).abbreviatingWithTildeInPath,
                                value: agent.broken ? "Broken" : agent.running ? "Running" : agent.runAtLoad ? "At login" : "On demand",
                                flag: care.isNew(agent: agent) ? appearedFlag : nil, flagColor: Theme.accent) {
                                if agent.broken, agent.path.hasPrefix(NSHomeDirectory() + "/") {
                                    Button("Remove") { Task { await care.remove(agent) } }
                                        .controlSize(.small)
                                        .disabled(care.store.busy != nil)
                                } else {
                                    Toggle(agent.label, isOn: Binding(get: { agent.enabled },
                                                                      set: { on in Task { await care.setEnabled(agent, on) } }))
                                        .toggleStyle(.switch)
                                        .labelsHidden()
                                        .controlSize(.small)
                                        .disabled(care.store.busy != nil)
                                }
                            }
                        }
                    }
                    }
                    if shows(.background) {
                    CareSection("Background Apps") {
                        if care.background.isEmpty {
                            Text("None running.").foregroundStyle(.secondary).padding(10)
                        }
                        ForEach(care.background, id: \.processIdentifier) { app in
                            CareRow(icon: Image(nsImage: app.icon ?? NSImage()).resizable().frame(width: 32, height: 32),
                                title: app.localizedName ?? "?", detail: app.bundleIdentifier ?? "", value: "") {
                                Button("Quit") { care.quit(app) }.controlSize(.small).gatedOnBusy(care.store)
                            }
                        }
                    }
                    }
                    if shows(.processes) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Top Processes").font(.title3.weight(.semibold))
                            Spacer()
                            Toggle("Show 25", isOn: $showMore).toggleStyle(.checkbox).controlSize(.small)
                            Picker("Sort by", selection: $order) {
                                Text("CPU").tag(Monitor.Order.cpu)
                                Text("Memory").tag(Monitor.Order.memory)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 160)
                        }
                        VStack(spacing: 0) {
                            ForEach(care.monitor.performanceTop) { p in
                                CareRow(icon: SymbolTile(symbol: "cpu", colors: Tint.violet, size: 32),
                                    title: p.name, detail: processDetail(p),
                                    value: order == .cpu ? String(format: "%.0f%% CPU", p.cpu) : Store.bytes(p.memory, .memory)) {
                                    ProcessControls(care: care, proc: p)
                                }
                            }
                        }
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.card))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.rim))
                    }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 70)
            }
        }
        .onAppear { if care.maintenance.isEmpty { care.loadMaintenance() } }
        // ps every three seconds while the module shows.
        .task(id: [order == .cpu, showMore, shows(.processes)]) {
            guard shows(.processes) else { return }
            if care.monitor.performance?.order != order { care.monitor.performanceTop = [] }
            care.monitor.performance = (order, showMore ? 25 : 10)
            while !Task.isCancelled {
                await care.monitor.readPerformanceTop()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .onDisappear {
            care.monitor.performance = nil
            care.monitor.performanceTop = []
        }
    }

    private func shows(_ p: Part) -> Bool { part == .all || part == p }

    private func label(_ p: Part) -> String {
        let n: Int? = switch p {
        case .all, .processes: nil
        case .maintenance: care.maintenance.count
        case .agents: care.agents.count
        case .background: care.background.count
        }
        // Zero until the first read, so only a count above it shows.
        guard let n, n > 0 else { return p.rawValue }
        return "\(p.rawValue) \(n)"
    }
}

private func processDetail(_ p: Proc) -> String {
    let flag = p.isZombie ? " · zombie" : p.isStopped ? " · stopped" : ""
    return "pid \(p.pid)\(flag)"
}

/// Quit and Force Quit for one process row, or why there are none.
private struct ProcessControls: View {
    let care: Care
    let proc: Proc

    var body: some View {
        if let reason = Processes.protection(of: proc) {
            Button("Quit") {}.controlSize(.small).disabled(true).help(reason)
        } else {
            HStack(spacing: 6) {
                Button("Quit") {
                    // An app gets the polite Quit it would from the Dock; anything else is asked about first.
                    guard isApp || Alerts.confirm("Quit \(proc.name)?",
                                                  "It is not an app, so it gets a signal to end; what it was doing may be lost.",
                                                  button: "Quit") else { return }
                    act(force: false)
                }
                .controlSize(.small)
                Button("Force Quit") {
                    guard Alerts.confirm("Force quit \(proc.name)?", "Unsaved work is lost.", button: "Force Quit") else { return }
                    act(force: true)
                }
                .controlSize(.small)
            }
            .gatedOnBusy(care.store)
        }
    }

    private var isApp: Bool { NSRunningApplication(processIdentifier: proc.pid)?.bundleIdentifier != nil }

    private func act(force: Bool) {
        if !end(force: force) {
            care.store.message = Store.Message(text: "Could not quit \(proc.name); macOS did not allow it.", failed: true)
        }
        Task { await care.monitor.readPerformanceTop() }
    }

    /// Apps close the polite way; anything else gets a signal.
    private func end(force: Bool) -> Bool {
        if let app = NSRunningApplication(processIdentifier: proc.pid), app.bundleIdentifier != nil {
            return force ? app.forceTerminate() : app.terminate()
        }
        return kill(proc.pid, force ? SIGKILL : SIGTERM) == 0
    }
}
