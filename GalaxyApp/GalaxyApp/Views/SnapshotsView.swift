import SwiftUI
import WebKit

/// Container that keeps a SnapshotsView alive per session using a ZStack.
/// Opacity + allowsHitTesting toggle visibility without destroying state.
struct SnapshotsContainerView: View {
    @EnvironmentObject var sessionManager: SessionManager

    var body: some View {
        ZStack {
            ForEach(sessionManager.sessions) { session in
                SnapshotsView(session: session)
                    .opacity(session.id == sessionManager.activeSessionId ? 1 : 0)
                    .allowsHitTesting(session.id == sessionManager.activeSessionId)
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

    // Annotation state
    @State private var openAnnotations: [SnapshotAnnotation] = []
    @State private var annotationHTMLMap: [Int32: String] = [:]
    @State private var webViewRef: WKWebView? = nil
    @State private var isRefreshing = false

    // Cmd+F find state. Controller owns the find bar's
    // visibility, query, and match counters; the slice-4
    // dispatcher will flip `isVisible` via activateFind().
    @StateObject private var findController =
        WebViewFindController(webView: nil, reverse: false)

    // Review state
    @State private var hasUnreviewedAnnotations: Bool = false

    // Duration tracking for timeline events
    @State private var snapshotDurationId: String? = nil

    // Focus state for keyboard navigation
    @State private var focusedIndex: Int? = nil

    // Sort state
    @State private var sortColumn: SortColumn = .number
    @State private var sortAscending: Bool = true

    enum SortColumn {
        case number, title, exchanges, size, reviews, created
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
            case .reviews:
                result = a.reviewCount < b.reviewCount
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
            syncReaderOpenState()
            updateEscapeMonitor()
            syncFindHandler()

            // Re-fetch index after reader closes if data was nilled
            // during a session switch while the reader was open.
            if openSnapshot == nil,
               session.id == sessionManager.activeSessionId,
               sessionManager.activeTab == .snapshots,
               snapshots == nil {
                fetchSnapshotList()
            }
        }
        .onChange(of: sessionManager.activeSessionId) {
            syncReaderOpenState()
            updateEscapeMonitor()
            restoreWebViewFocus()
            syncFindHandler()
            // Re-evaluate find-panel ownership: see note in
            // ArtifactsView.syncFindBarPanel — `dismiss(if:)`
            // makes this race-free when both old and new
            // surfaces fire their onChange in either order.
            syncFindBarPanel()

            // Nil index data for inactive sessions — always safe
            // since the reader replaces the index view entirely,
            // and the index re-fetches when the reader closes.
            if session.id != sessionManager.activeSessionId {
                snapshots = nil
            }
            // Re-fetch when switching back to this
            // session while already on the snapshots tab
            if session.id == sessionManager.activeSessionId,
               sessionManager.activeTab == .snapshots,
               openSnapshot == nil {
                fetchSnapshotList()
            }
        }
        .onChange(of: sessionManager.activeTab) {
            syncReaderOpenState()
            updateEscapeMonitor()
            restoreWebViewFocus()
            syncFindHandler()
            // Re-evaluate find-panel ownership on tab change.
            // See note in the activeSessionId onChange.
            syncFindBarPanel()
            // Refresh snapshot list when returning to snapshots tab
            if sessionManager.activeTab == .snapshots,
               session.id == sessionManager.activeSessionId,
               openSnapshot == nil {
                fetchSnapshotList()
            }
            // Nil index data when switching away from Snapshots tab
            // (only if reader is closed — preserve reader state)
            if sessionManager.activeTab != .snapshots,
               session.id == sessionManager.activeSessionId,
               openSnapshot == nil {
                snapshots = nil
            }
        }
        .onAppear {
            if sessionManager.pendingSnapshotNumber != nil,
               session.id == sessionManager.activeSessionId {
                handlePendingSnapshot()
            } else {
                fetchSnapshotList()
            }
            syncFindHandler()
        }
        .onChange(of: sessionManager.pendingSnapshotNumber) {
            guard session.id == sessionManager.activeSessionId else { return }
            handlePendingSnapshot()
        }
        // Mirror local reader state up to the session so
        // NavigationCoordinator can observe it for history
        // recording. Paired with the observer below.
        .onChange(of: openSnapshot?.number) { _, newValue in
            if session.openSnapshotNumber != newValue {
                session.openSnapshotNumber = newValue
            }
        }
        // React to external writes to session.openSnapshotNumber
        // (e.g., from NavigationCoordinator.apply during
        // back/forward). Opens or closes the reader to match.
        .onChange(of: session.openSnapshotNumber) { _, newValue in
            guard session.id == sessionManager.activeSessionId
            else { return }
            if openSnapshot?.number == newValue { return }
            if let number = newValue {
                openSnapshotByNumber(
                    number,
                    reason: "history-nav",
                    trigger: "history-nav"
                )
            } else if openSnapshot != nil {
                closeReader(reason: "history-nav")
            }
        }
        .onChange(of: sessionManager.listNavAction) {
            guard session.id == sessionManager.activeSessionId else { return }
            guard sessionManager.activeTab == .snapshots else { return }
            guard openSnapshot == nil else { return }
            guard let action = sessionManager.listNavAction else { return }
            sessionManager.listNavAction = nil
            handleListNavAction(action)
        }
        .onChange(of: sessionManager.pendingReviewCheck) {
            guard session.id == sessionManager.activeSessionId else { return }
            guard let snapshotId = sessionManager.pendingReviewCheck
            else { return }
            // Consume the signal before deciding whether it applies
            // here. An id belonging to some other snapshot left
            // sitting in place would make the next event carrying
            // that same id compare equal, so this handler would
            // never run and a wanted refresh would be skipped.
            sessionManager.pendingReviewCheck = nil
            guard let open = openSnapshot,
                  snapshotId == open.id else { return }
            checkReviewButtonVisibility(snapshotId: snapshotId)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication
                    .willTerminateNotification
            )
        ) { _ in
            if openSnapshot != nil {
                closeReader(reason: "app-quit")
            }
        }
        .onDisappear {
            // Fires when session is removed from
            // sessions array
            if openSnapshot != nil {
                closeReader(reason: "session-removed")
            }
            fetchTask?.cancel()
            fetchTask = nil
            SnapshotQueryService.shared.cancelAll()
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
                    .onAppear {
                        if let lastId = sortedSnapshots.last?.id {
                            scrollProxy.scrollTo(lastId, anchor: .bottom)
                        }
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
            sortableHeader("Reviews", column: .reviews, width: 70)
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

                Text(snap.reviewCount > 0 ? "\(snap.reviewCount)" : "\u{2014}")
                    .chromeFontMono(size: fontSize.caption2)
                    .foregroundColor(.secondary)
                    .frame(width: 70, alignment: .leading)

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
                Button(action: { handleBackButton() }) {
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

                Button(action: {
                    requestRefreshCurrentSnapshot(
                        snapshotId: snapshot.id
                    )
                }) {
                    Image(systemName: "arrow.clockwise")
                        .chromeFont(size: fontSize.iconSmall)
                        .foregroundColor(
                            isRefreshing
                                ? .secondary.opacity(0.5)
                                : .secondary
                        )
                        .rotationEffect(
                            .degrees(isRefreshing ? 360 : 0)
                        )
                        .animation(
                            isRefreshing
                                ? .linear(duration: 0.8)
                                  .repeatForever(
                                      autoreverses: false
                                  )
                                : .default,
                            value: isRefreshing
                        )
                }
                .buttonStyle(.plain)
                .help("Reload annotations")
                .disabled(isRefreshing)

                Spacer()

                // Metadata
                Text("#\(snapshot.number)")
                    .chromeFontMono(size: fontSize.caption2)
                    .foregroundColor(.secondary)
                Text(snapshot.title)
                    .chromeFont(size: fontSize.caption2, weight: .semibold)
                    .lineLimit(1)
                    .truncationMode(.tail)
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

                // Review with Claude button — always rendered for stable
                // layout, visibility controlled by opacity
                Button(action: { submitReview(snapshotId: snapshot.id) }) {
                    Text("Review with Claude")
                        .chromeFont(size: fontSize.caption2, weight: .medium)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.green)
                        )
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
                .opacity(hasUnreviewedAnnotations ? 1 : 0)
                .allowsHitTesting(hasUnreviewedAnnotations)

                CopyButton(
                    text: snapshot.content,
                    iconSize: fontSize.iconSmall
                )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(.windowBackgroundColor))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.primary.opacity(0.1))
                    .frame(height: 1)
            }

            // Markdown content with annotation support
            MarkdownReaderView(
                markdown: snapshot.content,
                isDark: colorScheme == .dark,
                annotations: openAnnotations,
                annotationHTMLMap: annotationHTMLMap,
                webViewRef: $webViewRef,
                onAnnotationMessage: { message in
                    handleAnnotationMessage(
                        message,
                        snapshotId: snapshot.id
                    )
                },
                itemLabel:
                    "Snapshot #\(snapshot.number)",
                baseUrlName: "snapshot-reader"
            )
        }
        .onChange(of: webViewRef) { _, newView in
            findController.bind(to: newView)
        }
        .onChange(of: openSnapshot?.number) { _, _ in
            findController.isVisible = false
        }
        .onChange(of: findController.isVisible) { _, _ in
            syncFindBarPanel()
        }
    }

    /// Show or hide the shared find-bar panel for this reader.
    /// Anchored to the WKWebView's top-right; see FindBarPanel
    /// for why the bar lives in a separate window.
    ///
    /// Self-gating: presents only when this view is the active
    /// surface (active session × snapshots tab) AND the
    /// controller's intent is visible AND the WKWebView anchor
    /// exists. Otherwise yields the panel using `dismiss(if:)`,
    /// which is a no-op when the panel is already bound to a
    /// different controller — safe to call from any
    /// tab/session-change observer without racing whichever
    /// surface just took ownership.
    private func syncFindBarPanel() {
        let amActive =
            sessionManager.activeSessionId == session.id
            && sessionManager.activeTab == .snapshots
        guard amActive,
              findController.isVisible,
              let anchor = webViewRef
        else {
            FindBarPanelController.shared
                .dismiss(if: findController)
            return
        }
        FindBarPanelController.shared.present(
            controller: findController,
            anchorView: anchor
        )
    }

    /// Bring up the find bar in the open snapshot reader.
    /// Called by the slice-4 Cmd+F dispatcher.
    func activateFind() {
        guard openSnapshot != nil else { return }
        findController.isVisible = true
        // Also call the panel sync directly. SwiftUI's
        // `.onChange(of: isVisible)` only fires on transitions,
        // so a re-press of Cmd+F while the bar is already
        // visible wouldn't otherwise reach the panel — and we
        // need it to reach the panel so the field gets
        // re-focused (Cmd+F when already open is the
        // refocus gesture).
        syncFindBarPanel()
    }

    /// Register this view as `SessionManager.snapshotsFindHandler`
    /// when it's the active surface (active session + snapshots
    /// tab). Re-registered from each onChange that affects either
    /// gate, plus onAppear for initial mount. See the matching
    /// note in `ArtifactsView.syncFindHandler` for the rationale
    /// — same per-instance fan-out fix; only the active surface's
    /// closure ends up in the slot.
    private func syncFindHandler() {
        guard sessionManager.activeSessionId == session.id,
              sessionManager.activeTab == .snapshots
        else { return }
        sessionManager.snapshotsFindHandler = {
            activateFind()
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
                    seedSnapshotTitles(result)
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

                // Fetch annotations using the snapshot's database ID
                let annotations = try await SnapshotQueryService.shared
                    .fetchAnnotations(snapshotId: detail.id)
                guard !Task.isCancelled else { return }

                // Pre-render annotation markdown to HTML
                var htmlMap: [Int32: String] = [:]
                for ann in annotations {
                    htmlMap[ann.number] = escapeAnnotationContent(ann.content)
                }

                await MainActor.run {
                    openSnapshot = detail
                    openAnnotations = annotations
                    annotationHTMLMap = htmlMap
                    isLoadingContent = false
                    hasUnreviewedAnnotations = annotations.contains {
                        $0.snapshotReviewId == nil
                    }

                    // Fire snapshot:opened duration event
                    let durationId =
                        "snapshot--\(UUID().uuidString)"
                    snapshotDurationId = durationId
                    TimelineService.record(
                        ledgerSessionId: lsid,
                        eventType: "snapshot:opened",
                        source:
                            "galaxy-app/views/snapshots",
                        durationIdentifier: durationId,
                        detailData: [
                            "snapshot_number":
                                detail.number,
                            "title": detail.title,
                        ]
                    )
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

    /// Check for unsaved annotation state before
    /// closing the reader.
    private func handleBackButton() {
        guard let wv = webViewRef else {
            closeReader()
            return
        }
        wv.evaluateJavaScript(
            "typeof AnnotationManager !== 'undefined'"
            + " ? AnnotationManager.getEscapeContext()"
            + " : 'close'"
        ) { result, _ in
            guard let context = result as? String
            else {
                DispatchQueue.main.async {
                    self.closeReader()
                }
                return
            }
            switch context {
            case "formHasText":
                guard let window = wv.window
                else { return }
                SheetAlert.confirm(
                    in: window,
                    message: "Discard annotation?",
                    detail: "You have unsaved text "
                        + "in the annotation form. "
                        + "It will be lost if you "
                        + "go back.",
                    onConfirm: { [self] in
                        self.closeReader()
                    }
                )
            case "editing":
                guard let window = wv.window
                else { return }
                SheetAlert.confirm(
                    in: window,
                    message: "Discard changes?",
                    detail: "You have unsaved changes"
                        + " to this annotation. They"
                        + " will be lost if you go"
                        + " back.",
                    onConfirm: { [self] in
                        self.closeReader()
                    }
                )
            default:
                DispatchQueue.main.async {
                    self.closeReader()
                }
            }
        }
    }

    private func closeReader(reason: String = "dismissed") {
        // Fire snapshot:closed duration event before
        // clearing state
        if let lsid = session.ledgerSessionId,
           let durationId = snapshotDurationId
        {
            var detailData: [String: Any] = [
                "reason": reason,
            ]
            if let snapshot = openSnapshot {
                detailData["snapshot_number"]
                    = snapshot.number
                detailData["title"] = snapshot.title
                detailData["annotation_count"]
                    = openAnnotations.count
            }
            TimelineService.record(
                ledgerSessionId: lsid,
                eventType: "snapshot:closed",
                source:
                    "galaxy-app/views/snapshots",
                durationIdentifier: durationId,
                detailData: detailData
            )
            snapshotDurationId = nil
        }

        let closingNumber = openSnapshot?.number
        removeEscapeMonitor()
        sessionManager.isSnapshotReaderOpen = false
        webViewRef = nil
        openSnapshot = nil  // Purge content from memory
        openAnnotations = []
        annotationHTMLMap = [:]
        hasUnreviewedAnnotations = false

        // Refocus the row that was open
        if let number = closingNumber {
            focusedIndex = sortedSnapshots.firstIndex(where: { $0.number == number })
        }
    }

    // MARK: - Active View State Sync

    /// Update isSnapshotReaderOpen to reflect whether the active view has
    /// a reader open. Only the active session participates in flag
    /// management — inactive sessions don't touch it.
    private func syncReaderOpenState() {
        guard session.id == sessionManager.activeSessionId else { return }
        if sessionManager.activeTab == .snapshots {
            sessionManager.isSnapshotReaderOpen = openSnapshot != nil
        } else {
            // Not on snapshots tab — reader isn't visible
            sessionManager.isSnapshotReaderOpen = false
        }
    }

    /// Install or remove the escape monitor based on whether this view
    /// is the active snapshots view with a reader open.
    private func updateEscapeMonitor() {
        let shouldBeInstalled = openSnapshot != nil
            && session.id == sessionManager.activeSessionId
            && sessionManager.activeTab == .snapshots
        if shouldBeInstalled {
            installEscapeMonitor()
        } else {
            removeEscapeMonitor()
        }
    }

    /// Restore AppKit first responder to the WKWebView when this view
    /// becomes the active visible view with a reader open. The JS-side
    /// focus state persists across opacity toggles, but AppKit drops
    /// first responder when the view is hidden — causing the beep on
    /// keystroke even though the textarea looks focused.
    private func restoreWebViewFocus() {
        guard session.id == sessionManager.activeSessionId,
              sessionManager.activeTab == .snapshots,
              openSnapshot != nil,
              let webView = webViewRef else { return }
        // Brief delay lets SwiftUI finish the opacity transition
        // before we hand first responder back to the web view.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            webView.window?.makeFirstResponder(webView)
        }
    }

    // MARK: - Escape Key (AppKit monitor)

    /// Install a local event monitor that catches Escape regardless of
    /// which AppKit responder (e.g. WKWebView) holds first responder.
    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            if event.keyCode == 53 {  // 53 = Escape
                // Defense in depth: only consume if we're the active view
                guard session.id == sessionManager.activeSessionId,
                      sessionManager.activeTab == .snapshots else {
                    return event
                }

                // Two-stage Esc: while find is open, the
                // first Esc closes find; subsequent Esc
                // falls through to the annotation/reader
                // close path below.
                if findController.isVisible {
                    findController.isVisible = false
                    return nil
                }

                // Query JS for current annotation context
                webViewRef?.evaluateJavaScript(
                    "typeof AnnotationManager !== 'undefined' ? AnnotationManager.getEscapeContext() : 'close'"
                ) { result, _ in
                    guard let context = result as? String else {
                        DispatchQueue.main.async { closeReader() }
                        return
                    }
                    switch context {
                    case "emojiPopup":
                        self.webViewRef?.evaluateJavaScript("""
                            (function() {
                                var ta = document.querySelector('.annotation-textarea:focus') ||
                                         document.querySelector('.annotation-edit-textarea:focus');
                                if (ta && typeof EmojiAutocomplete !== 'undefined') {
                                    EmojiAutocomplete.dismiss(ta);
                                }
                            })()
                        """)
                    case "editing":
                        self.showDiscardEditAlert()
                    case "expanded":
                        self.webViewRef?.evaluateJavaScript(
                            "AnnotationManager.collapseExpanded()"
                        )
                    case "formHasText":
                        self.showDiscardFormAlert()
                    case "formVisible":
                        self.webViewRef?.evaluateJavaScript(
                            "AnnotationManager.dismissForm()"
                        )
                    case "__consumed__":
                        break  // JS already handled it
                    default:
                        DispatchQueue.main.async { closeReader() }
                    }
                }
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

    /// Show an NSAlert asking to discard new annotation form content.
    /// On Discard: hides form and clears highlights. On Cancel: no-op.
    private func showDiscardFormAlert() {
        guard let window = webViewRef?.window else { return }

        SheetAlert.confirm(
            in: window,
            message: "Discard annotation?",
            detail: "You have unsaved text in the annotation "
                + "form. It will be lost if you dismiss.",
            onConfirm: { [self] in
                self.webViewRef?.evaluateJavaScript(
                    "AnnotationManager.dismissForm()"
                )
            }
        )
    }

    /// Show an NSAlert asking to discard edit changes.
    /// On Discard: cancels edit, returns to expanded card.
    /// On Cancel: no-op.
    private func showDiscardEditAlert() {
        guard let window = webViewRef?.window else { return }

        SheetAlert.confirm(
            in: window,
            message: "Discard changes?",
            detail: "You have unsaved changes to this "
                + "annotation. They will be lost if you "
                + "cancel editing.",
            onConfirm: { [self] in
                self.webViewRef?.evaluateJavaScript(
                    "AnnotationManager.cancelEdit()"
                )
            }
        )
    }

    /// Show an NSAlert asking to discard unsaved annotation form
    /// content before opening a new form at a different selection.
    private func showDragReplaceAnnotationAlert(
        startIdx: Int,
        endIdx: Int
    ) {
        guard let window = webViewRef?.window else { return }

        SheetAlert.confirm(
            in: window,
            message: "Discard annotation?",
            detail: "You have unsaved text in the annotation "
                + "form. It will be lost if you start a new "
                + "annotation.",
            onConfirm: { [self] in
                self.webViewRef?.evaluateJavaScript(
                    "AnnotationManager"
                    + ".showFormForSelection("
                    + "\(startIdx), \(endIdx))"
                )
            },
            onCancel: { [self] in
                self.webViewRef?.evaluateJavaScript(
                    "AnnotationManager.focusForm()"
                )
            }
        )
    }

    private func handlePendingSnapshot() {
        guard let number = sessionManager.pendingSnapshotNumber else { return }
        sessionManager.pendingSnapshotNumber = nil
        openSnapshotByNumber(
            number, reason: "auto-open", trigger: "auto-open"
        )
    }

    /// Fetch the snapshot list and open the snapshot with the given
    /// number. Shared entry point for both EventCoordinator-driven
    /// opens and history restoration (back/forward navigation).
    private func openSnapshotByNumber(
        _ number: Int32, reason: String, trigger: String
    ) {
        // Close any currently-open snapshot so its
        // duration event fires and state is cleaned up.
        if openSnapshot != nil {
            closeReader(reason: reason)
        }

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
                        seedSnapshotTitles(list)
                        isLoading = false
                    }
                    return  // Fail silently — unknown ref
                }

                let detail = try await SnapshotQueryService.shared
                    .fetchSnapshotContent(ledgerSessionId: lsid, number: number)
                guard !Task.isCancelled else { return }

                // Fetch annotations for the snapshot
                let annotations = try await SnapshotQueryService.shared
                    .fetchAnnotations(snapshotId: detail.id)
                guard !Task.isCancelled else { return }

                var htmlMap: [Int32: String] = [:]
                for ann in annotations {
                    htmlMap[ann.number] = escapeAnnotationContent(ann.content)
                }

                await MainActor.run {
                    snapshots = list
                    seedSnapshotTitles(list)
                    isLoading = false
                    openSnapshot = detail
                    openAnnotations = annotations
                    annotationHTMLMap = htmlMap
                    hasUnreviewedAnnotations = annotations.contains {
                        $0.snapshotReviewId == nil
                    }

                    // Fire snapshot:opened duration
                    // event for the auto-opened
                    // snapshot.
                    let durationId =
                        "snapshot--\(UUID().uuidString)"
                    snapshotDurationId = durationId
                    TimelineService.record(
                        ledgerSessionId: lsid,
                        eventType: "snapshot:opened",
                        source:
                            "galaxy-app/views/snapshots",
                        durationIdentifier: durationId,
                        detailData: [
                            "snapshot_number":
                                detail.number,
                            "title": detail.title,
                            "trigger": trigger,
                        ]
                    )
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    isLoading = false
                }
            }
        }
    }

    /// Seed the session's snapshot title cache so
    /// NavigationCoordinator can resolve history
    /// entry titles at push time.
    private func seedSnapshotTitles(
        _ list: [SnapshotSummary]
    ) {
        for snap in list {
            session.recordSnapshotInfo(
                number: snap.number, title: snap.title
            )
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

    // MARK: - Annotation Messages

    private func handleAnnotationMessage(_ message: AnnotationMessage, snapshotId: Int64) {
        switch message {
        case .create(let startLine, let endLine, let content):
            Task {
                do {
                    let annotation = try await SnapshotQueryService.shared
                        .createAnnotation(
                            snapshotId: snapshotId,
                            startLine: startLine,
                            endLine: endLine,
                            content: content
                        )
                    let html = escapeAnnotationContent(annotation.content)
                    await MainActor.run {
                        openAnnotations.append(annotation)
                        openAnnotations.sort {
                            ($0.startLine, $0.endLine, $0.number) <
                            ($1.startLine, $1.endLine, $1.number)
                        }
                        annotationHTMLMap[annotation.number] = html
                    }
                    let payload = buildAnnotationPayload(
                        annotation: annotation, renderedHTML: html
                    )
                    await MainActor.run {
                        webViewRef?.evaluateJavaScript(
                            "AnnotationManager.annotationCreated(\(payload))"
                        )
                    }
                } catch {
                    NSLog("SnapshotsView: create annotation error: %@",
                          error.localizedDescription)
                }
            }

        case .update(let number, let content):
            Task {
                do {
                    let annotation = try await SnapshotQueryService.shared
                        .updateAnnotation(
                            snapshotId: snapshotId,
                            number: number,
                            content: content
                        )
                    let html = escapeAnnotationContent(annotation.content)
                    await MainActor.run {
                        if let idx = openAnnotations.firstIndex(where: {
                            $0.number == number
                        }) {
                            openAnnotations[idx] = annotation
                        }
                        annotationHTMLMap[annotation.number] = html
                    }
                    let payload = buildAnnotationPayload(
                        annotation: annotation, renderedHTML: html
                    )
                    await MainActor.run {
                        webViewRef?.evaluateJavaScript(
                            "AnnotationManager.annotationUpdated(\(payload))"
                        )
                    }
                } catch {
                    NSLog("SnapshotsView: update annotation error: %@",
                          error.localizedDescription)
                }
            }

        case .delete(let number):
            Task {
                do {
                    try await SnapshotQueryService.shared
                        .deleteAnnotation(
                            snapshotId: snapshotId,
                            number: number
                        )
                    await MainActor.run {
                        openAnnotations.removeAll { $0.number == number }
                        annotationHTMLMap.removeValue(forKey: number)
                        webViewRef?.evaluateJavaScript(
                            "AnnotationManager.annotationDeleted(\(number))"
                        )
                    }
                } catch {
                    NSLog("SnapshotsView: delete annotation error: %@",
                          error.localizedDescription)
                }
            }

        case .confirmDragReplace(let startIdx, let endIdx):
            showDragReplaceAnnotationAlert(
                startIdx: startIdx,
                endIdx: endIdx
            )
        case .createDiffRange, .createRowRange,
             .createBlockRange, .createWhole,
             .setViewed:
            // Not applicable for snapshots — only the
            // diff reader emits these. `.setViewed`
            // is routed to ViewedFilesPersistence from
            // ArtifactsView; snapshots have no file
            // cards, so nothing to persist here.
            break
        }
    }

    /// Serialize an annotation + rendered HTML to a JSON string for JS injection.
    private func buildAnnotationPayload(
        annotation: SnapshotAnnotation, renderedHTML: String
    ) -> String {
        var annDict: [String: Any] = [
            "id": annotation.id,
            "number": annotation.number,
            "start_line": annotation.startLine,
            "end_line": annotation.endLine,
            "content": annotation.content,
            "created_at": annotation.createdAt,
            "updated_at": annotation.updatedAt
        ]
        if let rn = annotation.reviewNumber {
            annDict["review_number"] = rn
        }
        if let rra = annotation.reviewReviewedAt {
            annDict["review_reviewed_at"] = rra
        }
        let dict: [String: Any] = [
            "annotation": annDict,
            "renderedHTML": renderedHTML
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    // MARK: - Review Actions

    private func checkReviewButtonVisibility(snapshotId: Int64) {
        Task {
            do {
                let hasPending = try await SnapshotQueryService.shared
                    .checkHasPending(snapshotId: snapshotId)
                await MainActor.run {
                    hasUnreviewedAnnotations = hasPending
                }
            } catch {
                NSLog("SnapshotsView: checkReviewButton error: %@",
                      error.localizedDescription)
            }
        }
    }

    private func submitReview(snapshotId: Int64) {
        hasUnreviewedAnnotations = false  // Immediate, prevents double-click
        guard let lsid = session.ledgerSessionId else { return }
        guard let snapshotNumber = openSnapshot?.number else { return }
        closeReader(reason: "reviewed")

        Task {
            let needsResume = await MainActor.run { session.hasExited }

            if needsResume {
                // Pre-validate: can we actually resume?
                let dirExists = await MainActor.run {
                    FileManager.default.fileExists(
                        atPath: session.workingDirectory
                    )
                }
                guard dirExists else {
                    NSLog("SnapshotsView: submitReview aborted — "
                          + "working directory gone, skipping review "
                          + "creation to preserve unreviewed annotations")
                    await MainActor.run {
                        hasUnreviewedAnnotations = true
                    }
                    return
                }

                // Build message before entering the closure — it only
                // needs lsid and snapshotNumber, not the review result.
                let message = buildReviewMessage(
                    ledgerSessionId: lsid,
                    snapshotNumber: snapshotNumber
                )

                // Register the review action and resume in a
                // SINGLE MainActor.run block so registration
                // happens before resumeSession kicks off the new
                // process. The queued action fires on the next
                // endTurn — which is /galaxy:resume's turn end,
                // since that's the first turn the resumed session
                // runs.
                await MainActor.run {
                    session.onceAfterTurnEnd { [weak session] in
                        DispatchQueue.main.asyncAfter(
                            deadline: .now() + 3.0
                        ) {
                            Task { [weak session] in
                                guard let session = session else {
                                    return
                                }
                                do {
                                    // Create review at +3s, right
                                    // before sending — no orphan if
                                    // session dies during boot.
                                    let _ = try await
                                        SnapshotQueryService.shared
                                        .createReview(
                                            snapshotId: snapshotId
                                        )
                                    await MainActor.run {
                                        recordSnapshotReviewedEvent(
                                            ledgerSessionId: lsid,
                                            snapshotId: snapshotId
                                        )
                                    }
                                    await MainActor.run {
                                        session.sendCommand(message)
                                    }
                                    // Refresh so cards reflect
                                    // review assignment
                                    await reloadAnnotations(
                                        snapshotId: snapshotId
                                    )
                                } catch {
                                    await MainActor.run {
                                        hasUnreviewedAnnotations = true
                                    }
                                    NSLog(
                                        "SnapshotsView: submitReview"
                                        + " error: %@",
                                        error.localizedDescription
                                    )
                                }
                            }
                        }
                    }

                    // Resume the session. Internally calls
                    // startProcess and gates /galaxy:resume on
                    // the on_resume hook's session:ready event
                    // via waitForReady.
                    sessionManager.resumeSession(
                        sessionId: session.id
                    )
                }
            } else {
                // Session is running — create review and send
                do {
                    let _ = try await SnapshotQueryService.shared
                        .createReview(snapshotId: snapshotId)

                    await MainActor.run {
                        recordSnapshotReviewedEvent(
                            ledgerSessionId: lsid,
                            snapshotId: snapshotId
                        )
                    }

                    let message = buildReviewMessage(
                        ledgerSessionId: lsid,
                        snapshotNumber: snapshotNumber
                    )

                    await MainActor.run {
                        sessionManager.activeTab = .terminal
                        session.sendCommand(message)
                    }

                    // Refresh so cards reflect review assignment
                    await reloadAnnotations(
                        snapshotId: snapshotId
                    )
                } catch {
                    await MainActor.run {
                        hasUnreviewedAnnotations = true
                    }
                    NSLog("SnapshotsView: submitReview error: %@",
                          error.localizedDescription)
                }
            }
        }
    }

    /// Entry point for the reader's refresh button.
    ///
    /// Snapshot content is immutable, so the only thing a refresh can
    /// pick up is annotations created or removed outside the reader —
    /// by an agent working through the CLI, most often. Rebuilding the
    /// cards tears down an open form or an in-progress edit with them,
    /// so text typed but not saved is confirmed away rather than
    /// disappearing without warning.
    private func requestRefreshCurrentSnapshot(snapshotId: Int64) {
        guard !isRefreshing else { return }
        guard let wv = webViewRef, let window = wv.window else {
            refreshCurrentSnapshot(snapshotId: snapshotId)
            return
        }
        wv.evaluateJavaScript(
            "typeof AnnotationManager !== 'undefined' "
            + "? AnnotationManager.hasOpenUnsavedComment() : false"
        ) { [self] result, _ in
            guard (result as? Bool) == true else {
                refreshCurrentSnapshot(snapshotId: snapshotId)
                return
            }
            SheetAlert.confirm(
                in: window,
                message: "Discard unsaved annotation?",
                detail: "Refreshing rebuilds the annotation cards. "
                    + "Text you have typed but not saved will be "
                    + "lost.",
                confirm: "Refresh",
                onConfirm: {
                    refreshCurrentSnapshot(snapshotId: snapshotId)
                }
            )
        }
    }

    private func refreshCurrentSnapshot(snapshotId: Int64) {
        isRefreshing = true
        Task {
            await reloadAnnotations(snapshotId: snapshotId)
            await MainActor.run { isRefreshing = false }
        }
    }

    /// Re-fetch the annotation set from the CLI and rebuild the
    /// reader's cards from it.
    ///
    /// Used after submitting a review, so cards pick up their review
    /// metadata and lose their edit and delete buttons, and by the
    /// refresh button, so annotations created or removed outside the
    /// reader show up. No-ops if the reader has closed or moved to a
    /// different snapshot.
    private func reloadAnnotations(
        snapshotId: Int64
    ) async {
        do {
            let annotations = try await SnapshotQueryService.shared
                .fetchAnnotations(snapshotId: snapshotId)

            var htmlMap: [Int32: String] = [:]
            for ann in annotations {
                htmlMap[ann.number] = escapeAnnotationContent(ann.content)
            }

            await MainActor.run {
                // Guard against stale snapshot
                guard openSnapshot?.id == snapshotId else { return }

                openAnnotations = annotations
                annotationHTMLMap = htmlMap
                hasUnreviewedAnnotations = annotations.contains {
                    $0.snapshotReviewId == nil
                }

                // Push updated annotations to JS for card re-render
                let annotationDicts: [[String: Any]] =
                    annotations.map { a in
                        var dict: [String: Any] = [
                            "id": a.id,
                            "number": a.number,
                            "start_line": a.startLine,
                            "end_line": a.endLine,
                            "content": a.content,
                            "created_at": a.createdAt,
                            "updated_at": a.updatedAt
                        ]
                        if let rn = a.reviewNumber {
                            dict["review_number"] = rn
                        }
                        if let rra = a.reviewReviewedAt {
                            dict["review_reviewed_at"] = rra
                        }
                        return dict
                    }
                if let data = try? JSONSerialization.data(
                    withJSONObject: annotationDicts
                ),
                   let json = String(
                       data: data, encoding: .utf8
                   ) {
                    webViewRef?.evaluateJavaScript(
                        "AnnotationManager"
                        + ".refreshAnnotationData(\(json))"
                    )
                }
            }
        } catch {
            NSLog("SnapshotsView: refreshAnnotations error: %@",
                  error.localizedDescription)
        }
    }

    private func buildReviewMessage(
        ledgerSessionId: Int64,
        snapshotNumber: Int32
    ) -> String {
        let sid = ledgerSessionId
        let sn = snapshotNumber
        return "I've submitted snapshot annotations for your review."
            + " List pending reviews with"
            + " `galaxy-snapshots review list --json --pending"
            + " --ledger-session-id \(sid) --snapshot \(sn)`,"
            + " view each with"
            + " `galaxy-snapshots review view --json"
            + " --ledger-session-id \(sid) --snapshot \(sn) REVIEW_NUMBER`,"
            + " mark each reviewed with"
            + " `galaxy-snapshots review mark-reviewed"
            + " --ledger-session-id \(sid) --snapshot \(sn) REVIEW_NUMBER`,"
            + " then respond to each annotation in the conversation."
    }

    /// Record a snapshot:reviewed timeline event with expanded
    /// annotation content. Fire-and-forget — safe to call from
    /// any context.
    private func recordSnapshotReviewedEvent(
        ledgerSessionId: Int64,
        snapshotId: Int64
    ) {
        guard let snapshot = openSnapshot else { return }
        let annotations = openAnnotations

        let lines = snapshot.content.components(
            separatedBy: "\n"
        )

        // Build expanded annotations array. Annotation lines
        // are 1-based (from swift-markdown SourceRange).
        let expandedAnnotations: [[String: Any]] = annotations
            .map { ann in
                let start = max(Int(ann.startLine) - 1, 0)
                let end = min(
                    Int(ann.endLine), lines.count
                )
                let lineContent = lines[start..<end]
                    .joined(separator: "\n")

                return [
                    "number": ann.number,
                    "start_line": ann.startLine,
                    "end_line": ann.endLine,
                    "line_content": lineContent,
                    "annotation": ann.content,
                ] as [String: Any]
            }

        let detailData: [String: Any] = [
            "snapshot_id": snapshotId,
            "snapshot_number": snapshot.number,
            "title": snapshot.title,
            "exchange_count": snapshot.exchangeCount,
            "char_count": snapshot.charCount,
            "annotation_count": annotations.count,
            "annotations": expandedAnnotations,
        ]

        TimelineService.recordViaStdin(
            ledgerSessionId: ledgerSessionId,
            eventType: "snapshot:reviewed",
            source: "galaxy-app/views/snapshots",
            detailData: detailData
        )
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
