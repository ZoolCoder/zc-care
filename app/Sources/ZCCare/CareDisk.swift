import AppKit
import SwiftUI
import ZCCareCore

extension Care {
    /// Reads the startup disk: diskutil for health and volumes, tmutil for
    /// local snapshots. All of it is read-only and needs no password.
    func loadDisk() async {
        guard !loadingDisk else { return }
        loadingDisk = true
        defer {
            loadingDisk = false
            diskReadAt = .now
        }
        let runner = ProcessRunner(timeout: 30)
        let diskutil = "/usr/sbin/diskutil"
        guard let root = try? await runner.run(diskutil, ["info", "-plist", "/"], env: [:]), root.status == 0,
              let startup = DiskInfo.startup(root.stdout) else {
            diskHealth = nil
            return
        }
        // A failed read clears it, so no alert speaks from an old one.
        let info = try? await runner.run(diskutil, ["info", "-plist", startup.physical], env: [:])
        diskHealth = info.flatMap { $0.status == 0 ? DiskHealth(diskInfo: $0.stdout) : nil }
        if let r = try? await runner.run(diskutil, ["apfs", "list", "-plist", startup.container], env: [:]), r.status == 0 {
            containerSpace = ContainerSpace(apfsList: r.stdout, container: startup.container)
        }
        // A failed listing shows none rather than snapshots already thinned.
        let snapshots = try? await runner.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"], env: [:])
        localSnapshots = snapshots.flatMap { $0.status == 0 ? DiskInfo.snapshots(String(decoding: $0.stdout, as: UTF8.self)) : nil } ?? []
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        if let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
           let plain = v.volumeAvailableCapacity, let important = v.volumeAvailableCapacityForImportantUsage {
            purgeable = max(0, important - Int64(plain))
        }
    }
}

