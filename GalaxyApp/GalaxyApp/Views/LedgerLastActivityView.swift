import SwiftUI

/// Schema-aware renderer for the last exchange(s) in a session.
/// Parses session.ledgerLastInteraction (JSON string) — supports both
/// legacy single-object and new array format. Displays User, Assistant,
/// and Summary sections with truncation controls and inline
/// decisions/learnings.
struct LedgerLastActivityView: View {
    @ObservedObject var session: Session

    @Environment(\.chromeFontSize) private var chromeFontSize
    private var fontSize: ChromeFontSize { ChromeFontSize(chromeFontSize) }

    /// Parsed exchange data — recomputed when ledgerLastInteraction changes.
    /// Tries array format first, falls back to single-object wrapped in array.
    private var exchanges: [LastExchange] {
        guard let json = session.ledgerLastInteraction,
              let data = json.data(using: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        // Try array format first (new)
        if let array = try? decoder.decode([LastExchange].self, from: data) {
            return array
        }
        // Fall back to single object (legacy)
        if let single = try? decoder.decode(LastExchange.self, from: data) {
            return [single]
        }
        return []
    }

    // Track expanded state per field, namespaced by exchange index
    @State private var expandedFields: Set<String> = []

    var body: some View {
        if exchanges.isEmpty {
            Text("No activity recorded")
                .chromeFont(size: fontSize.caption)
                .foregroundColor(.secondary)
                .padding(.vertical, 8)
        } else {
            VStack(alignment: .leading, spacing: 16) {
                // Render in reverse-chronological order (most recent first)
                let reversed = Array(exchanges.reversed())
                ForEach(Array(reversed.enumerated()), id: \.offset) { revIdx, exchange in
                    let exchangeNum = exchanges.count - revIdx
                    let prefix = "exchange_\(revIdx)"

                    if exchanges.count > 1 {
                        exchangeBlock(
                            exchange: exchange,
                            number: exchangeNum,
                            total: exchanges.count,
                            prefix: prefix
                        )
                        if revIdx < reversed.count - 1 {
                            Divider()
                                .padding(.vertical, 4)
                        }
                    } else {
                        singleExchangeBlock(exchange: exchange, prefix: prefix)
                    }
                }
            }
        }
    }

    // MARK: - Exchange Blocks

    /// Render a numbered exchange for multi-exchange display.
    private func exchangeBlock(
        exchange: LastExchange,
        number: Int,
        total: Int,
        prefix: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Exchange \(number) of \(total)")
                .chromeFont(size: fontSize.caption2, weight: .medium)
                .foregroundColor(.secondary)
                .textCase(.uppercase)

            userSection(exchange, prefix: prefix)
            assistantSection(exchange, prefix: prefix)
            if let summary = exchange.summary {
                summarySection(summary, prefix: prefix)
            }
        }
    }

