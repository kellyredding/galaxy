import SwiftUI

/// Container that resolves the active session and renders SnapshotsView.
/// Mirrors LedgerContainerView's pattern for consistency.
struct SnapshotsContainerView: View {
    @EnvironmentObject var sessionManager: SessionManager

    private var activeSession: Session? {
        guard let activeId = sessionManager.activeSessionId else { return nil }
        return sessionManager.sessions.first { $0.id == activeId }
    }

    var body: some View {
        ZStack {
            if let session = activeSession {
                SnapshotsView(session: session)
                    .id(session.id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Displays a session's snapshots as a sortable index table.
/// Clicking a snapshot opens a full-view markdown reader.
struct SnapshotsView: View {
    @ObservedObject var session: Session
    @EnvironmentObject var sessionManager: SessionManager
    @Environment(\.chromeFontSize) private var chromeFontSize
    @Environment(\.colorScheme) private var colorScheme

    private var fontSize: ChromeFontSize { ChromeFontSize(chromeFontSize) }

    // JIT data state
    @State private var snapshots: [SnapshotSummary]? = nil
    @State private var isLoading: Bool = false
    @State private var fetchTask: Task<Void, Never>? = nil

    // Reader state
    @State private var openSnapshot: SnapshotDetail? = nil
    @State private var isLoadingContent: Bool = false
    @State private var isBackHovered: Bool = false
    @State private var escapeMonitor: Any? = nil

    // Focus state for keyboard navigation
    @State private var focusedIndex: Int? = nil

    // Sort state
    @State private var sortColumn: SortColumn = .created
    @State private var sortAscending: Bool = false

    enum SortColumn {
        case number, title, exchanges, size, created
    }

    private var sortedSnapshots: [SnapshotSummary] {
        guard let snapshots = snapshots else { return [] }
        return snapshots.sorted { a, b in
            let result: Bool
            switch sortColumn {
            case .number:
                result = a.number < b.number
            case .title:
                result = a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            case .exchanges:
                result = a.exchangeCount < b.exchangeCount
            case .size:
                result = a.charCount < b.charCount
            case .created:
                result = a.createdAt < b.createdAt
            }
            return sortAscending ? result : !result
        }
    }

    var body: some View {
        Group {
            if let snapshot = openSnapshot {
                // Reader view (full takeover)
                snapshotReader(snapshot)
            } else {
                // Index view
                snapshotIndex
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.textBackgroundColor))
        .onChange(of: openSnapshot != nil) {
            if openSnapshot != nil {
                installEscapeMonitor()
            } else {
                removeEscapeMonitor()
            }
        }
        .onAppear {
            if sessionManager.pendingSnapshotNumber != nil {
                handlePendingSnapshot()
            } else {
                fetchSnapshotList()
            }
        }
        .onChange(of: session.id) { handleSessionSwitch() }
        .onChange(of: sessionManager.pendingSnapshotNumber) {
            handlePendingSnapshot()
        }
        .onChange(of: sessionManager.listNavAction) {
            guard openSnapshot == nil else { return }
            guard let action = sessionManager.listNavAction else { return }
            sessionManager.listNavAction = nil
            handleListNavAction(action)
        }
        .onDisappear {
            fetchTask?.cancel()
            fetchTask = nil
            SnapshotQueryService.shared.cancelAll()
            removeEscapeMonitor()
            openSnapshot = nil
            snapshots = nil
        }
    }

    // MARK: - Index View

    @ViewBuilder
    private var snapshotIndex: some View {
        if isLoading && snapshots == nil {
            VStack {
                Spacer()
                ProgressView()
                    .scaleEffect(0.8)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if let snapshots = snapshots, snapshots.isEmpty {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "camera.viewfinder")
                    .chromeFont(size: fontSize.iconLarge)
                    .foregroundColor(.secondary)
                Text("No snapshots")
                    .chromeFont(size: fontSize.title2)
                    .foregroundColor(.primary)
                Text("Use /ledger:snapshot in a session to save one")
                    .chromeFont(size: fontSize.body)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if snapshots == nil {
            // No ledger session ID yet or fetch hasn't returned
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "camera.viewfinder")
                    .chromeFont(size: fontSize.iconLarge)
                    .foregroundColor(.secondary)
                Text("No snapshots")
                    .chromeFont(size: fontSize.title2)
                    .foregroundColor(.primary)
                Text("Use /ledger:snapshot in a session to save one")
                    .chromeFont(size: fontSize.body)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            GeometryReader { geo in
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            headerRow
                            ForEach(Array(sortedSnapshots.enumerated()), id: \.element.id) { index, snap in
                                snapshotRow(snap, index: index)
                                    .id(snap.id)
                            }
                        }
                        .frame(width: geo.size.width - 40, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                        .padding(.bottom, 20)
                    }
                    .onChange(of: focusedIndex) {
                        if let idx = focusedIndex, idx < sortedSnapshots.count {
                            scrollProxy.scrollTo(sortedSnapshots[idx].id)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Index Header

    private var headerRow: some View {
        HStack(spacing: 0) {
            sortableHeader("#", column: .number, width: 40)
            sortableHeader("Title", column: .title, width: nil)
            sortableHeader("Exchanges", column: .exchanges, width: 90)
            sortableHeader("Size", column: .size, width: 80)
            sortableHeader("Created", column: .created, width: 160)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color.primary.opacity(0.05))
    }

    private func sortableHeader(_ title: String, column: SortColumn, width: CGFloat?) -> some View {
        Button(action: {
            if sortColumn == column {
                sortAscending.toggle()
            } else {
                sortColumn = column
                sortAscending = column == .title  // Title defaults ascending, others descending
            }
        }) {
            HStack(spacing: 3) {
                Text(title)
                    .chromeFont(size: fontSize.caption2, weight: .semibold)
                    .foregroundColor(.secondary)
                if sortColumn == column {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(width: width, alignment: .leading)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }

    // MARK: - Index Row

    private func snapshotRow(_ snap: SnapshotSummary, index: Int) -> some View {
        let isFocused = focusedIndex == index

        return Button(action: { openSnapshotReader(number: snap.number) }) {
            HStack(spacing: 0) {
                Text(verbatim: "\(snap.number)")
                    .chromeFontMono(size: fontSize.caption2)
                    .foregroundColor(.secondary)
                    .frame(width: 40, alignment: .leading)

                Text(snap.title)
                    .chromeFont(size: fontSize.caption2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(verbatim: "\(snap.exchangeCount)")
                    .chromeFontMono(size: fontSize.caption2)
                    .frame(width: 90, alignment: .leading)

                Text(formatCharCount(snap.charCount))
                    .chromeFontMono(size: fontSize.caption2)
                    .foregroundColor(.secondary)
                    .frame(width: 80, alignment: .leading)

                Text(formatTimestamp(snap.createdAt))
                    .chromeFontMono(size: fontSize.caption2)
                    .frame(width: 160, alignment: .leading)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 8)
            .background(
                isFocused
                    ? Color.accentColor.opacity(0.15)
                    : (index % 2 == 1 ? Color.primary.opacity(0.03) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Reader View

    private func snapshotReader(_ snapshot: SnapshotDetail) -> some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                Button(action: { closeReader() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Snapshots")
                    }
                    .chromeFont(size: fontSize.caption2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.primary.opacity(isBackHovered ? 0.1 : 0))
                    )
                    .onHover { hovering in isBackHovered = hovering }
                }
                .buttonStyle(.plain)
                .foregroundColor(isBackHovered ? .primary : .secondary)

                Spacer()

                // Metadata
                Text("#\(snapshot.number)")
                    .chromeFontMono(size: fontSize.caption2)
                    .foregroundColor(.secondary)
                Text(snapshot.title)
                    .chromeFont(size: fontSize.caption2, weight: .semibold)
                Text("\u{00B7}")
                    .foregroundColor(.secondary)
                Text("\(snapshot.exchangeCount) exchange\(snapshot.exchangeCount == 1 ? "" : "s")")
                    .chromeFont(size: fontSize.caption2)
                    .foregroundColor(.secondary)
                Text("\u{00B7}")
                    .foregroundColor(.secondary)
                Text(formatTimestamp(snapshot.createdAt))
                    .chromeFont(size: fontSize.caption2)
                    .foregroundColor(.secondary)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(.windowBackgroundColor))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.primary.opacity(0.1))
                    .frame(height: 1)
            }

            // Markdown content
            MarkdownReaderView(
                markdown: snapshot.content,
                isDark: colorScheme == .dark
            )
        }
    }

    // MARK: - Data Lifecycle

    private func fetchSnapshotList() {
        guard let lsid = session.ledgerSessionId else { return }
        isLoading = true
        fetchTask = Task {
            do {
                let result = try await SnapshotQueryService.shared
                    .fetchSnapshots(ledgerSessionId: lsid)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    snapshots = result
                    isLoading = false
                    focusedIndex = result.isEmpty ? nil : 0
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    snapshots = []
                    isLoading = false
                }
                NSLog("SnapshotsView: fetchSnapshots error: %@", error.localizedDescription)
            }
        }
    }

    private func openSnapshotReader(number: Int32) {
        guard let lsid = session.ledgerSessionId else { return }
        isLoadingContent = true
        fetchTask?.cancel()
        SnapshotQueryService.shared.cancelAll()
        fetchTask = Task {
            do {
                let detail = try await SnapshotQueryService.shared
                    .fetchSnapshotContent(ledgerSessionId: lsid, number: number)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    openSnapshot = detail
                    isLoadingContent = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    isLoadingContent = false
                }
                NSLog("SnapshotsView: fetchContent error: %@", error.localizedDescription)
            }
        }
    }

    private func closeReader() {
        let closingNumber = openSnapshot?.number
        removeEscapeMonitor()
        openSnapshot = nil  // Purge content from memory

        // Refocus the row that was open
        if let number = closingNumber {
            focusedIndex = sortedSnapshots.firstIndex(where: { $0.number == number })
        }
    }

    // MARK: - Escape Key (AppKit monitor)

    /// Install a local event monitor that catches Escape regardless of
    /// which AppKit responder (e.g. WKWebView) holds first responder.
    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            if event.keyCode == 53 {  // 53 = Escape
                DispatchQueue.main.async { closeReader() }
                return nil  // Consume the event
            }
            return event
        }
    }

    private func removeEscapeMonitor() {
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }
    }

    private func handleSessionSwitch() {
        // Close reader, cancel fetches, nil data, re-fetch index
        fetchTask?.cancel()
        fetchTask = nil
        SnapshotQueryService.shared.cancelAll()
        openSnapshot = nil
        snapshots = nil
        isLoading = false
        isLoadingContent = false
        focusedIndex = nil
        fetchSnapshotList()
    }

    private func handlePendingSnapshot() {
        guard let number = sessionManager.pendingSnapshotNumber else { return }
        sessionManager.pendingSnapshotNumber = nil

        // Fetch fresh list first, then open the snapshot
        guard let lsid = session.ledgerSessionId else { return }
        fetchTask?.cancel()
        SnapshotQueryService.shared.cancelAll()
        isLoading = true
        fetchTask = Task {
            do {
                let list = try await SnapshotQueryService.shared
                    .fetchSnapshots(ledgerSessionId: lsid)
                guard !Task.isCancelled else { return }

                // Verify the snapshot exists in the fresh list
                guard list.contains(where: { $0.number == number }) else {
                    await MainActor.run {
                        snapshots = list
                        isLoading = false
                    }
                    return  // Fail silently — unknown ref
                }

                let detail = try await SnapshotQueryService.shared
                    .fetchSnapshotContent(ledgerSessionId: lsid, number: number)
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    snapshots = list
                    isLoading = false
                    openSnapshot = detail
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    isLoading = false
                }
            }
        }
    }

    // MARK: - List Focus Navigation

    private func handleListNavAction(_ action: ListNavAction) {
        let items = sortedSnapshots
        guard !items.isEmpty else { return }

        switch action {
        case .up:
            if let current = focusedIndex {
                guard current > 0 else { return }
                focusedIndex = current - 1
            } else {
                focusedIndex = items.count - 1
            }
        case .down:
            if let current = focusedIndex {
                guard current < items.count - 1 else { return }
                focusedIndex = current + 1
            } else {
                focusedIndex = 0
            }
        case .activate:
            guard let idx = focusedIndex, idx < items.count else { return }
            openSnapshotReader(number: items[idx].number)
        }
    }

    // MARK: - Formatting

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

    private static let sqliteDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let displayDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private func formatTimestamp(_ ts: String) -> String {
        if let date = Self.iso8601WithFractional.date(from: ts) {
            return Self.displayDateFormatter.string(from: date)
        }
        if let date = Self.iso8601Standard.date(from: ts) {
            return Self.displayDateFormatter.string(from: date)
        }
        if let date = Self.sqliteDateFormatter.date(from: ts) {
            return Self.displayDateFormatter.string(from: date)
        }
        return ts
    }

    private func formatCharCount(_ count: Int32) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }
}
