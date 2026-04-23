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
    /// - Leaves everything else alone — `LANG`, `PATH`,
    ///   `COLORTERM`, user-defined vars all pass through.
    ///   The login shell's own `.zprofile` /
    ///   `.bash_profile` rebuilds `PATH` correctly.
    static func buildEnvironment() -> [String] {
        var env = ProcessInfo.processInfo.environment.map {
            "\($0.key)=\($0.value)"
        }
        env = env.filter {
            !$0.hasPrefix("TERM=") &&
            !$0.hasPrefix("CLAUDECODE=") &&
            !$0.hasPrefix("CLAUDE_CLI_SESSION_ID=")
        }
        env.append("TERM=xterm-256color")
        return env
    }
}
