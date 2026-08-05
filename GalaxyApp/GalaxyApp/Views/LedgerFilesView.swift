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

    /// Order and selection. The selection is an identity rather than a row
    /// number, so re-sorting cannot slide the highlight onto another file.
    @State private var model = ListSortModel<LedgerFile, SortColumn>(
        columns: LedgerFilesView.columns,
        sortColumn: .lastSeen,
        sortAscending: false)

    enum SortColumn {
        case ops, fileType, filePath, pattern, accesses, lastSeen
    }

    /// What each column is called and how it orders. A count or a timestamp
    /// opens at its largest, which is what a reader choosing that column is
    /// after; text opens at A.
    private static let columns: [ListColumn<LedgerFile, SortColumn>] = [
        .init(.ops, title: "Ops") {
            ListSorting.compareText(
                LedgerFilesView.opsString($0),
                LedgerFilesView.opsString($1))
        },
        .init(.fileType, title: "Type") {
            ListSorting.compareText($0.fileType, $1.fileType)
        },
        .init(.filePath, title: "File Path") {
            ListSorting.compareText($0.filePath, $1.filePath)
        },
        .init(.pattern, title: "Pattern") {
            ListSorting.compareText($0.searchPattern, $1.searchPattern)
        },
        .init(.accesses, title: "Accesses", prefersAscending: false) {
            ListSorting.compare($0.accessCount, $1.accessCount)
        },
        .init(.lastSeen, title: "Last Seen", prefersAscending: false) {
            ListSorting.compare($0.lastSeenAt ?? "", $1.lastSeenAt ?? "")
        },
    ]

    private var sortedFiles: [LedgerFile] { model.sorted(files) }

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
        .listNavigation(
            from: sessionManager,
            isActive: {
                sessionManager.activeTab == .ledger
                    && sessionManager.activeLedgerSubTab == .files
            },
            onAction: { action in
                switch action {
                case .up: model.move(.up, in: sortedFiles)
                case .down: model.move(.down, in: sortedFiles)
                case .activate: break  // Nothing to open on a file yet
                }
            })
        // Keyed on the rows themselves, not how many there are: a refresh
        // returning as many files as it replaced never fired at all.
        .onChange(of: files.map { $0.map(\.id) }) {
            model.reconcileFocus(in: sortedFiles, seed: .first)
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
            sortableHeader(.ops, width: Self.colOps)
            sortableHeader(.fileType, width: Self.colType)
            sortableHeader(.filePath, width: flexWidth)
            sortableHeader(.pattern, width: Self.colPattern)
            sortableHeader(.accesses, width: Self.colAccesses)
            sortableHeader(.lastSeen, width: Self.colLastSeen)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color.primary.opacity(0.05))
    }

    private func sortableHeader(_ column: SortColumn, width: CGFloat) -> some View {
        Button(action: { model.select(column) }) {
            HStack(spacing: 3) {
                Text(model.title(for: column))
                    .chromeFont(size: fontSize.caption2, weight: .semibold)
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                    .lineLimit(1)
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
    }

    // MARK: - Data Row

    private func fileRow(_ file: LedgerFile, index: Int, flexWidth: CGFloat) -> some View {
        let isFocused = model.focusedId == file.id

        return HStack(spacing: Self.colSpacing) {
            Text(Self.opsString(file))
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

            Text(file.lastSeenAt.map { ListTimestamp.format($0) } ?? "--")
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

    // MARK: - Helpers

    /// Static so the column table can reach it without an instance.
    static func opsString(_ file: LedgerFile) -> String {
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
}
