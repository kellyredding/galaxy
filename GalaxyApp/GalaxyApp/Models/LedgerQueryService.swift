import Foundation

/// Singleton service that fetches ledger data on demand by spawning
/// the galaxy-ledger CLI as a subprocess. Each fetch cancels any
/// in-flight query to prevent stale results during rapid navigation.
class LedgerQueryService {
    static let shared = LedgerQueryService()

    private let binaryPath: String
    private let processTimeout: TimeInterval = 5.0

    /// Currently running subprocess — terminated before each new fetch.
    private var currentProcess: Process?
    private let lock = NSLock()

    private init() {
        self.binaryPath = "\(NSHomeDirectory())/.claude/galaxy/bin/galaxy-ledger"
    }

    // MARK: - Public API

    /// Cancel any in-flight CLI query.
    func cancelAll() {
        lock.lock()
        let proc = currentProcess
        currentProcess = nil
        lock.unlock()
        if let proc = proc, proc.isRunning {
            proc.terminate()
        }
    }

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
    /// Cancels any previous in-flight process first.
    private func runCLI(args: [String]) async throws -> Data {
        // Cancel previous (synchronous, safe to call from async)
        cancelAll()

        // Check for task cancellation
        try Task.checkCancellation()

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()

        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = args
        process.standardOutput = stdout
        process.standardError = stderr

        setCurrentProcess(process)

        return try await withCheckedThrowingContinuation { continuation in
            do {
                try process.run()
            } catch {
                self.clearCurrentProcess(process)
                continuation.resume(throwing: error)
                return
            }

            // Collect stdout/stderr on background threads BEFORE waiting
            // for exit. Reading after waitUntilExit deadlocks when output
            // exceeds the ~64KB pipe buffer — the process blocks on write
            // while waitUntilExit blocks on the process.
            DispatchQueue.global(qos: .userInitiated).async {
                let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()

                process.waitUntilExit()

                self.clearCurrentProcess(process)

                guard process.terminationStatus == 0 else {
                    let errMsg = String(data: stderrData, encoding: .utf8) ?? "Unknown error"
                    continuation.resume(
                        throwing: LedgerQueryError.cliError(
                            status: process.terminationStatus,
                            message: errMsg.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                    )
                    return
                }

                continuation.resume(returning: stdoutData)
            }
        }
    }

    /// Thread-safe setter for currentProcess.
    private func setCurrentProcess(_ process: Process) {
        lock.lock()
        currentProcess = process
        lock.unlock()
    }

    /// Thread-safe conditional clear of currentProcess.
    private func clearCurrentProcess(_ process: Process) {
        lock.lock()
        if currentProcess === process { currentProcess = nil }
        lock.unlock()
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
