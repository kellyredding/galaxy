import SwiftUI

/// Container that resolves the active session and renders LedgerView.
/// Mirrors TerminalContainerView's pattern for consistency.
struct LedgerContainerView: View {
    @EnvironmentObject var sessionManager: SessionManager

    private var activeSession: Session? {
        guard let activeId = sessionManager.activeSessionId else {
            return nil
        }
        return sessionManager.sessions.first { $0.id == activeId }
    }

    var body: some View {
        ZStack {
            if let session = activeSession {
                LedgerView(session: session)
                    .id(session.id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Displays ledger-synced session data in a scrollable info panel.
struct LedgerView: View {
    @ObservedObject var session: Session

    @Environment(\.chromeFontSize) private var chromeFontSize
    @Environment(\.colorScheme) private var colorScheme

    private var fontSize: ChromeFontSize { ChromeFontSize(chromeFontSize) }

    /// Observe ledgerVersion to trigger re-renders when enrichment
    /// data arrives. The actual data is read from plain vars below.
    private var _triggerRedraw: Int { session.ledgerVersion }

    var body: some View {
        let _ = _triggerRedraw  // Force dependency on ledgerVersion

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Status indicator
                statusBadge

                // Session Info section
                ledgerSection("Session") {
                    ledgerRow("Name", value: session.displayName)
                    ledgerRow("Persona", value: session.personaName ?? "--")
                    ledgerRow(
                        "Ref",
                        value: session.sessionRef
                    )
                    if let started = session.ledgerStartedAt {
                        ledgerRow("Started", value: formatTimestamp(started))
                    }
                    if let lastInteraction = session.ledgerLastInteraction {
                        ledgerRow(
                            "Last activity",
                            value: formatTimestamp(lastInteraction)
                        )
                    }
                }

                // Environment section
                ledgerSection("Environment") {
                    if let cwd = session.ledgerCwd {
                        ledgerRow("Working directory", value: abbreviatePath(cwd))
                    }
                    if let project = session.ledgerProjectDir {
                        ledgerRow("Project", value: abbreviatePath(project))
                    }
                    if let branch = session.ledgerGitBranch {
                        ledgerRow("Branch", value: branch)
                    }
                    if let model = session.ledgerModelDisplayName {
                        ledgerRow("Model", value: model)
                    }
                    if let version = session.ledgerClaudeVersion {
                        ledgerRow("Claude", value: version)
                    }
                }

                // Usage section
                ledgerSection("Usage") {
                    if let pct = session.ledgerContextPercentage {
                        contextRow(percentage: pct)
                    }
                    if let tokens = session.ledgerTokensUsed {
                        let max = session.ledgerTokensMax
                        let display = max != nil
                            ? "\(formatNumber(tokens)) / \(formatNumber(max!))"
                            : formatNumber(tokens)
                        ledgerRow("Tokens", value: display)
                    }
                    if let cost = session.ledgerCostUsd {
                        ledgerRow(
                            "Cost",
                            value: String(format: "$%.4f", cost)
                        )
                    }
                    if let added = session.ledgerLinesAdded,
                       let removed = session.ledgerLinesRemoved {
                        ledgerRow(
                            "Code changes",
                            value: "+\(added) / -\(removed)"
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.textBackgroundColor))
    }

    // MARK: - Status Badge

    private var statusBadge: some View {
        HStack(spacing: 6) {
            SessionStatusDot(session: session)
            Text(statusText)
                .chromeFont(size: fontSize.caption, weight: .medium)
                .foregroundColor(.secondary)
        }
    }

    private var statusText: String {
        if session.hasExited {
            if let code = session.exitCode {
                return "Stopped (exit \(code))"
            }
            return "Stopped"
        }
        if session.isBusy { return "Running — busy" }
        if session.isRunning { return "Running — idle" }
        return "Starting"
    }

    // MARK: - Section & Row Helpers

    private func ledgerSection<Content: View>(
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

    private func ledgerRow(_ label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .chromeFont(size: fontSize.caption2)
                .foregroundColor(.secondary)
                .frame(width: 120, alignment: .trailing)
            Text(value)
                .chromeFontMono(size: fontSize.caption2)
                .foregroundColor(.primary)
                .textSelection(.enabled)
        }
    }

    private func contextRow(percentage: Double) -> some View {
        HStack(alignment: .center) {
            Text("Context")
                .chromeFont(size: fontSize.caption2)
                .foregroundColor(.secondary)
                .frame(width: 120, alignment: .trailing)

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.2))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(contextBarColor(percentage))
                        .frame(
                            width: geo.size.width
                                * CGFloat(min(percentage, 100)) / 100
                        )
                }
            }
            .frame(height: 6)
            .frame(maxWidth: 120)

            Text(String(format: "%.0f%%", percentage))
                .chromeFontMono(size: fontSize.caption2)
                .foregroundColor(.primary)
        }
    }

    private func contextBarColor(_ pct: Double) -> Color {
        if pct >= 90 { return .red }
        if pct >= 70 { return .orange }
        return .green
    }

    // MARK: - Formatting

    /// Static formatters — allocated once, reused across re-renders.
    /// DateFormatter and NumberFormatter are expensive to create;
    /// allocating them in body would create new instances on every
    /// enrichment-driven redraw.
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

    /// SQLite datetime('now') format — stored as UTC with no timezone suffix.
    private static let sqliteDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")  // Fixed locale for parsing
        return f
    }()

    /// Localized display formatter — uses system locale and local timezone.
    private static let displayDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private static let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    private func abbreviatePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private func formatTimestamp(_ iso: String) -> String {
        if let date = Self.iso8601WithFractional.date(from: iso) {
            return Self.displayDateFormatter.string(from: date)
        }
        if let date = Self.iso8601Standard.date(from: iso) {
            return Self.displayDateFormatter.string(from: date)
        }
        if let date = Self.sqliteDateFormatter.date(from: iso) {
            return Self.displayDateFormatter.string(from: date)
        }
        return iso
    }

    private func formatNumber(_ n: Int) -> String {
        Self.numberFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
