import SwiftUI
import WebKit

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

    // Annotation state
    @State private var openAnnotations:
        [ArtifactAnnotation] = []
    @State private var annotationHTMLMap:
        [Int32: String] = [:]

    // Review state
    @State private var hasUnreviewedAnnotations:
        Bool = false

    // Duration tracking for timeline events
    @State private var artifactDurationId: String? = nil

    // Focus state for keyboard navigation
    @State private var focusedIndex: Int? = nil

    // Sort state
    @State private var sortColumn: SortColumn = .number
    @State private var sortAscending: Bool = true

    enum SortColumn {
        case number, title, type, filename, size, created
    }

    private var sortedArtifacts: [ArtifactSummary] {
        guard let artifacts = artifacts else { return [] }
        return artifacts.sorted { a, b in
            let result: Bool
            switch sortColumn {
            case .number:
                result = a.number < b.number
            case .title:
                result = a.title
                    .localizedCaseInsensitiveCompare(
                        b.title
                    ) == .orderedAscending
            case .type:
                result = a.artifactType < b.artifactType
            case .filename:
                result = a.originalFilename
                    .localizedCaseInsensitiveCompare(
                        b.originalFilename
                    ) == .orderedAscending
            case .size:
                result = a.fileSize < b.fileSize
            case .created:
                result = a.createdAt < b.createdAt
            }
            return sortAscending ? result : !result
        }
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
            updateEscapeMonitor()

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
            updateEscapeMonitor()
            restoreWebViewFocus()

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
            updateEscapeMonitor()
            restoreWebViewFocus()

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
        }
        .onChange(of: sessionManager.listNavAction) {
            guard session.id
                == sessionManager.activeSessionId
            else { return }
            guard sessionManager.activeTab == .artifacts
            else { return }
            guard openArtifact == nil else { return }
            guard let action = sessionManager.listNavAction
            else { return }
            sessionManager.listNavAction = nil
            handleListNavAction(action)
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
                        VStack(
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
                    .onChange(of: focusedIndex) {
                        if let idx = focusedIndex,
                           idx < sortedArtifacts.count
                        {
                            scrollProxy.scrollTo(
                                sortedArtifacts[idx].id
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - Index Header

    private var headerRow: some View {
        HStack(spacing: 0) {
            sortableHeader(
                "#", column: .number, width: 40
            )
            sortableHeader(
                "Title", column: .title, width: nil
            )
            sortableHeader(
                "Type", column: .type, width: 80
            )
            sortableHeader(
                "Filename", column: .filename,
                width: nil
            )
            sortableHeader(
                "Size", column: .size, width: 80
            )
            sortableHeader(
                "Created", column: .created, width: 160
            )
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color.primary.opacity(0.05))
    }

    private func sortableHeader(
        _ title: String,
        column: SortColumn,
        width: CGFloat?
    ) -> some View {
        Button(action: {
            if sortColumn == column {
                sortAscending.toggle()
            } else {
                sortColumn = column
                sortAscending =
                    column == .title
                    || column == .filename
            }
        }) {
            HStack(spacing: 3) {
                Text(title)
                    .chromeFont(
                        size: fontSize.caption2,
                        weight: .semibold
                    )
                    .foregroundColor(.secondary)
                if sortColumn == column {
                    Image(
                        systemName: sortAscending
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
        let isFocused = focusedIndex == index

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

                Text(formatTimestamp(artifact.createdAt))
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
                    formatTimestamp(artifact.createdAt)
                )
                .chromeFont(size: fontSize.caption2)
                .foregroundColor(.secondary)

                Spacer()

                // Review with Claude button
                Button(action: {
                    submitReview(
                        artifact: artifact
                    )
                }) {
                    Text("Review with Claude")
                        .chromeFont(
                            size: fontSize.caption2,
                            weight: .medium
                        )
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(
                                cornerRadius: 6
                            )
                            .fill(Color.green)
                        )
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
                .opacity(
                    hasUnreviewedAnnotations ? 1 : 0
                )
                .allowsHitTesting(
                    hasUnreviewedAnnotations
                )

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
                VStack(spacing: 0) {
                    artifactContentView(
                        artifact: artifact,
                        content: content
                    )
                    staleAnnotationsSection
                }
            } else if let path = artifact.sourcePath,
                      isImageExtension(
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
                        itemLabel: label,
                        onAnnotationMessage: {
                            message in
                            handleAnnotationMessage(
                                message,
                                artifact: artifact
                            )
                        },
                        webViewRef: $webViewRef
                    )
                    staleAnnotationsSection
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
    }

    // MARK: - Stale Annotations

    @ViewBuilder
    private var staleAnnotationsSection: some View {
        let staleAnns = openAnnotations.filter {
            $0.stale
        }
        if !staleAnns.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Rectangle()
                    .fill(Color.primary.opacity(0.1))
                    .frame(height: 1)
                DisclosureGroup(
                    "Stale Annotations"
                    + " (\(staleAnns.count))"
                ) {
                    VStack(
                        alignment: .leading,
                        spacing: 8
                    ) {
                        ForEach(staleAnns) { ann in
                            staleAnnotationCard(ann)
                        }
                    }
                    .padding(.top, 4)
                }
                .chromeFont(
                    size: fontSize.caption2,
                    weight: .medium
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(
                Color(.windowBackgroundColor)
            )
        }
    }

    private func staleAnnotationCard(
        _ ann: ArtifactAnnotation
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(ann.content)
                .chromeFont(size: fontSize.caption2)
                .opacity(0.7)

            if let captured = ann.anchorData
                .capturedContent
            {
                Text(captured)
                    .font(.system(
                        size: fontSize.caption2 - 1,
                        design: .monospaced
                    ))
                    .foregroundColor(.secondary)
                    .padding(4)
                    .background(
                        Color.secondary.opacity(0.1)
                    )
                    .cornerRadius(4)
                    .lineLimit(3)
            }

            Button("Dismiss") {
                dismissStaleAnnotation(ann)
            }
            .chromeFont(size: fontSize.caption2)
            .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func dismissStaleAnnotation(
        _ ann: ArtifactAnnotation
    ) {
        guard let lsid = session.ledgerSessionId,
              let artifact = openArtifact
        else { return }
        Task {
            do {
                try await ArtifactQueryService.shared
                    .deleteAnnotation(
                        ledgerSessionId: lsid,
                        artifactNumber: artifact.number,
                        number: ann.number
                    )
                await MainActor.run {
                    openAnnotations.removeAll {
                        $0.number == ann.number
                    }
                    annotationHTMLMap.removeValue(
                        forKey: ann.number
                    )
                }
            } catch {
                NSLog(
                    "ArtifactsView: dismiss stale "
                    + "annotation error: %@",
                    error.localizedDescription
                )
            }
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

        switch ext {
        case "md", "markdown":
            let activeAnns = openAnnotations.filter {
                !$0.stale
            }
            let snapshotAnns: [SnapshotAnnotation]
                = activeAnns.compactMap {
                    snapshotAnnotationFrom($0)
                }
            MarkdownReaderView(
                markdown: content,
                isDark: colorScheme == .dark,
                annotations: snapshotAnns,
                annotationHTMLMap: annotationHTMLMap,
                webViewRef: $webViewRef,
                onAnnotationMessage: { message in
                    handleAnnotationMessage(
                        message,
                        artifact: artifact
                    )
                },
                itemLabel:
                    "Artifact #\(artifact.number)",
                baseUrlName: "artifact-reader"
            )
        case "csv", "tsv":
            let label = "Artifact #\(artifact.number)"
            ArtifactTableView(
                content: content,
                isDark: colorScheme == .dark,
                annotations: openAnnotations,
                annotationHTMLMap: annotationHTMLMap,
                itemLabel: label,
                webViewRef: $webViewRef,
                onAnnotationMessage: { message in
                    handleAnnotationMessage(
                        message,
                        artifact: artifact
                    )
                }
            )
        case "mmd", "mermaid":
            let label = "Artifact #\(artifact.number)"
            let activeAnns = openAnnotations.filter {
                !$0.stale
            }
            ArtifactMermaidView(
                content: content,
                isDark: colorScheme == .dark,
                annotations: activeAnns,
                annotationHTMLMap: annotationHTMLMap,
                itemLabel: label,
                onAnnotationMessage: { message in
                    handleAnnotationMessage(
                        message,
                        artifact: artifact
                    )
                },
                webViewRef: $webViewRef
            )
        case "html", "htm":
            let label = "Artifact #\(artifact.number)"
            ArtifactHTMLView(
                content: content,
                isDark: colorScheme == .dark,
                annotations: openAnnotations,
                annotationHTMLMap: annotationHTMLMap,
                itemLabel: label,
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
                language: languageForExtension(ext),
                isDark: colorScheme == .dark,
                annotations: openAnnotations,
                annotationHTMLMap: annotationHTMLMap,
                itemLabel: label,
                webViewRef: $webViewRef,
                onAnnotationMessage: { message in
                    handleAnnotationMessage(
                        message,
                        artifact: artifact
                    )
                }
            )
        }
    }

    /// Map file extension to highlight.js language name.
    private func languageForExtension(
        _ ext: String
    ) -> String? {
        let map: [String: String] = [
            "rb": "ruby", "cr": "crystal",
            "py": "python", "js": "javascript",
            "ts": "typescript", "jsx": "javascript",
            "tsx": "typescript", "swift": "swift",
            "go": "go", "rs": "rust",
            "java": "java", "kt": "kotlin",
            "sql": "sql", "sh": "bash",
            "bash": "bash", "zsh": "bash",
            "yml": "yaml", "yaml": "yaml",
            "json": "json", "jsonl": "json",
            "toml": "ini",
            "xml": "xml", "html": "xml",
            "htm": "xml", "css": "css",
            "scss": "scss", "less": "less",
            "vue": "xml", "csv": "plaintext",
            "tsv": "plaintext",
            "mmd": "plaintext",
            "mermaid": "plaintext",
        ]
        return map[ext]
    }

    private func isImageExtension(
        _ filename: String
    ) -> Bool {
        let ext = (filename as NSString)
            .pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif",
                "svg", "webp"].contains(ext)
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
                    isLoading = false
                    focusedIndex =
                        result.isEmpty ? nil : 0
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

    private func openArtifactReader(
        artifact: ArtifactSummary
    ) {
        guard let lsid = session.ledgerSessionId
        else { return }

        // Check if the artifact is a type we can
        // render inline. Binary/image/large files
        // open externally.
        let ext = (
            artifact.originalFilename as NSString
        ).pathExtension.lowercased()

        let renderableExtensions: Set<String> = [
            "md", "markdown",
            "rb", "cr", "py", "js", "ts",
            "jsx", "tsx", "swift", "go", "rs",
            "java", "kt", "sql", "sh", "bash",
            "zsh", "yml", "yaml", "json", "toml",
            "xml", "html", "htm", "css", "scss",
            "less", "vue", "csv", "tsv", "txt",
            "jsonl", "mmd", "mermaid", "log", "conf",
            "cfg", "ini", "env", "gitignore",
            "dockerignore", "editorconfig",
            "png", "jpg", "jpeg", "gif", "svg",
            "webp",
        ]

        let imageExtensions: Set<String> = [
            "png", "jpg", "jpeg", "gif", "svg",
            "webp",
        ]

        // Size limits by type
        let sizeLimit: Int64
        if ext == "md" || ext == "markdown" {
            sizeLimit = 512_000
        } else if imageExtensions.contains(ext) {
            sizeLimit = 26_214_400  // 25MB
        } else if ext == "mmd" || ext == "mermaid" {
            sizeLimit = 102_400     // 100KB
        } else {
            sizeLimit = 2_000_000   // 2MB
        }

        if !renderableExtensions.contains(ext)
            || artifact.fileSize > sizeLimit
        {
            openExternally(artifact: artifact)
            return
        }

        // Images use file path directly — no need
        // to read content into a String.
        if imageExtensions.contains(ext),
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
                        = renderAnnotationHTML(
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
                    hasUnreviewedAnnotations
                        = annotations.contains {
                            $0.artifactReviewId
                                == nil && !$0.stale
                        }

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
                        = renderAnnotationHTML(
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
                    hasUnreviewedAnnotations
                        = annotations.contains {
                            $0.artifactReviewId == nil
                                && !$0.stale
                        }

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

    /// Read artifact content from its stored path via
    /// the CLI view command (outputs raw file content).
    private func readArtifactContent(
        ledgerSessionId: Int64,
        artifact: ArtifactSummary
    ) async throws -> String {
        // The view command outputs raw file content
        // to stdout. We need to shell out similarly
        // to other CLI calls.
        let binaryPath =
            "\(NSHomeDirectory())/.claude/galaxy"
            + "/bin/galaxy-artifacts"
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()

        process.executableURL = URL(
            fileURLWithPath: binaryPath
        )
        process.arguments = [
            "view",
            "--ledger-session-id",
            String(ledgerSessionId),
            String(artifact.number),
        ]
        process.standardOutput = stdout
        process.standardError = stderr

        return try await withCheckedThrowingContinuation {
            continuation in
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }

            DispatchQueue.global(qos: .userInitiated)
                .async {
                let outData = stdout
                    .fileHandleForReading
                    .readDataToEndOfFile()
                let errData = stderr
                    .fileHandleForReading
                    .readDataToEndOfFile()
                process.waitUntilExit()

                guard process.terminationStatus == 0
                else {
                    let errMsg = String(
                        data: errData,
                        encoding: .utf8
                    ) ?? "Unknown error"
                    continuation.resume(
                        throwing:
                            ArtifactQueryError
                            .cliError(
                                status: process
                                    .terminationStatus,
                                message: errMsg
                                    .trimmingCharacters(
                                        in:
                                            .whitespacesAndNewlines
                                    )
                            )
                    )
                    return
                }

                let content = String(
                    data: outData,
                    encoding: .utf8
                ) ?? ""
                continuation.resume(
                    returning: content
                )
            }
        }
    }

    private func openExternally(
        artifact: ArtifactSummary
    ) {
        // Use the source_path if available, otherwise
        // try the stored artifact path
        if let sourcePath = artifact.sourcePath {
            NSWorkspace.shared.open(
                URL(fileURLWithPath: sourcePath)
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

    /// Check for unsaved annotation state before
    /// closing the reader. Mirrors the escape-key
    /// logic for consistency.
    private func handleBackButton() {
        // Check WKWebView annotation forms
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

        let closingNumber = openArtifact?.number
        removeEscapeMonitor()
        sessionManager.isArtifactReaderOpen = false
        webViewRef = nil
        openArtifact = nil
        openArtifactContent = nil
        openAnnotations = []
        annotationHTMLMap = [:]
        hasUnreviewedAnnotations = false

        if let number = closingNumber {
            focusedIndex = sortedArtifacts
                .firstIndex(where: {
                    $0.number == number
                })
        }
    }

    // MARK: - Annotation Bridge

    /// Convert an ArtifactAnnotation to a
    /// SnapshotAnnotation for MarkdownReaderView.
    /// Only works for line_range annotations.
    private func snapshotAnnotationFrom(
        _ ann: ArtifactAnnotation
    ) -> SnapshotAnnotation? {
        guard ann.anchorData.type == .lineRange,
              let startLine = ann.anchorData.startLine,
              let endLine = ann.anchorData.endLine
        else { return nil }
        return SnapshotAnnotation(
            id: ann.id,
            createdAt: ann.createdAt,
            updatedAt: ann.updatedAt,
            snapshotId: ann.artifactId,
            number: ann.number,
            startLine: startLine,
            endLine: endLine,
            content: ann.content,
            snapshotReviewId: ann.artifactReviewId,
            reviewNumber: ann.reviewNumber,
            reviewReviewedAt: ann.reviewReviewedAt
        )
    }

    // MARK: - Annotation Messages

    private func handleAnnotationMessage(
        _ message: AnnotationMessage,
        artifact: ArtifactSummary
    ) {
        guard let lsid = session.ledgerSessionId
        else { return }

        switch message {
        case .create(
            let startLine, let endLine,
            let content
        ):
            let lines = (openArtifactContent ?? "")
                .components(separatedBy: "\n")
            let start = max(Int(startLine) - 1, 0)
            let end = min(
                Int(endLine), lines.count
            )
            let lineContent = lines[start..<end]
                .joined(separator: "\n")
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
                        hasUnreviewedAnnotations
                            = openAnnotations.contains {
                                $0.artifactReviewId
                                    == nil && !$0.stale
                            }
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
        }
    }

    /// Serialize an annotation + rendered HTML to a
    /// JSON string for JS injection. Works for both
    /// snapshot-bridged and artifact annotations.
    private func buildAnnotationPayload(
        annotation: SnapshotAnnotation,
        renderedHTML: String
    ) -> String {
        var annDict: [String: Any] = [
            "id": annotation.id,
            "number": annotation.number,
            "start_line": annotation.startLine,
            "end_line": annotation.endLine,
            "content": annotation.content,
            "created_at": annotation.createdAt,
            "updated_at": annotation.updatedAt,
        ]
        if let rn = annotation.reviewNumber {
            annDict["review_number"] = rn
        }
        if let rra = annotation.reviewReviewedAt {
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
        // Set position keys based on anchor type
        switch ann.anchorData.type {
        case .lineRange:
            if let sl = ann.anchorData.startLine {
                annDict["start_line"] = sl
            }
            if let el = ann.anchorData.endLine {
                annDict["end_line"] = el
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
                let html = renderAnnotationHTML(
                    ann.content
                )
                await MainActor.run {
                    openAnnotations.append(ann)
                    annotationHTMLMap[
                        ann.number
                    ] = html
                    hasUnreviewedAnnotations = true
                }
                // For markdown artifacts, use
                // snapshot bridge; for others use
                // generic payload
                let payload: String
                if let snapAnn
                    = snapshotAnnotationFrom(ann)
                {
                    payload = buildAnnotationPayload(
                        annotation: snapAnn,
                        renderedHTML: html
                    )
                } else {
                    payload
                        = buildGenericAnnotationPayload(
                            ann: ann,
                            renderedHTML: html
                        )
                }
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
                let html = renderAnnotationHTML(
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
                let payload: String
                if let snapAnn
                    = snapshotAnnotationFrom(ann)
                {
                    payload = buildAnnotationPayload(
                        annotation: snapAnn,
                        renderedHTML: html
                    )
                } else {
                    payload
                        = buildGenericAnnotationPayload(
                            ann: ann,
                            renderedHTML: html
                        )
                }
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
                + "if you start a new annotation.",
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

    // MARK: - Review Actions

    private func submitReview(
        artifact: ArtifactSummary
    ) {
        hasUnreviewedAnnotations = false
        guard let lsid = session.ledgerSessionId
        else { return }

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
                        hasUnreviewedAnnotations = true
                    }
                    return
                }

                let message = buildReviewMessage(
                    ledgerSessionId: lsid,
                    artifactNumber: artifact.number
                )

                await MainActor.run {
                    session.afterNextIdle {
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
                                        self
                                            .hasUnreviewedAnnotations
                                            = true
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
                        artifactNumber: artifact.number
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
                        hasUnreviewedAnnotations = true
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
                    = renderAnnotationHTML(ann.content)
            }

            await MainActor.run {
                guard openArtifact?.number
                    == artifact.number
                else { return }

                openAnnotations = annotations
                annotationHTMLMap = htmlMap
                hasUnreviewedAnnotations
                    = annotations.contains {
                        $0.artifactReviewId == nil
                            && !$0.stale
                    }

                // Push updated annotations to JS
                // (skip for whole-type renderers
                // which use SwiftUI cards)
                let activeAnns = annotations.filter {
                    !$0.stale
                        && $0.anchorData.type != .whole
                }
                let annDicts: [[String: Any]]
                    = activeAnns.map { a in
                        var dict: [String: Any] = [
                            "id": a.id,
                            "number": a.number,
                            "content": a.content,
                            "created_at": a.createdAt,
                            "updated_at": a.updatedAt,
                        ]
                        switch a.anchorData.type {
                        case .lineRange:
                            if let sl = a.anchorData
                                .startLine {
                                dict["start_line"] = sl
                            }
                            if let el = a.anchorData
                                .endLine {
                                dict["end_line"] = el
                            }
                        case .rowRange:
                            if let sr = a.anchorData
                                .startRow {
                                dict["start_row"] = sr
                            }
                            if let er = a.anchorData
                                .endRow {
                                dict["end_row"] = er
                            }
                        case .blockRange:
                            if let sb = a.anchorData
                                .startBlock {
                                dict["start_block"]
                                    = sb
                            }
                            if let eb = a.anchorData
                                .endBlock {
                                dict["end_block"] = eb
                            }
                        case .whole:
                            break
                        }
                        if let rn = a.reviewNumber {
                            dict["review_number"] = rn
                        }
                        if let rra
                            = a.reviewReviewedAt
                        {
                            dict["review_reviewed_at"]
                                = rra
                        }
                        return dict
                    }
                if !annDicts.isEmpty,
                   let data = try? JSONSerialization
                    .data(
                        withJSONObject: annDicts
                    ),
                   let json = String(
                       data: data, encoding: .utf8
                   )
                {
                    webViewRef?.evaluateJavaScript(
                        "AnnotationManager"
                        + ".refreshAnnotationData"
                        + "(\(json))"
                    )
                }
            }
        } catch {
            NSLog(
                "ArtifactsView: refresh annotations "
                + "error: %@",
                error.localizedDescription
            )
        }
    }

    private func buildReviewMessage(
        ledgerSessionId: Int64,
        artifactNumber: Int32
    ) -> String {
        let sid = ledgerSessionId
        let an = artifactNumber
        return "I've submitted artifact annotations "
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

    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor =
            NSEvent.addLocalMonitorForEvents(
                matching: .keyDown
            ) { [self] event in
                if event.keyCode == 53 {
                    guard session.id
                        == sessionManager
                            .activeSessionId,
                          sessionManager.activeTab
                            == .artifacts
                    else {
                        return event
                    }

                    webViewRef?.evaluateJavaScript(
                        "typeof AnnotationManager "
                        + "!== 'undefined' ? "
                        + "AnnotationManager"
                        + ".getEscapeContext() "
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
                            self.webViewRef?
                                .evaluateJavaScript(
                                    """
                                    (function() {
                                        var ta = document.querySelector('.annotation-textarea:focus') ||
                                                 document.querySelector('.annotation-edit-textarea:focus');
                                        if (ta && typeof EmojiAutocomplete !== 'undefined') {
                                            EmojiAutocomplete.dismiss(ta);
                                        }
                                    })()
                                    """
                                )
                        case "editing":
                            self
                                .showDiscardEditAlert()
                        case "expanded":
                            self.webViewRef?
                                .evaluateJavaScript(
                                    "AnnotationManager"
                                    + ".collapseExpanded"
                                    + "()"
                                )
                        case "formHasText":
                            self
                                .showDiscardFormAlert()
                        case "formVisible":
                            self.webViewRef?
                                .evaluateJavaScript(
                                    "AnnotationManager"
                                    + ".dismissForm()"
                                )
                        case "__consumed__":
                            break
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

    // MARK: - List Focus Navigation

    private func handleListNavAction(
        _ action: ListNavAction
    ) {
        let items = sortedArtifacts
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
                guard current < items.count - 1
                else { return }
                focusedIndex = current + 1
            } else {
                focusedIndex = 0
            }
        case .activate:
            guard let idx = focusedIndex,
                  idx < items.count
            else { return }
            openArtifactReader(
                artifact: items[idx]
            )
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

    private static let iso8601WithFractional: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSZ"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let iso8601Standard: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let sqliteDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private static let displayDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        return f
    }()

    private func formatTimestamp(
        _ timestamp: String
    ) -> String {
        let formatters = [
            Self.iso8601WithFractional,
            Self.iso8601Standard,
            Self.sqliteDateFormatter,
        ]
        for formatter in formatters {
            if let date = formatter.date(
                from: timestamp
            ) {
                return Self.displayDateFormatter.string(
                    from: date
                )
            }
        }
        return timestamp
    }
}
