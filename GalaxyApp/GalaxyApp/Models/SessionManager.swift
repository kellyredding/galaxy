import Foundation
import AppKit
import SwiftUI
import SwiftTerm

enum ListNavAction {
    case up, down, activate
}

enum AnnotationAction {
    case moveUp, moveDown
    case extendUp, extendDown
}

class SessionManager: ObservableObject {
    // Singleton instance for access from AppDelegate
    static let shared = SessionManager()

    @Published var sessions: [Session] = []
    @Published var activeSessionId: UUID?

    // Track whether the main window is focused (for bell indicator logic)
    @Published var isWindowFocused: Bool = true

    // Sidebar visibility — persisted in AppSettings, accessed via
    // SettingsManager. Computed property delegates read/write so
    // existing view code (ContentView, MainMenu) works unchanged.
    var isSidebarVisible: Bool {
        get { SettingsManager.shared.settings.isSidebarVisible }
        set { SettingsManager.shared.settings.isSidebarVisible = newValue }
    }

    // Active tab in the views area (global, not per-session)
    // Not persisted — always starts on Terminal at launch
    @Published var activeTab: SessionTab = .terminal

    // Active subtab within Ledger view (global, not per-session)
    // Not persisted — always starts on Last Activity at launch
    @Published var activeLedgerSubTab: LedgerSubTab = .lastActivity

    /// Snapshot number to auto-open when switching to snapshots tab.
    /// Set by EventCoordinator on snapshot.created, cleared by SnapshotsView after opening.
    @Published var pendingSnapshotNumber: Int32? = nil

    /// List navigation action bridged from menu shortcuts.
    /// Set by MenuActions, consumed by the active list view's onChange handler.
    @Published var listNavAction: ListNavAction? = nil

    /// Whether the snapshot reader is open (controls keyboard shortcut routing).
    /// When true, Cmd+J/K dispatch annotation actions instead of session switching.
    @Published var isSnapshotReaderOpen: Bool = false

    /// Annotation navigation action bridged from menu shortcuts when reader is open.
    /// Set by MenuActions, consumed by SnapshotsView's onChange handler.
    @Published var annotationAction: AnnotationAction? = nil

    /// Called when a session is removed from the session list.
    /// Used by EventCoordinator to clean up cached ledger_session_id mappings.
    var onSessionClosed: ((UUID) -> Void)?

    // Track if active session can be resumed (for menu updates)
    @Published var activeSessionCanResume: Bool = false

    /// Tracks last auto-clear time per session to prevent re-triggering
    /// before enrichment updates with fresh post-clear context percentage.
    private var lastAutoClearTime: [UUID: Date] = [:]

    /// Minimum seconds between auto-clears for the same session.
    private static let autoClearCooldown: TimeInterval = 30

    // Path to claude binary - detected at init
    let claudePath: String

    // Path to claude-persona binary - detected at init, nil if not installed
    let claudePersonaPath: String?

    var activeSession: Session? {
        sessions.first { $0.id == activeSessionId }
    }

    /// Update the activeSessionCanResume flag based on current state
    private func updateActiveSessionCanResume() {
        let canResume = activeSession?.hasExited ?? false
        if activeSessionCanResume != canResume {
            activeSessionCanResume = canResume
        }
    }

    init() {
        // Detect binary paths
        self.claudePath = SessionManager.findBinaryPath(
            name: "claude",
            searchPaths: [
                "\(NSHomeDirectory())/.local/bin/claude",
                "/usr/local/bin/claude",
                "/opt/homebrew/bin/claude",
            ],
            fallback: "\(NSHomeDirectory())/.local/bin/claude"
        )
        self.claudePersonaPath = SessionManager.findBinaryPath(name: "claude-persona")

        // Restore persisted sessions (all as stopped)
        if let persisted = SessionPersistence.shared.load() {
            for state in persisted.sessions {
                let session = Session(restoring: state)
                sessions.append(session)
            }
            if let activeId = persisted.activeSessionId {
                activeSessionId = activeId
            }
            NSLog(
                "SessionManager: Restored %d session(s) from disk",
                sessions.count
            )
        }
    }

    /// Find a binary by checking common paths, then falling back to `which`.
    /// Returns the resolved path, or `fallback` if provided and nothing found, or nil.
    private static func findBinaryPath(
        name: String,
        searchPaths: [String]? = nil,
        fallback: String? = nil
    ) -> String? {
        // Check explicit search paths first
        let paths = searchPaths ?? [
            "\(NSHomeDirectory())/.local/bin/\(name)",
            "/usr/local/bin/\(name)",
        ]

        for path in paths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Fallback: which command
        let task = Process()
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = [name]

        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !output.isEmpty {
                return output
            }
        } catch {
            // Ignore errors
        }

