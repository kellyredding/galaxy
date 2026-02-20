import Foundation
import Combine

/// Service that periodically fetches git status for sessions
class StatusLineService: ObservableObject {
    static let shared = StatusLineService()

    // Published status info keyed by session ID
    @Published var statusInfo: [UUID: SessionStatusInfo] = [:]

    // Pause publishing during drag operations for performance
    private var isPaused: Bool = false
    private var pendingStatusInfo: [UUID: SessionStatusInfo]?

    private var timer: Timer?
    private let updateInterval: TimeInterval = 5.0  // 5 seconds

    struct SessionStatusInfo {
        let gitBranch: String?
        let isDirty: Bool
        let hasStaged: Bool
        let aheadCount: Int
        let behindCount: Int

        var gitStatusDisplay: String {
            guard let branch = gitBranch else { return "" }

            var display = branch

            // Add dirty/staged indicators
            var indicators = ""
            if isDirty { indicators += "*" }
            if hasStaged { indicators += "+" }

            // Add ahead/behind counts
            if aheadCount > 0 || behindCount > 0 {
                if behindCount > 0 { indicators += "↓\(behindCount)" }
                if aheadCount > 0 { indicators += "↑\(aheadCount)" }
            }

            if !indicators.isEmpty {
                display += indicators
            }

            return "[\(display)]"
        }
    }

    private init() {}

    func startMonitoring(sessions: [Session]) {
        // Stop existing timer
        stopMonitoring()

        // Initial update
        updateAllSessions(sessions)

        // Schedule periodic updates
        timer = Timer.scheduledTimer(withTimeInterval: updateInterval, repeats: true) { [weak self] _ in
            self?.updateAllSessions(sessions)
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    /// Pause publishing updates during drag operations for performance
    func pauseUpdates() {
        isPaused = true
    }

    /// Resume publishing updates after drag operations complete
    func resumeUpdates() {
        isPaused = false
        // Apply any pending updates
        if let pending = pendingStatusInfo {
            statusInfo = pending
            pendingStatusInfo = nil
        }
    }

    func updateAllSessions(_ sessions: [Session]) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var newStatusInfo: [UUID: SessionStatusInfo] = [:]

            for session in sessions {
                let info = self?.fetchGitStatus(for: session.workingDirectory)
                newStatusInfo[session.id] = info
            }

            DispatchQueue.main.async {
                guard let self = self else { return }
                if self.isPaused {
                    // Store for later when resumed
                    self.pendingStatusInfo = newStatusInfo
                } else {
                    self.statusInfo = newStatusInfo
                }
            }
        }
    }

    private func fetchGitStatus(for directory: String) -> SessionStatusInfo {
        // Get branch name
        let branch = runGitCommand(["rev-parse", "--abbrev-ref", "HEAD"], in: directory)

        // Get porcelain status for dirty/staged detection
        let porcelainStatus = runGitCommand(["status", "--porcelain"], in: directory)
        let statusLines = porcelainStatus?.components(separatedBy: "\n").filter { !$0.isEmpty } ?? []

        var isDirty = false
        var hasStaged = false

        for line in statusLines {
            if line.count >= 2 {
                let index = line.index(line.startIndex, offsetBy: 0)
                let workTree = line.index(line.startIndex, offsetBy: 1)
                let indexStatus = line[index]
                let workTreeStatus = line[workTree]

                // Staged changes (index has status)
                if indexStatus != " " && indexStatus != "?" {
                    hasStaged = true
                }

                // Unstaged changes (work tree has status)
                if workTreeStatus != " " && workTreeStatus != "?" {
                    isDirty = true
                }

                // Untracked files count as dirty
                if indexStatus == "?" {
                    isDirty = true
                }
            }
        }

        // Get ahead/behind counts
        var aheadCount = 0
        var behindCount = 0

        if let revList = runGitCommand(["rev-list", "--left-right", "--count", "@{upstream}...HEAD"], in: directory) {
            let counts = revList.components(separatedBy: CharacterSet.whitespaces).compactMap { Int($0) }
            if counts.count == 2 {
                behindCount = counts[0]
                aheadCount = counts[1]
            }
        }

        return SessionStatusInfo(
            gitBranch: branch?.trimmingCharacters(in: .whitespacesAndNewlines),
            isDirty: isDirty,
            hasStaged: hasStaged,
            aheadCount: aheadCount,
            behindCount: behindCount
        )
    }

    private func runGitCommand(_ args: [String], in directory: String) -> String? {
        let task = Process()
        let pipe = Pipe()

        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.arguments = args
        task.currentDirectoryURL = URL(fileURLWithPath: directory)
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()

            if task.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                return String(data: data, encoding: .utf8)
            }
        } catch {
            // Git command failed - likely not a git repo
        }

        return nil
    }
}
