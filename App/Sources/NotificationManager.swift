import Foundation
import UserNotifications
import AgentBabysitterCore

/// Posts native notifications for planner events and routes notification
/// clicks back to the owning terminal.
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {

    /// Looks up the current row for a session when a notification is clicked.
    var rowProvider: (@MainActor (String) -> SessionRow?)?

    private let center = UNUserNotificationCenter.current()
    private var authorizationRequested = false

    /// Ask once at launch so the app appears in Notification settings before
    /// the first alert would fire.
    func primeAuthorization() {
        requestAuthorizationIfNeeded()
    }

    func deliver(_ events: [NotificationEvent], rows: [SessionRow],
                 muted: Bool, enabledKinds: Set<NotificationEvent.Kind>,
                 stallThresholdMinutes: Int) {
        guard !muted, !events.isEmpty else { return }
        requestAuthorizationIfNeeded()

        let rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        for event in events where enabledKinds.contains(event.kind) {
            guard let row = rowsByID[event.sessionID] else { continue }
            let content = UNMutableNotificationContent()
            content.body = body(for: event, row: row, stallMinutes: stallThresholdMinutes)
            content.userInfo = ["sessionID": event.sessionID]
            content.sound = .default
            center.add(UNNotificationRequest(
                identifier: "\(event.sessionID)-\(event.kind)-\(Date().timeIntervalSince1970)",
                content: content, trigger: nil))
        }
    }

    private func body(for event: NotificationEvent, row: SessionRow,
                      stallMinutes: Int) -> String {
        switch event.kind {
        case .waitingForInput:
            return "Session \(row.projectName) needs your input."
        case .turnCompleted:
            if row.cost.hasUnknownPricing || row.cost.dollars == 0 {
                return "Session \(row.projectName) finished its turn."
            }
            return String(format: "Session %@ finished its turn (cost $%.2f).",
                          row.projectName, row.cost.dollars)
        case .stalled:
            return "Session \(row.projectName) has produced nothing for \(stallMinutes) min."
        }
    }

    private func requestAuthorizationIfNeeded() {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let sessionID = response.notification.request.content
            .userInfo["sessionID"] as? String
        completionHandler()
        guard let sessionID else { return }
        Task { @MainActor in
            if let row = self.rowProvider?(sessionID) {
                TerminalFocuser.focusSession(row)
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler:
                                            @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
