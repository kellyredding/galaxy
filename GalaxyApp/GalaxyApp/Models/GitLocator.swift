import Foundation

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
        guard let env = ShellEnvironment.loginShellEnvironment(),
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