        return fallback
    }

    // Non-optional overload for claude (always returns a path)
    private static func findBinaryPath(
        name: String,
        searchPaths: [String],
        fallback: String
    ) -> String {
        return findBinaryPath(name: name, searchPaths: searchPaths, fallback: fallback as String?) ?? fallback
    }

    @discardableResult
    func createSession(
        workingDirectory: String? = nil,
        personaName: String? = nil,
        givenName: String? = nil,
        isVibe: Bool = false,
        resumeSessionId: String? = nil
    ) -> Session {
        let directory = workingDirectory ?? NSHomeDirectory()
        let sessionId = SessionIDGenerator.generate()

        // Parse resume UUID if provided
        let resumeUUID: UUID? = resumeSessionId.flatMap { UUID(uuidString: $0) }

        let session = Session(
            workingDirectory: directory,
            sessionRef: sessionId,
            personaName: personaName,
            isVibe: isVibe,
            resumeSessionId: resumeUUID
        )

        // Set optional user-assigned name (Galaxy-only, not passed to Claude)
        session.givenName = givenName

        // Determine the executable path: claude-persona for persona sessions, claude for vanilla
        let executablePath: String
        if personaName != nil, let cpPath = claudePersonaPath {
            executablePath = cpPath
        } else {
            executablePath = claudePath
        }

        // Set up terminal delegate to track process termination
        // Store a strong reference in session so it doesn't get deallocated
        let handler = TerminalProcessHandler(session: session, sessionManager: self)
        session.processHandler = handler
        session.terminalView.processDelegate = handler

        // Set up bell callback — handles sound/visual bell only.
        // Unread indicator is triggered by busy→idle, not bell events.
        session.terminalView.onBell = { [weak session] in
            guard let session = session else { return }
            DispatchQueue.main.async {
                let preference = SettingsManager.shared.settings.bellPreference

                switch preference {
                case .visualBell:
                    self.triggerVisualBell(for: session)
                case .none:
                    break
                default:
                    SettingsManager.shared.handleBell()
                }
            }
        }

        // Set up data received callback for busy state detection
        session.terminalView.onDataReceived = { [weak session] in
            session?.markBusy()
        }

        // Register persistent idle callback for auto-clear + unread indicator
        session.onIdleTransition = { [weak self] session in
            self?.handleIdleTransition(for: session)
        }

        // Determine if this is a resume (resumeSessionId provided means URL had resume param)
        let isResume = resumeSessionId != nil

        // Start the process
        session.startProcess(executablePath: executablePath, resume: isResume)

        sessions.append(session)
        activeSessionId = session.id
        activeTab = .terminal
        SessionPersistence.shared.markDirty()

        return session
    }

    func handleSessionExited(sessionId: UUID) {
        NSLog("SessionManager: handleSessionExited called for %@", sessionId.uuidString)

        // Sessions are kept in sidebar when they exit (no removal)
        // The session's hasExited flag is already set by the process handler

        // Update menu state and persist
        DispatchQueue.main.async {
            self.updateActiveSessionCanResume()
            SessionPersistence.shared.markDirty()
        }

        NSLog("SessionManager: Session marked as exited, keeping in sidebar")
    }

    func stopSession(sessionId: UUID) {
        guard let session = sessions.first(where: { $0.id == sessionId }) else {
            NSLog("SessionManager: Cannot stop - session not found")
            return
        }

        guard !session.hasExited else {
            NSLog("SessionManager: Cannot stop - session already stopped")
            return
        }

        NSLog("SessionManager: Stopping session %@", session.sessionRef)

        // Terminate the process using our tracked PID (sends SIGTERM)
        session.terminateProcess()

        // Switch to terminal so the user sees the stopped state
        activeTab = .terminal
    }

    func resumeSession(sessionId: UUID) {
        guard let session = sessions.first(where: { $0.id == sessionId }) else {
            NSLog("SessionManager: Cannot resume - session not found")
            return
        }

        guard session.hasExited else {
            NSLog("SessionManager: Cannot resume - session is still running")
            return
        }

        // Check if working directory still exists
        if !FileManager.default.fileExists(atPath: session.workingDirectory) {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Cannot Resume Session"
                alert.informativeText = """
                    The working directory for this session no longer \
                    exists:

                    \(session.workingDirectory)

                    You can close this session or copy the resume \
                    command to restart it manually.
                    """
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
            return
        }

        // Check if Claude has this session saved on disk
        let canResume = claudeSessionExists(sessionId: session.claudeSessionId, workingDirectory: session.workingDirectory)

        if canResume {
            NSLog("SessionManager: Resuming session %@ (found in Claude storage)", session.sessionRef)
        } else {
            NSLog("SessionManager: Session %@ not found in Claude storage, starting fresh", session.sessionRef)
        }

        // Switch to terminal so the user sees the resumed session
        activeTab = .terminal

        // Reset session state
        session.hasExited = false
        session.exitCode = nil
        session.isRunning = false

        // Disable focus reporting (mode 1004) before the view transition.
        // Claude Code enables mode 1004 so SwiftTerm sends ESC[I on focus-in.
        // During resume, the view swap triggers a focus event before the new
        // process is ready to parse it, leaking a stray "I" into the input.
        // The new Claude process will re-enable mode 1004 when it initializes.
        session.terminalView.feed(text: "\u{1b}[?1004l")

        // Clear the terminal buffer before resuming
        // This prevents duplicate content when Claude redraws after resume
        // ESC[2J = clear screen, ESC[3J = clear scrollback, ESC[H = cursor home
        session.terminalView.feed(text: "\u{1b}[2J\u{1b}[3J\u{1b}[H")

        // Re-attach process handler
        let handler = TerminalProcessHandler(session: session, sessionManager: self)
        session.processHandler = handler
        session.terminalView.processDelegate = handler

        // Set up bell callback — handles sound/visual bell only.
        // Unread indicator is triggered by busy→idle, not bell events.
        session.terminalView.onBell = { [weak session] in
            guard let session = session else { return }
            DispatchQueue.main.async {
                let preference = SettingsManager.shared.settings.bellPreference

                switch preference {
                case .visualBell:
                    self.triggerVisualBell(for: session)
                case .none:
                    break
                default:
                    SettingsManager.shared.handleBell()
                }
            }
        }

        // Set up data received callback for busy state detection
        session.terminalView.onDataReceived = { [weak session] in
            session?.markBusy()
        }

        // Register persistent idle callback for auto-clear + unread indicator
        session.onIdleTransition = { [weak self] session in
            self?.handleIdleTransition(for: session)
        }

        // Determine executable path: claude-persona for persona sessions, claude for vanilla
        let executablePath: String
        if session.personaName != nil, let cpPath = claudePersonaPath {
            executablePath = cpPath
        } else {
            executablePath = claudePath
        }

        // Start process: --resume if session exists in Claude storage, --session-id if not
        session.startProcess(executablePath: executablePath, resume: canResume)

        // Auto-handoff: send /handoff after Claude finishes booting.
        // Extra 1s delay after idle gives the TUI time to fully
        // initialize its input field after resume redraw.
        session.afterNextIdle { [weak session] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak session] in
                session?.sendCommand("/handoff")
            }
        }

        // Make this the active session
        activeSessionId = session.id
        SessionPersistence.shared.markDirty()

        // Update menu state (session is now running, not resumable)
        updateActiveSessionCanResume()
    }

    /// Clear the active session and auto-handoff when Claude settles.
    func clearActiveSession() {
        guard let session = activeSession, session.isRunning, !session.hasExited else { return }
        clearAndHandoff(session)
    }

    /// Compact the active session and auto-handoff when Claude settles.
    func compactActiveSession() {
        guard let session = activeSession, session.isRunning, !session.hasExited else { return }
        session.sendCommand("/compact")
        // Extra 1s delay after idle gives the TUI time to fully
        // settle after the compact operation completes.
        session.afterNextIdle { [weak session] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak session] in
                session?.sendCommand("/handoff")
            }
        }
    }

    /// Send /clear to a session and queue /handoff after it settles.
    /// Used by clearActiveSession, compactActiveSession, and auto-clear.
    private func clearAndHandoff(_ session: Session) {
        session.sendCommand("/clear")
        session.afterNextIdle { [weak session] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak session] in
                session?.sendCommand("/handoff")
            }
        }
    }

    /// Called on every busy→idle transition for a session.
    /// Checks context usage and auto-clears if above threshold.
    private func handleIdleTransition(for session: Session) {
        // Show unread indicator when a non-focused session goes idle
        // (assistant finished responding while you're elsewhere)
        let showIndicator = SettingsManager.shared.settings.showUnreadIndicator
        let isViewingThisSession = session.id == activeSessionId && activeTab == .terminal
        if showIndicator && !isViewingThisSession {
            session.hasUnreadResponse = true
        }

        let settings = SettingsManager.shared.settings
        guard settings.autoClearEnabled else { return }

        // ledgerContextPercentage is 0–100 (integer scale), matching the setting
        let threshold = Double(settings.autoClearThreshold)
        guard let contextPct = session.ledgerContextPercentage,
              contextPct > threshold else { return }

        // Cooldown: don't re-trigger within 30 seconds of last auto-clear
        if let lastClear = lastAutoClearTime[session.id],
           Date().timeIntervalSince(lastClear) < Self.autoClearCooldown {
            return
        }

        NSLog("SessionManager: Auto-clearing %@ — context at %.0f%%",
              session.sessionRef, contextPct * 100)

        lastAutoClearTime[session.id] = Date()
        clearAndHandoff(session)
    }

    /// Check if Claude has a session saved on disk for the given session ID and working directory
    private func claudeSessionExists(sessionId: String, workingDirectory: String) -> Bool {
        // Claude stores session data in ~/.claude/projects/<escaped-path>/<session-id>.jsonl
        // Path escaping: /Users/foo.bar/baz becomes -Users-foo-bar-baz (slashes AND dots become dashes)
        let escapedPath = workingDirectory
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
            .appendingPathComponent(escapedPath)

        // Check for the actual session data file (not just the index)
        let sessionFile = claudeDir.appendingPathComponent("\(sessionId).jsonl")
        let exists = FileManager.default.fileExists(atPath: sessionFile.path)

        NSLog("SessionManager: Session file %@.jsonl %@ at %@", sessionId, exists ? "found" : "not found", claudeDir.path)
        return exists
    }

    func switchTo(sessionId: UUID) {
        guard let session = sessions.first(where: { $0.id == sessionId }) else { return }
        activeSessionId = sessionId
        SessionPersistence.shared.markDirty()

        // Clear unread indicator immediately on switch (with fade animation).
        // Done here rather than solely in SessionRow's onChange(of: isSelected)
        // to avoid gesture disambiguation delays when double-click gestures
        // exist on child views. Only clears when on the terminal tab — viewing
        // Ledger or Snapshots keeps the indicator visible.
        if session.hasUnreadResponse && isWindowFocused && activeTab == .terminal {
            withAnimation(.easeOut(duration: 3.0)) {
                session.hasUnreadResponse = false
            }
        }

        // Update menu state for the newly active session
        updateActiveSessionCanResume()
    }

    func closeSession(sessionId: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else { return }

        NSLog("SessionManager: closeSession called for session %@", sessionId.uuidString)

        // Determine next session to select
        var nextActiveId: UUID? = nil
        if sessions.count > 1 {
            if index > 0 {
                nextActiveId = sessions[index - 1].id
            } else {
                nextActiveId = sessions[index + 1].id
            }
        }

        // Notify observers before removal (e.g., EventCoordinator cache cleanup)
        onSessionClosed?(sessionId)

        // Clean up auto-clear cooldown tracking
        lastAutoClearTime.removeValue(forKey: sessionId)

        // Remove the session (this will deallocate the terminal view which kills the process)
        sessions.remove(at: index)
        SessionPersistence.shared.markDirty()

        // Update active session
        if activeSessionId == sessionId {
            activeSessionId = nextActiveId
        }

        NSLog("SessionManager: Session removed, remaining count: %d", sessions.count)
    }

    /// Whether there's a previous session to switch to (not at top of list)
    var canSwitchToPreviousSession: Bool {
        guard sessions.count > 1,
              let currentId = activeSessionId,
              let currentIndex = sessions.firstIndex(where: { $0.id == currentId }) else { return false }
        return currentIndex > 0
    }

    /// Whether there's a next session to switch to (not at bottom of list)
    var canSwitchToNextSession: Bool {
        guard sessions.count > 1,
              let currentId = activeSessionId,
              let currentIndex = sessions.firstIndex(where: { $0.id == currentId }) else { return false }
        return currentIndex < sessions.count - 1
    }

    /// Switch to the previous session in the list (no wrap)
    func switchToPreviousSession() {
        guard canSwitchToPreviousSession,
              let currentId = activeSessionId,
              let currentIndex = sessions.firstIndex(where: { $0.id == currentId }) else { return }

        switchTo(sessionId: sessions[currentIndex - 1].id)
    }

    /// Switch to the next session in the list (no wrap)
    func switchToNextSession() {
        guard canSwitchToNextSession,
              let currentId = activeSessionId,
              let currentIndex = sessions.firstIndex(where: { $0.id == currentId }) else { return }

        switchTo(sessionId: sessions[currentIndex + 1].id)
    }

    /// Switch to the previous tab (stops at first boundary)
    func switchToPreviousTab() {
        let allTabs = SessionTab.allCases
        guard let currentIndex = allTabs.firstIndex(of: activeTab),
              currentIndex > allTabs.startIndex else { return }
        activeTab = allTabs[allTabs.index(before: currentIndex)]
    }

    /// Switch to the next tab (stops at last boundary)
    func switchToNextTab() {
        let allTabs = SessionTab.allCases
        guard let currentIndex = allTabs.firstIndex(of: activeTab) else { return }
        let nextIndex = allTabs.index(after: currentIndex)
        guard nextIndex < allTabs.endIndex else { return }
        activeTab = allTabs[nextIndex]
    }

    /// Switch to the previous inner tab within the active view (stops at first boundary)
    func switchToPreviousInnerTab() {
        switch activeTab {
        case .ledger:
            let allTabs = LedgerSubTab.allCases
            guard let currentIndex = allTabs.firstIndex(of: activeLedgerSubTab),
                  currentIndex > allTabs.startIndex else { return }
            activeLedgerSubTab = allTabs[allTabs.index(before: currentIndex)]
        default:
            break
        }
    }

    /// Switch to the next inner tab within the active view (stops at last boundary)
    func switchToNextInnerTab() {
        switch activeTab {
        case .ledger:
            let allTabs = LedgerSubTab.allCases
            guard let currentIndex = allTabs.firstIndex(of: activeLedgerSubTab) else { return }
            let nextIndex = allTabs.index(after: currentIndex)
            guard nextIndex < allTabs.endIndex else { return }
            activeLedgerSubTab = allTabs[nextIndex]
        default:
            break
        }
    }

    /// Swap two sessions in the array (used during drag-to-reorder)
    func swapSessions(_ indexA: Int, _ indexB: Int) {
        guard indexA >= 0 && indexA < sessions.count else { return }
        guard indexB >= 0 && indexB < sessions.count else { return }
        sessions.swapAt(indexA, indexB)
        SessionPersistence.shared.markDirty()
    }

    /// Pause busy state observation on all sessions (during drag/resize)
    func pauseAllBusyObservers() {
        sessions.forEach { $0.pauseBusyObserver() }
    }

    /// Resume busy state observation on all sessions (after drag/resize)
    func resumeAllBusyObservers() {
        sessions.forEach { $0.resumeBusyObserver() }
    }

    /// Trigger visual bell with 3 flashes, each shorter than the last
    private func triggerVisualBell(for session: Session) {
        // Flash durations: 3 flashes at 375ms each
        // Gap between flashes: 100ms
        let flashDurations = [0.375, 0.375, 0.375]
        let gap = 0.1

        var delay = 0.0
        for (index, duration) in flashDurations.enumerated() {
            // Turn on
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                session.visualBellActive = true
            }
            delay += duration

            // Turn off
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                session.visualBellActive = false
            }

            // Add gap before next flash (except after last flash)
            if index < flashDurations.count - 1 {
                delay += gap
            }
        }
    }
}

