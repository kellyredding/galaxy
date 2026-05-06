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
/// SwiftUI's `TextField` to avoid the ~3-second cold-init cost
/// SwiftUI's text field pays the first time it gets focus. See
/// the doc-comment on `FindTextFieldRepresentable` for the
/// detailed rationale.
struct FindBarView: View {
    @ObservedObject var controller: WebViewFindController
    @State private var fieldFocused: Bool = false
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
                focused: $fieldFocused,
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
        // The bar is kept always-attached in reader views
        // (opacity-toggled), so onAppear fires when the reader
        // opens — not when find opens. Gate by visibility so
        // we don't steal focus from the reader's own initial
        // first responder.
        .onAppear {
            if controller.isVisible { fieldFocused = true }
        }
        .onChange(of: controller.isVisible) { _, visible in
            // Mirror visibility into the focus binding both
            // directions: opening claims focus, closing yields
            // it. The representable handles the
            // makeFirstResponder dispatch off the binding.
            fieldFocused = visible
        }
    }

    private var matchLabel: String {
        if controller.query.isEmpty { return "" }
        if controller.matchCount == 0 { return "No matches" }
        return "\(controller.matchIndex + 1) "
            + "of \(controller.matchCount)"
    }
}
