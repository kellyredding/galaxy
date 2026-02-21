import AppKit
import SwiftUI
import Combine

/// NSWindowController that hosts the SettingsView, replacing SwiftUI's Settings scene.
/// This allows the preferences window to be opened via menu action with ⌘,
class PreferencesWindowController: NSWindowController {
    private static var shared: PreferencesWindowController?
    private var themeObserver: AnyCancellable?

    /// Shows the preferences window, creating it if necessary
    static func showPreferences() {
        if shared == nil {
            shared = PreferencesWindowController()
        }

        shared?.applyAppearance(SettingsManager.shared.settings.themePreference)
        shared?.showWindow(nil)
        shared?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
        window.setFrameAutosaveName("PreferencesWindow")

        super.init(window: window)

        // Set window delegate
        window.delegate = self

        // Create the hosting view once — never recreated on theme changes
        let settingsView = SettingsView()
            .environmentObject(SettingsManager.shared)
        let hostingView = NSHostingView(rootView: settingsView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = hostingView

        // Size window to fit content and center on first show
        let fittingSize = hostingView.fittingSize
        window.setContentSize(fittingSize)
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
