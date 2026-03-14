import AppKit
import SwiftUI

/// NSWindow subclass that disables key view loop recalculation.
/// The ZStack architecture keeps all tab/session views alive (3 containers × N sessions),
/// making recalculateKeyViewLoop traverse thousands of views — causing multi-second hangs
/// whenever a TextField gains or resigns first responder. Galaxy uses terminal-centric
/// focus management (makeFirstResponder), not Tab-key navigation, so the key view loop
/// is unnecessary.
class GalaxyWindow: NSWindow {
    override func recalculateKeyViewLoop() {
        // No-op: prevents AppKit from traversing the full SwiftUI view tree.
    }
}

/// NSWindowController that hosts the main ContentView via NSHostingView.
/// This provides full control over window lifecycle, avoiding SwiftUI's Window scene limitations.
class MainWindowController: NSWindowController {
    private let sessionManager: SessionManager
    private let settingsManager: SettingsManager

    init(sessionManager: SessionManager = .shared, settingsManager: SettingsManager = .shared) {
        self.sessionManager = sessionManager
        self.settingsManager = settingsManager

        // Create the window
        let window = GalaxyWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1680, height: 840),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Galaxy"
        window.minSize = NSSize(width: 800, height: 500)

        // Default position for first launch (no saved state)
        window.center()

        super.init(window: window)

        // Create SwiftUI content view with environment objects
        let contentView = ContentView()
            .environmentObject(sessionManager)
            .environmentObject(settingsManager)

        // Wrap in NSHostingView
        let hostingView = NSHostingView(rootView: contentView)
        window.contentView = hostingView

        // Apply initial theme appearance — window.appearance drives
        // SwiftUI's colorScheme environment without .preferredColorScheme()
        applyTheme(settingsManager.settings.themePreference)

        // Set up window delegate for close behavior
        window.delegate = self

        // Restore saved window frame + screen position
        restoreWindowState()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Apply theme by setting window.appearance — propagates to SwiftUI's
    /// colorScheme environment without recreating the view hierarchy.
    /// nil inherits the system appearance.
    func applyTheme(_ theme: ThemePreference) {
        switch theme {
        case .system:
            window?.appearance = nil
        case .light:
            window?.appearance = NSAppearance(named: .aqua)
        case .dark:
            window?.appearance = NSAppearance(named: .darkAqua)
        }
    }

    // MARK: - Window State Restoration

    /// Restore window frame and screen position from persisted
    /// state. Called once during init. On first launch (no saved
    /// state), the window stays centered at its default size.
    private func restoreWindowState() {
        guard let window = window,
              let saved = WindowStatePersistence.shared.load()
        else { return }

        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }

        // Restore the saved window frame first
        let savedFrame = NSRect(
            x: saved.windowFrame.x,
            y: saved.windowFrame.y,
            width: saved.windowFrame.width,
            height: saved.windowFrame.height
        )
        window.setFrame(savedFrame, display: false)

        // Try to find the saved screen by localizedName
        if let targetScreen = screens.first(where: {
            $0.localizedName == saved.screenIdentifier
        }) {
            // Screen found — move window there if needed
            if window.screen != targetScreen {
                moveWindow(window, toScreen: targetScreen)
            }
        } else {
            // Screen not found — proportionally scale to current screen
            let currentScreen = window.screen ?? NSScreen.screens[0]
            scaleWindowProportionally(
                window,
                fromScreenFrame: saved.screenFrame,
                toScreen: currentScreen
            )
        }

        // Final safety: ensure title bar is accessible
        let constrained = window.constrainFrameRect(
            window.frame,
            to: window.screen
        )
        if constrained != window.frame {
            window.setFrame(constrained, display: true)
        }
    }

    /// Move window to a target screen, preserving its relative
    /// position within the screen.
    private func moveWindow(
        _ window: NSWindow,
        toScreen target: NSScreen
    ) {
        guard let currentScreen = window.screen else { return }

        // Calculate relative position within current screen
        let currentFrame = currentScreen.visibleFrame
        let relX = (window.frame.origin.x - currentFrame.origin.x)
            / currentFrame.width
        let relY = (window.frame.origin.y - currentFrame.origin.y)
            / currentFrame.height

        // Apply same relative position on target screen
        let targetFrame = target.visibleFrame
        let newX = targetFrame.origin.x + (relX * targetFrame.width)
        let newY = targetFrame.origin.y + (relY * targetFrame.height)

        var newFrame = window.frame
        newFrame.origin = NSPoint(x: newX, y: newY)
        window.setFrame(newFrame, display: true)
    }

    /// Proportionally scale window position and size when the
    /// original screen is no longer available.
    private func scaleWindowProportionally(
        _ window: NSWindow,
        fromScreenFrame saved: PersistedScreenFrame,
        toScreen current: NSScreen
    ) {
        let currentFrame = current.visibleFrame

        // Calculate relative position and size on the old screen
        let relX = (window.frame.origin.x - saved.x) / saved.width
        let relY = (window.frame.origin.y - saved.y) / saved.height
        let relW = window.frame.width / saved.width
        let relH = window.frame.height / saved.height

        // Scale to current screen
        var newW = relW * currentFrame.width
        var newH = relH * currentFrame.height
        let newX = currentFrame.origin.x
            + (relX * currentFrame.width)
        let newY = currentFrame.origin.y
            + (relY * currentFrame.height)

        // Clamp to minimum window size
        newW = max(newW, window.minSize.width)
        newH = max(newH, window.minSize.height)

        let newFrame = NSRect(
            x: newX, y: newY, width: newW, height: newH
        )
        window.setFrame(newFrame, display: true)
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
        // Pause status line updates and busy observers during resize to reduce re-render lag
        StatusLineService.shared.pauseUpdates()
        SessionManager.shared.pauseAllBusyObservers()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        // Resume status line updates and busy observers after resize completes
        StatusLineService.shared.resumeUpdates()
        SessionManager.shared.resumeAllBusyObservers()

        // Persist new window size
        guard let window = window else { return }
        WindowStatePersistence.shared.saveWindowState(for: window)
    }

    // MARK: - Programmatic Resize Detection

    func windowDidResize(_ notification: Notification) {
        // windowDidResize fires for ALL resizes — both live (user drag) and
        // programmatic (Hammerspoon, AppleScript, accessibility APIs, etc.).
        // Skip during live resize: those are handled by windowDidEndLiveResize
        // to avoid saving on every intermediate frame.
        guard let window = window, !window.inLiveResize else { return }
        WindowStatePersistence.shared.saveWindowState(for: window)
    }

    // MARK: - Screen State Tracking

    func windowDidMove(_ notification: Notification) {
        guard let window = window else { return }
        WindowStatePersistence.shared.saveWindowState(for: window)
    }

    func windowDidChangeScreen(_ notification: Notification) {
        guard let window = window else { return }
        WindowStatePersistence.shared.saveWindowState(for: window)
    }
}
