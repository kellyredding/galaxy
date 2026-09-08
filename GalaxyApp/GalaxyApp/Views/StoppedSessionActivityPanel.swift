import SwiftUI

/// A collapsed "Last activity" summary on the stopped-session screen
/// that expands in place into a bounded, terminal-styled history of
/// recent turns.
///
/// The point is to answer "where was I?" for a session that has been
/// sitting stopped for days, without resuming it. The scrollback is
/// gone by the time this screen appears — `Session.processDidExit`
/// releases the backend, and a session restored at launch never had one
/// — so the timeline database is the only place the answer can come
/// from.
///
/// Two fetches, deliberately split. The collapsed row costs a single
/// CLI row and every stopped session shows it; the multi-turn query
/// fires only on first expand.
struct StoppedSessionActivityPanel: View {
    @ObservedObject var session: Session

    /// Gates both fetches. Every restored session is stopped at app
    /// launch and all panes stay mounted behind an opacity switch, so
    /// an ungated fetch would spawn one subprocess per session at
    /// startup rather than one for the session being looked at.
    let isVisibleSurface: Bool

    @Environment(\.chromeFontSize) private var chromeFontSize
    private var fontSize: ChromeFontSize {
        ChromeFontSize(chromeFontSize)
    }

    @State private var isExpanded = false
    @State private var summaryLoaded = false
    @State private var latestTurn: TimelineEvent?
    @State private var turns: [TurnPair]?
    @State private var summaryTask: Task<Void, Never>?
    @State private var historyTask: Task<Void, Never>?

    /// Width to match, measured from the resume command box so the two
    /// blocks line up however long a given session's command is.
    /// Falls back to a sensible column before the measurement lands.
    let width: CGFloat?

    private static let fallbackWidth: CGFloat = 520
    private static let panelHeight: CGFloat = 320
    private static let pairCount = 3

    /// A one-point view pinned to the end of the turn list. Scrolling
    /// to a turn means scrolling to a block that can be taller than the
    /// viewport, and `anchor: .bottom` on one of those lands somewhere
    /// arbitrary. A marker with no height cannot.
    private static let bottomAnchor = "turn-history-bottom"

    var body: some View {
        Group {
            // Nothing is drawn until a turn is known to exist, so a
            // session with no history — or one whose query failed —
            // looks exactly like this screen always has.
            if summaryLoaded, latestTurn != nil {
                VStack(alignment: .leading, spacing: 6) {
                    summaryRow

                    // The history's height is reserved whether or not
                    // it is showing. This screen is a centred block, so
                    // a panel that only took its 320pt while open would
                    // heave everything above it up and down by half
                    // that on every click of the chevron.
                    Group {
                        if isExpanded {
                            historyPanel
                        } else {
                            Color.clear
                        }
                    }
                    .frame(height: Self.panelHeight)
                }
                .frame(
                    width: width ?? Self.fallbackWidth,
                    alignment: .leading
                )
                .padding(.top, 20)
            } else {
                // A real, zero-sized view rather than the implicit
                // EmptyView. The fetch below is driven by this view's
                // own lifecycle, and SwiftUI does not reliably deliver
                // onAppear to an empty conditional branch — which would
                // mean the summary never loads and the panel never
                // appears at all. Zero-sized, and the host stacks it at
                // spacing 0, so it costs no layout.
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .onAppear { loadSummaryIfNeeded() }
        .onChange(of: isVisibleSurface) { loadSummaryIfNeeded() }
        .onChange(of: session.ledgerVersion) {
            // ledgerSessionId is not itself published; enrichment bumps
            // this when it lands, which is when the id can appear.
            guard !summaryLoaded else { return }
            loadSummaryIfNeeded()
        }
        .onDisappear {
            summaryTask?.cancel()
            summaryTask = nil
            historyTask?.cancel()
            historyTask = nil
        }
    }

    // MARK: - Collapsed Summary

    private var summaryRow: some View {
        Button {
            isExpanded.toggle()
            if isExpanded { loadHistoryIfNeeded() }
        } label: {
            HStack(spacing: 6) {
                Image(
                    systemName: isExpanded
                        ? "chevron.down" : "chevron.right"
                )
                .chromeFont(size: fontSize.caption)
                .foregroundColor(.secondary)
                .frame(width: 12, alignment: .leading)

                Text("Last activity")
                    .chromeFont(
                        size: fontSize.caption, weight: .semibold
                    )
                    .foregroundColor(.secondary)

                if let when = latestTurn?.occurredAt {
                    Text("· \(Self.ago(when))")
                        .chromeFont(size: fontSize.caption)
                        .foregroundColor(.secondary)
                }

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .pointingHandCursor()
    }

    // MARK: - Expanded History

    /// The turns, in a box of their own that scrolls.
    ///
    /// Takes its height from the caller, which reserves the same height
    /// for the collapsed state — so this bounds the history without
    /// being the thing that decides how tall the screen is.
    private var historyPanel: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    content
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchor)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Both paths matter. The turns can land after the box is on
            // screen (first expand, still fetching) or before it
            // (collapse, then expand again with them already held).
            .onAppear { scrollToNewest(proxy) }
            .onChange(of: turns?.count) { scrollToNewest(proxy) }
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(.windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    /// Open on the newest turn, the way a terminal opens on its newest
    /// line.
    ///
    /// The wait is the whole trick. Asking to scroll in the same pass
    /// that produced the rows targets a list the scroll view has not
    /// laid out yet, and the request is dropped — silently, leaving the
    /// box parked at the oldest turn. Yielding lets the layout settle
    /// first.
    private func scrollToNewest(_ proxy: ScrollViewProxy) {
        guard turns?.isEmpty == false else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let turns {
            if turns.isEmpty {
                Text("No turns recorded")
                    .chromeFont(size: fontSize.caption)
                    .foregroundColor(.secondary)
            } else {
                // Not lazy: three turns is nothing to build, and a lazy
                // stack may not have realised the last row when the
                // scroll to it is asked for.
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(turns) { turn in
                        turnBlock(turn).id(turn.id)
                    }
                }
            }
        } else {
            HStack {
                Spacer()
                ProgressView().scaleEffect(0.7).padding(.vertical, 8)
                Spacer()
            }
        }
    }

    private func turnBlock(_ turn: TurnPair) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(Self.timeOfDay.string(from: turn.endEvent.occurredAt))
                    .chromeFontMono(size: fontSize.caption2)
                    .foregroundColor(.secondary)
                statusBadge(turn.endEvent.eventType)
            }
            turnLine(">", turn.userMessage, glyphColor: .accentColor)
            turnLine("⏺", turn.assistantResponse, glyphColor: .secondary)
        }
    }

