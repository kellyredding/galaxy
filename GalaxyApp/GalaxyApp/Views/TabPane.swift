import SwiftUI

/// Show one tab's container and stand the rest down.
///
/// Six containers wrote the same three lines by hand, which is the shape
/// `ListNavigation` was extracted from for the same reason — five views wrote
/// that guard and two of them left a clause out.
///
/// Every container stays mounted and switching changes only opacity, hit
/// testing and z-order. That is deliberate and load-bearing: a conditional
/// would tear down and rebuild a terminal, a web view and a scroll position on
/// every switch. It is also why what a hidden pane must not do — answer a
/// keystroke, take first responder, consume a list-navigation action — is
/// handled by threading `isVisibleSurface` down to the views that care, rather
/// than by disabling the subtree here.
///
/// Deliberately *not* the same modifier Assist Ant has under this name. That
/// one also disables a covered pane, for a cursor-tracking problem this app
/// does not have and against a `covered` state this app has no concept of —
/// its readers live inside their tab rather than above the stack. Same name,
/// different signature, on purpose.
extension View {
    func tabPane(_ tab: SessionTab, selected: SessionTab) -> some View {
        let isSelected = tab == selected
        #if DEBUG
            TabPaneRegistry.record(tab)
        #endif
        return
            self
            .opacity(isSelected ? 1 : 0)
            .allowsHitTesting(isSelected)
            .zIndex(isSelected ? 1 : 0)
    }
}

#if DEBUG
    /// Which tabs actually reached the screen, so a missing container says so.
    ///
    /// A tab added to `SessionTab` and not to the stack is the one add-a-tab
    /// step nothing catches: the picker builds its button from `allCases`, the
    /// button selects the tab, and the content area goes blank. There is no
    /// compiler answer to that — driving the stack from `allCases` would need
    /// a builder returning conditional content, which churns view identity on
    /// every switch and tears down exactly the panes this design keeps alive.
    ///
    /// So this records what was *mounted* rather than restating what should
    /// be, which is what makes it worth having: a second hand-written list
    /// would be edited in the same sitting as the first and prove nothing.
    ///
    /// Debug only, and reported once. It cannot run in `make check`, which
    /// builds and runs three standalone tools and never launches the app —
    /// this speaks at first launch instead.
    enum TabPaneRegistry {
        private static var mounted: Set<SessionTab> = []
        private static var hasReported = false

        static func record(_ tab: SessionTab) {
            mounted.insert(tab)
        }

        /// Called once the stack has been built at least once.
        static func reportMissingPanes() {
            guard !hasReported else { return }
            hasReported = true
            let missing = Set(SessionTab.allCases).subtracting(mounted)
            guard !missing.isEmpty else { return }
            let names = missing.map(\.rawValue).sorted().joined(separator: ", ")
            assertionFailure(
                "No container is mounted for: \(names). Add one to "
                    + "ContentView.activeViewContent — the tab's button "
                    + "already exists, so it selects a blank pane."
            )
        }
    }
#endif
