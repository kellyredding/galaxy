import Foundation

/// Fetches snapshot data on demand by spawning galaxy-snapshots CLI.
/// Separate from LedgerQueryService to maintain independent
/// cancellation domains — switching ledger subtabs shouldn't cancel
/// an in-flight snapshot fetch and vice versa.
class SnapshotQueryService {
    static let shared = SnapshotQueryService()

    private let binaryPath: String
    private let processTimeout: TimeInterval = 5.0

    /// Currently running subprocess — terminated before each new fetch.
    private var currentProcess: Process?
    private let lock = NSLock()

    private init() {
        self.binaryPath = "\(NSHomeDirectory())/.claude/galaxy/bin/galaxy-snapshots"
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

    /// Fetch snapshot index (metadata only, no content).
    func fetchSnapshots(ledgerSessionId: Int64) async throws -> [SnapshotSummary] {
        let data = try await runCLI(
            args: ["list", "--json",
                   "--ledger-session-id", String(ledgerSessionId)]
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(SnapshotsResponse.self, from: data)
        return response.snapshots
    }

    /// Fetch full snapshot content for the reader.
    func fetchSnapshotContent(
        ledgerSessionId: Int64,
        number: Int32
    ) async throws -> SnapshotDetail {
        let data = try await runCLI(
            args: ["view", "--json",
                   "--ledger-session-id", String(ledgerSessionId),
                   String(number)]
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(SnapshotViewResponse.self, from: data)
        return response.snapshot
    }

    /// Fetch all annotations for a snapshot.
    func fetchAnnotations(snapshotId: Int64) async throws -> [SnapshotAnnotation] {
        let data = try await runCLI(
            args: ["annotation", "list", "--json",
                   "--snapshot-id", String(snapshotId)]
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(AnnotationsResponse.self, from: data)
        return response.annotations
    }

    /// Create an annotation on a snapshot. Content piped via stdin.
    func createAnnotation(
        snapshotId: Int64,
        startLine: Int32,
        endLine: Int32,
        content: String
    ) async throws -> SnapshotAnnotation {
        let data = try await runCLI(
            args: ["annotation", "create",
                   "--snapshot-id", String(snapshotId),
                   "--start-line", String(startLine),
                   "--end-line", String(endLine)],
            stdinContent: content
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(AnnotationCreateResponse.self, from: data)
        return response.annotation
    }

    /// Update an annotation's content. Content piped via stdin.
    func updateAnnotation(
        snapshotId: Int64,
        number: Int32,
        content: String
    ) async throws -> SnapshotAnnotation {
        let data = try await runCLI(
            args: ["annotation", "update",
                   "--snapshot-id", String(snapshotId),
                   String(number)],
            stdinContent: content
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(AnnotationCreateResponse.self, from: data)
        return response.annotation
    }

    /// Delete an annotation by number.
    func deleteAnnotation(
        snapshotId: Int64,
        number: Int32
    ) async throws {
        _ = try await runCLI(
            args: ["annotation", "delete",
                   "--snapshot-id", String(snapshotId),
                   String(number)]
        )
    }

    /// Create a review from all unreviewed annotations.
    func createReview(snapshotId: Int64) async throws -> SnapshotReviewCreateResult {
        let data = try await runCLI(
            args: ["review", "create",
                   "--snapshot-id", String(snapshotId)]
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SnapshotReviewCreateResult.self, from: data)
    }

    /// Check if a snapshot has unreviewed annotations.
    /// Uses an independent process — safe to call while other
    /// SnapshotQueryService operations are in-flight.
    func checkHasPending(snapshotId: Int64) async throws -> Bool {
        let data = try await runIndependent(
            args: ["review", "has-pending",
                   "--snapshot-id", String(snapshotId)]
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let result = try decoder.decode(HasPendingResult.self, from: data)
        return result.hasPending
    }

    // MARK: - CLI Subprocess

    /// Spawn the galaxy-snapshots binary and collect stdout.
    /// Cancels any previous in-flight process first.
    /// When stdinContent is provided, it's written to the process's stdin pipe.
    private func runCLI(args: [String], stdinContent: String? = nil) async throws -> Data {
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

        // Set up stdin pipe when content needs to be written
        var inputPipe: Pipe? = nil
        if stdinContent != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            inputPipe = pipe
        }

        setCurrentProcess(process)

        return try await withCheckedThrowingContinuation { continuation in
            do {
                try process.run()
            } catch {
                self.clearCurrentProcess(process)
                continuation.resume(throwing: error)
                return
            }

            // Write stdin content and close the pipe after launch
            if let content = stdinContent, let pipe = inputPipe {
                if let data = content.data(using: .utf8) {
                    pipe.fileHandleForWriting.write(data)
                }
                pipe.fileHandleForWriting.closeFile()
            }

            // Wait on background thread to avoid blocking
            DispatchQueue.global(qos: .userInitiated).async {
                process.waitUntilExit()

                self.clearCurrentProcess(process)

                guard process.terminationStatus == 0 else {
                    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                    let errMsg = String(data: errData, encoding: .utf8) ?? "Unknown error"
                    continuation.resume(
                        throwing: SnapshotQueryError.cliError(
                            status: process.terminationStatus,
                            message: errMsg.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                    )
                    return
                }

                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: data)
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

    /// Spawn the galaxy-snapshots binary independently of the shared
    /// currentProcess. Safe to call while other operations are
    /// in-flight — won't cancel them and won't be canceled by them.
    private func runIndependent(args: [String]) async throws -> Data {
        try Task.checkCancellation()

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()

        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = args
        process.standardOutput = stdout
        process.standardError = stderr

        return try await withCheckedThrowingContinuation { continuation in
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }

            DispatchQueue.global(qos: .userInitiated).async {
                process.waitUntilExit()

                guard process.terminationStatus == 0 else {
                    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                    let errMsg = String(data: errData, encoding: .utf8) ?? "Unknown error"
                    continuation.resume(
                        throwing: SnapshotQueryError.cliError(
                            status: process.terminationStatus,
                            message: errMsg.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                    )
                    return
                }

                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: data)
            }
        }
    }
}

// MARK: - Error Type

enum SnapshotQueryError: Error, LocalizedError {
    case cliError(status: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .cliError(let status, let message):
            return "galaxy-snapshots exited with status \(status): \(message)"
        }
    }
}

// MARK: - JSON Response Wrappers

private struct SnapshotsResponse: Codable {
    let snapshots: [SnapshotSummary]
}

private struct SnapshotViewResponse: Codable {
    let snapshot: SnapshotDetail
}

private struct AnnotationsResponse: Codable {
    let annotations: [SnapshotAnnotation]
}

private struct AnnotationCreateResponse: Codable {
    let annotation: SnapshotAnnotation
}

// MARK: - Codable Models

/// Snapshot metadata for the index view (no content).
struct SnapshotSummary: Codable, Identifiable {
    let id: Int64
    let number: Int32
    let title: String
    let exchangeCount: Int32
    let charCount: Int32
    let reviewCount: Int32
    let createdAt: String
}

/// Full snapshot for the reader view (includes content).
struct SnapshotDetail: Codable {
    let id: Int64
    let number: Int32
    let title: String
    let content: String
    let exchangeCount: Int32
    let charCount: Int32
    let createdAt: String
    let updatedAt: String
    let metadata: String?
}

/// Annotation attached to a snapshot's line range.
struct SnapshotAnnotation: Codable, Identifiable {
    let id: Int64
    let createdAt: String
    let updatedAt: String
    let snapshotId: Int64
    let number: Int32
    let startLine: Int32
    let endLine: Int32
    let content: String
    let snapshotReviewId: Int64?
    let reviewNumber: Int32?
    let reviewReviewedAt: String?
}

/// Result from creating a snapshot review.
struct SnapshotReviewCreateResult: Codable {
    let review: SnapshotReviewSummary
    let annotationCount: Int32
}

/// Summary of a snapshot review record.
struct SnapshotReviewSummary: Codable {
    let id: Int64
    let number: Int32
    let snapshotId: Int64
    let createdAt: String
    let updatedAt: String
    let reviewedAt: String?
}

/// Result from checking if unreviewed annotations exist.
struct HasPendingResult: Codable {
    let snapshotId: Int64
    let hasPending: Bool
    let count: Int32
}
