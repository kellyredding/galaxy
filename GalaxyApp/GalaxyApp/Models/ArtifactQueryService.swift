import Foundation

/// Fetches artifact data on demand by spawning galaxy-artifacts CLI.
/// Separate from other query services to maintain independent
/// cancellation domains.
class ArtifactQueryService {
    static let shared = ArtifactQueryService()

    /// Two cancellation domains: `trackedRunner` backs runCLI (a new
    /// fetch cancels the previous one, and cancelAll() targets it);
    /// `independentRunner` backs runIndependent (never cancelled by,
    /// nor cancelling, the tracked work).
    private let trackedRunner = ProcessRunner(
        binaryPath: "\(NSHomeDirectory())/.claude/galaxy/bin/galaxy-artifacts",
        defaultTimeout: 5
    )
    private let independentRunner = ProcessRunner(
        binaryPath: "\(NSHomeDirectory())/.claude/galaxy/bin/galaxy-artifacts",
        defaultTimeout: 5
    )

    private init() {}

    // MARK: - Public API

    /// Cancel any in-flight tracked CLI query. Independent queries
    /// (runIndependent) are intentionally left running.
    func cancelAll() {
        trackedRunner.cancelAll()
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

    /// Read an artifact's stored file content via the CLI's view
    /// command (raw stdout). Uses the independent lane so opening a
    /// reader neither cancels, nor is cancelled by, the index fetch.
    func fetchContent(
        ledgerSessionId: Int64,
        number: Int32
    ) async throws -> String {
        let data = try await runIndependent(
            args: [
                "view",
                "--ledger-session-id", String(ledgerSessionId),
                String(number),
            ]
        )
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Find the artifact whose source_path matches the given
    /// filesystem path. Compares on a normalized form
    /// (tilde-expanded, symlinks resolved) so callers can pass
    /// raw paths. Falls back to a filename-only match when the
    /// full-path comparison misses, which covers the common case
    /// of a path captured before a directory rename.
    func artifact(
        forSourcePath path: String,
        in ledgerSessionId: Int64
    ) async throws -> ArtifactSummary? {
        let list = try await fetchArtifacts(
            ledgerSessionId: ledgerSessionId
        )
        let target = Self.normalizedPath(path)
        if let exact = list.first(where: {
            guard let src = $0.sourcePath else {
                return false
            }
            return Self.normalizedPath(src) == target
        }) {
            return exact
        }
        let targetFilename =
            (target as NSString).lastPathComponent
        return list.first { summary in
            guard let source = summary.sourcePath else {
                return false
            }
            return (source as NSString).lastPathComponent
                == targetFilename
        }
    }

    /// Normalize a filesystem path for equality comparison.
    /// Expands leading `~`, standardizes the URL form
    /// (collapses `//`, resolves `.`/`..`), and follows
    /// symlinks when the file exists. Returns the original
    /// expanded path when symlink resolution fails.
    static func normalizedPath(_ s: String) -> String {
        let expanded =
            (s as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        return url.standardizedFileURL
            .resolvingSymlinksInPath().path
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
    ///
    /// When `skipEvent` is true, passes --skip-event
    /// to suppress the socket event. Used by the
    /// in-app refresh button (which handles its own
    /// UI reload). External callers omit this so
    /// Galaxy.app navigates via the socket event.
    func refreshArtifact(
        ledgerSessionId: Int64,
        artifactNumber: Int32,
        skipEvent: Bool = false
    ) async throws -> ArtifactRefreshResult {
        var args = [
            "refresh",
            "--ledger-session-id",
            String(ledgerSessionId),
        ]
        if skipEvent {
            args.append("--skip-event")
        }
        args.append(String(artifactNumber))

        let data = try await runIndependent(
            args: args
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

    /// Spawn the galaxy-artifacts binary and collect stdout. Cancels
    /// any previous in-flight tracked query first (single-flight).
    private func runCLI(
        args: [String],
        stdinContent: String? = nil
    ) async throws -> Data {
        trackedRunner.cancelAll()
        do {
            return try await trackedRunner.run(
                args: args,
                stdin: stdinContent?.data(using: .utf8)
            )
        } catch {
            throw Self.mapError(error)
        }
    }

    /// Spawn the galaxy-artifacts binary in an independent
    /// cancellation domain. Safe to call while other operations are
    /// in-flight — won't cancel them and won't be canceled by them.
    private func runIndependent(
        args: [String]
    ) async throws -> Data {
        do {
            return try await independentRunner.run(args: args)
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
            return ArtifactQueryError.cliError(
                status: status, message: message
            )
        case .timedOut(_, let seconds):
            return ArtifactQueryError.cliError(
                status: -1,
                message: "timed out after \(Int(seconds))s"
            )
        case .launchFailed(_, let underlying):
            return underlying
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
