import AppKit
import SwiftUI

/// NSWindowController that hosts the main ContentView via NSHostingView.
/// This provides full control over window lifecycle, avoiding SwiftUI's Window scene limitations.
class MainWindowController: NSWindowController {
    private let sessionManager: SessionManager
    private let settingsManager: SettingsManager

    init(sessionManager: SessionManager = .shared, settingsManager: SettingsManager = .shared) {
        self.sessionManager = sessionManager
        self.settingsManager = settingsManager

        // Create the window
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Galaxy"
        window.minSize = NSSize(width: 800, height: 500)
        window.setFrameAutosaveName("MainWindow")

        super.init(window: window)

        // Create SwiftUI content view with environment objects
        let contentView = ContentView()
            .environmentObject(sessionManager)
            .environmentObject(settingsManager)
            .environment(\.chromeFontSize, settingsManager.settings.chromeFontSize)
            .preferredColorScheme(preferredScheme)

        // Wrap in NSHostingView
        let hostingView = NSHostingView(rootView: contentView)
        window.contentView = hostingView

        // Center the window on first launch
        window.center()

        // Set up window delegate for close behavior
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var preferredScheme: ColorScheme? {
        switch settingsManager.settings.themePreference {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    /// Updates the content view's color scheme when settings change
    func updateColorScheme() {
        guard let window = window else { return }

        let contentView = ContentView()
            .environmentObject(sessionManager)
            .environmentObject(settingsManager)
            .environment(\.chromeFontSize, settingsManager.settings.chromeFontSize)
            .preferredColorScheme(preferredScheme)

        let hostingView = NSHostingView(rootView: contentView)
        window.contentView = hostingView
    }
}

// MARK: - NSWindowDelegate

extension MainWindowController: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Allow window to close - app continues running
        // User can quit with ⌘Q
        return true
    }

    func windowWillClose(_ notification: Notification) {
        // Window is closing - we could persist state here if needed
        NSLog("MainWindowController: Window will close")
    }

    // MARK: - Live Resize Performance Optimization

    func windowWillStartLiveResize(_ notification: Notification) {
        // Pause status line updates during resize to reduce re-render lag
        StatusLineService.shared.pauseUpdates()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        // Resume status line updates after resize completes
        StatusLineService.shared.resumeUpdates()
    }
}
