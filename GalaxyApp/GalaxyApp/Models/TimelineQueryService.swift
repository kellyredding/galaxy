import Foundation

/// Fetches timeline events on demand by spawning galaxy-timeline CLI.
/// Follows the SnapshotQueryService pattern: Process with async/await
/// bridging, NSLock for thread safety, cancellation support.
class TimelineQueryService {
    static let shared = TimelineQueryService()

    private let binaryPath: String

    /// Currently running subprocess — terminated before each new fetch.
    private var currentProcess: Process?
    private let lock = NSLock()

    /// Custom date formatter for CLI output format "yyyy-MM-dd HH:mm:ss" in UTC.
    static let dateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt
    }()

    private init() {
        self.binaryPath = "\(NSHomeDirectory())/.claude/galaxy/bin/galaxy-timeline"
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

    // MARK: - CLI Subprocess

    /// Spawn the galaxy-timeline binary and collect stdout.
    /// Cancels any previous in-flight process first.
    private func runCLI(args: [String]) async throws -> Data {
        cancelAll()
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

            // Read stdout/stderr BEFORE waitUntilExit to avoid
            // pipe buffer deadlock when output exceeds ~64KB.
            DispatchQueue.global(qos: .userInitiated).async {
                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                self.clearCurrentProcess(process)

                guard process.terminationStatus == 0 else {
                    let errMsg = String(data: errData, encoding: .utf8) ?? "Unknown error"
                    continuation.resume(
                        throwing: TimelineQueryError.cliError(
                            status: process.terminationStatus,
                            message: errMsg.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                    )
                    return
                }

                continuation.resume(returning: outData)
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

enum TimelineQueryError: Error, LocalizedError {
    case cliError(status: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .cliError(let status, let message):
            return "galaxy-timeline exited with status \(status): \(message)"
        }
    }
}
