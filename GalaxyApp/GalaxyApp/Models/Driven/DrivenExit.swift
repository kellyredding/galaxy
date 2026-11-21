import Foundation

/// A driven session's `session:exited`: recorded once Galaxy has marked the
/// process gone, so a driver that dismisses or resumes on it is never refused.
enum DrivenExit {
    static let eventType = "session:exited"

    /// `initiatedBy` is absent for a crash: nobody asked for the exit.
    static func detail(exitCode: Int32?, initiatedBy: String?) -> [String: Any] {
        var detail: [String: Any] = [:]
        if let exitCode { detail["exit_code"] = Int(exitCode) }
        if let initiatedBy { detail["initiated_by"] = initiatedBy }
        return detail
    }
}
