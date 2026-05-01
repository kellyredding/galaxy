import SwiftUI
import AppKit

/// SwiftUI popover content for selecting a marker emoji. Reports
/// selection via `onPick` (passing "" to mean "remove emoji").
/// The popover's open/close state lives in the parent — this view
/// only renders content. Selection auto-dismisses by clearing the
/// parent's `isPresented` binding, which the parent observes via
/// the `EmojiSlotButton`'s `onPopoverChange` callback.
struct EmojiPickerPopover: View {
    /// Currently-set emoji ("" if none). Drives whether the
    /// "Remove emoji" affordance is shown — only visible when
    /// the marker (or modal) actually has an emoji to remove.
    let currentEmoji: String

    /// Callback fired when the user picks an emoji or chooses
    /// "Remove emoji". Empty string means "remove".
    let onPick: (String) -> Void

    @State private var query: String = ""

    private static let popoverWidth: CGFloat = 300
    private static let popoverHeight: CGFloat = 360

    /// Grid columns sized for ~30pt emoji buttons.
    private let columns = [
        GridItem(.adaptive(minimum: 30), spacing: 4)
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Search bar — backed by AppKit's NSTextField via
            // AutoFocusSearchField rather than SwiftUI's TextField
            // + @FocusState, because the popover may be presented
            // over an NSApp.runModal session (the new-marker
            // modal). During a modal session, no other window can
            // become key, and SwiftUI's @FocusState relies on the
            // popover's window being key for its focus binding to
            // translate into makeFirstResponder. The AppKit-direct
            // approach calls makeFirstResponder on the popover's
            // own window regardless of key status, which works
            // both from the sidebar and from the modal.
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                AutoFocusSearchField(
                    text: $query,
                    placeholder: "Search emoji…"
                )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Remove-emoji affordance — only when the
                    // current marker has an emoji set. Hidden in
                    // the new-marker modal where emoji is empty
                    // by definition.
                    if !currentEmoji.isEmpty {
                        removeRow
                        Divider()
                    }

                    let groups = EmojiPickerData.filtered(by: query)
                    if groups.isEmpty {
                        Text("No matches")
                            .foregroundColor(.secondary)
                            .padding(.vertical, 20)
                            .frame(maxWidth: .infinity)
                    } else {
                        ForEach(groups, id: \.0) { (category, entries) in
                            categorySection(category, entries)
                        }
                    }
                }
                .padding(10)
            }
        }
        .frame(
            width: Self.popoverWidth,
            height: Self.popoverHeight
        )
    }

    private var removeRow: some View {
        Button(action: { onPick("") }) {
            HStack(spacing: 8) {
                Image(systemName: "square.dashed")
                    .foregroundColor(.secondary)
                Text("Remove emoji")
                    .foregroundColor(.primary)
                Spacer()
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func categorySection(
        _ category: EmojiCategory,
        _ entries: [EmojiEntry]
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(category.rawValue.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(entries) { entry in
                    Button(action: { onPick(entry.emoji) }) {
                        Text(entry.emoji)
                            .font(.system(size: 22))
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(entry.keywords.first ?? entry.emoji)
                }
            }
        }
    }
}

// MARK: - AutoFocusSearchField

/// `NSViewRepresentable` wrapping a borderless `NSTextField` that
/// claims first responder on appear via AppKit-direct
/// `makeFirstResponder`. Replaces SwiftUI's `TextField` +
/// `@FocusState` for the picker's search input because that
/// SwiftUI focus mechanism doesn't reliably translate to first
/// responder when the hosting popover is presented over an
/// `NSApp.runModal` session (the new-marker modal). The AppKit
/// path doesn't require the popover's window to be key, which
/// matters because `runModal` blocks key-window transitions.
///
/// Private to this file — the only consumer is
/// `EmojiPickerPopover`. If another caller needs the same
/// behavior later, promote to a shared file at that point.
private struct AutoFocusSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = placeholder
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.cell?.usesSingleLineMode = true
        field.delegate = context.coordinator
        // Defer to next runloop tick so the popover's hosting
        // view is fully attached to its window before we ask
        // for first responder. makeFirstResponder works on any
        // window regardless of key/main status — that's why
        // this works in the modal-popover case where SwiftUI's
        // @FocusState does not.
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
        }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        // Only update text if it differs (avoid clobbering the
        // user's cursor position while typing).
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AutoFocusSearchField

        init(_ parent: AutoFocusSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField
            else { return }
            parent.text = field.stringValue
        }
    }
}
