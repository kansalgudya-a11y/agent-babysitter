import Foundation
import AppKit
import UserNotifications
import AgentBabysitterCore

/// Posts native notifications for planner events and routes notification
/// clicks back to the owning terminal.
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {

    /// Looks up the current row for a session when a notification is
    /// clicked - async so it can reach sessions the auto-hide tidied away.
    var rowProvider: (@MainActor (String) async -> SessionRow?)?
    /// Formats a USD amount in the user's currency (set by AppModel).
    var money: (Double) -> String = { String(format: "~$%.2f", $0) }

    /// Rows that left the list take their delivered banners along.
    func removeDelivered(sessionIDs: [String]) {
        center.removeDeliveredNotifications(
            withIdentifiers: sessionIDs.map { "session-\($0)" })
    }

    private let center = UNUserNotificationCenter.current()
    private var authorizationRequested = false

    /// Ask once at launch so the app appears in Notification settings before
    /// the first alert would fire. On the very first launch, follow up with
    /// a single pointer to the menu bar - new users otherwise see nothing.
    func primeAuthorization() {
        requestAuthorizationIfNeeded()
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "welcomeNotificationSent") else { return }
        defaults.set(true, forKey: "welcomeNotificationSent")
        let content = UNMutableNotificationContent()
        content.body = "Agent Babysitter is running - click the icon in your "
            + "menu bar to see your AI agents. No setup needed."
        center.add(UNNotificationRequest(identifier: "welcome", content: content,
                                         trigger: UNTimeIntervalNotificationTrigger(
                                             timeInterval: 3, repeats: false)))
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
            content.categoryIdentifier = "session-event"
            // One identifier per session: a newer state replaces the older
            // banner instead of stacking (three flapping sessions used to
            // wallpaper the corner of the screen).
            center.add(UNNotificationRequest(
                identifier: "session-\(event.sessionID)",
                content: content, trigger: nil))
        }
    }

    /// "Still waiting (10 min): fix the login bug" — the opt-in follow-up for
    /// a waiting session the user missed. Same identifier as the session's
    /// state banner so it replaces the original 🟡 instead of stacking, and
    /// keeps the same jump/snooze actions.
    func deliverWaitingReminder(row: SessionRow, minutes: Int) {
        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.body = row.title
            .map { "Still waiting for you (\(minutes) min): “\($0)” — \(row.projectName)." }
            ?? "Still waiting for you (\(minutes) min): session \(row.projectName)."
        content.userInfo = ["sessionID": row.id]
        content.sound = .default
        content.categoryIdentifier = "session-event"
        center.add(UNNotificationRequest(identifier: "session-\(row.id)",
                                         content: content, trigger: nil))
    }

    /// Advisory spend nudge — surfaces a suggestion, never implies we stopped
    /// or paused the user's work. Clicking routes to the session like others.
    func deliverSpendSuggestion(_ suggestion: SpendGuardPlanner.Suggestion) {
        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = suggestion.kind == .burningFast ? "Spending fast 💸" : "Budget passed 💸"
        content.body = SpendGuardPlanner.message(
            suggestion.kind, project: suggestion.projectName,
            dollarsText: money(suggestion.dollars),
            burnText: money(suggestion.burnRatePerMinute))
        content.userInfo = ["sessionID": suggestion.id]
        content.sound = .default
        content.categoryIdentifier = "session-event"
        center.add(UNNotificationRequest(
            identifier: "spend-\(suggestion.id)-\(String(describing: suggestion.kind))",
            content: content, trigger: nil))
    }

    /// "Claude Code is at 82% of its 5-hour limit." One identifier per agent
    /// per window kind so re-alerts replace rather than stack. The label
    /// follows the window length (Cursor is monthly, Manus daily).
    func deliverLimitAlert(agentName: String, agentID: String,
                           usedPercent: Double, resetsAt: Date?,
                           windowMinutes: Int = 300, isWeekly: Bool = false) {
        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        let kind = isWeekly ? "weekly" : "primary"
        let window = isWeekly ? "weekly" : Self.windowLabel(minutes: windowMinutes)
        var body = "\(agentName) is at \(Int(usedPercent))% of its \(window) limit."
        if let resetsAt, resetsAt > Date() {
            let minutes = Int(resetsAt.timeIntervalSinceNow / 60)
            if minutes >= 24 * 60 {
                body += " Resets in \(minutes / (24 * 60))d \((minutes % (24 * 60)) / 60)h."
            } else if minutes >= 60 {
                body += " Resets in \(minutes / 60)h \(minutes % 60)m."
            } else {
                body += " Resets in \(max(minutes, 1))m."
            }
        }
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: "limit-\(agentID)-\(kind)",
                                         content: content, trigger: nil))
    }

    /// The predictive cousin of deliverLimitAlert: "on pace to hit its 5-hour
    /// limit at 2:14 PM — 40m before it resets." Same identifier scheme so a
    /// refreshed projection replaces the pending banner instead of stacking.
    func deliverPaceWarning(agentName: String, agentID: String,
                            usedPercent: Double, exhaustionAt: Date,
                            resetsAt: Date, isWeekly: Bool,
                            windowMinutes: Int) {
        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        let kind = isWeekly ? "weekly" : "primary"
        let window = isWeekly ? "weekly" : Self.windowLabel(minutes: windowMinutes)
        let earlyText = MenuContent.humanDuration(resetsAt.timeIntervalSince(exhaustionAt))
        content.body = "\(agentName) is at \(Int(usedPercent))% and on pace to hit its "
            + "\(window) limit at \(Self.clockTime(exhaustionAt)) — "
            + "\(earlyText) before it resets."
        content.sound = .default
        center.add(UNNotificationRequest(identifier: "pace-\(agentID)-\(kind)",
                                         content: content, trigger: nil))
    }

    // Cached: clockTime renders in the menu body on the 2s refresh tick, and
    // DateFormatter construction (especially template resolution) is the
    // expensive part — same reasoning as Currency's formatterCache.
    private static let todayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE j:mm")
        return formatter
    }()
    private static let farFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d, j:mm")
        return formatter
    }()

    /// "2:14 PM" today, "Thu 2:14 PM" within the week, "Jul 21, 2:14 PM"
    /// beyond — a bare weekday more than ~6 days out reads as the wrong week
    /// (reachable via monthly windows like Cursor's).
    static func clockTime(_ date: Date, now: Date = Date()) -> String {
        if Calendar.current.isDateInToday(date) {
            return Self.todayFormatter.string(from: date)
        }
        if date.timeIntervalSince(now) < 6 * 86_400 {
            return Self.weekdayFormatter.string(from: date)
        }
        return Self.farFormatter.string(from: date)
    }

    /// "Agent Babysitter 0.7.0 is available." Tapping it (or "Update now")
    /// opens the release page to download the new build. One identifier so a
    /// newer version replaces an older pending banner. `notes` is the
    /// what's-new digest — shown under the headline (the banner collapses it;
    /// Notification Center and the expanded banner show every line).
    func deliverUpdateAvailable(version: String, url: URL, notes: String?) {
        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = "Update available"
        content.body = "Agent Babysitter \(version) is ready to install."
            + (notes.map { "\n\($0)" } ?? "")
        content.userInfo = ["updateURL": url.absoluteString]
        content.categoryIdentifier = "update"
        content.sound = .default
        center.add(UNNotificationRequest(identifier: "update-available",
                                         content: content, trigger: nil))
    }

    /// "Your week with AI agents: ~$142 across 38 sessions…" Sunday evening,
    /// once per week (AppModel gates the cadence).
    func deliverWeeklyDigest(dollars: Double, sessions: Int, busiestProject: String?,
                             planValue: Bool, money: (Double) -> String) {
        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = "Your week with AI agents"
        var body = sessions == 0 && dollars == 0
            ? "A quiet week — no agent sessions."
            : "\(money(dollars))\(planValue ? " of plan value" : "") across "
              + "\(sessions) session\(sessions == 1 ? "" : "s")."
        if let busiestProject {
            body += " Busiest: \(busiestProject)."
        }
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: "weekly-digest",
                                         content: content, trigger: nil))
    }

    /// "You've spent ~$52 today — over your $50 budget." Once per day/week.
    func deliverCostBudgetAlert(isWeekly: Bool, spent: Double, budget: Double,
                                money: (Double) -> String) {
        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        let window = isWeekly ? "this week" : "today"
        content.body = "You've spent \(money(spent)) \(window) — over your \(money(budget)) budget."
        content.sound = .default
        center.add(UNNotificationRequest(
            identifier: "budget-\(isWeekly ? "week" : "day")", content: content, trigger: nil))
    }

    /// Warn that an installed agent can no longer be read (format drift).
    func deliverCannotRead(agentName: String, agentID: String) {
        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = "Can't read \(agentName)"
        content.body = "\(agentName) is running but its data format looks new — "
            + "updating Agent Babysitter may fix it."
        content.sound = .default
        center.add(UNNotificationRequest(identifier: "cannot-read-\(agentID)",
                                         content: content, trigger: nil))
    }

    /// Window name from its length, matching the menu's own labels.
    private static func windowLabel(minutes: Int) -> String {
        switch minutes {
        case ..<361: return "5-hour"
        case ..<(2 * 24 * 60): return "daily"
        case ..<(8 * 24 * 60): return "weekly"
        default: return "monthly"
        }
    }

    private func body(for event: NotificationEvent, row: SessionRow,
                      stallMinutes: Int) -> String {
        // With Precision mode on, the hook payload tells us what the agent
        // actually said — a banner you can act on without switching windows.
        let detail = freshDetail(row)
        switch event.kind {
        case .waitingForInput:
            if let detail, detail.kind == .waitingForInput {
                return "\(row.projectName): \(detail.text)"
            }
            return "Session \(row.projectName) needs your input."
        case .turnCompleted:
            if let detail, detail.kind == .turnCompleted {
                return "\(row.projectName) done: \(detail.text)"
            }
            if row.cost.hasUnknownPricing || row.cost.dollars == 0 {
                return "Session \(row.projectName) finished its turn."
            }
            return "Session \(row.projectName) finished its turn (cost \(money(row.cost.dollars)))."
        case .stalled:
            return "Session \(row.projectName) has produced nothing for \(stallMinutes) min."
        }
    }

    /// The hook detail, only when it plausibly belongs to this event
    /// (right kind, captured within the last couple of minutes).
    private func freshDetail(_ row: SessionRow) -> (kind: HookSignal.Kind, text: String)? {
        guard let signal = row.hookDetail, let text = signal.detail,
              Date().timeIntervalSince(signal.timestamp) < 150 else { return nil }
        return (signal.kind, text)
    }

    private func requestAuthorizationIfNeeded() {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        // "Jump to it" focuses the session's terminal/app; snooze re-alerts.
        let jump = UNNotificationAction(identifier: "jump", title: "Jump to it",
                                        options: [.foreground])
        let snooze = UNNotificationAction(identifier: "snooze10",
                                          title: "Remind me in 10 min")
        // "Update now" opens the download; dismissing is "Later".
        let updateNow = UNNotificationAction(identifier: "update-now", title: "Update now",
                                             options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "session-event", actions: [jump, snooze],
                                   intentIdentifiers: []),
            UNNotificationCategory(identifier: "update", actions: [updateNow],
                                   intentIdentifiers: []),
        ])
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let request = response.notification.request
        // Update banner: any tap (or "Update now") opens the download page;
        // dismissing it is "Later".
        if let urlString = request.content.userInfo["updateURL"] as? String,
           response.actionIdentifier != UNNotificationDismissActionIdentifier,
           let url = URL(string: urlString) {
            completionHandler()
            Task { @MainActor in NSWorkspace.shared.open(url) }
            return
        }
        let sessionID = request.content.userInfo["sessionID"] as? String
        if response.actionIdentifier == "snooze10" {
            // Same banner again in ten minutes.
            let redelivery = UNNotificationRequest(
                identifier: request.identifier + "-snoozed",
                content: request.content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 600, repeats: false))
            center.add(redelivery)
            completionHandler()
            return
        }
        completionHandler()
        guard let sessionID else { return }
        Task { @MainActor in
            if let row = await self.rowProvider?(sessionID) {
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
