import SwiftUI
import Combine

/// Content-sized entry listing with 300ms debounced search.
/// Owns its own vertical ScrollView so the metadata header
/// and subtab picker stay fixed while the table scrolls.
struct LedgerEntriesView: View {
    let sessionId: UUID
    let entries: [LedgerEntry]?
    let isLoading: Bool
    let ledgerSessionId: Int64?
    @Binding var searchQuery: String
    let onSearch: (String) -> Void
    let onClearSearch: () -> Void

    @EnvironmentObject var sessionManager: SessionManager
    @Environment(\.chromeFontSize) private var chromeFontSize
    private var fontSize: ChromeFontSize { ChromeFontSize(chromeFontSize) }

    @State private var expandedEntryIds: Set<Int64> = []

    /// Order and selection. The selection is an identity rather than a row
    /// number, so re-sorting cannot slide the highlight onto another entry.
    @State private var model = ListSortModel<LedgerEntry, SortColumn>(
        columns: LedgerEntriesView.columns,
        sortColumn: .importance,
        sortAscending: true)
    /// Incrementing counter — each bump triggers one focus request
    /// on the SafeSearchField via AppKit's makeFirstResponder.
    @State private var searchFocusTrigger: Int = 0

    /// Debounce publisher for search input
    @State private var searchSubject = PassthroughSubject<String, Never>()
    @State private var searchCancellable: AnyCancellable?

    enum SortColumn {
        case entryType, importance, source, content, category, created
    }

    /// What each column is called and how it orders. This tab opens on
    /// Importance, which is why its ranking is the one that matters most here.
    private static let columns: [ListColumn<LedgerEntry, SortColumn>] = [
        .init(.entryType, title: "Type") {
            ListSorting.compareText($0.entryType, $1.entryType)
        },
        // Ranked rather than spelled: as prose, "low" sorts between "high"
        // and "medium", so ascending read high, low, medium.
        .init(.importance, title: "Importance") {
            ListSorting.compare(
                ListSorting.importanceRank($0.importance),
                ListSorting.importanceRank($1.importance))
        },
        .init(.source, title: "Source") {
            ListSorting.compareText($0.source ?? "", $1.source ?? "")
        },
        .init(.content, title: "Content") {
            ListSorting.compareText($0.content, $1.content)
        },
        .init(.category, title: "Category") {
            ListSorting.compareText($0.category ?? "", $1.category ?? "")
        },
        .init(.created, title: "Created", prefersAscending: false) {
            ListSorting.compare($0.createdAt, $1.createdAt)
        },
    ]

    private var sortedEntries: [LedgerEntry] { model.sorted(entries) }

    var body: some View {
        mainContent
            .onAppear {
                setupSearchDebounce()
                searchFocusTrigger += 1
            }
            .listNavigation(
                from: sessionManager,
                isActive: {
                    // Spelled out rather than reusing `isSearchActive`, which
                    // asks two of these three and would answer yes from
                    // another tab.
                    sessionManager.activeTab == .ledger
                        && sessionManager.activeLedgerSubTab == .entries
                        && sessionId == sessionManager.activeSessionId
                },
                onAction: { action in
                    switch action {
                    case .up: model.move(.up, in: sortedEntries)
                    case .down: model.move(.down, in: sortedEntries)
                    case .activate: break  // Given a meaning below the table
                    }
                })
            // Keyed on the rows themselves, not how many there are: a search
            // returning as many entries as it replaced never fired at all.
            .onChange(of: entries.map { $0.map(\.id) }) {
                model.reconcileFocus(in: sortedEntries, seed: .first)
            }
            .onChange(of: sessionManager.activeTab) { focusSearchIfActive() }
            .onChange(of: sessionManager.activeSessionId) { focusSearchIfActive() }
            .onChange(of: sessionManager.activeLedgerSubTab) { focusSearchIfActive() }
    }

    /// Focus the search field when navigating to the Entries subtab.
    private func focusSearchIfActive() {
        guard sessionManager.activeTab == .ledger,
              sessionManager.activeLedgerSubTab == .entries,
              sessionId == sessionManager.activeSessionId else { return }
        searchFocusTrigger += 1
    }

    // MARK: - Main Content

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            searchBar

