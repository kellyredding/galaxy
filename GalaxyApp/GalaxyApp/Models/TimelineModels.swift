import SwiftUI

// MARK: - CLI JSON Response

struct TimelineEventsResponse: Codable {
    let events: [TimelineEvent]
}

/// A single timeline event decoded from CLI JSON output.
struct TimelineEvent: Codable, Identifiable {
    let id: Int64
    let eventType: String
    let occurredAt: Date
    let source: String
    let durationIdentifier: String?
    let detailData: String?
    let createdAt: String
    let updatedAt: String
}

// MARK: - Resource Classification

/// Resource lanes for the swimlane diagram.
enum TimelineResource: Int, CaseIterable {
    case session = 0
    case turn
    case context
    case scrollback
    case snapshot
    case agent

    var displayName: String {
        switch self {
        case .session: return "Session"
        case .turn: return "Turn"
        case .context: return "Context"
        case .scrollback: return "Scrollback"
        case .snapshot: return "Snapshot"
        case .agent: return "Agent"
        }
    }

    var color: Color {
        switch self {
        case .session: return .orange
        case .turn: return .purple
        case .context: return .red
        case .scrollback: return .blue
        case .snapshot: return .teal
        case .agent: return .green
        }
    }
}

/// How an event type renders in the timeline.
enum RenderingMode {
    case point
    case durationStart
    case durationEnd
}

/// Maps an event type string to its resource lane and rendering mode.
struct EventRegistration {
    let resource: TimelineResource
    let mode: RenderingMode
}

/// Declarative registry of known event types.
let timelineEventRegistry: [String: EventRegistration] = [
    "session:started":     EventRegistration(resource: .session, mode: .durationStart),
    "session:ended":       EventRegistration(resource: .session, mode: .durationEnd),
    "session:resumed":     EventRegistration(resource: .session, mode: .durationStart),
    "context:cleared":     EventRegistration(resource: .context, mode: .point),
    "context:compacted":   EventRegistration(resource: .context, mode: .point),
    "scrollback:entered":  EventRegistration(resource: .scrollback, mode: .durationStart),
    "scrollback:exited":   EventRegistration(resource: .scrollback, mode: .durationEnd),
    "scrollback:reviewed": EventRegistration(resource: .scrollback, mode: .point),
    "snapshot:created":    EventRegistration(resource: .snapshot, mode: .point),
    "snapshot:reviewed":   EventRegistration(resource: .snapshot, mode: .point),
    "turn:initiated":      EventRegistration(resource: .turn, mode: .durationStart),
    "turn:completed":      EventRegistration(resource: .turn, mode: .durationEnd),
    "turn:failed":         EventRegistration(resource: .turn, mode: .durationEnd),
    "turn:interrupted":    EventRegistration(resource: .turn, mode: .durationEnd),
    "turn:continued":      EventRegistration(resource: .turn, mode: .point),
]

// MARK: - Layout Output Types

/// Complete layout output from the layout engine.
struct TimelineLayout {
    let segments: [LayoutSegment]
    let activeLanes: [TimelineResource]
    let totalHeight: CGFloat
    /// The snapped UTC date of the first hash (hash index 0).
    let originHash: Date
    /// Peak sub-column count per lane (across all segments).
    let laneMaxSubColumns: [Int]

    /// Find the break after a given segment, if any.
    func breakAfter(_ segment: LayoutSegment) -> LayoutBreak? {
        return segment.breakAfter
    }
}

/// A contiguous segment of active time between inactivity breaks.
struct LayoutSegment: Identifiable {
    let id = UUID()
    let startHash: Int
    let endHash: Int
    let hashCount: Int
    let height: CGFloat
    let placedDots: [PlacedDot]
    let placedBars: [PlacedBar]
    /// Break that follows this segment (nil for the last segment).
    let breakAfter: LayoutBreak?
}

/// A collapsed inactivity gap between segments.
struct LayoutBreak {
    let duration: TimeInterval
    let formattedDuration: String
}

/// A positioned point event (dot) ready to render.
struct PlacedDot {
    let event: TimelineEvent
    let resource: TimelineResource
    let laneIndex: Int
    let subColumn: Int
    let maxSubColumns: Int
    let hashIndex: Int  // relative to segment
}

/// A positioned duration event (bar) ready to render.
struct PlacedBar {
    let startEvent: TimelineEvent
    let endEvent: TimelineEvent?
    let resource: TimelineResource
    let laneIndex: Int
    let subColumn: Int
    let maxSubColumns: Int
    let startHashIndex: Int  // relative to segment
    let endHashIndex: Int    // relative to segment (or segment end if open)
    let isOpenEnded: Bool
    /// Whether this bar continues from a previous segment (no top cap).
    let continuesFromPrevious: Bool
    /// Whether this bar continues into a later segment (no bottom cap).
    let continuesIntoNext: Bool
}

// MARK: - Hover Hit-Testing

