import AppKit
import SwiftUI
import ZCCareCore

/// The Mac itself: a grade, protection, a tile for each vital, and one
/// recommendation. It samples only while it shows.
struct MacTab: View {
    @Bindable var store: Store
    let snapshot: Snapshot
    private var open: Store.MacDetail? { store.macDetail }

    private var monitor: Monitor { store.monitor }
    private var vitals: Vitals { monitor.vitals }
    private var insecure: Int { store.findings.filter(\.isSecurity).count }

    var body: some View {
        ScrollViewReader { proxy in
            content
                // An opened tile's list starts below the fold; it scrolls up.
                .onChange(of: store.macDetail) { _, detail in
                    guard detail != nil else { return }
                    withAnimation { proxy.scrollTo("detail", anchor: .top) }
                }
        }
        .onAppear { monitor.start() }
        .onDisappear {
            monitor.stop()
            store.macDetail = nil
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            hero
            ProtectionTile(store: store, security: snapshot.security, insecure: insecure)
            // Two columns that each stack their tiles, so a tile is only as
            // tall as what it holds.
            HStack(alignment: .top, spacing: 8) {
                VStack(spacing: 8) {
                    diskTile
                    if let battery = vitals.battery { batteryTile(battery) }
                    networkTile
                }
                VStack(spacing: 8) {
                    memoryTile
                    cpuTile
                    devicesTile
                }
            }
            Group {
                switch open {
                case .disk:
                    if !store.monitor.volumes.isEmpty { DriveList(store: store, volumes: store.monitor.volumes) }
                    FreeUpList(store: store)
                case .memory:
                    if let memory = vitals.memory, memory.total > 0, memory.used > 0 { MemoryList(memory: memory) }
                    TopList(store: store, order: .memory)
                case .cpu:
                    if let sensors = vitals.sensors { SensorList(sensors: sensors) }
                    TopList(store: store, order: .cpu)
                case .battery: if let battery = vitals.battery { BatteryDetail(battery: battery) }
                case nil: EmptyView()
                }
            }
            .id("detail")
            Recommendation(advice: vitals.advice(insecure: insecure, updates: snapshot.outdated.count), act: act)
        }
    }

