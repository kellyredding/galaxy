import SwiftUI

/// Displays recent conversation turns in reverse
/// chronological order, sourced from timeline turn events.
///
/// The pairing itself lives in `TurnPairing`, shared with the
/// stopped session's history panel so the two surfaces cannot
/// disagree about which half of a turn supplies the prompt or
/// what a truncated record means.
struct LedgerLastActivityView: View {
    @ObservedObject var session: Session
    let turnEvents: [TimelineEvent]?
    let isLoading: Bool

    @Environment(\.chromeFontSize) private var chromeFontSize
    private var fontSize: ChromeFontSize {
        ChromeFontSize(chromeFontSize)
    }

    @State private var expandedFields: Set<String> = []

    /// Paired turns built from raw timeline events, most
    /// recent first.
    private var turns: [TurnPair] {
        guard let events = turnEvents else { return [] }
        return TurnPairing.pairs(
            from: events,
            limit: 5,
            order: .reverseChronological
        )
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
                        id: \.element.id
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
            switch turn.userMessage {
            case .text(let msg):
                sectionBlock("User") {
                    truncatableText(
                        msg,
                        key: "turn_\(index)_user"
                    )
                }
            case .unreadable:
                sectionBlock("User") { unavailableText }
            case .absent:
                EmptyView()
            }

            // Assistant response
            switch turn.assistantResponse {
            case .text(let resp):
                sectionBlock("Assistant") {
                    truncatableText(
                        resp,
                        key: "turn_\(index)_asst"
                    )
                }
            case .unreadable:
                sectionBlock("Assistant") { unavailableText }
            case .absent:
                if turn.endEvent.eventType
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
    }

    /// A payload the recorder truncated past the pipe buffer.
    /// Distinct from "(no response)": something was said, and
    /// the record of it did not survive being written.
    private var unavailableText: some View {
        Text("(content unavailable — record truncated)")
            .chromeFont(size: fontSize.caption2)
            .foregroundColor(.secondary)
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
