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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Marker name (optional)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)

                TextField(
                    "e.g. DONE, IN REVIEW, TODO",
                    text: $markerName
                )
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .name)
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
        SessionManager.shared.createMarker(name: markerName)
        onDismiss()
    }
}
