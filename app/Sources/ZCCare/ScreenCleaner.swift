import AppKit
import SwiftUI

/// Screen Cleaning Mode: every screen goes black and the keyboard types
/// nothing, so both can be wiped. Done on any screen, holding Esc for two
/// seconds, or a minute's wait ends it.
@MainActor
final class ScreenCleaner {
    static let shared = ScreenCleaner()
    static let limit = 60
    private static let escapeKey: UInt16 = 53
    private static let holdToLeave: Duration = .seconds(2)

    private let countdown = CleaningCountdown()
    private var timer: Task<Void, Never>?
    private var escapeHold: Task<Void, Never>?
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
            window.contentView = NSHostingView(rootView: CleaningScreen(countdown: countdown) { [weak self] in self?.stop() })
            window.setFrame(screen.frame, display: true)
            window.makeKeyAndOrderFront(nil)
            windows.append(window)
        }
        options = NSApp.presentationOptions
        NSApp.activate()
        // No Dock, menu bar or app switching: Command-Tab must not leave the mode.
        NSApp.presentationOptions = [.hideDock, .hideMenuBar, .disableProcessSwitching, .disableHideApplication,
                                     .disableAppleMenu, .disableSessionTermination]
        keys = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            let isEscape = event.keyCode == Self.escapeKey
            let type = event.type
            let repeating = type == .keyDown && event.isARepeat
            MainActor.assumeIsolated { if isEscape { self?.escape(type, repeating: repeating) } }
            return nil
        }
        countdown.remaining = Self.limit
        timer = Task {
            while countdown.remaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                countdown.remaining -= 1
            }
            stop()
        }
    }

    /// Esc held down long enough leaves; letting go early cancels.
    private func escape(_ type: NSEvent.EventType, repeating: Bool) {
        switch type {
        case .keyDown where !repeating:
            escapeHold = Task {
                try? await Task.sleep(for: Self.holdToLeave)
                if !Task.isCancelled { stop() }
            }
        case .keyUp:
            escapeHold?.cancel()
            escapeHold = nil
        default: break
        }
    }

    func stop() {
        timer?.cancel()
        escapeHold?.cancel()
        timer = nil
        escapeHold = nil
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

@MainActor @Observable
final class CleaningCountdown {
    var remaining = ScreenCleaner.limit
}

private struct CleaningScreen: View {
    let countdown: CleaningCountdown
    let done: () -> Void

    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 14) {
                Image(systemName: "keyboard.badge.ellipsis").font(.system(size: 54)).foregroundStyle(.white.opacity(0.5))
                Text("Screen Cleaning Mode").font(.title.weight(.semibold))
                Text("The keyboard is locked: wipe the screen and the keys.\nClick Done, or hold Esc for 2 seconds, when you are finished.\nThis ends by itself in \(countdown.remaining) seconds.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.6))
                Button("Done", action: done).controlSize(.large).padding(.top, 10)
            }
            .foregroundStyle(.white)
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }
}
