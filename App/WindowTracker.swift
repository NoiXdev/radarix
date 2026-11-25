import AppKit
import RadarixKit
import SwiftUI

/// The windows that count as Radarix windows for the Dock icon.
enum RadarixWindowKind {
    case main, description, repoInfo, overview, settings
}

/// Knows Radarix's own windows and keeps the Dock icon in step with them under "Hide from the
/// Dock when the window is closed".
///
/// A window counts only once `WindowMarker`, placed in its content, has reported it. That leaves
/// out every window Radarix does not make itself: the menu bar extra's panel, the status item,
/// popovers, menus, alerts, sheets and tooltips. A window counts while it is visible or minimized,
/// so switching to the accessory policy never takes a minimized window out of the Dock.
@MainActor
final class WindowTracker: NSObject {
    private struct Entry {
        weak var window: NSWindow?
        let kind: RadarixWindowKind
    }

    private var entries: [Entry] = []
    private let menuBarOnly: @MainActor () -> Bool

    init(menuBarOnly: @escaping @MainActor () -> Bool) {
        self.menuBarOnly = menuBarOnly
    }

    /// Starts following window notifications. Called once, at launch.
    func observe() {
        let center = NotificationCenter.default
        // Shown again: a reused window (Settings) is not reported by its marker a second time.
        for name in [
            NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didDeminiaturizeNotification,
        ] {
            center.addObserver(self, selector: #selector(windowShown(_:)), name: name, object: nil)
        }
        center.addObserver(self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: nil)
    }

    /// A marked window is about to appear: the Dock icon comes back before it shows.
    func register(_ window: NSWindow, kind: RadarixWindowKind) {
        entries.removeAll { $0.window == nil || $0.window === window }
        entries.append(Entry(window: window, kind: kind))
        showDockIcon()
    }

    /// An open window of `kind`, visible or minimized.
    func openWindow(of kind: RadarixWindowKind) -> NSWindow? {
        entries.first { $0.kind == kind && $0.window.map(Self.isOpen) == true }?.window
    }

    /// Applies the policy to the windows open now, leaving out `closing`. Never hides or closes
    /// a window: the accessory policy is chosen only when none is open.
    func update(closing: NSWindow? = nil) {
        let open = entries.compactMap(\.window).filter { $0 !== closing && Self.isOpen($0) }.count
        let accessory = InstancePolicy.activationIsAccessory(menuBarOnly: menuBarOnly(), openWindowCount: open)
        setPolicy(accessory ? .accessory : .regular)
    }

    private func showDockIcon() {
        setPolicy(.regular)
    }

    private func setPolicy(_ policy: NSApplication.ActivationPolicy) {
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    private func isTracked(_ window: NSWindow) -> Bool {
        entries.contains { $0.window === window }
    }

    private static func isOpen(_ window: NSWindow) -> Bool {
        window.isVisible || window.isMiniaturized
    }

    @objc private func windowShown(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, isTracked(window), Self.isOpen(window) else { return }
        showDockIcon()
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, isTracked(window) else { return }
        // After the close, so the window is gone from screen when the Dock icon goes.
        Task { @MainActor in self.update(closing: window) }
    }
}

/// Reports the window that shows this content to the tracker. A view inside the content, since
/// SwiftUI gives the scenes' windows no public handle.
struct WindowMarker: NSViewRepresentable {
    let kind: RadarixWindowKind
    let tracker: WindowTracker

    func makeNSView(context: Context) -> MarkerView {
        MarkerView(kind: kind, tracker: tracker)
    }

    func updateNSView(_ nsView: MarkerView, context: Context) {}

    final class MarkerView: NSView {
        private let kind: RadarixWindowKind
        private let tracker: WindowTracker

        init(kind: RadarixWindowKind, tracker: WindowTracker) {
            self.kind = kind
            self.tracker = tracker
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not used")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { tracker.register(window, kind: kind) }
        }
    }
}