// Handler for terminal process events
class TerminalProcessHandler: NSObject, LocalProcessTerminalViewDelegate {
    weak var session: Session?
    weak var sessionManager: SessionManager?

    init(session: Session, sessionManager: SessionManager) {
        self.session = session
        self.sessionManager = sessionManager
        NSLog("TerminalProcessHandler: Created for session %@", session.sessionRef)
    }

    func processTerminated(source: SwiftTerm.TerminalView, exitCode: Int32?) {
        NSLog("TerminalProcessHandler: processTerminated called! exitCode: %d", exitCode ?? -999)

        guard let session = session else {
            NSLog("TerminalProcessHandler: session is nil!")
            return
        }

        NSLog("TerminalProcessHandler: Notifying session %@ of exit", session.sessionRef)
        session.processDidExit(exitCode: exitCode ?? -1)

        // Notify SessionManager to update menu state
        sessionManager?.handleSessionExited(sessionId: session.id)

        NSLog("TerminalProcessHandler: Session marked as stopped, kept in sidebar")
    }

    func sizeChanged(source: SwiftTerm.LocalProcessTerminalView, newCols: Int, newRows: Int) {
        // Terminal size changed - handled automatically by SwiftTerm
    }

    func setTerminalTitle(source: SwiftTerm.LocalProcessTerminalView, title: String) {
        NSLog("TerminalProcessHandler: setTerminalTitle: %@", title)
    }

    func hostCurrentDirectoryUpdate (source: SwiftTerm.TerminalView, directory: String?) {
        NSLog("TerminalProcessHandler: hostCurrentDirectoryUpdate: %@", directory ?? "nil")
    }
}
