import Foundation
import Galactic

/// Captures the user's login-shell environment so a session Galaxy spawns
/// matches what a terminal gets — profile-exported secrets, the full PATH,
/// locale. Galaxy spawns Claude sessions directly (not via a shell), so
/// without this they inherit launchd's minimal environment and miss
/// everything the login profile exports.
///
/// The Shell pane needs no capture — it runs the profile itself; see
/// `ShellLauncher` for the parameters it launches with.
///
/// Pure functions, no state. The environment capture runs a subprocess
/// synchronously — call it OFF the main thread.
enum ShellEnvironment {
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
    /// Shell pane) would have.
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
}
