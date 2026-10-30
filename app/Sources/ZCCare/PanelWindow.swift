import AppKit
import SwiftUI

/// The panel in a floating window, for a bar that hides the macOS menu bar:
/// SketchyBar's item opens zccare://panel, and the panel drops down under the
/// click, like the menu bar one.
@MainActor
final class PanelWindow: NSObject, NSWindowDelegate {
    private let store: Store
    private var panel: NSPanel?
    private var host: NSHostingController<AnyView>?
    /// Where the panel's top edge stays while its content grows and shrinks.
    private var top: CGFloat = 0
    /// When a click elsewhere last closed the panel: a click on the bar item
    /// closes it that way first, and must not open it again.
    private var closedAt = Date.distantPast
    private var waitingForIdle = false

    init(store: Store) {
        self.store = store
    }

    func toggle() {
        if let panel, panel.isVisible {
            panel.orderOut(nil)
        } else if Date.now.timeIntervalSince(closedAt) > 0.4 {
            show()
        }
    }

    /// Opens the panel, or keeps it open: a notification or the hotkey.
    func show() {
        let panel = self.panel ?? make()
        self.panel = panel
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.frame else { return }
        let size = host?.sizeThatFits(in: frame.size) ?? NSSize(width: 428, height: 560)
        // Under the bar: SketchyBar is 36 points high, 2 down from the top.
        let x = min(max(mouse.x - size.width / 2, frame.minX + 8), frame.maxX - size.width - 8)
        top = frame.maxY - 46
        panel.setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)
        panel.makeKeyAndOrderFront(nil)
        store.refreshIfStale()
    }

    private func make() -> NSPanel {
        let panel = KeyPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
                             backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        // The panel draws its own background: no blur behind it to keep live.
        let root = PanelView(store: store)
            .environment(\.panelHost, .window)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.12)))
        // The window follows the view's size as tabs and sections change.
        let host = NSHostingController(rootView: AnyView(root))
        host.sizingOptions = [.preferredContentSize]
        panel.contentViewController = host
        self.host = host
        return panel
    }

    func windowDidResize(_ notification: Notification) {
        guard let panel, panel.frame.maxY != top else { return }
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: top - panel.frame.height))
    }

    /// The Mac tab samples only while someone can see it.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let panel else { return }
        if !panel.occlusionState.contains(.visible) {
            store.monitor.stop(host: .window)
        } else if store.tab == .mac {
            store.monitor.start(host: .window)
        }
    }

    /// Clicking elsewhere closes the panel, but not an alert the panel asked.
    /// While a job runs the panel stays open to show it, and closes once the
    /// job ends if the focus is still elsewhere.
    func windowDidResignKey(_ notification: Notification) {
        guard NSApp.modalWindow == nil else { return }
        guard store.busy == nil else { return closeWhenIdle() }
        close()
    }

    private func close() {
        panel?.orderOut(nil)
        closedAt = .now
    }

    private func closeWhenIdle() {
        guard !waitingForIdle else { return }
        waitingForIdle = true
        let store = store
        withObservationTracking { _ = store.busy } onChange: { [weak self] in
            Task { @MainActor in self?.busyChanged() }
        }
    }

    private func busyChanged() {
        waitingForIdle = false
        if store.busy != nil { return closeWhenIdle() }
        if let panel, panel.isVisible, !panel.isKeyWindow { close() }
    }
}

/// A borderless panel takes key only when it says it can, which its buttons
/// and the config chooser need.
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    /// Escape closes the panel.
    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}
