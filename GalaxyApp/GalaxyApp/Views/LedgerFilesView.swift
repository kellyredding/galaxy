import SwiftUI

/// Content-sized file listing for a ledger session.
/// Owns its own vertical ScrollView so the metadata header
/// and subtab picker stay fixed while the table scrolls.
struct LedgerFilesView: View {
    let files: [LedgerFile]?
    let isLoading: Bool

    @EnvironmentObject var sessionManager: SessionManager
    @Environment(\.chromeFontSize) private var chromeFontSize
    private var fontSize: ChromeFontSize { ChromeFontSize(chromeFontSize) }

    // Focus state for keyboard navigation
    @State private var focusedIndex: Int? = nil

    @State private var sortColumn: SortColumn = .lastSeen
    @State private var sortAscending: Bool = false

    enum SortColumn {
        case ops, fileType, filePath, pattern, accesses, lastSeen
    }

    private var sortedFiles: [LedgerFile] {
        guard let files = files else { return [] }
        return files.sorted { a, b in
            let result: Bool
            switch sortColumn {
            case .ops:
                result = opsString(a) < opsString(b)
            case .fileType:
                result = a.fileType < b.fileType
            case .filePath:
                result = a.filePath < b.filePath
            case .pattern:
                result = a.searchPattern < b.searchPattern
            case .accesses:
                result = a.accessCount < b.accessCount
            case .lastSeen:
                result = (a.lastSeenAt ?? "") < (b.lastSeenAt ?? "")
            }
            return sortAscending ? result : !result
        }
    }

    var body: some View {
        Group {
            if isLoading && files == nil {
                HStack {
                    Spacer()
                    ProgressView()
                        .scaleEffect(0.8)
                        .padding()
                    Spacer()
                }
            } else if let files = files, files.isEmpty {
                emptyState
            } else if files != nil {
                filesTable
            } else {
                // No ledger session yet or fetch never started
                emptyState
            }
        }
        .onChange(of: sessionManager.listNavAction) {
            guard sessionManager.activeLedgerSubTab == .files else { return }
            guard let action = sessionManager.listNavAction else { return }
            sessionManager.listNavAction = nil
            handleListNavAction(action)
        }
        .onChange(of: files?.count) {
            if let files = files, !files.isEmpty {
                focusedIndex = 0
            } else {
                focusedIndex = nil
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text")
                .chromeFont(size: fontSize.iconLarge)
                .foregroundColor(.secondary)
            Text("No files")
                .chromeFont(size: fontSize.title2)
                .foregroundColor(.primary)
            Text("Files appear as the session reads, edits, and writes")
                .chromeFont(size: fontSize.body)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Table Layout

    /// Fixed column widths — File Path is the flex column.
    private static let colOps: CGFloat = 50
    private static let colType: CGFloat = 80
    private static let colPattern: CGFloat = 120
    private static let colAccesses: CGFloat = 70
    private static let colLastSeen: CGFloat = 140
    private static let colSpacing: CGFloat = 8
    private static let rowPadding: CGFloat = 16  // 8 each side
    /// Sum of fixed columns + inter-column gaps (5 gaps for 6 columns) + row padding
    private static let fixedTotal: CGFloat =
        colOps + colType + colPattern + colAccesses + colLastSeen
        + (colSpacing * 5) + rowPadding
    private static let flexMin: CGFloat = 300

    private var filesTable: some View {
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
                                    sortedFiles
                                        .enumerated()
                                ),
                                id: \.element.id
                            ) { index, file in
                                fileRow(
                                    file,
                                    index: index,
                                    flexWidth: flexWidth
                                )
                                .id(file.id)
                            }
                        }
                        .frame(width: tableWidth)
                    }
                }
                .onChange(of: focusedIndex) {
                    if let idx = focusedIndex,
                       idx < sortedFiles.count
                    {
                        scrollProxy.scrollTo(
                            sortedFiles[idx].id
                        )
                    }
                }
            }
        }
    }

    // MARK: - Header

    private func headerRow(flexWidth: CGFloat) -> some View {
        HStack(spacing: Self.colSpacing) {
            sortableHeader("Ops", column: .ops, width: Self.colOps)
            sortableHeader("Type", column: .fileType, width: Self.colType)
            sortableHeader("File Path", column: .filePath, width: flexWidth)
            sortableHeader("Pattern", column: .pattern, width: Self.colPattern)
            sortableHeader("Accesses", column: .accesses, width: Self.colAccesses)
            sortableHeader("Last Seen", column: .lastSeen, width: Self.colLastSeen)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color.primary.opacity(0.05))
    }

    private func sortableHeader(_ title: String, column: SortColumn, width: CGFloat) -> some View {
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
                    .lineLimit(1)
                if sortColumn == column {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(width: width, alignment: .leading)
    }

    // MARK: - Data Row

    private func fileRow(_ file: LedgerFile, index: Int, flexWidth: CGFloat) -> some View {
        let isFocused = focusedIndex == index

        return HStack(spacing: Self.colSpacing) {
            Text(opsString(file))
                .chromeFontMono(size: fontSize.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .frame(width: Self.colOps, alignment: .leading)

            Text(file.fileType)
                .chromeFontMono(size: fontSize.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: Self.colType, alignment: .leading)

            Text(abbreviatePath(file.filePath))
                .chromeFontMono(size: fontSize.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(file.filePath)
                .frame(width: flexWidth, alignment: .leading)

            Text(file.searchPattern.isEmpty ? "" : file.searchPattern)
                .chromeFontMono(size: fontSize.caption2)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundColor(.secondary)
                .frame(width: Self.colPattern, alignment: .leading)

            Text(verbatim: "\(file.accessCount)")
                .chromeFontMono(size: fontSize.caption2)
                .lineLimit(1)
                .frame(width: Self.colAccesses, alignment: .leading)

            Text(file.lastSeenAt.map { formatTimestamp($0) } ?? "--")
                .chromeFontMono(size: fontSize.caption2)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: Self.colLastSeen, alignment: .leading)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .background(
            isFocused
                ? Color.accentColor.opacity(0.15)
                : (index % 2 == 1 ? Color.primary.opacity(0.03) : Color.clear)
        )
    }

    // MARK: - List Focus Navigation

    private func handleListNavAction(_ action: ListNavAction) {
        let items = sortedFiles
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
            break  // No-op for files
        }
    }

    // MARK: - Helpers

    private func opsString(_ file: LedgerFile) -> String {
        var ops: [String] = []
        if file.isRead { ops.append("R") }
        if file.isEdited { ops.append("E") }
        if file.isWritten { ops.append("W") }
        if file.isSearched { ops.append("S") }
        return ops.joined(separator: " ")
    }

    private func abbreviatePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
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
