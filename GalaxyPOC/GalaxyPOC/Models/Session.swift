import Foundation
import AppKit
import SwiftTerm

class Session: Identifiable, ObservableObject {
    let id: UUID
    @Published var name: String
    @Published var isRunning: Bool = false
    @Published var hasExited: Bool = false
    @Published var exitCode: Int32?

    let terminalView: LocalProcessTerminalView
    let createdAt: Date
    let workingDirectory: String

    private static var sessionCounter = 0

    // Keep a strong reference to the process handler so it doesn't get deallocated
    var processHandler: TerminalProcessHandler?

    init(workingDirectory: String) {
        self.id = UUID()
        self.createdAt = Date()
        self.workingDirectory = workingDirectory

        // Generate session name from directory
        Session.sessionCounter += 1
        let dirName = (workingDirectory as NSString).lastPathComponent
        self.name = dirName.isEmpty ? "Session \(Session.sessionCounter)" : dirName

        // Create terminal view with default configuration
        self.terminalView = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        configureTerminal()
    }

    private func configureTerminal() {
        // Configure terminal appearance
        let terminal = terminalView.getTerminal()

        // Set colors - dark theme
        terminalView.nativeForegroundColor = NSColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1.0)
        terminalView.nativeBackgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0)

        // Set font
        if let font = NSFont(name: "SF Mono", size: 13) ?? NSFont(name: "Menlo", size: 13) {
            terminalView.font = font
        }
    }

    func startProcess(claudePath: String) {
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

        // Start claude directly (not via shell) so SwiftTerm can properly monitor the process
        terminalView.startProcess(
            executable: claudePath,
            args: [],
            environment: envArray,
            execName: "claude"
        )

        isRunning = true
        NSLog("Session: Started process for %@ in %@", name, workingDirectory)
    }

    func processDidExit(exitCode: Int32) {
        DispatchQueue.main.async {
            self.isRunning = false
            self.hasExited = true
            self.exitCode = exitCode
        }
    }
}
