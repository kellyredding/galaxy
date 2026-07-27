import Foundation

/// Which keystrokes commit text and which insert a newline.
///
/// Foundation-only for the same reason as `Keystroke`: the smoke target links
/// it directly, so the resolver is covered without an app or a WebView.
struct TextEntryBindings: Codable, Equatable {
    var submit: [Keystroke]
    var newline: [Keystroke]

    enum Action: String, Codable {
        case submit
        case newline
    }

    /// Resolve a keystroke to the action it triggers, or nil for "not ours".
    ///
    /// Nil is the important case: the caller passes the event through
    /// untouched rather than swallowing it, which is what leaves every key the
    /// app does not own — and every shortcut it does not know about — working
    /// exactly as before.
    ///
    /// Submit is checked first, so a keystroke appearing in both lists
    /// commits. That is a deliberate tie-break rather than an error: a binding
    /// in both lists is a state the recorder can reach, and inserting an
    /// unwanted newline is a smaller harm than dropping committed text.
    func action(for keystroke: Keystroke) -> Action? {
        if submit.contains(keystroke) { return .submit }
        if newline.contains(keystroke) { return .newline }
        return nil
    }

    /// Reproduces what every composer does today: Command-Return commits, a
    /// bare Return inserts a newline. Nobody who never opens the settings card
    /// sees a change.
    static let `default` = TextEntryBindings(
        submit: [Keystroke(keyCode: Keystroke.Key.ret, modifiers: .command)],
        newline: [Keystroke(keyCode: Keystroke.Key.ret)]
    )
}
