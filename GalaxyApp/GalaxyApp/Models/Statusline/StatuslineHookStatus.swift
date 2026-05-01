import Foundation

/// Decoded from `galaxy-statusline hook status --json`. Mirrors
/// the HookStatus struct in
/// tools/statusline/src/galaxy_statusline/hook_manager.cr.
struct StatuslineHookStatus: Codable, Equatable {
    var installed: Bool
    var command: String?
    var matchesExpectedCommand: Bool
    var expectedCommand: String
    var settingsPath: String
}
