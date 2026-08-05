import Foundation

/// A reason the sessions panel is collapsed that is not the reader's
/// own choice.
///
/// One case per real surface that needs the horizontal room, in the
/// shape `KeystrokeAvailability` uses: the case carries its own words,
/// so a diagnostic naming the condition cannot disagree with the
/// condition actually holding. A case nothing asserts is a claim
/// nobody checked — add one when a surface arrives, not in advance of
/// one.
enum SessionsPanelCollapseCondition: Hashable, CaseIterable {
    /// The diff reader is the surface in front of the reader. Its file
    /// cards lay two columns of code side by side, and at the panel's
    /// default 220pt the right column wraps.
    case diffReader

    /// Why the panel is held. Paired with the case rather than written
    /// at the site that reports it, so a condition cannot be described
    /// as one it is not.
    var reason: String {
        switch self {
        case .diffReader:
            return "a diff artifact is open"
        }
    }
}
