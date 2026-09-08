import Foundation

// MARK: - CLI JSON Response

struct TimelineEventsResponse: Codable {
    let events: [TimelineEvent]
}

/// A single timeline event decoded from CLI JSON output.
///
/// Foundation-only, and kept apart from the timeline's layout types so
/// the pairing rules beside it can be compiled — and asserted — without
/// SwiftUI. `TimelineModels.swift` holds everything with a pixel in it.
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
