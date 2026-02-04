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

    // Track if active session can be resumed (for menu updates)
    @Published var activeSessionCanResume: Bool = false

    // Path to claude binary - detected at init
    let claudePath: String

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
        // Detect claude path
        self.claudePath = SessionManager.findClaudePath()
    }

    private static func findClaudePath() -> String {
        // Check common locations
        let possiblePaths = [
            "\(NSHomeDirectory())/.local/bin/claude",
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude"
        ]

        for path in possiblePaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Fallback - try to find via which command
        let task = Process()
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = ["claude"]

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

        // Return default path
        return "\(NSHomeDirectory())/.local/bin/claude"
    }

    @discardableResult
    func createSession(workingDirectory: String? = nil) -> Session {
        let directory = workingDirectory ?? NSHomeDirectory()
        let sessionId = SessionIDGenerator.generate()
        let session = Session(workingDirectory: directory, userSessionId: sessionId)

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

        // Start the claude process
        session.startProcess(claudePath: claudePath)

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

        NSLog("SessionManager: Stopping session %@", session.userSessionId)

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
            NSLog("SessionManager: Resuming session %@ (found in Claude storage)", session.userSessionId)
        } else {
            NSLog("SessionManager: Session %@ not found in Claude storage, starting fresh", session.userSessionId)
        }

        // Reset session state
        session.hasExited = false
        session.exitCode = nil
        session.isRunning = false

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

        // Start claude: --resume if session exists in Claude storage, --session-id if not
        session.startProcess(claudePath: claudePath, resume: canResume)

        // Make this the active session
        activeSessionId = session.id

        // Update menu state (session is now running, not resumable)
        updateActiveSessionCanResume()
    }

    /// Check if Claude has a session saved on disk for the given session ID and working directory
    private func claudeSessionExists(sessionId: String, workingDirectory: String) -> Bool {
        // Claude stores sessions in ~/.claude/projects/<escaped-path>/sessions-index.json
        // Path escaping: /Users/foo/bar becomes -Users-foo-bar
        let escapedPath = workingDirectory.replacingOccurrences(of: "/", with: "-")
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
            .appendingPathComponent(escapedPath)
        let indexFile = claudeDir.appendingPathComponent("sessions-index.json")

        guard FileManager.default.fileExists(atPath: indexFile.path) else {
            NSLog("SessionManager: Claude sessions index not found at %@", indexFile.path)
            return false
        }

        do {
            let data = try Data(contentsOf: indexFile)
            // Quick string search - faster than full JSON parse for this check
            let content = String(data: data, encoding: .utf8) ?? ""
            let exists = content.contains(sessionId)
            NSLog("SessionManager: Session %@ %@ in Claude storage", sessionId, exists ? "found" : "not found")
            return exists
        } catch {
            NSLog("SessionManager: Error reading Claude sessions index: %@", error.localizedDescription)
            return false
        }
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

        // Remove the session (this will deallocate the terminal view which kills the process)
        sessions.remove(at: index)

        // Update active session
        if activeSessionId == sessionId {
            activeSessionId = nextActiveId
        }

        NSLog("SessionManager: Session removed, remaining count: %d", sessions.count)
    }

    /// Switch to the previous session in the list (wraps around)
    func switchToPreviousSession() {
        guard sessions.count > 1 else { return }
        guard let currentId = activeSessionId,
              let currentIndex = sessions.firstIndex(where: { $0.id == currentId }) else { return }

        let previousIndex = currentIndex > 0 ? currentIndex - 1 : sessions.count - 1
        switchTo(sessionId: sessions[previousIndex].id)
    }

    /// Switch to the next session in the list (wraps around)
    func switchToNextSession() {
        guard sessions.count > 1 else { return }
        guard let currentId = activeSessionId,
              let currentIndex = sessions.firstIndex(where: { $0.id == currentId }) else { return }

        let nextIndex = currentIndex < sessions.count - 1 ? currentIndex + 1 : 0
        switchTo(sessionId: sessions[nextIndex].id)
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
        NSLog("TerminalProcessHandler: Created for session %@", session.name)
    }

    func processTerminated(source: SwiftTerm.TerminalView, exitCode: Int32?) {
        NSLog("TerminalProcessHandler: processTerminated called! exitCode: %d", exitCode ?? -999)

        guard let session = session else {
            NSLog("TerminalProcessHandler: session is nil!")
            return
        }

        NSLog("TerminalProcessHandler: Notifying session %@ of exit", session.name)
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
