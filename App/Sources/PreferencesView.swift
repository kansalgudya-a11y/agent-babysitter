import SwiftUI
import AgentBabysitterCore

struct PreferencesView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @StateObject private var license = LicenseManager()
    @StateObject private var updates = UpdateChecker()
    @State private var licenseKeyInput = ""

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
                Picker("Show costs as", selection: $model.costsArePlanValue) {
                    Text("Plan value").tag(true)
                    Text("API cost").tag(false)
                }
                if model.costsArePlanValue {
                    Text("Costs are the estimated value of your usage at API list prices. On a subscription (Pro/Max/Plus) you aren't billed per token — this is what that usage would cost on the API.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle(isOn: $model.syncStatsViaICloud) {
                    Text("Sync stats across my Macs (iCloud Drive)")
                    Text("Merges the stats totals from each of your Macs via a small file in iCloud Drive, so \"all time\" spans every machine. Only aggregate numbers — no session content — are stored.")
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
        let base = hour % 12 == 0 ? 12 : hour % 12
        return "\(base) \(hour < 12 ? "AM" : "PM")"
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
                    BudgetField(symbol: model.currency.symbol, initial: model.dailyBudget) {
                        model.dailyBudget = $0
                    }
                } label: {
                    Text("💸 Daily spend goes over")
                    Text("One heads-up per day when today's estimated cost crosses this. Leave empty to turn off.")
                }
                LabeledContent {
                    BudgetField(symbol: model.currency.symbol, initial: model.weeklyBudget) {
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
                    Text("Off by default, everything else stays fully offline. When on, the app uses your existing logins to fetch real usage: Claude via a tiny 1-token request to api.anthropic.com (5-hour + weekly %), Cursor's included-usage % from cursor.com, and your Manus credit balance from api.manus.im. Each read-only, each only its own vendor. Codex and Antigravity already show real usage with no network.")
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
                Text("Everything runs on your Mac. Agent Babysitter makes no network connections and collects nothing.")
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
                    let defaults = UserDefaults.standard
                    let report = """
                    Agent Babysitter \(updates.currentVersion)
                    limits: \(defaults.string(forKey: "debugUsageLimits") ?? defaults.dictionary(forKey: "debugUsageLimits").map(String.init(describing:)) ?? "-")
                    agents: \(defaults.string(forKey: "debugAgents") ?? "-")
                    toggles: precision=\(model.precisionModeEnabled) meter=\(model.claudeUsageMeterEnabled) live=\(model.liveUsageEnabled) alerts=\(model.notifyLimit)@\(Int(model.limitAlertThreshold))% pace=\(model.notifyPace)
                    """
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                }
                .help("Copies version, current readings, and toggle states — paste into a bug report. Contains no file contents or keys.")
            }
    }
}
