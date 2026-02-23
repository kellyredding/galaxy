import SwiftUI

/// Content-sized file listing for a ledger session.
/// Uses VStack rows instead of Table so the outer ScrollView
/// in LedgerView controls all scrolling.
struct LedgerFilesView: View {
    let files: [LedgerFile]?
    let isLoading: Bool

    @Environment(\.chromeFontSize) private var chromeFontSize
    private var fontSize: ChromeFontSize { ChromeFontSize(chromeFontSize) }

    @State private var sortColumn: SortColumn = .lastSeen
    @State private var sortAscending: Bool = false

    enum SortColumn {
        case ops, filePath, pattern, accesses, lastSeen
    }

    private var sortedFiles: [LedgerFile] {
        guard let files = files else { return [] }
        return files.sorted { a, b in
            let result: Bool
            switch sortColumn {
            case .ops:
                result = opsString(a) < opsString(b)
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
        if isLoading && files == nil {
            HStack {
                Spacer()
                ProgressView()
                    .scaleEffect(0.8)
                    .padding()
                Spacer()
            }
        } else if let files = files, files.isEmpty {
            Text("No files recorded for this session.")
                .chromeFont(size: fontSize.caption)
                .foregroundColor(.secondary)
                .padding(.vertical, 8)
        } else if files != nil {
            VStack(alignment: .leading, spacing: 0) {
                // Header row
                headerRow

                // Data rows
                ForEach(Array(sortedFiles.enumerated()), id: \.element.id) { index, file in
                    fileRow(file, isAlternate: index % 2 == 1)
                }
            }
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 0) {
            sortableHeader("Ops", column: .ops, width: 50)
            sortableHeader("File Path", column: .filePath, width: nil)
            sortableHeader("Pattern", column: .pattern, width: 120)
            sortableHeader("Accesses", column: .accesses, width: 70)
            sortableHeader("Last Seen", column: .lastSeen, width: 140)
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

    private func fileRow(_ file: LedgerFile, isAlternate: Bool) -> some View {
        HStack(spacing: 0) {
            Text(opsString(file))
                .chromeFontMono(size: fontSize.caption2)
                .foregroundColor(.secondary)
                .frame(width: 50, alignment: .leading)

            Text(abbreviatePath(file.filePath))
                .chromeFontMono(size: fontSize.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(file.filePath)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(file.searchPattern.isEmpty ? "" : file.searchPattern)
                .chromeFontMono(size: fontSize.caption2)
                .lineLimit(1)
                .foregroundColor(.secondary)
                .frame(width: 120, alignment: .leading)

            Text(verbatim: "\(file.accessCount)")
                .chromeFontMono(size: fontSize.caption2)
                .frame(width: 70, alignment: .leading)

            Text(file.lastSeenAt.map { formatTimestamp($0) } ?? "--")
                .chromeFontMono(size: fontSize.caption2)
                .frame(width: 140, alignment: .leading)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .background(isAlternate ? Color.primary.opacity(0.03) : Color.clear)
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
