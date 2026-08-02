import Foundation
import Galactic

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
        var args = ["sessions", "--json"]
        for id in sessionIdentifiers {
            args.append("--session")
            args.append(id)
        }

        // The runner bounds the call with `timeout`, drains the pipes
        // without parking a thread, and reports back on a background
        // queue — so this no longer manages its own timeout/wait.
        let startTime = CFAbsoluteTimeGetCurrent()
        ProcessRunner.run(
            executableURL: URL(fileURLWithPath: ledgerPath),
            arguments: args,
            timeout: timeout
        ) { [weak self] result in
            guard let self = self else { return }
            let duration = CFAbsoluteTimeGetCurrent() - startTime

            switch result {
            case .success(let data):
                do {
                    let response = try JSONDecoder().decode(
                        EnrichmentResponse.self, from: data
                    )
                    self.circuitBreaker.recordSuccess()
                    GalaxyLog.enrichment(
                        "Success in \(String(format: "%.1f", duration * 1000))ms"
                        + " — \(response.sessions.count) session(s)"
                    )
                    DispatchQueue.main.async { completion(response) }
                } catch {
                    GalaxyLog.enrichment(
                        "JSON parse failed: \(error.localizedDescription)"
                    )
                    self.circuitBreaker.recordFailure()
                    DispatchQueue.main.async { completion(nil) }
                }
            case .failure(let error):
                // Covers timeout, non-zero exit (status + stderr are in
                // the error message), and launch failure.
                GalaxyLog.enrichment(
                    "Subprocess failed in"
                    + " \(String(format: "%.1f", duration * 1000))ms:"
                    + " \(error.localizedDescription)"
                )
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
                    self.executeEnrichment(
                        sessionIdentifiers: next.sessionIdentifiers,
                        completion: next.completion
                    )
                }
            }
        }
    }

    /// Synchronous enrichment call for startup sync.
    /// Blocks the calling thread. Do NOT call from the main queue.
    func enrichSync(sessionIdentifiers: [String]) -> EnrichmentResponse? {
        guard !sessionIdentifiers.isEmpty else { return nil }

        var args = ["sessions", "--json"]
        for id in sessionIdentifiers {
            args.append("--session")
            args.append(id)
        }

        // Bounded by the service timeout so a wedged ledger call can't
        // block startup sync forever. Non-zero exit / timeout throws
        // and falls through to nil.
        guard let data = try? ProcessRunner.runSync(
            executableURL: URL(fileURLWithPath: ledgerPath),
            arguments: args,
            timeout: timeout
        ) else {
            return nil
        }
        return try? JSONDecoder().decode(EnrichmentResponse.self, from: data)
    }
}
