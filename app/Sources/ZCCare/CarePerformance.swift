import AppKit
import SwiftUI
import ZCCareCore

// MARK: Performance

struct PerformanceView: View {
    @Bindable var care: Care
    @State private var order = Monitor.Order.cpu

    var body: some View {
        VStack(spacing: 0) {
            CareHeader(title: "Performance", subtitle: care.startup.count == 1 ? "1 item starts with your session" : "\(care.startup.count) items start with your session",
                   action: ("Rescan", { Task { await care.loadAgents() } }))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
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
                    CareSection("Launch Agents") {
                        ForEach(care.agents) { agent in
                            CareRow(icon: SymbolTile(symbol: agent.broken ? "bolt.slash.fill" : "bolt.fill",
                                                 colors: agent.broken ? Tint.red : agent.enabled ? Tint.orange : Tint.gray, size: 32),
                                title: agent.label,
                                detail: (agent.broken ? "Program gone: " : care.managed(agent) ? "In your config: " : "")
                                    + (agent.program as NSString).abbreviatingWithTildeInPath,
                                value: agent.broken ? "Broken" : agent.running ? "Running" : agent.runAtLoad ? "At login" : "On demand",
                                flag: care.isNew(agent: agent) ? "New" : nil, flagColor: Theme.accent) {
                                if agent.broken, agent.path.hasPrefix(NSHomeDirectory() + "/") {
                                    Button("Remove") { Task { await care.remove(agent) } }
                                        .controlSize(.small)
                                        .disabled(care.store.busy != nil)
                                } else {
                                    Toggle("", isOn: Binding(get: { agent.enabled },
                                                             set: { on in Task { await care.setEnabled(agent, on) } }))
                                        .toggleStyle(.switch)
                                        .labelsHidden()
                                        .controlSize(.small)
                                        .disabled(care.store.busy != nil)
                                }
                            }
                        }
                    }
                    CareSection("Background Apps") {
                        if care.background.isEmpty {
                            Text("None running.").foregroundStyle(.secondary).padding(10)
                        }
                        ForEach(care.background, id: \.processIdentifier) { app in
                            CareRow(icon: Image(nsImage: app.icon ?? NSImage()).resizable().frame(width: 32, height: 32),
                                title: app.localizedName ?? "?", detail: app.bundleIdentifier ?? "", value: "") {
                                Button("Quit") { care.quit(app) }.controlSize(.small)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Top Processes").font(.title3.weight(.semibold))
                            Spacer()
                            Picker("", selection: $order) {
                                Text("CPU").tag(Monitor.Order.cpu)
                                Text("Memory").tag(Monitor.Order.memory)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 160)
                        }
                        VStack(spacing: 0) {
                            ForEach(care.monitor.top) { p in
                                CareRow(icon: SymbolTile(symbol: "cpu", colors: Tint.violet, size: 32),
                                    title: p.name, detail: "pid \(p.pid)",
                                    value: order == .cpu ? String(format: "%.0f%% CPU", p.cpu) : Store.bytes(p.memory, .memory)) {
                                    EmptyView()
                                }
                            }
                        }
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.08)))
                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.1)))
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 70)
            }
        }
        .onAppear { if care.maintenance.isEmpty { care.loadMaintenance() } }
        // ps every three seconds while the module shows.
        .task(id: order) {
            care.monitor.order = order
            while !Task.isCancelled {
                await care.monitor.readTop()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}
