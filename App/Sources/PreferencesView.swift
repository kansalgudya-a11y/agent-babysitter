import SwiftUI
import AgentBabysitterCore
import UserNotifications

struct PreferencesView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @StateObject private var license = LicenseManager()
    @StateObject private var updates = UpdateChecker()
    @State private var licenseKeyInput = ""
    // F2: destructive actions are gated behind a confirmation alert each, so a
    // stray click can never wipe settings or recorded history unprompted.
    @State private var showResetConfirm = false
    @State private var showDeleteConfirm = false

    var body: some View {
        TabView {
            Form {
                generalTab
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                notificationsTab
            }
            .formStyle(.grouped)
            .tabItem { Label("Notifications", systemImage: "bell.badge") }

            Form {
                advancedTab
            }
            .formStyle(.grouped)
            .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }

            Form {
                licenseTab
            }
            .formStyle(.grouped)
            .tabItem { Label("License & Updates", systemImage: "checkmark.seal") }
        }
        .frame(width: 480, height: 420)
    }

    /// A budget amount field. Edits a plain string so typing (incl. decimals)
    /// is smooth, and applies to the model on a short debounce — so typing
    /// "150" doesn't briefly set the budget to 1 then 15 (which could fire a
    /// premature over-budget alert and churn UserDefaults on every keystroke).
    /// Commits immediately on Return.
    struct BudgetField: View {
        let symbol: String
        let initial: Double
        let apply: (Double) -> Void
        @State private var text = ""
        @State private var debounce: Task<Void, Never>?

        var body: some View {
            HStack(spacing: 4) {
                Text(symbol).foregroundStyle(.secondary)
                TextField("", text: $text, prompt: Text("Off"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1)
                    .frame(width: 90)
                    .multilineTextAlignment(.trailing)
                    .onChange(of: text) { _, new in
                        debounce?.cancel()
                        debounce = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 700_000_000)
                            guard !Task.isCancelled else { return }
                            apply(BudgetInput.parse(new))
                        }
                    }
                    .onSubmit {
                        debounce?.cancel()
                        apply(BudgetInput.parse(text))
                    }
            }
            .onAppear { text = BudgetInput.format(initial) }
            .onDisappear {
                debounce?.cancel()
                apply(BudgetInput.parse(text))
            }
        }
    }

    @ViewBuilder private var generalTab: some View {
            Section("General") {
                Toggle("Start Agent Babysitter when I log in", isOn: $model.launchAtLogin)
                    .hapticTick(on: model.launchAtLogin)
                Toggle(isOn: $model.hotKeyEnabled) {
                    Text("Jump to the neediest session with a hotkey")
                    Text("From anywhere: focuses the session that's waiting for you (or stuck, or working).")
                }
                .hapticTick(on: model.hotKeyEnabled)
                if model.hotKeyEnabled {
                    Picker("Hotkey", selection: $model.hotKeyCombo) {
                        ForEach(HotKeyManager.combos, id: \.id) { combo in
                            Text(combo.label).tag(combo.id)
                        }
                    }
                }
                Picker("Hide finished sessions after", selection: $model.doneAutoHideMinutes) {
                    Text("Immediately").tag(-1.0)
                    Text("5 minutes").tag(5.0)
                    Text("10 minutes").tag(10.0)
                    Text("30 minutes").tag(30.0)
                    Text("1 hour").tag(60.0)
                    Text("Never").tag(0.0)
                }
                Picker("Show in the menu bar", selection: $model.menuBarStyle) {
                    Text("Status + count").tag("status")
                    Text("Today's cost").tag("cost")
                    // The number behind this style is the max across EVERY
                    // agent's primary window, whatever its length — on an
                    // account with Codex installed it is usually the weekly
                    // one. Naming it "5h" made the menu bar contradict the
                    // row it came from.
                    Text("Hottest limit %").tag("limit")
                    Text("7-day cost trend").tag("trend")
                }
                Picker("Currency", selection: $model.currencyCode) {
                    ForEach(Currency.catalog, id: \.code) { currency in
                        Text("\(currency.symbol)  \(currency.code) — \(currency.name)")
                            .tag(currency.code)
                    }
                }
                if model.currencyCode != "USD" {
                    Text("Costs are estimated in US dollars from token usage, then converted live at the latest exchange rate — refreshed automatically while the app runs and each time you open it. USD stays fully offline; other currencies fetch rates (no personal data sent).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // A checkbox, not a two-option picker: this flips a wording
                // label only — the number is identical either way. The old
                // "Show costs as: Plan value / API cost" picker implied a
                // different figure and lost trust when the total didn't move.
                Toggle(isOn: $model.costsArePlanValue) {
                    Text("Label costs as plan value")
                    Text("Doesn't change any number — only the wording. On a subscription (Pro/Max/Plus) you aren't billed per token; \"plan value\" is what that usage would cost at API list prices.")
                }
                .hapticTick(on: model.costsArePlanValue)
                Toggle(isOn: $model.syncStatsViaICloud) {
                    Text("Sync stats across my Macs (iCloud Drive)")
                    Text("Merges the stats totals from each of your Macs via a small file in iCloud Drive, so \"all time\" spans every machine. It stores cost and session totals broken down by agent, model, and project — which includes the names of the projects you work in — but never any session content, prompts, or transcripts.")
                }
                .hapticTick(on: model.syncStatsViaICloud)
                Button("Show the feature tour") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "welcome")
                }
                Button("Session history…") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "history")
                }
            }

    }

    static func hourLabel(_ hour: Int) -> String {
        // Render the hour in the system's own hour cycle instead of a hardcoded
        // 12-hour AM/PM: Date.FormatStyle.hour() follows the locale, so a 24-hour
        // region shows "09" and a 12-hour region shows "9 AM".
        let cal = Calendar.current
        let base = cal.startOfDay(for: Date())
        let date = cal.date(bySettingHour: hour, minute: 0, second: 0, of: base) ?? base
        return date.formatted(.dateTime.hour())
    }

    @ViewBuilder private var notificationsTab: some View {
            Section {
                Toggle(isOn: $model.notifyWaiting) {
                    Text("🟡 An agent needs my input")
                    Text("A question or a permission prompt is waiting for you.")
                }
                .hapticTick(on: model.notifyWaiting)
                Toggle(isOn: $model.waitingReminderEnabled) {
                    Text("Remind me if it's still waiting")
                    Text("One follow-up per question if you haven't acted after the time below — so a blocked agent never sits unnoticed.")
                }
                .hapticTick(on: model.waitingReminderEnabled)
                if model.waitingReminderEnabled {
                    Picker("Remind after", selection: $model.waitingReminderMinutes) {
                        Text("5 minutes").tag(5.0)
                        Text("10 minutes").tag(10.0)
                        Text("15 minutes").tag(15.0)
                        Text("30 minutes").tag(30.0)
                    }
                }
                Toggle(isOn: $model.notifyDone) {
                    Text("🔵 An agent finishes")
                    Text("Its reply is ready to read.")
                }
                .hapticTick(on: model.notifyDone)
                Toggle(isOn: $model.notifyStalled) {
                    Text("🔴 An agent looks stuck")
                    Text("Mid-task but silent for too long (time set below).")
                }
                .hapticTick(on: model.notifyStalled)
                Toggle(isOn: $model.spendGuardEnabled) {
                    Text("💸 An agent is spending fast")
                    Text("A nudge — never a pause — when a session burns money quickly or passes the budget below. It only suggests; your work keeps running.")
                }
                .hapticTick(on: model.spendGuardEnabled)
                if model.spendGuardEnabled {
                    Picker("Nudge once a session passes", selection: $model.spendGuardBudget) {
                        Text("$10").tag(10.0)
                        Text("$25").tag(25.0)
                        Text("$50").tag(50.0)
                        Text("$100").tag(100.0)
                    }
                }
                Toggle(isOn: $model.notifyLimit) {
                    // Governs every window an agent meters, not just Claude's
                    // 5-hour one: Codex's week and Cursor's billing cycle
                    // alert through this same switch.
                    Text("⚠️ An agent nears a usage limit")
                    Text("One heads-up per window when usage crosses the level below — for each agent's own window, whether that's five hours, a day, a week, or a billing cycle — so a long task doesn't burn the whole window unnoticed.")
                }
                .hapticTick(on: model.notifyLimit)
                if model.notifyLimit {
                    HStack {
                        Slider(value: $model.limitAlertThreshold, in: 50...95, step: 5) {
                            Text("Warn at")
                        }
                        .hapticTick(on: model.limitAlertThreshold)
                        Text("\(Int(model.limitAlertThreshold))%")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                Toggle(isOn: $model.notifyPace) {
                    Text("⏱ An agent is on pace to run out")
                    Text("Predicts the pace early: one heads-up with the time the limit would hit — before the wall, not after.")
                }
                .hapticTick(on: model.notifyPace)
                // These floors also gate the "on pace to hit the limit"
                // lines in the menu, so they stay visible even when the
                // notification toggle above is off.
                // Two floors, split by window LENGTH rather than by agent —
                // the stored keys are still paceFiveHourFloor/paceWeeklyFloor,
                // but neither has been 5-hour-or-weekly-only since Manus (a
                // daily quota) and Cursor (a monthly billing cycle) shipped.
                // The help text names the split by the WORD the row shows
                // ("5h"/"daily" vs "weekly"/"billing cycle") rather than by a
                // duration, because that word is literally the boundary:
                // UsageWindowName.isLong is what both the menu's pace line and
                // PaceAlertPlanner route on. Describing it as "refills within
                // a day" was already wrong for a 36-hour window, and would
                // have gone properly wrong for the first 2-to-7-day one.
                HStack {
                    Slider(value: $model.paceFiveHourFloor, in: 0...90, step: 5) {
                        Text("Short window pace from")
                    }
                    .hapticTick(on: model.paceFiveHourFloor)
                    Text(model.paceFiveHourFloor == 0 ? "always"
                         : "\(Int(model.paceFiveHourFloor))%")
                        .monospacedDigit()
                        .frame(width: 52, alignment: .trailing)
                }
                .help("Short windows are the ones a row calls \"5h\" or \"daily\" — Claude's five hours, Manus's daily quota. Show their pace line in the menu once the window is this full: green when the pace is fine, orange/red when it would hit the limit early. 0% shows it whenever a pace can be measured. Pace alerts additionally wait until at least 30%.")
                HStack {
                    Slider(value: $model.paceWeeklyFloor, in: 0...90, step: 5) {
                        Text("Long window pace from")
                    }
                    .hapticTick(on: model.paceWeeklyFloor)
                    Text(model.paceWeeklyFloor == 0 ? "always"
                         : "\(Int(model.paceWeeklyFloor))%")
                        .monospacedDigit()
                        .frame(width: 52, alignment: .trailing)
                }
                .help("Long windows are the ones a row calls \"weekly\" or \"billing cycle\" — Codex's weekly window, Cursor's monthly billing cycle, and the weekly window Claude publishes alongside its five-hour one. Show their pace line in the menu once the window is this full. Pace alerts additionally wait until at least 30%.")
                Toggle(isOn: $model.weeklyDigestEnabled) {
                    Text("📊 Weekly summary")
                    Text("One Sunday-evening note: the week's estimated cost, session count, and busiest project.")
                }
                .hapticTick(on: model.weeklyDigestEnabled)
                LabeledContent {
                    // displayCurrency + effectiveRate are the exact pair the
                // compare-time conversion divides by (AppModel.deliverBudgetAlerts),
                // so the symbol shown here never disagrees with the divisor —
                // unlike `currency`, which can name a currency whose rate hasn't
                // landed yet. See Contract 3.
                BudgetField(symbol: model.displayCurrency.symbol, initial: model.dailyBudget) {
                        model.dailyBudget = $0
                    }
                } label: {
                    Text("💸 Daily spend goes over")
                    Text("One heads-up per day when today's estimated cost crosses this. Leave empty to turn off.")
                }
                LabeledContent {
                    BudgetField(symbol: model.displayCurrency.symbol, initial: model.weeklyBudget) {
                        model.weeklyBudget = $0
                    }
                } label: {
                    Text("💸 Weekly spend goes over")
                    Text("Same, for the last 7 days combined.")
                }
            } header: {
                Text("Notify me when…")
            } footer: {
                Text("The bell button in the menu pauses all of these at once. Budgets are in your display currency; 0 turns a budget off.")
            }

            Section {
                Toggle(isOn: $model.quietHoursEnabled) {
                    Text("Quiet hours")
                    Text("Silence every banner during these hours — the menu keeps updating live, you just won't get pinged overnight.")
                }
                .hapticTick(on: model.quietHoursEnabled)
                if model.quietHoursEnabled {
                    HStack {
                        Picker("From", selection: $model.quietStartHour) {
                            ForEach(0..<24) { Text(Self.hourLabel($0)).tag($0) }
                        }
                        Picker("to", selection: $model.quietEndHour) {
                            ForEach(0..<24) { Text(Self.hourLabel($0)).tag($0) }
                        }
                    }
                    // Both pickers are free 0–23, so From == To is one stray
                    // click away — and it means quiet ALL DAY. Say so, or a
                    // mis-set picker silently swallows every alert forever,
                    // which is the worst failure mode this app has.
                    if model.quietStartHour == model.quietEndHour {
                        Text("⚠️ Same From and To means quiet all day — no banners at all. Set different hours to be pinged again.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section("Stuck detection") {
                HStack {
                    Slider(value: $model.stallThresholdMinutes, in: 1...30, step: 1) {
                        Text("Consider an agent stuck after")
                    }
                    .hapticTick(on: model.stallThresholdMinutes)
                    Text("\(Int(model.stallThresholdMinutes)) min")
                        .monospacedDigit()
                        .frame(width: 52, alignment: .trailing)
                }
                Text("How long an agent can stay silent mid-task before it shows as 🔴. Shorter catches problems faster; longer avoids false alarms on big tasks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

    }

    @ViewBuilder private var advancedTab: some View {
            Section {
                Toggle(isOn: $model.precisionModeEnabled) {
                    Text("Exact status from Claude Code")
                    Text("Uses Claude Code's own notifications so \"needs you\" and \"done\" are exact instead of inferred. Adds one small entry to Claude Code's settings; your other settings are never touched, and turning this off removes only our entry.")
                }
                .hapticTick(on: model.precisionModeEnabled)
                Toggle(isOn: $model.claudeUsageMeterEnabled) {
                    Text("Claude usage meter (works offline)")
                    Text("Shows your real 5-hour usage % with no internet, by recording the numbers Claude Code computes for its terminal status line. It updates whenever a Claude session runs in a terminal — the % covers your whole account, so it reflects desktop app usage too. If you only ever use the desktop app, turn on Live usage below instead. Your own status line keeps working, and turning this off restores it exactly.")
                }
                .hapticTick(on: model.claudeUsageMeterEnabled)
                Toggle(isOn: $model.liveUsageEnabled) {
                    Text("Live usage % (connects to the internet)")
                    Text("Off by default, everything else stays fully offline. When on, the app uses your existing logins to fetch real usage, repeating about once every 5 minutes for as long as this stays on: Claude via a tiny 1-token request to api.anthropic.com (5-hour + weekly %), Cursor's included-usage % from cursor.com, and your Manus credit balance from api.manus.im. Each read-only, each only its own vendor. Codex and Antigravity already show real usage with no network.")
                }
                .hapticTick(on: model.liveUsageEnabled)
                if model.liveUsageEnabled, let status = model.liveUsageStatus {
                    Label(status, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let error = model.hooksError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Advanced")
            } footer: {
                // "By default" is load-bearing: the webhook below is the one path
                // that, opt-in, can send a prompt off the Mac (question-text
                // toggle) — so the blanket "never leave" promise is qualified and
                // the webhook host is enumerated alongside every other trigger.
                Text("By default your transcripts and prompts stay on your Mac, and nothing about your usage is collected or uploaded. The app reaches the network only for these, each on its own trigger: currency rates from open.er-api.com while your display currency isn't USD; a daily update check to github.com (toggle it in License & Updates); Live usage above only when you turn it on (api.anthropic.com, cursor.com, api.manus.im); licence activation to api.lemonsqueezy.com only when you press Activate; and, only if you switch it on below, a single webhook URL you provide (status metadata only — or, if you also enable the separate question-text option there, the pending question). Everything else runs entirely on your Mac.")
            }

            // F7 — Remote push to a user-supplied webhook. Opt-in; the default
            // payload is metadata only. The URL is only ever typed by the user
            // here (never taken from any observed content).
            Section {
                Toggle(isOn: $model.webhookEnabled) {
                    Text("Send alerts to a webhook")
                    Text("Off by default. When on, the app POSTs a small status update to a URL you provide — your own server, or an ntfy.sh topic — so you can be pinged elsewhere (e.g. your phone). The default message contains only which agent, which project, its state, and the time: never prompts, transcripts, questions, or command lines. It follows the same alerts, mute, and quiet-hours rules as your local notifications.")
                }
                .hapticTick(on: model.webhookEnabled)
                if model.webhookEnabled {
                    TextField("Webhook URL", text: $model.webhookURLString,
                              prompt: Text("https://ntfy.sh/your-topic"))
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .lineLimit(1)
                    Toggle(isOn: $model.webhookIncludeQuestion) {
                        Text("Also include the pending question text")
                        Text("⚠️ This sends prompt content off your Mac. When on, the agent's actual question or prompt text is transmitted to the URL above — so use only an endpoint you fully control. Leave off to send status metadata only. Command lines are never sent, either way.")
                    }
                    .hapticTick(on: model.webhookIncludeQuestion)
                    // webhookIncludeQuestion defaults OFF (see AppModel); this
                    // extra red line makes the trade-off unmissable while it's on.
                    if model.webhookIncludeQuestion {
                        Label("Prompt text will be sent to your webhook.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    if let status = model.webhookStatus {
                        Label(status, systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Remote notifications")
            } footer: {
                Text("Opt-in. Use a URL that only you control. Standard ntfy.sh topics are public to anyone who knows the topic name, so pick an unguessable one or self-host.")
            }

            // F2 — Reset preferences / clear stored data. Both are confirmed and
            // both touch only this app's own settings and files.
            Section {
                Button("Reset all settings…") { showResetConfirm = true }
                Button("Delete stored data…", role: .destructive) { showDeleteConfirm = true }
            } header: {
                Text("Reset")
            } footer: {
                Text("Reset all settings returns every preference on every tab to its default. Delete stored data erases the cost and session history this app has recorded on your Mac — totals, per-agent and per-project breakdowns, session history, and the local event log. Neither touches any other app's data, and neither can be undone.")
            }
            .alert("Reset all settings?", isPresented: $showResetConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Reset", role: .destructive) { model.resetAllSettings() }
            } message: {
                Text("Every preference on every tab returns to its default. Your session-history file and recorded event log are left in place. This can't be undone.")
            }
            .alert("Delete stored data?", isPresented: $showDeleteConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) { model.deleteStoredData() }
            } message: {
                Text("This permanently erases the cost totals, per-agent and per-project breakdowns, session counts, session history, and local event log this app recorded on your Mac. Your preferences are kept. This can't be undone.")
            }

    }

    @ViewBuilder private var licenseTab: some View {
            Section {
                switch license.state {
                case .activated(let maskedKey):
                    LabeledContent("License") {
                        Label("Activated (key \(maskedKey))", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    }
                    Button("Deactivate on this Mac") {
                        Task { await license.deactivate() }
                    }
                    .disabled(license.busy)
                case .unlicensed:
                    LabeledContent("License") {
                        Text(LicenseManager.isBeta ? "Free beta — everything unlocked"
                                                   : "Not activated")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        TextField("License key", text: $licenseKeyInput)
                            .textFieldStyle(.roundedBorder)
                        Button("Activate") {
                            Task { await license.activate(key: licenseKeyInput) }
                        }
                        .disabled(license.busy || licenseKeyInput.isEmpty)
                    }
                }
                if let error = license.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("License")
            } footer: {
                Text("Activation contacts api.lemonsqueezy.com once, only when you press the button. Nothing else about your usage is ever sent.")
            }

            Section("About") {
                LabeledContent("Version") {
                    Text(updates.currentVersion)
                        .foregroundStyle(.secondary)
                }
                Toggle(isOn: $model.autoUpdateCheck) {
                    Text("Check for updates daily")
                    Text("Once a day, asks github.com if a newer version exists and notifies you if so (nothing about your usage is sent). Turn off to keep the app fully offline.")
                }
                .hapticTick(on: model.autoUpdateCheck)
                HStack {
                    Button("Check for updates") {
                        Task { await updates.check() }
                    }
                    .disabled(updates.status == .checking)
                    switch updates.status {
                    case .idle: EmptyView()
                    case .checking:
                        ProgressView().controlSize(.small)
                    case .upToDate(let version):
                        Text("You're on the latest version (\(version)).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .available(let version, let url, _):
                        Button("Get \(version)") { updates.openReleasePage(url) }
                            .buttonStyle(.link)
                    case .failed(let message):
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                if case .available(_, _, let notes) = updates.status, let notes {
                    Text("What's new:\n\(notes)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Copy diagnostics") {
                    // Async so we can read the live OS notification-authorization
                    // status: "I get no notifications" is the most common ticket,
                    // and .denied / quiet-hours / mute are exactly what the old
                    // dump omitted. No file contents or keys are included.
                    Task { @MainActor in
                        // Sendable enum only — see NotificationManager
                        // .currentAuthorizationStatus (Xcode 16 SDK treats
                        // UNNotificationSettings as non-Sendable).
                        let status = await NotificationManager.currentAuthorizationStatus(
                            UNUserNotificationCenter.current())
                        let auth: String
                        switch status {
                        case .authorized: auth = "authorized"
                        case .denied: auth = "denied — macOS silently drops every banner"
                        case .notDetermined: auth = "not yet requested"
                        case .provisional: auth = "provisional (quiet delivery)"
                        case .ephemeral: auth = "ephemeral"
                        @unknown default: auth = "unknown"
                        }
                        let defaults = UserDefaults.standard
                        let quiet = model.quietHoursEnabled
                            ? "on \(model.quietStartHour)–\(model.quietEndHour)" : "off"
                        let report = """
                        Agent Babysitter \(updates.currentVersion)
                        notifications: system=\(auth) muted=\(model.notificationsMuted) quietHours=\(quiet)
                        limits: \(defaults.string(forKey: "debugUsageLimits") ?? defaults.dictionary(forKey: "debugUsageLimits").map(String.init(describing:)) ?? "-")
                        agents: \(defaults.string(forKey: "debugAgents") ?? "-")
                        accuracy: precision=\(model.precisionModeEnabled) meter=\(model.claudeUsageMeterEnabled) live=\(model.liveUsageEnabled)
                        alerts: waiting=\(model.notifyWaiting) reminder=\(model.waitingReminderEnabled) done=\(model.notifyDone) stalled=\(model.notifyStalled) spendGuard=\(model.spendGuardEnabled) limit=\(model.notifyLimit)@\(Int(model.limitAlertThreshold))% pace=\(model.notifyPace) digest=\(model.weeklyDigestEnabled)
                        budgets: daily=\(model.dailyBudget) weekly=\(model.weeklyBudget) currency=\(model.currencyCode)
                        general: launchAtLogin=\(model.launchAtLogin) hideDoneMin=\(model.doneAutoHideMinutes) iCloudSync=\(model.syncStatsViaICloud)
                        """
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report, forType: .string)
                    }
                }
                .help("Copies version, current readings, notification permission, and toggle states — paste into a bug report. Contains no file contents or keys.")
            }
    }
}
