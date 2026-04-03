import Foundation

/// Fetches agent data on demand by spawning galaxy-agents CLI.
/// Follows the same pattern as SnapshotQueryService — independent
/// cancellation domain, process management, and JSON decoding.
class AgentsQueryService {
    static let shared = AgentsQueryService()

    private let binaryPath: String
    private let processTimeout: TimeInterval = 5.0

    /// Currently running subprocess — terminated before each
    /// new fetch.
    private var currentProcess: Process?
    private let lock = NSLock()

    private init() {
        self.binaryPath = "\(NSHomeDirectory())"
            + "/.claude/galaxy/bin/galaxy-agents"
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

    // MARK: - CLI Subprocess

    /// Spawn the galaxy-agents binary and collect stdout.
    /// Cancels any previous in-flight process first.
    private func runCLI(
        args: [String]
    ) async throws -> Data {
        cancelAll()
        try Task.checkCancellation()

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()

        process.executableURL = URL(
            fileURLWithPath: binaryPath
        )
        process.arguments = args
        process.standardOutput = stdout
        process.standardError = stderr

        setCurrentProcess(process)

        return try await withCheckedThrowingContinuation {
            continuation in
            do {
                try process.run()
            } catch {
                self.clearCurrentProcess(process)
                continuation.resume(throwing: error)
                return
            }

            DispatchQueue.global(
                qos: .userInitiated
            ).async {
                let outData = stdout
                    .fileHandleForReading
                    .readDataToEndOfFile()
                let errData = stderr
                    .fileHandleForReading
                    .readDataToEndOfFile()
                process.waitUntilExit()

                self.clearCurrentProcess(process)

                guard process.terminationStatus == 0
                else {
                    let errMsg = String(
                        data: errData,
                        encoding: .utf8
                    ) ?? "Unknown error"
                    continuation.resume(
                        throwing:
                            AgentsQueryError.cliError(
                                status: process
                                    .terminationStatus,
                                message: errMsg
                                    .trimmingCharacters(
                                        in:
                                            .whitespacesAndNewlines
                                    )
                            )
                    )
                    return
                }

                continuation.resume(
                    returning: outData
                )
            }
        }
    }

    /// Thread-safe setter for currentProcess.
    private func setCurrentProcess(
        _ process: Process
    ) {
        lock.lock()
        currentProcess = process
        lock.unlock()
    }

    /// Thread-safe conditional clear of currentProcess.
    private func clearCurrentProcess(
        _ process: Process
    ) {
        lock.lock()
        if currentProcess === process {
            currentProcess = nil
        }
        lock.unlock()
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
