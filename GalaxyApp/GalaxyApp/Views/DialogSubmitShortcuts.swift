import SwiftUI

/// The chords a dialog answers to submit, besides Return.
///
/// A view carries one `.keyboardShortcut`, and the primary button spends its
/// on `.defaultAction` — which is also what gives that button its default
/// styling, so it cannot be traded away. These carry the rest, on buttons that
/// exist for no other reason.
///
/// Hardcoded rather than read from the text-entry settings, and the keystroke
/// catalog's dialog rows stay literal for the same reason: a dialog still does
/// not follow a reconfigured submit key. What it does now is answer the two
/// chords that submit everywhere else in the app, so the habit the rest of
/// Galaxy trains stops being met with a beep here.
struct DialogSubmitShortcuts: View {
    /// Mirrors the primary button's own disabled state, so a chord cannot
    /// commit a form the button itself refuses.
    let isDisabled: Bool
    let submit: () -> Void

    var body: some View {
        ZStack {
            Button("", action: submit)
                .keyboardShortcut(.return, modifiers: .command)
            Button("", action: submit)
                .keyboardShortcut(.return, modifiers: .shift)
        }
        // Invisible and zero-sized, but deliberately not `.hidden()`: a hidden
        // view stops answering its shortcut, which is the entire job here.
        // Mounted as a background so it takes no room in the button row and
        // cannot shift the buttons it sits behind.
        .opacity(0)
        .frame(width: 0, height: 0)
        .disabled(isDisabled)
        .accessibilityHidden(true)
    }
}
