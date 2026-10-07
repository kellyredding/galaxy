import Foundation
import Galactic

/// A conversation Claude Code is running in a background worker under its
/// daemon. The daemon is detached from Galaxy, so the worker outlives the app
/// and keeps the conversation from being resumed until it is stopped.
struct BackgroundSession: Decodable {
    /// The short id `claude stop` takes. Interactive sessions have none.
    let id: String?
    let sessionId: String
    let pid: Int?
    let kind: String
    let status: String?

    var isBusy: Bool { status == "busy" }
}

enum BackgroundSessionError: Error, LocalizedError {
    case noShortId(String)
    case stillRunning(String)

    var errorDescription: String? {
        switch self {
        case .noShortId(let sessionId):
            return "Claude Code listed \(sessionId) without an id to stop it by."
        case .stillRunning(let id):
            return "Background session \(id) was still running after being stopped."
        }
    }
}

final class BackgroundSessionService {
    private let runner: ProcessRunner

    init(claudePath: String) {
        runner = ProcessRunner(binaryPath: claudePath, defaultTimeout: 5)
    }

    /// Nil when no live background worker holds the conversation, and also
    /// when the listing fails, so a failed check falls through to a plain
    /// resume rather than blocking one.
    func running(claudeSessionId: String) async -> BackgroundSession? {
        guard let data = try? await runner.run(args: ["agents", "--json"]),
              let all = try? JSONDecoder().decode([BackgroundSession].self, from: data)
        else { return nil }

        return all.first {
            $0.sessionId == claudeSessionId && $0.kind == "background" && $0.pid != nil
        }
    }

    /// Returns once the worker has left the listing, since `claude stop`
    /// is not documented to wait for the worker to exit.
    func stop(_ session: BackgroundSession) async throws {
        guard let id = session.id else {
            throw BackgroundSessionError.noShortId(session.sessionId)
        }
        _ = try await runner.run(args: ["stop", id])

        for _ in 0..<25 {
            if await running(claudeSessionId: session.sessionId) == nil { return }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw BackgroundSessionError.stillRunning(id)
    }
}
