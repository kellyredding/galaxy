import Foundation

/// Fetches agent data on demand by spawning galaxy-agents CLI.
/// Follows the same pattern as SnapshotQueryService — independent
/// cancellation domain, process management, and JSON decoding.
class AgentsQueryService {
    static let shared = AgentsQueryService()

    /// Two cancellation domains: `queryRunner` backs read fetches
    /// (a new fetch cancels the previous one, and cancelAll()
    /// targets it); `mutationRunner` backs writes so a concurrent
    /// polling read can never terminate an in-flight mutation.
    private let queryRunner = ProcessRunner(
        binaryPath: "\(NSHomeDirectory())/.claude/galaxy/bin/galaxy-agents",
        defaultTimeout: 5
    )
    private let mutationRunner = ProcessRunner(
        binaryPath: "\(NSHomeDirectory())/.claude/galaxy/bin/galaxy-agents",
        defaultTimeout: 5
    )

    private init() {}

    // MARK: - Public API

    /// Cancel any in-flight read query. In-flight mutations
    /// (runMutationCLI) are intentionally left running.
    func cancelAll() {
        queryRunner.cancelAll()
    }

    /// Fetch all agents for a session.
    func fetchAgents(
        ledgerSessionId: Int64
    ) async throws -> [AgentRun] {
        let data = try await runCLI(
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

    /// Fetch count of running agents for a session.
    func fetchRunningCount(
        ledgerSessionId: Int64
    ) async throws -> Int {
        let data = try await runCLI(
            args: [
                "running",
                "--ledger-session-id",
                String(ledgerSessionId),
            ]
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy =
            .convertFromSnakeCase
        let response = try decoder.decode(
            RunningCountResponse.self, from: data
        )
        return response.count
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

    /// Spawn the galaxy-agents binary and collect stdout. Cancels
    /// any previous in-flight read query first (single-flight).
    private func runCLI(
        args: [String]
    ) async throws -> Data {
        queryRunner.cancelAll()
        do {
            return try await queryRunner.run(args: args)
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

private struct RunningCountResponse: Codable {
    let count: Int
}
