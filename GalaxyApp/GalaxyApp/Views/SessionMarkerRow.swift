import SwiftUI
import AppKit

/// Sidebar row for a SessionMarker. Renders the drag handle, two
/// flanking horizontal lines, and a centered cluster of (optional)
/// emoji + name. A hover X delete button overlays the right edge.
/// Height is fixed to match SessionRow exactly (see
/// ChromeFontSize.sidebarRowHeight) so the drag coordinator's
/// uniform-height math stays valid.
///
/// Markers are not selectable — single-click does nothing.
/// Double-click anywhere on the row body activates inline edit
/// mode, which makes BOTH the emoji slot and the name field
/// interactive together. Enter / blur commits both; Esc cancels
/// both.
struct SessionMarkerRow: View {
    @ObservedObject var marker: SessionMarker
    var onRemove: () -> Void

    // Drag-to-reorder support (mirrors SessionRow)
    let isPlaceholder: Bool
    let rowIndex: Int
    let showDragHandle: Bool
    let isDragging: Bool

    // `sidebarWidth` previously declared here was unused —
    // the marker row never read it, only inherited the
    // parameter from SessionRow's interface when the two
    // were kept symmetrical. Removed alongside the
    // SessionRow refactor that moved adaptive truncation
    // to ViewThatFits.

    @Environment(\.chromeFontSize) private var chromeFontSize
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    // Edit-mode state (renamed from isEditingName: edit mode now
    // covers BOTH the emoji slot and the name field together).
    @State private var isEditing = false
    @State private var editingNameText = ""
    @State private var editingEmoji = ""

    // Picker coordination — see B.0 in the implementation plan.
    // `isPickerShowing` gates onBlurAttemptCommit so the popover
    // stealing focus from the name field doesn't tear down edit
    // mode. `refocusToken` is bumped each time the popover closes
    // to re-mount InlineNameEditor (forcing makeFirstResponder to
    // run again) so the user can keep typing seamlessly.
    @State private var isPickerShowing = false
    @State private var refocusToken = 0

    /// Captures the emoji slot's window-coordinate frame so the
    /// inline editor's mouse-down monitor can whitelist clicks on
    /// the slot. Without the whitelist, clicking the slot would
    /// fire a forced-blur commit before the popover could open.
    @State private var emojiSlotAnchor = RowFrameAnchor()

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
    private static let trailingGap: CGFloat = 32

    /// Minimum width for the inline editor — ensures a clear edit
    /// target even when the field is empty.
    private static let minEditorWidth: CGFloat = 24

    /// Minimum width for each flanking horizontal line. Ensures
    /// the lines stay visible (and visually meaningful) even when
    /// the centered cluster takes up most of the row width.
    private static let flankLineMinWidth: CGFloat = 24

    /// Trailing padding for the inline editor's measured width —
    /// prevents the cursor from clipping at the right edge as the
    /// user types and keeps a small gap before the right-side line.
    private static let editorTrailingPad: CGFloat = 6

    /// Emoji glyph size used by all three marker surfaces:
    /// - SessionMarkerRow (expanded sidebar, static + edit)
    /// - CollapsedMarkerRow (collapsed sidebar)
    /// - CollapsedMarkerTooltip (hover tooltip from collapsed)
    ///
    /// Lives here as the canonical owner of the marker's row
    /// rendering. The collapsed surfaces reference this same
    /// constant so the glyph reads identically across all three
    /// — change here and all three move in lockstep. Not
    /// `private` so cross-file references resolve.
    static let emojiGlyphSize: CGFloat = 16

    /// Preferred popover edge for the emoji picker. Points away
    /// from the sidebar so the popover grows into open content
    /// area; NSPopover auto-flips if the preferred edge would
    /// clip off-screen.
    private var pickerArrowEdge: Edge {
        switch SettingsManager.shared.settings.sidebarPosition {
        case .left:  return .leading
        case .right: return .trailing
        }
    }

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

