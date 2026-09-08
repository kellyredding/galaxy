import Foundation

/// One field of a turn's recorded detail.
///
/// `unreadable` is not hypothetical. The ledger hooks pipe detail_data
/// into `galaxy-timeline record --detail-data-stdin` with a
/// non-blocking spawn and exit without waiting, so a payload larger
/// than the pipe buffer lands truncated mid-string and no longer parses
/// as JSON. Folding that into `absent` renders a blank where content
/// existed, which on a stopped session's history is the only context
/// there is.
enum TurnText: Equatable {
    case text(String)
    case absent
    case unreadable
}

/// Which end of the returned list is the newest turn.
enum TurnOrder {
    case chronological
    case reverseChronological
}

/// A user prompt and the response it drew, recovered from the two
/// timeline events that bracket a turn.
struct TurnPair: Identifiable {
    let initiatedEvent: TimelineEvent?
    let endEvent: TimelineEvent
    let userMessage: TurnText
    let assistantResponse: TurnText

    var id: Int64 { endEvent.id }
}

enum TurnPairing {
    /// Pair turn events by `durationIdentifier`.
    ///
    /// Input is the CLI's `--reverse` output — newest first — because
    /// that is the only way to ask for the most recent N. The caller
    /// says which order it wants back.
    static func pairs(
        from events: [TimelineEvent],
        limit: Int,
        order: TurnOrder
    ) -> [TurnPair] {
        var initiatedByDuration: [String: TimelineEvent] = [:]
        var endEvents: [TimelineEvent] = []

        for event in events {
            if event.eventType == "turn:initiated" {
                if let did = event.durationIdentifier {
                    initiatedByDuration[did] = event
                }
            } else {
                endEvents.append(event)
            }
        }

        var pairs: [TurnPair] = []
        for endEvent in endEvents {
            let initiated = endEvent
                .durationIdentifier
                .flatMap { initiatedByDuration[$0] }

            // The prompt is on the initiated event, but a turn-end
            // event repeats it. Reading the end event first means a
            // pair whose initiated half fell outside the fetch window
            // still shows what was asked.
            let userMessage = firstReadable(
                in: [endEvent, initiated].compactMap { $0 },
                field: "user_message"
            )

            pairs.append(
                TurnPair(
                    initiatedEvent: initiated,
                    endEvent: endEvent,
                    userMessage: userMessage,
                    assistantResponse: detailField(
                        endEvent, "assistant_response"
                    )
                )
            )
            if pairs.count >= limit { break }
        }

        switch order {
        case .reverseChronological: return pairs
        case .chronological: return pairs.reversed()
        }
    }

    /// Extract a string field from an event's detail_data JSON.
    static func detailField(
        _ event: TimelineEvent,
        _ field: String
    ) -> TurnText {
        guard let json = event.detailData, !json.isEmpty else {
            return .absent
        }
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization
                  .jsonObject(with: data),
              let dict = object as? [String: Any]
        else { return .unreadable }
        guard let value = dict[field] as? String,
              !value.isEmpty
        else { return .absent }
        return .text(value)
    }

    /// The first event carrying this field, preferring readable text
    /// but remembering that something was there but truncated.
    private static func firstReadable(
        in events: [TimelineEvent],
        field: String
    ) -> TurnText {
        var fallback: TurnText = .absent
        for event in events {
            switch detailField(event, field) {
            case .text(let value):
                return .text(value)
            case .unreadable:
                fallback = .unreadable
            case .absent:
                continue
            }
        }
        return fallback
    }
}
