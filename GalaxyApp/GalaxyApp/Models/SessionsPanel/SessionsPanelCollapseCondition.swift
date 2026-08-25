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
    /// The Files tab is the surface on screen.
    ///
    /// Asserted for the whole tab rather than for an open document, unlike the
    /// diff reader beside it: the strip wants the width before any file does,
    /// because how many rows it wraps into is decided by how wide it is.
    case filesTab

    /// Why the panel is held. Paired with the case rather than written
    /// at the site that reports it, so a condition cannot be described
    /// as one it is not.
    var reason: String {
        switch self {
        case .diffReader:
            return "a diff artifact is open"
        case .filesTab:
            return "the Files tab is open"
        }
    }
}
