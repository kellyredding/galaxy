import AppKit
import Combine

/// Main entry point for the application.
/// Uses AppKit for the shell (menus, window management) and SwiftUI for content views.
class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?
    private var mainMenu: MainMenu?
    private var cancellables = Set<AnyCancellable>()
    private var eventCoordinator: EventCoordinator?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Disable macOS press-and-hold accent popover app-wide so held keys
        // produce normal key repeats. Without this, holding j/k in less (or
        // any pager/vim-style UI inside the shell pane) registers once and
        // then stops, while less rings BEL on the swallowed repeats. Routing
        // through SwiftTerm's interpretKeyEvents path is what exposes us to
        // the system default — Ghostty registers this same override at
        // launch for the same reason, so the workaround stays valid after
        // the eventual emulator swap. register(defaults:) writes to the
        // lowest-priority domain (no on-disk persistence), and Will-finish
        // is early enough to run before any window or text input context
        // initializes.
        UserDefaults.standard.register(defaults: [
            "ApplePressAndHoldEnabled": false,
        ])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Enable click-through: clicking into the Galaxy window from another
        // app activates AND delivers the click in one action, instead of
        // requiring a second click. SwiftUI creates internal NSView subclasses
        // that return false from acceptsFirstMouse(for:) by default, and we
        // can't subclass them — so we swizzle the base NSView method.
        NSView.enableClickThrough()

        // Probe the file system to trigger the macOS TCC permission dialog
        // before any session tries to access the working directory. Without
        // this, the first session launch fails because claude can't access
        // files on disk — the TCC prompt appears too late and the process
        // has already exited. This call blocks until the user responds.
        requestFileAccessIfNeeded()

        // Set up the main menu
        mainMenu = MainMenu()
        NSApp.mainMenu = mainMenu?.createMainMenu()

        // Eager-init the Terminal-tab command hub so its
        // Cmd+W local monitor is installed at launch rather
        // than lazily on first SwiftUI body evaluation. The
        // monitor needs to be in place before the user can
        // possibly press Cmd+W in a focused shell pane.
        _ = TerminalTabCommands.shared

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

        // Observe new session notification
        NotificationCenter.default.addObserver(
            forName: .showNewSession,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.showNewSession()
        }

        // Observe new marker notification
        NotificationCenter.default.addObserver(
            forName: .showNewMarker,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.showNewMarker()
        }

        // Observe restore session notification
        NotificationCenter.default.addObserver(
            forName: .showRestoreSession,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.showRestoreSession()
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

        // Observe theme preference changes — apply via window.appearance
        // so SwiftUI's colorScheme updates without recreating the view tree
        SettingsManager.shared.$settings
            .map(\.themePreference)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] theme in
                self?.mainWindowController?.applyTheme(theme)
            }
            .store(in: &cancellables)

        // Start the event system (socket listener + enrichment pipeline)
        eventCoordinator = EventCoordinator(sessionManager: SessionManager.shared)
        eventCoordinator?.start()

        // Wire session close → event coordinator cache cleanup
        SessionManager.shared.onSessionClosed = { [weak self] sessionId in
            self?.eventCoordinator?.sessionClosed(sessionId)
        }

        // Initialize notification service
        // (sets UNUserNotificationCenter delegate)
        _ = NotificationService.shared

        // Observe show-main-window notification (from notification clicks)
        NotificationCenter.default.addObserver(
            forName: .showMainWindow,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.mainWindowController?.showWindow(nil)
        }

        // Request notification authorization if any notification feature
        // is enabled (dock badge or session notifications)
        let appSettings = SettingsManager.shared.settings
        if appSettings.showDockBadge
            || appSettings.notifySessionIdle
            || appSettings.notifySessionExitedUnexpectedly
            || appSettings.notifyHighContext
            || appSettings.notifyAutoClearOccurred
        {
            Task {
                await SettingsManager.shared
                    .requestNotificationAuthorization()
            }
        }

        // Badge starts at nil (no sessions have unread state on fresh launch)
        NSApp.dockTile.badgeLabel = nil

        NSLog("AppDelegate: Application launched")
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        let sm = SessionManager.shared

        sm.quitWarnings { warnings in
            guard !warnings.isEmpty else {
                sender.reply(
                    toApplicationShouldTerminate: true
                )
                return
            }

            let message = "Quit with active sessions?"
            let details = warnings.map {
                session, reason in
                let reasonText: String
                switch reason {
                case .unsavedScrollback:
                    reasonText =
                        "has unsaved scrollback notes"
                case .inTurn:
                    reasonText =
                        "Claude is responding"
                case .runningAgents(let count):
                    reasonText =
                        "\(count) agent(s) running"
                }
                return "• \(session.displayName): "
                    + reasonText
            }.joined(separator: "\n")

            guard let window =
                NSApp.keyWindow ?? NSApp.mainWindow
            else {
                sender.reply(
                    toApplicationShouldTerminate: true
                )
                return
            }

            SheetAlert.confirm(
                in: window,
                message: message,
                detail: details,
                confirm: "Quit",
                onConfirm: {
                    sender.reply(
                        toApplicationShouldTerminate:
                            true
                    )
                },
                onCancel: {
                    sender.reply(
                        toApplicationShouldTerminate:
                            false
                    )
                }
            )
        }

        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSLog("AppDelegate: Application will terminate")
        NSApp.dockTile.badgeLabel = nil
        SessionPersistence.shared.flushSync()
        WindowStatePersistence.shared.flushSync()
        eventCoordinator?.stop()
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

    // MARK: - New Session

    private func showNewSession() {
        guard let window = mainWindowController?.window else { return }
        NewSessionSheetController.present(on: window)
    }

    // MARK: - New Marker

    private func showNewMarker() {
        guard let window = mainWindowController?.window else { return }
        NewMarkerSheetController.present(on: window)
    }

    // MARK: - Restore Session

    private func showRestoreSession() {
        guard let window = mainWindowController?.window else { return }
        RestoreSessionSheetController.present(on: window)
    }
}

// MARK: - Click-Through Swizzle

extension NSView {
    /// Swizzle acceptsFirstMouse(for:) on NSView to return true globally.
    /// This enables click-through for all views, including SwiftUI's internal
    /// view classes that we can't subclass. Called once at app launch.
    static func enableClickThrough() {
        let original = class_getInstanceMethod(
            NSView.self, #selector(acceptsFirstMouse(for:))
        )!
        let replacement = class_getInstanceMethod(
            NSView.self, #selector(galaxy_acceptsFirstMouse(for:))
        )!
        method_exchangeImplementations(original, replacement)
    }

    @objc private func galaxy_acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }
}
