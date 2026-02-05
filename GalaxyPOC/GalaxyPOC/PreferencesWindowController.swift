import AppKit
import SwiftUI

/// NSWindowController that hosts the SettingsView, replacing SwiftUI's Settings scene.
/// This allows the preferences window to be opened via menu action with ⌘,
class PreferencesWindowController: NSWindowController {
    private static var shared: PreferencesWindowController?

    /// Shows the preferences window, creating it if necessary
    static func showPreferences() {
        if shared == nil {
            shared = PreferencesWindowController()
        }

        shared?.showWindow(nil)
        shared?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init() {
        // Create the window
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        window.title = "Settings"
        window.setFrameAutosaveName("PreferencesWindow")

        super.init(window: window)

        // Create SwiftUI settings view
        let settingsView = SettingsView()
            .environmentObject(SettingsManager.shared)

        // Wrap in NSHostingView
        let hostingView = NSHostingView(rootView: settingsView)

        // Allow the hosting view to determine size
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = hostingView

        // Size window to fit content
        let fittingSize = hostingView.fittingSize
        window.setContentSize(fittingSize)

        // Center the window
        window.center()

        // Set window delegate
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - NSWindowDelegate

extension PreferencesWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // Don't deallocate - keep the shared instance for quick reopening
        // Settings are auto-saved by SettingsManager
    }
}
