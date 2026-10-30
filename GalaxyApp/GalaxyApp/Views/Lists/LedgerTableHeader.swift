import SwiftUI

/// A column header for the ledger tables.
///
/// Shared by the two ledger sub-tabs, which had this written out twice,
/// identically, down to the byte. Deliberately not shared with the artifacts
/// or agents tables: those decide column widths in mutually incompatible ways,
/// and one header spanning them all would have to pick one and change how the
/// others look.
struct LedgerTableHeader: View {
    let title: String
    let width: CGFloat
    let isSorted: Bool
    let ascending: Bool
    let fontSize: ChromeFontSize
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 3) {
                Text(title)
                    .chromeFont(size: fontSize.caption2, weight: .semibold)
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                    .lineLimit(1)
                if isSorted {
                    Image(
                        systemName: ascending
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
}
