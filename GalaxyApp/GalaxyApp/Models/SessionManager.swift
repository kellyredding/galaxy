import Foundation
import AppKit
import SwiftTerm

class SessionManager: ObservableObject {
    // Singleton instance for access from AppDelegate
    static let shared = SessionManager()

    @Published var sessions: [Session] = []
    @Published var activeSessionId: UUID?

    // Track whether the main window is focused (for bell indicator logic)
    @Published var isWindowFocused: Bool = true

    // Track sidebar visibility (for View menu toggle)
    @Published var isSidebarVisible: Bool = true

    /// Called when a session is removed from the session list.
    /// Used by EventCoordinator to clean up cached ledger_session_id mappings.
    var onSessionClosed: ((UUID) -> Void)?

    // Track if active session can be resumed (for menu updates)
    @Published var activeSessionCanResume: Bool = false

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

        // Set up bell callback
        session.terminalView.onBell = { [weak session] in
            guard let session = session else { return }
            DispatchQueue.main.async {
                let preference = SettingsManager.shared.settings.bellPreference

                switch preference {
                case .visualBell:
                    // Trigger visual bell (3 flashes, each shorter)
                    self.triggerVisualBell(for: session)
                case .none:
                    // Do nothing
                    break
                default:
                    // Sound-based (system or custom)
                    SettingsManager.shared.handleBell()
                }

                // Always show unread indicator on bell (if setting is enabled)
                // SessionRow handles clearing it when session is selected + focused
                let showBadge = SettingsManager.shared.settings.showBellBadge
                if showBadge {
                    session.hasUnreadBell = true
                }
            }
        }

        // Set up data received callback for busy state detection
        session.terminalView.onDataReceived = { [weak session] in
            session?.markBusy()
        }

        // Determine if this is a resume (resumeSessionId provided means URL had resume param)
        let isResume = resumeSessionId != nil

        // Start the process
        session.startProcess(executablePath: executablePath, resume: isResume)

        sessions.append(session)
        activeSessionId = session.id

        return session
    }

    func handleSessionExited(sessionId: UUID) {
        NSLog("SessionManager: handleSessionExited called for %@", sessionId.uuidString)

        // Sessions are kept in sidebar when they exit (no removal)
        // The session's hasExited flag is already set by the process handler

        // Update menu state
        DispatchQueue.main.async {
            self.updateActiveSessionCanResume()
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

        // Check if Claude has this session saved on disk
        let canResume = claudeSessionExists(sessionId: session.claudeSessionId, workingDirectory: session.workingDirectory)

        if canResume {
            NSLog("SessionManager: Resuming session %@ (found in Claude storage)", session.sessionRef)
        } else {
            NSLog("SessionManager: Session %@ not found in Claude storage, starting fresh", session.sessionRef)
        }

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

        // Set up bell callback
        session.terminalView.onBell = { [weak session] in
            guard let session = session else { return }
            DispatchQueue.main.async {
                let preference = SettingsManager.shared.settings.bellPreference

                switch preference {
                case .visualBell:
                    // Trigger visual bell (3 flashes, each shorter)
                    self.triggerVisualBell(for: session)
                case .none:
                    // Do nothing
                    break
                default:
                    // Sound-based (system or custom)
                    SettingsManager.shared.handleBell()
                }

                // Always show unread indicator on bell (if setting is enabled)
                // SessionRow handles clearing it when session is selected + focused
                let showBadge = SettingsManager.shared.settings.showBellBadge
                if showBadge {
                    session.hasUnreadBell = true
                }
            }
        }

        // Set up data received callback for busy state detection
        session.terminalView.onDataReceived = { [weak session] in
            session?.markBusy()
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

        // Update menu state (session is now running, not resumable)
        updateActiveSessionCanResume()
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
        if sessions.contains(where: { $0.id == sessionId }) {
            activeSessionId = sessionId
            // Note: SessionRow handles clearing hasUnreadBell with fade animation

            // Update menu state for the newly active session
            updateActiveSessionCanResume()
        }
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

        // Remove the session (this will deallocate the terminal view which kills the process)
        sessions.remove(at: index)

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

    /// Swap two sessions in the array (used during drag-to-reorder)
    func swapSessions(_ indexA: Int, _ indexB: Int) {
        guard indexA >= 0 && indexA < sessions.count else { return }
        guard indexB >= 0 && indexB < sessions.count else { return }
        sessions.swapAt(indexA, indexB)
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
