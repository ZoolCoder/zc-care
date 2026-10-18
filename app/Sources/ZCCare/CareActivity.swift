import AppKit
import SwiftUI
import ZCCareCore

// MARK: My Activity

/// CleanMyMac's My Activity: how the Mac is, what was cleaned, what to do next.
struct MyActivity: View {
    @Bindable var care: Care

    var body: some View {
        let log = care.store.activity
        VStack(spacing: 0) {
            CareHeader(title: "My Activity",
                   subtitle: log.since.map { "Since \($0.formatted(date: .abbreviated, time: .omitted))" }
                       ?? "What ZC Care cleans and runs shows here")
            ScrollView {
                VStack(spacing: 14) {
                    HStack(spacing: 14) {
                        MacHealth(care: care)
                        StorageCleaned(log: log)
                    }
                    .frame(height: 260)
                    HStack(alignment: .top, spacing: 14) {
                        Recommendations(care: care)
                        Recent(store: care.store, log: log)
                    }
                    .frame(minHeight: 280)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 70)
            }
        }
    }
}

private struct MacHealth: View {
    @Bindable var care: Care

    var body: some View {
        // The panel's grade, so both say the same.
        let grade = care.monitor.vitals.grade(insecure: care.store.findings.filter(\.isSecurity).count)
        VStack(alignment: .leading, spacing: 10) {
            Text("Mac Health").font(.headline)
            HStack(spacing: 14) {
                HeroArt(symbol: "macbook", colors: Tint.blue, size: 70)
                VStack(alignment: .leading, spacing: 2) {
                    Text(grade.rawValue).font(.title.weight(.bold)).foregroundStyle(grade.color)
                    Text(Host.current().localizedName ?? "This Mac").font(.callout)
                    Text(ProcessInfo.processInfo.operatingSystemVersionString).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if let disk = care.monitor.vitals.disk {
                let used = disk.total - disk.available
                HStack {
                    Text("\(Store.bytes(used)) used of \(Store.bytes(disk.total))").font(.callout)
                    Spacer()
                    Text("\(Store.bytes(disk.available)) free").font(.callout).foregroundStyle(.secondary)
                }
                ShareBar(share: Double(used) / Double(max(disk.total, 1)), colors: disk.isLow ? Tint.red : Tint.blue)
            }
        }
        .modifier(Glass())
        .task { await care.monitor.readHealth() }
    }
}

private struct StorageCleaned: View {
    let log: ActivityLog

    var body: some View {
        let byKind = log.freedByKind
        let top = max(byKind.first?.bytes ?? 1, 1)
        VStack(alignment: .leading, spacing: 10) {
            Text("Local Storage Cleaned").font(.headline)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(Store.bytes(log.freed)).font(.largeTitle.weight(.bold))
                let week = log.freed(lastDays: 7)
                if week > 0 { Text("+\(Store.bytes(week)) this week").font(.callout).foregroundStyle(Theme.good) }
            }
            Spacer(minLength: 0)
            if byKind.isEmpty {
                Text("Nothing cleaned yet.").foregroundStyle(.secondary)
            }
            ForEach(byKind.prefix(4), id: \.kind) { k in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(k.kind.rawValue).font(.callout)
                        Spacer()
                        Text(Store.bytes(k.bytes)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    ShareBar(share: Double(k.bytes) / Double(top), colors: Tint.green)
                }
            }
        }
        .modifier(Glass())
    }
}

private struct Recommendations: View {
    @Bindable var care: Care

    var body: some View {
        let all = care.recommendations
        VStack(alignment: .leading, spacing: 10) {
            Text(all.isEmpty ? "No Recommendations" : "\(all.count) Recommendations").font(.headline)
            if all.isEmpty {
                Text("Your Mac is in good shape.").foregroundStyle(.secondary)
            }
            ForEach(all) { r in
                HStack(spacing: 10) {
                    SymbolTile(symbol: r.symbol, colors: r.module.look.tint, size: 28)
                    Text(r.title).font(.callout).lineLimit(1)
                    Spacer()
                    Button("Go") { care.open(r.module) }.controlSize(.small)
                }
            }
        }
        .modifier(Glass())
    }
}

private struct Recent: View {
    let store: Store
    let log: ActivityLog

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent Activity").font(.headline)
            if log.entries.isEmpty {
                Text("Clean or run a task and it shows here.").foregroundStyle(.secondary)
            }
            ForEach(Array(log.entries.suffix(8).reversed().enumerated()), id: \.offset) { offset, e in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.title).font(.callout).lineLimit(1)
                        Text((e.kind.rawValue == e.title ? "" : e.kind.rawValue + " · ")
                             + e.date.formatted(.relative(presentation: .named))
                             + (e.putBack != nil ? " · put back" : ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if e.bytes > 0 { Text(Store.bytes(e.bytes)).font(.callout.monospacedDigit()).foregroundStyle(.secondary) }
                    if e.canPutBack {
                        Button("Put Back") { store.putBack(e) }
                            .controlSize(.small)
                            .disabled(store.busy != nil)
                            .help("Move it out of the Trash to where it was")
                    }
                }
            }
            if !log.runsByKind.isEmpty {
                Text(Store.counted(log.entries.count, "cleanup or task", "cleanups and tasks") + " in all").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
            }
        }
        .modifier(Glass())
    }
}

/// A thin rounded bar, filled to `share` in a gradient.
struct ShareBar: View {
    let share: Double
    let colors: [Color]

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule().fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                    .frame(width: g.size.width * min(max(share, 0), 1))
            }
        }
        .frame(height: 6)
    }
}
