import Foundation

/// Locations under `~/.claude/galaxy` this app reads.
///
/// Most of the app still builds these inline — a dozen `NSHomeDirectory() +
/// "/.claude/galaxy/…"` literals for the tool binaries, the socket, the log and
/// the ledger. This is not a migration of those; it is somewhere for a path
/// that is neither a binary nor a fixed runtime file to live, so the next one
/// has an obvious home rather than becoming a thirteenth literal.
enum GalaxyPaths {
    static var root: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/galaxy", isDirectory: true)
    }

    /// Where a custom source-reader theme lives, if one has been written.
    ///
    /// Not created at launch: an absent directory is the ordinary state and
    /// means the reader stays on the stock GitHub themes.
    static var sourceThemeDir: URL {
        root.appendingPathComponent("source", isDirectory: true)
    }
}
