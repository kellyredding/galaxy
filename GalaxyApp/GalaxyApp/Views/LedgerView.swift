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

/// Displays ledger-synced session data in a structured info panel with
/// a three-column metadata header and subtabbed detail area.
struct LedgerView: View {
    @ObservedObject var session: Session
    @EnvironmentObject var sessionManager: SessionManager

    @Environment(\.chromeFontSize) private var chromeFontSize
    @Environment(\.colorScheme) private var colorScheme

    private var fontSize: ChromeFontSize { ChromeFontSize(chromeFontSize) }

    /// Observe ledgerVersion to trigger re-renders when enrichment
    /// data arrives. The actual data is read from plain vars below.
    private var _triggerRedraw: Int { session.ledgerVersion }

    // MARK: - JIT Data State

    /// Files fetched for the current session (nil = not loaded, empty = loaded but none)
    @State private var files: [LedgerFile]? = nil

    /// Entries fetched for the current session
    @State private var entries: [LedgerEntry]? = nil

    /// Session detail fetched for identifiers subtab
    @State private var sessionDetail: LedgerSessionDetail? = nil

    /// Whether a JIT fetch is in progress
    @State private var isLoading: Bool = false

    /// Active fetch task — cancelled on tab/session switch
    @State private var fetchTask: Task<Void, Never>? = nil

    var body: some View {
        let _ = _triggerRedraw  // Force dependency on ledgerVersion

        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Row 1: Three-column metadata header
                    metadataHeader(availableWidth: geo.size.width - 40)

                    // Subtab picker
                    subtabPicker

                    // Subtab content
                    subtabContent
                }
                .frame(width: geo.size.width - 40, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .background(Color(.textBackgroundColor))
        .onChange(of: sessionManager.activeLedgerSubTab) {
            handleSubtabSwitch()
        }
        .onChange(of: session.id) {
            handleSessionSwitch()
        }
        .onAppear {
            triggerFetchForCurrentSubtab()
        }
        .onDisappear {
            // Cancel and deallocate when switching away from Ledger tab
            fetchTask?.cancel()
            fetchTask = nil
            LedgerQueryService.shared.cancelAll()
            files = nil
            entries = nil
            sessionDetail = nil
        }
    }

    // MARK: - Status Row

