import SwiftUI

/// Container that renders a single LedgerView for the active session.
/// Conditional rendering tears down the view on session switch, freeing
/// (N-1) × 6 view instances. The search query is hoisted to Session so
/// it survives teardown; all other data re-fetches in <100ms on return.
struct LedgerContainerView: View {
    @EnvironmentObject var sessionManager: SessionManager

    var body: some View {
        Group {
            if let session = sessionManager.activeSession {
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

    /// Per-subtab fetch tasks — independent cancellation so a files
    /// fetch doesn't kill an entries fetch and vice versa.
    @State private var filesFetchTask: Task<Void, Never>? = nil
    @State private var entriesFetchTask: Task<Void, Never>? = nil
    @State private var identifiersFetchTask: Task<Void, Never>? = nil

    /// True when this session is the visible one in the outer ZStack.
    private var isActiveSession: Bool {
        session.id == sessionManager.activeSessionId
    }

    var body: some View {
        let _ = _triggerRedraw  // Force dependency on ledgerVersion

        GeometryReader { geo in
            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Row 1: Three-column metadata header
                        metadataHeader(availableWidth: geo.size.width - 40)

                        // Subtab picker
                        subtabPicker

                        // Subtab content
                        subtabContent(scrollProxy: scrollProxy)
                    }
                    .frame(width: geo.size.width - 40, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 20)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .background(Color(.textBackgroundColor))
        .onChange(of: sessionManager.activeLedgerSubTab) {
            guard isActiveSession else { return }
            handleSubtabSwitch()
        }
        .onChange(of: sessionManager.activeTab) {
            guard isActiveSession else { return }
            if sessionManager.activeTab == .ledger {
                fetchSubtabIfNeeded()
            } else {
                // Leaving the ledger tab — nil sub-tab data to free
                // memory. Entries preserved if a search is active.
                files = nil
                if session.ledgerEntriesSearchQuery.isEmpty {
                    entries = nil
                }
                sessionDetail = nil
            }
        }
        .onChange(of: session.ledgerVersion) {
            // Enrichment event arrived — refresh the active subtab
            // with fresh data. Re-applies search if one is active.
            guard isActiveSession,
                  sessionManager.activeTab == .ledger else {
                // Not visible — just invalidate caches so the next
                // navigation triggers a fresh fetch.
                files = nil
                entries = nil
                sessionDetail = nil
                return
            }
            refreshCurrentSubtab()
        }
        .onAppear {
            guard isActiveSession else { return }
            refreshCurrentSubtab()
        }
        .onDisappear {
            // Fires on session switch (conditional rendering) and session removal
            filesFetchTask?.cancel(); filesFetchTask = nil
            entriesFetchTask?.cancel(); entriesFetchTask = nil
            identifiersFetchTask?.cancel(); identifiersFetchTask = nil
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
        if session.isInTurn { return "Running — busy" }
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
                ledgerRow("Suggested name", value: session.ledgerSuggestedName ?? "--")
                ledgerRow("Ref", value: session.sessionRef)
                ledgerRow("Persona", value: session.personaName ?? "--")
            }
            .frame(width: columnWidth, alignment: .leading)

            // Environment column
            ledgerSection("Environment") {
                if let project = session.ledgerProjectDir {
                    ledgerRow("Project dir", value: abbreviatePath(project))
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
                if let started = session.ledgerStartedAt {
                    ledgerRow("Started", value: formatTimestamp(started))
                }
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

    // MARK: - Subtab Content (ZStack — all views stay alive)

    @ViewBuilder
    private func subtabContent(scrollProxy: ScrollViewProxy) -> some View {
        let active = sessionManager.activeLedgerSubTab

        ZStack(alignment: .topLeading) {
            LedgerLastActivityView(session: session)
                .opacity(active == .lastActivity ? 1 : 0)
                .allowsHitTesting(active == .lastActivity)

            LedgerFilesView(files: files, isLoading: isLoading, scrollProxy: scrollProxy)
                .opacity(active == .files ? 1 : 0)
                .allowsHitTesting(active == .files)

            LedgerEntriesView(
                sessionId: session.id,
                entries: entries,
                isLoading: isLoading,
                ledgerSessionId: session.ledgerSessionId,
                searchQuery: Binding(
                    get: { session.ledgerEntriesSearchQuery },
                    set: { session.ledgerEntriesSearchQuery = $0 }
                ),
                onSearch: { query in searchEntries(query: query) },
                onClearSearch: { fetchEntriesData() },
                scrollProxy: scrollProxy
            )
            .opacity(active == .entries ? 1 : 0)
            .allowsHitTesting(active == .entries)

            LedgerIdentifiersView(
                session: session,
                sessionDetail: sessionDetail,
                isLoading: isLoading
            )
            .opacity(active == .identifiers ? 1 : 0)
            .allowsHitTesting(active == .identifiers)

            LedgerSuggestedNameView(session: session)
                .opacity(active == .suggestedName ? 1 : 0)
                .allowsHitTesting(active == .suggestedName)
        }
    }

    // MARK: - Data Lifecycle

    private func handleSubtabSwitch() {
        // Cancel in-flight fetches for previous subtabs
        filesFetchTask?.cancel(); filesFetchTask = nil
        entriesFetchTask?.cancel(); entriesFetchTask = nil
        identifiersFetchTask?.cancel(); identifiersFetchTask = nil
        isLoading = false

        // Nil data for non-active sub-tabs to free memory.
        // Entries data is preserved when a search is active so the
        // user returns to their filtered results on switch-back.
        let active = sessionManager.activeLedgerSubTab
        if active != .files { files = nil }
        if active != .entries { entries = nil }
        if active != .identifiers { sessionDetail = nil }

        fetchSubtabIfNeeded()
    }

    /// Unconditional refresh — re-fetches the active subtab's data,
    /// re-applying the entries search query if one is active.
    /// Used by the ledgerVersion change handler and onAppear.
    private func refreshCurrentSubtab() {
        switch sessionManager.activeLedgerSubTab {
        case .lastActivity, .suggestedName:
            break  // Driven by Session @Published properties
        case .files:
            fetchFilesData()
        case .entries:
            if session.ledgerEntriesSearchQuery.isEmpty {
                fetchEntriesData()
            } else {
                searchEntries(query: session.ledgerEntriesSearchQuery)
            }
        case .identifiers:
            fetchIdentifiersData()
        }
    }

    /// Lazy fetch — only fires when a subtab's data is still nil (first visit).
    /// Re-applies the hoisted search query when entries need re-fetching.
    private func fetchSubtabIfNeeded() {
        switch sessionManager.activeLedgerSubTab {
        case .lastActivity, .suggestedName:
            break
        case .files:
            if files == nil { fetchFilesData() }
        case .entries:
            if entries == nil {
                if session.ledgerEntriesSearchQuery.isEmpty {
                    fetchEntriesData()
                } else {
                    searchEntries(query: session.ledgerEntriesSearchQuery)
                }
            }
        case .identifiers:
            if sessionDetail == nil { fetchIdentifiersData() }
        }
    }

    /// Result wrapper for the fetch-vs-timeout race.
    private enum FetchRace<T: Sendable>: Sendable {
        case completed(T)
        case timeout
    }

    /// Races an async operation against a deadline to prevent an
    /// infinite spinner when fetch tasks are orphaned by rapid
    /// tab/session switching.  Timeout errors land in the caller's
    /// existing catch block which sets empty data + clears loading.
    private func withFetchDeadline<T: Sendable>(
        seconds: TimeInterval = 5.0,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        return try await withThrowingTaskGroup(of: FetchRace<T>.self) { group in
            group.addTask { .completed(try await operation()) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return .timeout
            }
            guard let first = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            switch first {
            case .completed(let result): return result
            case .timeout:
                throw NSError(
                    domain: "LedgerView", code: -1,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Fetch timed out after \(seconds)s"]
                )
            }
        }
    }

    private func fetchFilesData() {
        guard let lsid = session.ledgerSessionId else { return }
        isLoading = true
        filesFetchTask?.cancel()
        filesFetchTask = Task {
            do {
                let result = try await withFetchDeadline {
                    try await LedgerQueryService.shared.fetchFiles(ledgerSessionId: lsid)
                }
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
        entriesFetchTask?.cancel()
        entriesFetchTask = Task {
            do {
                let result = try await withFetchDeadline {
                    try await LedgerQueryService.shared.fetchEntries(ledgerSessionId: lsid)
                }
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
        entriesFetchTask?.cancel()
        entriesFetchTask = Task {
            do {
                let result = try await withFetchDeadline {
                    try await LedgerQueryService.shared.searchEntries(
                        ledgerSessionId: lsid, query: query
                    )
                }
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
        identifiersFetchTask?.cancel()
        identifiersFetchTask = Task {
            do {
                let result = try await withFetchDeadline {
                    try await LedgerQueryService.shared.fetchSession(ledgerSessionId: lsid)
                }
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
