import Foundation

/// Fire-and-forget runner for galaxy-ledger commands the app issues
/// rather than reads. Reads live in LedgerQueryService, which waits on
/// stdout; nothing here produces any.
enum LedgerCommandService {
    private static let binaryPath =
        "\(NSHomeDirectory())/.claude/galaxy/bin/galaxy-ledger"

    /// Start the turn a message queued mid-turn is about to become.
    ///
    /// Claude Code fires UserPromptSubmit for a queued message at once
    /// and never again when it dequeues, and no Stop hook fires on an
    /// interrupt — so nothing else marks that turn beginning until the
    /// agent produces its first line of text, 17 seconds later in the
    /// measurement that prompted this.
    ///
    /// Whether there is anything to open is the ledger's call: it holds
    /// the prompt set aside at submit time, and it reads the transcript
    /// to see whether Claude Code still has that message queued — a
    /// queued message is as often folded into the running turn, and
    /// opening a turn for one of those is worse than opening none.
    /// Call it on every interrupt and let it decide.
    ///
    /// `endedAt` is the keystroke's instant. A dequeue before it delivered
    /// the message into the interrupted turn; one after is the message
    /// starting its own.
    static func openQueuedTurn(
        claudeSessionId: String,
        transcriptPath: String,
        endedAt: Date,
        source: String
    ) {
        run(args: [
            "open-queued-turn",
            "--session", claudeSessionId,
            "--transcript-path", transcriptPath,
            "--ended-at", timestampFormatter.string(from: endedAt),
            "--source", source,
        ])
    }

    /// Milliseconds are the point: most dequeues land within a second of
    /// the turn they follow.
    private static let timestampFormatter: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt
    }()

    private static func run(args: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            GalaxyLog.events(
                "ledger command failed to launch: "
                + "\(args.first ?? "?") — "
                + error.localizedDescription
            )
        }
    }
}