    private var hero: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                if vitals.memory == nil {
                    Text("Mac Health: …").font(.title2.weight(.bold))
                } else {
                    let grade = vitals.grade(insecure: insecure)
                    Text("Mac Health: \(Text(grade.rawValue).foregroundStyle(grade.color))").font(.title2.weight(.bold))
                }
                Text(monitor.model).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            LaptopArt()
        }
        .padding(.horizontal, 2)
    }

    private var diskTile: some View {
        Tile(symbol: "internaldrive", title: vitals.disk?.name ?? "Disk", link: "Free Up", selected: open == .disk,
             action: { toggle(.disk) }) {
            if let disk = vitals.disk {
                Text("Available: \(Store.bytes(disk.available))").foregroundStyle(disk.isLow ? Theme.warning : .secondary)
                Text("of \(Store.bytes(disk.total))")
            }
            if !store.monitor.volumes.isEmpty {
                Text(Store.counted(store.monitor.volumes.count, "drive") + " connected")
            }
        }
    }

    private var memoryTile: some View {
        Tile(symbol: "memorychip", title: "Memory", link: "Free Up", selected: open == .memory,
             action: { toggle(.memory) }) {
            if let m = vitals.memory {
                Text("Pressure: \(m.pressure) %").foregroundStyle(m.pressure >= 75 ? Theme.bad : m.pressure >= 50 ? Theme.warning : .secondary)
                Text("\(Store.bytes(m.used, .memory)) of \(Store.bytes(m.total, .memory)) used")
            }
        }
    }

    private func batteryTile(_ b: Battery) -> some View {
        Tile(symbol: batterySymbol(b), title: "Battery", value: Text("\(b.percent) %"), link: "Details",
             selected: open == .battery, action: { toggle(.battery) }) {
            Text(b.timeLeft.map { b.state + " · " + $0 } ?? b.state)
            if let capacity = b.capacity {
                Text("Health \(capacity) %" + (b.cycles.map { " · \($0) cycles" } ?? ""))
                    .foregroundStyle(b.needsService ? Theme.warning : .secondary)
            }
        }
    }

    private var cpuTile: some View {
        Tile(symbol: "cpu", title: "CPU", value: vitals.sensors.map(temperature), link: "Top Apps",
             selected: open == .cpu, action: { toggle(.cpu) }) {
            Text("Load: " + (vitals.cpuLoad.map { "\(Int(($0 * 100).rounded())) %" } ?? "…"))
            if let fans = vitals.sensors?.fans, !fans.isEmpty {
                Text("Fans: \(fans.reduce(0, +) / fans.count) rpm")
            }
        }
    }

    private var networkTile: some View {
        let net = vitals.network
        return Tile(symbol: net?.wifi == false ? "network" : "wifi", title: net.map { $0.wifi ? "Wi-Fi" : $0.interface } ?? "Network",
                    link: monitor.testingSpeed ? "Testing…" : "Test Speed",
                    action: { Task { await store.testSpeed() } }) {
            if let net {
                Label(Store.rate(Int64(net.up)), systemImage: "arrow.up")
                Label(Store.rate(Int64(net.down)), systemImage: "arrow.down")
            }
            if let s = monitor.speed {
                Text("Speed: \(mbps(s.down)) down, \(mbps(s.up)) up").foregroundStyle(.primary)
            }
        }
    }

    private var devicesTile: some View {
        Tile(symbol: "dot.radiowaves.left.and.right", title: "Devices") {
            if vitals.devices.isEmpty {
                Text("Nothing connected")
            }
            ForEach(vitals.devices) { d in
                HStack(spacing: 4) {
                    Image(systemName: deviceSymbol(d.kind)).frame(width: 14)
                    Text(d.name).lineLimit(1)
                    Spacer(minLength: 2)
                    if let battery = d.battery { Text("\(battery) %").monospacedDigit() }
                }
            }
        }
    }

    // MARK: Actions

    private func toggle(_ detail: Store.MacDetail) {
        show(open == detail ? nil : detail)
    }

    private func show(_ detail: Store.MacDetail?) {
        store.macDetail = detail
    }

    private func act(_ action: Advice.Action) {
        switch action {
        case .freeUp: show(.disk)
        case .memory: show(.memory)
        case .cpu: show(.cpu)
        case .security: store.tab = .health
        case .updates: store.tab = .updates
        case .battery: show(.battery)
        case .none: break
        }
    }

    // MARK: Looks

    private func temperature(_ s: Sensors) -> Text {
        Text("\(Int(s.cpuTemp.rounded()))°C").foregroundStyle(s.cpuTemp >= 95 ? Theme.bad : s.cpuTemp >= 80 ? Theme.warning : .secondary)
    }

    private func mbps(_ bits: Double) -> String { "\(Int((bits / 1_000_000).rounded())) Mbps" }

    private func batterySymbol(_ b: Battery) -> String {
        if b.charging { return "battery.100percent.bolt" }
        let level = [100, 75, 50, 25].first { b.percent >= $0 - 12 } ?? 0
        return "battery.\(level)percent"
    }

    private func deviceSymbol(_ kind: String) -> String {
        switch kind.lowercased() {
        case "headset", "headphones": "headphones"
        case "keyboard": "keyboard"
        case "mouse": "computermouse"
        case "speaker": "hifispeaker"
        default: "dot.radiowaves.right"
        }
    }
}

/// A card in the grid: a title, a value on the right, a few lines, and a
/// link that opens what it is about.
private struct Tile<Lines: View>: View {
    let symbol: String
    let title: String
    var value: Text?
    var link: String?
    var selected = false
    var action: () -> Void = {}
    @ViewBuilder let lines: Lines

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol).foregroundStyle(.white.opacity(0.9)).frame(width: 18)
                Text(title).font(.callout.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                if let value { value.font(.caption.monospacedDigit().weight(.semibold)) }
            }
            // The link sits beside the last line, as CleanMyMac's do.
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                VStack(alignment: .leading, spacing: 3) { lines }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let link {
                    Button(link, action: action).buttonStyle(.zcLink).font(.callout.weight(.semibold))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .modifier(Card(selected: selected))
    }
}

