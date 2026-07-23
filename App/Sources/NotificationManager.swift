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
    /// Wired by AppModel: bring the app's popover/Stats forward when the user
    /// taps an alert that isn't tied to a single session (limit / pace /
    /// budget / digest / can't-read). Without this, those banners are dead
    /// ends; we fall back to activating the app so a tap is never a no-op.
    var onOpenApp: (() -> Void)?
    /// Wired by AppModel: run an update check when the user taps "Check for
    /// update" on a can't-read banner (route to UpdateChecker).
    var onCheckForUpdate: (() -> Void)?

    // MARK: - Authorization surface (verified against UNUserNotificationCenter)

    /// Last status read from the system; `.notDetermined` until refreshed.
    /// `.notDetermined` is treated as deliverable on purpose so first-run
    /// delivery still triggers the OS prompt; only an explicit `.denied`
    /// gates delivery off.
    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    /// Gate ALL delivery and ALL "already alerted / fired / digest" persistence
    /// on this. False only when the system will silently drop everything we
    /// post — so the app never burns a one-shot alert (85%-of-limit, weekly
    /// digest, spend-guard) against a center that can't deliver it.
    var canDeliver: Bool { authorizationStatus != .denied }

    /// AppModel sets this to mirror status into a @Published for the menu /
    /// Notifications-tab "alerts are blocked" banner.
    var onAuthorizationChange: ((UNAuthorizationStatus) -> Void)?

    /// Read the system's notification settings and update `authorizationStatus`;
    /// fire `onAuthorizationChange` only when it actually changes. Call at
    /// launch, on app-foreground, and when the Notifications settings tab
    /// appears.
    func refreshAuthorizationStatus() async {
        let settings = await center.notificationSettings()
        let new = settings.authorizationStatus
        guard new != authorizationStatus else { return }
        authorizationStatus = new
        onAuthorizationChange?(new)
    }

    /// Rows that left the list take their delivered banners along.
    func removeDelivered(sessionIDs: [String]) {
        center.removeDeliveredNotifications(
            withIdentifiers: sessionIDs.map { "session-\($0)" })
    }

    /// Clear a session's banner AND any pending snooze re-delivery. Call when
    /// the row departs OR leaves the waiting state — otherwise a snoozed
    /// "still needs your input" fires ten minutes after the session already
    /// finished. The snooze request id is deterministic (`session-<id>` plus
    /// the `-snoozed` suffix added in the tap handler), so both are removable.
    func cancelNotifications(sessionIDs: [String]) {
        let ids = sessionIDs.flatMap { ["session-\($0)", "session-\($0)-snoozed"] }
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    private let center = UNUserNotificationCenter.current()
    private var authorizationRequested = false

    /// Ask once at launch so the app appears in Notification settings before
    /// the first alert would fire. On the very first launch, follow up with a
    /// single pointer to the menu bar — but only once the user has actually
    /// granted permission: a welcome banner posted after "Don't Allow" is
    /// silently dropped, burning the one-shot pointer and leaving a new user
    /// with no way to find the app.
    func primeAuthorization() {
        let defaults = UserDefaults.standard
        let needWelcome = !defaults.bool(forKey: "welcomeNotificationSent")
        requestAuthorizationIfNeeded { [weak self] granted in
            guard let self, needWelcome, granted else { return }
            defaults.set(true, forKey: "welcomeNotificationSent")
            let content = UNMutableNotificationContent()
            content.body = "Agent Babysitter is running - click the icon in your "
                + "menu bar to see your AI agents. No setup needed."
            self.center.add(UNNotificationRequest(
                identifier: "welcome", content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)))
        }
    }

    /// `hideTranscriptText` drops any quoted agent output / user prompt back to
    /// the generic "Session <project> needs your input" copy — the opt-out for
    /// users who screen-share or present and don't want transcript text on a
    /// banner or lock screen. Defaults to false (current behaviour) so the
    /// existing AppModel call site is unaffected until it passes the pref.
    func deliver(_ events: [NotificationEvent], rows: [SessionRow],
                 muted: Bool, enabledKinds: Set<NotificationEvent.Kind>,
                 stallThresholdMinutes: Int, hideTranscriptText: Bool = false) {
        guard !muted, !events.isEmpty else { return }
        requestAuthorizationIfNeeded()

        let rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        for event in events where enabledKinds.contains(event.kind) {
            guard let row = rowsByID[event.sessionID] else { continue }
            let content = UNMutableNotificationContent()
            content.body = body(for: event, row: row, stallMinutes: stallThresholdMinutes,
                                hideTranscriptText: hideTranscriptText)
            content.userInfo = ["sessionID": event.sessionID]
            content.sound = .default
            content.categoryIdentifier = "session-event"
            // 🟡 needs-you and 🔴 stuck are the reason the app exists, so let
            // them pierce a macOS Focus mode (the deep-work state in which a
            // blocked agent is most likely to sit idle). 🔵 finished is
            // nice-to-know, so it stays `.active` and honours Focus.
            content.interruptionLevel = (event.kind == .turnCompleted) ? .active : .timeSensitive
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
    func deliverWaitingReminder(row: SessionRow, minutes: Int,
                                hideTranscriptText: Bool = false) {
        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.body = (hideTranscriptText ? nil : row.title)
            .map { "Still waiting for you (\(minutes) min): “\($0)” — \(row.projectName)." }
            ?? "Still waiting for you (\(minutes) min): session \(row.projectName)."
        content.userInfo = ["sessionID": row.id]
        content.sound = .default
        content.categoryIdentifier = "session-event"
        content.interruptionLevel = .timeSensitive
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
        content.interruptionLevel = .timeSensitive
        center.add(UNNotificationRequest(
            identifier: "spend-\(suggestion.id)-\(String(describing: suggestion.kind))",
            content: content, trigger: nil))
    }

    /// "Claude Code is at 82% of its 5-hour limit." One identifier per agent
    /// per window kind so re-alerts replace rather than stack. The window is
    /// named from its length by the same Core table the menu row uses (Codex
    /// weekly, Cursor billing cycle, Manus daily), so the banner and the row
    /// under it always call it the same thing.
    func deliverLimitAlert(agentName: String, agentID: String,
                           usedPercent: Double, resetsAt: Date?,
                           windowMinutes: Int = 300, isWeekly: Bool = false) {
        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        let kind = isWeekly ? "weekly" : "primary"
        let window = Self.windowLabel(minutes: windowMinutes, isWeekly: isWeekly)
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
        // Running out of quota is time-critical, and a tap should open the app
        // rather than do nothing (the "alert" category carries that action).
        content.interruptionLevel = .timeSensitive
        content.categoryIdentifier = "alert"
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
        let window = Self.windowLabel(minutes: windowMinutes, isWeekly: isWeekly)
        let earlyText = MenuContent.humanDuration(resetsAt.timeIntervalSince(exhaustionAt))
        content.body = "\(agentName) is at \(Int(usedPercent))% and on pace to hit its "
            + "\(window) limit at \(Self.clockTime(exhaustionAt)) — "
            + "\(earlyText) before it resets."
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.categoryIdentifier = "alert"
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
        // An update is informational, not time-critical — don't let it override
        // a Focus mode the way a stuck agent does.
        content.interruptionLevel = .passive
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
        // A weekly recap is a gentle, non-urgent note; keep it out of Focus.
        // The "alert" category still gives its tap somewhere to go.
        content.interruptionLevel = .passive
        content.categoryIdentifier = "alert"
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
        content.interruptionLevel = .timeSensitive
        content.categoryIdentifier = "alert"
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
        // The one banner a confused user most needs to act on — give it a
        // "Check for update" button instead of leaving it a dead end.
        content.categoryIdentifier = "diagnostic"
        center.add(UNNotificationRequest(identifier: "cannot-read-\(agentID)",
                                         content: content, trigger: nil))
    }

    /// Window name from its length. Delegates to Core so a banner can't name a
    /// window differently from the menu row it fires under: this used to
    /// return "monthly" for a 30-day window the menu captioned "billing
    /// cycle", which reads as two separate limits rather than one.
    /// `isWeekly` names the agent's secondary 7-day window, whatever the
    /// primary's length is.
    private static func windowLabel(minutes: Int, isWeekly: Bool) -> String {
        (isWeekly ? UsageWindowName.secondaryWeekly
                  : UsageWindowName.forWindow(minutes: minutes)).phrase
    }

    private func body(for event: NotificationEvent, row: SessionRow,
                      stallMinutes: Int, hideTranscriptText: Bool) -> String {
        // With Precision mode on, the hook payload tells us what the agent
        // actually said — a banner you can act on without switching windows.
        // `hideTranscriptText` suppresses that so nothing the agent said (or
        // the user asked) reaches a shared screen or lock screen.
        let detail = hideTranscriptText ? nil : freshDetail(row)
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

    /// Ask for permission exactly once and register the tap-action categories.
    /// The `then` completion runs on the grant/deny result (used by
    /// `primeAuthorization` to post the welcome only when granted); it also
    /// refreshes `authorizationStatus` from the completion so a first-launch
    /// "Don't Allow" gates delivery on the very next tick instead of waiting
    /// for the next app-foreground.
    private func requestAuthorizationIfNeeded(then completion: (@MainActor (Bool) -> Void)? = nil) {
        guard !authorizationRequested else {
            completion?(authorizationStatus == .authorized)
            return
        }
        authorizationRequested = true
        center.delegate = self
        registerCategories()
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in
                await self?.refreshAuthorizationStatus()
                completion?(granted)
            }
        }
    }

    /// Tap actions, split by what the banner is about. Session/spend banners
    /// jump to the terminal or snooze; alert banners open the app; the
    /// diagnostic banner offers an update check.
    private func registerCategories() {
        // "Jump to it" focuses the session's terminal/app; snooze re-alerts.
        let jump = UNNotificationAction(identifier: "jump", title: "Jump to it",
                                        options: [.foreground])
        let snooze = UNNotificationAction(identifier: "snooze10",
                                          title: "Remind me in 10 min")
        // "Update now" opens the download; dismissing is "Later".
        let updateNow = UNNotificationAction(identifier: "update-now", title: "Update now",
                                             options: [.foreground])
        let openApp = UNNotificationAction(identifier: "open-app",
                                           title: "Open Agent Babysitter", options: [.foreground])
        let checkUpdate = UNNotificationAction(identifier: "check-update",
                                               title: "Check for update", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "session-event", actions: [jump, snooze],
                                   intentIdentifiers: []),
            UNNotificationCategory(identifier: "update", actions: [updateNow],
                                   intentIdentifiers: []),
            UNNotificationCategory(identifier: "alert", actions: [openApp],
                                   intentIdentifiers: []),
            UNNotificationCategory(identifier: "diagnostic", actions: [checkUpdate],
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
        // "Check for update" on a can't-read banner runs the updater rather
        // than sending the user hunting for the release page.
        if response.actionIdentifier == "check-update" {
            completionHandler()
            Task { @MainActor in self.onCheckForUpdate?() }
            return
        }
        let sessionID = request.content.userInfo["sessionID"] as? String
        if response.actionIdentifier == "snooze10" {
            // Same banner again in ten minutes. The `-snoozed` suffix makes the
            // pending request removable by `cancelNotifications` once the
            // session leaves the waiting state or departs the list.
            let redelivery = UNNotificationRequest(
                identifier: request.identifier + "-snoozed",
                content: request.content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 600, repeats: false))
            center.add(redelivery)
            completionHandler()
            return
        }
        completionHandler()
        guard let sessionID else {
            // Limit / pace / budget / digest / can't-read banners aren't tied
            // to a single session; a tap should still surface the app rather
            // than do nothing. Prefer AppModel's opener; fall back to bringing
            // the app forward so the click is never a silent no-op.
            Task { @MainActor in
                if let onOpenApp = self.onOpenApp {
                    onOpenApp()
                } else {
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            return
        }
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
