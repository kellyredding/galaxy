import SwiftUI

extension View {
    /// Answer the list-navigation keystrokes when this view is the surface a
    /// reader is actually looking at.
    ///
    /// Five views wrote this guard by hand and two of them left out the
    /// active-tab check, which mattered: every tab container stays mounted
    /// behind an opacity of zero, the action is one shared value, and the first
    /// handler to read it clears it. A hidden list could therefore answer a
    /// keystroke aimed at the visible one and swallow it on the way.
    ///
    /// The manager is passed in rather than read from its singleton so the
    /// change is observed. `onChange` only fires while the view is being
    /// re-evaluated, and what re-evaluates it is the caller's own subscription
    /// to this object.
    func listNavigation(
        from manager: SessionManager,
        isActive: @escaping () -> Bool,
        onAction: @escaping (ListNavAction) -> Void
    ) -> some View {
        onChange(of: manager.listNavAction) {
            guard isActive() else { return }
            guard let action = manager.listNavAction else { return }
            manager.listNavAction = nil
            onAction(action)
        }
    }
}
