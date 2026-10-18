import AppKit
import SwiftUI

/// Screen Cleaning Mode: every screen goes black and the keyboard types
/// nothing, so both can be wiped. Only the mouse ends it.
@MainActor
final class ScreenCleaner {
    static let shared = ScreenCleaner()

    private var windows: [NSWindow] = []
    private var keys: Any?
    private var options: NSApplication.PresentationOptions = []

    func start() {
        guard windows.isEmpty else { return }
        for screen in NSScreen.screens {
            let window = CleaningWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = .screenSaver
            window.backgroundColor = .black
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.contentView = NSHostingView(rootView: CleaningScreen(main: screen == NSScreen.main) { [weak self] in self?.stop() })
            window.setFrame(screen.frame, display: true)
            window.makeKeyAndOrderFront(nil)
            windows.append(window)
        }
        options = NSApp.presentationOptions
        NSApp.activate()
        // No Dock, menu bar or app switching: Command-Tab must not leave the mode.
        NSApp.presentationOptions = [.hideDock, .hideMenuBar, .disableProcessSwitching, .disableHideApplication,
                                     .disableAppleMenu, .disableSessionTermination]
        keys = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { _ in nil }
    }

    func stop() {
        if let keys { NSEvent.removeMonitor(keys) }
        keys = nil
        NSApp.presentationOptions = options
        windows.forEach { $0.close() }
        windows = []
    }
}

/// A borderless window can take keys only when it says so.
private final class CleaningWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private struct CleaningScreen: View {
    let main: Bool
    let done: () -> Void

    var body: some View {
        ZStack {
            Color.black
            if main {
                VStack(spacing: 14) {
                    Image(systemName: "keyboard.badge.ellipsis").font(.system(size: 54)).foregroundStyle(.white.opacity(0.5))
                    Text("Screen Cleaning Mode").font(.title.weight(.semibold))
                    Text("The keyboard is locked: wipe the screen and the keys.\nClick Done when you are finished.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.6))
                    Button("Done", action: done).controlSize(.large).padding(.top, 10)
                }
                .foregroundStyle(.white)
            }
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }
}
