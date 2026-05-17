import Foundation
import Combine

/// Narrow publisher for sidebar visibility, deliberately
/// split off from `SettingsManager`'s fat `@Published var
/// settings: AppSettings` so toggling the sidebar doesn't
/// invalidate every consumer of app settings.
///
/// SwiftUI's `@ObservedObject` / `@EnvironmentObject` re-
/// evaluates the body of every view whose model fires
/// `objectWillChange`. Because `@Published` properties on a
/// single `ObservableObject` share that publisher, mutating
/// any field on `SettingsManager.settings` invalidates *all*
/// of its observers — and the diagnostic log proved that
/// fan-out blocks the main thread for 80–300ms per toggle,
/// gating the animation start.
///
/// Splitting visibility into its own `ObservableObject` means
/// only sidebar-aware views observe its `objectWillChange`.
/// `ContentView`, the toolbar button icon, and the menu
/// validator still react instantly; the terminal containers,
/// ledger views, agents/artifacts/snapshots/timeline views,
/// and the 20 session rows nested inside them never see the
/// invalidation at all.
///
/// Persistence is mirrored back to `SettingsManager.settings`
/// via `DispatchQueue.main.async` so the fat publisher fires
/// on a *subsequent* runloop pass — well after SwiftUI has
/// committed the narrow change and started the toggle
/// animation. The disk write itself is sub-millisecond
/// (verified by the `[Galaxy/dbg/settings] save:` markers);
/// what hurt was the synchronous SwiftUI invalidation
/// cascade, which the deferral moves out of the toggle's
/// critical path.
final class SidebarPreferences: ObservableObject {
    static let shared = SidebarPreferences()

    /// True when the session sidebar is expanded. Observers
    /// of this property re-render on flip; observers of
    /// `SettingsManager` do not.
    ///
    /// `didSet` fires the terminal display throttle so each
    /// toggle pauses PTY-driven invalidation for the slide
    /// animation's duration. Swift skips `didSet` during
    /// init, so the launch-time seed assignment below does
    /// not trigger the throttle — only subsequent
    /// (user-driven) toggles do.
    @Published var isVisible: Bool {
        didSet {
            TerminalDisplayThrottle.shared.pause(for: 0.25)
        }
    }

    private var cancellables = Set<AnyCancellable>()

    private init() {
        // Seed from the persisted settings on launch.
        self.isVisible = SettingsManager.shared
            .settings.isSidebarVisible

        // Persist to disk on every flip WITHOUT mutating
        // `SettingsManager.settings`. The earlier
        // deferred-mutation approach still ended up
        // firing the fat @Published synchronously inside
        // the deferred block — that cascade blocks main
        // for ~130ms on the menu path. Routing straight
        // to disk via a read-modify-write on a background
        // queue avoids the cascade entirely: no SwiftUI
        // observers of `SettingsManager` see the change,
        // so the toggle's main-thread cost is just the
        // narrow publisher's own (cheap) invalidation.
        // The on-disk JSON stays correct because the
        // file load at next launch reads the patched
        // value back into the seed above.
        $isVisible
            .dropFirst()
            .sink { value in
                SettingsManager.shared
                    .persistSidebarVisibility(value)
            }
            .store(in: &cancellables)
    }
}
