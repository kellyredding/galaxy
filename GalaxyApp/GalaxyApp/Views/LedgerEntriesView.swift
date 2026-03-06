import SwiftUI
import Combine

/// Content-sized entry listing with 300ms debounced search.
/// Uses VStack rows instead of Table so the outer ScrollView
/// in LedgerView controls all scrolling.
struct LedgerEntriesView: View {
    let sessionId: UUID
    let entries: [LedgerEntry]?
    let isLoading: Bool
    let ledgerSessionId: Int64?
    let onSearch: (String) -> Void
    let onClearSearch: () -> Void
    let scrollProxy: ScrollViewProxy

    @EnvironmentObject var sessionManager: SessionManager
    @Environment(\.chromeFontSize) private var chromeFontSize
    private var fontSize: ChromeFontSize { ChromeFontSize(chromeFontSize) }

    // Focus state for keyboard navigation
    @State private var focusedIndex: Int? = nil

    @State private var searchText: String = ""
    @State private var expandedEntryIds: Set<Int64> = []
    @State private var sortColumn: SortColumn = .importance
    @State private var sortAscending: Bool = true
    /// Incrementing counter — each bump triggers one focus request
    /// on the SafeSearchField via AppKit's makeFirstResponder.
    @State private var searchFocusTrigger: Int = 0

    /// Debounce publisher for search input
    @State private var searchSubject = PassthroughSubject<String, Never>()
    @State private var searchCancellable: AnyCancellable?

    enum SortColumn {
        case entryType, importance, source, content, category, created
    }

    private var sortedEntries: [LedgerEntry] {
        guard let entries = entries else { return [] }
        return entries.sorted { a, b in
            let result: Bool
            switch sortColumn {
            case .entryType:
                result = a.entryType < b.entryType
            case .importance:
                result = a.importance < b.importance
            case .source:
                result = (a.source ?? "") < (b.source ?? "")
            case .content:
                result = a.content < b.content
            case .category:
                result = (a.category ?? "") < (b.category ?? "")
            case .created:
                result = a.createdAt < b.createdAt
            }
            return sortAscending ? result : !result
        }
    }

    var body: some View {
        mainContent
            .onAppear {
                setupSearchDebounce()
                searchFocusTrigger += 1
            }
            .onChange(of: sessionManager.listNavAction) {
                guard sessionId == sessionManager.activeSessionId else { return }
                guard sessionManager.activeLedgerSubTab == .entries else { return }
                guard let action = sessionManager.listNavAction else { return }
                sessionManager.listNavAction = nil
                handleListNavAction(action)
            }
            .onChange(of: entries?.count) { handleEntriesCountChange() }
            .onChange(of: focusedIndex) { handleFocusedIndexChange() }
            .onChange(of: sessionManager.activeTab) { focusSearchIfActive() }
            .onChange(of: sessionManager.activeSessionId) { focusSearchIfActive() }
            .onChange(of: sessionManager.activeLedgerSubTab) { focusSearchIfActive() }
    }

    private func handleEntriesCountChange() {
        if let entries = entries, !entries.isEmpty {
            focusedIndex = 0
        } else {
            focusedIndex = nil
        }
    }

    private func handleFocusedIndexChange() {
        if let idx = focusedIndex, idx < sortedEntries.count {
            scrollProxy.scrollTo(sortedEntries[idx].id)
        }
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

            if !searchText.isEmpty, let entries = entries {
                Text("Showing \(entries.count) result\(entries.count == 1 ? "" : "s") for \"\(searchText)\"")
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
                Text(searchText.isEmpty
                     ? "No entries recorded for this session."
                     : "No entries matching \"\(searchText)\".")
                    .chromeFont(size: fontSize.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            } else if entries != nil {
                entriesContent
            }
        }
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
                text: $searchText,
                placeholder: "Search entries...",
                fontSize: fontSize.caption2,
                focusTrigger: searchFocusTrigger,
                isActive: isSearchActive,
                onTextChange: { searchSubject.send($0) },
                onSubmit: {
                    if searchText.isEmpty {
                        onClearSearch()
                    } else {
                        onSearch(searchText)
                    }
                }
            )
            if !searchText.isEmpty {
                Button(action: {
                    searchText = ""
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

    // MARK: - Entries Content

    private var entriesContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            headerRow

            // Data rows
            ForEach(Array(sortedEntries.enumerated()), id: \.element.id) { index, entry in
                entryRow(entry, index: index)
                    .id(entry.id)
            }
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 0) {
            sortableHeader("Type", column: .entryType, width: 120)
            sortableHeader("Importance", column: .importance, width: 100)
            sortableHeader("Source", column: .source, width: 70)
            sortableHeader("Content", column: .content, width: nil)
            sortableHeader("Category", column: .category, width: 100)
            sortableHeader("Created", column: .created, width: 140)
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
                sortAscending = true
            }
        }) {
            HStack(spacing: 3) {
                Text(title)
                    .chromeFont(size: fontSize.caption2, weight: .semibold)
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
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

    // MARK: - Data Row

    private func entryRow(_ entry: LedgerEntry, index: Int) -> some View {
        let isExpanded = expandedEntryIds.contains(entry.id)
        let isFocused = focusedIndex == index

        return HStack(alignment: .top, spacing: 0) {
            Text(entry.entryType)
                .chromeFontMono(size: fontSize.caption2)
                .frame(width: 120, alignment: .leading)

            Text(entry.importance)
                .chromeFontMono(size: fontSize.caption2)
                .foregroundColor(importanceColor(entry.importance))
                .frame(width: 100, alignment: .leading)

            Text(entry.source ?? "--")
                .chromeFontMono(size: fontSize.caption2)
                .foregroundColor(.secondary)
                .frame(width: 70, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(isExpanded ? entry.content : String(entry.content.prefix(100)))
                    .chromeFontMono(size: fontSize.caption2)
                    .lineLimit(isExpanded ? nil : 2)
                if entry.content.count > 100 {
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
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(entry.category ?? "--")
                .chromeFontMono(size: fontSize.caption2)
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .leading)

            Text(formatTimestamp(entry.createdAt))
                .chromeFontMono(size: fontSize.caption2)
                .frame(width: 140, alignment: .leading)
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

    // MARK: - List Focus Navigation

    private func handleListNavAction(_ action: ListNavAction) {
        let items = sortedEntries
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
            break  // No-op for entries
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
