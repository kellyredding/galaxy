import AppKit
import Combine

/// Main entry point for the application.
/// Uses AppKit for the shell (menus, window management) and SwiftUI for content views.
class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?
    private var mainMenu: MainMenu?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Probe the file system to trigger the macOS TCC permission dialog
        // before any session tries to access the working directory. Without
        // this, the first session launch fails because claude can't access
        // files on disk — the TCC prompt appears too late and the process
        // has already exited. This call blocks until the user responds.
        requestFileAccessIfNeeded()

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
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let pathItem = components.queryItems?.first(where: { $0.name == "path" }),
                  let path = pathItem.value else {
                NSLog("AppDelegate: new-session URL missing path parameter")
                return
            }

            // Parse optional persona parameters
            let persona = components.queryItems?.first(where: { $0.name == "persona" })?.value
            let vibe = components.queryItems?.first(where: { $0.name == "vibe" })?.value == "true"
            let resume = components.queryItems?.first(where: { $0.name == "resume" })?.value

            if let persona = persona {
                NSLog("AppDelegate: Creating persona session '%@' in %@ (vibe: %d, resume: %@)",
                      persona, path, vibe ? 1 : 0, resume ?? "nil")
            } else {
                NSLog("AppDelegate: Creating session in directory: %@ (resume: %@)",
                      path, resume ?? "nil")
            }

            SessionManager.shared.createSession(
                workingDirectory: path,
                personaName: persona,
                isVibe: vibe,
                resumeSessionId: resume
            )
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

    // MARK: - File Access

    /// Trigger macOS TCC permission dialogs on first launch before any
    /// session starts.
    ///
    /// macOS requires explicit user consent before an app (or its child
    /// processes) can access certain file system resources. The TCC prompt
    /// is triggered by the first actual access, but if that access comes
    /// from a spawned child process (like claude), the process may exit
    /// before the user can respond to the dialog.
    ///
    /// This method probes file system paths at launch to surface any
    /// permission dialogs early. Specifically:
    /// - Network volume mountpoints in the home directory (e.g., OrbStack
    ///   NFS mounts) trigger the "access files on a network volume" dialog.
    /// - The home directory itself is probed for general file access.
    private func requestFileAccessIfNeeded() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        // Probe the home directory for general file access
        _ = try? fm.contentsOfDirectory(atPath: home.path)

        // Find and probe network volume mountpoints in the home directory.
        // This triggers the kTCCServiceSystemPolicyNetworkVolumes dialog
        // (e.g., "Galaxy.app would like to access files on a network
        // volume") before any child process hits the gate.
        let keys: Set<URLResourceKey> = [.isVolumeKey, .volumeIsLocalKey]
        if let entries = try? fm.contentsOfDirectory(
            at: home,
            includingPropertiesForKeys: Array(keys)
        ) {
            for entry in entries {
                guard let values = try? entry.resourceValues(forKeys: keys),
                      values.isVolume == true,
                      values.volumeIsLocal == false else { continue }

                _ = try? fm.contentsOfDirectory(atPath: entry.path)
            }
        }
    }

    // MARK: - Preferences

    private func showPreferences() {
        PreferencesWindowController.showPreferences()
    }
}
