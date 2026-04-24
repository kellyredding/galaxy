import AppKit
import Combine
import SwiftUI  // For withAnimation
import Carbon.HIToolbox

/// Builds and manages the application's menu bar using AppKit NSMenu.
/// This provides full control over menu items, avoiding SwiftUI's auto-injected File > Close.
/// Uses NSMenuDelegate to rebuild menus just before display, ensuring current state.
/// Also subscribes to session state changes via Combine so that keyboard shortcuts
/// (e.g. ⌘R for Resume) work immediately — `menuNeedsUpdate` only fires reliably
/// when the menu is opened visually, not when macOS matches key equivalents.
class MainMenu: NSObject, NSMenuDelegate {
    private let sessionManager: SessionManager
    private let settingsManager: SettingsManager
    private var cancellables = Set<AnyCancellable>()

    // Menus that use delegate for dynamic rebuilding
    private var sessionsMenu: NSMenu?
    private var viewMenu: NSMenu?
    private var fileMenu: NSMenu?

    init(sessionManager: SessionManager = .shared, settingsManager: SettingsManager = .shared) {
        self.sessionManager = sessionManager
        self.settingsManager = settingsManager
        super.init()
        observeSessionState()
    }

    /// Subscribe to session state changes that affect File menu items.
    /// This ensures key equivalents (⌘W, ⌘R) reflect current state even
    /// when the menu hasn't been opened visually.
    private func observeSessionState() {
        // Active session changed or resume-ability changed — rebuild File menu
        sessionManager.$activeSessionId
            .merge(with: sessionManager.$activeSessionCanResume.map { _ in nil as UUID? })
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, let menu = self.fileMenu else { return }
                self.buildFileMenu(menu)
            }
            .store(in: &cancellables)

