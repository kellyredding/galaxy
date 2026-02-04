import SwiftUI

@main
struct GalaxyPOCApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var sessionManager = SessionManager.shared
    @StateObject private var settingsManager = SettingsManager.shared
    @Environment(\.colorScheme) var systemColorScheme

    var body: some Scene {
        // Use Window (not WindowGroup) for single-window app
        Window("Galaxy", id: "main") {
            ContentView()
                .environmentObject(sessionManager)
                .environmentObject(settingsManager)
                .preferredColorScheme(preferredScheme)
        }
        .windowStyle(.automatic)
        // Handle URL scheme events in this window
        .handlesExternalEvents(matching: ["galaxy"])
        .commands {
            // Remove the default "New" menu item - sessions are created via CLI
            CommandGroup(replacing: .newItem) { }

            // Remove "New Window" from File menu
            CommandGroup(replacing: .singleWindowList) { }

            CommandMenu("Sessions") {
                ForEach(Array(sessionManager.sessions.enumerated()), id: \.element.id) { index, session in
                    if index < 9 {
                        Button(session.name) {
                            sessionManager.switchTo(sessionId: session.id)
                        }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    }
                }
            }
        }

        // Settings window (⌘,)
        Settings {
            SettingsView()
                .environmentObject(settingsManager)
        }
    }

    private var preferredScheme: ColorScheme? {
        switch settingsManager.settings.themePreference {
        case .system:
            return nil  // Use system default
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}

// App Delegate to handle URL scheme and window focus
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
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
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        SessionManager.shared.isWindowFocused = true
        // Note: SessionRow handles clearing hasUnreadBell with fade animation
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        SessionManager.shared.isWindowFocused = false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            handleGalaxyURL(url)
        }

        // Bring app to front when receiving URL
        NSApp.activate(ignoringOtherApps: true)
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
}
