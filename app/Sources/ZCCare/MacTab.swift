import AppKit
import Charts
import CoreWLAN
import SwiftUI
import ZCCareCore

extension EnvironmentValues {
    /// Which window the panel's views are in; the floating panel sets it.
    @Entry var panelHost: Monitor.Host = .menu
}

/// The Mac itself: a grade, protection, a tile for each vital, and one
/// recommendation. It samples only while it shows.
struct MacTab: View {
    @Bindable var store: Store
    let snapshot: Snapshot
    @Environment(\.panelHost) private var host
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
        .onAppear { monitor.start(host: host) }
        .onDisappear {
            monitor.stop(host: host)
            // The other host's tab may still show it.
            if !monitor.readers.contains(.panel) { store.macDetail = nil }
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
                    DiskActivity(io: vitals.diskIO)
                    if !store.monitor.volumes.isEmpty { DriveList(store: store, volumes: store.monitor.volumes) }
                    FreeUpList(store: store)
                case .memory:
                    HistoryChart(title: "Memory Used", monitor: monitor, history: \.memoryHistory)
                    if let memory = vitals.memory, memory.total > 0, memory.used > 0 { MemoryList(memory: memory) }
                    TopList(store: store, order: .memory)
                case .cpu:
                    HistoryChart(title: "CPU Load", monitor: monitor, history: \.cpuHistory)
                    if let tiers = vitals.sensors?.tiers, !tiers.isEmpty { CoreList(tiers: tiers) }
                    if let sensors = vitals.sensors { SensorList(sensors: sensors) }
                    TopList(store: store, order: .cpu)
                case .battery:
                    if let battery = vitals.battery { BatteryDetail(battery: battery) }
                    AwakeList(store: store)
                    SleepList(store: store)
                    TopList(store: store, order: .cpu)
                case .network: NetworkDetail(store: store)
                case .devices: DevicesDetail()
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
                    link: "Details", selected: open == .network, action: { toggle(.network) }) {
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
        Tile(symbol: "dot.radiowaves.left.and.right", title: "Devices", link: "Details", selected: open == .devices,
             action: { toggle(.devices) }) {
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
                    .accessibilityHidden(true)
                // The group and its link carry the title already.
                Text(title).font(.callout.weight(.semibold)).lineLimit(1).accessibilityHidden(true)
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
                    // Several tiles share a link name: name the tile too.
                    Button(link, action: action).buttonStyle(.zcLink).font(.callout.weight(.semibold))
                        .accessibilityLabel("\(title) \(link)")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
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

/// What every drive reads and writes now. A dash until the second read.
private struct DiskActivity: View {
    let io: DiskIO?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle(title: "Activity")
            ListCard {
                ValueRow(title: "Reading", value: io.map { Store.rate(Int64($0.read)) } ?? "–")
                ValueRow(title: "Writing", value: io.map { Store.rate(Int64($0.write)) } ?? "–")
            }
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

/// The connection's addresses, router and DNS, the last speed test, and
/// the user's apps waiting for connections.
private struct NetworkDetail: View {
    let store: Store
    @State private var listeners: [Listener]?
    @State private var listenersFailed = false
    @State private var reading = false

    private var monitor: Monitor { store.monitor }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let connection = monitor.connection {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        SectionTitle(title: "Connection")
                        Spacer()
                        Button("Network Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension")!)
                        }
                        .buttonStyle(.zcLink).font(.caption)
                    }
                    ListCard {
                        ValueRow(title: "Service", value: connection.service == connection.interface
                                 ? connection.interface : "\(connection.service) (\(connection.interface))")
                        ForEach(connection.addresses, id: \.self) { address in
                            ValueRow(title: address.contains(":") ? "IPv6 address" : "IP address", value: address)
                        }
                        if let mask = connection.subnetMask { ValueRow(title: "Subnet mask", value: mask) }
                        if let router = connection.router { ValueRow(title: "Router", value: router) }
                        if !connection.dns.isEmpty { ValueRow(title: "DNS", value: connection.dns.joined(separator: ", ")) }
                        if !connection.searchDomains.isEmpty {
                            ValueRow(title: "Search domains", value: connection.searchDomains.joined(separator: ", "))
                        }
                        ForEach(connection.proxies, id: \.self) { proxy in ValueRow(title: "Proxy", value: proxy) }
                        if !connection.tunnels.isEmpty { ValueRow(title: "VPN", value: connection.tunnels.joined(separator: ", ")) }
                    }
                    .textSelection(.enabled)
                }
                if monitor.vitals.network?.wifi == true { WiFiLinkSection(store: store, interface: connection.interface) }
            } else {
                Text(monitor.connectionRead ? "Not connected" : "…").foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    SectionTitle(title: "Speed")
                    Spacer()
                    if monitor.testingSpeed {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(monitor.speed == nil ? "Test Speed" : "Test Again") { Task { await store.testSpeed() } }
                            .buttonStyle(.zcLink).font(.caption)
                    }
                }
                ListCard {
                    ValueRow(title: "Download", value: monitor.speed.map { mbps($0.down) } ?? "–")
                    ValueRow(title: "Upload", value: monitor.speed.map { mbps($0.up) } ?? "–")
                    if let latency = monitor.speed?.latency {
                        ValueRow(title: "Latency", value: "\(Int(latency.rounded())) ms", warn: latency >= 100)
                    }
                }
            }
            TrafficList(store: store)
            listening
        }
        .task { await readListeners() }
    }

    private var listening: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SectionTitle(title: "Listening")
                Spacer()
                if reading {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Refresh") { Task { await readListeners() } }.buttonStyle(.zcLink).font(.caption)
                }
            }
            ListCard {
                if !listenersFailed, let listeners, !listeners.isEmpty {
                    ForEach(listeners) { listener in
                        ValueRow(title: NSRunningApplication(processIdentifier: listener.pid)?.localizedName ?? listener.command,
                                 value: "\(listener.port) · \(listener.reachable ? "Network" : "This Mac")")
                    }
                } else {
                    Text(listenersFailed ? "Could not read the open ports." : listeners == nil ? "…" : "None of your apps is waiting for connections.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Text("Your apps waiting for connections on a port. Network means other devices can try to connect, unless the firewall stops them.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func readListeners() async {
        guard !reading else { return }
        reading = true
        defer { reading = false }
        let read = await Listener.read(runner: ProcessRunner(timeout: 10))
        listenersFailed = read == nil
        // A failed refresh shows the failure, not the rows from before.
        listeners = read
    }
}

/// The processes moving the most data now, measured while the detail shows:
/// a hidden panel keeps its views, so the loop stops with the panel's
/// reading. nettop takes about five seconds a reading, and little CPU.
private struct TrafficList: View {
    let store: Store
    @State private var traffic: [AppTraffic]?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle(title: "Apps Using the Network")
            ListCard {
                if !failed, let traffic, !traffic.isEmpty {
                    ForEach(traffic.prefix(5)) { app in
                        HStack {
                            Text(NSRunningApplication(processIdentifier: app.pid)?.localizedName
                                 ?? SleepBlocker.processName(app.pid) ?? app.name)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text("↓ \(Store.rate(Int64(app.down)))  ↑ \(Store.rate(Int64(app.up)))")
                                .font(.callout.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
                                .accessibilityLabel("receiving \(Store.rate(Int64(app.down))), sending \(Store.rate(Int64(app.up)))")
                        }
                        .accessibilityElement(children: .combine)
                        .modifier(Hover())
                    }
                } else {
                    Text(failed ? "Could not read the network use." : traffic == nil ? "Measuring…" : "No app is using the network.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .task(id: store.monitor.readers.contains(.panel)) {
            guard store.monitor.readers.contains(.panel) else { return }
            // Rates from before the panel hid are not current.
            traffic = nil
            failed = false
            var last: (at: Date, totals: [Int32: AppTraffic.Totals])?
            while !Task.isCancelled, store.monitor.readers.contains(.panel) {
                let started = Date.now
                guard let totals = await AppTraffic.read(runner: ProcessRunner(timeout: 15)) else {
                    guard !Task.isCancelled else { return }
                    failed = true
                    last = nil
                    try? await Task.sleep(for: .seconds(10))
                    continue
                }
                let now = Date.now
                if let last {
                    failed = false
                    traffic = AppTraffic.rates(from: last.totals, to: totals, over: now.timeIntervalSince(last.at))
                }
                last = (now, totals)
                // nettop takes about five seconds; never run it back to back.
                try? await Task.sleep(for: .seconds(max(0, 5 - now.timeIntervalSince(started))))
            }
        }
    }
}

/// The Wi-Fi link when the connection is Wi-Fi, read again every five
/// seconds while the panel shows; nothing for Ethernet or a link that is down.
private struct WiFiLinkSection: View {
    let store: Store
    let interface: String
    @State private var link: WiFiLink?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let link {
                SectionTitle(title: "Wi-Fi")
                ListCard {
                    ValueRow(title: "Signal", value: "\(link.quality.rawValue) · \(link.rssi) dBm"
                             + (link.noise.map { ", noise \($0) dBm" } ?? ""), warn: link.quality == .poor)
                    if let standard = link.standard { ValueRow(title: "Standard", value: standard) }
                    ValueRow(title: "Channel", value: link.channelText)
                    ValueRow(title: "Transmit rate", value: "\(Int(link.rate)) Mbps")
                    ValueRow(title: "Security", value: link.securityText, warn: link.isInsecure)
                    if link.isInsecure {
                        Text("Others nearby can read what is not otherwise encrypted on this network.")
                            .font(.caption).foregroundStyle(Theme.warning)
                    }
                }
            }
        }
        .task(id: [store.monitor.readers.contains(.panel) ? interface : ""]) {
            while !Task.isCancelled, store.monitor.readers.contains(.panel) {
                // CoreWLAN asks the Wi-Fi daemon, which can stall while it scans.
                link = await Task.detached { Self.read(interface) }.value
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    nonisolated private static func read(_ name: String) -> WiFiLink? {
        guard let wifi = CWWiFiClient.shared().interface(withName: name), wifi.powerOn() else { return nil }
        let rssi = wifi.rssiValue()
        guard rssi != 0, let channel = wifi.wlanChannel() else { return nil }
        let noise = wifi.noiseMeasurement()
        return WiFiLink(rssi: rssi, noise: noise < 0 ? noise : nil, rate: wifi.transmitRate(),
                        phy: wifi.activePHYMode().rawValue, security: wifi.security().rawValue,
                        channel: channel.channelNumber, band: channel.channelBand.rawValue,
                        width: channel.channelWidth.rawValue)
    }
}

/// The displays in use and what is plugged into the USB ports; the
/// Bluetooth devices are on the tile.
private struct DevicesDetail: View {
    @State private var screens = NSScreen.screens
    @State private var usb: [String]?
    @State private var usbFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    SectionTitle(title: "Displays")
                    Spacer()
                    Button("Displays Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!)
                    }
                    .buttonStyle(.zcLink).font(.caption)
                }
                ListCard {
                    ForEach(screens, id: \.self) { screen in
                        ValueRow(title: screen.localizedName, value: Self.describe(screen))
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                SectionTitle(title: "USB")
                ListCard {
                    if !usbFailed, let usb, !usb.isEmpty {
                        ForEach(Array(usb.enumerated()), id: \.offset) { _, name in
                            Text(name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).modifier(Hover())
                        }
                    } else {
                        Text(usbFailed ? "Could not read the USB devices." : usb == nil ? "…" : "Nothing plugged into USB.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task { await readUSB() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = NSScreen.screens
        }
    }

    private func readUSB() async {
        let read = await USBDevices.read(runner: ProcessRunner(timeout: 15))
        usbFailed = read == nil
        usb = read
    }

    /// "External · 3840 × 2160 · 60 Hz": the pixels drawn, not the size
    /// macOS lays things out at. A built-in display says so in its name.
    private static func describe(_ screen: NSScreen) -> String {
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        let pixels = screen.convertRectToBacking(screen.frame).size
        var parts = id.flatMap { CGDisplayIsBuiltin($0) == 0 ? ["External"] : nil } ?? []
        parts.append("\(Int(pixels.width)) × \(Int(pixels.height))")
        if screen.maximumFramesPerSecond > 0 { parts.append("\(screen.maximumFramesPerSecond) Hz") }
        return parts.joined(separator: " · ")
    }
}

private func mbps(_ bits: Double) -> String { "\(Int((bits / 1_000_000).rounded())) Mbps" }

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

/// The apps that stop the Mac, or its screen, sleeping when idle, read
/// again every five seconds while the panel shows; a hidden panel keeps its
/// views, so the loop stops with the panel's reading, not on disappear.
private struct AwakeList: View {
    let store: Store
    @State private var blockers: [SleepBlocker]?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle(title: "Keeping Awake")
            ListCard {
                if let blockers, !blockers.isEmpty {
                    ForEach(blockers) { row($0) }
                } else {
                    Text(failed ? "Could not ask macOS what keeps it awake." : blockers == nil ? "…" : "Nothing keeps the Mac awake.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .task(id: store.monitor.readers.contains(.panel)) {
            while !Task.isCancelled, store.monitor.readers.contains(.panel) {
                read()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func read() {
        let read = SleepBlocker.read { NSRunningApplication(processIdentifier: $0)?.localizedName ?? SleepBlocker.processName($0) }
        failed = read == nil
        blockers = read
    }

    private func row(_ blocker: SleepBlocker) -> some View {
        let app = NSRunningApplication(processIdentifier: blocker.pid)
        let what = blocker.display ? "Screen on" : "Awake"
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(blocker.name).lineLimit(1)
                if let via = blocker.via { Text("through \(via)").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Text([what, blocker.held(at: .now)].compactMap { $0 }.joined(separator: " · "))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            if let app, app.activationPolicy == .regular, app != .current {
                Button("Quit") {
                    store.quit(app)
                    // Drop the row once the app is gone, not at the next five-second read.
                    Task {
                        try? await Task.sleep(for: .seconds(1))
                        read()
                    }
                }
                .controlSize(.small).gatedOnBusy(store)
            }
        }
        .modifier(Hover())
    }
}

/// How the Mac slept over the last day, from the power management log.
/// pmset takes seconds of CPU to print it, so a reading is kept for five
/// minutes across detail switches, not taken on a loop.
private struct SleepList: View {
    let store: Store
    @State private var log = Self.kept?.log
    @State private var failed = false
    @MainActor private static var kept: (log: SleepLog, at: Date)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle(title: "Sleep")
            ListCard {
                if let log {
                    ValueRow(title: "Last slept", value: Self.describe(log.lastSleep))
                    ValueRow(title: "Last woke", value: Self.describe(log.lastWake))
                    ValueRow(title: "Upkeep wakes, past day", value: "\(log.darkWakes)")
                    ValueRow(title: "Battery used asleep, past day", value: "\(log.drained) %", warn: log.drained >= 10)
                    if failed {
                        Text("Could not read the sleep log again; this is an earlier reading.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text(failed ? "Could not read the sleep log." : "Reading the sleep log…")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .task(id: store.monitor.readers.contains(.panel)) {
            guard store.monitor.readers.contains(.panel),
                  Self.kept.map({ Date.now.timeIntervalSince($0.at) > 300 }) ?? true else { return }
            let read = await SleepLog.read(runner: ProcessRunner(timeout: 30))
            guard !Task.isCancelled else { return }
            failed = read == nil
            if let read {
                log = read
                Self.kept = (read, .now)
            }
        }
    }

    /// "Lid closed · Thu 19:11", with the date once a week could make the
    /// weekday ambiguous.
    private static func describe(_ event: SleepLog.Event?) -> String {
        guard let event else { return "Not in the last log" }
        var format = Date.FormatStyle().weekday(.abbreviated).hour().minute()
        if Date.now.timeIntervalSince(event.at) > 6 * 86_400 { format = format.day().month(.abbreviated) }
        return "\(event.reason) · \(event.at.formatted(format))"
    }
}

/// A reading in a detail list: a name and its value on the right.
private struct ValueRow: View {
    let title: String
    let value: String
    var warn = false

    var body: some View {
        HStack {
            Text(title).fixedSize()
            Spacer()
            Text(value).font(.callout.monospacedDigit()).foregroundStyle(warn ? Theme.warning : .secondary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
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

/// A share, 0 to 1, over the last five minutes or as long as it has been
/// read, with its peak. It reads the history itself, so a new reading
/// redraws only the chart.
private struct HistoryChart: View {
    let title: String
    let monitor: Monitor
    let history: KeyPath<Monitor, Recent>
    @State private var copied = false

    var body: some View {
        let recent = monitor[keyPath: history]
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle(title: title)
                Spacer()
                if let peak = recent.peak, recent.values.count >= 2 {
                    Text("Peak \(percent(peak)) · last \(recent.span)").font(.caption).foregroundStyle(.secondary)
                    Button(copied ? "Copied" : "Copy Readings") { copy(recent) }
                        .buttonStyle(.zcLink).font(.caption)
                        .help("Copy each reading with its time, for a spreadsheet")
                }
            }
            .task(id: copied) {
                guard copied else { return }
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled { copied = false }
            }
            ListCard {
                // The space stays while the first readings come, so what is
                // below does not jump.
                if recent.values.count >= 2 {
                    chart(recent)
                } else {
                    Text("Reading…").font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 64)
                }
            }
        }
    }

    private func copy(_ recent: Recent) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(recent.table(column: title), forType: .string)
        copied = true
    }

    private func chart(_ recent: Recent) -> some View {
        Chart {
            ForEach(Array(recent.values.enumerated()), id: \.offset) { item in
                AreaMark(x: .value("Reading", item.offset), y: .value("Share", item.element))
                    .foregroundStyle(Theme.accent.opacity(0.2))
                LineMark(x: .value("Reading", item.offset), y: .value("Share", item.element))
                    .foregroundStyle(Theme.accent)
            }
        }
        .chartXScale(domain: 0...(recent.capacity - 1))
        .chartYScale(domain: 0...1)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(values: [0, 0.5, 1]) { value in
                AxisGridLine()
                AxisValueLabel { Text(percent(value.as(Double.self) ?? 0)) }
            }
        }
        .frame(height: 64)
        .accessibilityElement()
        .accessibilityLabel("\(title) over the last \(recent.span): now \(percent(recent.values.last ?? 0)), peak \(percent(recent.peak ?? 0))")
    }

    private func percent(_ share: Double) -> String { "\(Int((share * 100).rounded())) %" }
}

/// Each kind of core with its load and clock, and a bar for each core.
private struct CoreList: View {
    let tiers: [CoreTier]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle(title: "Cores", count: tiers.reduce(0) { $0 + $1.cores.count }.nonZero)
            ListCard {
                ForEach(Array(tiers.enumerated()), id: \.offset) { _, tier in
                    VStack(alignment: .leading, spacing: 4) {
                        ValueRow(title: tier.title, value: value(tier), warn: tier.load >= 0.9)
                        if !tier.cores.isEmpty { bars(tier) }
                    }
                }
            }
        }
    }

    private func value(_ tier: CoreTier) -> String {
        let clock = tier.megahertz > 0 ? String(format: "%.1f GHz · ", Double(tier.megahertz) / 1000) : ""
        return clock + "\(Int((tier.load * 100).rounded())) %"
    }

    private func bars(_ tier: CoreTier) -> some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(tier.cores.enumerated()), id: \.offset) { _, load in
                ZStack(alignment: .bottom) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(load >= 0.9 ? Theme.warning : Theme.accent)
                        .frame(height: max(2, 22 * min(1, load)))
                }
                .frame(maxWidth: 14)
                .frame(height: 22)
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 2)
        .accessibilityElement()
        .accessibilityLabel(tier.title + ": " + tier.cores.enumerated()
            .map { "core \($0.offset + 1) \(Int(($0.element * 100).rounded())) %" }.joined(separator: ", "))
    }
}

private extension Int {
    var nonZero: Int? { self > 0 ? self : nil }
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