/// Identifies the timeline item currently under the
/// mouse cursor, used for tooltip display.
enum HoveredTimelineItem {
    case dot(PlacedDot)
    case bar(PlacedBar)

    var event: TimelineEvent {
        switch self {
        case .dot(let d): return d.event
        case .bar(let b): return b.startEvent
        }
    }

    var endEvent: TimelineEvent? {
        switch self {
        case .dot: return nil
        case .bar(let b): return b.endEvent
        }
    }

    var resource: TimelineResource {
        switch self {
        case .dot(let d): return d.resource
        case .bar(let b): return b.resource
        }
    }
}

// MARK: - Tooltip Formatting

/// Formats detail_data for tooltip display per event type.
enum TimelineTooltipFormatter {
    /// Human-readable event type label.
    static func label(
        for eventType: String
    ) -> String {
        switch eventType {
        case "session:started": return "Session Started"
        case "session:resumed": return "Session Resumed"
        case "session:ended": return "Session Ended"
        case "context:cleared": return "Context Cleared"
        case "context:compacted":
            return "Context Compacted"
        case "scrollback:entered":
            return "Scrollback Entered"
        case "scrollback:exited":
            return "Scrollback Exited"
        case "scrollback:reviewed":
            return "Scrollback Reviewed"
        case "snapshot:created":
            return "Snapshot Created"
        case "snapshot:reviewed":
            return "Snapshot Reviewed"
        case "turn:initiated":
            return "Turn Initiated"
        case "turn:completed":
            return "Turn Completed"
        case "turn:failed":
            return "Turn Failed"
        case "turn:interrupted":
            return "Turn Interrupted"
        case "turn:continued":
            return "Turn Continued"
        default: return eventType
        }
    }

    /// Parse detail_data JSON and return summary lines.
    static func detailLines(
        for eventType: String,
        detailData: String?
    ) -> [String] {
        guard let data = detailData,
            let jsonData = data.data(using: .utf8),
            let dict = try? JSONSerialization
                .jsonObject(with: jsonData)
                as? [String: Any]
        else { return [] }

        switch eventType {
        case "session:started":
            return sessionStartedLines(dict)
        case "session:resumed":
            return sessionResumedLines(dict)
        case "session:ended":
            return sessionEndedLines(dict)
        case "context:cleared", "context:compacted":
            return contextLines(dict)
        case "snapshot:created":
            return snapshotCreatedLines(dict)
        case "snapshot:reviewed":
            return snapshotReviewedLines(dict)
        case "scrollback:reviewed":
            return scrollbackReviewedLines(dict)
        case "scrollback:exited":
            return scrollbackExitedLines(dict)
        case "turn:initiated":
            return turnInitiatedLines(dict)
        case "turn:completed":
            return turnCompletedLines(dict)
        case "turn:failed":
            return turnFailedLines(dict)
        case "turn:interrupted":
            return turnInterruptedLines(dict)
        case "turn:continued":
            return turnContinuedLines(dict)
        default:
            return []
        }
    }

    // MARK: - Per-Type Formatters

    private static func sessionStartedLines(
        _ d: [String: Any]
    ) -> [String] {
        var lines: [String] = []
        if let cwd = d["cwd"] as? String {
            let short = abbreviatePath(cwd)
            lines.append("cwd: \(short)")
        }
        if let branch = d["git_branch"] as? String {
            lines.append("branch: \(branch)")
        }
        return lines
    }

    private static func sessionResumedLines(
        _ d: [String: Any]
    ) -> [String] {
        var lines: [String] = []
        if let cwd = d["cwd"] as? String {
            let short = abbreviatePath(cwd)
            lines.append("cwd: \(short)")
        }
        if let branch = d["git_branch"] as? String {
            lines.append("branch: \(branch)")
        }
        if let dc = d["decisions_count"] as? Int,
            dc > 0
        {
            lines.append("decisions: \(dc)")
        }
        if let lc = d["learnings_count"] as? Int,
            lc > 0
        {
            lines.append("learnings: \(lc)")
        }
        if let fc = d["files_count"] as? Int,
            fc > 0
        {
            lines.append("files: \(fc)")
        }
        return lines
    }

    private static func sessionEndedLines(
        _ d: [String: Any]
    ) -> [String] {
        var lines: [String] = []
        if let cost = d["cost_usd"] as? Double {
            lines.append(
                String(
                    format: "cost: $%.2f", cost
                )
            )
        } else if let cost = d["cost_usd"]
            as? String,
            let val = Double(cost)
        {
            lines.append(
                String(
                    format: "cost: $%.2f", val
                )
            )
        }
        if let pct = d["context_percentage"]
            as? Int
        {
            lines.append("context: \(pct)%")
        } else if let pct =
            d["context_percentage"] as? String
        {
            lines.append("context: \(pct)%")
        }
        if let tokens = d["tokens_used"] as? Int {
            lines.append(
                "tokens: \(formatNumber(tokens))"
            )
        }
        return lines
    }