/// The whole startup disk rather than the home folder: every APFS volume,
/// the ones Finder hides too, what macOS can purge, and the drive's health.
struct StartupDiskView: View {
    @Bindable var care: Care

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let space = care.containerSpace {
                    usage(space)
                    CareSection("Volumes") {
                        ForEach(space.volumes) { volume in
                            CareRow(icon: SymbolTile(symbol: symbol(volume.role), colors: volume.role == "Data" ? Tint.blue : Tint.gray, size: 32),
                                    title: volume.name, detail: ContainerSpace.describe(volume.role),
                                    value: Store.bytes(volume.used)) { EmptyView() }
                        }
                        if space.unaccounted > 0 {
                            CareRow(icon: SymbolTile(symbol: "square.stack.3d.up.fill", colors: Tint.violet, size: 32),
                                    title: "Snapshots and metadata", detail: "In use, but in no volume's count",
                                    value: Store.bytes(space.unaccounted)) { EmptyView() }
                        }
                    }
                    reclaimable
                } else if care.diskReadAt != nil && !care.loadingDisk {
                    VStack(spacing: 10) {
                        Text("The startup disk could not be read.").foregroundStyle(.secondary)
                        Button("Try Again") { Task { await care.loadDisk() } }.controlSize(.small)
                    }
                    .padding(20)
                } else {
                    ProgressView().padding(20)
                }
                health
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
        }
        .task { if care.containerSpace == nil { await care.loadDisk() } }
    }

    private func usage(_ space: ContainerSpace) -> some View {
        let used = space.size - space.free
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(Store.bytes(used)) used of \(Store.bytes(space.size))").font(.headline)
                Spacer()
                Text("\(Store.bytes(space.free)) free").foregroundStyle(.secondary)
                if care.loadingDisk { ProgressView().controlSize(.small) }
                Button("Refresh") { Task { await care.loadDisk() } }.controlSize(.small).disabled(care.loadingDisk)
            }
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(Array(space.volumes.enumerated()), id: \.element.id) { i, volume in
                        Rectangle().fill(Sunburst.color(i, depth: 0))
                            .frame(width: max(2, geo.size.width * CGFloat(volume.used) / CGFloat(max(space.size, 1))))
                            .help("\(volume.name): \(Store.bytes(volume.used))")
                    }
                    Rectangle().fill(Theme.divider)
                }
            }
            .frame(height: 14)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .padding(16)
        .modifier(Card())
    }

    @ViewBuilder private var reclaimable: some View {
        CareSection("Space macOS Frees on Its Own") {
            CareRow(icon: SymbolTile(symbol: "arrow.3.trianglepath", colors: Tint.green, size: 32), title: "Purgeable",
                    detail: "Caches and iCloud copies macOS drops when space runs low",
                    value: care.purgeable.map { Store.bytes($0) } ?? "…") { EmptyView() }
            CareRow(icon: SymbolTile(symbol: "clock.arrow.circlepath", colors: Tint.orange, size: 32), title: "Local Time Machine Snapshots",
                    detail: care.localSnapshots.isEmpty ? "None on this disk" : care.localSnapshots.map(snapshotDate).joined(separator: ", "),
                    value: Store.counted(care.localSnapshots.count, "snapshot")) {
                if !care.localSnapshots.isEmpty {
                    Button("Thin…") {
                        if care.maintenance.isEmpty { care.loadMaintenance() }
                        guard let task = care.maintenance.first(where: { $0.id == "snapshots" }) else { return }
                        Task {
                            await care.run(task)
                            await care.loadDisk()
                        }
                    }
                    .controlSize(.small)
                    .help("Delete local Time Machine snapshots; backups on the backup disk stay")
                    .gatedOnBusy(care.store)
                }
            }
        }
    }

    @ViewBuilder private var health: some View {
        CareSection("Drive Health") {
            if let h = care.diskHealth {
                CareRow(icon: SymbolTile(symbol: "internaldrive.fill", colors: tint(h.verdict), size: 32),
                        title: h.model ?? "Startup disk", detail: verdictText(h), value: h.smart ?? "",
                        flag: h.concerns.first, flagColor: h.verdict == .failing ? Theme.bad : Theme.warning) { EmptyView() }
                let facts = facts(h)
                if !facts.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 10) {
                        ForEach(facts, id: \.0) { title, value in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(title).font(.caption).foregroundStyle(.secondary)
                                Text(value).font(.callout.weight(.semibold)).monospacedDigit()
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
            } else {
                Text(care.loadingDisk ? "Reading the drive…" : "The drive did not report its health.")
                    .foregroundStyle(.secondary).padding(10)
            }
        }
    }

    private func verdictText(_ h: DiskHealth) -> String {
        switch h.verdict {
        case .good: "Healthy, by the drive's own report"
        case .watch: "Working, with something to watch"
        case .failing: "Failing: back up now"
        case .unknown: "This drive does not report its health"
        }
    }

    private func facts(_ h: DiskHealth) -> [(String, String)] {
        var out: [(String, String)] = []
        if let wear = h.wear { out.append(("Endurance Used", "\(wear)%")) }
        if let spare = h.spare { out.append(("Spare Blocks", "\(spare)%")) }
        if let c = h.celsius { out.append(("Temperature", "\(c) °C")) }
        if let hours = h.powerOnHours { out.append(("Powered On", Store.counted(hours, "hour"))) }
        if let written = h.written { out.append(("Written", Store.bytes(written))) }
        if let read = h.read { out.append(("Read", Store.bytes(read))) }
        if let n = h.unsafeShutdowns { out.append(("Unsafe Shutdowns", "\(n)")) }
        if let n = h.mediaErrors { out.append(("Media Errors", "\(n)")) }
        return out
    }

    private func tint(_ verdict: DiskHealth.Verdict) -> [Color] {
        switch verdict {
        case .good: Tint.green
        case .watch: Tint.orange
        case .failing: Tint.red
        case .unknown: Tint.gray
        }
    }

    private func symbol(_ role: String?) -> String {
        switch role {
        case "Data": "person.crop.square.fill"
        case "System": "apple.logo"
        case "VM": "memorychip.fill"
        case "Recovery": "lifepreserver.fill"
        case "Update": "arrow.down.circle.fill"
        default: "internaldrive.fill"
        }
    }

    /// "com.apple.TimeMachine.2026-10-30-050000.local" as its date.
    private func snapshotDate(_ name: String) -> String {
        name.replacingOccurrences(of: "com.apple.TimeMachine.", with: "").replacingOccurrences(of: ".local", with: "")
    }
}
