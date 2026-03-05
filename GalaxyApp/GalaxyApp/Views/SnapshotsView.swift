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

    // Review state
    @State private var hasUnreviewedAnnotations: Bool = false

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
        }
        .onChange(of: sessionManager.activeSessionId) {
            syncReaderOpenState()
            updateEscapeMonitor()
            restoreWebViewFocus()
        }
        .onChange(of: sessionManager.activeTab) {
            syncReaderOpenState()
            updateEscapeMonitor()
            restoreWebViewFocus()
            // Refresh snapshot list when returning to snapshots tab
            if sessionManager.activeTab == .snapshots,
               session.id == sessionManager.activeSessionId,
               openSnapshot == nil {
                fetchSnapshotList()
            }
        }
        .onAppear {
            if sessionManager.pendingSnapshotNumber != nil,
               session.id == sessionManager.activeSessionId {
                handlePendingSnapshot()
            } else {
                fetchSnapshotList()
            }
        }
        .onChange(of: sessionManager.pendingSnapshotNumber) {
            guard session.id == sessionManager.activeSessionId else { return }
            handlePendingSnapshot()
        }
        .onChange(of: sessionManager.listNavAction) {
            guard session.id == sessionManager.activeSessionId else { return }
            guard sessionManager.activeTab == .snapshots else { return }
            guard openSnapshot == nil else { return }
            guard let action = sessionManager.listNavAction else { return }
            sessionManager.listNavAction = nil
            handleListNavAction(action)
        }
        .onChange(of: sessionManager.annotationAction) {
            guard session.id == sessionManager.activeSessionId else { return }
            guard sessionManager.activeTab == .snapshots else { return }
            guard let action = sessionManager.annotationAction else { return }
            sessionManager.annotationAction = nil
            handleAnnotationAction(action)
        }
        .onChange(of: sessionManager.pendingReviewCheck) {
            guard session.id == sessionManager.activeSessionId else { return }
            guard let snapshotId = sessionManager.pendingReviewCheck,
                  let open = openSnapshot,
                  snapshotId == open.id else { return }
            sessionManager.pendingReviewCheck = nil
            checkReviewButtonVisibility(snapshotId: snapshotId)
        }
        .onDisappear {
            // Fires when session is removed from sessions array
            fetchTask?.cancel()
            fetchTask = nil
            SnapshotQueryService.shared.cancelAll()
            removeEscapeMonitor()
            if session.id == sessionManager.activeSessionId {
                sessionManager.isSnapshotReaderOpen = false
            }
            webViewRef = nil
            openSnapshot = nil
            openAnnotations = []
            annotationHTMLMap = [:]
            hasUnreviewedAnnotations = false
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
                snapshotNumber: snapshot.number,
                annotations: openAnnotations,
                annotationHTMLMap: annotationHTMLMap,
                webViewRef: $webViewRef,
                onAnnotationMessage: { message in
                    handleAnnotationMessage(message, snapshotId: snapshot.id)
                }
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

                // Fetch annotations using the snapshot's database ID
                let annotations = try await SnapshotQueryService.shared
                    .fetchAnnotations(ledgerSnapshotId: detail.id)
                guard !Task.isCancelled else { return }

                // Pre-render annotation markdown to HTML
                var htmlMap: [Int32: String] = [:]
                for ann in annotations {
                    htmlMap[ann.number] = renderAnnotationHTML(ann.content)
                }

                await MainActor.run {
                    openSnapshot = detail
                    openAnnotations = annotations
                    annotationHTMLMap = htmlMap
                    isLoadingContent = false
                    hasUnreviewedAnnotations = annotations.contains {
                        $0.ledgerSnapshotReviewId == nil
                    }
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
    /// Three-stage behavior: cancel edit -> clear form text -> close reader.
    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            if event.keyCode == 53 {  // 53 = Escape
                // Defense in depth: only consume if we're the active view
                guard session.id == sessionManager.activeSessionId,
                      sessionManager.activeTab == .snapshots else {
                    return event
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
                        self.webViewRef?.evaluateJavaScript(
                            "AnnotationManager.cancelEdit()"
                        )
                    case "expanded":
                        self.webViewRef?.evaluateJavaScript(
                            "AnnotationManager.collapseExpanded(); AnnotationManager.focusTextarea()"
                        )
                    case "formHasText":
                        self.webViewRef?.evaluateJavaScript(
                            "AnnotationManager.clearForm()"
                        )
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

                // Fetch annotations for the snapshot
                let annotations = try await SnapshotQueryService.shared
                    .fetchAnnotations(ledgerSnapshotId: detail.id)
                guard !Task.isCancelled else { return }

                var htmlMap: [Int32: String] = [:]
                for ann in annotations {
                    htmlMap[ann.number] = renderAnnotationHTML(ann.content)
                }

                await MainActor.run {
                    snapshots = list
                    isLoading = false
                    openSnapshot = detail
                    openAnnotations = annotations
                    annotationHTMLMap = htmlMap
                    hasUnreviewedAnnotations = annotations.contains {
                        $0.ledgerSnapshotReviewId == nil
                    }
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

    // MARK: - Annotation Actions

    private func handleAnnotationAction(_ action: AnnotationAction) {
        guard openSnapshot != nil else { return }
        let jsFunction: String
        switch action {
        case .moveUp: jsFunction = "AnnotationManager.moveUp()"
        case .moveDown: jsFunction = "AnnotationManager.moveDown()"
        case .extendUp: jsFunction = "AnnotationManager.extendHighlightUp()"
        case .extendDown: jsFunction = "AnnotationManager.extendHighlightDown()"
        }
        webViewRef?.evaluateJavaScript(jsFunction)
    }

    private func handleAnnotationMessage(_ message: AnnotationMessage, snapshotId: Int64) {
        switch message {
        case .create(let startLine, let endLine, let content):
            Task {
                do {
                    let annotation = try await SnapshotQueryService.shared
                        .createAnnotation(
                            ledgerSnapshotId: snapshotId,
                            startLine: startLine,
                            endLine: endLine,
                            content: content
                        )
                    let html = renderAnnotationHTML(annotation.content)
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
                            ledgerSnapshotId: snapshotId,
                            number: number,
                            content: content
                        )
                    let html = renderAnnotationHTML(annotation.content)
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
                            ledgerSnapshotId: snapshotId,
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
                    .checkHasPending(ledgerSnapshotId: snapshotId)
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

                // Register review action and resume in a SINGLE
                // MainActor.run block so both afterNextIdle calls
                // happen before the process starts. See plan for
                // the arming invariant.
                //
                // Timing: afterNextIdle actions fire together in a
                // single drain loop. /handoff uses asyncAfter(+1.0),
                // the review uses asyncAfter(+3.0). Both schedule
                // from the same instant, giving ~2s gap.
                await MainActor.run {
                    session.afterNextIdle { [weak session] in
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
                                            ledgerSnapshotId: snapshotId
                                        )
                                    await MainActor.run {
                                        session.sendCommand(message)
                                    }
                                    // Refresh so cards reflect
                                    // review assignment
                                    await refreshAnnotationsAfterReview(
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

                    // Resume the session. Internally registers
                    // /handoff via afterNextIdle (at +1s) and calls
                    // startProcess.
                    sessionManager.resumeSession(
                        sessionId: session.id
                    )
                }
            } else {
                // Session is running — create review and send
                do {
                    let _ = try await SnapshotQueryService.shared
                        .createReview(ledgerSnapshotId: snapshotId)

                    let message = buildReviewMessage(
                        ledgerSessionId: lsid,
                        snapshotNumber: snapshotNumber
                    )

                    await MainActor.run {
                        sessionManager.activeTab = .terminal
                        session.sendCommand(message)
                    }

                    // Refresh so cards reflect review assignment
                    await refreshAnnotationsAfterReview(
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

    /// Refresh annotation state after a review is created.
    /// Re-fetches from CLI so cards reflect review assignment
    /// (review metadata visible, edit/delete buttons hidden).
    /// No-ops if the reader has closed or switched snapshots.
    private func refreshAnnotationsAfterReview(
        snapshotId: Int64
    ) async {
        do {
            let annotations = try await SnapshotQueryService.shared
                .fetchAnnotations(ledgerSnapshotId: snapshotId)

            var htmlMap: [Int32: String] = [:]
            for ann in annotations {
                htmlMap[ann.number] = renderAnnotationHTML(ann.content)
            }

            await MainActor.run {
                // Guard against stale snapshot
                guard openSnapshot?.id == snapshotId else { return }

                openAnnotations = annotations
                annotationHTMLMap = htmlMap
                hasUnreviewedAnnotations = annotations.contains {
                    $0.ledgerSnapshotReviewId == nil
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
            + " `galaxy-ledger snapshot review list --json --pending"
            + " --ledger-session-id \(sid) --snapshot \(sn)`,"
            + " view each with"
            + " `galaxy-ledger snapshot review view --json"
            + " --ledger-session-id \(sid) --snapshot \(sn) REVIEW_NUMBER`,"
            + " mark each reviewed with"
            + " `galaxy-ledger snapshot review mark-reviewed"
            + " --ledger-session-id \(sid) --snapshot \(sn) REVIEW_NUMBER`,"
            + " then respond to each annotation in the conversation."
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
