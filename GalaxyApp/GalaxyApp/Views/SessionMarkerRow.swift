import SwiftUI
import AppKit

/// Sidebar row for a SessionMarker. Renders the drag handle, two
/// flanking horizontal lines, a centered name (optional), and a
/// hover X delete button. Height is fixed to match SessionRow
/// exactly (see ChromeFontSize.sidebarRowHeight) so the drag
/// coordinator's uniform-height math stays valid.
///
/// Markers are not selectable — single-click does nothing.
/// Double-click anywhere on the row body activates inline rename.
struct SessionMarkerRow: View {
    @ObservedObject var marker: SessionMarker
    var onRemove: () -> Void

    // Drag-to-reorder support (mirrors SessionRow)
    let isPlaceholder: Bool
    let rowIndex: Int
    let showDragHandle: Bool
    let isDragging: Bool

    let sidebarWidth: CGFloat

    @Environment(\.chromeFontSize) private var chromeFontSize
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false
    @State private var isEditingName = false
    @State private var editingNameText = ""

    private var fontSize: ChromeFontSize {
        ChromeFontSize(chromeFontSize)
    }

    /// Lines and name share the same color so the marker reads as
    /// a single decorative element. `.primary` tracks light/dark
    /// theme automatically. Markers have no selection state, so
    /// there's no "selected" branch.
    private var lineColor: Color { .primary }

    private var rowHeight: CGFloat { fontSize.sidebarRowHeight }

    /// Right-side gap reserves room for the floating hover X.
    /// Pulled to a constant so future tweaks live in one place.
    private static let trailingGap: CGFloat = 32

    /// Minimum width for the inline editor — ensures a clear edit
    /// target even when the field is empty.
    private static let minEditorWidth: CGFloat = 24

    /// Minimum width for each flanking horizontal line. Ensures
    /// the lines stay visible (and visually meaningful) even when
    /// the centered name truncates to fit the sidebar — without
    /// this floor, layoutPriority on the Text starves the lines
    /// to ~0pt and the marker's "section header" silhouette
    /// disappears.
    private static let flankLineMinWidth: CGFloat = 24

    /// Trailing padding for the inline editor's measured width —
    /// prevents the cursor from clipping at the right edge as the
    /// user types and keeps a small gap before the right-side line.
    private static let editorTrailingPad: CGFloat = 6

    /// Measure the visual width of `text` rendered in the marker
    /// name's bold system font at the given size. Used by the
    /// inline editor to grow with content.
    private static func measureTextWidth(
        _ text: String,
        fontSize: CGFloat
    ) -> CGFloat {
        let font = NSFont.systemFont(
            ofSize: fontSize, weight: .bold
        )
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        return (text as NSString).size(
            withAttributes: attrs
        ).width
    }

    var body: some View {
        HStack(spacing: 6) {
            // Drag handle (mirrors SessionRow exactly)
            if showDragHandle {
                SessionRowDragHandle(
                    itemId: marker.id,
                    itemIndex: rowIndex
                )
                .frame(width: 18, height: 32)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }

            // Flanking-lines + centered-name band. The two lines
            // run through the vertical center of the text. When
            // there's no name (or the user is editing an empty
            // name), the two lines meet in the middle.
            HStack(spacing: 6) {
                Rectangle()
                    .fill(lineColor)
                    .frame(height: 1)
                    .frame(
                        minWidth: Self.flankLineMinWidth,
                        maxWidth: .infinity
                    )

                if isEditingName {
                    // Width is measured here rather than relying
                    // on the editor's intrinsicContentSize.
                    // InlineNameEditor sets `cell.isScrollable = true`
                    // (needed by SessionRow), which makes the field's
                    // intrinsic width collapse to ~1 character. We
                    // measure the live text width and apply an
                    // explicit .frame(width:) so the editor grows
                    // as the user types.
                    let measured = Self.measureTextWidth(
                        editingNameText,
                        fontSize: fontSize.caption1
                    )
                    let editorWidth = max(
                        Self.minEditorWidth,
                        measured + Self.editorTrailingPad
                    )

                    InlineNameEditor(
                        text: $editingNameText,
                        fontSize: fontSize.caption1,
                        fontWeight: .bold,
                        textColor: .labelColor,
                        onCommit: { commitNameEdit() },
                        onCancel: { cancelNameEdit() },
                        // Click-outside / app-deactivate → commit.
                        // Slice B will extend the helper with an
                        // `isPickerShowing` guard so picker-induced
                        // blur doesn't terminate edit mode.
                        onBlur: { onBlurAttemptCommit() }
                    )
                    .frame(
                        width: editorWidth,
                        height: fontSize.caption1LineHeight
                    )
                } else if !marker.name.isEmpty {
                    Text(marker.name)
                        .chromeFont(
                            size: fontSize.caption1,
                            weight: .bold
                        )
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundColor(lineColor)
                        .layoutPriority(1)
                }
                // When name is empty AND not editing, no center
                // view is laid out → the two Rectangles meet in
                // the middle.

                Rectangle()
                    .fill(lineColor)
                    .frame(height: 1)
                    .frame(
                        minWidth: Self.flankLineMinWidth,
                        maxWidth: .infinity
                    )
            }
            // Whole-band double-click — covers both the empty-line
            // case and the case where the user double-clicks on a
            // line near (but not on) the existing text.
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                if !isEditingName { beginNameEdit() }
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, Self.trailingGap)
        .frame(height: rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .opacity(isPlaceholder ? 0 : 1)
        .background(
            isPlaceholder
                ? Color(NSColor.windowBackgroundColor)
                : Color.clear
        )
        .overlay(alignment: .bottom) {
            // Match session-row separator for visual consistency.
            Rectangle()
                .fill(Color.primary.opacity(0.15))
                .frame(height: 1)
        }
        .overlay(alignment: .trailing) {
            // Hover X delete — mirrors SessionRow's pattern.
            // Suppressed during drag.
            if isHovered && !isDragging {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 18))
                }
                .buttonStyle(.plain)
                .help("Remove marker")
                .transition(.opacity)
                .padding(.trailing, 2)
            }
        }
        .onHover { hovering in
            // Ignore hover during drag — prevents stale states on
            // rows the dragged item passes over.
            guard !isDragging else { return }
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .onChange(of: isDragging) { oldValue, newValue in
            if newValue && !isPlaceholder {
                // Drag started: clear hover on non-dragged rows
                isHovered = false
            } else if oldValue && !newValue && isPlaceholder {
                // Drag ended: this was the dragged row, mouse
                // is likely still over it
                isHovered = true
            }
        }
    }

    // MARK: - Name Editing

    private func beginNameEdit() {
        editingNameText = marker.name
        isEditingName = true
    }

    private func commitNameEdit() {
        // Allow empty: marker collapses to just the lines.
        marker.name = editingNameText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        SessionPersistence.shared.markDirty()
        isEditingName = false
    }

    private func cancelNameEdit() {
        isEditingName = false
    }

    /// Called by InlineNameEditor when the field loses first
    /// responder for any reason other than Enter/Esc — i.e.
    /// click-outside, app deactivation, programmatic focus shift.
    ///
    /// Slice A: always commit (mirrors SessionRow's behavior).
    /// Slice B will extend this with an `isPickerShowing` guard so
    /// the emoji picker stealing focus doesn't tear down edit mode
    /// behind the user's back.
    private func onBlurAttemptCommit() {
        commitNameEdit()
    }
}