            if !searchQuery.isEmpty, let entries = entries {
                Text("Showing \(entries.count) result\(entries.count == 1 ? "" : "s") for \"\(searchQuery)\"")
                    .chromeFont(size: fontSize.caption2)
                    .foregroundColor(.secondary)
            }

            if isLoading && entries == nil {
                HStack {
                    Spacer()
                    ProgressView()
                        .scaleEffect(0.8)
                        .padding()
                    Spacer()
                }
            } else if let entries = entries, entries.isEmpty {
                if searchQuery.isEmpty {
                    emptyState
                } else {
                    Text("No entries matching \"\(searchQuery)\".")
                        .chromeFont(size: fontSize.caption)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 8)
                }
            } else if entries != nil {
                entriesContent
            } else {
                // No ledger session yet or fetch never started
                emptyState
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "list.bullet")
                .chromeFont(size: fontSize.iconLarge)
                .foregroundColor(.secondary)
            Text("No entries")
                .chromeFont(size: fontSize.title2)
                .foregroundColor(.primary)
            Text("Entries are captured automatically as the session works")
                .chromeFont(size: fontSize.body)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Search Bar

    /// Active when this is the visible session AND the Entries subtab is selected.
    private var isSearchActive: Bool {
        sessionId == sessionManager.activeSessionId
            && sessionManager.activeLedgerSubTab == .entries
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.system(size: 12))
            SafeSearchField(
                text: $searchQuery,
                placeholder: "Search entries...",
                fontSize: fontSize.caption2,
                focusTrigger: searchFocusTrigger,
                isActive: isSearchActive,
                onTextChange: { searchSubject.send($0) },
                onSubmit: {
                    if searchQuery.isEmpty {
                        onClearSearch()
                    } else {
                        onSearch(searchQuery)
                    }
                }
            )
            if !searchQuery.isEmpty {
                Button(action: {
                    searchQuery = ""
                    onClearSearch()
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
        .frame(maxWidth: 300)
    }

    // MARK: - Table Layout

    /// Fixed column widths — Content is the flex column.
    private static let colType: CGFloat = 90
    private static let colImportance: CGFloat = 100
    private static let colSource: CGFloat = 80
    private static let colCategory: CGFloat = 90
    private static let colCreated: CGFloat = 150
    private static let colSpacing: CGFloat = 8
    private static let rowPadding: CGFloat = 16  // 8 each side
    /// Sum of fixed columns + inter-column gaps (5 gaps for 6 columns) + row padding
    private static let fixedTotal: CGFloat =
        colType + colImportance + colSource + colCategory + colCreated
        + (colSpacing * 5) + rowPadding
    private static let flexMin: CGFloat = 300

    // MARK: - Entries Content

    private var entriesContent: some View {
        GeometryReader { geo in
            let flexWidth = max(
                Self.flexMin,
                geo.size.width - Self.fixedTotal
            )
            let tableWidth =
                Self.fixedTotal + flexWidth

            ScrollViewReader { scrollProxy in
                ScrollView {
                    ScrollView(
                        .horizontal,
                        showsIndicators: true
                    ) {
                        VStack(
                            alignment: .leading,
                            spacing: 0
                        ) {
                            headerRow(
                                flexWidth: flexWidth
                            )

                            ForEach(
                                Array(
                                    sortedEntries
                                        .enumerated()
                                ),
                                id: \.element.id
                            ) { index, entry in
                                entryRow(
                                    entry,
                                    index: index,
                                    flexWidth: flexWidth
                                )
                                .id(entry.id)
                            }
                        }
                        .frame(width: tableWidth)
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

    // MARK: - Header

    private func headerRow(flexWidth: CGFloat) -> some View {
        HStack(spacing: Self.colSpacing) {
            sortableHeader(.entryType, width: Self.colType)
            sortableHeader(.importance, width: Self.colImportance)
            sortableHeader(.source, width: Self.colSource)
            sortableHeader(.content, width: flexWidth)
            sortableHeader(.category, width: Self.colCategory)
            sortableHeader(.created, width: Self.colCreated)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color.primary.opacity(0.05))
    }

    private func sortableHeader(_ column: SortColumn, width: CGFloat) -> some View {
        LedgerTableHeader(
            title: model.title(for: column),
            width: width,
            isSorted: model.sortColumn == column,
            ascending: model.sortAscending,
            fontSize: fontSize,
            onTap: { model.select(column) })
    }

    // MARK: - Data Row

    private func entryRow(_ entry: LedgerEntry, index: Int, flexWidth: CGFloat) -> some View {
        let isExpanded = expandedEntryIds.contains(entry.id)
        let isFocused = model.focusedId == entry.id

        return HStack(spacing: Self.colSpacing) {
            Text(entry.entryType)
                .chromeFontMono(size: fontSize.caption2)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: Self.colType, alignment: .leading)

            Text(entry.importance)
                .chromeFontMono(size: fontSize.caption2)
                .foregroundColor(importanceColor(entry.importance))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: Self.colImportance, alignment: .leading)

            Text(entry.source ?? "--")
                .chromeFontMono(size: fontSize.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: Self.colSource, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(isExpanded ? entry.content : String(entry.content.prefix(200)))
                    .chromeFontMono(size: fontSize.caption2)
                    .lineLimit(isExpanded ? nil : 1)
                    .truncationMode(.tail)
                if entry.content.count > 80 {
                    Button(isExpanded ? "Show less" : "Show more") {
                        if isExpanded {
                            expandedEntryIds.remove(entry.id)
                        } else {
                            expandedEntryIds.insert(entry.id)
                        }
                    }
                    .buttonStyle(.plain)
                    .chromeFont(size: fontSize.caption2)
                    .foregroundColor(.accentColor)
                }
            }
            .frame(width: flexWidth, alignment: .leading)

            Text(entry.category ?? "--")
                .chromeFontMono(size: fontSize.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: Self.colCategory, alignment: .leading)

            Text(ListTimestamp.format(entry.createdAt))
                .chromeFontMono(size: fontSize.caption2)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: Self.colCreated, alignment: .leading)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .background(
            isFocused
                ? Color.accentColor.opacity(0.15)
                : (index % 2 == 1 ? Color.primary.opacity(0.03) : Color.clear)
        )
    }

    // MARK: - Search Debounce

    private func setupSearchDebounce() {
        searchCancellable = searchSubject
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { query in
                if query.isEmpty {
                    onClearSearch()
                } else {
                    onSearch(query)
                }
            }
    }

    // MARK: - Helpers

    private func importanceColor(_ importance: String) -> Color {
        switch importance.lowercased() {
        case "high": return .red
        case "medium": return .orange
        default: return .secondary
        }
    }
}

// MARK: - Safe Search Field (AppKit-backed)

/// NSViewRepresentable wrapping InlineEditField for the entries search bar.
/// Uses the same key-view-safe NSTextField subclass as the session rename
/// field, avoiding the autofill heuristic traversal that blocks the main
/// thread when SwiftUI's TextField becomes first responder in the ZStack.
struct SafeSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let fontSize: CGFloat
    /// Incrementing counter — each change from the last-seen value
    /// triggers one makeFirstResponder call via AppKit.
    let focusTrigger: Int
    /// Only the active session's search field should grab focus.
    /// Without this guard, all ZStack instances dispatch focus and
    /// the last hidden one wins.
    let isActive: Bool
    /// Called on every keystroke with the current field value.
    /// Used to feed the debounce pipeline directly from AppKit,
    /// bypassing the SwiftUI state round-trip.
    var onTextChange: ((String) -> Void)? = nil
    /// Called when the user presses Enter/Return in the field.
    var onSubmit: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> InlineEditField {
        let field = InlineEditField()
        field.font = NSFont.systemFont(ofSize: fontSize)
        field.placeholderString = placeholder
        field.textColor = .labelColor
        field.backgroundColor = .clear
        field.isBordered = false
        field.focusRingType = .none
        field.drawsBackground = false
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ nsView: InlineEditField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.font = NSFont.systemFont(ofSize: fontSize)

        // Focus when the trigger counter advances — active instance only
        if isActive && focusTrigger != context.coordinator.lastSeenTrigger {
            context.coordinator.lastSeenTrigger = focusTrigger
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SafeSearchField
        /// Last focusTrigger value we acted on
        var lastSeenTrigger: Int = 0

        init(_ parent: SafeSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            let value = field.stringValue
            parent.text = value
            parent.onTextChange?(value)
        }

        /// Intercept Enter/Return to trigger an immediate search.
        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit?()
                return true  // handled — don't insert newline
            }
            return false
        }
    }
}
