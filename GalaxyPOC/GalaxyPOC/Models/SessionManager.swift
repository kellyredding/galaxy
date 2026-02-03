import Foundation
import AppKit
import SwiftTerm
import Combine

class SessionManager: ObservableObject {
    // Singleton instance for access from AppDelegate
    static let shared = SessionManager()

    @Published var sessions: [Session] = []
    @Published var activeSessionId: UUID?

    // Path to claude binary - detected at init
    let claudePath: String

    // Track subscriptions for session exit observation
    private var exitObservers: [UUID: AnyCancellable] = [:]

    var activeSession: Session? {
        sessions.first { $0.id == activeSessionId }
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

        // Clean up the observer (no longer needed)
        exitObservers.removeValue(forKey: sessionId)

        // Force UI update by notifying observers
        DispatchQueue.main.async {
            self.objectWillChange.send()
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

        NSLog("SessionManager: Resuming session %@", session.userSessionId)

        // Reset session state
        session.hasExited = false
        session.exitCode = nil
        session.isRunning = false

        // Re-attach process handler
        let handler = TerminalProcessHandler(session: session, sessionManager: self)
        session.processHandler = handler
        session.terminalView.processDelegate = handler

        // Start claude with resume flag
        session.startProcess(claudePath: claudePath, resume: true)

        // Make this the active session
        activeSessionId = session.id
    }

    func switchTo(sessionId: UUID) {
        if sessions.contains(where: { $0.id == sessionId }) {
            activeSessionId = sessionId
        }
    }

    func closeSession(sessionId: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else { return }

        NSLog("SessionManager: closeSession called for session %@", sessionId.uuidString)

        // Clean up the observer
        exitObservers.removeValue(forKey: sessionId)

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

    func switchToSessionByIndex(_ index: Int) {
        if index >= 0 && index < sessions.count {
            activeSessionId = sessions[index].id
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

        // Session stays in sidebar - no removal, just state update
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
