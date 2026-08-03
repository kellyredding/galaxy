import Foundation
import Galactic

/// Fetches snapshot data on demand by spawning galaxy-snapshots CLI.
/// Separate from LedgerQueryService to maintain independent
/// cancellation domains — switching ledger subtabs shouldn't cancel
/// an in-flight snapshot fetch and vice versa.
class SnapshotQueryService {
    static let shared = SnapshotQueryService()

    /// Two cancellation domains: `trackedRunner` backs runCLI (a new
    /// fetch cancels the previous one, and cancelAll() targets it);
    /// `independentRunner` backs runIndependent (never cancelled by,
    /// nor cancelling, the tracked work).
    private let trackedRunner = ProcessRunner(
        binaryPath: "\(NSHomeDirectory())/.claude/galaxy/bin/galaxy-snapshots",
        defaultTimeout: 5
    )
    private let independentRunner = ProcessRunner(
        binaryPath: "\(NSHomeDirectory())/.claude/galaxy/bin/galaxy-snapshots",
        defaultTimeout: 5
    )

    private init() {}

    // MARK: - Public API

    /// Cancel any in-flight tracked CLI query. Independent queries
    /// (runIndependent) are intentionally left running.
    func cancelAll() {
        trackedRunner.cancelAll()
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
    /// How many unreviewed annotations a snapshot has.
    ///
    /// The CLI has always reported the count alongside the boolean; only
    /// this side discarded it, back when the caller was toggling a
    /// button's opacity.
    func checkPendingCount(snapshotId: Int64) async throws -> Int {
        let data = try await runIndependent(
            args: ["review", "has-pending",
                   "--snapshot-id", String(snapshotId)]
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let result = try decoder.decode(HasPendingResult.self, from: data)
        return Int(result.count)
    }

    // MARK: - CLI Subprocess

    /// Spawn the galaxy-snapshots binary and collect stdout. Cancels
    /// any previous in-flight tracked query first (single-flight).
    /// When stdinContent is provided, it's written to the process's
    /// stdin pipe.
    private func runCLI(args: [String], stdinContent: String? = nil) async throws -> Data {
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

    /// Spawn the galaxy-snapshots binary in an independent
    /// cancellation domain. Safe to call while other operations are
    /// in-flight — won't cancel them and won't be canceled by them.
    private func runIndependent(args: [String]) async throws -> Data {
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
            return SnapshotQueryError.cliError(status: status, message: message)
        case .timedOut(_, let seconds):
            return SnapshotQueryError.cliError(
                status: -1,
                message: "timed out after \(Int(seconds))s"
            )
        case .launchFailed(_, let underlying):
            return underlying
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
