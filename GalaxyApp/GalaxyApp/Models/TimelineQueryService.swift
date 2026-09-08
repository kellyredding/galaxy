import Foundation
import Galactic

/// Fetches timeline events on demand by spawning galaxy-timeline CLI.
/// Follows the SnapshotQueryService pattern: Process with async/await
/// bridging, NSLock for thread safety, cancellation support.
class TimelineQueryService {
    static let shared = TimelineQueryService()

    /// Drift-detector queries fire every 30s per running session;
    /// the timeout is deliberately shorter so a wedged query is
    /// reclaimed before the next sweep and can never accumulate.
    private let runner = ProcessRunner(
        binaryPath: "\(NSHomeDirectory())/.claude/galaxy/bin/galaxy-timeline",
        defaultTimeout: 10
    )

    /// A second cancellation domain, for the stopped sessions' history
    /// panel. The runner above is single-flight — every query cancels
    /// the last — and the Timeline tab polls it every 5s, so a panel
    /// sharing it would trade kills with that poll and neither would
    /// reliably land. Same split, and the same reason, as
    /// ArtifactQueryService's independent runner.
    private let independentRunner = ProcessRunner(
        binaryPath: "\(NSHomeDirectory())/.claude/galaxy/bin/galaxy-timeline",
        defaultTimeout: 10
    )

    /// Custom date formatter for CLI output format "yyyy-MM-dd HH:mm:ss" in UTC.
    static let dateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt
    }()

    private init() {}

    // MARK: - Public API

    /// Cancel any in-flight CLI query.
    func cancelAll() {
        runner.cancelAll()
    }

    /// Fetch timeline events for a ledger session.
    func fetchEvents(ledgerSessionId: Int64) async throws -> [TimelineEvent] {
        let data = try await runCLI(
            args: ["list", "--json",
                   "--ledger-session-id", String(ledgerSessionId)]
        )
        return try Self.decodeEvents(data)
    }

    /// Fetch the most recent turn event for a session.
    /// Queries turn-ending events (completed, failed,
    /// interrupted, abandoned) plus turn:initiated as
    /// fallback. Returns nil if no turn events exist.
    func fetchMostRecentTurnEvent(
        ledgerSessionId: Int64
    ) async throws -> TimelineEvent? {
        let data = try await runCLI(
            args: Self.turnEventArgs(
                ledgerSessionId: ledgerSessionId, limit: 1
            )
        )
        return try Self.decodeEvents(data).first
    }

    /// Fetch recent turn events for display in the Ledger's
    /// Last Activity sub-tab. Returns both initiated and
    /// end events so the caller can pair them by
    /// durationIdentifier.
    ///
    /// Fetches the most recent `pairCount` completed turns
    /// by querying end events first, then their matching
    /// initiated events.
    func fetchRecentTurnEvents(
        ledgerSessionId: Int64,
        pairCount: Int = 5
    ) async throws -> [TimelineEvent] {
        let data = try await runCLI(
            args: Self.turnEventArgs(
                ledgerSessionId: ledgerSessionId,
                limit: pairCount * 3
            )
        )
        return try Self.decodeEvents(data)
    }

    /// Turn events for a stopped session's history panel — the same
    /// query as `fetchRecentTurnEvents`, on the independent runner so
    /// it neither cancels nor is cancelled by the Timeline tab's poll.
    ///
    /// Kept as its own method rather than a flag on the one above: the
    /// callers differ in cancellation semantics, not in query shape,
    /// and a Bool parameter would make every existing call site read as
    /// a choice it never makes.
    func fetchStoppedSessionTurnEvents(
        ledgerSessionId: Int64,
        pairCount: Int = 10
    ) async throws -> [TimelineEvent] {
        let data = try await runIndependentCLI(
            args: Self.turnEventArgs(
                ledgerSessionId: ledgerSessionId,
                limit: pairCount * 3
            )
        )
        return try Self.decodeEvents(data)
    }

    /// The newest turn event for a stopped session's collapsed summary
    /// row. One row, on the independent runner.
    func fetchStoppedSessionLatestTurn(
        ledgerSessionId: Int64
    ) async throws -> TimelineEvent? {
        let data = try await runIndependentCLI(
            args: Self.turnEventArgs(
                ledgerSessionId: ledgerSessionId, limit: 1
            )
        )
        return try Self.decodeEvents(data).first
    }

    // MARK: - Shared Query Shape

    /// Turn-ending events plus `turn:initiated`, newest first. The
    /// caller's limit needs headroom over the pair count it wants,
    /// since a pair costs two rows.
    private static func turnEventArgs(
        ledgerSessionId: Int64, limit: Int
    ) -> [String] {
        [
            "list", "--json",
            "--ledger-session-id", String(ledgerSessionId),
            "--event-type", turnEventTypes,
            "--reverse",
            "--limit", String(limit),
        ]
    }

    private static let turnEventTypes = [
        "turn:completed",
        "turn:failed",
        "turn:interrupted",
        "turn:abandoned",
        "turn:initiated",
    ].joined(separator: ",")

    private static func decodeEvents(
        _ data: Data
    ) throws -> [TimelineEvent] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .formatted(dateFormatter)
        return try decoder.decode(
            TimelineEventsResponse.self, from: data
        ).events
    }

    // MARK: - CLI Subprocess

    /// Spawn the galaxy-timeline binary and collect stdout. Cancels
    /// any previous in-flight query first (single-flight). The runner
    /// guarantees no thread is parked waiting on the child and bounds
    /// every query by a timeout.
    private func runCLI(args: [String]) async throws -> Data {
        runner.cancelAll()
        do {
            return try await runner.run(args: args)
        } catch {
            throw Self.mapError(error)
        }
    }

    /// Spawn on the independent runner, with no pre-emptive cancel:
    /// concurrent callers here are expected and safe, and the point of
    /// the second domain is that nothing else gets to kill them.
    private func runIndependentCLI(args: [String]) async throws -> Data {
        do {
            return try await independentRunner.run(args: args)
        } catch {
            throw Self.mapError(error)
        }
    }

    /// Translate the runner's generic error into this service's
    /// error type so callers see the familiar surface.
    private static func mapError(_ error: Error) -> Error {
        guard let error = error as? ProcessRunError else { return error }
        switch error {
        case .cliError(_, let status, let message):
            return TimelineQueryError.cliError(status: status, message: message)
        case .timedOut(_, let seconds):
            return TimelineQueryError.cliError(
                status: -1,
                message: "timed out after \(Int(seconds))s"
            )
        case .launchFailed(_, let underlying):
            return underlying
        }
    }
}

// MARK: - Error Type

enum TimelineQueryError: Error, LocalizedError {
    case cliError(status: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .cliError(let status, let message):
            return "galaxy-timeline exited with status \(status): \(message)"
        }
    }
}
