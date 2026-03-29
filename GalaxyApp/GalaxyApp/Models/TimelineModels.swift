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
    case context
    case scrollback
    case snapshot
    case agent

    var displayName: String {
        switch self {
        case .session: return "Session"
        case .context: return "Context"
        case .scrollback: return "Scrollback"
        case .snapshot: return "Snapshot"
        case .agent: return "Agent"
        }
    }

    var color: Color {
        switch self {
        case .session: return .orange
        case .context: return .purple
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
