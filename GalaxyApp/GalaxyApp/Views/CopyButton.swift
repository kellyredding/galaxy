import SwiftUI
import AppKit

/// A reusable copy-to-clipboard button that shows a doc.on.doc icon,
/// animates to a green checkmark on success, and reverts after 2 seconds.
struct CopyButton: View {
    let text: String
    let iconSize: CGFloat

    @State private var showCopied = false

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

        withAnimation {
            showCopied = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                showCopied = false
            }
        }
    }
}
