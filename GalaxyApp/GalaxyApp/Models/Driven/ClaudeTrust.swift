import Foundation

/// Whether Claude Code already trusts a folder: a locked session cannot answer
/// the trust dialog. MEASURED (Claude Code 2.1.269): trust is per folder, and a
/// trusted `~/projects` did not cover a repository inside it.
enum ClaudeTrust {
    enum Decision: Equatable {
        case trusted
        case untrusted
        /// The config could not be read or parsed; the reason, for the reply.
        case unreadable(String)
    }

    static var configPath: String { NSHomeDirectory() + "/.claude.json" }

    static func decide(directory: String) -> Decision {
        guard let data = FileManager.default.contents(atPath: configPath) else {
            return .unreadable("could not read \(configPath)")
        }
        return decide(directory: directory, config: data)
    }

    static func decide(directory: String, config: Data) -> Decision {
        guard let root = try? JSONSerialization.jsonObject(with: config) as? [String: Any] else {
            return .unreadable("could not parse \(configPath)")
        }
        let projects = root["projects"] as? [String: Any] ?? [:]
        for candidate in candidates(for: directory) {
            if let entry = projects[candidate] as? [String: Any],
                entry["hasTrustDialogAccepted"] as? Bool == true
            {
                return .trusted
            }
        }
        return .untrusted
    }

    /// `/tmp` and `/private/tmp` name one folder, so both spellings count.
    static func candidates(for directory: String) -> [String] {
        let given = (directory as NSString).standardizingPath
        let resolved = URL(fileURLWithPath: given).resolvingSymlinksInPath().path
        return given == resolved ? [given] : [given, resolved]
    }

    static func refusal(for directory: String, decision: Decision) -> String? {
        switch decision {
        case .trusted:
            return nil
        case .untrusted:
            return "Claude Code has not trusted \(directory): trust it first (open claude there "
                + "once and accept the dialog) or use a folder it already trusts"
        case .unreadable(let reason):
            return "cannot tell whether Claude Code trusts \(directory) (\(reason)): "
                + "trust it first or use a folder it already trusts"
        }
    }
}
