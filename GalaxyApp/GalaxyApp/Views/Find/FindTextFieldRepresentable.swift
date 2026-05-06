import AppKit
import SwiftUI

/// Bridges an `NSTextField` into SwiftUI for the find bar.
///
/// **Why an AppKit text field, not SwiftUI's `TextField`?**
/// SwiftUI's TextField bridges through `_SystemTextFieldFieldEditor`,
/// a private subclass of NSTextView that lazily initializes a heavy
/// stack of macOS subsystems on first focus per instance —
/// TextKit, NSSpellChecker dictionaries, NSTextInputContext, Touch
/// Bar candidate-list, system text replacements, etc. Measured
/// ~3 seconds of blocked main thread on first Cmd+F per artifact
/// reader / scrollback overlay.
///
/// `NSTextField` uses a much cheaper code path (the shared NSTextView
/// field editor on NSWindow) which we additionally pre-warm at app
/// launch via `TextInputWarmup`. Empirically that brings first-time
/// focus from ~3000ms down to <50ms.
///
/// The bridge is intentionally narrow — single-line plain text, two
/// keyboard shortcuts (Enter / Shift+Enter), and Esc-to-cancel.
struct FindTextFieldRepresentable: NSViewRepresentable {
    @Binding var text: String

    /// Two-way focus binding. Set true to request focus; reads
    /// false when the field has resigned. The coordinator
    /// reflects user-driven focus changes back through this
    /// binding, so the parent view can keep its own state in
    /// sync without polling AppKit.
    @Binding var focused: Bool

    let placeholder: String
    let font: NSFont
    let textColor: NSColor

    /// Enter (no modifier). Convention: advance to next match.
    let onSubmit: () -> Void

    /// Shift+Enter. Convention: previous match.
    let onShiftSubmit: () -> Void

    /// Esc. Convention: close the find bar.
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let tf = NSTextField()
        tf.isBezeled = false
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.cell?.usesSingleLineMode = true
        tf.cell?.wraps = false
        tf.cell?.isScrollable = true
        tf.lineBreakMode = .byClipping
        tf.placeholderString = placeholder
        tf.font = font
        tf.textColor = textColor
        tf.delegate = context.coordinator
        tf.stringValue = text

        return tf
    }

    func updateNSView(_ tf: NSTextField, context: Context) {
        // Keep coordinator's closures fresh — view re-renders
        // capture new closures each time.
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onShiftSubmit = onShiftSubmit
        context.coordinator.onCancel = onCancel

        // Keep the field's text in sync with the binding
        // without clobbering the user's in-flight typing.
        // controlTextDidChange (user input) writes the binding;
        // setting stringValue here only fires when the binding
        // moved for some other reason (programmatic clear,
        // reader swap, etc.).
        if tf.stringValue != text {
            tf.stringValue = text
        }

        // Drive AppKit firstResponder from the SwiftUI binding.
        // Dispatched async so any in-flight SwiftUI render
        // completes before we mutate the responder chain.
        let wantsFocus = focused
        let isCurrentlyFocused = tf.window?.firstResponder === tf
            || (tf.currentEditor() != nil
                && tf.window?.firstResponder
                    === tf.currentEditor())

        if wantsFocus && !isCurrentlyFocused {
            DispatchQueue.main.async { [weak tf] in
                guard let tf = tf, let window = tf.window
                else { return }
                _ = window.makeFirstResponder(tf)
            }
        } else if !wantsFocus && isCurrentlyFocused {
            DispatchQueue.main.async { [weak tf] in
                guard let tf = tf, let window = tf.window
                else { return }
                _ = window.makeFirstResponder(nil)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            focused: $focused,
            onSubmit: onSubmit,
            onShiftSubmit: onShiftSubmit,
            onCancel: onCancel
        )
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String
        @Binding var focused: Bool
        var onSubmit: () -> Void
        var onShiftSubmit: () -> Void
        var onCancel: () -> Void

        init(
            text: Binding<String>,
            focused: Binding<Bool>,
            onSubmit: @escaping () -> Void,
            onShiftSubmit: @escaping () -> Void,
            onCancel: @escaping () -> Void
        ) {
            self._text = text
            self._focused = focused
            self.onSubmit = onSubmit
            self.onShiftSubmit = onShiftSubmit
            self.onCancel = onCancel
        }

        // MARK: NSTextFieldDelegate

        func controlTextDidChange(_ obj: Notification) {
            guard let tf = obj.object as? NSTextField else { return }
            // Mutating the binding inside the delegate callback
            // is allowed (we're already on main); SwiftUI will
            // schedule the dependent updates on its own cycle.
            text = tf.stringValue
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            // Reflect AppKit-driven focus back into the binding
            // so the parent view's focus state stays consistent
            // when the user clicks the field directly.
            DispatchQueue.main.async { [weak self] in
                self?.focused = true
            }
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            DispatchQueue.main.async { [weak self] in
                self?.focused = false
            }
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                // Enter / Shift+Enter. Single-line NSTextField
                // routes both through insertNewline:; we sniff
                // the shift state from the current event.
                let shift = NSApp.currentEvent?
                    .modifierFlags
                    .contains(.shift) ?? false
                if shift {
                    onShiftSubmit()
                } else {
                    onSubmit()
                }
                // Returning true keeps the field editor from
                // committing-and-blurring; the user can chain
                // Enter presses to walk through matches.
                return true

            case #selector(NSResponder.cancelOperation(_:)):
                onCancel()
                return true

            default:
                return false
            }
        }
    }
}