/// The Mac in the hero: a glossy cyan screen on a silver base.
private struct LaptopArt: View {
    var body: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 5)
                .fill(LinearGradient(colors: [Color(red: 0.62, green: 0.93, blue: 1), Color(red: 0.24, green: 0.58, blue: 1)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(alignment: .top) {
                    // The glare across the top of the screen.
                    RoundedRectangle(cornerRadius: 5)
                        .fill(LinearGradient(colors: [.white.opacity(0.45), .clear], startPoint: .top, endPoint: .center))
                }
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(white: 0.9), lineWidth: 2.5))
                .frame(width: 54, height: 36)
            UnevenRoundedRectangle(bottomLeadingRadius: 4, bottomTrailingRadius: 4)
                .fill(LinearGradient(colors: [Color(white: 0.96), Color(red: 0.62, green: 0.72, blue: 0.9)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 68, height: 6)
        }
        .shadow(color: Theme.accent.opacity(0.55), radius: 12)
    }
}

/// The doctor's security checks as one card; a click opens the Health tab.
private struct ProtectionTile: View {
    let store: Store
    let security: [Check]
    let insecure: Int

    var body: some View {
        let passing = security.filter(\.isOK)
        Button { store.tab = .health } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: insecure == 0 ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .font(.title2)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, insecure == 0 ? Theme.good : Theme.warning)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Text("Protection by")
                        BrandMark.image(size: 13)
                        Text("ZC Doctor")
                    }
                    .font(.callout.weight(.semibold))
                    Text("\(passing.count) of \(security.count) security checks pass")
                        .font(.caption.weight(.medium))
                    Text(passing.prefix(3).map(\.title).joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Label(insecure == 0 ? "Protected" : "\(insecure) to fix",
                      systemImage: insecure == 0 ? "checkmark" : "exclamationmark.triangle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(insecure == 0 ? .white : Theme.warning)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(Card())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open the Health tab")
    }
}

private struct Recommendation: View {
    let advice: Advice
    let act: (Advice.Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Today's Recommendation").font(.headline).padding(.top, 6).padding(.leading, 2)
            HStack(alignment: .top, spacing: 12) {
                SymbolTile(symbol: symbol, colors: tint, size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(advice.title).font(.callout.weight(.semibold))
                    Text(advice.body).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let button = advice.button {
                        HStack {
                            Spacer()
                            Button(button) { act(advice.action) }
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(Card())
        }
    }

    private var symbol: String {
        switch advice.action {
        case .freeUp: "internaldrive"
        case .memory: "memorychip"
        case .cpu: "thermometer.high"
        case .battery: "battery.25percent"
        case .security: "lock.shield"
        case .updates: "arrow.down.circle"
        case .none: "sparkles"
        }
    }

    private var tint: [Color] {
        switch advice.action {
        case .none: Tint.cyan
        case .updates: Tint.blue
        case .security: Tint.orange
        default: Tint.pink
        }
    }
}

/// What can be ejected, each with its space and an Eject button.
private struct DriveList: View {
    let store: Store
    let volumes: [Volume]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle(title: "Drives", count: volumes.count)
            ListCard {
                ForEach(volumes) { volume in
                    HStack(spacing: 8) {
                        Image(systemName: volume.isLocal ? "externaldrive" : "server.rack")
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(volume.name).lineLimit(1)
                            Text(detail(volume)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if store.monitor.ejecting.contains(volume.path) {
                            ProgressView().controlSize(.small)
                        } else {
                            Button {
                                Task { await store.eject(volume) }
                            } label: {
                                Image(systemName: "eject.fill")
                            }
                            .buttonStyle(.borderless)
                            .help("Eject “\(volume.name)”")
                            .accessibilityLabel("Eject \(volume.name)")
                        }
                    }
                    .modifier(Hover())
                }
            }
        }
    }

    private func detail(_ volume: Volume) -> String {
        guard volume.total > 0 else { return volume.kind }
        return "\(volume.kind) · \(Store.bytes(volume.available)) free of \(Store.bytes(volume.total))"
    }
}

/// The folders Free Up can clear, each with its size, and the Trash.
private struct FreeUpList: View {
    let store: Store

    var body: some View {
        let spots = Junk.spots(home: NSHomeDirectory())
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SectionTitle(title: "Free Up")
                if let total = total(spots) {
                    Text(Store.bytes(total)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                }
                Spacer()
                if store.monitor.scanning {
                    ProgressView().controlSize(.mini)
                } else {
                    Button("Rescan") { Task { await store.monitor.scan() } }.buttonStyle(.zcLink).font(.caption)
                }
            }
            ListCard {
            ForEach(spots) { spot in
                let size = store.monitor.junk[spot.id]
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(spot.title).lineLimit(1)
                        Text(spot.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(size.map { Store.bytes($0) } ?? "…").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Button("Clear") { Task { await store.clean(spot) } }
                        .controlSize(.small)
                        .disabled(store.busy != nil || (size ?? 0) == 0)
                }
                .modifier(Hover())
            }
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Trash")
                    Text("What is in it is deleted for good.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Empty") { Task { await store.emptyTrash() } }
                    .controlSize(.small)
                    .disabled(store.busy != nil)
            }
            .modifier(Hover())
            }
        }
    }

