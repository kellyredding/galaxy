import Foundation
import Combine
import Galactic

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
/// Persistence goes straight to disk through
/// `SettingsManager.persistSidebarVisibility`, never through
/// `SettingsManager.settings`. Mutating the struct fires the
/// fat `@Published` synchronously — that cascade blocks main
/// for ~130ms on the menu path — while a read-modify-write on
/// a background queue costs the toggle frame nothing and the
/// next launch reads the patched value back into the seed.
///
/// What reaches disk is the reader's *choice* and nothing
/// else. `SessionsPanelModel` keeps that apart from what is on
/// screen, so a surface holding the panel shut for its own
/// reasons cannot be mistaken for a reader who shut it, and
/// cannot outlive the session that asked.
final class SidebarPreferences: ObservableObject {
    static let shared = SidebarPreferences()

    /// Whether the panel is showing.
    ///
    /// Read by everything that draws the panel or describes
    /// it — `ContentView`, the toolbar button, the View menu's
    /// validator, the ⌘/ context — because every one of those
    /// is about what is on screen rather than about what was
    /// chosen. The choice is `preferredVisible`, reachable
    /// only through `setPreferred`, which is what stops a
    /// future caller from persisting an automatic collapse.
    ///
    /// `didSet` fires the terminal display throttle so each
    /// move pauses PTY-driven invalidation while the panel
    /// resizes. Swift skips `didSet` during init, so the
    /// launch-time seed assignment below does not trigger the
    /// throttle — only subsequent moves do.
    @Published private(set) var isVisible: Bool {
        didSet {
            TerminalDisplayThrottle.shared.pause(for: 0.25)
        }
    }

    /// The reader's choice, for the persistence rendezvous in
    /// `SettingsManager.save()` only. Everything that draws or
    /// describes the panel wants `isVisible`.
    var preferredVisible: Bool { model.preferred }

    /// Which surfaces are currently holding the panel.
    var heldBy: Set<SessionsPanelCollapseCondition> {
        model.conditions
    }

    private var model: SessionsPanelModel
    private var restoreWork: DispatchWorkItem?

    /// How long a restore waits before landing.
    ///
    /// Leaving one diff for another closes the reader before
    /// it opens the next, so the condition retracts and
    /// re-asserts inside a single keystroke with a content
    /// fetch in between. Restoring immediately puts the panel
    /// back for the length of that fetch, which reads as a
    /// flicker rather than as the panel returning. A collapse
    /// is what the reader is waiting for and lands at once; a
    /// restore is cleanup and can settle.
    private let restoreSettleDelay: TimeInterval = 0.2

    private init() {
        let seeded = SettingsManager.shared
            .settings.isSidebarVisible
        self.model = SessionsPanelModel(preferred: seeded)
        self.isVisible = seeded
    }

    // MARK: - The reader's choice

    /// Record what the reader wants and show it, ending any
    /// overrule in force.
    ///
    /// The only path to disk. A condition never persists,
    /// which is what keeps quitting with a diff open from
    /// coming back collapsed.
    func setPreferred(_ visible: Bool) {
        restoreWork?.cancel()
        model.setPreferred(visible)
        publish()
        SettingsManager.shared
            .persistSidebarVisibility(model.preferred)
    }

    /// Flip relative to what is on screen, not to what was
    /// chosen: the button reads "Show Sessions" whenever the
    /// panel is shut, however it came to be shut, and has to
    /// do what it says.
    func togglePreferred() {
        setPreferred(!isVisible)
    }

    // MARK: - Conditions

    /// Assert or retract a collapse condition. Safe to call
    /// repeatedly with the same value — the model holds a set,
    /// and `publish` declines a value that did not move.
    func setCondition(
        _ asserted: Bool,
        _ condition: SessionsPanelCollapseCondition
    ) {
        model.set(asserted, condition: condition)
        applyConditionChange()
    }

    /// Drop every condition. For the last session closing,
    /// where no artifacts view is left active to retract what
    /// the closed one was holding.
    func clearAllConditions() {
        model.clearConditions()
        applyConditionChange()
    }

    private func applyConditionChange() {
        if model.isVisible {
            scheduleRestore()
        } else {
            restoreWork?.cancel()
            publish()
        }
    }

    private func scheduleRestore() {
        restoreWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.publish()
        }
        restoreWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + restoreSettleDelay,
            execute: work
        )
    }

    /// Guarded so a no-op assertion does not publish a change
    /// to every observer, the way
    /// `TerminalPaneCoordinator.setScrollbackOpen` guards its
    /// own set writes.
    private func publish() {
        let next = model.isVisible
        guard next != isVisible else { return }
        isVisible = next
    }
}
