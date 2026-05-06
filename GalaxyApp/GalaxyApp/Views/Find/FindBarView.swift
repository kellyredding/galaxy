import AppKit
import SwiftUI

/// Compact find bar shown above a searchable WKWebView.
///
/// Identical UI on every surface (scrollback overlay, snapshot
/// reader, every artifact reader) — the controller's `webView`
/// determines what's actually being searched. Hides itself by
/// binding to `controller.isVisible`; surrounding chrome decides
/// when to flip that flag (typically a Cmd+F dispatcher).
///
/// Uses an AppKit-backed `FindTextFieldRepresentable` instead of
/// SwiftUI's `TextField` to avoid the latter's heavier cold-init
/// cost. The bar itself is hosted in a separate `NSPanel` (see
/// `FindBarPanel`) so AppKit's password-autofill heuristic walks
/// the panel's tiny view tree on first-responder transitions
/// instead of the parent window's full SwiftUI hierarchy.
struct FindBarView: View {
    @ObservedObject var controller: WebViewFindController
    @Environment(\.chromeFontSize) private var chromeFontSize

    private var fontSize: ChromeFontSize {
        ChromeFontSize(chromeFontSize)
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .chromeFont(size: fontSize.iconSmall)
                .foregroundColor(.secondary)

            FindTextFieldRepresentable(
                text: $controller.query,
                placeholder: "Find",
                font: NSFont.monospacedSystemFont(
                    ofSize: fontSize.caption,
                    weight: .regular
                ),
                textColor: .labelColor,
                onSubmit: { controller.next() },
                onShiftSubmit: { controller.prev() },
                onCancel: { controller.isVisible = false }
            )
            .frame(minWidth: 160)

            Text(matchLabel)
                .chromeFontMono(size: fontSize.caption2)
                .foregroundColor(.secondary)
                .frame(minWidth: 60, alignment: .trailing)

            Button(action: { controller.prev() }) {
                Image(systemName: "chevron.up")
                    .chromeFont(size: fontSize.iconSmall)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(controller.matchCount == 0)
            // ⇧↩ is also handled inside the text field's
            // doCommandBy: when focus is in the field. This
            // shortcut covers the case where focus has drifted
            // elsewhere (e.g., after a click outside).
            .keyboardShortcut(.return, modifiers: .shift)
            .help("Previous match (⇧↩)")

            Button(action: { controller.next() }) {
                Image(systemName: "chevron.down")
                    .chromeFont(size: fontSize.iconSmall)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(controller.matchCount == 0)
            .help("Next match (↩)")

            Button(action: { controller.isVisible = false }) {
                Image(systemName: "xmark")
                    .chromeFont(size: fontSize.iconSmall)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Tertiary fallback for Esc — text field handles it
            // first via cancelOperation:, AppKit-level Esc
            // monitors in the parent views (scrollback overlay,
            // artifact reader) handle it as belt-and-suspenders.
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
    }

    private var matchLabel: String {
        if controller.query.isEmpty { return "" }
        if controller.matchCount == 0 { return "No matches" }
        return "\(controller.matchIndex + 1) "
            + "of \(controller.matchCount)"
    }
}
