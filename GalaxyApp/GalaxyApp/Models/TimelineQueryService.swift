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
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .formatted(Self.dateFormatter)
        let response = try decoder.decode(TimelineEventsResponse.self, from: data)
        return response.events
    }

    /// Fetch the most recent turn event for a session.
    /// Queries turn-ending events (completed, failed,
    /// interrupted, abandoned) plus turn:initiated as
    /// fallback. Returns nil if no turn events exist.
    func fetchMostRecentTurnEvent(
        ledgerSessionId: Int64
    ) async throws -> TimelineEvent? {
        let eventTypes = [
            "turn:completed",
            "turn:failed",
            "turn:interrupted",
            "turn:abandoned",
            "turn:initiated",
        ].joined(separator: ",")

        let data = try await runCLI(
            args: [
                "list", "--json",
                "--ledger-session-id",
                String(ledgerSessionId),
                "--event-type", eventTypes,
                "--reverse",
                "--limit", "1",
            ]
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .formatted(
            Self.dateFormatter
        )
        let response = try decoder.decode(
            TimelineEventsResponse.self, from: data
        )
        return response.events.first
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
        // Fetch end events (completed, failed, interrupted,
        // abandoned) plus initiated, reversed, with enough
        // headroom to cover pairCount complete pairs.
        let eventTypes = [
            "turn:completed",
            "turn:failed",
            "turn:interrupted",
            "turn:abandoned",
            "turn:initiated",
        ].joined(separator: ",")

        let data = try await runCLI(
            args: [
                "list", "--json",
                "--ledger-session-id",
                String(ledgerSessionId),
                "--event-type", eventTypes,
                "--reverse",
                "--limit", String(pairCount * 3),
            ]
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy =
            .convertFromSnakeCase
        decoder.dateDecodingStrategy =
            .formatted(Self.dateFormatter)
        let response = try decoder.decode(
            TimelineEventsResponse.self, from: data
        )
        return response.events
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
