import SwiftUI

/// Modal sheet for creating a new sidebar marker.
/// Single optional name field — empty submission is allowed and
/// produces a "lines-only" marker that the user can name later
/// via inline rename.
struct NewMarkerView: View {
    /// Callback to dismiss the window.
    let onDismiss: () -> Void

    enum FocusField: Hashable { case name, create }
    @FocusState private var focusedField: FocusField?

    @State private var markerName: String = ""
    @State private var markerEmoji: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Marker name (optional)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)

                HStack(spacing: 8) {
                    EmojiSlotButton(
                        emoji: $markerEmoji,
                        preferredEdge: .top
                    )
                    .frame(width: 32, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(NSColor.controlBackgroundColor))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(
                                        Color(NSColor.separatorColor),
                                        lineWidth: 0.5
                                    )
                            )
                    )

                    TextField(
                        "e.g. DONE, IN REVIEW, TODO",
                        text: $markerName
                    )
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .name)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .focusable()
                    .focused($focusedField, equals: .create)
            }
        }
        .padding(20)
        .frame(width: 380)
        .defaultFocus($focusedField, .name)
    }

    private func submit() {
        SessionManager.shared.createMarker(
            name: markerName, emoji: markerEmoji
        )
        onDismiss()
    }
}
