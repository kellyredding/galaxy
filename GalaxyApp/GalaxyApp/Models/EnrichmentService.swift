import Foundation

/// Calls `galaxy-ledger sessions --json` to enrich events with fresh session data.
///
/// Manages subprocess concurrency (max 4 concurrent), timeout (10 seconds),
/// and circuit breaker integration. All enrichment flows through this service.
final class EnrichmentService {
    /// Path to the galaxy-ledger binary
    private let ledgerPath: String

    /// Maximum concurrent subprocess calls
    private let maxConcurrent: Int

    /// Subprocess timeout
    private let timeout: TimeInterval

    /// Circuit breaker to prevent runaway spawning
    let circuitBreaker: CircuitBreaker

    /// Current number of in-flight subprocesses
    private var inFlightCount: Int = 0

    /// Queue of pending enrichment requests (when at max concurrency)
    private var pendingQueue: [(sessionIdentifiers: [String], completion: (EnrichmentResponse?) -> Void)] = []

    /// Serial queue for concurrency bookkeeping
    private let bookkeepingQueue = DispatchQueue(label: "com.kellyredding.galaxy.enrichment-bookkeeping")

    /// Parsed response from `galaxy-ledger sessions --json`
    struct EnrichmentResponse: Codable {
        let sessions: [SessionData]
    }

    /// Individual session data from enrichment API
    struct SessionData: Codable {
        let ledgerSessionId: Int64
        let sessionIdentifiers: [String]
        let currentSessionIdentifier: String?
        let claudePids: [Int]?
        let currentClaudePid: Int?
        let cwd: String?
        let projectDir: String?
        let gitBranch: String?
        let modelId: String?
        let modelDisplayName: String?
        let claudeVersion: String?
        let contextPercentage: Double?
        let tokensUsed: Int?
        let tokensMax: Int?
        let costUsd: Double?
        let linesAdded: Int?
        let linesRemoved: Int?
        let startedAt: String?
        let updatedAt: String?
        let suggestedName: String?
        let suggestedNameData: String?

        enum CodingKeys: String, CodingKey {
            case ledgerSessionId = "ledger_session_id"
            case sessionIdentifiers = "session_identifiers"
            case currentSessionIdentifier = "current_session_identifier"
            case claudePids = "claude_pids"
            case currentClaudePid = "current_claude_pid"
            case cwd
            case projectDir = "project_dir"
            case gitBranch = "git_branch"
            case modelId = "model_id"
            case modelDisplayName = "model_display_name"
            case claudeVersion = "claude_version"
            case contextPercentage = "context_percentage"
            case tokensUsed = "tokens_used"
            case tokensMax = "tokens_max"
            case costUsd = "cost_usd"
            case linesAdded = "lines_added"
            case linesRemoved = "lines_removed"
            case startedAt = "started_at"
            case updatedAt = "updated_at"
            case suggestedName = "suggested_name"
            case suggestedNameData = "suggested_name_data"
        }
    }

    init(
        ledgerPath: String? = nil,
        maxConcurrent: Int = 4,
        timeout: TimeInterval = 10.0
    ) {
        self.ledgerPath = ledgerPath ?? EnrichmentService.findLedgerPath()
        self.maxConcurrent = maxConcurrent
        self.timeout = timeout
        self.circuitBreaker = CircuitBreaker()
    }

    /// Find the galaxy-ledger binary path
    private static func findLedgerPath() -> String {
        let searchPaths = [
            NSHomeDirectory() + "/.claude/galaxy/bin/galaxy-ledger",
            NSHomeDirectory() + "/.local/bin/galaxy-ledger",
            "/usr/local/bin/galaxy-ledger",
        ]
        for path in searchPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        // Fallback
        return NSHomeDirectory() + "/.claude/galaxy/bin/galaxy-ledger"
    }

    /// Enrich session data by calling `galaxy-ledger sessions --json`.
    ///
    /// - Parameters:
    ///   - sessionIdentifiers: Claude session UUIDs to query
    ///   - completion: Called on the main queue with parsed response, or nil on failure
    func enrich(sessionIdentifiers: [String], completion: @escaping (EnrichmentResponse?) -> Void) {
        guard !sessionIdentifiers.isEmpty else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        // Check circuit breaker
        guard circuitBreaker.shouldAllow else {
            GalaxyLog.enrichment("Call blocked by circuit breaker (state=open)")
            DispatchQueue.main.async { completion(nil) }
            return
        }

        bookkeepingQueue.async { [weak self] in
            guard let self = self else { return }

            if self.inFlightCount >= self.maxConcurrent {
                self.pendingQueue.append((sessionIdentifiers: sessionIdentifiers, completion: completion))
                return
            }

            self.inFlightCount += 1
            self.executeEnrichment(sessionIdentifiers: sessionIdentifiers, completion: completion)
        }
    }

