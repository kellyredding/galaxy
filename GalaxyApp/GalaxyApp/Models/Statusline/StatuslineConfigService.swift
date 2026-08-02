import Foundation
import SwiftUI
import Galactic

/// Async wrapper around the `galaxy-statusline` CLI. All
/// statusline configuration reads and writes flow through here —
/// the Settings tab never touches ~/.claude/settings.json or
/// ~/.claude/galaxy/statusline/config.json directly.
///
/// CLI invocations run through ProcessRunner, which drains the
/// pipes and observes exit via event callbacks (no blocked thread)
/// and bounds each call with a timeout.
@MainActor
final class StatuslineConfigService: ObservableObject {
    enum ServiceError: Error, LocalizedError, Equatable {
        case cliMissing(path: String)
        case cliError(status: Int32, message: String)
        case decodeError(description: String)

        var errorDescription: String? {
            switch self {
            case .cliMissing(let path):
                return "galaxy-statusline binary not found at \(path)"
            case .cliError(let status, let message):
                return "galaxy-statusline exited with status \(status): \(message)"
            case .decodeError(let description):
                return "Failed to decode CLI output: \(description)"
            }
        }
    }

    /// Last successfully fetched hook status. nil before first load.
    @Published private(set) var hookStatus: StatuslineHookStatus?

    /// Last successfully fetched config. nil when uninstalled or
    /// before first load.
    @Published private(set) var config: StatuslineConfig?

    /// In-flight operation count — drives spinners and disables
    /// controls while the CLI is being invoked.
    @Published private(set) var inFlight: Int = 0

    /// Most recent error (cleared on the next successful operation).
    @Published var lastError: ServiceError?

    /// Immutable, thread-safe — accessed from the nonisolated
    /// runCLI method without crossing actor boundaries.
    nonisolated private let binaryPath: String

    /// Statusline reads/writes are independent and infrequent
    /// (Settings tab), so no shared cancellation is needed — each
    /// call is bounded by its own timeout.
    nonisolated private let runner: ProcessRunner

    init(binaryPath: String? = nil) {
        let resolved = binaryPath
            ?? "\(NSHomeDirectory())/.claude/galaxy/bin/galaxy-statusline"
        self.binaryPath = resolved
        self.runner = ProcessRunner(binaryPath: resolved, defaultTimeout: 5)
    }

    // MARK: - Public API

    /// Refresh hook status + (if installed) config from the CLI.
    /// The single source of truth for the Settings tab's view state.
    func refresh() async {
        await withTracking {
            let status = try await self.fetchHookStatus()
            self.hookStatus = status
            if status.installed && status.matchesExpectedCommand {
                self.config = try await self.fetchConfig()
            } else {
                self.config = nil
            }
        }
    }

    /// Install the hook, then refresh. Idempotent at the CLI layer.
    func installHook() async {
        await withTracking {
            _ = try await self.runCLI(args: ["hook", "install"])
            self.hookStatus = try await self.fetchHookStatus()
            if self.hookStatus?.installed == true {
                self.config = try await self.fetchConfig()
            }
        }
    }

    /// Uninstall the hook, then refresh. Config file is preserved
    /// at the CLI layer; re-installing restores user customizations.
    func uninstallHook() async {
        await withTracking {
            _ = try await self.runCLI(args: ["hook", "uninstall"])
            self.hookStatus = try await self.fetchHookStatus()
            self.config = nil
        }
    }

    /// Set a single config key, then re-fetch the entire config so
    /// the UI reflects the canonical state. On error, lastError
    /// populates without throwing — the view's local binding state
    /// will snap back to the last-known-good config on the next
    /// re-render.
    func setConfigKey(_ key: String, value: String) async {
        await withTracking {
            _ = try await self.runCLI(args: ["config", "set", key, value])
            self.config = try await self.fetchConfig()
        }
    }

    /// Reset config to defaults, then re-fetch.
    func resetConfig() async {
        await withTracking {
            _ = try await self.runCLI(args: ["config", "reset"])
            self.config = try await self.fetchConfig()
        }
    }

    /// Render a fabricated sample status line via the CLI's
    /// preview subcommand. Returns the raw ANSI-encoded output
    /// for the caller to parse and display. Does NOT touch the
    /// service's published state — preview is a derived view of
    /// `config`, callers can re-invoke whenever they need.
    func renderSample() async throws -> String {
        let data = try await runCLI(args: ["preview"])
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Internal

    private func fetchHookStatus() async throws -> StatuslineHookStatus {
        let data = try await runCLI(args: ["--json", "hook", "status"])
        return try Self.decode(StatuslineHookStatus.self, from: data)
    }

    private func fetchConfig() async throws -> StatuslineConfig {
        let data = try await runCLI(args: ["config"])
        return try Self.decode(StatuslineConfig.self, from: data)
    }

    /// Wrap a body that performs CLI calls with in-flight counter
    /// management and centralized error capture.
    private func withTracking(
        _ body: @MainActor @escaping () async throws -> Void
    ) async {
        inFlight += 1
        defer { inFlight -= 1 }
        do {
            try await body()
            lastError = nil
        } catch let err as ServiceError {
            lastError = err
        } catch {
            lastError = .cliError(
                status: -1,
                message: error.localizedDescription
            )
        }
    }

    private static func decode<T: Decodable>(
        _ type: T.Type, from data: Data
    ) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw ServiceError.decodeError(
                description: error.localizedDescription
            )
        }
    }

    /// Spawn galaxy-statusline with the given arguments and return
    /// stdout as Data. Mirrors TimelineQueryService.runCLI.
    nonisolated private func runCLI(args: [String]) async throws -> Data {
        let path = self.binaryPath
        guard FileManager.default.fileExists(atPath: path) else {
            throw ServiceError.cliMissing(path: path)
        }
        do {
            return try await runner.run(args: args)
        } catch {
            throw Self.mapError(error)
        }
    }

    /// Translate the runner's generic error into this service's
    /// error type so callers see the familiar surface.
    nonisolated private static func mapError(_ error: Error) -> Error {
        guard let error = error as? ProcessRunError else { return error }
        switch error {
        case .cliError(_, let status, let message):
            return ServiceError.cliError(status: status, message: message)
        case .timedOut(_, let seconds):
            return ServiceError.cliError(
                status: -1,
                message: "timed out after \(Int(seconds))s"
            )
        case .launchFailed(_, let underlying):
            return underlying
        }
    }
}