    /// One speaker's text behind a prompt glyph.
    ///
    /// `.unreadable` is rendered rather than skipped: a payload the
    /// recorder truncated past the pipe buffer is a different fact from
    /// a turn that never carried one, and on this screen a blank would
    /// read as "nothing was said".
    @ViewBuilder
    private func turnLine(
        _ glyph: String, _ text: TurnText, glyphColor: Color
    ) -> some View {
        switch text {
        case .text(let value):
            // In full. This screen exists to show what was said, and a
            // turn clipped at some character count is exactly the
            // question it was meant to answer left half-answered. The
            // collapsed summary line is the place that abbreviates.
            promptRow(
                glyph,
                value.trimmingCharacters(in: .whitespacesAndNewlines),
                glyphColor: glyphColor, textColor: .primary
            )
        case .unreadable:
            promptRow(
                glyph, "(content unavailable — record truncated)",
                glyphColor: glyphColor, textColor: .secondary
            )
        case .absent:
            EmptyView()
        }
    }

    private func promptRow(
        _ glyph: String, _ value: String,
        glyphColor: Color, textColor: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(glyph)
                .chromeFontMono(size: fontSize.caption2)
                .foregroundColor(glyphColor)
            Text(value)
                .chromeFontMono(size: fontSize.caption2)
                .foregroundColor(textColor)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func statusBadge(_ eventType: String) -> some View {
        let (label, color): (String, Color) = {
            switch eventType {
            case "turn:completed": return ("completed", .green)
            case "turn:failed": return ("failed", .red)
            case "turn:interrupted": return ("interrupted", .orange)
            case "turn:abandoned": return ("abandoned", .secondary)
            default: return (eventType, .secondary)
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

    // MARK: - Fetching

    private func loadSummaryIfNeeded() {
        guard isVisibleSurface, !summaryLoaded, summaryTask == nil,
              let lsid = session.ledgerSessionId
        else { return }

        summaryTask = Task {
            let event = try? await TimelineQueryService.shared
                .fetchStoppedSessionLatestTurn(ledgerSessionId: lsid)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                latestTurn = event
                // Set on failure too. A transient CLI error leaves the
                // screen as it has always looked rather than parking a
                // spinner nobody can clear.
                summaryLoaded = true
                summaryTask = nil
            }
        }
    }

    private func loadHistoryIfNeeded() {
        guard turns == nil, historyTask == nil,
              let lsid = session.ledgerSessionId
        else { return }

        historyTask = Task {
            let events = try? await TimelineQueryService.shared
                .fetchStoppedSessionTurnEvents(
                    ledgerSessionId: lsid,
                    pairCount: Self.pairCount
                )
            guard !Task.isCancelled else { return }
            let paired = TurnPairing.pairs(
                from: events ?? [],
                limit: Self.pairCount,
                order: .chronological
            )
            await MainActor.run {
                turns = paired
                historyTask = nil
            }
        }
    }

    // MARK: - Formatting

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    private static func ago(_ date: Date) -> String {
        relative.localizedString(for: date, relativeTo: Date())
    }

    private static let timeOfDay: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()
}
