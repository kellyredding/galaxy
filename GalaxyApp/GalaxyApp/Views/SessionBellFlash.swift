import SwiftUI

/// Backdrop washes for the sidebar bell flash, in both sidebar modes.
///
/// Two values rather than one because the thing being washed differs. A
/// selected row's background is forced dark in either app theme, so white reads
/// on it. An unselected row draws no background of its own and follows the app
/// theme, where white would disappear in light mode — and inverting to black
/// would put a dark wash behind dark text, since the flash renders behind the
/// row's content rather than over it.
///
/// Neutral gray solves that the way the pane pulse already does: it dims a light
/// row and lightens a dark one, reading as a flash in both without fighting the
/// text. It is deliberately *not* wired to `TerminalVisualBell.peakOpacity`
/// despite matching it today — that is the apex of a 200ms animated curve, this
/// is a sustained fill, and tuning one should not silently move the other.
///
/// Kept app-side on purpose. The engine owns the rhythm a flash follows; which
/// rows flash, and in what colour, is this application's to decide.
extension Color {

    /// Wash for the selected row, over its forced-dark base.
    static let sessionBellFlashSelected = Color.white.opacity(0.4)

    /// Wash for any other row, over whatever the theme puts behind it.
    static let sessionBellFlashUnselected = Color.gray.opacity(0.25)
}