        // Artifact reader or tab changed — rebuild File menu
        // so ⌘R switches between Refresh artifact and Resume session
        sessionManager.$isArtifactReaderOpen
            .merge(with: sessionManager.$activeTab.map { _ in false })
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, let menu = self.fileMenu else { return }
                self.buildFileMenu(menu)
            }
            .store(in: &cancellables)
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
        menu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "")

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

        // New Session (⌘N) - always available at top
        let newItem = NSMenuItem(
            title: "New Session...",
            action: #selector(MenuActions.newSession(_:)),
            keyEquivalent: "n"
        )
        newItem.target = MenuActions.shared
        menu.addItem(newItem)

        // Restore Session (⌘O) - always available
        let restoreItem = NSMenuItem(
            title: "Restore Session...",
            action: #selector(MenuActions.restoreSession(_:)),
            keyEquivalent: "o"
        )
        restoreItem.target = MenuActions.shared
        menu.addItem(restoreItem)

        menu.addItem(.separator())

        let activeSession = sessionManager.activeSession
        let hasSessions = !sessionManager.sessions.isEmpty

        // Refresh artifact (⌘R) — takes precedence over
        // Resume when artifact reader is open on Artifacts tab
        let artifactReaderActive =
            sessionManager.activeTab == .artifacts
            && sessionManager.isArtifactReaderOpen
        if artifactReaderActive {
            let refreshItem = NSMenuItem(
                title: "Refresh artifact",
                action: #selector(
                    MenuActions.refreshArtifact(_:)
                ),
                keyEquivalent: "r"
            )
            refreshItem.target = MenuActions.shared
            menu.addItem(refreshItem)
        }

        if let session = activeSession {
            if !session.hasExited {
                // Session is running: Stop session (⌘W)
                let stopItem = NSMenuItem(
                    title: "Stop session",
                    action: #selector(MenuActions.stopSession(_:)),
                    keyEquivalent: "w"
                )
                stopItem.target = MenuActions.shared
                menu.addItem(stopItem)
            } else {
                // Session is stopped: Dismiss with confirmation (⌘W)
                let dismissItem = NSMenuItem(
                    title: "Dismiss session",
                    action: #selector(MenuActions.dismissSession(_:)),
                    keyEquivalent: "w"
                )
                dismissItem.target = MenuActions.shared
                menu.addItem(dismissItem)

                if !artifactReaderActive {
                    let resumeItem = NSMenuItem(
                        title: "Resume session",
                        action: #selector(
                            MenuActions.resumeSession(_:)
                        ),
                        keyEquivalent: "r"
                    )
                    resumeItem.target = MenuActions.shared
                    menu.addItem(resumeItem)
                }
            }
        } else if hasSessions {
            // Has sessions but none active
            let item = NSMenuItem(title: "Stop session", action: nil, keyEquivalent: "w")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            // No sessions: Close window (⌘W)
            let closeWindowItem = NSMenuItem(
                title: "Close window",
                action: #selector(NSWindow.performClose(_:)),
                keyEquivalent: "w"
            )
            menu.addItem(closeWindowItem)
        }

        menu.addItem(.separator())

        // Close window (⌘⇧W) — always available
        let closeWindowShiftItem = NSMenuItem(
            title: "Close window",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "W"
        )
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
                title: session.displayName,
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

        // Scrollback: available when active session exists, disabled when not on Terminal tab
        if activeSession != nil {
            menu.addItem(.separator())

            let onTerminalTab = sessionManager.activeTab == .terminal
            let scrollbackItem = NSMenuItem(
                title: "Scrollback",
                action: onTerminalTab ? #selector(MenuActions.enterScrollback(_:)) : nil,
                keyEquivalent: "s"
            )
            scrollbackItem.target = MenuActions.shared
            menu.addItem(scrollbackItem)
        }

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
        let isVisible = settingsManager.settings.isSidebarVisible

        // Back / Forward in session navigation history
        let backItem = NSMenuItem(
            title: "Back",
            action: #selector(MenuActions.historyBack(_:)),
            keyEquivalent: "["
        )
        backItem.target = MenuActions.shared
        backItem.isEnabled = sessionManager.canNavigateBack
        menu.addItem(backItem)

        let forwardItem = NSMenuItem(
            title: "Forward",
            action: #selector(MenuActions.historyForward(_:)),
            keyEquivalent: "]"
        )
        forwardItem.target = MenuActions.shared
        forwardItem.isEnabled = sessionManager.canNavigateForward
        menu.addItem(forwardItem)

        menu.addItem(.separator())

        // Hide sessions: ⌘⇧[ if panel on left, ⌘⇧] if panel on right
        let hideItem = NSMenuItem(
            title: "Hide sessions",
            action: #selector(MenuActions.hideSessions(_:)),
            keyEquivalent: panelOnLeft ? "[" : "]"
        )
        hideItem.target = MenuActions.shared
        hideItem.keyEquivalentModifierMask = [.command, .shift]
        hideItem.isEnabled = isVisible
        menu.addItem(hideItem)

        // Show sessions: ⌘⇧] if panel on left, ⌘⇧[ if panel on right
        let showItem = NSMenuItem(
            title: "Show sessions",
            action: #selector(MenuActions.showSessions(_:)),
            keyEquivalent: panelOnLeft ? "]" : "["
        )
        showItem.target = MenuActions.shared
        showItem.keyEquivalentModifierMask = [.command, .shift]
        showItem.isEnabled = !isVisible
        menu.addItem(showItem)

        menu.addItem(.separator())

        // Session switching - vim style (⌘k/j)
        let canGoPrev = sessionManager.canSwitchToPreviousSession
        let canGoNext = sessionManager.canSwitchToNextSession
        let prevTitle = "Previous session"
        let nextTitle = "Next session"

        let prevItem = NSMenuItem(title: prevTitle, action: #selector(MenuActions.previousSession(_:)), keyEquivalent: "k")
        prevItem.target = MenuActions.shared
        prevItem.isEnabled = canGoPrev
        menu.addItem(prevItem)

        let prevArrowItem = NSMenuItem(title: prevTitle, action: #selector(MenuActions.previousSession(_:)), keyEquivalent: String(UnicodeScalar(NSUpArrowFunctionKey)!))
        prevArrowItem.target = MenuActions.shared
        prevArrowItem.keyEquivalentModifierMask = .command
        prevArrowItem.isEnabled = canGoPrev
        prevArrowItem.isAlternate = true
        menu.addItem(prevArrowItem)

        let nextItem = NSMenuItem(title: nextTitle, action: #selector(MenuActions.nextSession(_:)), keyEquivalent: "j")
        nextItem.target = MenuActions.shared
        nextItem.isEnabled = canGoNext
        menu.addItem(nextItem)

        let nextArrowItem = NSMenuItem(title: nextTitle, action: #selector(MenuActions.nextSession(_:)), keyEquivalent: String(UnicodeScalar(NSDownArrowFunctionKey)!))
        nextArrowItem.target = MenuActions.shared
        nextArrowItem.keyEquivalentModifierMask = .command
        nextArrowItem.isEnabled = canGoNext
        nextArrowItem.isAlternate = true
        menu.addItem(nextArrowItem)

        menu.addItem(.separator())

        // View switching: ⌘H / ⌘L and ⌘← / ⌘→
        let prevViewItem = NSMenuItem(
            title: "Previous view",
            action: #selector(MenuActions.previousView(_:)),
            keyEquivalent: "h"
        )
        prevViewItem.target = MenuActions.shared
        menu.addItem(prevViewItem)

        let prevViewArrowItem = NSMenuItem(
            title: "Previous view",
            action: #selector(MenuActions.previousView(_:)),
            keyEquivalent: String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        )
        prevViewArrowItem.target = MenuActions.shared
        prevViewArrowItem.keyEquivalentModifierMask = .command
        prevViewArrowItem.isAlternate = true
        menu.addItem(prevViewArrowItem)

        let nextViewItem = NSMenuItem(
            title: "Next view",
            action: #selector(MenuActions.nextView(_:)),
            keyEquivalent: "l"
        )
        nextViewItem.target = MenuActions.shared
        menu.addItem(nextViewItem)

        let nextViewArrowItem = NSMenuItem(
            title: "Next view",
            action: #selector(MenuActions.nextView(_:)),
            keyEquivalent: String(UnicodeScalar(NSRightArrowFunctionKey)!)
        )
        nextViewArrowItem.target = MenuActions.shared
        nextViewArrowItem.keyEquivalentModifierMask = .command
        nextViewArrowItem.isAlternate = true
        menu.addItem(nextViewArrowItem)

        // Tab switching within views: ⌘⇧H / ⌘⇧L and ⌘⇧← / ⌘⇧→
        // Only enabled when the active view has inner tabs
        let hasInnerTabs = sessionManager.activeTab.hasInnerTabs

        let prevTabItem = NSMenuItem(
            title: "Previous tab",
            action: #selector(MenuActions.previousTab(_:)),
            keyEquivalent: "h"
        )
        prevTabItem.target = MenuActions.shared
        prevTabItem.keyEquivalentModifierMask = [.command, .shift]
        prevTabItem.isEnabled = hasInnerTabs
        menu.addItem(prevTabItem)

        let prevTabArrowItem = NSMenuItem(
            title: "Previous tab",
            action: #selector(MenuActions.previousTab(_:)),
            keyEquivalent: String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        )
        prevTabArrowItem.target = MenuActions.shared
        prevTabArrowItem.keyEquivalentModifierMask = [.command, .shift]
        prevTabArrowItem.isEnabled = hasInnerTabs
        prevTabArrowItem.isAlternate = true
        menu.addItem(prevTabArrowItem)

        let nextTabItem = NSMenuItem(
            title: "Next tab",
            action: #selector(MenuActions.nextTab(_:)),
            keyEquivalent: "l"
        )
        nextTabItem.target = MenuActions.shared
        nextTabItem.keyEquivalentModifierMask = [.command, .shift]
        nextTabItem.isEnabled = hasInnerTabs
        menu.addItem(nextTabItem)

        let nextTabArrowItem = NSMenuItem(
            title: "Next tab",
            action: #selector(MenuActions.nextTab(_:)),
            keyEquivalent: String(UnicodeScalar(NSRightArrowFunctionKey)!)
        )
        nextTabArrowItem.target = MenuActions.shared
        nextTabArrowItem.keyEquivalentModifierMask = [.command, .shift]
        nextTabArrowItem.isEnabled = hasInnerTabs
        nextTabArrowItem.isAlternate = true
        menu.addItem(nextTabArrowItem)

        // List item navigation: ⌘⇧K / ⌘⇧J and ⌘⇧↑ / ⌘⇧↓
        let hasListFocus: Bool = {
            switch sessionManager.activeTab {
            case .snapshots: return true
            case .artifacts: return true
            case .agents: return true
            case .ledger: return [.files, .entries].contains(sessionManager.activeLedgerSubTab)
            case .terminal: return false
            case .timeline: return false
            }
        }()
        let focusPrevTitle = "Previous item"
        let focusNextTitle = "Next item"

        let focusPrevItem = NSMenuItem(
            title: focusPrevTitle,
            action: #selector(MenuActions.focusPreviousListItem(_:)),
            keyEquivalent: "k"
        )
        focusPrevItem.target = MenuActions.shared
        focusPrevItem.keyEquivalentModifierMask = [.command, .shift]
        focusPrevItem.isEnabled = hasListFocus
        menu.addItem(focusPrevItem)

        let focusPrevArrowItem = NSMenuItem(
            title: focusPrevTitle,
            action: #selector(MenuActions.focusPreviousListItem(_:)),
            keyEquivalent: String(UnicodeScalar(NSUpArrowFunctionKey)!)
        )
        focusPrevArrowItem.target = MenuActions.shared
        focusPrevArrowItem.keyEquivalentModifierMask = [.command, .shift]
        focusPrevArrowItem.isEnabled = hasListFocus
        focusPrevArrowItem.isAlternate = true
        menu.addItem(focusPrevArrowItem)

        let focusNextItem = NSMenuItem(
            title: focusNextTitle,
            action: #selector(MenuActions.focusNextListItem(_:)),
            keyEquivalent: "j"
        )
        focusNextItem.target = MenuActions.shared
        focusNextItem.keyEquivalentModifierMask = [.command, .shift]
        focusNextItem.isEnabled = hasListFocus
        menu.addItem(focusNextItem)

        let focusNextArrowItem = NSMenuItem(
            title: focusNextTitle,
            action: #selector(MenuActions.focusNextListItem(_:)),
            keyEquivalent: String(UnicodeScalar(NSDownArrowFunctionKey)!)
        )
        focusNextArrowItem.target = MenuActions.shared
        focusNextArrowItem.keyEquivalentModifierMask = [.command, .shift]
        focusNextArrowItem.isEnabled = hasListFocus
        focusNextArrowItem.isAlternate = true
        menu.addItem(focusNextArrowItem)

        // Activate focused item: Enter (snapshots index only, disabled when reader open)
        let activateItem = NSMenuItem(
            title: "Open snapshot",
            action: #selector(MenuActions.activateFocusedListItem(_:)),
            keyEquivalent: "\r"
        )
        activateItem.target = MenuActions.shared
        activateItem.keyEquivalentModifierMask = []
        activateItem.isEnabled = (sessionManager.activeTab == .snapshots && !sessionManager.isSnapshotReaderOpen)
            || (sessionManager.activeTab == .artifacts && !sessionManager.isArtifactReaderOpen)
        menu.addItem(activateItem)

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

        // Terminal tab shell pane controls.
        // Enabled only when the Terminal tab is active and a
        // session exists. Both items take a matching Cmd+T /
        // Cmd+Shift+T binding; the focus-session shortcut
        // returns focus to the Claude terminal after the user
        // has been typing in the shell.
        let canOperateShell = sessionManager.activeTab == .terminal
            && sessionManager.activeSessionId != nil

        let openShellItem = NSMenuItem(
            title: "Open Shell",
            action: #selector(MenuActions.openShell(_:)),
            keyEquivalent: "t"
        )
        openShellItem.target = MenuActions.shared
        openShellItem.isEnabled = canOperateShell
        menu.addItem(openShellItem)

        let focusSessionItem = NSMenuItem(
            title: "Focus Session Pane",
            action: #selector(MenuActions.focusSessionPane(_:)),
            keyEquivalent: "t"
        )
        focusSessionItem.target = MenuActions.shared
        focusSessionItem.keyEquivalentModifierMask =
            [.command, .shift]
        focusSessionItem.isEnabled = canOperateShell
        menu.addItem(focusSessionItem)

        menu.addItem(.separator())

        // Standard view items
        menu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]
    }

    // MARK: - Window Menu

    private func buildWindowMenu(_ menu: NSMenu) {
        let showItem = NSMenuItem(
            title: "Show Galaxy",
            action: #selector(MenuActions.showMainWindow(_:)),
            keyEquivalent: ""
        )
        showItem.target = MenuActions.shared
        menu.addItem(showItem)
        menu.addItem(.separator())
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

    @objc func newSession(_ sender: Any?) {
        NotificationCenter.default.post(name: .showNewSession, object: nil)
    }

    @objc func restoreSession(_ sender: Any?) {
        NotificationCenter.default.post(name: .showRestoreSession, object: nil)
    }

    @objc func stopSession(_ sender: Any?) {
        guard let activeId = SessionManager.shared.activeSessionId else { return }
        SessionManager.shared.confirmAndStopSession(sessionId: activeId)
    }

    @objc func dismissSession(_ sender: Any?) {
        guard let activeId = SessionManager.shared.activeSessionId else { return }
        SessionManager.shared.confirmAndDismissSession(sessionId: activeId)
    }

    // MARK: - Window Menu Actions

    @objc func showMainWindow(_ sender: Any?) {
        NotificationCenter.default.post(
            name: .showMainWindow, object: nil
        )
        NSApp.activate(ignoringOtherApps: true)
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

    @objc func refreshArtifact(_ sender: Any?) {
        NotificationCenter.default.post(
            name: .refreshArtifact, object: nil
        )
    }

    @objc func enterScrollback(_ sender: Any?) {
        NotificationCenter.default.post(name: .enterScrollback, object: nil)
    }

    @objc func clearSession(_ sender: Any?) {
        SessionManager.shared.clearActiveSession()
    }

    @objc func compactSession(_ sender: Any?) {
        SessionManager.shared.compactActiveSession()
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

    @objc func historyBack(_ sender: Any?) {
        SessionManager.shared.navigateBack()
    }

    @objc func historyForward(_ sender: Any?) {
        SessionManager.shared.navigateForward()
    }

    @objc func previousSession(_ sender: Any?) {
        SessionManager.shared.switchToPreviousSession()
    }

    @objc func nextSession(_ sender: Any?) {
        SessionManager.shared.switchToNextSession()
    }

    @objc func previousView(_ sender: Any?) {
        SessionManager.shared.switchToPreviousTab()
    }

    @objc func nextView(_ sender: Any?) {
        SessionManager.shared.switchToNextTab()
    }

    @objc func previousTab(_ sender: Any?) {
        SessionManager.shared.switchToPreviousInnerTab()
    }

    @objc func nextTab(_ sender: Any?) {
        SessionManager.shared.switchToNextInnerTab()
    }

    // MARK: - List Navigation Actions

    @objc func focusPreviousListItem(_ sender: Any?) {
        SessionManager.shared.listNavAction = .up
    }

    @objc func focusNextListItem(_ sender: Any?) {
        SessionManager.shared.listNavAction = .down
    }

    @objc func activateFocusedListItem(_ sender: Any?) {
        SessionManager.shared.listNavAction = .activate
    }

    @objc func defaultTerminalFontSize(_ sender: Any?) {
        SessionManager.shared.activeSession?.resetTerminalFontSize()
    }

    @objc func biggerTerminalFontSize(_ sender: Any?) {
        if let shellPane = Self.focusedShellPane() {
            shellPane.increaseFontSize()
        } else {
            SessionManager.shared.activeSession?
                .increaseTerminalFontSize()
        }
    }

    @objc func smallerTerminalFontSize(_ sender: Any?) {
        if let shellPane = Self.focusedShellPane() {
            shellPane.decreaseFontSize()
        } else {
            SessionManager.shared.activeSession?
                .decreaseTerminalFontSize()
        }
    }

    @objc func openShell(_ sender: Any?) {
        guard let id = SessionManager.shared.activeSessionId
        else { return }
        TerminalTabCommands.shared.openShell.send(id)
    }

    @objc func focusSessionPane(_ sender: Any?) {
        guard let id = SessionManager.shared.activeSessionId
        else { return }
        TerminalTabCommands.shared.focusSession.send(id)
    }

    /// Walk up from the current first responder looking for
    /// a `TerminalHostView` hosting a `ShellTerminalPane`.
    /// Used by ⌘+/⌘- to route font size changes to the focused
    /// pane — shell pane when it's focused, session pane
    /// otherwise. Returns nil when the focus is elsewhere.
    private static func focusedShellPane() -> ShellTerminalPane? {
        guard let window = NSApp.keyWindow,
              let responder =
                window.firstResponder as? NSView
        else { return nil }
        var view: NSView? = responder
        while let v = view {
            if let host = v as? TerminalHostView,
               let shell = host.pane as? ShellTerminalPane {
                return shell
            }
            view = v.superview
        }
        return nil
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
    static let showNewSession = Notification.Name("showNewSession")
    static let showMainWindow = Notification.Name("showMainWindow")
    static let showRestoreSession = Notification.Name("showRestoreSession")
    static let restoreSessionNavigateUp = Notification.Name("restoreSessionNavigateUp")
    static let restoreSessionNavigateDown = Notification.Name("restoreSessionNavigateDown")
    static let restoreSessionConfirm = Notification.Name("restoreSessionConfirm")
    static let refreshArtifact = Notification.Name("refreshArtifact")
}
