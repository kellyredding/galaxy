import SwiftUI

/// Small clickable slot rendering the current emoji or an empty-
/// state outline. Click → opens the SwiftUI emoji picker popover
/// anchored to this button. Picker selection drives the bound
/// `emoji` value; the popover auto-dismisses on selection.
///
/// `preferredEdge` hints which side the popover should appear on.
/// NSPopover (which SwiftUI's `.popover` modifier wraps on macOS)
/// auto-flips when that edge would clip off-screen and slides
/// vertically to fit, so callers pass a sensible default (e.g.,
/// based on sidebar position) and the system handles the rest.
///
/// `onPopoverChange` lets the parent observe open/close transitions
/// — `SessionMarkerRow` uses this to manage its `isPickerShowing`
/// flag (which gates the blur-to-commit path) and to refocus the
/// inline name field after the popover closes.
struct EmojiSlotButton: View {
    @Binding var emoji: String

    /// Preferred popover arrow edge. `.leading` / `.trailing` for
    /// inline-edit cases (sidebar-position aware), `.top` for the
    /// new-marker modal.
    let preferredEdge: Edge

    /// Optional callback fired when the popover transitions
    /// open → closed or closed → open.
    var onPopoverChange: ((Bool) -> Void)? = nil

    @State private var isPresented: Bool = false

    private static let slotSize: CGFloat = 28

    var body: some View {
        Button(action: { isPresented = true }) {
            Group {
                if emoji.isEmpty {
                    // Dashed-square outline = clearly empty
                    // placeholder. Avoids using a real face/emoji
                    // glyph that could read as "this IS the
                    // current emoji".
                    Image(systemName: "square.dashed")
                        .font(.system(size: 18))
                        .foregroundColor(.secondary)
                } else {
                    Text(emoji)
                        .font(.system(size: 18))
                }
            }
            .frame(
                width: Self.slotSize, height: Self.slotSize
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(
            isPresented: $isPresented,
            arrowEdge: preferredEdge
        ) {
            EmojiPickerPopover(
                currentEmoji: emoji,
                onPick: { picked in
                    emoji = picked
                    isPresented = false
                }
            )
        }
        .onChange(of: isPresented) { _, newValue in
            onPopoverChange?(newValue)
        }
    }
}
