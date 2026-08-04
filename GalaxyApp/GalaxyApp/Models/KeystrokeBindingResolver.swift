import Foundation
import Galactic

/// Turns a catalog binding into the text a row displays.
///
/// Sits outside `Models/Keystrokes/` deliberately, and that placement is
/// the whole design: everything in that directory is `import Foundation`
/// and nothing else, which is what lets a dependency-free `type: tool`
/// smoke target compile the catalog and assert what the sheet decides.
/// This file needs Galactic for `TextEntryBindings` and Galaxy's own
/// `SettingsManager` for the live values, so it cannot live there — and
/// pulling it in would drag the whole app into the smoke target with it.
///
/// It is also what keeps the sheet honest. Three of the catalog's
/// bindings are decided by settings rather than by code — the submit and
/// newline keystrokes, and which bracket hides the sessions panel — so
/// they are read here at display time rather than frozen into the
/// catalog where a change in Settings would leave them lying.
enum KeystrokeBindingResolver {

    /// Shown when a configurable keystroke has nothing assigned. A dash
    /// reads as "not bound"; an empty cell reads as a rendering bug.
    ///
    /// Nearly unreachable in Galaxy — `AppSettings` coerces an empty
    /// list back to the default on decode — but the type permits the
    /// state, and `displayLabels(for:)` answers empty for it, so the
    /// dash is what an empty answer renders as rather than a hole.
    static let unbound = "—"

    /// Every keystroke bound to `binding`, in the order Settings lists
    /// them: one for a fixed key, as many as are configured for a
    /// text-entry action, and a single dash when one has nothing.
    ///
    /// All of them, not just the first. A placeholder naming one of
    /// three chords is a hint doing its job; a *reference* naming one of
    /// three is denying that the other two work.
    static func displayTexts(for binding: KeystrokeBinding) -> [String] {
        switch binding {
        case .literal(let text):
            return [text]
        case .textEntrySubmit:
            return labels(for: .submit)
        case .textEntryNewline:
            return labels(for: .newline)
        // The bracket that means "toward the panel" — ⇧⌘[ with the panel
        // on the left, ⇧⌘] with it on the right, exactly as
        // `buildSessionsMenu` assigns them. Read from the same setting
        // the menu reads, so the sheet and the menu cannot disagree
        // about which bracket a user should press.
        case .sessionsPanelHide:
            return [panelOnLeft ? "⇧⌘[" : "⇧⌘]"]
        case .sessionsPanelShow:
            return [panelOnLeft ? "⇧⌘]" : "⇧⌘["]
        }
    }

    /// Galactic answers with the configured labels in the user's order,
    /// and with nothing at all when a list is empty — which is why the
    /// em dash is still here. The shared helper cannot know that a
    /// cheat-sheet row wants "not bound" spelled out where a composer
    /// placeholder wants silence, so it declines to guess and the caller
    /// decides.
    private static func labels(
        for action: TextEntryBindings.Action
    ) -> [String] {
        let labels = SettingsManager.shared.settings.textEntry
            .displayLabels(for: action)
        return labels.isEmpty ? [unbound] : labels
    }

    private static var panelOnLeft: Bool {
        SettingsManager.shared.settings.sidebarPosition == .left
    }
}
