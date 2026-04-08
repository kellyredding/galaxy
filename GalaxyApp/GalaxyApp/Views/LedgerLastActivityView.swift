import SwiftUI

/// Displays recent conversation turns in reverse
/// chronological order, sourced from timeline turn events.
/// Each turn shows the user message (from turn:initiated)
/// and assistant response (from the turn-end event).
struct LedgerLastActivityView: View {
    @ObservedObject var session: Session
    let turnEvents: [TimelineEvent]?
    let isLoading: Bool

    @Environment(\.chromeFontSize) private var chromeFontSize
    private var fontSize: ChromeFontSize {
        ChromeFontSize(chromeFontSize)
    }

    @State private var expandedFields: Set<String> = []

    /// Paired turns built from raw timeline events.
    /// Groups initiated + end events by durationIdentifier,
    /// returns up to 5 pairs, most recent first.
    private var turns: [TurnPair] {
        guard let events = turnEvents else { return [] }

        // Index initiated events by durationIdentifier
        var initiatedByDuration: [String: TimelineEvent] =
            [:]
        // Collect end events in order (already reversed
        // from CLI)
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
            let userMessage = initiated
                .flatMap { parseDetailField($0, "user_message") }
            let assistantResponse =
                parseDetailField(
                    endEvent, "assistant_response"
                )
            pairs.append(
                TurnPair(
                    initiatedEvent: initiated,
                    endEvent: endEvent,
                    userMessage: userMessage,
                    assistantResponse: assistantResponse
                )
            )
            if pairs.count >= 5 { break }
        }
        return pairs
    }

    var body: some View {
        ScrollView {
            if isLoading && turnEvents == nil {
                HStack {
                    Spacer()
                    ProgressView()
                        .scaleEffect(0.8)
                        .padding()
                    Spacer()
                }
            } else if turns.isEmpty {
                Text("No turns recorded")
                    .chromeFont(size: fontSize.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(
                    alignment: .leading,
                    spacing: 16
                ) {
                    ForEach(
                        Array(turns.enumerated()),
                        id: \.offset
                    ) { index, turn in
                        turnBlock(
                            turn,
                            index: index
                        )
                        if index < turns.count - 1 {
                            Divider()
                                .padding(.vertical, 4)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Turn Block

    private func turnBlock(
        _ turn: TurnPair,
        index: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: timestamp + status badge
            HStack(spacing: 8) {
                Text(
                    formatDate(
                        turn.endEvent.occurredAt
                    )
                )
                .chromeFont(
                    size: fontSize.caption2
                )
                .foregroundColor(.secondary)

                turnStatusBadge(
                    turn.endEvent.eventType
                )
            }

            // User message
            if let msg = turn.userMessage,
               !msg.isEmpty
            {
                sectionBlock("User") {
                    truncatableText(
                        msg,
                        key: "turn_\(index)_user"
                    )
                }
            }

            // Assistant response
            if let resp = turn.assistantResponse,
               !resp.isEmpty
            {
                sectionBlock("Assistant") {
                    truncatableText(
                        resp,
                        key: "turn_\(index)_asst"
                    )
                }
            } else if turn.endEvent.eventType
                != "turn:completed"
            {
                sectionBlock("Assistant") {
                    Text("(no response)")
                        .chromeFont(
                            size: fontSize.caption2
                        )
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Status Badge

    private func turnStatusBadge(
        _ eventType: String
    ) -> some View {
        let (label, color): (String, Color) = {
            switch eventType {
            case "turn:completed":
                return ("completed", .green)
            case "turn:failed":
                return ("failed", .red)
            case "turn:interrupted":
                return ("interrupted", .orange)
            case "turn:abandoned":
                return ("abandoned", .secondary)
            default:
                return (eventType, .secondary)
            }
        }()

        return Text(label)
            .chromeFont(size: fontSize.caption2)
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(color.opacity(0.12))
            )
    }

    // MARK: - Layout Helpers

    private func sectionBlock<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .chromeFont(
                    size: fontSize.caption2,
                    weight: .semibold
                )
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            content()
        }
    }

    private func truncatableText(
        _ text: String,
        key: String
    ) -> some View {
        let isExpanded = expandedFields.contains(key)
        let needsTruncation = text.count > 500
        let display = (!isExpanded && needsTruncation)
            ? String(text.prefix(500)) + "..."
            : text

        return VStack(alignment: .leading, spacing: 2) {
            Text(display)
                .chromeFontMono(
                    size: fontSize.caption2
                )
                .foregroundColor(.primary)
                .textSelection(.enabled)
            if needsTruncation {
                Button(
                    isExpanded
                        ? "Show less"
                        : "Show more"
                ) {
                    if isExpanded {
                        expandedFields.remove(key)
                    } else {
                        expandedFields.insert(key)
                    }
                }
                .buttonStyle(.plain)
                .chromeFont(size: fontSize.caption2)
                .foregroundColor(.accentColor)
            }
        }
    }

    // MARK: - Detail Data Parsing

    /// Extract a string field from an event's
    /// detail_data JSON.
    private func parseDetailField(
        _ event: TimelineEvent,
        _ field: String
    ) -> String? {
        guard let json = event.detailData,
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization
                  .jsonObject(with: data)
                  as? [String: Any]
        else { return nil }
        return dict[field] as? String
    }

    // MARK: - Formatting

    private static let displayDateFormatter:
        DateFormatter = {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            return f
        }()

    private func formatDate(_ date: Date) -> String {
        Self.displayDateFormatter.string(from: date)
    }
}

// MARK: - Turn Pair Model

struct TurnPair {
    let initiatedEvent: TimelineEvent?
    let endEvent: TimelineEvent
    let userMessage: String?
    let assistantResponse: String?
}
