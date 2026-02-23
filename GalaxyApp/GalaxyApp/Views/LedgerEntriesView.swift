import SwiftUI
import Combine

/// Content-sized entry listing with 300ms debounced search.
/// Uses VStack rows instead of Table so the outer ScrollView
/// in LedgerView controls all scrolling.
struct LedgerEntriesView: View {
    let entries: [LedgerEntry]?
    let isLoading: Bool
    let ledgerSessionId: Int64?
    let onSearch: (String) -> Void
    let onClearSearch: () -> Void

    @Environment(\.chromeFontSize) private var chromeFontSize
    private var fontSize: ChromeFontSize { ChromeFontSize(chromeFontSize) }

    @State private var searchText: String = ""
    @State private var expandedEntryIds: Set<Int64> = []
    @State private var sortColumn: SortColumn = .importance
    @State private var sortAscending: Bool = true
    @FocusState private var isSearchFocused: Bool

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
        VStack(alignment: .leading, spacing: 8) {
            // Search bar
            searchBar

            // Results indicator
            if !searchText.isEmpty, let entries = entries {
                Text("Showing \(entries.count) result\(entries.count == 1 ? "" : "s") for \"\(searchText)\"")
                    .chromeFont(size: fontSize.caption2)
                    .foregroundColor(.secondary)
            }

            // Content
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
        .onAppear {
            setupSearchDebounce()
            isSearchFocused = true
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.system(size: 12))
            TextField("Search entries...", text: $searchText)
                .textFieldStyle(.plain)
                .chromeFont(size: fontSize.caption2)
                .focused($isSearchFocused)
                .onChange(of: searchText) {
                    if searchText.isEmpty {
                        searchSubject.send("")
                    } else {
                        searchSubject.send(searchText)
                    }
                }
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
                entryRow(entry, isAlternate: index % 2 == 1)
            }
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 0) {
            sortableHeader("Type", column: .entryType, width: 120)
            sortableHeader("Importance", column: .importance, width: 80)
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

    private func entryRow(_ entry: LedgerEntry, isAlternate: Bool) -> some View {
        let isExpanded = expandedEntryIds.contains(entry.id)

        return HStack(alignment: .top, spacing: 0) {
            Text(entry.entryType)
                .chromeFontMono(size: fontSize.caption2)
                .frame(width: 120, alignment: .leading)

            Text(entry.importance)
                .chromeFontMono(size: fontSize.caption2)
                .foregroundColor(importanceColor(entry.importance))
                .frame(width: 80, alignment: .leading)

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
        .background(isAlternate ? Color.primary.opacity(0.03) : Color.clear)
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
