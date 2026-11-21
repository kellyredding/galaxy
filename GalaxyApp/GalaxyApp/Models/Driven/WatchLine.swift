import Foundation

/// One event notification on galaxy-watch.sock: a signal, not a payload. The
/// subscriber reads details from the timeline row `event_id` names.
enum WatchLine {
    private static let timelinePrefix = "timeline."

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    /// A timeline envelope's `ref` is the row it was written to; nothing else
    /// carries a row, so its event id is null. `detail` is for the events
    /// Galaxy raises with no row to read, so their facts travel on the line.
    static func encode(
        event: String, ref: String?, ts: Int64, sessionID: String, detail: [String: Any]? = nil
    ) -> Data {
        let isTimeline = event.hasPrefix(timelinePrefix)
        let eventID: Any = isTimeline ? (ref.flatMap { Int64($0) } ?? NSNull()) : NSNull()
        let type = isTimeline ? String(event.dropFirst(timelinePrefix.count)) : event
        var object: [String: Any] = [
            "v": 1,
            "event_id": eventID,
            "type": type,
            "session_id": sessionID,
            "occurred_at": iso8601.string(from: Date(timeIntervalSince1970: TimeInterval(ts))),
        ]
        if let detail { object["detail"] = detail }
        guard JSONSerialization.isValidJSONObject(object) else { return Data() }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    static func subscribed(_ sessionID: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["v": 1, "subscribed": sessionID])) ?? Data()
    }

    static func error(_ message: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["v": 1, "error": message])) ?? Data()
    }
}

/// The one line a subscriber sends: `{"v":1,"subscribe":"<session id>"}`.
enum WatchSubscribeRequest {
    /// The longest a subscribe line can reasonably be; anything longer
    /// without a newline is not a subscriber.
    static let maxBytes = 4096

    /// The session id as the subscriber wrote it, echoed back verbatim in the
    /// acknowledgement, or nil for anything that is not a subscribe request.
    static func sessionID(from line: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            let id = object["subscribe"] as? String,
            UUID(uuidString: id) != nil
        else { return nil }
        return id
    }
}

/// Bounds what one subscriber may have outstanding, so a reader that stops
/// reading costs a fixed amount and is then let go. Dropping is always safe:
/// the subscriber reconnects and fills the gap from the timeline.
struct WatchBackpressure {
    static let capacity = 256
    static let maxSubscribers = 32

    private(set) var outstanding = 0

    /// Counts a line handed to the connection; false once the subscriber has
    /// fallen too far behind to keep.
    mutating func sent() -> Bool {
        outstanding += 1
        return outstanding <= Self.capacity
    }

    mutating func delivered() {
        outstanding = max(0, outstanding - 1)
    }
}
