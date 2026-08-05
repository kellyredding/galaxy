import SwiftUI
import WebKit
import Galactic

/// Container that keeps an ArtifactsView alive per session using
/// a ZStack. Opacity + allowsHitTesting toggle visibility without
/// destroying state.
struct ArtifactsContainerView: View {
    @EnvironmentObject var sessionManager: SessionManager

    var body: some View {
        ZStack {
            ForEach(sessionManager.sessions) { session in
                ArtifactsView(session: session)
                    .opacity(
                        session.id
                            == sessionManager.activeSessionId
                            ? 1 : 0
                    )
                    .allowsHitTesting(
                        session.id
                            == sessionManager.activeSessionId
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Displays a session's artifacts as a sortable index table.
/// Clicking an artifact opens a reader view or falls back to
/// OS open for unsupported types.
struct ArtifactsView: View {
    @ObservedObject var session: Session
    @EnvironmentObject var sessionManager: SessionManager
    @Environment(\.chromeFontSize) private var chromeFontSize
    @Environment(\.colorScheme) private var colorScheme

    private var fontSize: ChromeFontSize {
        ChromeFontSize(chromeFontSize)
    }

    /// Whether this view is the surface in front of the user — both halves,
    /// composed once, the way `ContentView` composes the terminal's.
    ///
    /// Every artifacts container stays mounted and is switched by opacity, so
    /// a reader open here is still in the window after the user moves to
    /// another tab or session. A zero alpha is not hidden, and
    /// `performKeyEquivalent` is offered to the whole hierarchy before the menu
    /// bar — which is how an unseen reader came to answer ⌘=/⌘-/⌘0 and zoom
    /// itself while the Terminal tab's font-size items sat unreached.
    private var isVisibleSurface: Bool {
        session.id == sessionManager.activeSessionId
            && sessionManager.activeTab == .artifacts
    }

    /// Whether the artifact on screen is the one `ArtifactDiffView` renders.
    ///
    /// Asked of the filename, because that is what `artifactContentView`
    /// dispatches on. `artifact.artifactType` is a label the CLI hands back
    /// verbatim from `--artifact-type`, so a "diff"-typed file not named
    /// `.gdiff` renders as source and must not take the sessions panel. The
    /// two inputs here are the two the switch has, so this cannot answer
    /// differently from the view that mounts.
    private var openArtifactIsDiffReader: Bool {
        guard let artifact = openArtifact else { return false }
        return FileKind.resolve(
            filename: artifact.originalFilename
        ) == .unhandled("gdiff")
    }

    // JIT data state
    @State private var artifacts: [ArtifactSummary]? = nil
    @State private var isLoading: Bool = false
    @State private var fetchTask: Task<Void, Never>? = nil

    // Reader state
    @State private var openArtifact: ArtifactSummary? = nil
    @State private var openArtifactContent: String? = nil
    @State private var isLoadingContent: Bool = false
    @State private var isBackHovered: Bool = false
    @State private var escapeMonitor: Any? = nil
    @State private var webViewRef: WKWebView? = nil

    // Cmd+F find state. Controller owns the find bar's
    // visibility, query, and match counters; the slice-4
    // dispatcher will flip `isVisible` via activateFind().
    @StateObject private var findController =
        WebViewFindController(webView: nil, reverse: false)

    // Annotation state
    @State private var openAnnotations:
        [ArtifactAnnotation] = []
    @State private var annotationHTMLMap:
        [Int32: String] = [:]

    // Review state — how many annotations a review would carry, which is
    // what the reader's send bar reports.
    @State private var pendingAnnotationCount: Int = 0

    // Refresh state
    @State private var isRefreshing = false
    @State private var imageRefreshToken: Int = 0

    // Duration tracking for timeline events
    @State private var artifactDurationId: String? = nil

    /// Order and selection. The selection is an identity rather than a row
    /// number, so re-sorting cannot slide the highlight onto another artifact.
    @State private var model = ListSortModel<ArtifactSummary, SortColumn>(
        columns: ArtifactsView.columns,
        sortColumn: .number,
        sortAscending: true)

    enum SortColumn {
        case number, title, type, filename, size, created
    }

    /// What each column is called and how it orders. A number, a size or a
    /// timestamp opens at its largest, which is what a reader picking that
    /// column is after; text opens at A.
    private static let columns: [ListColumn<ArtifactSummary, SortColumn>] = [
        .init(.number, title: "#") {
            ListSorting.compare($0.number, $1.number)
        },
        .init(.title, title: "Title") {
            ListSorting.compareText($0.title, $1.title)
        },
        .init(.type, title: "Type") {
            ListSorting.compareText($0.artifactType, $1.artifactType)
        },
        .init(.filename, title: "Filename") {
            ListSorting.compareText(
                $0.originalFilename, $1.originalFilename)
        },
        .init(.size, title: "Size", prefersAscending: false) {
            ListSorting.compare($0.fileSize, $1.fileSize)
        },
        .init(.created, title: "Created", prefersAscending: false) {
            ListSorting.compare($0.createdAt, $1.createdAt)
        },
    ]

    private var sortedArtifacts: [ArtifactSummary] {
        model.sorted(artifacts)
    }

    var body: some View {
        Group {
            if let artifact = openArtifact {
                artifactReader(artifact)
            } else {
                artifactIndex
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.textBackgroundColor))
        .onChange(of: openArtifact != nil) {
            syncReaderOpenState()
            syncSessionsPanelCondition()
            updateEscapeMonitor()
            syncFindHandler()

            if openArtifact == nil,
               session.id
                   == sessionManager.activeSessionId,
               sessionManager.activeTab == .artifacts,
               artifacts == nil
            {
                fetchArtifactList()
            }
        }
        .onChange(of: sessionManager.activeSessionId) {
            syncReaderOpenState()
            syncSessionsPanelCondition()
            updateEscapeMonitor()
            restoreWebViewFocus()
            syncFindHandler()
            // Re-evaluate find-panel ownership: if we just
            // became the active surface and our controller was
            // visible, re-present; if we're no longer active,
            // yield the panel (`dismiss(if:)` no-ops when the
            // panel is already bound to a different controller,
            // so this can't steal the panel from the incoming
            // active surface).
            syncFindBarPanel()

            if session.id
                != sessionManager.activeSessionId
            {
                artifacts = nil
            }
            // Re-fetch when switching back to this
            // session while already on the artifacts tab
            if session.id
                == sessionManager.activeSessionId,
               sessionManager.activeTab == .artifacts,
               openArtifact == nil
            {
                fetchArtifactList()
            }
        }
        .onChange(of: sessionManager.activeTab) {
            syncReaderOpenState()
            syncSessionsPanelCondition()
            updateEscapeMonitor()
            restoreWebViewFocus()
            syncFindHandler()
            // Re-evaluate find-panel ownership on tab change.
            // See note in the activeSessionId onChange.
            syncFindBarPanel()

            if sessionManager.activeTab == .artifacts,
               session.id
                   == sessionManager.activeSessionId,
               openArtifact == nil
            {
                fetchArtifactList()
            }
            if sessionManager.activeTab != .artifacts,
               session.id
                   == sessionManager.activeSessionId,
               openArtifact == nil
            {
                artifacts = nil
            }
        }
        .onAppear {
            fetchArtifactList()
            syncFindHandler()
        }
        .listNavigation(
            from: sessionManager,
            isActive: {
                session.id
                    == sessionManager.activeSessionId
                    && sessionManager.activeTab
                        == .artifacts
                    && openArtifact == nil
            },
            onAction: { action in
                switch action {
                case .up:
                    model.move(.up, in: sortedArtifacts)
                case .down:
                    model.move(
                        .down, in: sortedArtifacts)
                case .activate:
                    if let artifact = model.focusedElement(
                        in: sortedArtifacts)
                    {
                        openArtifactReader(
                            artifact: artifact)
                    }
                }
            })
        .onChange(
            of: sessionManager.pendingArtifactReviewCheck
        ) {
            guard session.id
                == sessionManager.activeSessionId
            else { return }
            guard let artifactNumber
                = sessionManager
                    .pendingArtifactReviewCheck
            else { return }
            // Consume the signal before deciding whether it
            // applies here. A number belonging to some other
            // artifact left sitting in place would make the
            // next event carrying that same number compare
            // equal, so this handler would never run and a
            // refresh the reader did want would be skipped.
            sessionManager
                .pendingArtifactReviewCheck = nil
            guard let open = openArtifact,
                  artifactNumber == open.number
            else { return }
            checkReviewButtonVisibility(
                artifactNumber: artifactNumber
            )
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication
                    .willTerminateNotification
            )
        ) { _ in
            if openArtifact != nil {
                closeReader(reason: "app-quit")
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .refreshArtifact
            )
        ) { _ in
            if openArtifact != nil {
                requestRefreshCurrentArtifact()
            }
        }
        .onChange(
            of: sessionManager.pendingArtifactShow
        ) {
            guard session.id
                == sessionManager.activeSessionId
            else { return }
            handlePendingArtifactShow()
        }
        // Mirror local reader state up to the session so
        // NavigationCoordinator can observe it for history
        // recording. Paired with the observer below — each
        // guards against looping by checking equality first.
        .onChange(of: openArtifact?.number) { _, newValue in
            if session.openArtifactNumber != newValue {
                session.openArtifactNumber = newValue
            }
        }
        // React to external writes to session.openArtifactNumber
        // (e.g., from NavigationCoordinator.apply during
        // back/forward). Opens or closes the reader to match.
        .onChange(of: session.openArtifactNumber) { _, newValue in
            guard session.id
                == sessionManager.activeSessionId
            else { return }
            // Already in sync — this change came from our own
            // mirror above.
            if openArtifact?.number == newValue { return }
            if let number = newValue {
                openArtifactByNumber(
                    number, reason: "history-nav"
                )
            } else if openArtifact != nil {
                closeReader(reason: "history-nav")
            }
        }
        .onDisappear {
            if openArtifact != nil {
                closeReader(reason: "session-removed")
            }
            fetchTask?.cancel()
            fetchTask = nil
            ArtifactQueryService.shared.cancelAll()
            artifacts = nil
        }
    }

    // MARK: - Index View

    @ViewBuilder
    private var artifactIndex: some View {
        if isLoading && artifacts == nil {
            VStack {
                Spacer()
                ProgressView()
                    .scaleEffect(0.8)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if let artifacts = artifacts,
                  artifacts.isEmpty
        {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "doc.richtext")
                    .chromeFont(size: fontSize.iconLarge)
                    .foregroundColor(.secondary)
                Text("No artifacts")
                    .chromeFont(size: fontSize.title2)
                    .foregroundColor(.primary)
                Text(
                    "Artifacts appear here when Claude "
                    + "produces files"
                )
                .chromeFont(size: fontSize.body)
                .foregroundColor(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if artifacts == nil {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "doc.richtext")
                    .chromeFont(size: fontSize.iconLarge)
                    .foregroundColor(.secondary)
                Text("No artifacts")
                    .chromeFont(size: fontSize.title2)
                    .foregroundColor(.primary)
                Text(
                    "Artifacts appear here when Claude "
                    + "produces files"
                )
                .chromeFont(size: fontSize.body)
                .foregroundColor(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            GeometryReader { geo in
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        LazyVStack(
                            alignment: .leading,
                            spacing: 0
                        ) {
                            headerRow
                            ForEach(
                                Array(
                                    sortedArtifacts
                                        .enumerated()
                                ),
                                id: \.element.id
                            ) { index, artifact in
                                artifactRow(
                                    artifact,
                                    index: index
                                )
                                .id(artifact.id)
                            }
                        }
                        .frame(
                            width: geo.size.width - 40,
                            alignment: .leading
                        )
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                        .padding(.bottom, 20)
                    }
                    .onAppear {
                        if let lastId =
                            sortedArtifacts.last?.id
                        {
                            scrollProxy.scrollTo(
                                lastId,
                                anchor: .bottom
                            )
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
            sortableHeader(.type, width: 80)
            sortableHeader(.filename, width: nil)
            sortableHeader(.size, width: 80)
            sortableHeader(.created, width: 160)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color.primary.opacity(0.05))
    }

    private func sortableHeader(
        _ column: SortColumn,
        width: CGFloat?
    ) -> some View {
        Button(action: { model.select(column) }) {
            HStack(spacing: 3) {
                Text(model.title(for: column))
                    .chromeFont(
                        size: fontSize.caption2,
                        weight: .semibold
                    )
                    .foregroundColor(.secondary)
                if model.sortColumn == column {
                    Image(
                        systemName: model.sortAscending
                            ? "chevron.up"
                            : "chevron.down"
                    )
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(width: width, alignment: .leading)
        .frame(
            maxWidth: width == nil ? .infinity : nil,
            alignment: .leading
        )
    }

    // MARK: - Index Row

    private func artifactRow(
        _ artifact: ArtifactSummary,
        index: Int
    ) -> some View {
        let isFocused = model.focusedId == artifact.id

        return Button(action: {
            openArtifactReader(artifact: artifact)
        }) {
            HStack(spacing: 0) {
                Text(verbatim: "\(artifact.number)")
                    .chromeFontMono(
                        size: fontSize.caption2
                    )
                    .foregroundColor(.secondary)
                    .frame(width: 40, alignment: .leading)

                Text(artifact.title)
                    .chromeFont(
                        size: fontSize.caption2
                    )
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(
                        maxWidth: .infinity,
                        alignment: .leading
                    )

                Text(artifact.artifactType)
                    .chromeFont(
                        size: fontSize.caption2
                    )
                    .foregroundColor(.secondary)
                    .frame(width: 80, alignment: .leading)

                Text(artifact.originalFilename)
                    .chromeFontMono(
                        size: fontSize.caption2
                    )
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundColor(.secondary)
                    .frame(
                        maxWidth: .infinity,
                        alignment: .leading
                    )

                Text(formatFileSize(artifact.fileSize))
                    .chromeFontMono(
                        size: fontSize.caption2
                    )
                    .foregroundColor(.secondary)
                    .frame(width: 80, alignment: .leading)

                Text(ListTimestamp.format(artifact.createdAt))
                    .chromeFontMono(
                        size: fontSize.caption2
                    )
                    .frame(
                        width: 160, alignment: .leading
                    )
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 8)
            .background(
                isFocused
                    ? Color.accentColor.opacity(0.15)
                    : (index % 2 == 1
                        ? Color.primary.opacity(0.03)
                        : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Reader View

    private func artifactReader(
        _ artifact: ArtifactSummary
    ) -> some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                Button(action: {
                    handleBackButton()
                }) {
                    HStack(spacing: 4) {
                        Image(
                            systemName: "chevron.left"
                        )
                        Text("Artifacts")
                    }
                    .chromeFont(
                        size: fontSize.caption2
                    )
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(
                            cornerRadius: 4
                        )
                        .fill(
                            Color.primary.opacity(
                                isBackHovered ? 0.1 : 0
                            )
                        )
                    )
                    .onHover { hovering in
                        isBackHovered = hovering
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(
                    isBackHovered ? .primary : .secondary
                )

                Button(action: {
                    requestRefreshCurrentArtifact()
                }) {
                    Image(
                        systemName: "arrow.clockwise"
                    )
                    .chromeFont(size: fontSize.iconSmall)
                    .foregroundColor(
                        isRefreshing
                            ? .secondary.opacity(0.5)
                            : .secondary
                    )
                    .rotationEffect(
                        .degrees(
                            isRefreshing ? 360 : 0
                        )
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
                .help(
                    "Refresh from source file"
                )
                .disabled(isRefreshing)

                Spacer()

                // Metadata
                Text("#\(artifact.number)")
                    .chromeFontMono(
                        size: fontSize.caption2
                    )
                    .foregroundColor(.secondary)
                Text(artifact.title)
                    .chromeFont(
                        size: fontSize.caption2,
                        weight: .semibold
                    )
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("\u{00B7}")
                    .foregroundColor(.secondary)
                Text(artifact.artifactType)
                    .chromeFont(
                        size: fontSize.caption2
                    )
                    .foregroundColor(.secondary)
                Text("\u{00B7}")
                    .foregroundColor(.secondary)
                Text(
                    formatFileSize(artifact.fileSize)
                )
                .chromeFont(size: fontSize.caption2)
                .foregroundColor(.secondary)
                Text("\u{00B7}")
                    .foregroundColor(.secondary)
                Text(
                    ListTimestamp.format(artifact.createdAt)
                )
                .chromeFont(size: fontSize.caption2)
                .foregroundColor(.secondary)

                Spacer()

                if let content = openArtifactContent {
                    CopyButton(
                        text: content,
                        iconSize: fontSize.iconSmall
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(.windowBackgroundColor))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.primary.opacity(0.1))
                    .frame(height: 1)
            }

            // Content area
            if isLoadingContent {
                VStack {
                    Spacer()
                    ProgressView()
                        .scaleEffect(0.8)
                    Spacer()
                }
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity
                )
            } else if let content = openArtifactContent {
                artifactContentView(
                    artifact: artifact,
                    content: content
                )
            } else if let path = artifact.storedPath
                ?? artifact.sourcePath,
                FileKind.isImage(
                    artifact.originalFilename
                )
            {
                let label
                    = "Artifact #\(artifact.number)"
                let activeAnns
                    = openAnnotations.filter {
                        !$0.stale
                    }
                VStack(spacing: 0) {
                    ArtifactImageView(
                        filePath: path,
                        isDark: colorScheme == .dark,
                        annotations: activeAnns,
                        annotationHTMLMap:
                            annotationHTMLMap,
                        pendingReviewCount:
                            pendingAnnotationCount,
                        itemLabel: label,
                        onAnnotationMessage: {
                            message in
                            handleAnnotationMessage(
                                message,
                                artifact: artifact
                            )
                        },
                        isVisibleSurface: isVisibleSurface,
                        webViewRef: $webViewRef
                    )
                    .id(imageRefreshToken)
                }
            } else {
                VStack {
                    Spacer()
                    Text("Unable to load content")
                        .chromeFont(
                            size: fontSize.body
                        )
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity
                )
            }
        }
        .onChange(of: webViewRef) { _, newView in
            findController.bind(to: newView)
        }
        .onChange(of: openArtifact?.number) { _, _ in
            findController.isVisible = false
        }
        .onChange(of: findController.isVisible) { _, _ in
            syncFindBarPanel()
        }
    }

    /// Show or hide the shared find-bar panel for this reader.
    /// The panel is anchored to the WKWebView's top-right so it
    /// renders in the same place to the user's eye as the prior
    /// inline overlay. See FindBarPanel for why the bar lives
    /// in a separate window instead of inline.
    ///
    /// Self-gating: presents only when this view is the active
    /// surface (active session × artifacts tab) AND the
    /// controller's intent is visible AND the WKWebView anchor
    /// exists. Otherwise yields the panel using `dismiss(if:)`,
    /// which is a no-op when the panel is already bound to a
    /// different controller — so this is safe to call from any
    /// tab/session-change observer without racing whichever
    /// surface just took ownership.
    private func syncFindBarPanel() {
        let amActive =
            sessionManager.activeSessionId == session.id
            && sessionManager.activeTab == .artifacts
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

    /// Bring up the find bar in the open artifact reader.
    /// Called by the slice-4 Cmd+F dispatcher. Image
    /// artifacts have no text content, so this is a silent
    /// no-op on them.
    func activateFind() {
        guard let artifact = openArtifact else { return }
        if FileKind.isImage(artifact.originalFilename) { return }
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

    /// Register this view as `SessionManager.artifactsFindHandler`
    /// when it's the active surface (active session + artifacts
    /// tab). Re-registered from each onChange that affects either
    /// gate, plus onAppear for initial mount. The closure captures
    /// the stable `findController` (`@StateObject`) and the live
    /// `openArtifact` snapshot via `self`-of-this-view-instance —
    /// SwiftUI Views are structs, but @State and @StateObject
    /// internally hold class-backed storage that survives struct
    /// copies, so reads inside the closure see current values.
    /// We do not clear the slot when this view is no longer
    /// active: the next active surface (a different session's
    /// view, or another tab's handler) overwrites it. Stale
    /// closures referencing dead state are harmless because
    /// `activateFind()` switches on `activeTab` before
    /// dispatching.
    private func syncFindHandler() {
        guard sessionManager.activeSessionId == session.id,
              sessionManager.activeTab == .artifacts
        else { return }
        sessionManager.artifactsFindHandler = {
            activateFind()
        }
    }

    // MARK: - Whole Annotations (Mermaid/Image)

    // MARK: - Content Dispatch

    /// Determine the renderer based on extension and render
    /// the content. Markdown gets the full
    /// MarkdownReaderView; source code and plain text get a
    /// syntax-highlighted WKWebView; everything else gets a
    /// simple text display or external open.
    @ViewBuilder
    private func artifactContentView(
        artifact: ArtifactSummary,
        content: String
    ) -> some View {
        let ext = (
            artifact.originalFilename as NSString
        ).pathExtension.lowercased()

        switch FileKind.resolve(
            filename: artifact.originalFilename,
            firstLine: content.split(
                separator: "\n", maxSplits: 1
            ).first.map(String.init)
        ) {
        case .markdown:
            // The reader anchors to line ranges, so anything
            // anchored another way is left out — as it was when
            // these were converted one at a time and a
            // non-line-range conversion returned nothing. Passing
            // them through unconverted is what keeps the captured
            // source text with them.
            let activeAnns = MarkdownRenderer.anchoring
                .screen(openAnnotations)
                .filter {
                    $0.anchorStartLine != nil
                        && $0.anchorEndLine != nil
                }
            MarkdownReaderView(
                markdown: content,
                isDark: colorScheme == .dark,
                annotations: activeAnns,
                annotationHTMLMap: annotationHTMLMap,
                pendingReviewCount: pendingAnnotationCount,
                isVisibleSurface: isVisibleSurface,
                webViewRef: $webViewRef,
                onAnnotationMessage: { message in
                    handleAnnotationMessage(
                        message,
                        artifact: artifact
                    )
                },
                itemLabel:
                    "Artifact #\(artifact.number)",
                baseUrlName: "artifact-reader",
                referencePath: artifact.sourcePath
            )
        case .table:
            let label = "Artifact #\(artifact.number)"
            ArtifactTableView(
                content: content,
                isDark: colorScheme == .dark,
                annotations: openAnnotations,
                annotationHTMLMap: annotationHTMLMap,
                pendingReviewCount: pendingAnnotationCount,
                itemLabel: label,
                isVisibleSurface: isVisibleSurface,
                webViewRef: $webViewRef,
                onAnnotationMessage: { message in
                    handleAnnotationMessage(
                        message,
                        artifact: artifact
                    )
                },
                referencePath: artifact.sourcePath
            )
        case .mermaid:
            let label = "Artifact #\(artifact.number)"
            let activeAnns = openAnnotations.filter {
                !$0.stale
            }
            ArtifactMermaidView(
                content: content,
                isDark: colorScheme == .dark,
                annotations: activeAnns,
                annotationHTMLMap: annotationHTMLMap,
                pendingReviewCount: pendingAnnotationCount,
                itemLabel: label,
                onAnnotationMessage: { message in
                    handleAnnotationMessage(
                        message,
                        artifact: artifact
                    )
                },
                isVisibleSurface: isVisibleSurface,
                webViewRef: $webViewRef
            )
        case .html:
            let label = "Artifact #\(artifact.number)"
            ArtifactHTMLView(
                content: content,
                isDark: colorScheme == .dark,
                annotations: openAnnotations,
                annotationHTMLMap: annotationHTMLMap,
                pendingReviewCount: pendingAnnotationCount,
                itemLabel: label,
                isVisibleSurface: isVisibleSurface,
                webViewRef: $webViewRef,
                onAnnotationMessage: { message in
                    handleAnnotationMessage(
                        message,
                        artifact: artifact
                    )
                }
            )
        case .transcript:
            let label =
                "Artifact #\(artifact.number)"
            ArtifactTranscriptView(
                content: content,
                isDark: colorScheme == .dark,
                annotations: openAnnotations,
                annotationHTMLMap:
                    annotationHTMLMap,
                pendingReviewCount:
                    pendingAnnotationCount,
                itemLabel: label,
                isVisibleSurface: isVisibleSurface,
                webViewRef: $webViewRef,
                onAnnotationMessage: { msg in
                    handleAnnotationMessage(
                        msg,
                        artifact: artifact
                    )
                }
            )
        case .unhandled("gdiff"):
            let label = "Artifact #\(artifact.number)"
            // Pre-render the diff with any viewed files
            // already checked + collapsed. Persistence
            // is keyed by (ledger session, artifact
            // number) — when lsid isn't available yet
            // (rare early-startup race) the `.map`
            // falls through to the empty-set default.
            // Written as an expression rather than an
            // `if let` because ViewBuilder doesn't
            // accept statement-form optional binding.
            let viewed: Set<String> =
                session.ledgerSessionId.map { lsid in
                    ViewedFilesPersistence.shared
                        .viewed(
                            lsid: lsid,
                            artifactNumber:
                                artifact.number
                        )
                } ?? []
            ArtifactDiffView(
                content: content,
                isDark: colorScheme == .dark,
                annotations: openAnnotations,
                annotationHTMLMap: annotationHTMLMap,
                pendingReviewCount: pendingAnnotationCount,
                itemLabel: label,
                viewedFilePaths: viewed,
                isVisibleSurface: isVisibleSurface,
                webViewRef: $webViewRef,
                onAnnotationMessage: { message in
                    handleAnnotationMessage(
                        message,
                        artifact: artifact
                    )
                }
            )
        default:
            // Source code / plain text renderer
            let label = "Artifact #\(artifact.number)"
            ArtifactSourceView(
                content: content,
                language: FileKind.highlightLanguage(
                    forFilename: artifact.originalFilename
                ),
                isDark: colorScheme == .dark,
                annotations: openAnnotations,
                annotationHTMLMap: annotationHTMLMap,
                pendingReviewCount: pendingAnnotationCount,
                itemLabel: label,
                isVisibleSurface: isVisibleSurface,
                webViewRef: $webViewRef,
                onAnnotationMessage: { message in
                    handleAnnotationMessage(
                        message,
                        artifact: artifact
                    )
                },
                referencePath: artifact.sourcePath
            )
        }
    }

    /// Map file extension to highlight.js language name.
    /// Which annotations the reader for this artifact is answerable
    /// for.
    ///
    /// Mirrors the dispatch in `artifactContentView`: that decides which
    /// reader opens, this decides what a rebuild sends it, and the two
    /// disagreeing is how a refresh came to invert a diagram's cards.
    ///
    /// It answers with the reader's *own* declared anchoring rather than a
    /// second description of it, so the two can now only disagree about
    /// which reader opens — never about what that reader will accept once
    /// it has. Screening and the values handed to the page are one thing.
    ///
    /// JSONL is the awkward one — whether it opens as a transcript or
    /// as source depends on the content rather than the extension, so
    /// the content has to be available to answer at all. Without it
    /// the source reading is assumed, matching the dispatch's own
    /// fallback.
    private func annotationScope(
        for artifact: ArtifactSummary,
        content: String?
    ) -> ReaderAnchoring {
        let kind = FileKind.resolve(
            filename: artifact.originalFilename,
            firstLine: content?.split(
                separator: "\n", maxSplits: 1
            ).first.map(String.init)
        )
        if case .unhandled("gdiff") = kind { return diffAnchoring }
        return kind.anchoring
    }

    // MARK: - Data Lifecycle

    private func fetchArtifactList() {
        guard let lsid = session.ledgerSessionId
        else { return }
        isLoading = true
        fetchTask = Task {
            do {
                let result = try await
                    ArtifactQueryService.shared
                    .fetchArtifacts(
                        ledgerSessionId: lsid
                    )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    artifacts = result
                    seedArtifactTitles(result)
                    isLoading = false
                    // Seeded at the last row, which is the end this
                    // list scrolls to when it appears.
                    model.reconcileFocus(
                        in: model.sorted(result),
                        seed: .last)
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    artifacts = []
                    isLoading = false
                }
                NSLog(
                    "ArtifactsView: fetchArtifacts "
                    + "error: %@",
                    error.localizedDescription
                )
            }
        }
    }

    /// Entry point for both refresh affordances — the toolbar
    /// button and the menu command.
    ///
    /// Refreshing rebuilds the annotation cards, which tears down an
    /// open form or an in-progress edit along with them, so anything
    /// typed but not saved is confirmed away rather than disappearing
    /// without warning. Committed annotations are never at risk; they
    /// come back from data.
    private func requestRefreshCurrentArtifact() {
        guard openArtifact != nil, !isRefreshing else { return }
        guard let wv = webViewRef, let window = wv.window
        else {
            // No reader web view to lose work from — whole-file
            // renderers use SwiftUI cards.
            refreshCurrentArtifact()
            return
        }
        wv.evaluateJavaScript(
            "typeof AnnotationManager !== 'undefined' "
            + "? AnnotationManager"
            + ".hasOpenUnsavedComment() : false"
        ) { [self] result, _ in
            guard (result as? Bool) == true else {
                refreshCurrentArtifact()
                return
            }
            SheetAlert.confirm(
                in: window,
                message: "Discard unsaved annotation?",
                detail: "Refreshing rebuilds the annotation "
                    + "cards. Text you have typed but not "
                    + "saved will be lost.",
                confirm: "Refresh",
                onConfirm: { refreshCurrentArtifact() }
            )
        }
    }

    /// In-app refresh: call CLI with --skip-event,
    /// then re-read content + annotations in place.
    /// The reader stays open — no tab switch, no
    /// close/reopen jank. The --skip-event flag
    /// suppresses the socket event since we handle
    /// the UI reload directly here.
    private func refreshCurrentArtifact() {
        guard let artifact = openArtifact,
              let lsid = session.ledgerSessionId,
              !isRefreshing
        else { return }

        isRefreshing = true

        fetchTask?.cancel()
        ArtifactQueryService.shared.cancelAll()
        fetchTask = Task {
            // Step 1: Call refresh with --skip-event
            // to re-sync source → stored
            do {
                _ = try await
                    ArtifactQueryService.shared
                    .refreshArtifact(
                        ledgerSessionId: lsid,
                        artifactNumber:
                            artifact.number,
                        skipEvent: true
                    )
            } catch {
                // Refresh failed — still try to
                // re-read existing stored content
            }

            // Step 2: Re-read content + annotations
            // (same flow as initial open)
            let ext = (
                artifact.originalFilename
                    as NSString
            ).pathExtension.lowercased()

            let imageExtensions: Set<String> = [
                "png", "jpg", "jpeg", "gif",
                "svg", "webp",
            ]

            if imageExtensions.contains(ext) {
                // Images: re-fetch annotations and
                // bump token to force view reload
                let annotations: [ArtifactAnnotation]
                do {
                    annotations = try await
                        ArtifactQueryService.shared
                        .fetchAnnotations(
                            ledgerSessionId: lsid,
                            artifactNumber:
                                artifact.number
                        )
                } catch {
                    annotations = []
                }

                var htmlMap: [Int32: String] = [:]
                for ann in annotations {
                    htmlMap[ann.number]
                        = escapeAnnotationContent(
                            ann.content
                        )
                }

                guard !Task.isCancelled
                else { return }

                await MainActor.run {
                    openAnnotations = annotations
                    annotationHTMLMap = htmlMap
                    recountPending(annotations)
                    imageRefreshToken += 1
                    isRefreshing = false
                }
            } else {
                // Text: re-read content + annotations
                do {
                    let content = try await
                        readArtifactContent(
                            ledgerSessionId: lsid,
                            artifact: artifact
                        )
                    guard !Task.isCancelled
                    else { return }

                    let annotations = try await
                        ArtifactQueryService.shared
                        .fetchAnnotations(
                            ledgerSessionId: lsid,
                            artifactNumber:
                                artifact.number
                        )

                    var htmlMap: [Int32: String] = [:]
                    for ann in annotations {
                        htmlMap[ann.number]
                            = escapeAnnotationContent(
                                ann.content
                            )
                    }

                    guard !Task.isCancelled
                    else { return }

                    await MainActor.run {
                        openArtifactContent = content
                        openAnnotations = annotations
                        annotationHTMLMap = htmlMap
                        recountPending(annotations)
                        // Rebuild the cards as well. The state
                        // above only re-renders the page when
                        // the content itself changed, so an
                        // annotation added or deleted while the
                        // reader stayed open would leave the
                        // cards showing the old set.
                        pushAnnotationData(
                            annotations,
                            scope: annotationScope(
                                for: artifact,
                                content: content
                            )
                        )
                        isRefreshing = false
                    }
                } catch {
                    await MainActor.run {
                        isRefreshing = false
                    }
                }
            }
        }
    }

    /// Handle a pending artifact show from
    /// EventCoordinator (socket event). Delegates to
    /// openArtifactByNumber after clearing the
    /// pending signal.
    private func handlePendingArtifactShow() {
        guard let number =
            sessionManager.pendingArtifactShow
        else { return }
        sessionManager.pendingArtifactShow = nil
        openArtifactByNumber(number, reason: "pending-show")
    }

    /// Fetch the artifact list and open the artifact
    /// with the given number. Shared entry point for
    /// both EventCoordinator-driven shows and history
    /// restoration (back/forward navigation).
    private func openArtifactByNumber(
        _ number: Int32, reason: String
    ) {
        guard let lsid = session.ledgerSessionId
        else { return }

        // Close any currently-open artifact so its
        // duration event fires and state is cleaned up.
        if openArtifact != nil {
            closeReader(reason: reason)
        }

        // Fetch fresh list, then open the artifact
        fetchTask?.cancel()
        ArtifactQueryService.shared.cancelAll()
        isLoading = true
        fetchTask = Task {
            do {
                let list = try await
                    ArtifactQueryService.shared
                    .fetchArtifacts(
                        ledgerSessionId: lsid
                    )
                guard !Task.isCancelled
                else { return }

                guard let artifact = list.first(
                    where: { $0.number == number }
                ) else {
                    await MainActor.run {
                        artifacts = list
                        seedArtifactTitles(list)
                        isLoading = false
                    }
                    return
                }

                await MainActor.run {
                    artifacts = list
                    seedArtifactTitles(list)
                    isLoading = false
                    openArtifactReader(
                        artifact: artifact
                    )
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                }
            }
        }
    }

    /// Seed the session's artifact title cache so
    /// NavigationCoordinator can resolve history
    /// entry titles at push time.
    private func seedArtifactTitles(
        _ list: [ArtifactSummary]
    ) {
        for artifact in list {
            session.recordArtifactInfo(
                number: artifact.number,
                title: artifact.title,
                type: artifact.artifactType
            )
        }
    }

    private func openArtifactReader(
        artifact: ArtifactSummary
    ) {
        guard let lsid = session.ledgerSessionId
        else { return }

        // Whether this opens inline or goes to the OS.
        //
        // The kind table answers both halves — what this file is, and how big
        // is too big for it. `gdiff` resolves as unhandled there because the
        // engine ships no diff reader; this app does, so it is renderable
        // here and carries a cap of its own.
        let kind = FileKind.resolve(
            filename: artifact.originalFilename
        )
        let isGdiff = kind == .unhandled("gdiff")
        let sizeLimit = isGdiff
            ? 5_000_000
            : kind.defaultSizeCap

        if (!isGdiff && kind.isUnhandled)
            || artifact.fileSize > sizeLimit
        {
            openExternally(artifact: artifact)
            return
        }

        // Images use file path directly — no need
        // to read content into a String.
        if kind == .image,
           let path = artifact.sourcePath
        {
            isLoadingContent = true
            fetchTask = Task {
                let annotations: [ArtifactAnnotation]
                do {
                    annotations = try await
                        ArtifactQueryService.shared
                        .fetchAnnotations(
                            ledgerSessionId: lsid,
                            artifactNumber:
                                artifact.number
                        )
                } catch {
                    annotations = []
                }

                var htmlMap: [Int32: String] = [:]
                for ann in annotations {
                    htmlMap[ann.number]
                        = escapeAnnotationContent(
                            ann.content
                        )
                }

                guard !Task.isCancelled
                else { return }

                await MainActor.run {
                    openArtifact = artifact
                    openArtifactContent = nil
                    openAnnotations = annotations
                    annotationHTMLMap = htmlMap
                    isLoadingContent = false
                    recountPending(annotations)

                    let durationId =
                        "artifact--"
                        + "\(UUID().uuidString)"
                    artifactDurationId = durationId
                    TimelineService.record(
                        ledgerSessionId: lsid,
                        eventType:
                            "artifact:opened",
                        source:
                            "galaxy-app/views"
                            + "/artifacts",
                        durationIdentifier:
                            durationId,
                        detailData: [
                            "artifact_number":
                                artifact.number,
                            "title":
                                artifact.title,
                            "artifact_type":
                                artifact
                                .artifactType,
                        ]
                    )
                }
            }
            return
        }

        isLoadingContent = true
        fetchTask?.cancel()
        ArtifactQueryService.shared.cancelAll()
        fetchTask = Task {
            do {
                let content = try await
                    readArtifactContent(
                        ledgerSessionId: lsid,
                        artifact: artifact
                    )
                guard !Task.isCancelled else { return }
                // Fetch annotations
                let annotations = try await
                    ArtifactQueryService.shared
                    .fetchAnnotations(
                        ledgerSessionId: lsid,
                        artifactNumber:
                            artifact.number
                    )

                var htmlMap: [Int32: String] = [:]
                for ann in annotations {
                    htmlMap[ann.number]
                        = escapeAnnotationContent(
                            ann.content
                        )
                }

                guard !Task.isCancelled else { return }

                await MainActor.run {
                    openArtifact = artifact
                    openArtifactContent = content
                    openAnnotations = annotations
                    annotationHTMLMap = htmlMap
                    isLoadingContent = false
                    recountPending(annotations)

                    // Fire artifact:opened
                    // duration event
                    let durationId =
                        "artifact--\(UUID().uuidString)"
                    artifactDurationId = durationId
                    TimelineService.record(
                        ledgerSessionId: lsid,
                        eventType: "artifact:opened",
                        source:
                            "galaxy-app/views/artifacts",
                        durationIdentifier: durationId,
                        detailData: [
                            "artifact_number":
                                artifact.number,
                            "title": artifact.title,
                            "artifact_type":
                                artifact.artifactType,
                        ]
                    )
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    isLoadingContent = false
                }
                NSLog(
                    "ArtifactsView: openReader "
                    + "error: %@",
                    error.localizedDescription
                )
            }
        }
    }

    /// Read artifact content via the CLI's view command (raw file
    /// content), routed through the shared query service so the
    /// view never spawns a subprocess itself.
    private func readArtifactContent(
        ledgerSessionId: Int64,
        artifact: ArtifactSummary
    ) async throws -> String {
        try await ArtifactQueryService.shared.fetchContent(
            ledgerSessionId: ledgerSessionId,
            number: artifact.number
        )
    }

    /// Hand an artifact to whichever application owns its type.
    ///
    /// Two paths are tried, in order. The source is preferred because it is
    /// the file the user still works in, and opening the stored copy would
    /// invite edits that go nowhere. The stored copy is the fallback because
    /// it is the one Galaxy can be sure of: an artifact saved from a pipe has
    /// no source at all, and a source recorded relative to some long-gone
    /// working directory resolves to nothing.
    ///
    /// Both of those used to end the same way. Only the source was tried, the
    /// result of trying was discarded, and a failure was indistinguishable
    /// from a click that never landed — no window, no error, nothing in the
    /// log. The comment here promised the fallback that the code did not
    /// have.
    private func openExternally(
        artifact: ArtifactSummary
    ) {
        let candidates = [
            artifact.sourcePath, artifact.storedPath,
        ].compactMap { $0 }

        var opened = false
        for path in candidates {
            if NSWorkspace.shared.open(
                URL(fileURLWithPath: path)
            ) {
                opened = true
                break
            }
        }

        if !opened {
            GalaxyLog.dbg(
                "artifacts",
                "external open failed for #\(artifact.number) "
                    + "(\(artifact.originalFilename)); tried "
                    + "\(candidates.count) path(s)"
            )
        }

        // Fire a point event for external opens
        if let lsid = session.ledgerSessionId {
            TimelineService.record(
                ledgerSessionId: lsid,
                eventType: "artifact:opened",
                source:
                    "galaxy-app/views/artifacts",
                detailData: [
                    "artifact_number":
                        artifact.number,
                    "title": artifact.title,
                    "artifact_type":
                        artifact.artifactType,
                    "trigger": "external",
                ]
            )
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

    private func closeReader(
        reason: String = "dismissed"
    ) {
        if let lsid = session.ledgerSessionId,
           let durationId = artifactDurationId
        {
            var detailData: [String: Any] = [
                "reason": reason
            ]
            if let artifact = openArtifact {
                detailData["artifact_number"] =
                    artifact.number
                detailData["title"] = artifact.title
                detailData["artifact_type"] =
                    artifact.artifactType
            }
            TimelineService.record(
                ledgerSessionId: lsid,
                eventType: "artifact:closed",
                source:
                    "galaxy-app/views/artifacts",
                durationIdentifier: durationId,
                detailData: detailData
            )
            artifactDurationId = nil
        }

        removeEscapeMonitor()
        sessionManager.isArtifactReaderOpen = false
        webViewRef = nil
        openArtifact = nil
        openArtifactContent = nil
        openAnnotations = []
        annotationHTMLMap = [:]
        // Set directly rather than through setPendingCount: the web view is
        // already gone, so there is nothing left to tell.
        pendingAnnotationCount = 0

        // Nothing to refocus: the selection is the row's identity, so it
        // survived the round trip through the reader on its own.
    }

    // MARK: - Annotation Bridge

    // MARK: - Annotation Messages

    private func handleAnnotationMessage(
        _ message: AnnotationMessage,
        artifact: ArtifactSummary
    ) {
        guard let lsid = session.ledgerSessionId
        else { return }

        switch message {
        case .createDiffRange(
            let startLine, let endLine, let rows,
            let filePath, let fileStartLine,
            let fileEndLine, let fileLineSide,
            let content
        ):
            // Build a structured `diff_range` anchor so
            // reviewing agents see which file + which
            // old/new line + which kind (add / delete /
            // context) the user selected, along with
            // the row's code content. Also synthesize
            // a marker-prefixed `line_content` string
            // so existing annotation-display code that
            // reads `line_content` still shows
            // something meaningful.
            //
            // `file_path` + `file_start_line` /
            // `file_end_line` / `file_line_side` are
            // lifted out of `rows[]` so the reader's
            // display label can show
            // `path/to/file.rb:N` instead of the
            // meaningless global data-line counter.
            // JS computes them at capture time.
            // Two forms of the same selection. The marked
            // one tells a reviewing agent which rows were
            // added, removed, or merely context. The plain
            // one is what belongs on a clipboard or inside
            // a suggestion block: source that could be
            // pasted back into the file. Recording both
            // beats deriving one later, since removing a
            // prefix would eat the first characters of any
            // line whose own code begins that way.
            var markedParts: [String] = []
            var sourceParts: [String] = []
            for row in rows {
                let kind = row["kind"] as? String ?? ""
                let text = row["content"]
                    as? String ?? ""
                let prefix: String
                switch kind {
                case "add": prefix = "+ "
                case "delete": prefix = "- "
                case "context": prefix = "  "
                default: continue
                }
                markedParts.append(prefix + text)
                sourceParts.append(text)
            }
            let lineContent =
                markedParts.joined(separator: "\n")
            let sourceContent =
                sourceParts.joined(separator: "\n")
            var anchorData: [String: Any] = [
                "type": "diff_range",
                "start_line": startLine,
                "end_line": endLine,
                "line_content": lineContent,
                "source_content": sourceContent,
                "rows": rows,
            ]
            if let fp = filePath {
                anchorData["file_path"] = fp
            }
            if let fs = fileStartLine {
                anchorData["file_start_line"] = fs
            }
            if let fe = fileEndLine {
                anchorData["file_end_line"] = fe
            }
            if let fls = fileLineSide {
                anchorData["file_line_side"] = fls
            }
            createAnnotation(
                lsid: lsid,
                artifact: artifact,
                anchorData: anchorData,
                content: content
            )

        case .create(
            let startLine, let endLine,
            let content
        ):
            // The line-range captured by the JS comes
            // from the rendered DOM's `data-line`
            // counter. For source / markdown artifacts
            // that counter tracks real lines in
            // `openArtifactContent`, so we can slice it
            // to recover `line_content`. For .gdiff
            // artifacts the counter is a rendered-row
            // index (file headers, hunk separators,
            // +/-/context rows all consume slots) and
            // does NOT map to newlines in the raw JSON
            // blob — slicing can easily produce
            // start > end and crash Swift's array
            // subscript. Guard conservatively so both
            // cases stop at empty content rather than
            // abort.
            let lines = (openArtifactContent ?? "")
                .components(separatedBy: "\n")
            let start = max(Int(startLine) - 1, 0)
            let end = min(
                Int(endLine), lines.count
            )
            let lineContent: String
            if start < end {
                lineContent = lines[start..<end]
                    .joined(separator: "\n")
            } else {
                lineContent = ""
            }
            let anchorData: [String: Any] = [
                "type": "line_range",
                "start_line": startLine,
                "end_line": endLine,
                "line_content": lineContent,
            ]
            createAnnotation(
                lsid: lsid,
                artifact: artifact,
                anchorData: anchorData,
                content: content
            )

        case .createRowRange(
            let startRow, let endRow,
            let content
        ):
            let csvLines = (openArtifactContent ?? "")
                .components(separatedBy: "\n")
            // Row 1 = first data row (after header)
            let start = Int(startRow)
            let end = min(
                Int(endRow), csvLines.count - 1
            )
            let rowContent: String
            if start >= 1 && end < csvLines.count {
                rowContent = csvLines[start...end]
                    .joined(separator: "\n")
            } else {
                rowContent = ""
            }
            let anchorData: [String: Any] = [
                "type": "row_range",
                "start_row": startRow,
                "end_row": endRow,
                "row_content": rowContent,
            ]
            createAnnotation(
                lsid: lsid,
                artifact: artifact,
                anchorData: anchorData,
                content: content
            )

        case .createBlockRange(
            let startBlock, let endBlock,
            let blockContent, let content
        ):
            var anchorData: [String: Any] = [
                "type": "block_range",
                "start_block": startBlock,
                "end_block": endBlock,
            ]
            if let bc = blockContent, !bc.isEmpty {
                anchorData["block_content"] = bc
            }
            createAnnotation(
                lsid: lsid,
                artifact: artifact,
                anchorData: anchorData,
                content: content
            )

        case .createWhole(let content):
            var anchorData: [String: Any] = [
                "type": "whole",
            ]
            if let path = artifact.sourcePath {
                anchorData["artifact_path"] = path
            }
            createAnnotation(
                lsid: lsid,
                artifact: artifact,
                anchorData: anchorData,
                content: content
            )

        case .update(let number, let content):
            updateAnnotation(
                lsid: lsid,
                artifact: artifact,
                number: number,
                content: content
            )

        case .delete(let number):
            Task {
                do {
                    try await
                        ArtifactQueryService.shared
                        .deleteAnnotation(
                            ledgerSessionId: lsid,
                            artifactNumber:
                                artifact.number,
                            number: number
                        )
                    await MainActor.run {
                        openAnnotations.removeAll {
                            $0.number == number
                        }
                        annotationHTMLMap.removeValue(
                            forKey: number
                        )
                        webViewRef?.evaluateJavaScript(
                            "AnnotationManager"
                            + ".annotationDeleted"
                            + "(\(number))"
                        )
                        recountPending(openAnnotations)
                    }
                } catch {
                    NSLog(
                        "ArtifactsView: delete "
                        + "annotation error: %@",
                        error.localizedDescription
                    )
                }
            }

        case .confirmDragReplace(
            let startIdx, let endIdx
        ):
            showDragReplaceAnnotationAlert(
                startIdx: startIdx,
                endIdx: endIdx
            )

        case .setViewed(
            let filePath, let isViewed
        ):
            // Viewed state is app-local UI progress,
            // not annotation data — route straight to
            // the persistence singleton. The JS
            // already updated the DOM (check state +
            // collapse class) optimistically; Swift's
            // job is just to persist for the next
            // open.
            ViewedFilesPersistence.shared.setViewed(
                lsid: lsid,
                artifactNumber: artifact.number,
                filePath: filePath,
                isViewed: isViewed
            )

        case .reviewWithClaude(let comment):
            submitReview(
                artifact: artifact, comment: comment)
        }
    }

    /// Build a JS-injectable annotation payload for
    /// any anchor type (line_range, row_range,
    /// block_range).
    private func buildGenericAnnotationPayload(
        ann: ArtifactAnnotation,
        renderedHTML: String
    ) -> String {
        var annDict: [String: Any] = [
            "id": ann.id,
            "number": ann.number,
            "content": ann.content,
            "created_at": ann.createdAt,
            "updated_at": ann.updatedAt,
        ]
        // Set position keys based on anchor type.
        // `.diffRange` uses the same data-line keyed
        // lookup as `.lineRange` in the JS layer, so it
        // emits identical position keys — plus the
        // per-file reference fields so the fresh card
        // immediately renders with its file-aware
        // label (and gets stamped with data-file-path
        // for the collapse handler). Must stay in
        // lockstep with `buildAnnotationInitJS`'s
        // .diffRange branch — both paths feed the same
        // JS renderer.
        switch ann.anchorData.type {
        case .lineRange:
            if let sl = ann.anchorData.startLine {
                annDict["start_line"] = sl
            }
            if let el = ann.anchorData.endLine {
                annDict["end_line"] = el
            }
        case .diffRange:
            if let sl = ann.anchorData.startLine {
                annDict["start_line"] = sl
            }
            if let el = ann.anchorData.endLine {
                annDict["end_line"] = el
            }
            if let fp = ann.anchorData.filePath {
                annDict["file_path"] = fp
            }
            if let fs = ann.anchorData.fileStartLine {
                annDict["file_start_line"] = fs
            }
            if let fe = ann.anchorData.fileEndLine {
                annDict["file_end_line"] = fe
            }
            if let fls = ann.anchorData.fileLineSide {
                annDict["file_line_side"] = fls
            }
        case .rowRange:
            if let sr = ann.anchorData.startRow {
                annDict["start_row"] = sr
            }
            if let er = ann.anchorData.endRow {
                annDict["end_row"] = er
            }
        case .blockRange:
            if let sb = ann.anchorData.startBlock {
                annDict["start_block"] = sb
            }
            if let eb = ann.anchorData.endBlock {
                annDict["end_block"] = eb
            }
        case .whole:
            break
        }
        if let rn = ann.reviewNumber {
            annDict["review_number"] = rn
        }
        if let rra = ann.reviewReviewedAt {
            annDict["review_reviewed_at"] = rra
        }
        let dict: [String: Any] = [
            "annotation": annDict,
            "renderedHTML": renderedHTML,
        ]
        guard let data = try? JSONSerialization
            .data(withJSONObject: dict),
              let json = String(
                  data: data, encoding: .utf8
              )
        else { return "{}" }
        return json
    }

    // MARK: - Annotation CRUD Helpers

    /// Create an annotation via CLI and update JS.
    private func createAnnotation(
        lsid: Int64,
        artifact: ArtifactSummary,
        anchorData: [String: Any],
        content: String
    ) {
        Task {
            do {
                let ann = try await
                    ArtifactQueryService.shared
                    .createAnnotation(
                        ledgerSessionId: lsid,
                        artifactNumber:
                            artifact.number,
                        anchorData: anchorData,
                        content: content
                    )
                let html = escapeAnnotationContent(
                    ann.content
                )
                await MainActor.run {
                    openAnnotations.append(ann)
                    annotationHTMLMap[
                        ann.number
                    ] = html
                    recountPending(openAnnotations)
                }
                let payload
                    = buildGenericAnnotationPayload(
                        ann: ann,
                        renderedHTML: html
                    )
                await MainActor.run {
                    webViewRef?.evaluateJavaScript(
                        "AnnotationManager"
                        + ".annotationCreated"
                        + "(\(payload))"
                    )
                }
            } catch {
                NSLog(
                    "ArtifactsView: create "
                    + "annotation error: %@",
                    error.localizedDescription
                )
            }
        }
    }

    /// Update an annotation via CLI and update JS.
    private func updateAnnotation(
        lsid: Int64,
        artifact: ArtifactSummary,
        number: Int32,
        content: String
    ) {
        Task {
            do {
                let ann = try await
                    ArtifactQueryService.shared
                    .updateAnnotation(
                        ledgerSessionId: lsid,
                        artifactNumber:
                            artifact.number,
                        number: number,
                        content: content
                    )
                let html = escapeAnnotationContent(
                    ann.content
                )
                await MainActor.run {
                    if let idx = openAnnotations
                        .firstIndex(where: {
                            $0.number == number
                        })
                    {
                        openAnnotations[idx] = ann
                    }
                    annotationHTMLMap[
                        ann.number
                    ] = html
                }
                let payload
                    = buildGenericAnnotationPayload(
                        ann: ann,
                        renderedHTML: html
                    )
                await MainActor.run {
                    webViewRef?.evaluateJavaScript(
                        "AnnotationManager"
                        + ".annotationUpdated"
                        + "(\(payload))"
                    )
                }
            } catch {
                NSLog(
                    "ArtifactsView: update "
                    + "annotation error: %@",
                    error.localizedDescription
                )
            }
        }
    }

    // MARK: - Alert Helpers

    private func showDragReplaceAnnotationAlert(
        startIdx: Int,
        endIdx: Int
    ) {
        guard let window = webViewRef?.window
        else { return }

        SheetAlert.confirm(
            in: window,
            message: "Discard annotation?",
            detail: "You have unsaved text in the "
                + "annotation form. It will be lost "
                + "if you select a different range.",
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

    // MARK: - Pending Count

    /// Recount what a review would carry, from the annotations in hand.
    ///
    /// Pending and not stale — the same predicate the CLI's `save_review`
    /// counts and claims on, whose own comment explains why the two have to
    /// agree: a review that reported one number and carried another would be
    /// worse than a wrong badge. This predicate was written out six times in
    /// this file before the count needed a single answer.
    private func recountPending(
        _ annotations: [ArtifactAnnotation]
    ) {
        setPendingCount(
            annotations.filter {
                $0.artifactReviewId == nil && !$0.stale
            }.count
        )
    }

    /// Store the count and tell the open reader.
    ///
    /// The page is told separately from being given the annotations, because
    /// the two travel on different schedules: annotations are pushed when the
    /// document's cards change, the count also moves when a review claims
    /// annotations the page is still displaying.
    private func setPendingCount(_ count: Int) {
        pendingAnnotationCount = count
        webViewRef?.evaluateJavaScript(
            "window.GalaxySendBar.update(\(count))"
        )
    }

    // MARK: - Review Actions

    /// Re-count the open artifact's unreviewed annotations. Driven by
    /// annotation and review events, so the send bar stays truthful when
    /// annotations are created or deleted outside the reader — by an
    /// agent working through the CLI, most often. Only the count is
    /// refreshed: reloading the cards would rebuild the annotation DOM
    /// underneath whatever form or edit the user has open.
    ///
    /// This is why the count is stored rather than derived from
    /// `openAnnotations`. That array is the reader's view of the
    /// annotations and goes stale precisely in this case, so the
    /// database is asked instead.
    private func checkReviewButtonVisibility(
        artifactNumber: Int32
    ) {
        guard let lsid = session.ledgerSessionId else { return }
        Task {
            do {
                let pending = try await ArtifactQueryService
                    .shared
                    .checkPendingCount(
                        ledgerSessionId: lsid,
                        artifactNumber: artifactNumber
                    )
                await MainActor.run {
                    setPendingCount(pending)
                }
            } catch {
                NSLog(
                    "ArtifactsView: checkReviewButton "
                    + "error: %@",
                    error.localizedDescription
                )
            }
        }
    }

    private func submitReview(
        artifact: ArtifactSummary,
        comment: String
    ) {
        // Optimistic, to stop a second press landing while the first is still
        // in flight. Every failure path below puts the real count back.
        setPendingCount(0)
        guard let lsid = session.ledgerSessionId
        else { return }
        closeReader(reason: "reviewed")

        Task {
            let needsResume = await MainActor.run {
                session.hasExited
            }

            if needsResume {
                let dirExists = await MainActor.run {
                    FileManager.default.fileExists(
                        atPath:
                            session.workingDirectory
                    )
                }
                guard dirExists else {
                    NSLog(
                        "ArtifactsView: submitReview "
                        + "aborted — working directory "
                        + "gone"
                    )
                    await MainActor.run {
                        recountPending(openAnnotations)
                    }
                    return
                }

                let message = buildReviewMessage(
                    ledgerSessionId: lsid,
                    artifactNumber: artifact.number,
                    comment: comment
                )

                await MainActor.run {
                    session.onceAfterTurnEnd {
                        [weak session] in
                        DispatchQueue.main.asyncAfter(
                            deadline: .now() + 3.0
                        ) {
                            Task { [weak session] in
                                guard let session
                                    = session
                                else { return }
                                do {
                                    let _ = try await
                                        ArtifactQueryService
                                        .shared
                                        .createReview(
                                            ledgerSessionId:
                                                lsid,
                                            artifactNumber:
                                                artifact
                                                .number
                                        )
                                    await MainActor.run {
                                        self
                                            .recordArtifactReviewedEvent(
                                                ledgerSessionId:
                                                    lsid,
                                                artifact:
                                                    artifact
                                            )
                                    }
                                    await MainActor.run {
                                        session
                                            .sendCommand(
                                                message
                                            )
                                    }
                                    await self
                                        .refreshAnnotationsAfterReview(
                                            artifact:
                                                artifact
                                        )
                                } catch {
                                    await MainActor.run {
                                        self.recountPending(
                                            self.openAnnotations
                                        )
                                    }
                                    NSLog(
                                        "ArtifactsView:"
                                        + " submitReview"
                                        + " error: %@",
                                        error
                                            .localizedDescription
                                    )
                                }
                            }
                        }
                    }

                    sessionManager.resumeSession(
                        sessionId: session.id
                    )
                }
            } else {
                do {
                    let _ = try await
                        ArtifactQueryService.shared
                        .createReview(
                            ledgerSessionId: lsid,
                            artifactNumber:
                                artifact.number
                        )

                    await MainActor.run {
                        recordArtifactReviewedEvent(
                            ledgerSessionId: lsid,
                            artifact: artifact
                        )
                    }

                    let message = buildReviewMessage(
                        ledgerSessionId: lsid,
                        artifactNumber: artifact.number,
                        comment: comment
                    )

                    await MainActor.run {
                        sessionManager.activeTab
                            = .terminal
                        session.sendCommand(message)
                    }

                    await refreshAnnotationsAfterReview(
                        artifact: artifact
                    )
                } catch {
                    await MainActor.run {
                        recountPending(openAnnotations)
                    }
                    NSLog(
                        "ArtifactsView: submitReview "
                        + "error: %@",
                        error.localizedDescription
                    )
                }
            }
        }
    }

    /// Rebuild the reader's annotation cards from the given set.
    ///
    /// The scope decides which of them belong to the reader being
    /// rebuilt, so that a rebuild sends the same set the initial load
    /// did. Stale ones are always left out; they belong to the drawer
    /// rather than the page. Callers must already be on the main
    /// actor.
    ///
    /// An empty set is sent rather than withheld: that is how a reader
    /// is told its last card is gone. Nothing renders cards this does
    /// not send any more, so there is no longer a case where empty
    /// means "no news" instead of "nothing left".
    @MainActor
    private func pushAnnotationData(
        _ annotations: [ArtifactAnnotation],
        scope: ReaderAnchoring
    ) {
        let activeAnns = scope.screen(annotations)
        let annDicts: [[String: Any]] = activeAnns.map(
            readerAnnotationDict
        )
        // Ship the card bodies alongside the records. A refresh can
        // introduce annotations the page has never rendered, and
        // those have no entry in its map yet.
        var htmlMap: [String: String] = [:]
        for a in activeAnns {
            htmlMap[String(a.number)]
                = escapeAnnotationContent(a.content)
        }
        if let data = try? JSONSerialization
            .data(withJSONObject: annDicts),
           let json = String(
               data: data, encoding: .utf8
           ),
           let mapData = try? JSONSerialization
            .data(withJSONObject: htmlMap),
           let mapJson = String(
               data: mapData, encoding: .utf8
           )
        {
            webViewRef?.evaluateJavaScript(
                "AnnotationManager"
                + ".refreshAnnotationData"
                + "(\(json), \(mapJson))"
            )
        }
    }

    private func refreshAnnotationsAfterReview(
        artifact: ArtifactSummary
    ) async {
        guard let lsid = session.ledgerSessionId
        else { return }
        do {
            let annotations = try await
                ArtifactQueryService.shared
                .fetchAnnotations(
                    ledgerSessionId: lsid,
                    artifactNumber: artifact.number
                )

            var htmlMap: [Int32: String] = [:]
            for ann in annotations {
                htmlMap[ann.number]
                    = escapeAnnotationContent(ann.content)
            }

            await MainActor.run {
                guard openArtifact?.number
                    == artifact.number
                else { return }

                openAnnotations = annotations
                annotationHTMLMap = htmlMap
                recountPending(annotations)

                pushAnnotationData(
                    annotations,
                    scope: annotationScope(
                        for: artifact,
                        content: openArtifactContent
                    )
                )
            }
        } catch {
            NSLog(
                "ArtifactsView: refresh annotations "
                + "error: %@",
                error.localizedDescription
            )
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
        artifactNumber: Int32,
        comment: String
    ) -> String {
        let lead = comment.isEmpty ? "" : comment + "\n\n"
        let sid = ledgerSessionId
        let an = artifactNumber
        return lead
            + "I've submitted artifact annotations "
            + "for your review."
            + " List pending reviews with"
            + " `galaxy-artifacts review list --json"
            + " --pending --ledger-session-id \(sid)"
            + " --artifact \(an)`,"
            + " view each with"
            + " `galaxy-artifacts review view --json"
            + " --ledger-session-id \(sid)"
            + " --artifact \(an) REVIEW_NUMBER`,"
            + " mark each reviewed with"
            + " `galaxy-artifacts review mark-reviewed"
            + " --ledger-session-id \(sid)"
            + " --artifact \(an) REVIEW_NUMBER`,"
            + " then respond to each annotation in "
            + "the conversation."
    }

    private func recordArtifactReviewedEvent(
        ledgerSessionId: Int64,
        artifact: ArtifactSummary
    ) {
        let activeAnns = openAnnotations.filter {
            !$0.stale
        }
        let expandedAnnotations: [[String: Any]]
            = activeAnns.map { ann in
                var entry: [String: Any] = [
                    "number": ann.number,
                    "annotation": ann.content,
                    "anchor_type":
                        ann.anchorData.type.rawValue,
                ]
                if let lc = ann.anchorData.lineContent {
                    entry["line_content"] = lc
                }
                if let rc = ann.anchorData.rowContent {
                    entry["row_content"] = rc
                }
                if let bc = ann.anchorData.blockContent {
                    entry["block_content"] = bc
                }
                if let ap = ann.anchorData.artifactPath {
                    entry["artifact_path"] = ap
                }
                if let sl = ann.anchorData.startLine {
                    entry["start_line"] = sl
                }
                if let el = ann.anchorData.endLine {
                    entry["end_line"] = el
                }
                return entry
            }

        let detailData: [String: Any] = [
            "artifact_number": artifact.number,
            "title": artifact.title,
            "artifact_type": artifact.artifactType,
            "annotation_count": activeAnns.count,
            "annotations": expandedAnnotations,
        ]

        TimelineService.recordViaStdin(
            ledgerSessionId: ledgerSessionId,
            eventType: "artifact:reviewed",
            source: "galaxy-app/views/artifacts",
            detailData: detailData
        )
    }

    // MARK: - Active View State Sync

    private func syncReaderOpenState() {
        guard session.id
            == sessionManager.activeSessionId
        else { return }
        if sessionManager.activeTab == .artifacts {
            sessionManager.isArtifactReaderOpen =
                openArtifact != nil
        } else {
            sessionManager.isArtifactReaderOpen = false
        }
    }

    /// Hold the sessions panel collapsed while the diff reader is the
    /// surface on screen.
    ///
    /// The active-session guard is load-bearing here in a way it is not in
    /// `syncReaderOpenState`. `isVisibleSurface` already includes that
    /// check, so the guard changes nothing about computing a *true*
    /// answer — it exists to stop every *other* session's mounted
    /// artifacts view from writing its own `false` over the condition the
    /// visible one is holding. Exactly one view passes it, and that view's
    /// state is the whole answer.
    private func syncSessionsPanelCondition() {
        guard session.id
            == sessionManager.activeSessionId
        else { return }
        SidebarPreferences.shared.setCondition(
            isVisibleSurface && openArtifactIsDiffReader,
            .diffReader
        )
    }

    private func updateEscapeMonitor() {
        let shouldBeInstalled = openArtifact != nil
            && session.id
                == sessionManager.activeSessionId
            && sessionManager.activeTab == .artifacts
        if shouldBeInstalled {
            installEscapeMonitor()
        } else {
            removeEscapeMonitor()
        }
    }

    private func restoreWebViewFocus() {
        guard session.id
            == sessionManager.activeSessionId,
              sessionManager.activeTab == .artifacts,
              openArtifact != nil,
              let webView = webViewRef
        else { return }
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.05
        ) {
            webView.window?.makeFirstResponder(webView)
        }
    }

    // MARK: - Escape Key (AppKit monitor)

    /// A binding added here also needs a row in `KeystrokeCatalog`, with an
    /// availability case naming its gate — nothing fails to say so, because
    /// the catalog restates these facts rather than deriving them.
    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor =
            NSEvent.addLocalMonitorForEvents(
                matching: .keyDown
            ) { [self] event in
                // Stand down while the cheat sheet claims the keyboard.
                // Same two-stage path as Snapshots, and this monitor
                // deliberately does not bail for a focused text view
                // because the annotation textarea *is* one — so nothing
                // else here would stop it.
                if KeystrokeSheetModel.isClaimingKeyboard { return event }

                if event.keyCode == 53 {
                    guard session.id
                        == sessionManager
                            .activeSessionId,
                          sessionManager.activeTab
                            == .artifacts
                    else {
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

                    // Which layer is outermost. Asking changes
                    // nothing, so every case below has to name
                    // the action it wants — including the two
                    // that the question used to perform on its
                    // own, and which Back had no way to decline.
                    webViewRef?.evaluateJavaScript(
                        "typeof AnnotationManager "
                        + "!== 'undefined' ? "
                        + "AnnotationManager"
                        + ".escapeContext() "
                        + ": 'close'"
                    ) { result, _ in
                        guard let context
                            = result as? String
                        else {
                            DispatchQueue.main.async {
                                closeReader()
                            }
                            return
                        }
                        switch context {
                        case "emojiPopup":
                            self.runInReader(
                                "dismissEmojiPopup()")
                        case "overallComment":
                            self.runInReader(
                                "collapseOverallComment()")
                        case "editingDirty":
                            self
                                .showDiscardEditAlert()
                        case "editingClean":
                            self.runInReader("cancelEdit()")
                        case "expanded":
                            self.runInReader(
                                "collapseExpanded()")
                        case "formHasText":
                            self
                                .showDiscardFormAlert()
                        case "formVisible":
                            self.runInReader("dismissForm()")
                        default:
                            DispatchQueue.main.async {
                                closeReader()
                            }
                        }
                    }
                    return nil
                }
                return event
            }
    }

    private func showDiscardFormAlert() {
        guard let window = webViewRef?.window
        else { return }

        SheetAlert.confirm(
            in: window,
            message: "Discard annotation?",
            detail: "You have unsaved text in the "
                + "annotation form. It will be lost "
                + "if you dismiss.",
            onConfirm: { [self] in
                self.webViewRef?.evaluateJavaScript(
                    "AnnotationManager.dismissForm()"
                )
            }
        )
    }

    private func showDiscardEditAlert() {
        guard let window = webViewRef?.window
        else { return }

        SheetAlert.confirm(
            in: window,
            message: "Discard changes?",
            detail: "You have unsaved changes to "
                + "this annotation. They will be "
                + "lost if you cancel editing.",
            onConfirm: { [self] in
                self.webViewRef?.evaluateJavaScript(
                    "AnnotationManager.cancelEdit()"
                )
            }
        )
    }

    private func removeEscapeMonitor() {
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }
    }

    // MARK: - Formatting

    private func formatFileSize(
        _ bytes: Int64
    ) -> String {
        if bytes >= 1_048_576 {
            return String(
                format: "%.1fM",
                Double(bytes) / 1_048_576.0
            )
        } else if bytes >= 1024 {
            return String(
                format: "%.1fK",
                Double(bytes) / 1024.0
            )
        }
        return "\(bytes)B"
    }
}
