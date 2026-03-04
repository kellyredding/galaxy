import Foundation
import UserNotifications
import AppKit

final class NotificationService: NSObject,
    UNUserNotificationCenterDelegate
{
    static let shared = NotificationService()

    /// Track when each session last entered busy state
    /// (for minimum busy duration filtering)
    private var busyStartTimes: [UUID: Date] = [:]

    /// Track the last context percentage we warned about per session
    /// to avoid re-firing on every enrichment cycle
    private var lastWarnedContextPct: [UUID: Int] = [:]

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    // MARK: - Busy Duration Tracking

    /// Called when a session transitions idle → busy.
    /// Records the timestamp for minimum-busy-duration filtering.
    func sessionDidBecomeBusy(_ sessionId: UUID) {
        busyStartTimes[sessionId] = Date()
    }

    /// Returns the duration the session was busy, or nil if
    /// not tracked.
    func sessionBusyDuration(_ sessionId: UUID) -> TimeInterval? {
        guard let start = busyStartTimes[sessionId] else {
            return nil
        }
        return Date().timeIntervalSince(start)
    }

    /// Clean up tracking state when a session is closed.
    func sessionClosed(_ sessionId: UUID) {
        busyStartTimes.removeValue(forKey: sessionId)
        lastWarnedContextPct.removeValue(forKey: sessionId)
    }

    // MARK: - Notification Senders

    /// Send a "Session Ready" notification.
    func notifySessionReady(
        sessionId: UUID,
        displayName: String,
        contextPct: Double?,
        linesAdded: Int?,
        linesRemoved: Int?
    ) {
        let content = UNMutableNotificationContent()
        content.title = displayName

        var parts: [String] = ["Ready for input"]
        if let pct = contextPct {
            parts.append("\(Int(pct))% context")
        }
        if let added = linesAdded, let removed = linesRemoved,
           (added > 0 || removed > 0) {
            parts.append("+\(added)/-\(removed) lines")
        }
        content.body = parts.joined(separator: " \u{00B7} ")
        content.sound = .default
        content.userInfo = [
            "sessionId": sessionId.uuidString,
            "tab": "terminal",
        ]

        let request = UNNotificationRequest(
            identifier: "session-ready-\(sessionId.uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Send a "Session Exited Unexpectedly" notification.
    func notifySessionExitedUnexpectedly(
        sessionId: UUID,
        displayName: String,
        exitCode: Int32
    ) {
        let content = UNMutableNotificationContent()
        content.title = displayName
        content.body = "Session exited unexpectedly (code \(exitCode))"
        content.sound = .default
        content.userInfo = [
            "sessionId": sessionId.uuidString,
            "tab": "terminal",
        ]

        let request = UNNotificationRequest(
            identifier: "session-exited-\(sessionId.uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Send a "High Context Warning" notification.
    /// Returns false if suppressed (already warned at this level).
    @discardableResult
    func notifyHighContext(
        sessionId: UUID,
        displayName: String,
        contextPct: Int
    ) -> Bool {
        // Suppress if we already warned at or above this percentage
        if let lastWarned = lastWarnedContextPct[sessionId],
           lastWarned >= contextPct {
            return false
        }

        lastWarnedContextPct[sessionId] = contextPct

        let content = UNMutableNotificationContent()
        content.title = displayName
        content.body = "Context at \(contextPct)%"
            + " \u{2014} consider compacting or clearing"
        content.sound = .default
        content.userInfo = [
            "sessionId": sessionId.uuidString,
            "tab": "terminal",
        ]

        let request = UNNotificationRequest(
            identifier: "high-context-\(sessionId.uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
        return true
    }

    /// Reset the high-context warning state for a session so the
    /// warning can fire again on the next threshold crossing.
    /// Called automatically when enrichment data shows context
    /// dropped below the threshold.
    func resetHighContextWarning(for sessionId: UUID) {
        lastWarnedContextPct.removeValue(forKey: sessionId)
    }

    /// Send an "Auto-Clear Occurred" notification.
    func notifyAutoClearOccurred(
        sessionId: UUID,
        displayName: String,
        contextPct: Int
    ) {
        let content = UNMutableNotificationContent()
        content.title = displayName
        content.body = "Auto-cleared at \(contextPct)% context"
        content.sound = .default
        content.userInfo = [
            "sessionId": sessionId.uuidString,
            "tab": "terminal",
        ]

        let request = UNNotificationRequest(
            identifier: "auto-clear-\(sessionId.uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Send a "Snapshot Created" notification.
    func notifySnapshotCreated(
        sessionId: UUID,
        displayName: String,
        snapshotNumber: Int32
    ) {
        let content = UNMutableNotificationContent()
        content.title = displayName
        content.body = "Snapshot #\(snapshotNumber) created"
        content.sound = .default
        content.userInfo = [
            "sessionId": sessionId.uuidString,
            "tab": "snapshots",
            "snapshotNumber": Int(snapshotNumber),
        ]

        let request = UNNotificationRequest(
            identifier: "snapshot-\(sessionId.uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Handle notification click — deep link to the session and tab.
    /// Posts `.showMainWindow` so AppDelegate can ensure the window
    /// is visible (handles the case where the user closed the window
    /// via the red button but the app is still running).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo

        if let sessionIdString = userInfo["sessionId"] as? String,
           let sessionId = UUID(uuidString: sessionIdString) {
            DispatchQueue.main.async {
                let sm = SessionManager.shared

                // Bring app to front and ensure window is visible
                NSApplication.shared.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(
                    name: .showMainWindow, object: nil
                )

                sm.switchTo(sessionId: sessionId)

                // Navigate to the target tab
                let tab = userInfo["tab"] as? String ?? "terminal"
                switch tab {
                case "snapshots":
                    sm.activeTab = .snapshots
                    // Open the snapshot reader if number was provided
                    if let number = userInfo["snapshotNumber"] as? Int {
                        sm.pendingSnapshotNumber = Int32(number)
                    }
                default:
                    sm.activeTab = .terminal
                }
            }
        }

        completionHandler()
    }

    /// Show notifications even when the app is in the foreground.
    /// Individual suppression logic is applied before sending, so
    /// if a notification reaches here it should be displayed.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
