import Foundation
import UserNotifications
import AppKit

final class NotificationService: NSObject,
    UNUserNotificationCenterDelegate
{
    static let shared = NotificationService()

    /// Track the last context percentage we warned about per session
    /// to avoid re-firing on every enrichment cycle
    private var lastWarnedContextPct: [UUID: Int] = [:]

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Clean up tracking state when a session is closed.
    func sessionClosed(_ sessionId: UUID) {
        lastWarnedContextPct.removeValue(forKey: sessionId)
    }

    // MARK: - Notification Senders

    /// Send a "Session Idle" notification.
    /// Shows a preview of the last assistant response when available,
    /// falling back to context/lines stats.
    func notifySessionIdle(
        sessionId: UUID,
        displayName: String,
        responsePreview: String?,
        contextPct: Double?,
        linesAdded: Int?,
        linesRemoved: Int?
    ) {
        let content = UNMutableNotificationContent()
        content.title = displayName

        // Subtitle: "Idle · 22% context"
        var subtitleParts: [String] = ["Idle"]
        if let pct = contextPct {
            subtitleParts.append("\(Int(pct))% context")
        }
        content.subtitle = subtitleParts
            .joined(separator: " \u{00B7} ")

        // Body: last assistant response preview (or fallback)
        if let preview = responsePreview, !preview.isEmpty {
            content.body = preview
        } else {
            content.body = ""
        }
        content.sound = .default
        content.userInfo = [
            "sessionId": sessionId.uuidString,
            "tab": "terminal",
        ]

        let request = UNNotificationRequest(
            identifier: "session-idle-\(sessionId.uuidString)",
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

    /// Send a "Terminal Bell" notification with context
    /// from the most recent turn event.
    func notifyTerminalBell(
        sessionId: UUID,
        displayName: String,
        bodyText: String?
    ) {
        let content = UNMutableNotificationContent()
        content.title = displayName
        content.subtitle = "Terminal bell"
        if let text = bodyText, !text.isEmpty {
            content.body = text
        }
        content.sound = .default
        content.userInfo = [
            "sessionId": sessionId.uuidString,
            "tab": "terminal",
        ]

        let request = UNNotificationRequest(
            identifier:
                "terminal-bell-\(sessionId.uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Send a "Permission Request" notification.
    func notifyPermissionRequest(
        sessionId: UUID,
        displayName: String
    ) {
        let content = UNMutableNotificationContent()
        content.title = displayName
        content.body = "Waiting for permission approval"
        content.sound = .default
        content.userInfo = [
            "sessionId": sessionId.uuidString,
            "tab": "terminal",
        ]

        let request = UNNotificationRequest(
            identifier:
                "permission-request-\(sessionId.uuidString)",
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
