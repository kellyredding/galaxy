import Foundation

/// Whether the sessions panel is showing, resolved from two
/// independent facts: what the reader chose, and which surfaces have
/// asked for the room.
///
/// The type exists because those two were one stored `Bool`. A surface
/// collapsing the panel by writing that flag would overwrite the
/// choice it is supposed to hand back — and, that flag being the
/// persisted one, would still be holding the panel shut at the next
/// launch with nothing left to say why. Kept apart here, `preferred`
/// is only ever written by the reader and `conditions` only ever by a
/// surface, so neither can spend the other.
struct SessionsPanelModel {
    /// What the reader chose. The persisted value, and the only one.
    private(set) var preferred: Bool

    /// Surfaces currently asking for the room.
    ///
    /// A set rather than a count for the reason
    /// `Session.runningAgentIds` is one: a surface can assert twice,
    /// since three `onChange` handlers drive the artifacts condition,
    /// and can fail to retract at all when the view holding it goes
    /// away. Membership makes the first harmless and leaves the second
    /// recoverable by anyone who knows the condition's name.
    private(set) var conditions: Set<SessionsPanelCollapseCondition> = []

    /// Whether a condition is presently overruling `preferred`.
    ///
    /// Deliberately not `!conditions.isEmpty`, and the difference is
    /// the feature: a reader who reaches for ⇧⌘] while the panel is
    /// held gets it, and keeps it for as long as they stay. A `Bool`
    /// rather than a second set because it answers a different
    /// question than overlap does — `conditions` is what keeps two
    /// surfaces from cancelling one another, which is the failure
    /// `NavigationCoordinator.isSuppressingRecording` has from using
    /// one `Bool` for both at once.
    private(set) var isOverruling: Bool = false

    init(preferred: Bool) {
        self.preferred = preferred
    }

    /// What the panel does right now.
    var isVisible: Bool {
        isOverruling ? false : preferred
    }

    /// The reader spoke. Their word is the preference from here on,
    /// and it ends any overrule in force — including one they happen
    /// to agree with, so Hide pressed while the panel is already held
    /// is recorded rather than swallowed and then undone on the way
    /// out.
    mutating func setPreferred(_ visible: Bool) {
        preferred = visible
        isOverruling = false
    }

    /// A surface asked for the room, or gave it back.
    ///
    /// Only a first condition overrules. One arriving while another is
    /// held changes nothing, and neither does one arriving after the
    /// reader has overruled — it still joins the set, so its
    /// retraction is accounted for, but the panel stays the reader's
    /// until they leave.
    mutating func set(
        _ asserted: Bool,
        condition: SessionsPanelCollapseCondition
    ) {
        let wasEmpty = conditions.isEmpty
        if asserted {
            conditions.insert(condition)
            if wasEmpty { isOverruling = true }
        } else {
            conditions.remove(condition)
            if conditions.isEmpty { isOverruling = false }
        }
    }

    /// Drop every condition at once, for the paths where the surface
    /// holding one went away with nothing left to retract it. See
    /// `SessionManager.closeSession`.
    mutating func clearConditions() {
        conditions.removeAll()
        isOverruling = false
    }
}
