import Foundation
import Galactic

/// Records timeline events by running galaxy-timeline. Fire-and-forget,
/// except `recordReturningID`, which answers the new event's id.
enum TimelineService {
    private static let binaryPath =
        "\(NSHomeDirectory())/.claude/galaxy/bin/galaxy-timeline"

    /// Record a timeline event with detail data passed as a
    /// CLI argument. Use for small payloads only.
    ///
    /// `onRecorded` runs once the event is written, off the caller's
    /// thread. It exists for the caller that has a second event to
    /// record and needs the two to reach Galaxy in order — recording
    /// is a subprocess, and two of them race.
    static func record(
        ledgerSessionId: Int64,
        eventType: String,
        source: String,
        durationIdentifier: String? = nil,
        detailData: [String: Any]? = nil,
        onRecorded: (() -> Void)? = nil
    ) {
        var args = [
            "record",
            "--ledger-session-id", String(ledgerSessionId),
            "--event-type", eventType,
            "--source", source,
        ]

        if let durationIdentifier = durationIdentifier {
            args.append("--duration-identifier")
            args.append(durationIdentifier)
        }

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

        launchFireAndForget(args: args, onExit: onRecorded)
    }

    /// Record a timeline event with detail data piped via
    /// stdin. Use for large payloads (annotations, notes)
    /// that may exceed CLI argument limits.
    static func recordViaStdin(
        ledgerSessionId: Int64,
        eventType: String,
        source: String,
        durationIdentifier: String? = nil,
        detailData: [String: Any]
    ) {
        var args = [
            "record",
            "--ledger-session-id", String(ledgerSessionId),
            "--event-type", eventType,
            "--source", source,
            "--detail-data-stdin",
        ]

        if let durationIdentifier = durationIdentifier {
            args.append("--duration-identifier")
            args.append(durationIdentifier)
        }

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

    /// Record an event and answer its id on the main queue, or nil when it was
    /// not recorded. For a caller that has to point something at the event.
    static func recordReturningID(
        ledgerSessionId: Int64,
        eventType: String,
        source: String,
        detailData: [String: Any],
        completion: @escaping (Int64?) -> Void
    ) {
        let args = [
            "record",
            "--ledger-session-id", String(ledgerSessionId),
            "--event-type", eventType,
            "--source", source,
            "--detail-data-stdin",
            "--json",
        ]

        guard let jsonData = try? JSONSerialization.data(
            withJSONObject: detailData
        ) else {
            SessionSubmit.log("timeline record failed: \(eventType) detail not serializable")
            DispatchQueue.main.async { completion(nil) }
            return
        }

        ProcessRunner.run(
            executableURL: URL(fileURLWithPath: binaryPath),
            arguments: args,
            stdin: jsonData,
            timeout: 5
        ) { result in
            var id: Int64?
            switch result {
            case .success(let output):
                id = (try? JSONSerialization.jsonObject(with: output))
                    .flatMap { $0 as? [String: Any] }
                    .flatMap { ($0["id"] as? NSNumber)?.int64Value }
                if id == nil {
                    SessionSubmit.log("timeline record \(eventType): no id in output")
                }
            case .failure(let error):
                SessionSubmit.log(
                    "timeline record \(eventType) failed: \(error.localizedDescription)")
            }
            DispatchQueue.main.async { completion(id) }
        }
    }

    private static func launchFireAndForget(
        args: [String],
        stdinData: Data? = nil,
        onExit: (() -> Void)? = nil
    ) {
        let process = Process()
        process.executableURL = URL(
            fileURLWithPath: binaryPath
        )
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        if let onExit = onExit {
            process.terminationHandler = { _ in onExit() }
        }

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
                // Nothing was recorded, so there is nothing left for
                // the follow-up to arrive ahead of.
                onExit?()
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
                onExit?()
            }
        }
    }
}
