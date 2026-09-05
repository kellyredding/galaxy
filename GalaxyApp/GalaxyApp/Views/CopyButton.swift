import SwiftUI
import AppKit

/// A reusable copy-to-clipboard button that shows a doc.on.doc icon,
/// animates to a green checkmark on success, and reverts after 2 seconds.
struct CopyButton: View {
    let text: String
    let iconSize: CGFloat

    @State private var showCopied = false

    /// Which press the pending reset belongs to.
    ///
    /// Pressing again inside the two seconds used to leave two resets in
    /// flight, and the first of them cleared the check the second press had
    /// just put up — so the confirmation vanished early on exactly the press
    /// that repeated because the first one was not believed.
    @State private var confirmToken = 0

    var body: some View {
        Button(action: copyText) {
            Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                .chromeFont(size: iconSize)
                .foregroundColor(showCopied ? .green : .secondary)
        }
        .buttonStyle(.plain)
        .help("Copy to clipboard")
    }

    private func copyText() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        confirmToken += 1
        let token = confirmToken
        withAnimation {
            showCopied = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard token == confirmToken else { return }
            withAnimation {
                showCopied = false
            }
        }
    }
}
