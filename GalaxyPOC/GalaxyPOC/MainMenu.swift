import AppKit
import SwiftUI  // For withAnimation
import Carbon.HIToolbox

/// Builds and manages the application's menu bar using AppKit NSMenu.
/// This provides full control over menu items, avoiding SwiftUI's auto-injected File > Close.
/// Uses NSMenuDelegate to rebuild menus just before display, ensuring current state.
class MainMenu: NSObject, NSMenuDelegate {
    private let sessionManager: SessionManager
    private let settingsManager: SettingsManager

    // Menus that use delegate for dynamic rebuilding
    private var sessionsMenu: NSMenu?
    private var viewMenu: NSMenu?
    private var fileMenu: NSMenu?

    init(sessionManager: SessionManager = .shared, settingsManager: SettingsManager = .shared) {
        self.sessionManager = sessionManager
        self.settingsManager = settingsManager
        super.init()
    }

    /// Creates and returns the main menu bar
    func createMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        // Application menu (uses app name)
        let appMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        buildAppMenu(appMenu)

        // File menu - use delegate to rebuild just before display
        let fileMenu = NSMenu(title: "File")
        fileMenu.delegate = self
        let fileMenuItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)
        self.fileMenu = fileMenu
        buildFileMenu(fileMenu)

        // Edit menu (standard)
        let editMenu = NSMenu(title: "Edit")
        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        buildEditMenu(editMenu)

        // Sessions menu - use delegate to rebuild just before display
        let sessionsMenu = NSMenu(title: "Sessions")
        sessionsMenu.delegate = self
        let sessionsMenuItem = NSMenuItem(title: "Sessions", action: nil, keyEquivalent: "")
        sessionsMenuItem.submenu = sessionsMenu
        mainMenu.addItem(sessionsMenuItem)
        self.sessionsMenu = sessionsMenu
        buildSessionsMenu(sessionsMenu)

        // View menu - use delegate to rebuild just before display
        let viewMenu = NSMenu(title: "View")
        viewMenu.delegate = self
        let viewMenuItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)
        self.viewMenu = viewMenu
        buildViewMenu(viewMenu)

        // Window menu (standard)
        let windowMenu = NSMenu(title: "Window")
        let windowMenuItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        buildWindowMenu(windowMenu)

        // Help menu (standard)
        let helpMenu = NSMenu(title: "Help")
        let helpMenuItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)
        buildHelpMenu(helpMenu)

        return mainMenu
    }

    // MARK: - App Menu

    private func buildAppMenu(_ menu: NSMenu) {
        let appName = ProcessInfo.processInfo.processName

        menu.addItem(withTitle: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menu.addItem(.separator())

        let prefsItem = NSMenuItem(title: "Settings...", action: #selector(MenuActions.showPreferences(_:)), keyEquivalent: ",")
        prefsItem.target = MenuActions.shared
        menu.addItem(prefsItem)

        menu.addItem(.separator())

        let servicesMenu = NSMenu(title: "Services")
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = servicesMenu
        menu.addItem(servicesItem)
        NSApp.servicesMenu = servicesMenu

        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")

        let hideOthersItem = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(hideOthersItem)

        menu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    // MARK: - File Menu

    private func buildFileMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let activeSession = sessionManager.activeSession
        let hasSessions = !sessionManager.sessions.isEmpty

        if let session = activeSession {
            if !session.hasExited {
                // Session is running: Stop session (⌘W)
                let stopItem = NSMenuItem(title: "Stop session", action: #selector(MenuActions.stopSession(_:)), keyEquivalent: "w")
                stopItem.target = MenuActions.shared
                menu.addItem(stopItem)
            } else {
                // Session is stopped: Close session (⌘W) and Resume session (⌘R)
                let closeItem = NSMenuItem(title: "Close session", action: #selector(MenuActions.closeSession(_:)), keyEquivalent: "w")
                closeItem.target = MenuActions.shared
                menu.addItem(closeItem)

                let resumeItem = NSMenuItem(title: "Resume session", action: #selector(MenuActions.resumeSession(_:)), keyEquivalent: "r")
                resumeItem.target = MenuActions.shared
                menu.addItem(resumeItem)
            }
        } else if hasSessions {
            // Has sessions but none active (shouldn't normally happen, but handle it)
            let item = NSMenuItem(title: "Stop session", action: nil, keyEquivalent: "w")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            // No sessions: Close window (⌘W)
            let closeWindowItem = NSMenuItem(title: "Close window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
            menu.addItem(closeWindowItem)
        }

        menu.addItem(.separator())

        // Close window (⌘⇧W) - always available
        let closeWindowShiftItem = NSMenuItem(title: "Close window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "W")
        closeWindowShiftItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(closeWindowShiftItem)
    }

    // MARK: - Edit Menu

    private func buildEditMenu(_ menu: NSMenu) {
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    }

    // MARK: - Sessions Menu

    private func buildSessionsMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        // Session switching: ⌘1-9
        for (index, session) in sessionManager.sessions.enumerated() where index < 9 {
            let item = NSMenuItem(
                title: session.userSessionId,
                action: #selector(MenuActions.switchToSession(_:)),
                keyEquivalent: "\(index + 1)"
            )
            item.target = MenuActions.shared
            item.tag = index
            item.state = session.id == sessionManager.activeSessionId ? .on : .off
            menu.addItem(item)
        }

        // Stop/Close/Resume session with ⌘W/⌘R is in File menu

        let activeSession = sessionManager.activeSession

        // Clear/Compact: only show when active session is running
        if let active = activeSession, active.isRunning && !active.hasExited {
            menu.addItem(.separator())

            let clearItem = NSMenuItem(title: "Clear session", action: #selector(MenuActions.clearSession(_:)), keyEquivalent: "")
            clearItem.target = MenuActions.shared
            clearItem.keyEquivalent = "\u{08}"  // Delete key
            clearItem.keyEquivalentModifierMask = [.command, .shift]
            menu.addItem(clearItem)

            let compactItem = NSMenuItem(title: "Compact session", action: #selector(MenuActions.compactSession(_:)), keyEquivalent: "")
            compactItem.target = MenuActions.shared
            compactItem.keyEquivalent = "\u{08}"  // Delete key
            compactItem.keyEquivalentModifierMask = [.command, .control]
            menu.addItem(compactItem)
        }
    }

    // MARK: - View Menu

    private func buildViewMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let panelOnLeft = settingsManager.settings.sidebarPosition == .left
        let isVisible = sessionManager.isSidebarVisible

        // Hide sessions: ⌘[ if panel on left, ⌘] if panel on right
        let hideItem = NSMenuItem(title: "Hide sessions", action: #selector(MenuActions.hideSessions(_:)), keyEquivalent: panelOnLeft ? "[" : "]")
        hideItem.target = MenuActions.shared
        hideItem.isEnabled = isVisible
        menu.addItem(hideItem)

        // Show sessions: ⌘] if panel on left, ⌘[ if panel on right
        let showItem = NSMenuItem(title: "Show sessions", action: #selector(MenuActions.showSessions(_:)), keyEquivalent: panelOnLeft ? "]" : "[")
        showItem.target = MenuActions.shared
        showItem.isEnabled = !isVisible
        menu.addItem(showItem)

        menu.addItem(.separator())

        // Session switching - vim style (⌘k/j) - no wrap, disable at boundaries
        let canGoPrev = sessionManager.canSwitchToPreviousSession
        let canGoNext = sessionManager.canSwitchToNextSession

        let prevItem = NSMenuItem(title: "Previous session", action: #selector(MenuActions.previousSession(_:)), keyEquivalent: "k")
        prevItem.target = MenuActions.shared
        prevItem.isEnabled = canGoPrev
        menu.addItem(prevItem)

        let prevArrowItem = NSMenuItem(title: "Previous session", action: #selector(MenuActions.previousSession(_:)), keyEquivalent: String(UnicodeScalar(NSUpArrowFunctionKey)!))
        prevArrowItem.target = MenuActions.shared
        prevArrowItem.keyEquivalentModifierMask = .command
        prevArrowItem.isEnabled = canGoPrev
        prevArrowItem.isAlternate = true
        menu.addItem(prevArrowItem)

        let nextItem = NSMenuItem(title: "Next session", action: #selector(MenuActions.nextSession(_:)), keyEquivalent: "j")
        nextItem.target = MenuActions.shared
        nextItem.isEnabled = canGoNext
        menu.addItem(nextItem)

        let nextArrowItem = NSMenuItem(title: "Next session", action: #selector(MenuActions.nextSession(_:)), keyEquivalent: String(UnicodeScalar(NSDownArrowFunctionKey)!))
        nextArrowItem.target = MenuActions.shared
        nextArrowItem.keyEquivalentModifierMask = .command
        nextArrowItem.isEnabled = canGoNext
        nextArrowItem.isAlternate = true
        menu.addItem(nextArrowItem)

        menu.addItem(.separator())

        // Terminal font size
        let activeSession = sessionManager.activeSession
        let hasActiveRunningSession = activeSession != nil && activeSession?.hasExited != true

        let defaultTerminalItem = NSMenuItem(title: "Default terminal font size", action: #selector(MenuActions.defaultTerminalFontSize(_:)), keyEquivalent: "0")
        defaultTerminalItem.target = MenuActions.shared
        defaultTerminalItem.isEnabled = hasActiveRunningSession
        menu.addItem(defaultTerminalItem)

        let biggerTerminalItem = NSMenuItem(title: "Bigger", action: #selector(MenuActions.biggerTerminalFontSize(_:)), keyEquivalent: "=")
        biggerTerminalItem.target = MenuActions.shared
        biggerTerminalItem.isEnabled = hasActiveRunningSession && (activeSession?.canIncreaseTerminalFontSize ?? false)
        menu.addItem(biggerTerminalItem)

        let smallerTerminalItem = NSMenuItem(title: "Smaller", action: #selector(MenuActions.smallerTerminalFontSize(_:)), keyEquivalent: "-")
        smallerTerminalItem.target = MenuActions.shared
        smallerTerminalItem.isEnabled = hasActiveRunningSession && (activeSession?.canDecreaseTerminalFontSize ?? false)
        menu.addItem(smallerTerminalItem)

        menu.addItem(.separator())

        // Chrome font size
        let defaultChromeItem = NSMenuItem(title: "Default chrome font size", action: #selector(MenuActions.defaultChromeFontSize(_:)), keyEquivalent: "0")
        defaultChromeItem.target = MenuActions.shared
        defaultChromeItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(defaultChromeItem)

        let biggerChromeItem = NSMenuItem(title: "Bigger", action: #selector(MenuActions.biggerChromeFontSize(_:)), keyEquivalent: "=")
        biggerChromeItem.target = MenuActions.shared
        biggerChromeItem.keyEquivalentModifierMask = [.command, .shift]
        biggerChromeItem.isEnabled = settingsManager.settings.chromeFontSize < AppSettings.chromeFontSizeRange.upperBound
        menu.addItem(biggerChromeItem)

        let smallerChromeItem = NSMenuItem(title: "Smaller", action: #selector(MenuActions.smallerChromeFontSize(_:)), keyEquivalent: "-")
        smallerChromeItem.target = MenuActions.shared
        smallerChromeItem.keyEquivalentModifierMask = [.command, .shift]
        smallerChromeItem.isEnabled = settingsManager.settings.chromeFontSize > AppSettings.chromeFontSizeRange.lowerBound
        menu.addItem(smallerChromeItem)

        menu.addItem(.separator())

        // Standard view items
        menu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]
    }

    // MARK: - Window Menu

    private func buildWindowMenu(_ menu: NSMenu) {
        menu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")

        NSApp.windowsMenu = menu
    }

    // MARK: - Help Menu

    private func buildHelpMenu(_ menu: NSMenu) {
        let appName = ProcessInfo.processInfo.processName
        let helpItem = NSMenuItem(title: "\(appName) Help", action: #selector(NSApplication.showHelp(_:)), keyEquivalent: "?")
        menu.addItem(helpItem)

        NSApp.helpMenu = menu
    }

    // MARK: - NSMenuDelegate

    /// Called just before the menu is displayed - rebuild to ensure current state
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === fileMenu {
            buildFileMenu(menu)
        } else if menu === sessionsMenu {
            buildSessionsMenu(menu)
        } else if menu === viewMenu {
            buildViewMenu(menu)
        }
    }
}

// MARK: - Menu Actions

/// Singleton class to handle menu actions. Uses @objc methods that can be targeted by menu items.
class MenuActions: NSObject {
    static let shared = MenuActions()

    private override init() {
        super.init()
    }

    // MARK: - File Menu Actions

    @objc func stopSession(_ sender: Any?) {
        guard let activeId = SessionManager.shared.activeSessionId else { return }
        SessionManager.shared.stopSession(sessionId: activeId)
    }

    @objc func closeSession(_ sender: Any?) {
        guard let activeId = SessionManager.shared.activeSessionId else { return }
        SessionManager.shared.closeSession(sessionId: activeId)
    }

    // MARK: - Sessions Menu Actions

    @objc func switchToSession(_ sender: NSMenuItem) {
        let index = sender.tag
        let sessions = SessionManager.shared.sessions
        guard index < sessions.count else { return }
        SessionManager.shared.switchTo(sessionId: sessions[index].id)
    }

    @objc func resumeSession(_ sender: Any?) {
        guard let activeId = SessionManager.shared.activeSessionId else { return }
        SessionManager.shared.resumeSession(sessionId: activeId)
    }

    @objc func clearSession(_ sender: Any?) {
        SessionManager.shared.activeSession?.sendCommand("/clear")
    }

    @objc func compactSession(_ sender: Any?) {
        SessionManager.shared.activeSession?.sendCommand("/compact")
    }

    // MARK: - View Menu Actions

    @objc func hideSessions(_ sender: Any?) {
        withAnimation(.easeInOut(duration: 0.2)) {
            SessionManager.shared.isSidebarVisible = false
        }
    }

    @objc func showSessions(_ sender: Any?) {
        withAnimation(.easeInOut(duration: 0.2)) {
            SessionManager.shared.isSidebarVisible = true
        }
    }

    @objc func previousSession(_ sender: Any?) {
        SessionManager.shared.switchToPreviousSession()
    }

    @objc func nextSession(_ sender: Any?) {
        SessionManager.shared.switchToNextSession()
    }

    @objc func defaultTerminalFontSize(_ sender: Any?) {
        SessionManager.shared.activeSession?.resetTerminalFontSize()
    }

    @objc func biggerTerminalFontSize(_ sender: Any?) {
        SessionManager.shared.activeSession?.increaseTerminalFontSize()
    }

    @objc func smallerTerminalFontSize(_ sender: Any?) {
        SessionManager.shared.activeSession?.decreaseTerminalFontSize()
    }

    @objc func defaultChromeFontSize(_ sender: Any?) {
        SettingsManager.shared.settings.chromeFontSize = 13.0
    }

    @objc func biggerChromeFontSize(_ sender: Any?) {
        let newSize = min(
            SettingsManager.shared.settings.chromeFontSize + AppSettings.chromeFontSizeStep,
            AppSettings.chromeFontSizeRange.upperBound
        )
        SettingsManager.shared.settings.chromeFontSize = newSize
    }

    @objc func smallerChromeFontSize(_ sender: Any?) {
        let newSize = max(
            SettingsManager.shared.settings.chromeFontSize - AppSettings.chromeFontSizeStep,
            AppSettings.chromeFontSizeRange.lowerBound
        )
        SettingsManager.shared.settings.chromeFontSize = newSize
    }

    // MARK: - App Menu Actions

    @objc func showPreferences(_ sender: Any?) {
        NotificationCenter.default.post(name: .showPreferences, object: nil)
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let showPreferences = Notification.Name("showPreferences")
}