    private var statusRow: some View {
        HStack(alignment: .top) {
            Text("Status")
                .chromeFont(size: fontSize.caption2)
                .foregroundColor(.secondary)
                .frame(width: 90, alignment: .trailing)
            HStack(spacing: 5) {
                SessionStatusDot(session: session)
                Text(statusText)
                    .chromeFontMono(size: fontSize.caption2)
                    .foregroundColor(.primary)
            }
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

    // MARK: - Three-Column Metadata Header

    private func metadataHeader(availableWidth: CGFloat) -> some View {
        let columnSpacing: CGFloat = 20
        let columnWidth = (availableWidth - (2 * columnSpacing)) / 3

        return HStack(alignment: .top, spacing: columnSpacing) {
            // Session column
            ledgerSection("Session") {
                statusRow
                ledgerRow("Name", value: session.displayName)
                ledgerRow("Persona", value: session.personaName ?? "--")
                ledgerRow("Ref", value: session.sessionRef)
                if let started = session.ledgerStartedAt {
                    ledgerRow("Started", value: formatTimestamp(started))
                }
            }
            .frame(width: columnWidth, alignment: .leading)

            // Environment column
            ledgerSection("Environment") {
                if let project = session.ledgerProjectDir {
                    ledgerRow("Project", value: abbreviatePath(project))
                }
                if let cwd = session.ledgerCwd {
                    ledgerRow("Working dir", value: abbreviatePath(cwd))
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
            .frame(width: columnWidth, alignment: .leading)

            // Usage column
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
                    ledgerRow("Cost", value: String(format: "$%.4f", cost))
                }
                if let added = session.ledgerLinesAdded,
                   let removed = session.ledgerLinesRemoved {
                    ledgerRow("Changes", value: "+\(added) / -\(removed)")
                }
            }
            .frame(width: columnWidth, alignment: .leading)
        }
    }

    // MARK: - Subtab Picker

    private var subtabPicker: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.primary.opacity(0.1))
                .frame(height: 1)

            HStack(spacing: 0) {
                ForEach(LedgerSubTab.allCases, id: \.self) { tab in
                    Button(action: { sessionManager.activeLedgerSubTab = tab }) {
                        HStack(spacing: 4) {
                            Image(systemName: tab.icon)
                            Text(tab.rawValue)
                        }
                        .chromeFont(size: fontSize.caption2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(
                                    sessionManager.activeLedgerSubTab == tab
                                        ? Color.primary.opacity(0.1)
                                        : Color.clear
                                )
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(
                        sessionManager.activeLedgerSubTab == tab ? .primary : .secondary
                    )
                }
                Spacer()
            }
            .padding(.vertical, 6)
        }
    }

    // MARK: - Subtab Content (exclusive switch)

    @ViewBuilder
    private var subtabContent: some View {
        switch sessionManager.activeLedgerSubTab {
        case .lastActivity:
            LedgerLastActivityView(session: session)
        case .files:
            LedgerFilesView(files: files, isLoading: isLoading)
        case .entries:
            LedgerEntriesView(
                entries: entries,
                isLoading: isLoading,
                ledgerSessionId: session.ledgerSessionId,
                onSearch: { query in searchEntries(query: query) },
                onClearSearch: { fetchEntriesData() }
            )
        case .identifiers:
            LedgerIdentifiersView(
                session: session,
                sessionDetail: sessionDetail,
                isLoading: isLoading
            )
        }
    }

    // MARK: - Data Lifecycle

    private func handleSubtabSwitch() {
        // Cancel in-flight fetch
        fetchTask?.cancel()
        fetchTask = nil
        LedgerQueryService.shared.cancelAll()

        // Nil out stale data
        files = nil
        entries = nil
        sessionDetail = nil
        isLoading = false

        // Trigger fetch for new subtab
        triggerFetchForCurrentSubtab()
    }

    private func handleSessionSwitch() {
        // Cancel in-flight fetch
        fetchTask?.cancel()
        fetchTask = nil
        LedgerQueryService.shared.cancelAll()

        // Nil out cached data
        files = nil
        entries = nil
        sessionDetail = nil
        isLoading = false

        // Trigger fetch for current subtab
        triggerFetchForCurrentSubtab()
    }

    private func triggerFetchForCurrentSubtab() {
        switch sessionManager.activeLedgerSubTab {
        case .lastActivity:
            break  // Uses data already on Session, no fetch needed
        case .files:
            fetchFilesData()
        case .entries:
            fetchEntriesData()
        case .identifiers:
            fetchIdentifiersData()
        }
    }

    private func fetchFilesData() {
        guard let lsid = session.ledgerSessionId else { return }
        isLoading = true
        fetchTask = Task {
            do {
                let result = try await LedgerQueryService.shared.fetchFiles(ledgerSessionId: lsid)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    files = result
                    isLoading = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    files = []
                    isLoading = false
                }
                NSLog("LedgerView: fetchFiles error: %@", error.localizedDescription)
            }
        }
    }

    private func fetchEntriesData() {
        guard let lsid = session.ledgerSessionId else { return }
        isLoading = true
        fetchTask = Task {
            do {
                let result = try await LedgerQueryService.shared.fetchEntries(ledgerSessionId: lsid)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    entries = result
                    isLoading = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    entries = []
                    isLoading = false
                }
                NSLog("LedgerView: fetchEntries error: %@", error.localizedDescription)
            }
        }
    }

    private func searchEntries(query: String) {
        guard let lsid = session.ledgerSessionId else { return }
        isLoading = true
        fetchTask?.cancel()
        LedgerQueryService.shared.cancelAll()
        fetchTask = Task {
            do {
                let result = try await LedgerQueryService.shared.searchEntries(
                    ledgerSessionId: lsid, query: query
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    entries = result
                    isLoading = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    entries = []
                    isLoading = false
                }
                NSLog("LedgerView: searchEntries error: %@", error.localizedDescription)
            }
        }
    }

    private func fetchIdentifiersData() {
        guard let lsid = session.ledgerSessionId else { return }
        isLoading = true
        fetchTask = Task {
            do {
                let result = try await LedgerQueryService.shared.fetchSession(ledgerSessionId: lsid)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    sessionDetail = result
                    isLoading = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    sessionDetail = nil
                    isLoading = false
                }
                NSLog("LedgerView: fetchSession error: %@", error.localizedDescription)
            }
        }
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
                .frame(width: 90, alignment: .trailing)
            Text(value)
                .chromeFontMono(size: fontSize.caption2)
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.enabled)
        }
    }

    private func contextRow(percentage: Double) -> some View {
        HStack(alignment: .center) {
            Text("Context")
                .chromeFont(size: fontSize.caption2)
                .foregroundColor(.secondary)
                .frame(width: 90, alignment: .trailing)

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
            .frame(maxWidth: 100)

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
        f.locale = Locale(identifier: "en_US_POSIX")
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

    func formatTimestamp(_ iso: String) -> String {
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
