import Foundation
import AppKit
import SwiftTerm

class Session: Identifiable, ObservableObject {
    /// UUID used for SwiftUI Identifiable AND as Claude's session ID
    let id: UUID

    /// Human-readable session identifier for display (e.g., "rich-grass-hides")
    let userSessionId: String
    @Published var name: String
    @Published var isRunning: Bool = false
    @Published var hasExited: Bool = false
    @Published var exitCode: Int32?

    let terminalView: LocalProcessTerminalView
    let createdAt: Date
    let workingDirectory: String

    // Keep a strong reference to the process handler so it doesn't get deallocated
    var processHandler: TerminalProcessHandler?

    // Track the child process PID for termination (SwiftTerm doesn't expose this)
    private var childPid: pid_t = 0

    init(workingDirectory: String, userSessionId: String) {
        self.id = UUID()
        self.userSessionId = userSessionId
        self.createdAt = Date()
        self.workingDirectory = workingDirectory

        // Use directory basename as display name
        let dirName = (workingDirectory as NSString).lastPathComponent
        self.name = dirName.isEmpty ? "~" : dirName

        // Create terminal view with default configuration
        self.terminalView = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        configureTerminal()
    }

    private func configureTerminal() {
        // Set font
        if let font = NSFont(name: "SF Mono", size: 13) ?? NSFont(name: "Menlo", size: 13) {
            terminalView.font = font
        }

        // Terminal colors are controlled by Claude Code's own settings
        // We don't override them here - let Claude Code manage its appearance
    }

    /// Claude's session ID (UUID string) for --session-id / --resume flags
    var claudeSessionId: String {
        id.uuidString.lowercased()
    }

    /// Returns the CLI command to resume this session
    var resumeCommand: String {
        return "cd \(workingDirectory) && claude --resume \(claudeSessionId)"
    }

    func startProcess(claudePath: String, resume: Bool = false) {
        // Build environment as array of "KEY=VALUE" strings (SwiftTerm 1.2.5 format)
        var envArray: [String] = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }

        // Override terminal-related environment variables
        envArray = envArray.filter {
            !$0.hasPrefix("TERM=") &&
            !$0.hasPrefix("COLORTERM=") &&
            !$0.hasPrefix("LANG=")
        }
        envArray.append("TERM=xterm-256color")
        envArray.append("COLORTERM=truecolor")
        envArray.append("LANG=en_US.UTF-8")

        // Change to working directory first
        FileManager.default.changeCurrentDirectoryPath(workingDirectory)

        // Build args
        var args: [String] = []

        if resume {
            // Resume this specific Claude session by its UUID
            args.append("--resume")
            args.append(claudeSessionId)
            NSLog("Session: Resuming Claude session %@ in %@", claudeSessionId, workingDirectory)
        } else {
            // Start new Claude session with our UUID so we can resume it later
            args.append("--session-id")
            args.append(claudeSessionId)
            NSLog("Session: Starting new Claude session with ID %@", claudeSessionId)
        }

        // Start claude directly (not via shell) so SwiftTerm can properly monitor the process
        terminalView.startProcess(
            executable: claudePath,
            args: args,
            environment: envArray,
            execName: "claude"
        )

        isRunning = true
        NSLog("Session: Started process for %@ in %@", name, workingDirectory)

        // Capture the child PID after a short delay to allow fork to complete
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.captureChildPid()
        }
    }

    func processDidExit(exitCode: Int32) {
        DispatchQueue.main.async {
            self.isRunning = false
            self.hasExited = true
            self.exitCode = exitCode
            self.childPid = 0
        }
    }

    /// Terminate the child process gracefully
    /// Tries SIGHUP first (terminal hangup), falls back to SIGTERM if needed
    func terminateProcess() {
        guard childPid > 0 else {
            NSLog("Session: Cannot terminate - no child PID tracked")
            return
        }

        let pid = childPid

        // First try SIGHUP (graceful terminal hangup)
        NSLog("Session: Sending SIGHUP to PID %d", pid)
        kill(pid, SIGHUP)

        // Check after a short delay if process is still running
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5) {
            // kill with signal 0 just checks if process exists
            if kill(pid, 0) == 0 {
                // Process still running, escalate to SIGTERM
                NSLog("Session: Process %d still running after SIGHUP, sending SIGTERM", pid)
                kill(pid, SIGTERM)
            } else {
                NSLog("Session: Process %d terminated after SIGHUP", pid)
            }
        }
    }

    /// Find the claude child process that belongs to this session
    /// Called shortly after startProcess() to capture the PID
    func captureChildPid() {
        let task = Process()
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        // -P: parent PID, -n: newest match, -x: exact name match
        task.arguments = ["-P", String(getpid()), "-n", "-x", "claude"]

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               let pid = Int32(output), pid > 0 {
                self.childPid = pid
                NSLog("Session: Captured child PID %d for %@", pid, name)
            } else {
                NSLog("Session: Could not find child PID for %@", name)
            }
        } catch {
            NSLog("Session: Error running pgrep: %@", error.localizedDescription)
        }
    }
}
