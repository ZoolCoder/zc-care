import AppKit
import SwiftUI
import ZCCareCore

// MARK: Space Lens

/// The home folder as rings: each ring a level down, each arc a folder's
/// share of its parent. Clicking an arc goes into it.
struct SpaceLensView: View {
    @Bindable var care: Care
    @State private var focus: String?
    @State private var hover: SpaceNode?
    @State private var part = Part.home

    enum Part: String, CaseIterable { case home = "Home Folder", disk = "Startup Disk" }

    var body: some View {
        VStack(spacing: 0) {
            CareHeader(title: "Space Lens", subtitle: subtitle, busy: care.scanningSpace,
                   action: (care.space == nil ? "Scan" : "Rescan", { Task { await care.scanSpace() } }),
                   stop: care.stopSpaceScan)
            Picker("Show", selection: $part) {
                ForEach(Part.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.bottom, 12)
            if part == .disk {
                StartupDiskView(care: care)
            } else if let root = care.space?.root {
                let node = focus.flatMap(root.find) ?? root
                HStack(alignment: .top, spacing: 24) {
                    Sunburst(node: node, hover: $hover) { focus = $0.path }
                        .frame(minWidth: 240, idealWidth: 420, maxWidth: 420)
                        .aspectRatio(1, contentMode: .fit)
                        .overlay {
                            VStack(spacing: 4) {
                                Text((hover ?? node).name).font(.headline).lineLimit(1)
                                Text(Store.bytes((hover ?? node).size)).font(.title2.weight(.bold))
                                if node.path != root.path {
                                    Button("Back") { focus = (node.path as NSString).deletingLastPathComponent }
                                        .controlSize(.small)
                                }
                            }
                            .frame(width: 130)
                        }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(node.path == root.path ? "Home" : (node.path as NSString).abbreviatingWithTildeInPath)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).padding(.bottom, 6)
                        growers(node)
                        ForEach(Array(node.children.enumerated()), id: \.element.id) { i, child in
                            Button { if !child.children.isEmpty { focus = child.path } } label: {
                                HStack {
                                    Circle().fill(Sunburst.color(i, depth: 0)).frame(width: 9, height: 9)
                                    Text(child.name).lineLimit(1)
                                    if let grew = care.space?.growth(of: child.path), grew >= SpaceScan.noticeable {
                                        Text("+" + Store.bytes(grew)).font(.caption).foregroundStyle(Theme.warning)
                                    }
                                    Spacer()
                                    Text(Store.bytes(child.size)).monospacedDigit().foregroundStyle(.secondary)
                                    // Only folders measured further down open.
                                    Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                                        .foregroundStyle(.tertiary).opacity(child.children.isEmpty ? 0 : 1)
                                    Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: child.path)]) } label: {
                                        Image(systemName: "magnifyingglass").accessibilityLabel("Show in Finder")
                                    }
                                    .buttonStyle(.plain)
                                    .help("Show in Finder")
                                    if SpaceLens.canTrash(child.path, home: NSHomeDirectory()) {
                                        Button { trash(child) } label: {
                                            Image(systemName: "trash").accessibilityLabel(removalVerb(care.store))
                                        }
                                        .buttonStyle(.plain)
                                        .help(removalVerb(care.store))
                                        .gatedOnBusy(care.store)
                                    }
                                }
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(child.children.isEmpty ? child.name : "Open \(child.name)")
                            .contextMenu {
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: child.path)]) }
                                if SpaceLens.canTrash(child.path, home: NSHomeDirectory()) {
                                    Divider()
                                    Button(removalVerb(care.store) + "…") { trash(child) }
                                        .gatedOnBusy(care.store)
                                }
                            }
                        }
                        Text("Use a folder's trash button to \(care.store.deletesPermanently ? "delete" : "move") it\(care.store.deletesPermanently ? "" : " to the Trash"). Your home folder's own folders, hidden ones, the Library and synced folders stay.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 10)
                    }
                    .font(.callout)
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 28)
            } else {
                VStack(spacing: 14) {
                    Spacer()
                    HeroArt(symbol: "chart.pie.fill", colors: Tint.blue, size: 110)
                    Text(care.scanningSpace ? "Measuring your home folder…" : "See what fills your home folder")
                        .font(.title2.weight(.bold))
                    Text("du reads every folder; it takes a few minutes, and the result is kept.")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear(perform: takeDiskRequest)
        .onChange(of: care.showStartupDisk) { takeDiskRequest() }
    }

    private func takeDiskRequest() {
        guard care.showStartupDisk else { return }
        care.showStartupDisk = false
        part = .disk
    }

    /// What grew most since the previous scan inside this folder, each with
    /// the module that cleans that kind of folder, where one does.
    @ViewBuilder private func growers(_ node: SpaceNode) -> some View {
        let grown = care.space?.growers(under: node.path) ?? []
        if !grown.isEmpty, let since = care.space?.previousAt {
            VStack(alignment: .leading, spacing: 4) {
                Text("Grew since \(since.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(grown) { grower in
                    HStack {
                        Text((grower.path as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text("+" + Store.bytes(grower.grew)).monospacedDigit().foregroundStyle(Theme.warning)
                        if let module = SpaceDestination.of(grower.path, home: NSHomeDirectory()).map(Self.module) {
                            Button(module.rawValue) { care.open(module) }
                                .buttonStyle(.zcLink).font(.caption)
                                .help("Open \(module.rawValue) to clean it up")
                        }
                    }
                }
            }
            .padding(.bottom, 10)
        }
    }

    private func trash(_ node: SpaceNode) {
        Task { await care.trash(LargeFile(url: URL(fileURLWithPath: node.path), size: node.size), within: NSHomeDirectory()) }
    }

    private static func module(_ destination: SpaceDestination) -> Care.Module {
        switch destination {
        case .clutter: .clutter
        case .developer: .developer
        case .cloud: .cloud
        }
    }

    private var subtitle: String {
        guard let space = care.space else { return "Folders by size, three levels down" }
        return "\(Store.bytes(space.root.size)) in your home folder, measured " + relativeDate(space.scannedAt)
    }
}

struct Sunburst: View {
    let node: SpaceNode
    @Binding var hover: SpaceNode?
    let open: (SpaceNode) -> Void

    private struct Arc: Identifiable {
        var node: SpaceNode
        var start: Double
        var end: Double
        var depth: Int
        var color: Color
        var id: String { node.path }
    }

    static func color(_ i: Int, depth: Int) -> Color {
        Color(hue: (Double(i) * 0.13 + 0.78).truncatingRemainder(dividingBy: 1), saturation: 0.65 - Double(depth) * 0.12,
              brightness: 0.95 - Double(depth) * 0.08)
    }

    private var arcs: [Arc] {
        var out: [Arc] = []
        func walk(_ n: SpaceNode, from start: Double, span: Double, depth: Int, hue: Int?) {
            guard depth < 3, n.size > 0 else { return }
            var at = start
            for (i, child) in n.children.enumerated() {
                let share = span * Double(child.size) / Double(n.size)
                let h = hue ?? i
                out.append(Arc(node: child, start: at, end: at + share, depth: depth, color: Self.color(h, depth: depth)))
                walk(child, from: at, span: share, depth: depth + 1, hue: h)
                at += share
            }
        }
        walk(node, from: 0, span: 1, depth: 0, hue: nil)
        return out
    }

    var body: some View {
        let arcs = arcs
        GeometryReader { geo in
            ZStack {
                ForEach(arcs) { arc in
                    Ring(start: arc.start, end: arc.end, inner: 0.34 + Double(arc.depth) * 0.22, outer: 0.34 + Double(arc.depth + 1) * 0.22 - 0.01)
                        .fill(arc.color.opacity(hover?.path == arc.node.path ? 1 : 0.82))
                }
            }
            // Hover and taps test each frame, not each ring, so the arc
            // under the pointer comes from its angle and distance instead.
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let at): hover = Self.arc(at: at, in: geo.size, of: arcs)?.node
                case .ended: hover = nil
                }
            }
            .gesture(SpatialTapGesture().onEnded { tap in
                if let arc = Self.arc(at: tap.location, in: geo.size, of: arcs), !arc.node.children.isEmpty { open(arc.node) }
            })
        }
        .animation(.easeOut(duration: 0.25), value: node.path)
    }

    private static func arc(at point: CGPoint, in size: CGSize, of arcs: [Arc]) -> Arc? {
        let dx = point.x - size.width / 2, dy = point.y - size.height / 2
        let reach = (dx * dx + dy * dy).squareRoot() / (min(size.width, size.height) / 2)
        guard reach >= 0.34 else { return nil }
        let depth = Int((reach - 0.34) / 0.22)
        var turn = (atan2(dy, dx) + .pi / 2) / (2 * .pi)
        if turn < 0 { turn += 1 }
        return arcs.first { $0.depth == depth && turn >= $0.start && turn < $0.end }
    }
}

/// A slice of a ring, as fractions of a turn and of the view's half width.
private struct Ring: Shape {
    var start: Double
    var end: Double
    var inner: Double
    var outer: Double

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        let a0 = Angle.degrees(start * 360 - 90), a1 = Angle.degrees(max(end - 0.002, start) * 360 - 90)
        var p = Path()
        p.addArc(center: c, radius: r * outer, startAngle: a0, endAngle: a1, clockwise: false)
        p.addArc(center: c, radius: r * inner, startAngle: a1, endAngle: a0, clockwise: true)
        p.closeSubpath()
        return p
    }
}
