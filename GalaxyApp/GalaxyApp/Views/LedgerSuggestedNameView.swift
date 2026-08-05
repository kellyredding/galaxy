import SwiftUI

/// Renders the suggested name state machine data from the ledger.
/// Parses session.ledgerSuggestedNameData (JSON string) and displays
/// name, status, quality, attempts, and timing information.
struct LedgerSuggestedNameView: View {
    @ObservedObject var session: Session

    @Environment(\.chromeFontSize) private var chromeFontSize
    private var fontSize: ChromeFontSize { ChromeFontSize(chromeFontSize) }

    /// Parsed state data — recomputed when ledgerSuggestedNameData changes.
    private var stateData: SuggestedNameStateData? {
        guard let json = session.ledgerSuggestedNameData,
              !json.isEmpty,
              json != "{}",
              let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(SuggestedNameStateData.self, from: data)
    }

    var body: some View {
        let _ = session.ledgerVersion  // Force re-render on enrichment

        ScrollView {
            if let state = stateData {
                VStack(alignment: .leading, spacing: 16) {
                    nameSection(state)
                    stateSection(state)
                }
            } else {
                Text("No suggested name data")
                    .chromeFont(size: fontSize.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            }
        }
    }

    // MARK: - Name Section

    private func nameSection(_ state: SuggestedNameStateData) -> some View {
        sectionBlock("Name") {
            infoRow("Suggested", value: session.ledgerSuggestedName ?? "--")
            infoRow("Quality", value: qualityDisplay(state.quality))
            infoRow("Finalized", value: state.finalized ? "Yes" : "No")
        }
    }

    // MARK: - State Section

    private func stateSection(_ state: SuggestedNameStateData) -> some View {
        sectionBlock("Generation") {
            infoRow("Status", value: formatStatus(state.status))
            infoRow("Attempts", value: "\(state.attempts) of 3")
            infoRow("Exchanges", value: "\(state.exchangeCount)")
            if let lastAttempt = state.lastAttemptAt {
                infoRow(
                    "Last attempt",
                    value: ListTimestamp.format(lastAttempt))
            } else {
                infoRow("Last attempt", value: "--")
            }
        }
    }

    // MARK: - Display Helpers

    private func qualityDisplay(_ quality: Int) -> String {
        if quality == 0 { return "--" }
        let label: String
        switch quality {
        case 1: label = "Very Generic"
        case 2: label = "Somewhat Generic"
        case 3: label = "Acceptable"
        case 4: label = "Good"
        case 5: label = "Excellent"
        default: label = "Unknown"
        }
        return "\(quality)/5 — \(label)"
    }

    private func formatStatus(_ status: String) -> String {
        switch status {
        case "needs_more_context": return "Needs More Context"
        case "code_detected": return "Code Detected (Rejected)"
        case "awaiting_improvement": return "Awaiting Improvement"
        case "finalized_quality_met": return "Finalized (Quality Met)"
        case "finalized_max_attempts": return "Finalized (Max Attempts)"
        default: return status.isEmpty ? "--" : status
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
}

// MARK: - Codable Model

struct SuggestedNameStateData: Codable {
    let attempts: Int
    let quality: Int
    let finalized: Bool
    let status: String
    let exchangeCount: Int
    let lastAttemptAt: String?
}
