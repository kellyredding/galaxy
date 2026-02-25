import AppKit
import SwiftUI
import Combine

/// Presents the new-session dialog as a standalone modal window.
/// Follows the PreferencesWindowController pattern — a regular NSWindow hosting
/// a SwiftUI view. Using a standalone window (rather than beginSheet) ensures
/// the NSHostingView renders with the same default background as Settings.
class NewSessionSheetController: NSObject, NSWindowDelegate {
    private static var active: NewSessionSheetController?

    private let window: NSWindow
    private var themeObserver: AnyCancellable?

    /// Show the new-session dialog as an app-modal window.
    /// No-ops if already open (prevents double-open).
    static func present(on parentWindow: NSWindow) {
        guard active == nil else { return }

        let controller = NewSessionSheetController(parentWindow: parentWindow)
        active = controller
        controller.show()

        // Runs after the modal event loop ends (dismiss was called)
        controller.themeObserver = nil
        active = nil
    }

    private init(parentWindow: NSWindow) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "New session"
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
        let view = NewSessionView { [weak self] in
            self?.dismiss()
        }

        let hostingView = NSHostingView(rootView: view)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = hostingView

        // Size window to fit SwiftUI content
        let fittingSize = hostingView.fittingSize
        window.setContentSize(fittingSize)

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
