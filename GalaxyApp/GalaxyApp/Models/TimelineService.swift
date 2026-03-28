import Foundation

/// Fire-and-forget timeline event recorder.
/// Spawns galaxy-timeline as a detached subprocess — no stdout
/// capture, no process tracking, no error propagation.
enum TimelineService {
    private static let binaryPath =
        "\(NSHomeDirectory())/.claude/galaxy/bin/galaxy-timeline"

    /// Record a timeline event with detail data passed as a
    /// CLI argument. Use for small payloads only.
    static func record(
        ledgerSessionId: Int64,
        eventType: String,
        source: String,
        detailData: [String: Any]? = nil
    ) {
        var args = [
            "record",
            "--ledger-session-id", String(ledgerSessionId),
            "--event-type", eventType,
            "--source", source,
        ]

        if let detailData = detailData,
           let jsonData = try? JSONSerialization.data(
               withJSONObject: detailData
           ),
           let jsonString = String(
               data: jsonData, encoding: .utf8
           ) {
            args.append("--detail-data")
            args.append(jsonString)
        }

        launchFireAndForget(args: args)
    }

    /// Record a timeline event with detail data piped via
    /// stdin. Use for large payloads (annotations, notes)
    /// that may exceed CLI argument limits.
    static func recordViaStdin(
        ledgerSessionId: Int64,
        eventType: String,
        source: String,
        detailData: [String: Any]
    ) {
        let args = [
            "record",
            "--ledger-session-id", String(ledgerSessionId),
            "--event-type", eventType,
            "--source", source,
            "--detail-data-stdin",
        ]

        guard let jsonData = try? JSONSerialization.data(
            withJSONObject: detailData
        ) else {
            NSLog(
                "TimelineService: failed to serialize "
                + "detail data for %@",
                eventType
            )
            return
        }

        launchFireAndForget(
            args: args, stdinData: jsonData
        )
    }

    private static func launchFireAndForget(
        args: [String],
        stdinData: Data? = nil
    ) {
        let process = Process()
        process.executableURL = URL(
            fileURLWithPath: binaryPath
        )
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        if let stdinData = stdinData {
            let pipe = Pipe()
            process.standardInput = pipe
            do {
                try process.run()
                // Write stdin on background thread to
                // avoid blocking if pipe buffer is full
                DispatchQueue.global(qos: .utility).async {
                    pipe.fileHandleForWriting.write(stdinData)
                    pipe.fileHandleForWriting.closeFile()
                }
            } catch {
                NSLog(
                    "TimelineService: launch failed: %@",
                    error.localizedDescription
                )
            }
        } else {
            process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                NSLog(
                    "TimelineService: launch failed: %@",
                    error.localizedDescription
                )
            }
        }
    }
}
