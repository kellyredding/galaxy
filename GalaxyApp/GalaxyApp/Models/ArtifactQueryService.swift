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

    // MARK: - Annotations

    /// Fetch all annotations for an artifact.
    func fetchAnnotations(
        ledgerSessionId: Int64,
        artifactNumber: Int32
    ) async throws -> [ArtifactAnnotation] {
        let data = try await runCLI(
            args: ["annotation", "list", "--json",
                   "--ledger-session-id",
                   String(ledgerSessionId),
                   "--artifact",
                   String(artifactNumber)]
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(
            ArtifactAnnotationsResponse.self,
            from: data
        )
        return response.annotations
    }

    /// Refresh an artifact by re-syncing from its
    /// source file. Returns JSON with refresh status.
    /// Uses runIndependent so it doesn't cancel
    /// in-flight fetch operations.
    func refreshArtifact(
        ledgerSessionId: Int64,
        artifactNumber: Int32
    ) async throws -> ArtifactRefreshResult {
        let data = try await runIndependent(
            args: ["refresh",
                   "--ledger-session-id",
                   String(ledgerSessionId),
                   String(artifactNumber)]
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy
            = .convertFromSnakeCase
        return try decoder.decode(
            ArtifactRefreshResult.self,
            from: data
        )
    }

    /// Create an annotation. Content + anchor data piped
    /// via stdin as JSON envelope.
    func createAnnotation(
        ledgerSessionId: Int64,
        artifactNumber: Int32,
        anchorData: [String: Any],
        content: String
    ) async throws -> ArtifactAnnotation {
        let envelope: [String: Any] = [
            "anchor_data": anchorData,
            "content": content,
        ]
        let jsonData = try JSONSerialization.data(
            withJSONObject: envelope
        )
        let jsonString = String(
            data: jsonData, encoding: .utf8
        )!
        let data = try await runCLI(
            args: ["annotation", "create",
                   "--ledger-session-id",
                   String(ledgerSessionId),
                   "--artifact",
                   String(artifactNumber)],
            stdinContent: jsonString
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(
            ArtifactAnnotationCreateResponse.self,
            from: data
        )
        return response.annotation
    }

    /// Update an annotation's content. Content piped via
    /// stdin as plain text.
    func updateAnnotation(
        ledgerSessionId: Int64,
        artifactNumber: Int32,
        number: Int32,
        content: String
    ) async throws -> ArtifactAnnotation {
        let data = try await runCLI(
            args: ["annotation", "update",
                   "--ledger-session-id",
                   String(ledgerSessionId),
                   "--artifact",
                   String(artifactNumber),
                   String(number)],
            stdinContent: content
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(
            ArtifactAnnotationCreateResponse.self,
            from: data
        )
        return response.annotation
    }

    /// Delete an annotation by number.
    func deleteAnnotation(
        ledgerSessionId: Int64,
        artifactNumber: Int32,
        number: Int32
    ) async throws {
        _ = try await runCLI(
            args: ["annotation", "delete",
                   "--ledger-session-id",
                   String(ledgerSessionId),
                   "--artifact",
                   String(artifactNumber),
                   String(number)]
        )
    }

    // MARK: - Reviews

    /// Create a review from all unreviewed annotations.
    func createReview(
        ledgerSessionId: Int64,
        artifactNumber: Int32
    ) async throws -> ArtifactReviewCreateResult {
        let data = try await runCLI(
            args: ["review", "create",
                   "--ledger-session-id",
                   String(ledgerSessionId),
                   "--artifact",
                   String(artifactNumber)]
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(
            ArtifactReviewCreateResult.self,
            from: data
        )
    }

    /// Check if an artifact has unreviewed annotations.
    /// Uses an independent process — safe to call while
    /// other operations are in-flight.
    func checkHasPending(
        ledgerSessionId: Int64,
        artifactNumber: Int32
    ) async throws -> Bool {
        let data = try await runIndependent(
            args: ["review", "has-pending",
                   "--ledger-session-id",
                   String(ledgerSessionId),
                   "--artifact",
                   String(artifactNumber)]
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let result = try decoder.decode(
            ArtifactHasPendingResult.self,
            from: data
        )
        return result.hasPending
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

    /// Spawn the galaxy-artifacts binary independently
    /// of the shared currentProcess. Safe to call while
    /// other operations are in-flight — won't cancel them
    /// and won't be canceled by them.
    private func runIndependent(
        args: [String]
    ) async throws -> Data {
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

        return try await withCheckedThrowingContinuation {
            continuation in
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }

            DispatchQueue.global(qos: .userInitiated)
                .async {
                let outData = stdout.fileHandleForReading
                    .readDataToEndOfFile()
                let errData = stderr.fileHandleForReading
                    .readDataToEndOfFile()
                process.waitUntilExit()

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

private struct ArtifactAnnotationsResponse: Codable {
    let annotations: [ArtifactAnnotation]
}

private struct ArtifactAnnotationCreateResponse: Codable {
    let annotation: ArtifactAnnotation
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

/// Annotation attached to an artifact.
struct ArtifactAnnotation: Codable, Identifiable {
    let id: Int64
    let number: Int32
    let artifactId: Int64
    let artifactReviewId: Int64?
    let reviewNumber: Int32?
    let reviewReviewedAt: String?
    let content: String
    let anchorData: AnchorData
    let contentHash: String
    let stale: Bool
    let createdAt: String
    let updatedAt: String
}

/// Result from creating an artifact review.
struct ArtifactReviewCreateResult: Codable {
    let review: ArtifactReviewSummary
    let annotationCount: Int32
}

/// Summary of an artifact review record.
struct ArtifactReviewSummary: Codable {
    let id: Int64
    let number: Int32
    let artifactId: Int64
    let createdAt: String
    let updatedAt: String
    let reviewedAt: String?
}

/// Result from checking for unreviewed annotations.
struct ArtifactHasPendingResult: Codable {
    let artifactId: Int64
    let hasPending: Bool
    let count: Int32
}

/// Result from refreshing an artifact from source.
struct ArtifactRefreshResult: Codable {
    let number: Int32
    let resaved: Bool
    let hasSource: Bool
    let sourceExists: Bool
}
