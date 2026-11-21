import Foundation

/// The launch arguments every driven session gets on top of its vibe flag, on
/// every launch — a resume does not inherit a process's flags, so these are
/// re-applied each time rather than set once.
///
/// Together they keep an unattended session from ever stopping for input: the
/// question and plan tools are removed outright, and the hook answers any
/// permission request that a mode change could still produce.
enum DrivenLaunch {
    static let disallowedTools = ["AskUserQuestion", "EnterPlanMode", "ExitPlanMode"]

    static let permissionHookCommand =
        "~/.claude/galaxy/bin/galaxy-ledger allow-permission"

    /// Inline, so the hook reaches only the session launched with it.
    static var settingsJSON: String {
        let settings: [String: Any] = [
            "hooks": [
                "PermissionRequest": [
                    [
                        "hooks": [
                            [
                                "type": "command",
                                "command": permissionHookCommand,
                                "timeout": 5,
                            ] as [String: Any]
                        ]
                    ]
                ]
            ]
        ]
        let data = try? JSONSerialization.data(
            withJSONObject: settings, options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// `claude` takes one `--disallowed-tools` followed by its values;
    /// claude-persona takes the flag once per value.
    static func arguments(persona: Bool) -> [String] {
        let tools: [String] = persona
            ? disallowedTools.flatMap { ["--disallowed-tools", $0] }
            : ["--disallowed-tools"] + disallowedTools
        return tools + ["--settings", settingsJSON]
    }
}