    /// Execute the actual subprocess call
    private func executeEnrichment(sessionIdentifiers: [String], completion: @escaping (EnrichmentResponse?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let task = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            task.executableURL = URL(fileURLWithPath: self.ledgerPath)
            var args = ["sessions", "--json"]
            for id in sessionIdentifiers {
                args.append("--session")
                args.append(id)
            }
            task.arguments = args
            task.standardOutput = stdoutPipe
            task.standardError = stderrPipe

            // Timeout: terminate after self.timeout seconds
            let timeoutWorkItem = DispatchWorkItem { [weak self] in
                if task.isRunning {
                    GalaxyLog.enrichment("Subprocess timed out after \(self?.timeout ?? 0)s")
                    task.terminate()
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + self.timeout, execute: timeoutWorkItem)

            let startTime = CFAbsoluteTimeGetCurrent()
            do {
                try task.run()

                // Read stdout BEFORE waitUntilExit to avoid pipe deadlock.
                // If the subprocess writes more than ~64KB, the pipe buffer
                // fills and the process blocks on write. waitUntilExit would
                // then block forever waiting for a process that can't exit.
                let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                timeoutWorkItem.cancel()
                let duration = CFAbsoluteTimeGetCurrent() - startTime

                if task.terminationStatus == 0 {

                    do {
                        let response = try JSONDecoder().decode(EnrichmentResponse.self, from: data)
                        self.circuitBreaker.recordSuccess()
                        GalaxyLog.enrichment("Success in \(String(format: "%.1f", duration * 1000))ms — \(response.sessions.count) session(s)")
                        DispatchQueue.main.async { completion(response) }
                    } catch {
                        GalaxyLog.enrichment("JSON parse failed: \(error.localizedDescription)")
                        self.circuitBreaker.recordFailure()
                        DispatchQueue.main.async { completion(nil) }
                    }
                } else {
                    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderrStr = String(data: stderrData, encoding: .utf8) ?? ""
                    GalaxyLog.enrichment("Subprocess exited \(task.terminationStatus) in \(String(format: "%.1f", duration * 1000))ms — stderr: \(String(stderrStr.prefix(300)))")
                    self.circuitBreaker.recordFailure()
                    DispatchQueue.main.async { completion(nil) }
                }
            } catch {
                timeoutWorkItem.cancel()
                GalaxyLog.enrichment("Failed to launch subprocess: \(error.localizedDescription)")
                self.circuitBreaker.recordFailure()
                DispatchQueue.main.async { completion(nil) }
            }

            // Bookkeeping: decrement in-flight, drain pending queue
            self.bookkeepingQueue.async { [weak self] in
                guard let self = self else { return }
                self.inFlightCount -= 1

                if let next = self.pendingQueue.first {
                    self.pendingQueue.removeFirst()
                    self.inFlightCount += 1
                    self.executeEnrichment(sessionIdentifiers: next.sessionIdentifiers, completion: next.completion)
                }
            }
        }
    }

    /// Synchronous enrichment call for startup sync.
    /// Blocks the calling thread. Do NOT call from the main queue.
    func enrichSync(sessionIdentifiers: [String]) -> EnrichmentResponse? {
        guard !sessionIdentifiers.isEmpty else { return nil }

        let task = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        task.executableURL = URL(fileURLWithPath: ledgerPath)
        var args = ["sessions", "--json"]
        for id in sessionIdentifiers {
            args.append("--session")
            args.append(id)
        }
        task.arguments = args
        task.standardOutput = stdoutPipe
        task.standardError = stderrPipe

        do {
            try task.run()

            // Read stdout BEFORE waitUntilExit to avoid pipe deadlock.
            // If the subprocess writes more than ~64KB, the pipe buffer
            // fills and the process blocks on write. waitUntilExit would
            // then block forever waiting for a process that can't exit.
            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()

            guard task.terminationStatus == 0 else {
                return nil
            }

            return try JSONDecoder().decode(EnrichmentResponse.self, from: data)
        } catch {
            return nil
        }
    }
}
