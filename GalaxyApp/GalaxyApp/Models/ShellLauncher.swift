import Foundation

/// Helpers for launching an interactive login shell inside
/// the Shell pane. Pure functions — no state, safe to call
/// from anywhere.
enum ShellLauncher {
    /// Resolve the user's login shell from the password
    /// database. Falls back to `/bin/zsh` if the lookup
    /// fails for any reason (extremely unlikely on a
    /// normally-configured macOS install).
    static func userLoginShell() -> String {
        let uid = getuid()
        var pwd = passwd()
        var result: UnsafeMutablePointer<passwd>? = nil
        var buffer = [CChar](repeating: 0, count: 1024)
        let rc = getpwuid_r(
            uid, &pwd, &buffer, buffer.count, &result
        )
        if rc == 0, result != nil,
           let shellPtr = pwd.pw_shell {
            let shell = String(cString: shellPtr)
            if !shell.isEmpty {
                return shell
            }
        }
        return "/bin/zsh"
    }

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
    /// - Strips `CLAUDECODE` and `CLAUDE_CLI_SESSION_ID`
    ///   so the shell doesn't inherit Galaxy's Claude
    ///   context (prevents the shell from thinking it's
    ///   nested inside a Claude session),
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
            !$0.hasPrefix("CLAUDECODE=") &&
            !$0.hasPrefix("CLAUDE_CLI_SESSION_ID=")
        }
        env.append("TERM=xterm-256color")
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
