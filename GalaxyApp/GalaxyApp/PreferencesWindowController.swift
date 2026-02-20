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

        shared?.updateContent(theme: SettingsManager.shared.settings.themePreference)
        shared?.showWindow(nil)
        shared?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func preferredScheme(for theme: ThemePreference) -> ColorScheme? {
        switch theme {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
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

        // Set window delegate
        window.delegate = self

        // Initial content
        updateContent(theme: SettingsManager.shared.settings.themePreference)

        // Observe theme changes to update appearance
        // Note: @Published fires with the NEW value before the property is set,
        // so we must use the value passed to sink, not re-read from the instance
        themeObserver = SettingsManager.shared.$settings
            .map(\.themePreference)
            .removeDuplicates()
            .sink { [weak self] newTheme in
                self?.updateContent(theme: newTheme)
            }
    }

    private func updateContent(theme: ThemePreference) {
        guard let window = window else { return }

        // Create SwiftUI settings view with theme applied
        let settingsView = SettingsView()
            .environmentObject(SettingsManager.shared)
            .preferredColorScheme(preferredScheme(for: theme))

        // Wrap in NSHostingView
        let hostingView = NSHostingView(rootView: settingsView)

        // Allow the hosting view to determine size
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = hostingView

        // Size window to fit content
        let fittingSize = hostingView.fittingSize
        window.setContentSize(fittingSize)

        // Center only on first show
        if !window.isVisible {
            window.center()
        }
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
