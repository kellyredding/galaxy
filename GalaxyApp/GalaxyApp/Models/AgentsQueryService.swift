import Foundation
import Galactic

/// Fetches agent data on demand by spawning galaxy-agents CLI.
/// Follows the same pattern as SnapshotQueryService — independent
/// cancellation domain, process management, and JSON decoding.
class AgentsQueryService {
    static let shared = AgentsQueryService()

    private static let binaryPath =
        "\(NSHomeDirectory())/.claude/galaxy/bin/galaxy-agents"

    /// One read cancellation domain per session, plus a separate
    /// mutation lane.
    ///
    /// Reads are single-flight *within* a session: a newer answer
    /// about a session supersedes the older one, so killing the
    /// stale query is right. Reads about *different* sessions are
    /// not substitutes for one another — the startup seed asks one
    /// question per session, and an answer about one says nothing
    /// about another. A single shared read runner made every query
    /// cancel every other query regardless of subject, so whichever
    /// sessions were asked about first could lose their answers and
    /// never be asked again.
    ///
    /// Keyed by ledger session id and never pruned: a runner is a
    /// lock and an empty dictionary, and the key space is bounded by
    /// how many sessions the app has seen.
    private var readRunners: [Int64: ProcessRunner] = [:]
    private let readRunnersLock = NSLock()

    private let mutationRunner = ProcessRunner(
        binaryPath: AgentsQueryService.binaryPath,
        defaultTimeout: 5
    )

    private init() {}

    // MARK: - Public API

    /// Cancel every in-flight read query, across all sessions.
    /// In-flight mutations (runMutationCLI) are intentionally
    /// left running.
    func cancelAll() {
        readRunnersLock.lock()
        let runners = Array(readRunners.values)
        readRunnersLock.unlock()

        for runner in runners {
            runner.cancelAll()
        }
    }

    /// Fetch all agents for a session.
    func fetchAgents(
        ledgerSessionId: Int64
    ) async throws -> [AgentRun] {
        let data = try await runCLI(
            ledgerSessionId: ledgerSessionId,
            args: [
                "list", "--json",
                "--ledger-session-id",
                String(ledgerSessionId),
            ]
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy =
            .convertFromSnakeCase
        let response = try decoder.decode(
            AgentsResponse.self, from: data
        )
        return response.agents
    }


    /// Result of a reconcile pass: running counts keyed by
    /// ledger session id, taken after the sweep.
    struct ReconcileResult: Decodable {
        let skipped: Bool
        let running: [String: Int]

        /// Count for a session, absent meaning none running.
        func count(for ledgerSessionId: Int64) -> Int {
            running[String(ledgerSessionId)] ?? 0
        }
    }

    /// Sweep agents whose owning process is gone, and return
    /// what is running afterwards.
    ///
    /// Deliberately not per-session, and deliberately not on
    /// the read lane: it takes no session id because a live
    /// session's rows are never sweepable — the rows worth
    /// sweeping belong to sessions that already exited. One
    /// invocation therefore covers every session at once,
    /// which also keeps the tick to a single subprocess no
    /// matter how many sessions are open.
    func reconcile() async throws -> ReconcileResult {
        let data = try await runMutationCLI(
            args: ["reconcile"]
        )
        return try JSONDecoder().decode(
            ReconcileResult.self, from: data
        )
    }

    /// Mark a single agent as abandoned. Idempotent — the
    /// CLI exits 0 even when the row is already terminal,
    /// so callers don't need to distinguish "race lost"
    /// from real errors.
    func abandonAgent(
        ledgerSessionId: Int64,
        agentId: String
    ) async throws {
        _ = try await runMutationCLI(
            args: [
                "abandon",
                "--ledger-session-id",
                String(ledgerSessionId),
                "--agent-id", agentId,
            ]
        )
    }

    // MARK: - CLI Subprocess

    /// The read runner for one session, created on first use.
    private func readRunner(
        for ledgerSessionId: Int64
    ) -> ProcessRunner {
        readRunnersLock.lock()
        defer { readRunnersLock.unlock() }

        if let existing = readRunners[ledgerSessionId] {
            return existing
        }
        let runner = ProcessRunner(
            binaryPath: Self.binaryPath,
            defaultTimeout: 5
        )
        readRunners[ledgerSessionId] = runner
        return runner
    }

    /// Spawn the galaxy-agents binary and collect stdout. Cancels
    /// any previous in-flight read query *for this session*, which
    /// leaves queries about other sessions running.
    private func runCLI(
        ledgerSessionId: Int64,
        args: [String]
    ) async throws -> Data {
        let runner = readRunner(for: ledgerSessionId)
        runner.cancelAll()
        do {
            return try await runner.run(args: args)
        } catch {
            throw Self.mapError(error)
        }
    }

    /// Mutation-lane subprocess runner. Uses `mutationRunner` and
    /// never cancels reads — a concurrent polling read must not
    /// terminate an in-flight write. Short-lived; callers should
    /// not fire overlapping mutations.
    private func runMutationCLI(
        args: [String]
    ) async throws -> Data {
        do {
            return try await mutationRunner.run(args: args)
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
            return AgentsQueryError.cliError(status: status, message: message)
        case .timedOut(_, let seconds):
            return AgentsQueryError.cliError(
                status: -1,
                message: "timed out after \(Int(seconds))s"
            )
        case .launchFailed(_, let underlying):
            return underlying
        }
    }
}

// MARK: - Error Type

enum AgentsQueryError: Error, LocalizedError {
    case cliError(status: Int32, message: String)

    /// True when the child was terminated rather than failing on
    /// its own. Reads are single-flight per session, so this means
    /// a newer query for the same session replaced this one —
    /// routine, and worth naming separately so a genuine failure
    /// is not buried among them in the log.
    var isSuperseded: Bool {
        if case .cliError(let status, _) = self {
            return status == SIGTERM
        }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .cliError(let status, let message):
            return "galaxy-agents exited with"
                + " status \(status): \(message)"
        }
    }
}

// MARK: - JSON Response Wrappers

private struct AgentsResponse: Codable {
    let agents: [AgentRun]
}

