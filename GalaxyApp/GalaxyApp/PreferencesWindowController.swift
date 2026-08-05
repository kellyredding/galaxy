import AppKit
import SwiftUI
import Combine

/// NSWindowController that hosts the SettingsView as an app-modal window.
/// Uses NSApp.runModal(for:) to capture all key events, preventing accidental
/// keyboard shortcuts (like ⌘W) from leaking through to the main window.
class PreferencesWindowController: NSWindowController {
    private static var shared: PreferencesWindowController?
    private var themeObserver: AnyCancellable?
    private var escapeMonitor: Any?

    /// Shows the preferences window as an app-modal dialog.
    /// Creates the controller on first call; reuses it on subsequent calls.
    static func showPreferences() {
        if shared == nil {
            shared = PreferencesWindowController()
        }

        guard let controller = shared else { return }

        controller.applyAppearance(SettingsManager.shared.settings.themePreference)
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Install a local event monitor for Escape — NSHostingView swallows
        // the key event before it reaches the responder chain, so we intercept
        // at the event level instead.
        controller.escapeMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { event in
            // Stand down while the cheat sheet claims the keyboard. Here
            // Escape dismisses Settings and unwinds `runModal`, tearing
            // down the window the sheet was drawn over. Passing the event
            // on gives a deliberate two-stage unwind — the first Escape
            // closes the sheet, the second the panel — which mirrors the
            // readers' own two-stage Escape rather than inventing a rule.
            if KeystrokeSheetModel.isClaimingKeyboard { return event }

            if event.keyCode == 53 {  // Escape
                controller.dismiss()
                return nil  // consume the event
            }
            return event
        }

        NSApp.runModal(for: controller.window!)

        // Runs after the modal event loop ends (dismiss was called)
        if let monitor = controller.escapeMonitor {
            NSEvent.removeMonitor(monitor)
            controller.escapeMonitor = nil
        }
    }

    private func nsAppearance(for theme: ThemePreference) -> NSAppearance? {
        switch theme {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    private init() {
        // Create the window
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 450),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        window.title = "Settings"

        super.init(window: window)

        // Set window delegate
        window.delegate = self

        // Host SettingsView in an NSHostingController so SwiftUI's
        // preferred content size drives the window's content size in
        // both directions — grow on tab switch to a taller pane AND
        // shrink back when switching to a shorter one.
        //
        // .preferredContentSize is the bidirectional channel: it
        // creates Auto Layout constraints from the SwiftUI content's
        // ideal size and feeds the controller's preferredContentSize,
        // which NSWindow then uses to update contentMinSize and
        // contentMaxSize. The default .standardBounds propagates
        // grows via the intrinsic-content-size channel but does not
        // actively shrink when SwiftUI's preferred size contracts —
        // the window would stay stuck at the tallest tab's height.
        let settingsView = SettingsView()
            .environmentObject(SettingsManager.shared)
        let hostingController = NSHostingController(rootView: settingsView)
        hostingController.sizingOptions = [.preferredContentSize]
        window.contentViewController = hostingController

        // Center on first show — content size lands automatically via
        // the hosting controller's preferred content size.
        window.center()

        // Apply initial appearance
        applyAppearance(SettingsManager.shared.settings.themePreference)

        // Observe theme changes to update window appearance
        themeObserver = SettingsManager.shared.$settings
            .map(\.themePreference)
            .removeDuplicates()
            .sink { [weak self] newTheme in
                self?.applyAppearance(newTheme)
            }
    }

    /// Update the window's NSAppearance without recreating the view hierarchy.
    /// Setting window.appearance to nil inherits the system appearance.
    private func applyAppearance(_ theme: ThemePreference) {
        window?.appearance = nsAppearance(for: theme)
    }

    private func dismiss() {
        NSApp.stopModal()
        // Use orderOut instead of close — close triggers a window animation
        // on a background display link thread that crashes if the controller
        // is deallocated before the animation completes.
        window?.orderOut(nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - NSWindowDelegate

extension PreferencesWindowController: NSWindowDelegate {
    /// Intercept the red X close button — redirect through dismiss() so
    /// we use orderOut (no animation) instead of the default close.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismiss()
        return false
    }

    /// The window is not user-resizable, so every resize is content-
    /// driven — switching to the wide statusline tab and back narrows
    /// or widens the SwiftUI content, which the hosting controller
    /// propagates to the window. Re-center on each resize so the
    /// window grows from its center rather than anchoring its left
    /// edge and expanding rightward.
    func windowDidResize(_ notification: Notification) {
        window?.center()
    }
}
