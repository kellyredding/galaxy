import AppKit
import Galactic
import Combine
import Carbon.HIToolbox

/// Builds and manages the application's menu bar using AppKit NSMenu.
/// This provides full control over menu items, avoiding SwiftUI's auto-injected File > Close.
/// Uses NSMenuDelegate to rebuild menus just before display, ensuring current state.
/// Also subscribes to session state changes via Combine so that keyboard shortcuts
/// (e.g. ⌘R for Resume) work immediately — `menuNeedsUpdate` only fires reliably
/// when the menu is opened visually, not when macOS matches key equivalents.
///
/// A binding added here also needs a row in `KeystrokeCatalog` — with an
/// availability case that names its gate, and aliases carrying the words
/// its label does not — or it will not appear in the ⌘/ cheat sheet.
/// Nothing fails to say so: the catalog restates these facts rather than
/// deriving them, so a keystroke added without a row is simply absent
/// from the sheet, and the sheet goes on looking complete.
class MainMenu: NSObject, NSMenuDelegate {
    private let sessionManager: SessionManager
    private let settingsManager: SettingsManager
    private var cancellables = Set<AnyCancellable>()

    // Menus that use delegate for dynamic rebuilding
    private var sessionsMenu: NSMenu?
    private var viewMenu: NSMenu?
    private var fileMenu: NSMenu?
    private var editMenu: NSMenu?

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

        // Edit menu — use delegate to rebuild just before
        // display so the Find item's enabled state reflects
        // the current active tab + reader sub-state.
        let editMenu = NSMenu(title: "Edit")
        editMenu.delegate = self
        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        self.editMenu = editMenu
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

        // New Marker (⇧⌘N) - sits between New Session and Restore.
        // keyEquivalent uses lowercase "n"; the explicit
        // keyEquivalentModifierMask adds Shift on top of the
        // implicit Command, producing ⇧⌘N.
        let newMarkerItem = NSMenuItem(
            title: "New Marker...",
            action: #selector(MenuActions.newMarker(_:)),
            keyEquivalent: "n"
        )
        newMarkerItem.keyEquivalentModifierMask = [.command, .shift]
        newMarkerItem.target = MenuActions.shared
        menu.addItem(newMarkerItem)

        // Restore Session (⇧⌘T) - always available.
        //
        // The browser gesture, and sessions are this app's tabs: ⌘W
        // dismisses one, ⇧⌘T brings the last one back. It moved off ⌘O
        // so the Terminal tab could give that to Open Shell Pane, which
        // is a many-times-a-day action where this is not.
        let restoreItem = NSMenuItem(
            title: "Restore Session...",
            action: #selector(MenuActions.restoreSession(_:)),
            keyEquivalent: "t"
        )
        restoreItem.target = MenuActions.shared
        restoreItem.keyEquivalentModifierMask = [.command, .shift]
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
        menu.removeAllItems()

        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        menu.addItem(.separator())