            // Flanking-lines + LEFT-justified cluster band. The
            // left line is fixed at the minimum width; the
            // cluster sits immediately to its right; the right
            // line takes all remaining space and shrinks first
            // when the cluster grows. Sidebar-position-agnostic
            // by design — this layout reads the same whether the
            // sidebar is on the left or the right of the window.
            HStack(spacing: 6) {
                Rectangle()
                    .fill(lineColor)
                    .frame(
                        width: Self.flankLineMinWidth, height: 1
                    )

                if isEditing {
                    editingCenterCluster
                } else {
                    staticCenterCluster
                }

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
            // line near (but not on) the existing text/emoji.
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                if !isEditing { beginEdit() }
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

    // MARK: - Center cluster (static)

    /// Static (non-edit) cluster: emoji (if set) followed by name
    /// (if set). When both are empty, the cluster contributes
    /// zero width and the flanking lines meet in the middle.
    ///
    /// `.layoutPriority(1)` on the outer HStack tells the parent
    /// flank-line band to give this cluster its intrinsic width
    /// FIRST, then split the remainder between the flexible
    /// flanking rectangles. Without this, the rectangles' greedy
    /// `maxWidth: .infinity` competes with the text and forces
    /// truncation on names like "IN REVIEW" or "BACKLOG" that
    /// would otherwise fit.
    @ViewBuilder
    private var staticCenterCluster: some View {
        HStack(spacing: 4) {
            if !marker.emoji.isEmpty {
                Text(marker.emoji)
                    .font(.system(size: Self.emojiGlyphSize))
            }
            if !marker.name.isEmpty {
                Text(marker.name)
                    .chromeFont(
                        size: fontSize.caption1, weight: .bold
                    )
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundColor(lineColor)
            }
        }
        .layoutPriority(1)
    }

    // MARK: - Center cluster (edit mode)

    /// Edit-mode cluster: clickable emoji slot + inline name
    /// editor. The slot's window-coord frame is captured into
    /// `emojiSlotAnchor` so the editor's mouse-down monitor can
    /// whitelist clicks on it (otherwise the click would force
    /// blur + commit before the popover could open). The
    /// `isPickerShowing` flag set by the slot's
    /// `onPopoverChange` callback ALSO guards the post-popover
    /// blur path — both layers are needed (see B.0 in the plan).
    @ViewBuilder
    private var editingCenterCluster: some View {
        HStack(spacing: 4) {
            EmojiSlotButton(
                emoji: $editingEmoji,
                preferredEdge: pickerArrowEdge,
                onPopoverChange: { isOpen in
                    isPickerShowing = isOpen
                    if !isOpen {
                        // Popover closed — re-mount the inline
                        // editor so it reclaims first responder
                        // and the user can keep typing.
                        refocusToken &+= 1
                    }
                }
            )
            .background(FrameAnchorView(anchor: emojiSlotAnchor))

            // Live-measured editor width matches Slice A behavior.
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
                onCommit: { commitEdit() },
                onCancel: { cancelEdit() },
                onBlur: { onBlurAttemptCommit() },
                // Whitelist the emoji slot frame so clicks on it
                // don't trigger the monitor's forced-blur path.
                // The popover-takes-focus blur is still gated by
                // isPickerShowing inside onBlurAttemptCommit —
                // both layers are needed (different code paths).
                isClickInsideEditingSurface: { point in
                    emojiSlotAnchor.currentWindowFrame()?
                        .contains(point) ?? false
                }
            )
            .id(refocusToken)  // Re-mount forces makeFirstResponder
                               // to fire again after picker closes.
            .frame(
                width: editorWidth,
                height: fontSize.caption1LineHeight
            )
        }
        // Same priority hint as the static cluster — the
        // slot+editor combo gets intrinsic width first; lines
        // around it fill the leftover.
        .layoutPriority(1)
    }

    // MARK: - Edit lifecycle

    /// Enter edit mode. Seeds the editing buffers from the marker's
    /// current values so Esc can revert to them.
    private func beginEdit() {
        editingNameText = marker.name
        editingEmoji = marker.emoji
        isEditing = true
    }

    /// Commit both name and emoji edits. Allows empty values:
    /// empty name → marker collapses to just lines + emoji (or
    /// just lines if emoji is also empty); empty emoji → marker
    /// renders without a leading glyph.
    private func commitEdit() {
        marker.name = editingNameText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        marker.emoji = editingEmoji
        SessionPersistence.shared.markDirty()
        isEditing = false
        isPickerShowing = false
    }

    /// Discard both edits and exit edit mode.
    private func cancelEdit() {
        isEditing = false
        isPickerShowing = false
    }

    /// Called by InlineNameEditor when the field loses first
    /// responder for any reason other than Enter/Esc — i.e.
    /// click-outside, app deactivation, popover-takes-focus.
    ///
    /// Skip the commit while the picker is up: the focus loss in
    /// that case is the popover stealing focus, NOT a true
    /// click-outside. Committing here would tear down edit mode
    /// before the user has finished picking. The picker's close
    /// callback bumps `refocusToken` so the field re-claims
    /// first responder afterward.
    private func onBlurAttemptCommit() {
        if isPickerShowing { return }
        commitEdit()
    }
}

// MARK: - Equatable conformance

/// Same rationale as `SessionRow`'s extension — short-circuit
/// SwiftUI body re-evals on parent invalidations when the
/// marker's own visible inputs haven't changed. `onRemove`
/// is excluded from the comparison; it's a closure
/// recreated on every parent eval but captures only stable
/// values.
extension SessionMarkerRow: Equatable {
    static func == (
        lhs: SessionMarkerRow,
        rhs: SessionMarkerRow
    ) -> Bool {
        lhs.marker === rhs.marker
            && lhs.isPlaceholder == rhs.isPlaceholder
            && lhs.rowIndex == rhs.rowIndex
            && lhs.showDragHandle == rhs.showDragHandle
            && lhs.isDragging == rhs.isDragging
    }
}
