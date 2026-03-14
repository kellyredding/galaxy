import SwiftUI
import Combine

struct RestoreSessionView: View {
    let onDismiss: () -> Void

    @ObservedObject private var sessionManager = SessionManager.shared
    @ObservedObject private var settingsManager = SettingsManager.shared
    @State private var selectedId: UUID? = nil
    @State private var searchText: String = ""
    @State private var searchFocusTrigger: Int = 0
    private let searchSubject = PassthroughSubject<String, Never>()
    @State private var debouncedSearch: String = ""
    @State private var debounceCancel: AnyCancellable? = nil
    @State private var scrollProxy: ScrollViewProxy? = nil

    /// Width of the column being dragged at gesture start.
    @State private var dragStartWidth: CGFloat = 0

    /// Global X position at drag start — used to compute our own
    /// translation independent of ScrollView coordinate shifts.
    @State private var dragStartX: CGFloat = 0

    /// Table width frozen at drag start to prevent ScrollView jitter.
    /// During a drag the effective width only grows, never shrinks.
    @State private var frozenTableWidth: CGFloat = 0

    /// Closed sessions filtered by the debounced search query.
    private var filteredSessions: [PersistedClosedSession] {
        guard !debouncedSearch.isEmpty else {
            return sessionManager.closedSessions
        }
        let query = debouncedSearch.lowercased()
        return sessionManager.closedSessions.filter { closed in
            let s = closed.session
            let name = displayName(for: s).lowercased()
            let persona = (s.personaName ?? "").lowercased()
            let dir = abbreviatedPath(s.workingDirectory).lowercased()
            let time = relativeTime(closed.closedAt).lowercased()
            return name.contains(query)
                || persona.contains(query)
                || dir.contains(query)
                || time.contains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            searchBar
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)

            // Table or empty state
            if sessionManager.closedSessions.isEmpty {
                emptyState
            } else if filteredSessions.isEmpty {
                noMatchesState
            } else {
                tableContent
            }

            Divider()

            // Button row
            buttonRow
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(minWidth: 500, idealWidth: 640, minHeight: 300, idealHeight: 420)
        .onAppear {
            // Select the first (most recently closed) session
            selectedId = sessionManager.closedSessions.first?.session.id

            // Focus the search field so the user can start typing immediately
            searchFocusTrigger += 1

            // Set up debounce pipeline
            debounceCancel = searchSubject
                .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
                .removeDuplicates()
                .sink { query in
                    debouncedSearch = query
                    // Re-select first match after filter changes
                    if let first = filteredSessions.first {
                        selectedId = first.session.id
                    } else {
                        selectedId = nil
                    }
                }
        }
        .onReceive(NotificationCenter.default.publisher(for: .restoreSessionNavigateUp)) { _ in
            moveSelection(by: -1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .restoreSessionNavigateDown)) { _ in
            moveSelection(by: 1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .restoreSessionConfirm)) { _ in
            restoreSelected()
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.system(size: 12))
            SafeSearchField(
                text: $searchText,
                placeholder: "Filter sessions...",
                fontSize: 12,
                focusTrigger: searchFocusTrigger,
                isActive: true,
                onTextChange: { searchSubject.send($0) },
                onSubmit: { restoreSelected() }
            )
            if !searchText.isEmpty {
                Button(action: {
                    searchText = ""
                    debouncedSearch = ""
                    selectedId = sessionManager.closedSessions.first?.session.id
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(.controlBackgroundColor))
        )
    }

    // MARK: - Table Content

    /// Total width of all columns plus divider gaps and row padding.
    private var computedTableWidth: CGFloat {
        let s = settingsManager.settings
        return s.restoreColNameWidth
            + s.restoreColPersonaWidth
            + s.restoreColDirectoryWidth
            + s.restoreColClosedWidth
            + 32  // four 8px divider gaps
            + 32  // horizontal padding (16 each side)
    }

    /// Effective table width — during a drag, only allows growth
    /// (never shrinks) to prevent ScrollView repositioning jitter.
    private var tableRowWidth: CGFloat {
        if frozenTableWidth > 0 {
            return max(frozenTableWidth, computedTableWidth)
        }
        return computedTableWidth
    }

    private var tableContent: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 0) {
                        // Header
                        tableHeader
                            .padding(.horizontal, 16)

                        // Rows
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(filteredSessions, id: \.session.id) { closed in
                                tableRow(closed)
                                    .id(closed.session.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        selectedId = closed.session.id
                                    }
                                    .simultaneousGesture(
                                        TapGesture(count: 2).onEnded {
                                            selectedId = closed.session.id
                                            restoreSelected()
                                        }
                                    )
                            }
                        }
                    }
                    .frame(
                        minWidth: max(tableRowWidth, geo.size.width),
                        alignment: .leading
                    )
                }
                .onAppear { scrollProxy = proxy }
            }
        }
    }

    private var tableHeader: some View {
        let s = settingsManager.settings
        return HStack(spacing: 0) {
            Text("Name")
                .padding(.horizontal, 6)
                .frame(width: s.restoreColNameWidth, alignment: .leading)
            columnDivider(
                binding: \.restoreColNameWidth,
                minWidth: AppSettings.restoreColNameMinWidth,
                autoFit: { autoFitName() }
            )
            Text("Persona")
                .padding(.horizontal, 6)
                .frame(width: s.restoreColPersonaWidth, alignment: .leading)
            columnDivider(
                binding: \.restoreColPersonaWidth,
                minWidth: AppSettings.restoreColPersonaMinWidth,
                autoFit: { autoFitPersona() }
            )
            Text("Directory")
                .padding(.horizontal, 6)
                .frame(width: s.restoreColDirectoryWidth, alignment: .leading)
            columnDivider(
                binding: \.restoreColDirectoryWidth,
                minWidth: AppSettings.restoreColDirectoryMinWidth,
                autoFit: { autoFitDirectory() }
            )
            Text("Closed")
                .padding(.horizontal, 6)
                .frame(width: s.restoreColClosedWidth, alignment: .trailing)
            columnDivider(
                binding: \.restoreColClosedWidth,
                minWidth: AppSettings.restoreColClosedMinWidth,
                autoFit: { autoFitClosed() }
            )
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundColor(.secondary)
        .padding(.vertical, 4)
    }

    /// Draggable divider between column headers. Resizes the column
    /// to its left — dragging right makes it wider, left makes it
    /// narrower. Double-click to auto-fit. Simple single-column
    /// resize like NSTableView.
    private func columnDivider(
        binding: WritableKeyPath<AppSettings, CGFloat>,
        minWidth: CGFloat,
        autoFit: @escaping () -> Void
    ) -> some View {
        let maxW = AppSettings.restoreColMaxWidth

        return Color(.separatorColor)
            .frame(width: 2)
            .padding(.horizontal, 3)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .onTapGesture(count: 2) {
                autoFit()
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        // Capture initial state on first drag event.
                        // Use global coordinate space so ScrollView
                        // content-offset shifts can't affect our delta.
                        if dragStartWidth == 0 {
                            dragStartWidth = settingsManager.settings[
                                keyPath: binding
                            ]
                            dragStartX = value.startLocation.x
                            frozenTableWidth = computedTableWidth
                        }
                        let delta = value.location.x - dragStartX
                        let newWidth = min(
                            max(dragStartWidth + delta, minWidth),
                            maxW
                        )
                        var txn = Transaction()
                        txn.disablesAnimations = true
                        withTransaction(txn) {
                            settingsManager.settings[keyPath: binding] = newWidth
                        }
                    }
                    .onEnded { _ in
                        dragStartWidth = 0
                        dragStartX = 0
                        frozenTableWidth = 0
                    }
            )
    }

    private func tableRow(_ closed: PersistedClosedSession) -> some View {
        let s = closed.session
        let isSelected = selectedId == s.id
        let dirExists = FileManager.default.fileExists(atPath: s.workingDirectory)
        let cols = settingsManager.settings

        return HStack(spacing: 0) {
            Text(displayName(for: s))
                .lineLimit(1)
                .padding(.horizontal, 6)
                .frame(width: cols.restoreColNameWidth, alignment: .leading)
            Color.clear
                .frame(width: 2)
                .padding(.horizontal, 3)
                .frame(maxHeight: .infinity)
            Text(s.personaName ?? "—")
                .lineLimit(1)
                .foregroundColor(.secondary)
                .padding(.horizontal, 6)
                .frame(width: cols.restoreColPersonaWidth, alignment: .leading)
            Color.clear
                .frame(width: 2)
                .padding(.horizontal, 3)
                .frame(maxHeight: .infinity)
            HStack(spacing: 3) {
                if !dirExists {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                        .font(.system(size: 9))
                        .help("Directory no longer exists")
                }
                Text(abbreviatedPath(s.workingDirectory))
                    .lineLimit(1)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 6)
            .frame(width: cols.restoreColDirectoryWidth, alignment: .leading)
            Color.clear
                .frame(width: 2)
                .padding(.horizontal, 3)
                .frame(maxHeight: .infinity)
            Text(relativeTime(closed.closedAt))
                .lineLimit(1)
                .foregroundColor(.secondary)
                .padding(.horizontal, 6)
                .frame(width: cols.restoreColClosedWidth, alignment: .trailing)
            Color.clear
                .frame(width: 2)
                .padding(.horizontal, 3)
                .frame(maxHeight: .infinity)
        }
        .font(.system(size: 12))
        .padding(.vertical, 6)
        .padding(.horizontal, 16)
        .background(
            isSelected
                ? Color.accentColor.opacity(0.2)
                : Color.clear
        )
    }

    // MARK: - Empty States

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("No recently closed sessions")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noMatchesState: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("No sessions match \"\(debouncedSearch)\"")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Button Row

    private var buttonRow: some View {
        HStack {
            Spacer()
            Button("Cancel") {
                onDismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button("Restore") {
                restoreSelected()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selectedId == nil || filteredSessions.isEmpty)
        }
    }

    // MARK: - Actions

    private func restoreSelected() {
        guard let id = selectedId,
              let closed = filteredSessions.first(where: { $0.session.id == id })
        else { return }
        sessionManager.restoreSession(closedSession: closed)
        onDismiss()
    }

    private func moveSelection(by offset: Int) {
        let sessions = filteredSessions
        guard !sessions.isEmpty else { return }

        let currentIndex = sessions.firstIndex(where: { $0.session.id == selectedId }) ?? 0
        let newIndex = min(max(currentIndex + offset, 0), sessions.count - 1)
        let newId = sessions[newIndex].session.id
        selectedId = newId
        scrollProxy?.scrollTo(newId, anchor: .center)
    }

    // MARK: - Auto-Fit Columns

    /// Row content font used for width measurement.
    private static let rowFont = NSFont.systemFont(ofSize: 12)
    /// Header label font used for width measurement.
    private static let headerFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    /// Horizontal padding on each side of a cell (6px × 2).
    private static let cellPadding: CGFloat = 12

    /// Measure the rendered width of a string at a given font.
    private func textWidth(_ string: String, font: NSFont) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        return ceil((string as NSString).size(withAttributes: attrs).width)
    }

    /// Optimal column width: max of header label and all visible row
    /// values, plus cell padding, clamped to min/max bounds.
    private func optimalWidth(
        header: String,
        values: [String],
        minWidth: CGFloat
    ) -> CGFloat {
        let maxW = AppSettings.restoreColMaxWidth
        let headerW = textWidth(header, font: Self.headerFont) + Self.cellPadding
        let contentW = values.map { textWidth($0, font: Self.rowFont) + Self.cellPadding }.max() ?? 0
        return min(max(max(headerW, contentW), minWidth), maxW)
    }

    /// Toggle a column between fit-to-content and its default width.
    /// If the current width matches the optimal fit, snap to default;
    /// otherwise snap to fit.
    private func toggleFit(
        current: CGFloat,
        defaultWidth: CGFloat,
        optimal: CGFloat,
        apply: (CGFloat) -> Void
    ) {
        // Use 1px tolerance for floating-point comparison
        if abs(current - optimal) < 1 {
            apply(defaultWidth)
        } else {
            apply(optimal)
        }
    }

    private func autoFitName() {
        let values = filteredSessions.map { displayName(for: $0.session) }
        let optimal = optimalWidth(
            header: "Name", values: values,
            minWidth: AppSettings.restoreColNameMinWidth
        )
        toggleFit(
            current: settingsManager.settings.restoreColNameWidth,
            defaultWidth: AppSettings.default.restoreColNameWidth,
            optimal: optimal
        ) { settingsManager.settings.restoreColNameWidth = $0 }
    }

    private func autoFitPersona() {
        let values = filteredSessions.map { $0.session.personaName ?? "—" }
        let optimal = optimalWidth(
            header: "Persona", values: values,
            minWidth: AppSettings.restoreColPersonaMinWidth
        )
        toggleFit(
            current: settingsManager.settings.restoreColPersonaWidth,
            defaultWidth: AppSettings.default.restoreColPersonaWidth,
            optimal: optimal
        ) { settingsManager.settings.restoreColPersonaWidth = $0 }
    }

    private func autoFitDirectory() {
        // Add extra space for the warning icon on missing directories
        let extraIcon: CGFloat = 15
        let maxW = AppSettings.restoreColMaxWidth
        let minW = AppSettings.restoreColDirectoryMinWidth
        let headerW = textWidth("Directory", font: Self.headerFont) + Self.cellPadding
        let contentW = filteredSessions.map { closed -> CGFloat in
            let text = abbreviatedPath(closed.session.workingDirectory)
            let w = textWidth(text, font: Self.rowFont) + Self.cellPadding
            let dirExists = FileManager.default.fileExists(atPath: closed.session.workingDirectory)
            return dirExists ? w : w + extraIcon
        }.max() ?? 0
        let optimal = min(max(max(headerW, contentW), minW), maxW)
        toggleFit(
            current: settingsManager.settings.restoreColDirectoryWidth,
            defaultWidth: AppSettings.default.restoreColDirectoryWidth,
            optimal: optimal
        ) { settingsManager.settings.restoreColDirectoryWidth = $0 }
    }

    private func autoFitClosed() {
        let values = filteredSessions.map { relativeTime($0.closedAt) }
        let optimal = optimalWidth(
            header: "Closed", values: values,
            minWidth: AppSettings.restoreColClosedMinWidth
        )
        toggleFit(
            current: settingsManager.settings.restoreColClosedWidth,
            defaultWidth: AppSettings.default.restoreColClosedWidth,
            optimal: optimal
        ) { settingsManager.settings.restoreColClosedWidth = $0 }
    }

    // MARK: - Helpers

    /// Display name for a persisted session — mirrors Session.displayName logic.
    private func displayName(for s: PersistedSession) -> String {
        if let name = s.givenName, !name.isEmpty {
            return "\(name) (\(s.sessionRef))"
        }
        if let suggested = s.ledgerSuggestedName, !suggested.isEmpty {
            return "\(suggested) (\(s.sessionRef))"
        }
        return s.sessionRef
    }

    /// Abbreviate a path by replacing the home directory with ~.
    private func abbreviatedPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    /// Format a date as fuzzy relative time.
    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
