import AppKit
import SwiftUI
import Combine

/// Presents the restore-session dialog as a standalone modal window.
/// Follows the NewSessionSheetController pattern — a regular NSWindow
/// hosting a SwiftUI view with NSApp.runModal for blocking behavior.
class RestoreSessionSheetController: NSObject, NSWindowDelegate {
    private static var active: RestoreSessionSheetController?

    private let window: NSWindow
    private var themeObserver: AnyCancellable?
    private var escapeMonitor: Any?

    /// Show the restore-session dialog as an app-modal window.
    /// No-ops if already open (prevents double-open).
    static func present(on parentWindow: NSWindow) {
        guard active == nil else { return }

        let controller = RestoreSessionSheetController(parentWindow: parentWindow)
        active = controller
        controller.show()

        // Runs after the modal event loop ends (dismiss was called)
        if let monitor = controller.escapeMonitor {
            NSEvent.removeMonitor(monitor)
            controller.escapeMonitor = nil
        }
        controller.themeObserver = nil
        active = nil
    }

    private init(parentWindow: NSWindow) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Restore session"
        window.minSize = NSSize(width: 500, height: 300)
        window.autorecalculatesKeyViewLoop = true
        self.window = window

        super.init()

        window.delegate = self

        // Apply current theme appearance
        applyAppearance(SettingsManager.shared.settings.themePreference)

        // Observe theme changes while window is open
        themeObserver = SettingsManager.shared.$settings
            .map(\.themePreference)
            .removeDuplicates()
            .sink { [weak self] newTheme in
                self?.applyAppearance(newTheme)
            }

        // Host the SwiftUI view
        let view = RestoreSessionView { [weak self] in
            self?.dismiss()
        }

        let hostingView = NSHostingView(rootView: view)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = hostingView

        // Size window to fit SwiftUI content
        let fittingSize = hostingView.fittingSize
        let width = max(fittingSize.width, 640)
        let height = max(fittingSize.height, 420)
        window.setContentSize(NSSize(width: width, height: height))

        // Center on the parent window
        let parentCenter = NSPoint(
            x: parentWindow.frame.midX,
            y: parentWindow.frame.midY
        )
        let origin = NSPoint(
            x: parentCenter.x - window.frame.width / 2,
            y: parentCenter.y - window.frame.height / 2 + 50
        )
        window.setFrameOrigin(origin)
    }

    private func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Install a local event monitor for Escape — NSHostingView
        // swallows the key event before it reaches the responder chain,
        // so we intercept at the event level instead.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { [weak self] event in
            if event.keyCode == 53 {  // Escape
                self?.dismiss()
                return nil  // consume the event
            }
            return event
        }

        NSApp.runModal(for: window)
    }

    private func dismiss() {
        NSApp.stopModal()
        // Use orderOut instead of close — close triggers a window animation
        // on a background display link thread that crashes if the controller
        // is deallocated before the animation completes.
        window.orderOut(nil)
    }

    // MARK: - NSWindowDelegate

    /// Intercept the red X close button — redirect through dismiss() so
    /// we use orderOut (no animation) instead of the default close.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismiss()
        return false
    }

    // MARK: - Helpers

    private func applyAppearance(_ theme: ThemePreference) {
        window.appearance = nsAppearance(for: theme)
    }

    private func nsAppearance(
        for theme: ThemePreference
    ) -> NSAppearance? {
        switch theme {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}
