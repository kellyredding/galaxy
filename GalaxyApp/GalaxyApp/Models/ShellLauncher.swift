import Foundation

/// Helpers for the user's login shell: launching it interactively
/// in the Shell pane, and capturing its environment for sessions
/// that Galaxy spawns directly. Pure functions — no state, safe to
/// call from anywhere (the environment capture must run off the main
/// thread; see `loginShellEnvironment`).
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

    /// Capture the environment of the user's login shell as an array
    /// of "KEY=VALUE" strings — the same environment a terminal (the
    /// Shell pane) would have. Galaxy spawns Claude sessions directly
    /// (not via a shell), so without this they inherit launchd's
    /// minimal env and miss everything the login profile exports:
    /// secrets, the real PATH, locale, tool shims.
    ///
    /// Delegates entirely to the user's login shell (resolved from the
    /// passwd DB) run as an INTERACTIVE LOGIN shell — `-i -l` — so the
    /// capture matches the Shell pane's `-il` across shells (notably
    /// zsh, whose `.zshrc` is interactive-only and would be skipped by
    /// a non-interactive login shell). Galaxy makes no assumptions
    /// about which shell or which dotfiles the user runs; it just asks
    /// the shell what its environment is.
    ///
    /// `env -0` emits NUL-delimited records so values containing
    /// newlines survive intact. stdin is fed empty so an interactive
    /// shell sees EOF immediately and never blocks. stderr (prompt /
    /// MOTD noise) is surfaced by the runner only on non-zero exit, so
    /// it never pollutes the parsed stdout.
    ///
    /// Returns nil on any failure (non-zero exit, timeout, undecodable
    /// output) so callers fall back to the process's own environment.
    ///
    /// Runs a subprocess synchronously — call OFF the main thread.
    static func loginShellEnvironment(
        timeout: TimeInterval = 10
    ) -> [String]? {
        let shell = userLoginShell()
        guard let data = try? ProcessRunner.runSync(
            executableURL: URL(fileURLWithPath: shell),
            arguments: ["-i", "-l", "-c", "env -0"],
            stdin: Data(),   // EOF on stdin → interactive shell won't block
            timeout: timeout
        ) else {
            return nil
        }

        // Split on NUL; keep only well-formed, decodable KEY=VALUE records.
        let entries = data
            .split(separator: 0, omittingEmptySubsequences: true)
            .compactMap { String(data: Data($0), encoding: .utf8) }
            .filter { $0.contains("=") }

        return entries.isEmpty ? nil : entries
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
            !TerminalIdentity.isInherited($0) &&
            !$0.hasPrefix("CLAUDECODE=") &&
            !$0.hasPrefix("CLAUDE_CLI_SESSION_ID=")
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

/// Resolves the git executable Galaxy should use for repository
/// queries, decoupled from Xcode. A GUI app launched by launchd
/// inherits only launchd's minimal PATH, so a bare `git` — or the
/// `/usr/bin/git` shim — resolves through xcode-select to Xcode's
/// bundled git rather than the git the user actually runs in their
/// terminal. That mismatch means version drift, and on a machine
/// with no Command Line Tools it triggers the install prompt.
///
/// The path is resolved once on first use and cached for the app's
/// lifetime (git can't relocate mid-session). Because the login-shell
/// fallback spawns a subprocess, the first access must happen off the
/// main thread — StatusLineService's callers already run on a
/// background queue, and the common case never reaches the fallback.
enum GitLocator {
    /// Absolute path to the resolved git executable. Computed once,
    /// then cached (static-let init is thread-safe).
    static let gitPath: String = resolve()

    /// The xcode-select shim. Always present on macOS, so it is the
    /// guaranteed floor. Paired with --no-optional-locks even this
    /// cannot collide on the index lock, so it is a safe last resort.
    private static let fallback = "/usr/bin/git"

    private static func resolve() -> String {
        let fm = FileManager.default

        // 1. Well-known Homebrew locations — the overwhelming common
        // case, resolved with a couple of stat() calls and no
        // subprocess.
        let wellKnown = [
            "/opt/homebrew/bin/git",  // Apple Silicon Homebrew
            "/usr/local/bin/git",     // Intel Homebrew / manual install
        ]
        for path in wellKnown where fm.isExecutableFile(atPath: path) {
            return path
        }

        // 2. The user's real login-shell PATH — catches mise, asdf,
        // nix, MacPorts, and anything else, since it asks the user's
        // own shell what git it resolves.
        if let path = gitInLoginShellPath(fm) {
            return path
        }

        // 3. Guaranteed floor.
        return fallback
    }

    /// Pull PATH from the login-shell environment and return the first
    /// directory holding an executable `git`. Nil if the capture fails
    /// or no git is found on that PATH.
    private static func gitInLoginShellPath(
        _ fm: FileManager
    ) -> String? {
        guard let env = ShellLauncher.loginShellEnvironment(),
              let pathEntry = env.first(where: {
                  $0.hasPrefix("PATH=")
              })
        else { return nil }

        let pathValue = pathEntry.dropFirst("PATH=".count)
        for dir in pathValue.split(separator: ":") where !dir.isEmpty {
            let candidate = "\(dir)/git"
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
