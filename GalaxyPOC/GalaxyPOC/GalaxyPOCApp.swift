import AppKit
import Combine

/// Main entry point for the application.
/// Uses AppKit for the shell (menus, window management) and SwiftUI for content views.
class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?
    private var mainMenu: MainMenu?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set up the main menu
        mainMenu = MainMenu()
        NSApp.mainMenu = mainMenu?.createMainMenu()

        // Create and show the main window
        mainWindowController = MainWindowController()
        mainWindowController?.showWindow(nil)
        mainWindowController?.window?.makeKeyAndOrderFront(nil)

        // Observe preferences notification
        NotificationCenter.default.addObserver(
            forName: .showPreferences,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.showPreferences()
        }

        // Observe window focus changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: nil
        )

        // Observe settings changes that affect color scheme
        SettingsManager.shared.$settings
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.mainWindowController?.updateColorScheme()
            }
            .store(in: &cancellables)

        NSLog("AppDelegate: Application launched")
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSLog("AppDelegate: Application will terminate")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep app running even when window is closed
        // User must explicitly quit with ⌘Q
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Show the main window when clicking dock icon
        if !flag {
            mainWindowController?.showWindow(nil)
        }
        return true
    }

    // MARK: - URL Handling

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            handleGalaxyURL(url)
        }

        // Bring app to front when receiving URL
        NSApp.activate(ignoringOtherApps: true)

        // Show window if hidden
        mainWindowController?.showWindow(nil)
    }

    private func handleGalaxyURL(_ url: URL) {
        guard url.scheme == "galaxy" else { return }

        NSLog("AppDelegate: Received URL: %@", url.absoluteString)

        switch url.host {
        case "new-session":
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let pathItem = components.queryItems?.first(where: { $0.name == "path" }),
               let path = pathItem.value {
                NSLog("AppDelegate: Creating session in directory: %@", path)
                SessionManager.shared.createSession(workingDirectory: path)
            } else {
                NSLog("AppDelegate: new-session URL missing path parameter")
            }
        default:
            NSLog("AppDelegate: Unknown galaxy URL action: %@", url.host ?? "nil")
        }
    }

    // MARK: - Window Focus

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        SessionManager.shared.isWindowFocused = true
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        SessionManager.shared.isWindowFocused = false
    }

    // MARK: - Preferences

    private func showPreferences() {
        PreferencesWindowController.showPreferences()
    }
}
