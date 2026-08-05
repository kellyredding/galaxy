import SwiftUI
import WebKit
import Galactic

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

    /// Whether this view is the surface in front of the user — both halves,
    /// composed once, the way `ContentView` composes the terminal's. See
    /// `ArtifactsView`'s twin for what goes wrong without it.
    private var isVisibleSurface: Bool {
        session.id == sessionManager.activeSessionId
            && sessionManager.activeTab == .snapshots
    }

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
    // How many annotations a review would carry, which is what the
    // reader's send bar reports.
    @State private var pendingAnnotationCount: Int = 0

    // Duration tracking for timeline events
    @State private var snapshotDurationId: String? = nil

    /// Order and selection. The selection is an identity rather than a row
    /// number, so re-sorting cannot slide the highlight onto another snapshot.
    @State private var model = ListSortModel<SnapshotSummary, SortColumn>(
        columns: SnapshotsView.columns,
        sortColumn: .number,
        sortAscending: true)

    enum SortColumn {
        case number, title, exchanges, size, reviews, created
    }

    /// What each column is called and how it orders. A count, a size or a
    /// timestamp opens at its largest, which is what a reader picking that
    /// column is after; text opens at A.
    private static let columns: [ListColumn<SnapshotSummary, SortColumn>] = [
        .init(.number, title: "#") {
            ListSorting.compare($0.number, $1.number)
        },
        .init(.title, title: "Title") {
            ListSorting.compareText($0.title, $1.title)
        },
        .init(.exchanges, title: "Exchanges", prefersAscending: false) {
            ListSorting.compare($0.exchangeCount, $1.exchangeCount)
        },
        .init(.size, title: "Size", prefersAscending: false) {
            ListSorting.compare($0.charCount, $1.charCount)
        },
        .init(.reviews, title: "Reviews", prefersAscending: false) {
            ListSorting.compare($0.reviewCount, $1.reviewCount)
        },
        .init(.created, title: "Created", prefersAscending: false) {
            ListSorting.compare($0.createdAt, $1.createdAt)
        },
    ]

    private var sortedSnapshots: [SnapshotSummary] { model.sorted(snapshots) }

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
        .listNavigation(
            from: sessionManager,
            isActive: {
                session.id == sessionManager.activeSessionId
                    && sessionManager.activeTab == .snapshots
                    && openSnapshot == nil
            },
            onAction: { action in
                switch action {
                case .up: model.move(.up, in: sortedSnapshots)
                case .down: model.move(.down, in: sortedSnapshots)
                case .activate:
                    if let snap = model.focusedElement(in: sortedSnapshots) {
                        openSnapshotReader(number: snap.number)
                    }
                }
            })
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
                        LazyVStack(alignment: .leading, spacing: 0) {
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
                    .onChange(of: model.focusedId) {
                        if let id = model.focusedId {
                            scrollProxy.scrollTo(id)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Index Header

    private var headerRow: some View {
        HStack(spacing: 0) {
            sortableHeader(.number, width: 40)
            sortableHeader(.title, width: nil)
            sortableHeader(.exchanges, width: 90)
            sortableHeader(.size, width: 80)
            sortableHeader(.reviews, width: 70)
            sortableHeader(.created, width: 160)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color.primary.opacity(0.05))
    }

    private func sortableHeader(_ column: SortColumn, width: CGFloat?) -> some View {
        Button(action: { model.select(column) }) {
            HStack(spacing: 3) {
                Text(model.title(for: column))
                    .chromeFont(size: fontSize.caption2, weight: .semibold)
                    .foregroundColor(.secondary)
                if model.sortColumn == column {
                    Image(
                        systemName: model.sortAscending
                            ? "chevron.up" : "chevron.down"
                    )
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
        let isFocused = model.focusedId == snap.id

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

                Text(ListTimestamp.format(snap.createdAt))
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
                Text(ListTimestamp.format(snapshot.createdAt))
                    .chromeFont(size: fontSize.caption2)
                    .foregroundColor(.secondary)

                Spacer()

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
                pendingReviewCount: pendingAnnotationCount,
                isVisibleSurface: isVisibleSurface,
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
                    // Seeded at the last row, which is the end this list
                    // scrolls to when it appears.
                    model.reconcileFocus(
                        in: model.sorted(result), seed: .last)
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
                    recountPending(annotations)

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

    /// Ask about anything typed before closing the reader.
    ///
    /// Deliberately not the escape-key logic. Escape unwinds
    /// whatever layer is outermost; Back is leaving, and the only
    /// thing it needs to know is what text it would take along —
    /// which is one question, whatever else happens to be on top
    /// of it. Asking the layer question here is what used to let
    /// an open emoji popup or an expanded card send Back straight
    /// past a half-written annotation underneath.
    private func handleBackButton() {
        guard let wv = webViewRef else {
            closeReader()
            return
        }
        wv.evaluateJavaScript(
            "typeof AnnotationManager !== 'undefined'"
            + " ? AnnotationManager.unsavedTextKind()"
            + " : 'none'"
        ) { result, _ in
            let kind = (result as? String) ?? "none"
            DispatchQueue.main.async {
                self.confirmBack(kind: kind, in: wv)
            }
        }
    }

    private func confirmBack(kind: String, in wv: WKWebView) {
        // A theme change carries all three of these across. Back
        // ends the page for good, so it is the one that asks.
        let prompt: (message: String, detail: String)?
        switch kind {
        case "comment":
            prompt = (
                "Discard your comment?",
                "You have an unsent overall comment on the "
                    + "send bar. It will be lost if you go back."
            )
        case "edit":
            prompt = (
                "Discard changes?",
                "You have unsaved changes to this annotation. "
                    + "They will be lost if you go back."
            )
        case "form":
            prompt = (
                "Discard annotation?",
                "You have unsaved text in the annotation form. "
                    + "It will be lost if you go back."
            )
        default:
            prompt = nil
        }
        guard let prompt else {
            closeReader()
            return
        }
        guard let window = wv.window else { return }
        SheetAlert.confirm(
            in: window,
            message: prompt.message,
            detail: prompt.detail,
            onConfirm: { [self] in
                self.closeReader()
            }
        )
    }

    /// Call one of the reader page's own actions.
    ///
    /// Named rather than inlined so the escape switch reads as a
    /// list of decisions instead of a list of scripts — the emoji
    /// case in particular used to be a seven-line function
    /// literal, written out twice in this app.
    private func runInReader(_ call: String) {
        webViewRef?.evaluateJavaScript(
            "typeof AnnotationManager !== 'undefined'"
            + " ? AnnotationManager.\(call) : null"
        )
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

        removeEscapeMonitor()
        sessionManager.isSnapshotReaderOpen = false
        webViewRef = nil
        openSnapshot = nil  // Purge content from memory
        openAnnotations = []
        annotationHTMLMap = [:]
        // Set directly rather than through setPendingCount: the web view is
        // already gone, so there is nothing left to tell.
        pendingAnnotationCount = 0

        // Nothing to refocus: the selection is the row's identity, so it
        // survived the round trip through the reader on its own.
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
    ///
    /// A binding added here also needs a row in `KeystrokeCatalog`, with an
    /// availability case naming its gate — nothing fails to say so, because
    /// the catalog restates these facts rather than deriving them.
    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            // Stand down while the cheat sheet claims the keyboard. Its
            // two-stage Escape closes find, then the annotation, then the
            // reader — three things behind the sheet, none of them what
            // the reader pressing Escape meant. A gate rather than an
            // ordering assumption: AppKit does not contract the order
            // local monitors run in.
            if KeystrokeSheetModel.isClaimingKeyboard { return event }

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
                // Which layer is outermost. Asking changes nothing, so
                // every case below names the action it wants — including
                // the two the question used to perform on its own, and
                // which Back had no way to decline.
                webViewRef?.evaluateJavaScript(
                    "typeof AnnotationManager !== 'undefined' ? AnnotationManager.escapeContext() : 'close'"
                ) { result, _ in
                    guard let context = result as? String else {
                        DispatchQueue.main.async { closeReader() }
                        return
                    }
                    switch context {
                    case "emojiPopup":
                        self.runInReader("dismissEmojiPopup()")
                    case "overallComment":
                        self.runInReader("collapseOverallComment()")
                    case "editingDirty":
                        self.showDiscardEditAlert()
                    case "editingClean":
                        self.runInReader("cancelEdit()")
                    case "expanded":
                        self.runInReader("collapseExpanded()")
                    case "formHasText":
                        self.showDiscardFormAlert()
                    case "formVisible":
                        self.runInReader("dismissForm()")
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
                + "form. It will be lost if you select a "
                + "different range.",
            onConfirm: { [self] in
                self.webViewRef?.evaluateJavaScript(
                    "AnnotationManager"
                    + ".showSelectionToolbar("
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
                    recountPending(annotations)

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
        case .reviewWithClaude(let comment):
            guard let snapshot = openSnapshot else { break }
            submitReview(snapshotId: snapshot.id, comment: comment)
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

    // MARK: - Pending Count

    /// Recount what a review would carry, from the annotations in hand.
    ///
    /// No staleness term, unlike the artifact readers: a snapshot's content
    /// cannot change under an annotation, so nothing can go stale.
    private func recountPending(_ annotations: [SnapshotAnnotation]) {
        setPendingCount(
            annotations.filter { $0.snapshotReviewId == nil }.count
        )
    }

    /// Store the count and tell the open reader.
    private func setPendingCount(_ count: Int) {
        pendingAnnotationCount = count
        webViewRef?.evaluateJavaScript(
            "window.GalaxySendBar.update(\(count))"
        )
    }

    // MARK: - Review Actions

    /// Re-count the open snapshot's unreviewed annotations, so the send bar
    /// stays truthful when annotations are created or deleted outside the
    /// reader — by an agent working through the CLI, most often.
    ///
    /// This is why the count is stored rather than derived from
    /// `openAnnotations`: that array is the reader's view and goes stale
    /// precisely in this case, so the database is asked instead.
    private func checkReviewButtonVisibility(snapshotId: Int64) {
        Task {
            do {
                let pending = try await SnapshotQueryService.shared
                    .checkPendingCount(snapshotId: snapshotId)
                await MainActor.run {
                    setPendingCount(pending)
                }
            } catch {
                NSLog("SnapshotsView: checkReviewButton error: %@",
                      error.localizedDescription)
            }
        }
    }

    private func submitReview(snapshotId: Int64, comment: String) {
        // Optimistic, to stop a second press landing while the first is
        // still in flight. Every failure path below puts the real count back.
        setPendingCount(0)
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
                        recountPending(openAnnotations)
                    }
                    return
                }

                // Build message before entering the closure — it only
                // needs lsid and snapshotNumber, not the review result.
                let message = buildReviewMessage(
                    ledgerSessionId: lsid,
                    snapshotNumber: snapshotNumber,
                    comment: comment
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
                                        recountPending(openAnnotations)
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
                        snapshotNumber: snapshotNumber,
                        comment: comment
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
                        recountPending(openAnnotations)
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
                recountPending(annotations)

                // Push updated annotations to JS for card re-render
                let annotationDicts =
                    annotations.map(readerAnnotationDict)
                // Ship the card bodies alongside the records. A
                // refresh can introduce annotations the page has
                // never rendered, and those have no entry in its
                // map yet.
                var jsHtmlMap: [String: String] = [:]
                for a in annotations {
                    jsHtmlMap[String(a.number)] =
                        escapeAnnotationContent(a.content)
                }
                if let data = try? JSONSerialization.data(
                    withJSONObject: annotationDicts
                ),
                   let json = String(
                       data: data, encoding: .utf8
                   ),
                   let mapData = try? JSONSerialization.data(
                       withJSONObject: jsHtmlMap
                   ),
                   let mapJson = String(
                       data: mapData, encoding: .utf8
                   ) {
                    webViewRef?.evaluateJavaScript(
                        "AnnotationManager"
                        + ".refreshAnnotationData("
                        + "\(json), \(mapJson))"
                    )
                }
            }
        } catch {
            NSLog("SnapshotsView: refreshAnnotations error: %@",
                  error.localizedDescription)
        }
    }

    /// The message the agent is sent, with the reader's overall comment ahead
    /// of it.
    ///
    /// The comment leads for the reason it leads a code review: it is what the
    /// whole set is about, and everything after it here is a set of commands
    /// for fetching the parts. Blank leaves the message exactly as it was.
    private func buildReviewMessage(
        ledgerSessionId: Int64,
        snapshotNumber: Int32,
        comment: String
    ) -> String {
        let lead = comment.isEmpty ? "" : comment + "\n\n"
        let sid = ledgerSessionId
        let sn = snapshotNumber
        return lead
            + "I've submitted snapshot annotations for your review."
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

    private func formatCharCount(_ count: Int32) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }
}
