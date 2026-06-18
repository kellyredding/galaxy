import Foundation
import Combine

/// Service that fetches git status for sessions on demand.
/// Triggered by EventCoordinator after enrichment completes — no polling timer.
class StatusLineService: ObservableObject {
    static let shared = StatusLineService()

    // Published status info keyed by session ID
    @Published var statusInfo: [UUID: SessionStatusInfo] = [:]

    // Pause publishing during drag operations for performance
    private var isPaused: Bool = false
    private var pendingStatusInfo: [UUID: SessionStatusInfo]?

    struct SessionStatusInfo: Equatable {
        let gitBranch: String?
        let isDirty: Bool
        let hasStaged: Bool
        let hasStashed: Bool
        let aheadCount: Int
        let behindCount: Int
    }

    private init() {}

    /// Refresh git status for all sessions. Called by ExpandedSessionSidebar
    /// on appear and session count changes.
    func refreshSessions(_ sessions: [Session]) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var newStatusInfo: [UUID: SessionStatusInfo] = [:]

            for session in sessions {
                let info = self?.fetchGitStatus(for: session.ledgerCwd ?? session.workingDirectory)
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

    /// Refresh git status for a single session. Called by
    /// EventCoordinator after enrichment completes — only the
    /// session that matched the event gets refreshed.
    func refreshSession(_ session: Session) {
        let sessionId = session.id
        let directory = session.ledgerCwd ?? session.workingDirectory

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let info = self?.fetchGitStatus(for: directory)

            DispatchQueue.main.async {
                guard let self = self else { return }
                if self.isPaused {
                    self.pendingStatusInfo = self.pendingStatusInfo ?? self.statusInfo
                    self.pendingStatusInfo?[sessionId] = info
                } else {
                    self.statusInfo[sessionId] = info
                }
            }
        }
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

        // Check for stashed changes (matches statusline: git rev-parse --verify refs/stash)
        let hasStashed = runGitCommand(["rev-parse", "--verify", "refs/stash"], in: directory) != nil

        // Get ahead/behind counts
        var aheadCount = 0
        var behindCount = 0

        if let revList = runGitCommand(["rev-list", "--left-right", "--count", "@{upstream}...HEAD"], in: directory) {
            let counts = revList.components(separatedBy: CharacterSet.whitespacesAndNewlines).compactMap { Int($0) }
            if counts.count == 2 {
                behindCount = counts[0]
                aheadCount = counts[1]
            }
        }

        return SessionStatusInfo(
            gitBranch: branch?.trimmingCharacters(in: .whitespacesAndNewlines),
            isDirty: isDirty,
            hasStaged: hasStaged,
            hasStashed: hasStashed,
            aheadCount: aheadCount,
            behindCount: behindCount
        )
    }

    private func runGitCommand(_ args: [String], in directory: String) -> String? {
        // Bounded so a slow or locked repo can't block statusline
        // rendering indefinitely. A non-zero exit (e.g. not a git repo)
        // or timeout throws and falls through to nil, matching the
        // previous behavior.
        guard let data = try? ProcessRunner.runSync(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: args,
            currentDirectory: URL(fileURLWithPath: directory),
            timeout: 5
        ) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
