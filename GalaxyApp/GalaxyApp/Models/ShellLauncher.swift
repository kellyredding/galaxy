import Foundation
import Galactic

/// Launch parameters for the Shell pane: where its login shell starts, and
/// what environment it runs with. Pure functions, no state.
///
/// The login-shell lookup and the environment capture live in
/// `ShellEnvironment`. They answer a different question — what the user's
/// profile exports — and are consumed by the session-spawn path rather than
/// by the pane, which runs the profile itself.
enum ShellLauncher {
    /// Resolve the cwd to launch the shell in for a given
    /// session. Fallback chain:
    ///
    /// 1. `session.ledgerCwd` — where Claude has most
    ///    recently `cd`'d
    /// 2. `session.ledgerProjectDir` — the project root
    ///    from ledger enrichment
    /// 3. `session.workingDirectory` — Galaxy-persisted
    ///    initial cwd
    /// 4. `$HOME`
    ///
    /// Skips any entry that doesn't exist on disk, so a
    /// stale ledger cwd pointing at a deleted directory
    /// falls through cleanly.
    static func resolveCwd(for session: Session?) -> String {
        let fm = FileManager.default
        if let cwd = session?.ledgerCwd,
           !cwd.isEmpty,
           fm.fileExists(atPath: cwd) {
            return cwd
        }
        if let projectDir = session?.ledgerProjectDir,
           !projectDir.isEmpty,
           fm.fileExists(atPath: projectDir) {
            return projectDir
        }
        if let wd = session?.workingDirectory,
           !wd.isEmpty,
           fm.fileExists(atPath: wd) {
            return wd
        }
        return NSHomeDirectory()
    }

    /// Build the environment array for the shell. Starts
    /// from Galaxy's inherited environment and:
    ///
    /// - Strips `TERM` (forced to `xterm-256color` below),
    /// - Strips the Claude context variables, so the shell
    ///   doesn't inherit Galaxy's own Claude context and
    ///   think it is nested inside a session. `CLAUDE_CODE_*`
    ///   matters even though the pane is spawned directly,
    ///   because launching Galaxy.app from inside a Claude
    ///   Code session leaks that family into Galaxy's own
    ///   environment,
    /// - Sets `LANG` to a UTF-8 locale when unset. macOS
    ///   GUI apps don't inherit `LANG` from launchd, so a
    ///   shell launched from Galaxy starts with no locale
    ///   — `less` (git's pager) then renders non-ASCII
    ///   bytes as `<HEX>` escapes. Terminal.app and iTerm2
    ///   set this themselves; we do the same,
    /// - Leaves everything else alone — `PATH`,
    ///   `COLORTERM`, user-defined vars all pass through.
    ///   The login shell's own `.zprofile` /
    ///   `.bash_profile` rebuilds `PATH` correctly, and
    ///   any `LANG`/`LC_*` the user sets there wins over
    ///   our default.
    static func buildEnvironment() -> [String] {
        let inherited = ProcessInfo.processInfo.environment
        var env = inherited.map { "\($0.key)=\($0.value)" }
        env = env.filter {
            !$0.hasPrefix("TERM=") &&
            !TerminalIdentity.isInherited($0) &&
            !$0.hasPrefix("CLAUDECODE=") &&
            !$0.hasPrefix("CLAUDE_CLI_SESSION_ID=") &&
            !$0.hasPrefix("CLAUDE_CODE_")
        }
        env.append("TERM=xterm-256color")

        // The same identity the session pane claims, so a Claude started by
        // hand here answers to the configured keystrokes rather than falling
        // back to Claude Code's defaults. Previously this pane passed the
        // launching terminal's identity straight through, which made the
        // behaviour depend on how Galaxy itself was started.
        //
        // The claim reaches every program in this shell, not just Claude — see
        // TerminalIdentity for what that costs and why it is affordable.
        env.append(TerminalIdentity.declaration)
        if inherited["LANG"]?.isEmpty ?? true {
            env.append("LANG=\(defaultUtf8Locale())")
        }
        return env
    }

    /// Pick a sensible UTF-8 locale for `LANG` when nothing
    /// is inherited. Derives from `Locale.current` —
    /// typically `en_US` on a US English install — and
    /// appends `.UTF-8`. Strips any `@modifier` suffix
    /// (e.g. `en_US@rg=usc`) since `LANG` doesn't accept
    /// those. Falls back to `en_US.UTF-8` if the identifier
    /// doesn't look like a standard `xx_YY` locale.
    private static func defaultUtf8Locale() -> String {
        let id = Locale.current.identifier
        let core = id.split(separator: "@")
            .first.map(String.init) ?? ""
        if core.contains("_") && !core.isEmpty {
            return "\(core).UTF-8"
        }
        return "en_US.UTF-8"
    }
}
