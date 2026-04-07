import Foundation

/// Fetches artifact data on demand by spawning galaxy-artifacts CLI.
/// Separate from other query services to maintain independent
/// cancellation domains.
class ArtifactQueryService {
    static let shared = ArtifactQueryService()

    private let binaryPath: String
    private let processTimeout: TimeInterval = 5.0

    /// Currently running subprocess — terminated before each new fetch.
    private var currentProcess: Process?
    private let lock = NSLock()

    private init() {
        self.binaryPath = "\(NSHomeDirectory())/.claude/galaxy/bin/galaxy-artifacts"
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

    /// Fetch artifact index (metadata only, no content).
    func fetchArtifacts(
        ledgerSessionId: Int64
    ) async throws -> [ArtifactSummary] {
        let data = try await runCLI(
            args: ["list", "--json",
                   "--ledger-session-id",
                   String(ledgerSessionId)]
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(
            ArtifactsResponse.self, from: data
        )
        return response.artifacts
    }

    // MARK: - CLI Subprocess

    /// Spawn the galaxy-artifacts binary and collect stdout.
    /// Cancels any previous in-flight process first.
    private func runCLI(
        args: [String],
        stdinContent: String? = nil
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

        var inputPipe: Pipe? = nil
        if stdinContent != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            inputPipe = pipe
        }

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

            if let content = stdinContent,
               let pipe = inputPipe
            {
                if let data = content.data(using: .utf8) {
                    pipe.fileHandleForWriting.write(data)
                }
                pipe.fileHandleForWriting.closeFile()
            }

            DispatchQueue.global(qos: .userInitiated)
                .async {
                let outData = stdout.fileHandleForReading
                    .readDataToEndOfFile()
                let errData = stderr.fileHandleForReading
                    .readDataToEndOfFile()
                process.waitUntilExit()

                self.clearCurrentProcess(process)

                guard process.terminationStatus == 0
                else {
                    let errMsg = String(
                        data: errData, encoding: .utf8
                    ) ?? "Unknown error"
                    continuation.resume(
                        throwing:
                            ArtifactQueryError.cliError(
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
        if currentProcess === process {
            currentProcess = nil
        }
        lock.unlock()
    }
}

// MARK: - Error Type

enum ArtifactQueryError: Error, LocalizedError {
    case cliError(status: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .cliError(let status, let message):
            return "galaxy-artifacts exited with "
                + "status \(status): \(message)"
        }
    }
}

// MARK: - JSON Response Wrappers

private struct ArtifactsResponse: Codable {
    let artifacts: [ArtifactSummary]
}

// MARK: - Codable Models

/// Artifact metadata for the index view.
struct ArtifactSummary: Codable, Identifiable {
    var id: Int32 { number }
    let number: Int32
    let title: String
    let artifactType: String
    let mimeType: String
    let originalFilename: String
    let fileSize: Int64
    let sourcePath: String?
    let createdAt: String
    let description: String?
}