    private static func contextLines(
        _ d: [String: Any]
    ) -> [String] {
        var lines: [String] = []
        if let dc = d["decisions_count"] as? Int {
            lines.append("decisions: \(dc)")
        }
        if let lc = d["learnings_count"] as? Int {
            lines.append("learnings: \(lc)")
        }
        if let ec = d["exchanges_count"] as? Int {
            lines.append("exchanges: \(ec)")
        }
        if let fe = d["files_edited_count"]
            as? Int
        {
            lines.append("files edited: \(fe)")
        }
        return lines
    }

    private static func snapshotCreatedLines(
        _ d: [String: Any]
    ) -> [String] {
        var lines: [String] = []
        if let num = d["snapshot_number"]
            as? Int
        {
            lines.append("#\(num)")
        }
        if let title = d["title"] as? String {
            let truncated = title.count > 40
                ? String(title.prefix(37)) + "…"
                : title
            lines.append(truncated)
        }
        return lines
    }

    private static func snapshotReviewedLines(
        _ d: [String: Any]
    ) -> [String] {
        var lines: [String] = []
        if let num = d["snapshot_number"]
            as? Int
        {
            lines.append("#\(num)")
        }
        if let title = d["title"] as? String {
            let truncated = title.count > 40
                ? String(title.prefix(37)) + "…"
                : title
            lines.append(truncated)
        }
        if let ac = d["annotation_count"]
            as? Int
        {
            lines.append(
                "\(ac) annotation\(ac == 1 ? "" : "s")"
            )
        }
        return lines
    }

    private static func scrollbackReviewedLines(
        _ d: [String: Any]
    ) -> [String] {
        var lines: [String] = []
        if let nc = d["note_count"] as? Int {
            lines.append(
                "\(nc) note\(nc == 1 ? "" : "s")"
            )
        }
        return lines
    }

    private static func scrollbackExitedLines(
        _ d: [String: Any]
    ) -> [String] {
        var lines: [String] = []
        if let reason = d["reason"] as? String {
            lines.append("reason: \(reason)")
        }
        if let nc = d["note_count"] as? Int,
            nc > 0
        {
            lines.append(
                "\(nc) note\(nc == 1 ? "" : "s")"
            )
        }
        return lines
    }

    // MARK: - Turn Formatters

    private static func turnInitiatedLines(
        _ d: [String: Any]
    ) -> [String] {
        var lines: [String] = []
        if let msg = d["user_message"] as? String {
            lines.append(truncate(msg, to: 80))
        }
        return lines
    }

    private static func turnCompletedLines(
        _ d: [String: Any]
    ) -> [String] {
        var lines: [String] = []
        if let msg = d["user_message"] as? String {
            lines.append(truncate(msg, to: 80))
        }
        if let followUps = d["follow_up_messages"]
            as? [[String: Any]],
            !followUps.isEmpty
        {
            let n = followUps.count
            lines.append(
                "+ \(n) follow-up\(n == 1 ? "" : "s")"
            )
        }
        if let resp = d["assistant_response"]
            as? String
        {
            lines.append(truncate(resp, to: 80))
        }
        return lines
    }

    private static func turnFailedLines(
        _ d: [String: Any]
    ) -> [String] {
        var lines: [String] = []
        if let msg = d["user_message"] as? String {
            lines.append(truncate(msg, to: 80))
        }
        if let followUps = d["follow_up_messages"]
            as? [[String: Any]],
            !followUps.isEmpty
        {
            let n = followUps.count
            lines.append(
                "+ \(n) follow-up\(n == 1 ? "" : "s")"
            )
        }
        lines.append("⚠ error")
        return lines
    }

    private static func turnInterruptedLines(
        _ d: [String: Any]
    ) -> [String] {
        var lines: [String] = []
        if let msg = d["user_message"] as? String {
            lines.append(truncate(msg, to: 80))
        }
        lines.append("⚠ interrupted")
        return lines
    }

    private static func turnContinuedLines(
        _ d: [String: Any]
    ) -> [String] {
        var lines: [String] = []
        if let resp = d["assistant_response"]
            as? String
        {
            lines.append(truncate(resp, to: 80))
        }
        return lines
    }

    // MARK: - Helpers

    private static func truncate(
        _ text: String, to maxLength: Int
    ) -> String {
        let cleaned = text
            .replacingOccurrences(
                of: "\n", with: " "
            )
            .trimmingCharacters(in: .whitespaces)
        if cleaned.count > maxLength {
            return String(
                cleaned.prefix(maxLength - 1)
            ) + "…"
        }
        return cleaned
    }

    private static func abbreviatePath(
        _ path: String
    ) -> String {
        let home = FileManager.default
            .homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~"
                + path.dropFirst(home.count)
        }
        return path
    }

    private static func formatNumber(
        _ n: Int
    ) -> String {
        if n >= 1_000_000 {
            return String(
                format: "%.1fM",
                Double(n) / 1_000_000
            )
        } else if n >= 1_000 {
            return String(
                format: "%.1fK",
                Double(n) / 1_000
            )
        }
        return "\(n)"
    }
}
