import Foundation

/// Singleton service that fetches ledger data on demand by spawning
/// the galaxy-ledger CLI as a subprocess. Each public method is
/// designed to be called from independent per-subtab Tasks —
/// concurrent CLI calls are expected and safe.
class LedgerQueryService {
    static let shared = LedgerQueryService()

    /// Concurrent calls are expected and safe, so this runner is
    /// never cancelled as a group — each call is bounded only by its
    /// own timeout and its caller's Task cancellation.
    private let runner = ProcessRunner(
        binaryPath: "\(NSHomeDirectory())/.claude/galaxy/bin/galaxy-ledger",
        defaultTimeout: 5
    )

    private init() {}

    // MARK: - Public API

    /// Fetch session detail (identifiers, PIDs) for a ledger session.
    func fetchSession(ledgerSessionId: Int64) async throws -> LedgerSessionDetail? {
        let data = try await runCLI(
            args: ["sessions", "--json", "--ledger-session-id", String(ledgerSessionId)]
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(SessionsResponse.self, from: data)
        return response.sessions.first
    }

    /// Fetch all files for a ledger session.
    func fetchFiles(ledgerSessionId: Int64) async throws -> [LedgerFile] {
        let data = try await runCLI(
            args: ["list-files", "--json", "--ledger-session-id", String(ledgerSessionId)]
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(FilesResponse.self, from: data)
        return response.files
    }

    /// Fetch recent entries for a ledger session.
    func fetchEntries(ledgerSessionId: Int64, limit: Int = 100) async throws -> [LedgerEntry] {
        let data = try await runCLI(
            args: ["list-entries", "--json", "--ledger-session-id", String(ledgerSessionId),
                   "--limit", String(limit)]
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(EntriesResponse.self, from: data)
        return response.entries
    }

    /// Search entries for a ledger session by query string.
    func searchEntries(ledgerSessionId: Int64, query: String) async throws -> [LedgerEntry] {
        let data = try await runCLI(
            args: ["search", "--json", "--ledger-session-id", String(ledgerSessionId),
                   "--query", query]
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(EntriesResponse.self, from: data)
        return response.entries
    }

    // MARK: - CLI Subprocess

    /// Spawn the galaxy-ledger binary and collect stdout.
    /// No shared process tracking — each call is independent.
    /// Task-level cancellation prevents stale data from being written.
    private func runCLI(args: [String]) async throws -> Data {
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
            return LedgerQueryError.cliError(status: status, message: message)
        case .timedOut(_, let seconds):
            return LedgerQueryError.cliError(
                status: -1,
                message: "timed out after \(Int(seconds))s"
            )
        case .launchFailed(_, let underlying):
            return underlying
        }
    }
}

// MARK: - Error Type

enum LedgerQueryError: Error, LocalizedError {
    case cliError(status: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .cliError(let status, let message):
            return "galaxy-ledger exited with status \(status): \(message)"
        }
    }
}

// MARK: - JSON Response Wrappers

private struct SessionsResponse: Codable {
    let sessions: [LedgerSessionDetail]
}

private struct FilesResponse: Codable {
    let files: [LedgerFile]
}

private struct EntriesResponse: Codable {
    let entries: [LedgerEntry]
}

// MARK: - Codable Models

struct LedgerSessionDetail: Codable {
    let ledgerSessionId: Int64
    let sessionIdentifiers: [String]
    let currentSessionIdentifier: String?
    let claudePids: [Int]?
    let currentClaudePid: Int?
}

struct LedgerFile: Codable, Identifiable {
    let id: Int64
    let filePath: String
    let searchPattern: String
    let isRead: Bool
    let isEdited: Bool
    let isWritten: Bool
    let isSearched: Bool
    let firstSeenAt: String?
    let lastSeenAt: String?
    let accessCount: Int64
    let fileType: String
}

struct LedgerEntry: Codable, Identifiable {
    let id: Int64
    let entryType: String
    let source: String?
    let content: String
    let importance: String
    let category: String?
    let keywords: String?
    let sourceFile: String?
    let ledgerSessionId: Int64
    let createdAt: String
}