        // Find (⌘F) — enabled when the active tab can host a
        // find bar (terminal with a session, or a snapshot/
        // artifact reader open). The action increments
        // SessionManager.findActivationCounter; surface-side
        // observers do the actual work based on their own
        // gates.
        let findItem = NSMenuItem(
            title: "Find…",
            action: #selector(MenuActions.find(_:)),
            keyEquivalent: "f"
        )
        findItem.target = MenuActions.shared
        findItem.isEnabled = canActivateFind
        menu.addItem(findItem)
    }

    /// Whether the active tab + sub-state can host a find
    /// session. Used to gate the Edit ▸ Find menu item.
    /// Per-surface activation handlers double-check their
    /// own state when the counter ticks, so this is purely
    /// for the visible menu state.
    private var canActivateFind: Bool {
        switch sessionManager.activeTab {
        case .terminal:
            return sessionManager.activeSession != nil
        case .artifacts:
            return sessionManager.isArtifactReaderOpen
        case .snapshots:
            return sessionManager.isSnapshotReaderOpen
        case .agents, .ledger, .timeline:
            return false
        }
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

        menu.addItem(.separator())

        // Previous / Next session — vim-style ⇧⌘K/⇧⌘J with hidden
        // arrow twins ⇧⌘↑/⇧⌘↓. Sessions sit one level out from the
        // panes, which is why these carry Shift and the pane pair
        // does not. Enable state is dynamic via
        // `MenuActions.validateMenuItem`, which the Sessions
        // menu only rebuilds on visual open — pressing the
        // shortcut after creating a second session no longer
        // skips the dispatch on a stale-disabled item.
        let prevTitle = "Previous session"
        let nextTitle = "Next session"

        let prevItem = NSMenuItem(title: prevTitle, action: #selector(MenuActions.previousSession(_:)), keyEquivalent: "k")
        prevItem.target = MenuActions.shared
        prevItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(prevItem)

        let prevArrowItem = NSMenuItem(title: prevTitle, action: #selector(MenuActions.previousSession(_:)), keyEquivalent: String(UnicodeScalar(NSUpArrowFunctionKey)!))
        prevArrowItem.target = MenuActions.shared
        prevArrowItem.keyEquivalentModifierMask = [.command, .shift]
        prevArrowItem.isHidden = true
        menu.addItem(prevArrowItem)

        let nextItem = NSMenuItem(title: nextTitle, action: #selector(MenuActions.nextSession(_:)), keyEquivalent: "j")
        nextItem.target = MenuActions.shared
        nextItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(nextItem)

        let nextArrowItem = NSMenuItem(title: nextTitle, action: #selector(MenuActions.nextSession(_:)), keyEquivalent: String(UnicodeScalar(NSDownArrowFunctionKey)!))
        nextArrowItem.target = MenuActions.shared
        nextArrowItem.keyEquivalentModifierMask = [.command, .shift]
        nextArrowItem.isHidden = true
        menu.addItem(nextArrowItem)

        menu.addItem(.separator())

        // Hide / Show sessions sidebar — keys flip with sidebar
        // position (⌘⇧[ = "toward the panel", ⌘⇧] = "away
        // from the panel"). Enable state is dynamic via
        // `MenuActions.validateMenuItem`, so toggling visibility
        // doesn't strand the inverse shortcut on a stale flag.
        let panelOnLeft = settingsManager.settings.sidebarPosition == .left
        let hideItem = NSMenuItem(
            title: "Hide sessions",
            action: #selector(MenuActions.hideSessions(_:)),
            keyEquivalent: panelOnLeft ? "[" : "]"
        )
        hideItem.target = MenuActions.shared
        hideItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(hideItem)

        let showItem = NSMenuItem(
            title: "Show sessions",
            action: #selector(MenuActions.showSessions(_:)),
            keyEquivalent: panelOnLeft ? "]" : "["
        )
        showItem.target = MenuActions.shared
        showItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(showItem)

        menu.addItem(.separator())

        // Pane focus is NOT a menu item of its own. ⌘K/⌘J mean
        // "previous/next thing on this surface", and on the Terminal
        // tab that thing is a pane — so the View menu's single pair
        // carries both meanings. Two items sharing one key equivalent
        // do not both stay bound: AppKit resolves the duplicate by
        // unbinding one, silently, which is what left ⌘K dead here
        // while ⌘O beside it worked.
        let openShellItem = NSMenuItem(
            title: "Open Shell Pane",
            action: #selector(MenuActions.openShell(_:)),
            keyEquivalent: "o"
        )
        openShellItem.target = MenuActions.shared
        menu.addItem(openShellItem)

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

            // Trim buffer (⌃⌘K). Action is always set; the live
            // enable gate lives in `validateMenuItem` (focused
            // terminal pane). ⌃⌘K is its own equivalent — not shared
            // with any other item — so it displays and dispatches
            // reliably, and the Cmd keeps it out of the terminal's
            // control-character space.
            let trimBufferItem = NSMenuItem(
                title: "Trim Buffer",
                action: #selector(MenuActions.trimBuffer(_:)),
                keyEquivalent: "k"
            )
            trimBufferItem.target = MenuActions.shared
            trimBufferItem.keyEquivalentModifierMask =
                [.command, .control]
            menu.addItem(trimBufferItem)

            // Reflow buffer (⌃L). Redraws the current screen without
            // trimming scrollback. Same focused-pane gate as Trim.
            let reflowBufferItem = NSMenuItem(
                title: "Reflow Buffer",
                action: #selector(MenuActions.reflowBuffer(_:)),
                keyEquivalent: "l"
            )
            reflowBufferItem.target = MenuActions.shared
            reflowBufferItem.keyEquivalentModifierMask = [.control]
            menu.addItem(reflowBufferItem)
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

        // Inbox (⇧⌘I) — what is waiting to reach the active session.
        //
        // Outside the running-session block above, unlike Clear and Compact.
        // Those act on a session and are meaningless without one; this reports
        // on a queue that outlives the session it belongs to, and the question
        // it answers — "where did my message go" — is asked most often when
        // something has just stopped. Lowercase "i" plus an explicit mask, the
        // idiom `newMarkerItem` documents.
        menu.addItem(.separator())
        let inboxItem = NSMenuItem(
            title: "Inbox",
            action: #selector(MenuActions.showAgentInbox(_:)),
            keyEquivalent: "i"
        )
        inboxItem.keyEquivalentModifierMask = [.command, .shift]
        inboxItem.target = MenuActions.shared
        menu.addItem(inboxItem)

        // No key equivalent, deliberately. This answers one recoverable
        // fault and is dimmed in every other state, so a binding would
        // spend a chord on something almost never reachable — and would
        // owe KeystrokeCatalog an availability case for it.
        let markReadyItem = NSMenuItem(
            title: "Mark Session Ready",
            action: #selector(MenuActions.markSessionReady(_:)),
            keyEquivalent: ""
        )
        markReadyItem.target = MenuActions.shared
        menu.addItem(markReadyItem)
    }

    // MARK: - View Menu

    private func buildViewMenu(_ menu: NSMenu) {
        menu.removeAllItems()

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

        // Horizontal navigation, one level per modifier.
        //
        // Unshifted acts on the innermost thing you are in; shifted acts
        // one level out. So ⌘H/L moves between a view's inner tabs and
        // ⇧⌘H/L moves between the views themselves — which is the
        // inverse of how this shipped originally, when the unshifted key
        // took the outer level and the shifted one the inner.
        //
        // ⌘H/L is therefore dead on a view with no inner tabs, and that
        // is deliberate: ⇧⌘H/L means "switch view" everywhere, always,
        // rather than meaning different levels on different tabs.
        let prevTabItem = NSMenuItem(
            title: "Previous tab",
            action: #selector(MenuActions.previousTab(_:)),
            keyEquivalent: "h"
        )
        prevTabItem.target = MenuActions.shared
        menu.addItem(prevTabItem)

        let prevTabArrowItem = NSMenuItem(
            title: "Previous tab",
            action: #selector(MenuActions.previousTab(_:)),
            keyEquivalent: String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        )
        prevTabArrowItem.target = MenuActions.shared
        prevTabArrowItem.keyEquivalentModifierMask = .command
        prevTabArrowItem.isHidden = true
        menu.addItem(prevTabArrowItem)

        let nextTabItem = NSMenuItem(
            title: "Next tab",
            action: #selector(MenuActions.nextTab(_:)),
            keyEquivalent: "l"
        )
        nextTabItem.target = MenuActions.shared
        menu.addItem(nextTabItem)

        let nextTabArrowItem = NSMenuItem(
            title: "Next tab",
            action: #selector(MenuActions.nextTab(_:)),
            keyEquivalent: String(UnicodeScalar(NSRightArrowFunctionKey)!)
        )
        nextTabArrowItem.target = MenuActions.shared
        nextTabArrowItem.keyEquivalentModifierMask = .command
        nextTabArrowItem.isHidden = true
        menu.addItem(nextTabArrowItem)

        let prevViewItem = NSMenuItem(
            title: "Previous view",
            action: #selector(MenuActions.previousView(_:)),
            keyEquivalent: "h"
        )
        prevViewItem.target = MenuActions.shared
        prevViewItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(prevViewItem)

        let prevViewArrowItem = NSMenuItem(
            title: "Previous view",
            action: #selector(MenuActions.previousView(_:)),
            keyEquivalent: String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        )
        prevViewArrowItem.target = MenuActions.shared
        prevViewArrowItem.keyEquivalentModifierMask = [.command, .shift]
        prevViewArrowItem.isHidden = true
        menu.addItem(prevViewArrowItem)

        let nextViewItem = NSMenuItem(
            title: "Next view",
            action: #selector(MenuActions.nextView(_:)),
            keyEquivalent: "l"
        )
        nextViewItem.target = MenuActions.shared
        nextViewItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(nextViewItem)

        let nextViewArrowItem = NSMenuItem(
            title: "Next view",
            action: #selector(MenuActions.nextView(_:)),
            keyEquivalent: String(UnicodeScalar(NSRightArrowFunctionKey)!)
        )
        nextViewArrowItem.target = MenuActions.shared
        nextViewArrowItem.keyEquivalentModifierMask = [.command, .shift]
        nextViewArrowItem.isHidden = true
        menu.addItem(nextViewArrowItem)

        // Vertical navigation, same rule as the horizontal pair
        // above: unshifted is the innermost thing you are in. On a list
        // surface that is the list, so ⌘K/J move the selection and
        // ⇧⌘K/J move between sessions one level out.
        let vertical = MenuActions.verticalNavDescriptor()
        let focusPrevTitle = vertical.previous
        let focusNextTitle = vertical.next

        let focusPrevItem = NSMenuItem(
            title: focusPrevTitle,
            action: #selector(MenuActions.verticalNavPrevious(_:)),
            keyEquivalent: "k"
        )
        focusPrevItem.target = MenuActions.shared
        menu.addItem(focusPrevItem)

        let focusPrevArrowItem = NSMenuItem(
            title: focusPrevTitle,
            action: #selector(MenuActions.verticalNavPrevious(_:)),
            keyEquivalent: String(UnicodeScalar(NSUpArrowFunctionKey)!)
        )
        focusPrevArrowItem.target = MenuActions.shared
        focusPrevArrowItem.keyEquivalentModifierMask = .command
        focusPrevArrowItem.isHidden = true
        menu.addItem(focusPrevArrowItem)

        let focusNextItem = NSMenuItem(
            title: focusNextTitle,
            action: #selector(MenuActions.verticalNavNext(_:)),
            keyEquivalent: "j"
        )
        focusNextItem.target = MenuActions.shared
        menu.addItem(focusNextItem)

        let focusNextArrowItem = NSMenuItem(
            title: focusNextTitle,
            action: #selector(MenuActions.verticalNavNext(_:)),
            keyEquivalent: String(UnicodeScalar(NSDownArrowFunctionKey)!)
        )
        focusNextArrowItem.target = MenuActions.shared
        focusNextArrowItem.keyEquivalentModifierMask = .command
        focusNextArrowItem.isHidden = true
        menu.addItem(focusNextArrowItem)

        // Activate focused item: Enter. The action is consumed
        // by Snapshots / Artifacts / Agents / Ledger surfaces
        // via `SessionManager.listNavAction = .activate`, so
        // the menu title flips to whatever the focused list
        // would open. `MenuActions.validateMenuItem` provides
        // the live enable gate; this build-time title is just
        // what the user sees when they open the View menu.
        let activateItem = NSMenuItem(
            title: MenuActions.openFocusedItemDescriptor().title,
            action: #selector(MenuActions.activateFocusedListItem(_:)),
            keyEquivalent: "\r"
        )
        activateItem.target = MenuActions.shared
        activateItem.keyEquivalentModifierMask = []
        menu.addItem(activateItem)

        menu.addItem(.separator())

        // Terminal font size. Enable state is computed
        // dynamically by `MenuActions.validateMenuItem` —
        // gated on a terminal pane being resolvable, not on
        // whether a session merely exists. Static
        // `isEnabled` would go stale between buildViewMenu
        // calls (the View menu only rebuilds on visual open),
        // which dropped the menu's key equivalents on the
        // floor and let SwiftTerm consume the keystroke.
        //
        // Both groups name their steps "Bigger" and
        // "Smaller", so each sits under a heading. Flat, with
        // only a separator between them, the two pairs were
        // told apart solely by the wording of the item above.
        let terminalFontHeader = NSMenuItem(
            title: "Terminal Font Size", action: nil, keyEquivalent: ""
        )
        terminalFontHeader.isEnabled = false
        menu.addItem(terminalFontHeader)

        let defaultTerminalItem = NSMenuItem(title: "Default", action: #selector(MenuActions.defaultTerminalFontSize(_:)), keyEquivalent: "0")
        defaultTerminalItem.target = MenuActions.shared
        defaultTerminalItem.indentationLevel = 1
        menu.addItem(defaultTerminalItem)

        let biggerTerminalItem = NSMenuItem(title: "Bigger", action: #selector(MenuActions.biggerTerminalFontSize(_:)), keyEquivalent: "=")
        biggerTerminalItem.target = MenuActions.shared
        biggerTerminalItem.indentationLevel = 1
        menu.addItem(biggerTerminalItem)

        let smallerTerminalItem = NSMenuItem(title: "Smaller", action: #selector(MenuActions.smallerTerminalFontSize(_:)), keyEquivalent: "-")
        smallerTerminalItem.target = MenuActions.shared
        smallerTerminalItem.indentationLevel = 1
        menu.addItem(smallerTerminalItem)

        menu.addItem(.separator())

        // Chrome font size. Bounds-checked dynamically by
        // `MenuActions.validateMenuItem` so the keyboard
        // shortcut stops firing at the upper / lower limit
        // without a buildViewMenu rebuild.
        let chromeFontHeader = NSMenuItem(
            title: "Chrome Font Size", action: nil, keyEquivalent: ""
        )
        chromeFontHeader.isEnabled = false
        menu.addItem(chromeFontHeader)

        let defaultChromeItem = NSMenuItem(title: "Default", action: #selector(MenuActions.defaultChromeFontSize(_:)), keyEquivalent: "0")
        defaultChromeItem.target = MenuActions.shared
        defaultChromeItem.keyEquivalentModifierMask = [.command, .shift]
        defaultChromeItem.indentationLevel = 1
        menu.addItem(defaultChromeItem)

        let biggerChromeItem = NSMenuItem(title: "Bigger", action: #selector(MenuActions.biggerChromeFontSize(_:)), keyEquivalent: "=")
        biggerChromeItem.target = MenuActions.shared
        biggerChromeItem.keyEquivalentModifierMask = [.command, .shift]
        biggerChromeItem.indentationLevel = 1
        menu.addItem(biggerChromeItem)

        let smallerChromeItem = NSMenuItem(title: "Smaller", action: #selector(MenuActions.smallerChromeFontSize(_:)), keyEquivalent: "-")
        smallerChromeItem.target = MenuActions.shared
        smallerChromeItem.keyEquivalentModifierMask = [.command, .shift]
        smallerChromeItem.indentationLevel = 1
        menu.addItem(smallerChromeItem)

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

    /// No `delegate = self`, and that is not a compromise. The four menus
    /// that carry one need it because their *items* change — ⌘R swaps
    /// between Refresh artifact and Resume session, ⌘W four ways, the
    /// session list grows. Nothing here changes shape: two items, two
    /// fixed titles, and ⌘/'s only state-dependent behaviour (open vs.
    /// close) is inside `toggle()`. Its one live gate — not beneath a
    /// modal — is `validateMenuItem`'s job, which needs no delegate and
    /// keeps the visible menu and the key equivalent in lockstep. A
    /// delegate would rebuild an identical menu on every open.
    private func buildHelpMenu(_ menu: NSMenu) {
        let appName = ProcessInfo.processInfo.processName
        let helpItem = NSMenuItem(title: "\(appName) Help", action: #selector(NSApplication.showHelp(_:)), keyEquivalent: "?")
        menu.addItem(helpItem)

        // Keyboard Shortcuts (⌘/) opens the in-window cheat sheet. A menu
        // item rather than another local key monitor: this app already
        // runs several of those and they have to reason about one
        // another, whereas a menu item gets dispatch, validation, and
        // menu-bar discoverability for free.
        //
        // ⌘/ and the ⌘? above are the same physical key with different
        // modifier masks, so AppKit matches them separately — no need to
        // reach for keyEquivalentModifierMask.
        menu.addItem(.separator())
        let shortcutsItem = NSMenuItem(
            title: "Keyboard Shortcuts",
            action: #selector(MenuActions.showCheatSheet(_:)),
            keyEquivalent: "/"
        )
        shortcutsItem.target = MenuActions.shared
        menu.addItem(shortcutsItem)

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
        } else if menu === editMenu {
            buildEditMenu(menu)
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

    @objc func newMarker(_ sender: Any?) {
        NotificationCenter.default.post(name: .showNewMarker, object: nil)
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
        SidebarPreferences.shared.setPreferred(false)
    }

    @objc func showSessions(_ sender: Any?) {
        SidebarPreferences.shared.setPreferred(true)
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

    /// ⌘K — the previous thing on this surface: the pane above on the
    /// Terminal tab, the row above on a list.
    @objc func verticalNavPrevious(_ sender: Any?) {
        let sm = SessionManager.shared
        if sm.activeTab == .terminal {
            guard let id = sm.activeSessionId else { return }
            TerminalTabCommands.shared.focusSession.send(id)
        } else {
            sm.listNavAction = .up
        }
    }

    /// ⌘J — the next thing on this surface: the pane below, or the row
    /// below. Declines to open a shell that is not there; that is ⌘O.
    @objc func verticalNavNext(_ sender: Any?) {
        let sm = SessionManager.shared
        if sm.activeTab == .terminal {
            guard let id = sm.activeSessionId else { return }
            TerminalTabCommands.shared.focusShell.send(id)
        } else {
            sm.listNavAction = .down
        }
    }

    @objc func activateFocusedListItem(_ sender: Any?) {
        SessionManager.shared.listNavAction = .activate
    }

    /// View ▸ Default / Bigger / Smaller terminal font size
    /// route through the focused `TerminalPane` so the chrome
    /// layer never reaches into a backend-specific zoom path.
    /// `validateMenuItem` already gates these on a terminal
    /// pane being the first responder; the no-op guard here
    /// is belt-and-suspenders for the (unreachable) case
    /// where validation is bypassed.
    @objc func defaultTerminalFontSize(_ sender: Any?) {
        Self.targetTerminalPane()?.resetFontSize()
    }

    @objc func biggerTerminalFontSize(_ sender: Any?) {
        Self.targetTerminalPane()?.increaseFontSize()
    }

    @objc func smallerTerminalFontSize(_ sender: Any?) {
        Self.targetTerminalPane()?.decreaseFontSize()
    }

    /// Sessions ▸ Trim buffer (⌃⌘K). Routes through the focused
    /// terminal pane so the chrome layer never reaches into a
    /// backend-specific path. `validateMenuItem` gates this on a
    /// terminal pane being focused; the optional-chain no-op is
    /// belt-and-suspenders for the (unreachable) bypassed-validation
    /// case.
    @objc func trimBuffer(_ sender: Any?) {
        Self.targetTerminalPane()?.trimBuffer()
    }

    /// Sessions ▸ Reflow buffer (⌃L). Redraws the focused terminal's
    /// current screen without trimming scrollback.
    @objc func reflowBuffer(_ sender: Any?) {
        Self.targetTerminalPane()?.reflowBuffer()
    }

    @objc func openShell(_ sender: Any?) {
        let sm = SessionManager.shared
        if sm.activeTab != .terminal {
            sm.activeTab = .terminal
        }
        guard let id = sm.activeSessionId else { return }
        TerminalTabCommands.shared.openShell.send(id)
    }



    /// The pane a pane-directed command should act on.
    ///
    /// Prefers the first responder, which is unambiguous while the user is
    /// typing in a terminal. Falls back to the pane-focus memory when that walk
    /// finds nothing — which is not an edge case but two ordinary situations:
    /// the find bar takes key in a panel of its own, so `NSApp.keyWindow` is
    /// not this window at all; and leaving a pane ends in
    /// `makeFirstResponder(nil)`, which leaves the window itself holding it,
    /// and a window is not an `NSView`. In both the user is looking straight at
    /// the terminal they were last in, and a zoom that refuses until they click
    /// back into it is the defect this closes.
    ///
    /// Gated on the Terminal tab because this app hosts the find bar in its
    /// artifact and snapshot readers too — so the bar holding key does not mean
    /// a terminal is on screen, and a zoom must not resize a pane the user
    /// cannot see.
    static func targetTerminalPane() -> TerminalPane? {
        if let focused = focusedTerminalPane() { return focused }
        guard SessionManager.shared.activeTab == .terminal,
              let session = SessionManager.shared.activeSession
        else { return nil }
        return session.paneRegistry.lastFocusedPaneKind == .shell
            ? session.shellPane
            : session.sessionPane
    }

    /// Which pane the caret is literally in, or nil when it is anywhere
    /// else.
    ///
    /// The half-answer below, exposed — and only because one caller wants
    /// exactly the half. `KeystrokeSheetModel` records where focus *is*,
    /// so `KeystrokeAvailability` can tell the keys that need the caret in
    /// a pane (⌘S, the line jumps, the interrupt) from the ones that
    /// settle for the focus memory (the font keys, Trim, Reflow). Every
    /// other caller wants `targetTerminalPane()`, which composes this with
    /// that memory.
    static func focusedPaneKind() -> TerminalPaneKind? {
        focusedTerminalPane()?.paneKind
    }

    /// Walk up from the current first responder looking for
    /// a `TerminalHostView` and return its hosted
    /// `TerminalPane` (Session or Shell).
    ///
    /// Private, and deliberately only half an answer: it reports where the
    /// caret literally is, which is nil for every case
    /// `targetTerminalPane` exists to cover. Callers want that one, or the
    /// kind-only accessor above.
    private static func focusedTerminalPane() -> TerminalPane? {
        guard let window = NSApp.keyWindow,
              let responder =
                window.firstResponder as? NSView
        else { return nil }
        var view: NSView? = responder
        while let v = view {
            if let host = v as? TerminalHostView {
                return host.pane
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

    // MARK: - Edit Menu Actions

    /// Bumps SessionManager's find-activation counter; the
    /// active surface (terminal host, artifact reader frame,
    /// snapshot reader frame) observes the bump and brings up
    /// its find bar based on its own gates.
    @objc func find(_ sender: Any?) {
        SessionManager.shared.activateFind()
    }

    // MARK: - Help Menu Actions

    /// Help ▸ Keyboard Shortcuts (⌘/). Toggles, so the same keystroke
    /// that summons the sheet puts it away.
    ///
    /// `assumeIsolated` rather than a hop: AppKit dispatches menu actions
    /// on the main thread, and hopping would let the sheet's snapshot be
    /// taken a runloop turn later than the keystroke that asked for it —
    /// long enough for the first responder it reads to have moved. The
    /// snapshot is taken inside the sections provider `toggle()` invokes
    /// (see `KeystrokeSheetModel`), so a hop would move the reading of
    /// focus, not just the presentation.
    @objc func showCheatSheet(_ sender: Any?) {
        MainActor.assumeIsolated { CheatSheetPresenter.shared.toggle() }
    }

    /// Sessions ▸ Inbox. Opens what is waiting to reach the active session.
    @objc func showAgentInbox(_ sender: Any?) {
        MainActor.assumeIsolated { AgentInboxPresenter.shared.toggle() }
    }

    /// Sessions ▸ Mark Session Ready. Releases a queue whose readiness signal
    /// never arrived.
    ///
    /// Asserts a fact rather than forcing one: validation restricts this to
    /// `.neverReady`, which by construction means the agent has been sitting at
    /// a prompt while nothing told the app so. `markReady` wakes the consumer
    /// itself, so anything waiting goes out from here.
    @objc func markSessionReady(_ sender: Any?) {
        MainActor.assumeIsolated {
            guard let session = SessionManager.shared.activeSession,
                  session.submitBlockReason == .neverReady
            else { return }
            SessionSubmit.log(
                "mark-ready by hand session=\(session.sessionRef)")
            session.markReady()
        }
    }

}

// MARK: - Menu Validation

/// Dynamic enable/disable for menu items whose state can
/// shift between `buildXxxMenu` calls — primarily the View
/// ▸ font-size shortcuts. AppKit calls `validateMenuItem`
/// both on visual menu open and on key-equivalent dispatch,
/// so the keyboard shortcut and the visible menu state stay
/// in lockstep without reactive Combine rebuilds for each
/// underlying signal (active session, per-pane font size,
/// chrome font size, first responder).
///
/// Items not handled here defer to the explicit `isEnabled`
/// set inside the matching `buildXxxMenu` — that preserves
/// the existing build-time logic for every other action
/// (Find, Back/Forward, Hide/Show sessions, list-nav, etc.).
extension MenuActions: NSMenuItemValidation {
    func validateMenuItem(
        _ menuItem: NSMenuItem
    ) -> Bool {
        switch menuItem.action {
        // Terminal font items: only fire when a terminal pane
        // can be named — the one holding the caret, or the one
        // the user was last in on the Terminal tab.
        // `targetTerminalPane()` returns the protocol-typed
        // pane (Session or Shell) so neither this gate nor
        // the action handlers couple to SwiftTerm.
        case #selector(defaultTerminalFontSize(_:)):
            return Self.targetTerminalPane() != nil
        case #selector(biggerTerminalFontSize(_:)):
            return Self.targetTerminalPane()?
                .canIncreaseFontSize ?? false
        case #selector(smallerTerminalFontSize(_:)):
            return Self.targetTerminalPane()?
                .canDecreaseFontSize ?? false

        // Sessions ▸ Trim buffer. Live-gated on a terminal pane being
        // nameable, so the item (and its ⌃⌘K equivalent) is active only
        // on the Terminal tab.
        case #selector(trimBuffer(_:)):
            return Self.targetTerminalPane() != nil
        // Split from Trim for one reason: ⌃L carries no Command, so it is
        // reachable from a text field the user is typing in — including
        // the cheat sheet's search field, which is why the sheet has to
        // be able to take it back.
        case #selector(reflowBuffer(_:)):
            return !KeystrokeSheetModel.isClaimingKeyboard
                && Self.targetTerminalPane() != nil

        // Help ▸ Keyboard Shortcuts. Live everywhere except beneath a
        // modal: Settings and Restore Session run their own
        // `NSApp.runModal` loops, and a sheet opened behind one would be
        // invisible while its Escape monitor took Escape from the panel
        // the user is actually looking at.
        case #selector(showCheatSheet(_:)):
            return NSApp.modalWindow == nil

        // Sessions ▸ Inbox. Same modal gate as the cheat sheet, and for the
        // same reason: Settings and Restore Session run their own
        // `NSApp.runModal` loops, and an overlay opened behind one would be
        // invisible while its Escape monitor took Escape from the panel the
        // reader is actually looking at.
        //
        // No session gate. A queue survives the session it was filled for, so
        // dimming this when nothing is running would hide the messages exactly
        // when someone is looking for them.
        case #selector(showAgentInbox(_:)):
            return NSApp.modalWindow == nil

        // The interlock, and the whole reason this is a menu item rather
        // than a button on the refusal. `.neverReady` is the one blocked
        // state a person can truthfully resolve; the others are either
        // transient or owe an ordered command that releasing early would
        // overtake. Dimmed everywhere else, so the menu answers "is this
        // my problem" without anyone having to try it.
        case #selector(markSessionReady(_:)):
            return SessionManager.shared.activeSession?
                .submitBlockReason == .neverReady

        // Chrome font items: bound-checked against the live
        // settings value, never gated on focus — the user
        // wants ⌘⇧+/⌘⇧-/⌘⇧0 working from any tab.
        case #selector(biggerChromeFontSize(_:)):
            return SettingsManager.shared.settings
                .chromeFontSize
                < AppSettings.chromeFontSizeRange.upperBound
        case #selector(smallerChromeFontSize(_:)):
            return SettingsManager.shared.settings
                .chromeFontSize
                > AppSettings.chromeFontSizeRange.lowerBound
        case #selector(defaultChromeFontSize(_:)):
            return true

        // Sessions ▸ Previous / Next session. Live gates on
        // SessionManager so creating a second session
        // immediately makes the shortcuts dispatch — the
        // Sessions menu only rebuilds on visual open and
        // would otherwise leave both items stale-disabled
        // through the entire keyboard-only workflow.
        case #selector(previousSession(_:)):
            return SessionManager.shared
                .canSwitchToPreviousSession
        case #selector(nextSession(_:)):
            return SessionManager.shared
                .canSwitchToNextSession

        // Sessions ▸ Hide / Show sessions sidebar. The
        // visible state flips with every dispatch, so the
        // inverse shortcut needs to come live again
        // immediately. Reads the narrow `SidebarPreferences`
        // publisher — same source the action handlers
        // mutate, so the gate and the dispatch agree.
        //
        // Deliberately the effective value and not
        // `preferredVisible`: while a collapse condition holds
        // the panel shut, Show is the item that does something
        // and Hide is the one that would be a no-op. Gating on
        // the choice would offer the reader the wrong half.
        // Sessions ▸ Open Shell Pane. Gated on the Terminal tab:
        // the panes it opens only exist there.
        case #selector(openShell(_:)):
            return SessionManager.shared.activeTab == .terminal
                && SessionManager.shared.activeSessionId != nil

        // View ▸ list navigation and inner tabs. Live for the
        // same reason the terminal font items above are: the View
        // menu rebuilds only on visual open, so a build-time
        // `isEnabled` goes stale the moment the reader changes tab
        // — and a stale-disabled item drops its key equivalent on
        // the floor, where SwiftTerm takes it as terminal input.
        case #selector(verticalNavPrevious(_:)),
             #selector(verticalNavNext(_:)):
            return Self.verticalNavDescriptor().enabled

        case #selector(previousTab(_:)),
             #selector(nextTab(_:)):
            return SessionManager.shared.activeTab.hasInnerTabs

        case #selector(hideSessions(_:)):
            return SidebarPreferences.shared.isVisible
        case #selector(showSessions(_:)):
            return !SidebarPreferences.shared.isVisible

        // View ▸ Open <thing>. Source of truth is
        // `openFocusedItemDescriptor`, also consumed by
        // buildViewMenu for the menu title — so the wording
        // and the enable gate are guaranteed to agree about
        // which surfaces own the Enter shortcut.
        case #selector(activateFocusedListItem(_:)):
            // The one bare key equivalent in this app's menus. AppKit
            // matches menu equivalents in `sendEvent` ahead of the
            // responder chain, so while the cheat sheet's search field
            // has the caret this item would otherwise open a row behind
            // the sheet and the reader would see their Return vanish.
            return !KeystrokeSheetModel.isClaimingKeyboard
                && Self.openFocusedItemDescriptor().enabled

        // For everything else, the explicit `isEnabled` set
        // by the relevant `buildXxxMenu` IS the answer. Once
        // a target conforms to NSMenuItemValidation, AppKit
        // routes every item targeting it through this method
        // — returning `menuItem.isEnabled` keeps that logic
        // intact rather than forcing a parallel reimpl here.
        default:
            return menuItem.isEnabled
        }
    }

    /// Title and enable gate for the View ▸ Open <thing>
    /// menu item, derived from the active tab and (for
    /// Ledger) sub-tab. Single source of truth: buildViewMenu
    /// reads `.title` for the visible label, validateMenuItem
    /// reads `.enabled` for the dispatch gate. The active
    /// surfaces — Snapshots, Artifacts, Agents, Ledger Files
    /// / Entries — are the ones whose `.onChange` handlers
    /// consume `SessionManager.listNavAction = .activate`.
    /// All other tabs (Terminal, Timeline, the read-only
    /// Ledger sub-tabs) collapse to a neutral disabled "Open".
    /// Titles and enable gate for the View menu's ⌘K / ⌘J pair.
    ///
    /// One pair of items rather than one per meaning. Two menu items
    /// sharing a key equivalent do not both stay bound — AppKit resolves
    /// the duplicate by unbinding one, with no warning and no way to see
    /// it from the source. That is the trap `KeystrokeSmoke` already
    /// records as "⌘R's two meanings and its hole", and it is why the
    /// pane-focus commands have no menu items of their own.
    ///
    /// Same shape as `openFocusedItemDescriptor`: buildViewMenu reads the
    /// titles, validateMenuItem reads the gate, so the words and the
    /// dispatch cannot disagree.
    static func verticalNavDescriptor() -> (
        previous: String, next: String, enabled: Bool
    ) {
        let sm = SessionManager.shared
        if sm.activeTab == .terminal {
            return (
                "Focus Session Pane", "Focus Shell Pane",
                sm.activeSessionId != nil
            )
        }
        return ("Previous item", "Next item", hasListFocus())
    }

    /// Whether the active surface has a focusable list, in the sense
    /// `buildViewMenu` means it.
    ///
    /// Live rather than a stored flag, and shared by the menu builder
    /// and the validator so the two cannot disagree about which
    /// surfaces own ⌘J/K. Asks `KeystrokeCatalog.ledgerListSubTabs`
    /// for the Ledger's answer rather than restating it, which is the
    /// third caller of that set and the reason it is named once.
    static func hasListFocus() -> Bool {
        let sm = SessionManager.shared
        switch sm.activeTab {
        case .snapshots, .artifacts, .agents:
            return true
        case .ledger:
            return KeystrokeCatalog.ledgerListSubTabs
                .contains(sm.activeLedgerSubTab)
        case .terminal, .timeline:
            return false
        }
    }

    static func openFocusedItemDescriptor() -> (
        title: String, enabled: Bool
    ) {
        let sm = SessionManager.shared
        switch sm.activeTab {
        case .snapshots:
            return (
                "Open snapshot", !sm.isSnapshotReaderOpen
            )
        case .artifacts:
            return (
                "Open artifact", !sm.isArtifactReaderOpen
            )
        case .agents:
            return ("Open agent run", true)
        case .ledger:
            switch sm.activeLedgerSubTab {
            case .fileAccess: return ("Reveal file in Finder", true)
            case .entries: return ("Open entry", true)
            case .identifiers, .lastActivity,
                 .suggestedName:
                return ("Open", false)
            }
        case .terminal, .timeline:
            return ("Open", false)
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let showPreferences = Notification.Name("showPreferences")
    static let showNewSession = Notification.Name("showNewSession")
    static let showNewMarker = Notification.Name("showNewMarker")
    static let showMainWindow = Notification.Name("showMainWindow")
    static let showRestoreSession = Notification.Name("showRestoreSession")
    static let restoreSessionNavigateUp = Notification.Name("restoreSessionNavigateUp")
    static let restoreSessionNavigateDown = Notification.Name("restoreSessionNavigateDown")
    static let restoreSessionConfirm = Notification.Name("restoreSessionConfirm")
    static let refreshArtifact = Notification.Name("refreshArtifact")
    static let enterScrollback = Notification.Name("enterScrollback")
}

extension MenuActions {
    /// The ⌘S notification above, as a terminal host consumes it.
    ///
    /// A host is told that the user asked to open a scrollback; how the menu
    /// said so is this app's business, and a broadcast is how it says so here
    /// because the menu has no handle on whichever host should answer. Mapping
    /// it where the notification is declared keeps both halves of that decision
    /// together.
    static var scrollbackActivations: ScrollbackActivations {
        NotificationCenter.default
            .publisher(for: .enterScrollback)
            .map { _ in () }
            .eraseToAnyPublisher()
    }
}