    private func total(_ spots: [Junk]) -> Int64? {
        let sizes = spots.compactMap { store.monitor.junk[$0.id] }
        return sizes.isEmpty ? nil : sizes.reduce(0, +)
    }
}

/// What macOS and the battery itself say about its wear and charge.
private struct BatteryDetail: View {
    let battery: Battery

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SectionTitle(title: "Battery")
                Spacer()
                Button("Battery Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!)
                }
                .buttonStyle(.zcLink).font(.caption)
            }
            ListCard {
                ValueRow(title: "Condition", value: battery.health.map { $0 == "Good" ? "Normal" : $0 } ?? "…", warn: battery.isWorn)
                ValueRow(title: "Maximum capacity", value: battery.capacity.map { "\($0) %" } ?? "…", warn: battery.isFaded)
                ValueRow(title: "Charge cycles", value: battery.cycles.map(String.init) ?? "…")
                if let t = battery.temperature {
                    ValueRow(title: "Temperature", value: "\(Int(t.rounded())) °C", warn: t >= 40)
                }
                if battery.countsDown {
                    ValueRow(title: battery.charging ? "Time to full" : "Time left", value: battery.clock ?? "Estimating…")
                } else {
                    ValueRow(title: "Power", value: battery.state)
                }
                if let watts = battery.adapterWatts { ValueRow(title: "Charger", value: "\(watts) W") }
            }
        }
    }
}

/// A reading in a detail list: a name and its value on the right.
private struct ValueRow: View {
    let title: String
    let value: String
    var warn = false

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).font(.callout.monospacedDigit()).foregroundStyle(warn ? Theme.warning : .secondary)
        }
        .modifier(Hover())
    }
}

/// What memory holds, as one bar and a row for each part, and swap.
private struct MemoryList: View {
    let memory: Memory

