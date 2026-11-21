import Foundation

/// Who produced a message for a session's inbox. A lock refuses only a person.
enum InboxOrigin: Equatable {
    /// Composed by someone in Galaxy's UI: a scrollback, file or artifact review.
    case person
    /// Issued by Galaxy itself: auto-clear, cut-off recovery.
    case galaxy
    /// Sent by the session's owner through `galaxy session send`.
    case driver
}