    /// Render a single exchange (no numbering header).
    private func singleExchangeBlock(
        exchange: LastExchange,
        prefix: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            userSection(exchange, prefix: prefix)
            assistantSection(exchange, prefix: prefix)
            if let summary = exchange.summary {
                summarySection(summary, prefix: prefix)
            }
        }
    }

    // MARK: - User Section

    private func userSection(_ exchange: LastExchange, prefix: String) -> some View {
        sectionBlock("User") {
            if let ts = exchange.userTimestamp {
                infoRow("Timestamp", value: formatTimestamp(ts))
            }
            truncatableRow("Message", value: exchange.userMessage, key: "\(prefix)_user_message")
        }
    }

    // MARK: - Assistant Section

    private func assistantSection(_ exchange: LastExchange, prefix: String) -> some View {
        sectionBlock("Assistant") {
            if let messages = exchange.assistantMessages, !messages.isEmpty {
                ForEach(Array(messages.enumerated()), id: \.offset) { index, msg in
                    VStack(alignment: .leading, spacing: 4) {
                        if messages.count > 1 {
                            Text("Message \(index + 1)")
                                .chromeFont(size: fontSize.caption2, weight: .medium)
                                .foregroundColor(.secondary)
                                .padding(.top, index > 0 ? 8 : 0)
                        }
                        if let ts = msg.timestamp {
                            infoRow("Timestamp", value: formatTimestamp(ts))
                        }
                        truncatableRow(
                            "Response",
                            value: msg.content,
                            key: "\(prefix)_assistant_\(index)"
                        )
                        if let tools = msg.toolUses, !tools.isEmpty {
                            infoRow("Tools", value: tools.joined(separator: ", "))
                        } else {
                            infoRow("Tools", value: "(none)")
                        }
                    }
                }
            } else if let full = exchange.fullContent, !full.isEmpty {
                truncatableRow("Response", value: full, key: "\(prefix)_full_content")
            } else {
                Text("No assistant response")
                    .chromeFont(size: fontSize.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Summary Section

    private func summarySection(_ summary: ExchangeSummary, prefix: String) -> some View {
        sectionBlock("Summary") {
            infoRow("Request", value: summary.userRequest)
            infoRow("Response", value: summary.assistantResponse)
            if let files = summary.filesModified, !files.isEmpty {
                multiLineRow("Files", values: files)
            }
            if let actions = summary.keyActions, !actions.isEmpty {
                multiLineRow("Actions", values: actions)
            }
            if let decisions = summary.decisions, !decisions.isEmpty {
                decisionsBlock(decisions)
            }
            if let learnings = summary.learnings, !learnings.isEmpty {
                multiLineRow("Learnings", values: learnings)
            }
        }
    }

    /// Render decisions with choice, rationale, and optional alternatives.
    private func decisionsBlock(_ decisions: [ExchangeDecision]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(decisions.enumerated()), id: \.offset) { _, decision in
                HStack(alignment: .top) {
                    Text("Decision")
                        .chromeFont(size: fontSize.caption2)
                        .foregroundColor(.secondary)
                        .frame(width: 80, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(decision.choice)
                            .chromeFontMono(size: fontSize.caption2)
                            .foregroundColor(.primary)
                        Text(decision.rationale)
                            .chromeFontMono(size: fontSize.caption2)
                            .foregroundColor(.secondary)
                        if let alt = decision.alternatives, !alt.isEmpty {
                            Text("Alt: \(alt)")
                                .chromeFontMono(size: fontSize.caption2)
                                .foregroundColor(.secondary)
                                .italic()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Layout Helpers

    private func sectionBlock<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .chromeFont(size: fontSize.caption, weight: .semibold)
                .foregroundColor(.secondary)
                .textCase(.uppercase)

            VStack(alignment: .leading, spacing: 4) {
                content()
            }
        }
    }

    private func infoRow(_ label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .chromeFont(size: fontSize.caption2)
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .trailing)
            Text(value)
                .chromeFontMono(size: fontSize.caption2)
                .foregroundColor(.primary)
                .textSelection(.enabled)
        }
    }

    private func truncatableRow(_ label: String, value: String, key: String) -> some View {
        let isExpanded = expandedFields.contains(key)
        let needsTruncation = value.count > 500
        let displayValue = (!isExpanded && needsTruncation)
            ? String(value.prefix(500)) + "..."
            : value

        return HStack(alignment: .top) {
            Text(label)
                .chromeFont(size: fontSize.caption2)
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayValue)
                    .chromeFontMono(size: fontSize.caption2)
                    .foregroundColor(.primary)
                    .textSelection(.enabled)
                if needsTruncation {
                    Button(isExpanded ? "Show less" : "Show more") {
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
    }

    private func multiLineRow(_ label: String, values: [String]) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .chromeFont(size: fontSize.caption2)
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                ForEach(values, id: \.self) { value in
                    Text(abbreviatePath(value))
                        .chromeFontMono(size: fontSize.caption2)
                        .foregroundColor(.primary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    // MARK: - Formatting

    private func abbreviatePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private static let iso8601WithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso8601Standard: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let displayDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private func formatTimestamp(_ iso: String) -> String {
        if let date = Self.iso8601WithFractional.date(from: iso) {
            return Self.displayDateFormatter.string(from: date)
        }
        if let date = Self.iso8601Standard.date(from: iso) {
            return Self.displayDateFormatter.string(from: date)
        }
        return iso
    }
}

// MARK: - Codable Models

struct LastExchange: Codable {
    let userMessage: String
    let userTimestamp: String?
    let fullContent: String?
    let assistantMessages: [AssistantMessage]?
    let summary: ExchangeSummary?
}

struct AssistantMessage: Codable {
    let content: String
    let timestamp: String?
    let toolUses: [String]?
}

struct ExchangeSummary: Codable {
    let userRequest: String
    let assistantResponse: String
    let filesModified: [String]?
    let keyActions: [String]?
    let decisions: [ExchangeDecision]?
    let learnings: [String]?
}

struct ExchangeDecision: Codable {
    let choice: String
    let rationale: String
    let alternatives: String?
}