    private var parts: [(title: String, bytes: Int64, color: Color)] {
        [("App memory", memory.app, Theme.accent), ("Wired", memory.wired, Theme.violet),
         ("Compressed", memory.compressed, Theme.warning), ("Cached files", memory.cached, Theme.good)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle(title: "Memory")
            ListCard {
                bar.padding(.vertical, 4)
                ForEach(parts, id: \.title) { part in
                    HStack(spacing: 6) {
                        Circle().fill(part.color).frame(width: 7, height: 7)
                        ValueRow(title: part.title, value: Store.bytes(part.bytes, .memory))
                    }
                }
                HStack(spacing: 6) {
                    Circle().fill(.quaternary).frame(width: 7, height: 7)
                    ValueRow(title: "Free", value: Store.bytes(memory.free, .memory))
                }
                HStack(spacing: 6) {
                    Color.clear.frame(width: 7, height: 7)
                    ValueRow(title: "Swap used", value: memory.swapUsed > 0 ? Store.bytes(memory.swapUsed, .memory) : "None",
                             warn: memory.isSwapping)
                }
            }
        }
    }

    private var bar: some View {
        GeometryReader { geo in
            // Scaled to the larger of the parts and RAM, so the bar never spills.
            let scale = geo.size.width / CGFloat(max(memory.total, parts.reduce(0) { $0 + $1.bytes }))
            HStack(spacing: 0) {
                ForEach(parts, id: \.title) { part in
                    part.color.frame(width: CGFloat(part.bytes) * scale)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 8)
        .background(.quaternary)
        .clipShape(Capsule())
        .accessibilityElement()
        .accessibilityLabel("\(Store.bytes(memory.used, .memory)) of \(Store.bytes(memory.total, .memory)) used")
    }
}

/// What macmon reads beyond the CPU tile: the GPU, each fan against its
/// top speed, and the power drawn.
private struct SensorList: View {
    let sensors: Sensors

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle(title: "Sensors")
            ListCard {
                ValueRow(title: "CPU temperature", value: degrees(sensors.cpuTemp), warn: sensors.cpuTemp >= 80)
                if let t = sensors.gpuTemp { ValueRow(title: "GPU temperature", value: degrees(t), warn: t >= 80) }
                if let load = sensors.gpuLoad { ValueRow(title: "GPU load", value: "\(Int((load * 100).rounded())) %") }
                ForEach(Array(sensors.fans.enumerated()), id: \.offset) { i, rpm in
                    let limit = i < sensors.fanLimits.count ? sensors.fanLimits[i] : nil
                    ValueRow(title: sensors.fans.count > 1 ? "Fan \(i + 1)" : "Fan",
                             value: limit.map { "\(rpm) of \($0) rpm" } ?? "\(rpm) rpm")
                }
                if let w = sensors.cpuPower { ValueRow(title: "CPU power", value: watts(w)) }
                if let w = sensors.gpuPower { ValueRow(title: "GPU power", value: watts(w)) }
                if let w = sensors.systemPower { ValueRow(title: "Whole Mac power", value: watts(w)) }
            }
        }
    }

    private func degrees(_ t: Double) -> String { "\(Int(t.rounded())) °C" }

    private func watts(_ w: Double) -> String { String(format: w < 10 ? "%.1f W" : "%.0f W", w) }
}

/// The busiest processes by memory or CPU; an app can be quit from here.
private struct TopList: View {
    let store: Store
    let order: Monitor.Order

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle(title: order == .memory ? "Using the most memory" : "Using the most CPU")
            ListCard {
            if store.monitor.top.isEmpty {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            }
            ForEach(store.monitor.top) { proc in
                let app = NSRunningApplication(processIdentifier: proc.pid)
                HStack(spacing: 8) {
                    if let icon = app?.icon {
                        Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "gearshape").foregroundStyle(.secondary).frame(width: 16)
                    }
                    Text(app?.localizedName ?? proc.name).lineLimit(1)
                    Spacer()
                    Text(order == .memory ? Store.bytes(proc.memory, .memory) : "\(Int(proc.cpu.rounded())) %")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    if let app, app.activationPolicy == .regular, app != .current {
                        Button("Quit") { store.quit(app) }.controlSize(.small).gatedOnBusy(store)
                    }
                }
                .modifier(Hover())
            }
            }
        }
    }
}

extension Grade {
    var color: Color {
        switch self {
        case .excellent: Theme.accent
        case .good: Theme.good
        case .fair: Theme.warning
        case .poor: Theme.bad
        }
    }
}
