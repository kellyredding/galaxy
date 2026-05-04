import SwiftUI

/// Compact find bar shown above a searchable WKWebView.
///
/// Identical UI on every surface (scrollback overlay, snapshot
/// reader, every artifact reader) — the controller's `webView`
/// determines what's actually being searched. Hides itself by
/// binding to `controller.isVisible`; surrounding chrome decides
/// when to flip that flag (typically a Cmd+F dispatcher).
struct FindBarView: View {
    @ObservedObject var controller: WebViewFindController
    @FocusState private var fieldFocused: Bool
    @Environment(\.chromeFontSize) private var chromeFontSize

    private var fontSize: ChromeFontSize {
        ChromeFontSize(chromeFontSize)
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .chromeFont(size: fontSize.iconSmall)
                .foregroundColor(.secondary)

            TextField("Find", text: $controller.query)
                .textFieldStyle(.plain)
                .chromeFontMono(size: fontSize.caption)
                .focused($fieldFocused)
                .onSubmit { controller.next() }
                .frame(minWidth: 160)

            Text(matchLabel)
                .chromeFontMono(size: fontSize.caption2)
                .foregroundColor(.secondary)
                .frame(minWidth: 60, alignment: .trailing)

            Button(action: { controller.prev() }) {
                Image(systemName: "chevron.up")
                    .chromeFont(size: fontSize.iconSmall)
            }
            .buttonStyle(.plain)
            .disabled(controller.matchCount == 0)
            .help("Previous match (⇧↩)")

            Button(action: { controller.next() }) {
                Image(systemName: "chevron.down")
                    .chromeFont(size: fontSize.iconSmall)
            }
            .buttonStyle(.plain)
            .disabled(controller.matchCount == 0)
            .help("Next match (↩)")

            Button(action: { controller.isVisible = false }) {
                Image(systemName: "xmark")
                    .chromeFont(size: fontSize.iconSmall)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .help("Close find (Esc)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(NSColor.controlBackgroundColor))
                .shadow(radius: 4, y: 2)
        )
        .onAppear { fieldFocused = true }
        .onChange(of: controller.isVisible) { _, visible in
            if visible { fieldFocused = true }
        }
    }

    private var matchLabel: String {
        if controller.query.isEmpty { return "" }
        if controller.matchCount == 0 { return "No matches" }
        return "\(controller.matchIndex + 1) "
            + "of \(controller.matchCount)"
    }
}
