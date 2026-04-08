import SwiftUI

/// Two-column layout showing session identifiers and process IDs.
/// Data is fetched JIT via LedgerQueryService.fetchSession() to
/// ensure fresh identifier/PID data (not stale enrichment).
struct LedgerIdentifiersView: View {
    @ObservedObject var session: Session
    let sessionDetail: LedgerSessionDetail?
    let isLoading: Bool

    @Environment(\.chromeFontSize) private var chromeFontSize
    private var fontSize: ChromeFontSize { ChromeFontSize(chromeFontSize) }

    var body: some View {
        ScrollView {
            if isLoading && sessionDetail == nil {
                HStack {
                    Spacer()
                    ProgressView()
                        .scaleEffect(0.8)
                        .padding()
                    Spacer()
                }
            } else if let detail = sessionDetail {
                HStack(alignment: .top, spacing: 40) {
                    identifiersColumn(detail)
                    pidsColumn(detail)
                    Spacer(minLength: 0)
                }
            } else {
                Text("No identifier data available.")
                    .chromeFont(size: fontSize.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            }
        }
    }

    // MARK: - Session Identifiers Column

    private func identifiersColumn(_ detail: LedgerSessionDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Session Identifiers")
                .chromeFont(size: fontSize.caption, weight: .semibold)
                .foregroundColor(.secondary)
                .textCase(.uppercase)

            VStack(alignment: .leading, spacing: 4) {
                labeledValue("Ledger ID", value: "\(detail.ledgerSessionId)")

                if !detail.sessionIdentifiers.isEmpty {
                    HStack(alignment: .top) {
                        Text("Claude IDs")
                            .chromeFont(size: fontSize.caption2)
                            .foregroundColor(.secondary)
                            .frame(width: 80, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(detail.sessionIdentifiers, id: \.self) { sid in
                                HStack(spacing: 4) {
                                    Text(sid)
                                        .chromeFontMono(size: fontSize.caption2)
                                        .foregroundColor(.primary)
                                        .textSelection(.enabled)
                                    if sid == detail.currentSessionIdentifier {
                                        Text("current")
                                            .chromeFont(size: fontSize.caption2)
                                            .foregroundColor(.green)
                                            .padding(.horizontal, 4)
                                            .background(
                                                RoundedRectangle(cornerRadius: 3)
                                                    .fill(Color.green.opacity(0.15))
                                            )
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - PIDs Column

    private func pidsColumn(_ detail: LedgerSessionDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Process IDs")
                .chromeFont(size: fontSize.caption, weight: .semibold)
                .foregroundColor(.secondary)
                .textCase(.uppercase)

            VStack(alignment: .leading, spacing: 4) {
                if let current = detail.currentClaudePid {
                    labeledValue("Current PID", value: "\(current)")
                }

                if let pids = detail.claudePids, !pids.isEmpty {
                    HStack(alignment: .top) {
                        Text("All PIDs")
                            .chromeFont(size: fontSize.caption2)
                            .foregroundColor(.secondary)
                            .frame(width: 80, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(pids, id: \.self) { pid in
                                HStack(spacing: 4) {
                                    Text(verbatim: "\(pid)")
                                        .chromeFontMono(size: fontSize.caption2)
                                        .foregroundColor(.primary)
                                        .textSelection(.enabled)
                                    if pid == detail.currentClaudePid {
                                        Text("current")
                                            .chromeFont(size: fontSize.caption2)
                                            .foregroundColor(.green)
                                            .padding(.horizontal, 4)
                                            .background(
                                                RoundedRectangle(cornerRadius: 3)
                                                    .fill(Color.green.opacity(0.15))
                                            )
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func labeledValue(_ label: String, value: String) -> some View {
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
