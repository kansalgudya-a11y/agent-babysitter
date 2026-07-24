import Foundation
import SwiftUI
import ServiceManagement
import UserNotifications
import AgentBabysitterCore

/// Main-actor view model: owns the store and watchers, republishes their
/// state for SwiftUI. All heavy lifting stays in AgentBabysitterCore.
/// An installed agent whose data we've lost the ability to read.
struct UnreadableAgent: Identifiable, Equatable {
    let id: String
    let name: String
}

@MainActor
final class AppModel: ObservableObject {

    @Published private(set) var rows: [SessionRow] = []
    @Published private(set) var summary = MenuBarSummary(worstState: nil, activeCount: 0)
    @Published private(set) var processDetectionDegraded = false
    @Published private(set) var noAgentsDetected = false
    @Published private(set) var todayCost = SessionCost()
    @Published private(set) var usageLimits: [String: UsageLimitSnapshot] = [:]
    /// Agents whose files exist on this Mac, in display order.
    @Published private(set) var installedAgents: [(id: String, name: String)] = []
    /// The usage-limits list's agents: installed, minus the ones that record
    /// no quota anywhere (Hermes, both OpenClaw surfaces — they could only
    /// ever read "not shared by this app"). Kept separate from
    /// `installedAgents`, which still drives session rows, cost, drift checks,
    /// and notification names for every installed agent. Derived rather than
    /// published: `installedAgents` is already @Published, so SwiftUI
    /// re-renders on change, and `adapters` is a stored let that is populated
    /// in the snapshot harness too.
    var usageAgents: [(id: String, name: String)] {
        let muted = Set(adapters.filter { !$0.publishesUsageLimit }.map(\.id))
        return installedAgents.filter { !muted.contains($0.id) }
    }
    /// Installed agents that CAN raise needs-you / finished / stuck banners —
    /// they publish turn boundaries. The delivery gate already drops
    /// activity-based rows (`rows.filter { !$0.isActivityBased }`), so these two
    /// lists are the honest coverage the Notifications tab shows under the three
    /// state toggles, derived from the private `adapters` capability flags.
    var notifiableAgentNames: [String] {
        let notifiable = Set(adapters.filter { !$0.isActivityBased }.map(\.id))
        return installedAgents.filter { notifiable.contains($0.id) }.map(\.name)
    }
    /// Installed agents that can NEVER produce a lifecycle banner — Cursor,
    /// Manus, Gemini, Antigravity infer activity from write gaps and expose no
    /// turn boundaries. Named so the UI can say so instead of leaving a ticked
    /// toggle that silently never fires for them.
    var activityOnlyAgentNames: [String] {
        let activityOnly = Set(adapters.filter { $0.isActivityBased }.map(\.id))
        return installedAgents.filter { activityOnly.contains($0.id) }.map(\.name)
    }
    /// Agents with a live process right now — their app/CLI is open.
    @Published private(set) var runningAgentIDs: Set<String> = []
    /// Observed daily cost totals, oldest first, at most 7 days. Accumulated
    /// locally — the store only retains 24h of sessions.
    @Published private(set) var costHistory: [(day: Date, dollars: Double)] = [] {
        didSet { rebuildSparkline() }
    }
    /// Pre-rendered 7-day cost trend for the "trend" menu-bar style — drawn
    /// once per history change (and only while that style is active), not per
    /// label render.
    @Published private(set) var sparklineImage: NSImage?

    private func rebuildSparkline() {
        sparklineImage = menuBarStyle == "trend"
            ? Sparkline.image(dailyDollars: costHistory.map(\.dollars)) : nil
    }
    /// Full per-day stats history (kept indefinitely, local-day buckets):
    /// per-agent dollars, session counts, and active minutes.
    @Published private(set) var statsDays: [DayStat] = []
    private var lastActiveTick = Date()
    @Published var liveUsageEnabled: Bool {
        didSet {
            UserDefaults.standard.set(liveUsageEnabled, forKey: "liveUsageEnabled")
            Task { await self.refreshLiveUsage(forceFetch: true) }
        }
    }
    /// Why the last live fetch produced nothing — shown under the toggle.
    @Published private(set) var liveUsageStatus: String?
    @Published var notifyLimit: Bool {
        didSet { UserDefaults.standard.set(notifyLimit, forKey: "notifyLimit") }
    }
    @Published var limitAlertThreshold: Double {
        didSet { UserDefaults.standard.set(limitAlertThreshold, forKey: "limitAlertThreshold") }
    }
    @Published var notifyPace: Bool {
        didSet { UserDefaults.standard.set(notifyPace, forKey: "notifyPace") }
    }
    /// "Show pace from N%" — below this the projection is treated as
    /// early-window noise. Two knobs split by window LENGTH, not by agent: the
    /// first covers windows that refill within a day (Claude's 5 hours, Manus's
    /// daily quota), the second a week or more (Codex weekly, Cursor's billing
    /// cycle, and any agent's secondary weekly window). The stored keys keep
    /// their original names so existing preferences survive.
    /// Both gate the menu caption and the pace notification alike, and both
    /// route a window the SAME way — through `UsageWindowName.isLong`, the
    /// boundary the row's own caption is named from. They used to disagree:
    /// `PaceAlertPlanner` applied the short floor to every primary window
    /// whatever its length, so on Codex (whose primary IS the weekly window) a
    /// long floor of 90% with a short floor of 0% silenced the menu's pace
    /// line at 45% while the banner still fired.
    @Published var paceFiveHourFloor: Double {
        didSet { UserDefaults.standard.set(paceFiveHourFloor, forKey: "paceFiveHourFloor") }
    }
    @Published var paceWeeklyFloor: Double {
        didSet { UserDefaults.standard.set(paceWeeklyFloor, forKey: "paceWeeklyFloor") }
    }
    /// Warn when today's / this week's estimated spend crosses this budget.
    /// Entered and stored in the DISPLAY currency (the symbol the field shows);
    /// `deliverBudgetAlerts` converts it to USD via `effectiveRate` before the
    /// comparison, since spend totals are tracked in USD. 0 = off. Alert fires
    /// once per day / week.
    @Published var dailyBudget: Double {
        didSet { UserDefaults.standard.set(dailyBudget, forKey: "dailyBudget") }
    }
    @Published var weeklyBudget: Double {
        didSet { UserDefaults.standard.set(weeklyBudget, forKey: "weeklyBudget") }
    }
    /// Costs are token-usage estimates at API list prices. On a subscription
    /// that's the *value* of usage, not a bill — this reframes the label.
    @Published var costsArePlanValue: Bool {
        didSet { UserDefaults.standard.set(costsArePlanValue, forKey: "costsArePlanValue") }
    }
    @Published var quietHoursEnabled: Bool {
        didSet { UserDefaults.standard.set(quietHoursEnabled, forKey: "quietHoursEnabled") }
    }
    @Published var quietStartHour: Int {
        didSet { UserDefaults.standard.set(quietStartHour, forKey: "quietStartHour") }
    }
    @Published var quietEndHour: Int {
        didSet { UserDefaults.standard.set(quietEndHour, forKey: "quietEndHour") }
    }
    /// Merge stats across your Macs via an iCloud Drive file. Off by default.
    @Published var syncStatsViaICloud: Bool {
        didSet {
            UserDefaults.standard.set(syncStatsViaICloud, forKey: "syncStatsViaICloud")
            if syncStatsViaICloud { Task { await self.loadSyncedStats() } }
        }
    }
    @Published var notificationsMuted: Bool {
        didSet { UserDefaults.standard.set(notificationsMuted, forKey: "notificationsMuted") }
    }
    /// Session history (finished sessions) + agents we can no longer read.
    @Published private(set) var sessionHistory: [SessionHistoryEntry] = []
    @Published private(set) var unreadableAgents: [UnreadableAgent] = []
    /// ISO code of the display currency. USD (default) needs no rate and no
    /// network; picking another fetches its rate.
    @Published var currencyCode: String {
        didSet {
            guard currencyCode != oldValue else { return }
            // The snapshot harness injects a currency via applyFixture; it must
            // not persist to the real prefs or hit the network.
            guard !Self.isSnapshotMode else { return }
            UserDefaults.standard.set(currencyCode, forKey: "currencyCode")
            startCurrencyRateRefresh()
        }
    }
    /// Cached USD→currency rate (1 for USD). Drives every cost display.
    @Published private(set) var currencyRate: Double = 1

    var currency: Currency { Currency.byCode(currencyCode) ?? .usd }

    /// We only ever convert when we hold a rate that belongs to the CURRENT
    /// currency — otherwise (e.g. the user just switched currency and the
    /// fetch hasn't landed, or failed offline) we fall back to plain USD
    /// rather than paint a foreign symbol onto a stale or 1:1 rate.
    var displayCurrency: Currency {
        currency.code == "USD" || cachedCurrencyRate?.code == currency.code ? currency : .usd
    }
    var effectiveRate: Double {
        displayCurrency.code == "USD" ? 1 : currencyRate
    }

    /// Format a USD amount in the user's chosen currency. The single entry
    /// point every cost label goes through.
    func money(_ usd: Double, approximate: Bool = true) -> String {
        CurrencyFormatter.string(usd: usd, currency: displayCurrency, rate: effectiveRate,
                                 approximate: approximate)
    }

    /// Compact form for the menu bar (no decimals, k/M past 10k).
    func moneyCompact(_ usd: Double) -> String {
        CurrencyFormatter.compact(usd: usd, currency: displayCurrency, rate: effectiveRate)
    }
    /// Positive = minutes to keep finished rows, 0 = never hide,
    /// negative = hide immediately (same tick the state flips done).
    static func hideInterval(_ minutes: Double) -> TimeInterval? {
        if minutes > 0 { return minutes * 60 }
        if minutes < 0 { return 0 }
        return nil
    }

    /// Minutes after which finished sessions hide from the list; 0 = never.
    @Published var doneAutoHideMinutes: Double {
        didSet {
            UserDefaults.standard.set(doneAutoHideMinutes, forKey: "doneAutoHideMinutes")
            applyStoreConfiguration()
        }
    }
    @Published var stallThresholdMinutes: Double {
        didSet {
            UserDefaults.standard.set(stallThresholdMinutes, forKey: "stallThresholdMinutes")
            applyStoreConfiguration()
        }
    }
    @Published var notifyWaiting: Bool {
        didSet { UserDefaults.standard.set(notifyWaiting, forKey: "notifyWaiting") }
    }
    @Published var notifyDone: Bool {
        didSet { UserDefaults.standard.set(notifyDone, forKey: "notifyDone") }
    }
    /// Sunday-evening week summary notification.
    @Published var weeklyDigestEnabled: Bool {
        didSet { UserDefaults.standard.set(weeklyDigestEnabled, forKey: "weeklyDigestEnabled") }
    }
    /// One automatic follow-up per waiting episode, after the minutes below.
    @Published var waitingReminderEnabled: Bool {
        didSet { UserDefaults.standard.set(waitingReminderEnabled, forKey: "waitingReminderEnabled") }
    }
    @Published var waitingReminderMinutes: Double {
        didSet { UserDefaults.standard.set(waitingReminderMinutes, forKey: "waitingReminderMinutes") }
    }
    /// Advisory spend guard: a nudge (never a pause) when a session burns fast
    /// or crosses the per-session budget below.
    @Published var spendGuardEnabled: Bool {
        didSet { UserDefaults.standard.set(spendGuardEnabled, forKey: "spendGuardEnabled") }
    }
    @Published var spendGuardBudget: Double {
        didSet { UserDefaults.standard.set(spendGuardBudget, forKey: "spendGuardBudget") }
    }
    @Published var notifyStalled: Bool {
        didSet { UserDefaults.standard.set(notifyStalled, forKey: "notifyStalled") }
    }
    @Published var precisionModeEnabled: Bool {
        didSet {
            guard oldValue != precisionModeEnabled else { return }
            UserDefaults.standard.set(precisionModeEnabled, forKey: "precisionModeEnabled")
            applyPrecisionMode()
        }
    }
    @Published var claudeUsageMeterEnabled: Bool {
        didSet {
            guard oldValue != claudeUsageMeterEnabled else { return }
            UserDefaults.standard.set(claudeUsageMeterEnabled, forKey: "claudeUsageMeterEnabled")
            applyClaudeUsageMeter()
        }
    }
    @Published var hotKeyEnabled: Bool {
        didSet {
            UserDefaults.standard.set(hotKeyEnabled, forKey: "hotKeyEnabled")
            applyHotKey()
        }
    }
    @Published var hotKeyCombo: String {
        didSet {
            UserDefaults.standard.set(hotKeyCombo, forKey: "hotKeyCombo")
            applyHotKey()
        }
    }
    /// What the menu bar icon shows: "status", "cost", "limit", or "trend".
    @Published var menuBarStyle: String {
        didSet {
            UserDefaults.standard.set(menuBarStyle, forKey: "menuBarStyle")
            // Switching into "trend" needs the sparkline built now, not on
            // the next cost change; switching out frees it.
            if menuBarStyle != oldValue { rebuildSparkline() }
        }
    }
    /// Hottest pace-corrected usage across agents' PRIMARY windows, for the
    /// "limit" menu-bar style — whatever length each window is (Codex's weekly
    /// one usually wins on this author's machine), so the label that describes
    /// it must not name a window either.
    @Published private(set) var hottestLimitPercent: Double?
    @Published var launchAtLogin: Bool {
        didSet {
            guard oldValue != launchAtLogin, !suppressToggleApply else { return }
            applyLaunchAtLogin()
        }
    }
    @Published private(set) var hooksError: String?
    /// True when macOS will silently drop every banner we post (the user hit
    /// "Don't Allow" or switched the app off in System Settings › Notifications).
    /// Mirrored from `NotificationManager.authorizationStatus`; the menu and the
    /// Notifications tab render a "notifications are blocked" banner from it.
    @Published private(set) var notificationsBlocked = false
    /// Why the last "Start at login" toggle failed, or an approval hint when the
    /// system parks the item in .requiresApproval — surfaced under the toggle
    /// the way `liveUsageStatus` is, instead of the switch silently flipping back.
    @Published private(set) var launchAtLoginStatus: String?
    /// Set true only while a toggle's own error handler reverts its value, so the
    /// re-entrant didSet doesn't re-run apply…() (which would wipe the error we
    /// just set, or bounce the login-item registration a second time).
    private var suppressToggleApply = false
    @Published private(set) var welcomeDismissed: Bool =
        UserDefaults.standard.bool(forKey: "welcomeDismissed")
    /// The guide version floor at launch: tips newer than this get NEW
    /// badges, and a pill in the menu invites the tour after an update.
    @Published private(set) var guideVersionFloor: String =
        UserDefaults.standard.string(forKey: "lastSeenGuideVersion") ?? "0"
    var newFeatureCount: Int { FeatureGuide.tipsNewer(than: guideVersionFloor).count }

    func isNewTip(_ tip: FeatureGuide.Tip) -> Bool {
        tip.version.compare(guideVersionFloor, options: .numeric) == .orderedDescending
    }

    /// Called when the tour closes: everything shipped so far is now seen.
    func markGuideSeen() {
        let current = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        UserDefaults.standard.set(current, forKey: "lastSeenGuideVersion")
        guideVersionFloor = current
    }

    // MARK: - F7 remote push (webhook)

    /// Opt-in second notification sink. Off by default; the URL is supplied by
    /// the USER only (never observed content). The default payload carries just
    /// {agent, project, state, timestamp} — no prompt/question/transcript/tool
    /// text — because the app's privacy promise is "transcripts and prompts
    /// never leave your Mac". Sending the pending question is the separate,
    /// default-OFF `webhookIncludeQuestion` toggle below.
    @Published var webhookEnabled: Bool {
        didSet { UserDefaults.standard.set(webhookEnabled, forKey: "webhookEnabled") }
    }
    @Published var webhookURLString: String {
        didSet { UserDefaults.standard.set(webhookURLString, forKey: "webhookURL") }
    }
    /// Default OFF, warned in the UI: transmits the pending question / title
    /// (prompt-derived text) to the user's endpoint. Never sends tool command
    /// lines regardless of this toggle.
    @Published var webhookIncludeQuestion: Bool {
        didSet { UserDefaults.standard.set(webhookIncludeQuestion, forKey: "webhookIncludeQuestion") }
    }
    /// Last webhook send failure, surfaced under the toggle; nil after a success.
    @Published private(set) var webhookStatus: String?
    private let webhookSink = WebhookSink()

    // MARK: - F8 first-run stats reveal

    /// Bumped exactly once, on genuine first run, after the initial
    /// StatsRecompute backfills prior-day history — an always-alive opener view
    /// observes it and opens the Stats window with an all-time range.
    @Published var firstRunStatsRequest: Int = 0
    /// "Before today, your agents already cost you $X across N days." nil = none.
    @Published private(set) var firstRunStatsMessage: String?

    // MARK: - F10 git snapshots / F11 tool-call feed (app-side caches)

    /// F10: git working-tree summary per `"agentID/sessionID"`, computed OFF the
    /// 2s tick and injected onto `.done` rows at publish. `forGrowth` records the
    /// row's `lastGrowthAt` the snapshot was taken for, so a later turn re-runs it.
    private var gitByKey: [String: (snap: GitSnapshot, forGrowth: Date?)] = [:]
    /// Keys with a git read in flight — never spawn a second concurrent read.
    private var gitInFlight: Set<String> = []
    /// Last `lastGrowthAt` epoch we ran git for per key, even when the result was
    /// nil (a non-git cwd). Prevents re-spawning `git` every tick for a `.done`
    /// row whose cwd is not a repo; a new turn (fresh epoch) re-arms it.
    private var gitAttemptedGrowth: [String: Date] = [:]
    /// F11: redacted last-10 tool-call summaries per `"claude-code/sessionID"`,
    /// fed by the Precision-mode hook watcher, injected onto rows at publish.
    /// Never notified/webhooked/synced — display only.
    private var toolCallsByKey: [String: [ToolCallSummary]] = [:]

    private let projectsRoot: URL
    // OpenClawAdapter.allSurfaces() MUST precede ClaudeCodeAdapter(): the SDK
    // surface claims OpenClaw's temp-workspace transcripts under ~/.claude/projects
    // before Claude Code (first isTranscript match wins in transcriptsChanged).
    // Claude Code yields those dirs only because OpenClaw is registered here to
    // take them; a store without OpenClaw must keep counting them itself.
    private let adapters: [any AgentAdapter] =
        OpenClawAdapter.allSurfaces()
        + [ClaudeCodeAdapter(excludeProjectDir: OpenClawAdapter.isSDKWorkspaceProjectDir),
           CodexAdapter(), HermesAdapter()]
        + AntigravityAdapter.allSurfaces()
        + GeminiAdapter.allSurfaces() + [CursorAdapter(), ManusAdapter()]
    private let store: SessionStore
    private let processWatcher: ProcessWatcher
    private var fsWatchers: [FSEventsWatcher] = []
    private var watchedRoots: Set<URL> = []
    private var hookWatcher: HookEventWatcher?
    private var refreshTimer: Timer?
    private var onboardingPollTimer: Timer?
    private var notificationPlanner = NotificationPlanner()
    private var waitingReminderPlanner = WaitingReminderPlanner()
    private var spendGuardPlanner = SpendGuardPlanner(
        firedBurn: Set(UserDefaults.standard.stringArray(forKey: "spendGuardFiredBurn") ?? []),
        firedBudget: Set(UserDefaults.standard.stringArray(forKey: "spendGuardFiredBudget") ?? []))
    /// "What Agent Babysitter caught for you" — persisted across launches and
    /// summed for the current month into `impactThisMonth` for the stats view.
    private var impactLedger = ImpactLedger.Ledger()
    @Published private(set) var impactThisMonth = ImpactLedger.Summary()
    /// What the stats window currently shows — the weekly digest reads this
    /// so it matches the numbers the user sees (household sum when sync on).
    private var latestDisplayLedger: StatsLedger.Ledger?
    private let notificationManager = NotificationManager()
    private let liveUsageService = LiveUsageService()
    private let hotKeyManager = HotKeyManager()
    private var liveUsage: [String: UsageLimitSnapshot] = [:]
    private var liveUsageTimer: Timer?
    /// Zero-network Claude usage captured from status-line/hook events.
    /// Persisted so an app restart doesn't lose a still-valid reading.
    private var capturedUsage: [String: UsageLimitSnapshot] = [:] {
        didSet {
            guard capturedUsage != oldValue else { return }
            let data = try? JSONEncoder().encode(capturedUsage)
            UserDefaults.standard.set(data, forKey: "capturedUsage")
        }
    }
    private var lastDebugLimits: [String: String] = [:]
    private var lastDebugAgents = ""
    private var lastDebugRows = ""
    /// Limit alerts fire once per window per agent; keyed by reset time and
    /// persisted so a relaunch doesn't re-alert the same window.
    private var alertedFiveHour: [String: Date] =
        (UserDefaults.standard.dictionary(forKey: "alertedFiveHour") as? [String: Double] ?? [:])
            .mapValues(Date.init(timeIntervalSince1970:))
    private var alertedWeekly: [String: Date] =
        (UserDefaults.standard.dictionary(forKey: "alertedWeekly") as? [String: Double] ?? [:])
            .mapValues(Date.init(timeIntervalSince1970:))
    /// Pace warnings share the once-per-window discipline, tracked apart from
    /// the threshold alerts so each can fire in the same window.
    private var paceAlertedFiveHour: [String: Date] =
        (UserDefaults.standard.dictionary(forKey: "paceAlertedFiveHour") as? [String: Double] ?? [:])
            .mapValues(Date.init(timeIntervalSince1970:))
    private var paceAlertedWeekly: [String: Date] =
        (UserDefaults.standard.dictionary(forKey: "paceAlertedWeekly") as? [String: Double] ?? [:])
            .mapValues(Date.init(timeIntervalSince1970:))
    /// True while any agent's window is at/over 90% — tints the menu bar.
    @Published private(set) var limitDanger = false

    /// True when launched by the UI-snapshot harness: no watchers, no
    /// timers, no notification prompt — views render from injected fixtures.
    static let isSnapshotMode = CommandLine.arguments.contains("--ui-snapshots")

    /// The complete set of first-run defaults this app owns. Extracted from
    /// init() so F2's "Reset all settings" can re-seed them after wiping the
    /// persistent domain — `removePersistentDomain` also drops every registered
    /// default, so the app must re-register them or every toggle reverts to the
    /// raw type zero (false / 0 / "") instead of its documented default.
    static func registerDefaults(_ defaults: UserDefaults) {
        defaults.register(defaults: ["stallThresholdMinutes": 5.0,
                                     "notifyWaiting": true,
                                     "notifyDone": true,
                                     "notifyStalled": true,
                                     "notifyLimit": true,
                                     "notifyPace": true,
                                     "paceFiveHourFloor": 10.0,
                                     "paceWeeklyFloor": 10.0,
                                     "limitAlertThreshold": 80.0,
                                     "hotKeyEnabled": true,
                                     "menuBarStyle": "status",
                                     "hotKeyCombo": "opt-cmd-b",
                                     "autoUpdateCheck": true,
                                     "costsArePlanValue": true,
                                     "quietStartHour": 22,
                                     "quietEndHour": 8,
                                     "weeklyDigestEnabled": true,
                                     "waitingReminderMinutes": 10.0,
                                     "spendGuardEnabled": true,
                                     "spendGuardBudget": 25.0,
                                     // A documented always-on safety net (the toggle's
                                     // help promises it fires): register it true so a
                                     // fresh install isn't silently missing the one
                                     // follow-up that keeps a blocked agent from sitting
                                     // unnoticed. Unlike precision/usage-meter/live-usage,
                                     // this makes no network call and changes no external
                                     // config, so on-by-default is the honest default.
                                     "waitingReminderEnabled": true,
                                     "doneAutoHideMinutes": 10.0])
    }

    init() {
        let defaults = UserDefaults.standard
        AppModel.registerDefaults(defaults)
        let root = PlatformPaths.homeDirectory(".claude/projects")
        projectsRoot = root
        let stallMinutes = defaults.double(forKey: "stallThresholdMinutes")
        let precision = defaults.bool(forKey: "precisionModeEnabled")
        let hideMinutes = defaults.double(forKey: "doneAutoHideMinutes")
        store = SessionStore(configuration: .init(projectsRoot: root,
                                                  stallThreshold: stallMinutes * 60,
                                                  precisionModeEnabled: precision,
                                                  adapters: adapters,
                                                  doneAutoHide: Self.hideInterval(hideMinutes)))
        processWatcher = ProcessWatcher(adapters: adapters)
        notificationsMuted = defaults.bool(forKey: "notificationsMuted")
        currencyCode = defaults.string(forKey: "currencyCode") ?? "USD"
        if let data = defaults.data(forKey: "currencyRate"),
           let cached = try? JSONDecoder().decode(CurrencyRateService.CachedRate.self, from: data),
           cached.code == (defaults.string(forKey: "currencyCode") ?? "USD") {
            currencyRate = cached.rate
            cachedCurrencyRate = cached
        }
        doneAutoHideMinutes = defaults.double(forKey: "doneAutoHideMinutes")
        stallThresholdMinutes = stallMinutes
        notifyWaiting = defaults.bool(forKey: "notifyWaiting")
        notifyDone = defaults.bool(forKey: "notifyDone")
        notifyStalled = defaults.bool(forKey: "notifyStalled")
        waitingReminderEnabled = defaults.bool(forKey: "waitingReminderEnabled")
        waitingReminderMinutes = defaults.double(forKey: "waitingReminderMinutes")
        spendGuardEnabled = defaults.bool(forKey: "spendGuardEnabled")
        spendGuardBudget = defaults.double(forKey: "spendGuardBudget")
        // Skip the real on-disk ledger under the snapshot harness so QA renders
        // are hermetic: fixtures inject their own impact via applyFixture, and a
        // render must never carry this machine's private spend/activity figures.
        if !Self.isSnapshotMode,
           let data = defaults.data(forKey: "impactLedger"),
           let l = try? JSONDecoder().decode(ImpactLedger.Ledger.self, from: data) {
            impactLedger = l
        }
        impactThisMonth = ImpactLedger.summary(impactLedger, days: AppModel.currentMonthDayKeys())
        weeklyDigestEnabled = defaults.bool(forKey: "weeklyDigestEnabled")
        webhookEnabled = defaults.bool(forKey: "webhookEnabled")
        webhookURLString = defaults.string(forKey: "webhookURL") ?? ""
        webhookIncludeQuestion = defaults.bool(forKey: "webhookIncludeQuestion")
        notifyLimit = defaults.bool(forKey: "notifyLimit")
        notifyPace = defaults.bool(forKey: "notifyPace")
        // Snapshot renders share the user's defaults domain — pin the pace
        // floors so QA output doesn't depend on this machine's slider
        // positions (init-time assignment fires no didSet, so nothing is
        // written back to the user's plist).
        paceFiveHourFloor = Self.isSnapshotMode ? 10
            : defaults.double(forKey: "paceFiveHourFloor")
        paceWeeklyFloor = Self.isSnapshotMode ? 10
            : defaults.double(forKey: "paceWeeklyFloor")
        limitAlertThreshold = defaults.double(forKey: "limitAlertThreshold")
        dailyBudget = defaults.double(forKey: "dailyBudget")
        weeklyBudget = defaults.double(forKey: "weeklyBudget")
        costsArePlanValue = defaults.bool(forKey: "costsArePlanValue")
        quietHoursEnabled = defaults.bool(forKey: "quietHoursEnabled")
        quietStartHour = defaults.integer(forKey: "quietStartHour")
        quietEndHour = defaults.integer(forKey: "quietEndHour")
        syncStatsViaICloud = defaults.bool(forKey: "syncStatsViaICloud")
        hotKeyEnabled = defaults.bool(forKey: "hotKeyEnabled")
        hotKeyCombo = defaults.string(forKey: "hotKeyCombo") ?? "opt-cmd-b"
        menuBarStyle = defaults.string(forKey: "menuBarStyle") ?? "status"
        autoUpdateCheck = defaults.bool(forKey: "autoUpdateCheck")
        precisionModeEnabled = precision
        claudeUsageMeterEnabled = defaults.bool(forKey: "claudeUsageMeterEnabled")
        liveUsageEnabled = defaults.bool(forKey: "liveUsageEnabled")
        launchAtLogin = SMAppService.mainApp.status == .enabled
        if let data = defaults.data(forKey: "capturedUsage"),
           let saved = try? JSONDecoder().decode([String: UsageLimitSnapshot].self, from: data) {
            capturedUsage = saved.filter { Date().timeIntervalSince($0.value.capturedAt) < 300 * 60 }
        }
        // Seed the cost trend from disk so the sparkline (and the popover
        // chart) are populated at launch — recordCostHistory only reassigns
        // when today's total *changes*, which may not happen for a while
        // after a same-day relaunch.
        let persistedHistory = defaults.dictionary(forKey: "costHistory") as? [String: Double] ?? [:]
        costHistory = DailyCostHistory.series(persistedHistory)
        guard !Self.isSnapshotMode else { return }
        if !defaults.bool(forKey: "welcomeDismissed"),
           defaults.string(forKey: "lastSeenGuideVersion") == nil {
            markGuideSeen()
        }
        notificationManager.rowProvider = { [weak self] sessionID in
            // Through the store so clicks on older banners still reach
            // sessions the auto-hide has tidied away.
            await self?.store.rows(includeHidden: true).first { $0.id == sessionID }
        }
        notificationManager.money = { [weak self] in self?.money($0) ?? String(format: "~$%.2f", $0) }
        hotKeyManager.target = { [weak self] in self?.neediestRow() }
        applyHotKey()
        // Mirror the system's notification permission into `notificationsBlocked`
        // before priming, so the "blocked" banner is right from the first tick
        // and delivery is gated off (see refresh()) when macOS would drop banners.
        notificationManager.onAuthorizationChange = { [weak self] status in
            self?.notificationsBlocked = (status == .denied)
        }
        notificationManager.primeAuthorization()
        Task { await notificationManager.refreshAuthorizationStatus() }
        // A change made in System Settings › Notifications while we were in the
        // background flips the banner on next foreground without a relaunch.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.notificationManager.refreshAuthorizationStatus() }
        }
        start()
        if precision { applyPrecisionMode() }
        if claudeUsageMeterEnabled { applyClaudeUsageMeter() }
        if liveUsageEnabled { Task { await refreshLiveUsage(forceFetch: true) } }
        startCurrencyRateRefresh()
        scheduleUpdateCheck()
        loadSessionHistory()
    }

    /// "Can't read <agent>" fired banners, keyed `agentID@appVersion` and
    /// persisted, so a permanently-unreadable agent re-fires once per app
    /// VERSION (i.e. when a parser update might have fixed it) instead of once
    /// per launch. Re-armed for a fresh fire if the agent heals then breaks again.
    private var notifiedUnreadable: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "notifiedUnreadable") ?? [])
    private static let appVersion =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    private let currencyRateService = CurrencyRateService()
    private var cachedCurrencyRate: CurrencyRateService.CachedRate?
    private var currencyRateTimer: Timer?

    /// Automatic daily update check. On by default; a network call to
    /// github.com only (no user data). Off makes the app fully offline again.
    @Published var autoUpdateCheck: Bool {
        didSet {
            UserDefaults.standard.set(autoUpdateCheck, forKey: "autoUpdateCheck")
            scheduleUpdateCheck()
        }
    }
    private let updateChecker = UpdateChecker()
    private var updateCheckTimer: Timer?

    /// Check for a new release at most once a day. A menu-bar app can run for
    /// days, so a 6-hour heartbeat re-evaluates "has 24h passed?" rather than
    /// relying on launch alone. New builds are announced once per version.
    private func scheduleUpdateCheck() {
        updateCheckTimer?.invalidate()
        updateCheckTimer = nil
        guard !Self.isSnapshotMode, autoUpdateCheck else { return }
        Task { await runUpdateCheckIfDue() }
        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) {
            [weak self] _ in
            Task { @MainActor in await self?.runUpdateCheckIfDue() }
        }
    }

    /// Whether banners should be held right now for the user's quiet hours.
    var isQuietNow: Bool {
        quietHoursEnabled && QuietHours.isQuiet(
            now: Date(), startHour: quietStartHour, endHour: quietEndHour)
    }

    private func runUpdateCheckIfDue() async {
        let defaults = UserDefaults.standard
        let last = defaults.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= 24 * 3600 else { return }
        defaults.set(Date(), forKey: "lastUpdateCheck")
        await updateChecker.check()
        guard case .available(let version, let url, let notes) = updateChecker.status else { return }
        // Announce each new version once; don't re-nag daily for one the user
        // has already been told about. Hold the banner during quiet hours —
        // leaving it un-notified so a later check delivers it.
        guard defaults.string(forKey: "lastNotifiedUpdateVersion") != version, !isQuietNow
        else { return }
        defaults.set(version, forKey: "lastNotifiedUpdateVersion")
        notificationManager.deliverUpdateAvailable(version: version, url: url, notes: notes)
    }

    /// Keep the display rate live: fetch now and re-fetch on a short cadence
    /// while a non-USD currency is selected (USD needs no rate and no
    /// network). Called on launch and whenever the currency changes.
    private func startCurrencyRateRefresh() {
        currencyRateTimer?.invalidate()
        currencyRateTimer = nil
        guard !Self.isSnapshotMode, currencyCode != "USD" else { return }
        Task { await refreshCurrencyRate() }
        currencyRateTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) {
            [weak self] _ in
            Task { @MainActor in
                guard let self, self.currencyCode != "USD" else { return }
                await self.refreshCurrencyRate()
            }
        }
    }

    /// Refresh the display-currency rate (no-op for USD). Persists the result
    /// so a relaunch shows converted costs immediately, offline.
    private func refreshCurrencyRate() async {
        let code = currencyCode
        guard let fresh = await currencyRateService.rate(for: code, cached: cachedCurrencyRate)
        else { return }
        cachedCurrencyRate = fresh
        currencyRate = fresh.rate
        if let data = try? JSONEncoder().encode(fresh) {
            UserDefaults.standard.set(data, forKey: "currencyRate")
        }
    }

    /// Injects a complete UI state for the snapshot harness.
    func applyFixture(rows: [SessionRow], summary: MenuBarSummary,
                      usageLimits: [String: UsageLimitSnapshot],
                      installedAgents: [(id: String, name: String)],
                      runningAgentIDs: Set<String>,
                      todayCost: SessionCost,
                      costHistory: [(day: Date, dollars: Double)],
                      limitDanger: Bool = false,
                      noAgentsDetected: Bool = false,
                      welcomeDismissed: Bool = true,
                      processDetectionDegraded: Bool = false,
                      statsDays: [DayStat] = [],
                      impactThisMonth: ImpactLedger.Summary = ImpactLedger.Summary(),
                      currency: (code: String, rate: Double)? = nil) {
        if let currency {
            self.currencyCode = currency.code
            self.currencyRate = currency.rate
            // Mark the rate as belonging to this currency so displayCurrency
            // resolves to it (not the USD fallback) in fixtures.
            self.cachedCurrencyRate = .init(code: currency.code, rate: currency.rate,
                                            fetchedAt: Date())
        }
        self.rows = rows
        self.summary = summary
        self.usageLimits = usageLimits
        self.installedAgents = installedAgents
        self.runningAgentIDs = runningAgentIDs
        self.todayCost = todayCost
        self.costHistory = costHistory
        self.limitDanger = limitDanger
        self.noAgentsDetected = noAgentsDetected
        self.welcomeDismissed = welcomeDismissed
        self.processDetectionDegraded = processDetectionDegraded
        self.statsDays = statsDays
        self.impactThisMonth = impactThisMonth
    }

    /// Poll live usage on a slow cadence while enabled. Each probe costs one
    /// haiku token of the very quota it measures, so the periodic poll only
    /// runs while Claude is actually in use; toggling the setting fetches
    /// once immediately so the row populates.
    private func refreshLiveUsage(forceFetch: Bool = false) async {
        liveUsageTimer?.invalidate()
        liveUsageTimer = nil
        guard liveUsageEnabled else {
            liveUsage = [:]
            liveUsageStatus = nil
            await refresh()
            return
        }
        if forceFetch || !runningAgentIDs.isDisjoint(with: ["claude-code", "cursor", "manus"]) {
            let agents: Set<String> = forceFetch
                ? ["claude-code", "cursor", "manus"]
                : runningAgentIDs.intersection(["claude-code", "cursor", "manus"])
            let result = await liveUsageService.fetch(enabled: true, agents: agents)
            liveUsage = liveUsage.merging(result.limits) { _, new in new }
            liveUsageStatus = result.failure
            await refresh()
        }
        liveUsageTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let agents = self.runningAgentIDs.intersection(["claude-code", "cursor", "manus"])
                guard self.liveUsageEnabled, !agents.isEmpty else { return }
                let result = await self.liveUsageService.fetch(enabled: true, agents: agents)
                self.liveUsage = self.liveUsage.merging(result.limits) { _, new in new }
                self.liveUsageStatus = result.failure
                await self.refresh()
            }
        }
    }

    func dismissWelcome() {
        welcomeDismissed = true
        UserDefaults.standard.set(true, forKey: "welcomeDismissed")
    }

    func dismiss(_ row: SessionRow) {
        let store = store
        Task {
            await store.dismissSession(id: row.id, agentID: row.agentID)
            await self.refresh()
        }
    }

    func retryDetection() {
        start()
    }

    private func start() {
        // The app works with ANY subset of agents installed; onboarding only
        // when none have ever produced data.
        let availableRoots = adapters.map(\.transcriptRoot)
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !availableRoots.isEmpty else {
            noAgentsDetected = true
            // Slow poll so an agent installed later is picked up without a
            // manual Retry (the copy promises this).
            onboardingPollTimer?.invalidate()
            onboardingPollTimer = Timer.scheduledTimer(withTimeInterval: 15,
                                                       repeats: true) { [weak self] _ in
                Task { @MainActor in self?.start() }
            }
            return
        }
        noAgentsDetected = false
        onboardingPollTimer?.invalidate()
        onboardingPollTimer = nil

        let store = store
        Task {
            await store.bootstrap()
            await self.refresh()
        }

        fsWatchers.forEach { $0.stop() }
        fsWatchers = []
        watchedRoots = []
        for root in availableRoots { addWatcher(for: root) }

        Task {
            await processWatcher.start { [weak self] update in
                Task {
                    await store.processesUpdated(update)
                    await self?.refresh()
                }
            }
        }

        scheduleRefreshTimer(interval: 2)
    }

    /// States drift as time passes with no events (working -> stalled) and
    /// elapsed-time labels need re-rendering — but an idle Mac shouldn't pay
    /// a 2s heartbeat all night. Fast while sessions are listed or recently
    /// were; slow when quiet. File/process events still refresh instantly.
    private var refreshInterval: TimeInterval = 2
    private var lastRowsSeenAt = Date()

    private func scheduleRefreshTimer(interval: TimeInterval) {
        refreshInterval = interval
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    /// The popover just opened: whatever the idle cadence was doing, the
    /// user is looking NOW - refresh immediately and go fast, so the menu
    /// can never show a stale (possibly empty) snapshot at open.
    func popoverOpened() {
        lastRowsSeenAt = Date()
        if refreshInterval != 2 { scheduleRefreshTimer(interval: 2) }
        // Freshen the exchange rate when the user actually looks at costs.
        if !Self.isSnapshotMode, currencyCode != "USD" {
            Task { await refreshCurrencyRate() }
        }
        let watcher = processWatcher
        Task {
            await watcher.setPace(fast: true)
            await watcher.pollOnce()
            await self.refresh()
        }
    }

    private func adaptRefreshCadence() {
        if !rows.isEmpty { lastRowsSeenAt = Date() }
        let quiet = rows.isEmpty && Date().timeIntervalSince(lastRowsSeenAt) > 120
        // Back off harder in Low Power Mode — the user reached for that switch
        // precisely to stop background drain. Agents still refresh, just less
        // often; only lengthens the interval, never shortens it.
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let desired: TimeInterval = quiet ? (lowPower ? 60 : 30) : (lowPower ? 5 : 2)
        if desired != refreshInterval {
            scheduleRefreshTimer(interval: desired)
            let watcher = processWatcher
            Task { await watcher.setPace(fast: !quiet) }
        }
    }

    /// Watch an adapter root; used at start and when a root appears later
    /// (agent installed while the app is running).
    private func addWatcher(for root: URL) {
        guard !watchedRoots.contains(root) else { return }
        let store = store
        let watcher = FSEventsWatcher(
            url: root,
            onChange: { [weak self] paths in
                Task { @MainActor in self?.transcriptsChangedDebounced(paths) }
            },
            onNeedsRescan: { [weak self] in
                Task {
                    await store.bootstrap()
                    await self?.refresh()
                }
            })
        watcher.start()
        fsWatchers.append(watcher)
        watchedRoots.insert(root)
    }

    private var fsCoalesceTask: Task<Void, Never>?
    private var fsPendingPaths: Set<String> = []

    /// While an agent streams its transcript, FSEvents can fire many times a
    /// second. Each fire used to drive a full `store.transcriptsChanged` + row
    /// rebuild + refresh, so the advertised idle backoff never engaged whenever
    /// anything was writing — the app was busiest exactly when the laptop already
    /// was. Coalesce a burst into ONE store update + refresh per ~0.4s window
    /// (paths deduped); the timer cadence still covers steady state, and the
    /// popover open path refreshes immediately on its own.
    private func transcriptsChangedDebounced(_ paths: [String]) {
        fsPendingPaths.formUnion(paths)
        guard fsCoalesceTask == nil else { return }
        fsCoalesceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self else { return }
            let batch = Array(self.fsPendingPaths)
            self.fsPendingPaths.removeAll()
            self.fsCoalesceTask = nil
            await self.store.transcriptsChanged(paths: batch)
            await self.refresh()
        }
    }

    /// Pick up agents installed after launch: when a known root appears,
    /// watch it and rescan. Runs on the 2s refresh tick — five fileExists
    /// checks, negligible.
    private func adoptNewlyInstalledAgents() {
        for adapter in adapters {
            let root = adapter.transcriptRoot
            if !watchedRoots.contains(root),
               FileManager.default.fileExists(atPath: root.path) {
                addWatcher(for: root)
                let store = store
                Task {
                    await store.bootstrap()
                    await self.refresh()
                }
            }
        }
    }

    /// True while a refresh is mid-flight. refresh() has many `await` hops and
    /// ~8 callers (FSEvents, process polls, timers, hotkeys); without this, a
    /// slow refresh that started first can finish LAST and republish a staler
    /// snapshot over a newer one — the numbers tick backward and dismissed rows
    /// flash back. @MainActor makes this flag race-free.
    private var isRefreshing = false
    private var refreshCoalesced = false

    private func refresh() async {
        if isRefreshing { refreshCoalesced = true; return }
        isRefreshing = true
        defer {
            isRefreshing = false
            // Fold every request that arrived mid-flight into ONE more pass, so
            // the final published state always reflects the latest read.
            if refreshCoalesced {
                refreshCoalesced = false
                Task { @MainActor in await self.refresh() }
            }
        }
        recomputeStatsHistoryIfNeeded()   // one-shot; guarded by a version key
        adoptNewlyInstalledAgents()
        // `var` so F10's git summary and F11's tool-call feed can be folded onto
        // the value-type rows just before publishing (the store carries neither).
        var rows = await store.rows()
        // The planner and EVERY delivery path see UNFILTERED state. With "Hide
        // finished sessions: Immediately" (doneAutoHide == 0) a finished row is
        // filtered out of `rows` before its .done edge is ever observed, so the
        // finished notification would never fire; feeding unfiltered rows fixes
        // that. `rows` (filtered) still drives the display, the menu count,
        // departed/history and stats — a hidden .done row must not inflate them.
        let plannerRows = await store.rows(includeHidden: true)
        // Summary from the rows we already hold — no second full rows() pass
        // (which re-reconciles disk and re-copies every session's cost each
        // tick, doubling the store's steady-state cost). Derived from FILTERED
        // rows so a hidden .done session can't inflate the active count.
        let summary = store.menuBarSummary(from: rows)
        let degraded = await store.isProcessDetectionDegraded
        let todayCost = await store.todayCost()
        var usageLimits = await store.usageLimits()
        // Layer readings: on-disk, then zero-network captures from the
        // status-line/hook meter, then opt-in live fetches — for the same
        // agent the newest capture wins. A captured % older than the whole
        // 5h window says nothing about the current window; drop it.
        let liveCaptured = capturedUsage.filter {
            Date().timeIntervalSince($0.value.capturedAt) < 300 * 60
        }
        if liveCaptured.count != capturedUsage.count { capturedUsage = liveCaptured }
        usageLimits = UsageLimitLayering.merged(base: usageLimits,
                                                overlays: [liveCaptured, liveUsage])
        // Clear a session's banner AND any pending snooze re-delivery both when
        // the row DEPARTS and when it merely LEAVES the waiting state (answered
        // in place) — otherwise a snoozed "needs your input" fires for a turn
        // that has already completed. `departed` is still off the filtered rows.
        let prevWaiting = Set(self.rows.filter { $0.state == .waitingForInput }.map(\.id))
        let nowWaiting = Set(plannerRows.filter { $0.state == .waitingForInput }.map(\.id))
        let departed = Set(self.rows.map(\.id)).subtracting(rows.map(\.id))
        if !departed.isEmpty {
            recordHistory(for: self.rows.filter { departed.contains($0.id) })
        }
        let toCancel = departed.union(prevWaiting.subtracting(nowWaiting))
        if !toCancel.isEmpty {
            notificationManager.cancelNotifications(sessionIDs: Array(toCancel))
        }
        // F10/F11: evict the app-side caches for sessions that departed this
        // tick. The composite keys are rebuilt from the OUTGOING rows (`self.rows`
        // still holds each departed session's agentID) — `departed` is a bare id
        // set, so `removeValue(forKey: id)` alone would never match the
        // "agentID/id" keys and the caches would grow unbounded.
        if !departed.isEmpty {
            for old in self.rows where departed.contains(old.id) {
                let gkey = "\(old.agentID)/\(old.id)"
                gitByKey.removeValue(forKey: gkey)
                gitInFlight.remove(gkey)
                gitAttemptedGrowth.removeValue(forKey: gkey)
                toolCallsByKey.removeValue(forKey: "claude-code/\(old.id)")
            }
        }
        // F10: a row that just entered .done gets a read-only git diff for its
        // cwd, computed OFF this tick (detached) and stored back for the next
        // publish — never blocking the 2s heartbeat.
        scheduleGitSnapshots(for: rows)
        // F10/F11: fold the async-computed git snapshot and the redacted
        // tool-call feed onto the value-type rows just before publishing. Absent
        // entries leave the row at its defaults (nil / []). Injecting into the
        // DISPLAYED rows (not plannerRows) keeps this text off every delivery path.
        for i in rows.indices {
            let gkey = "\(rows[i].agentID)/\(rows[i].id)"
            if let snap = gitByKey[gkey]?.snap { rows[i].git = snap }
            if let calls = toolCallsByKey["claude-code/\(rows[i].id)"], !calls.isEmpty {
                rows[i].recentToolCalls = calls
            }
        }
        // Assign @Published state only when it actually changed: an unconditional
        // assign fires objectWillChange every tick and re-renders the whole menu,
        // a direct contributor to the idle CPU burn.
        if self.rows != rows { self.rows = rows }
        if self.usageLimits != usageLimits { self.usageLimits = usageLimits }
        let running = await store.runningAgentIDs()
        if self.runningAgentIDs != running { self.runningAgentIDs = running }
        // "Installed" = the app bundle is registered or the CLI is on PATH.
        // A live/running agent always counts too, so an actual session can
        // never be hidden by a detection miss. Uninstalled apps never appear.
        let installedIDs = AgentInstallDetector.installedIDs(among: adapters)
            .union(runningAgentIDs)
        let newInstalled = adapters
            .filter { installedIDs.contains($0.id) }
            .map { (id: $0.id, name: $0.displayName) }
        // `[(id:,name:)]` isn't Equatable; compare a flattened key list so the
        // publisher fires only when the installed set or a display name changed.
        if newInstalled.map({ "\($0.id)\t\($0.name)" })
            != installedAgents.map({ "\($0.id)\t\($0.name)" }) {
            self.installedAgents = newInstalled
        }
        // Mirror for support/debugging - written only when changed; the 2s
        // tick must not churn plists all day.
        let debugLimits = usageLimits.mapValues {
            "\($0.usedPercent.map { String(Int($0)) } ?? "-")% \($0.plan ?? "")"
                + ($0.isLive ? " · live" : "")
        }
        if debugLimits != lastDebugLimits {
            lastDebugLimits = debugLimits
            UserDefaults.standard.set(debugLimits, forKey: "debugUsageLimits")
        }
        let debugRows = rows.map { "[\($0.state.label)] \($0.agentName): \($0.projectName)" }
            .joined(separator: " | ")
        if debugRows != lastDebugRows {
            lastDebugRows = debugRows
            UserDefaults.standard.set(debugRows, forKey: "debugRows")
        }
        let debugAgents = "installed: \(installedAgents.map(\.id).sorted().joined(separator: " ")) | running: \(runningAgentIDs.sorted().joined(separator: " "))"
        if debugAgents != lastDebugAgents {
            lastDebugAgents = debugAgents
            UserDefaults.standard.set(debugAgents, forKey: "debugAgents")
        }
        let unreadable = await computeUnreadableAgents()
        if self.unreadableAgents != unreadable { self.unreadableAgents = unreadable }
        recordCostHistory(todayCost.dollars)
        await recordStats(rows: rows)
        adaptRefreshCadence()
        if self.summary != summary { self.summary = summary }
        if self.processDetectionDegraded != degraded { self.processDetectionDegraded = degraded }
        if self.todayCost != todayCost { self.todayCost = todayCost }

        // The weekly digest is only ever "due" Sunday 18:00–23:59. If the user's
        // quiet hours cover that window it would be dropped forever; record the
        // Sunday's week key AND the timestamp so `deliverWeeklyDigestIfDue` can
        // catch up on the first non-quiet tick — even one that has rolled into
        // Monday, which is already the NEXT ISO week (so a week-key match alone
        // would miss it). Keyed only on delivery, so it still fires at most once.
        if weeklyDigestEnabled, !notificationsMuted, isQuietNow,
           WeeklyDigest.isDue(now: Date(),
                              lastFired: UserDefaults.standard.string(forKey: "weeklyDigestFired")) {
            let d = UserDefaults.standard
            d.set(WeeklyDigest.weekKey(for: Date()), forKey: "weeklyDigestPending")
            d.set(Date().timeIntervalSince1970, forKey: "weeklyDigestPendingAt")
        }

        // Quiet hours silence every banner (the menu still updates live).
        guard !isQuietNow else { return }
        // If macOS will silently drop everything we post (the user hit "Don't
        // Allow" or turned the app off in System Settings › Notifications),
        // deliver nothing AND advance NO dedupe bookkeeping below — otherwise the
        // 85%-of-limit warning and this week's digest are burned for good and
        // never re-offered once permission returns.
        guard notificationManager.canDeliver else { return }
        deliverLimitAlerts(usageLimits)
        deliverBudgetAlerts(todayCost.dollars)
        deliverWeeklyDigestIfDue()
        // "Can't read <agent>" fires once per app VERSION (when a parser update
        // might have fixed it), not once per launch. Keys are `agentID@version`,
        // persisted, and re-armed to exactly the still-unreadable set so an agent
        // that heals then breaks again fires afresh.
        var unreadableChanged = false
        for agent in unreadableAgents {
            if notifiedUnreadable.insert("\(agent.id)@\(Self.appVersion)").inserted {
                notificationManager.deliverCannotRead(agentName: agent.name, agentID: agent.id)
                unreadableChanged = true
            }
        }
        let liveUnreadableKeys = Set(unreadableAgents.map { "\($0.id)@\(Self.appVersion)" })
        if notifiedUnreadable != liveUnreadableKeys {
            notifiedUnreadable = liveUnreadableKeys
            unreadableChanged = true
        }
        if unreadableChanged {
            UserDefaults.standard.set(Array(notifiedUnreadable), forKey: "notifiedUnreadable")
        }

        // Activity-based agents (Antigravity/Cursor/Manus/Gemini) infer turn
        // ends from write gaps; a long think would flap Done/Working and spam
        // notifications — they never notify. Plan over UNFILTERED rows so a
        // finished-then-immediately-hidden session's .done edge is still seen.
        // Muting pauses the planner ENTIRELY (the events(for:) call is skipped,
        // not just its delivery) so a state change during a two-minute mute is
        // preserved and announced on unmute — matching the waiting-reminder and
        // spend-guard behaviour, instead of being silently swallowed.
        var events: [NotificationEvent] = []
        if !notificationsMuted {
            let notifiableRows = plannerRows.filter { !$0.isActivityBased }
            events = notificationPlanner.events(for: plannerRows)
                .filter { event in notifiableRows.contains { $0.id == event.sessionID } }
            var enabledKinds: Set<NotificationEvent.Kind> = []
            if notifyWaiting { enabledKinds.insert(.waitingForInput) }
            if notifyDone { enabledKinds.insert(.turnCompleted) }
            if notifyStalled { enabledKinds.insert(.stalled) }
            notificationManager.deliver(events, rows: plannerRows,
                                        muted: notificationsMuted,
                                        enabledKinds: enabledKinds,
                                        stallThresholdMinutes: Int(stallThresholdMinutes))
            // F7: mirror the SAME deduped, non-activity, mute-/quiet-gated events
            // to the user's opt-in webhook. Default payload = agent/project/state/
            // timestamp only (no prompt/transcript/tool text). The pending
            // question rides along ONLY when the user turned on the explicit
            // include-question toggle. Tool command lines are NEVER sent.
            if webhookEnabled, !webhookURLString.isEmpty,
               let url = URL(string: webhookURLString) {
                for event in events {
                    guard let row = plannerRows.first(where: { $0.id == event.sessionID })
                    else { continue }
                    let payload = WebhookPayload(
                        agent: row.agentName,
                        project: row.projectName,
                        state: row.state.label,
                        timestamp: Date().ISO8601Format(),
                        question: webhookIncludeQuestion
                            ? (row.hookDetail?.detail ?? row.title) : nil)
                    Task { [weak self] in
                        guard let self else { return }
                        let failure = await self.webhookSink.send(payload, to: url)
                        await MainActor.run { self.webhookStatus = failure }
                    }
                }
            }
        }

        // Opt-in follow-up for waiting sessions the user missed. While muted
        // (or in quiet hours, which returns above) the planner is paused; a
        // session still waiting past the interval when banners resume
        // reminds right away — you asked to be caught up.
        if waitingReminderEnabled, !notificationsMuted {
            let due = waitingReminderPlanner.dueReminders(
                rows: plannerRows, interval: waitingReminderMinutes * 60)
            for id in due {
                guard let row = plannerRows.first(where: { $0.id == id }) else { continue }
                notificationManager.deliverWaitingReminder(
                    row: row, minutes: Int(waitingReminderMinutes))
            }
        }

        // Advisory spend guard — a nudge to look, never a pause. Paused while
        // muted (like the waiting reminder) so a nudge is never silently
        // consumed by the planner's once-per-episode flag; a still-fast session
        // nudges once banners resume.
        var newSuggestions = 0
        if spendGuardEnabled, !notificationsMuted {
            let suggestions = spendGuardPlanner.evaluate(
                rows: plannerRows,
                config: SpendGuardPlanner.Config(sessionBudget: max(1, spendGuardBudget)))
            for s in suggestions {
                notificationManager.deliverSpendSuggestion(s)
                newSuggestions += 1
            }
            // Remember which sessions were nudged so quitting and reopening
            // doesn't repeat every nudge for a session that's still running.
            if !suggestions.isEmpty {
                let defaults = UserDefaults.standard
                defaults.set(Array(spendGuardPlanner.firedBurn), forKey: "spendGuardFiredBurn")
                defaults.set(Array(spendGuardPlanner.firedBudget), forKey: "spendGuardFiredBudget")
            }
        }

        // Record only what we actually surfaced: the three honest, episode-
        // deduped activity counters — stall/wait edges for the categories still
        // enabled and not muted (quiet hours already returned above), plus the
        // spend nudges delivered this tick. Deliberately NO dollar figure: the
        // app never saved that money, and the old per-tick "flagged" total
        // re-added each nudged session's running total every tick, inflating it
        // 20–96×. `dollarsFlagged` is omitted (defaults to 0 in Core, kept only
        // for on-disk decode compatibility) and never displayed.
        let delivering = !notificationsMuted
        let newStalls = (delivering && notifyStalled) ? events.filter { $0.kind == .stalled }.count : 0
        let newWaits = (delivering && notifyWaiting) ? events.filter { $0.kind == .waitingForInput }.count : 0
        if newStalls > 0 || newWaits > 0 || newSuggestions > 0 {
            impactLedger = ImpactLedger.recorded(
                impactLedger, todayKey: DailyCostHistory.key(for: Date()),
                stalls: newStalls, waits: newWaits,
                suggestions: newSuggestions)
            persistImpact()
        }
    }

    /// F10: for every row that just entered `.done` with a real cwd, run a
    /// READ-ONLY `git diff`/`status` for that directory OFF the 2s tick and cache
    /// the result. Guards: never two concurrent reads for one key (`gitInFlight`),
    /// and never re-run the same growth epoch — including the nil/no-repo result —
    /// so a `.done` row whose cwd is not a git repo doesn't re-spawn `git` every
    /// tick (`gitAttemptedGrowth`). A new turn (fresh `lastGrowthAt`) re-arms it.
    private func scheduleGitSnapshots(for rows: [SessionRow]) {
        guard !Self.isSnapshotMode else { return }
        for row in rows where row.state == .done {
            guard let cwd = row.cwd,
                  !cwd.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let key = "\(row.agentID)/\(row.id)"
            let epoch = row.lastGrowthAt ?? .distantPast
            if gitAttemptedGrowth[key] == epoch || gitInFlight.contains(key) { continue }
            gitInFlight.insert(key)
            gitAttemptedGrowth[key] = epoch
            let growth = row.lastGrowthAt
            // MainActor-isolated task, NOT Task.detached + MainActor.run: the
            // latter sends `self` across isolation domains, which Xcode 16.x
            // rejects ("sending 'self' risks causing data races") even though
            // newer toolchains accept it — CI builds on 16.4. `read` is
            // nonisolated async, so the git subprocess still runs off-main.
            Task { @MainActor [weak self] in
                let snap = await GitSnapshotReader.read(cwd: cwd)
                guard let self else { return }
                self.gitInFlight.remove(key)
                if let snap {
                    self.gitByKey[key] = (snap, growth)
                } else {
                    // Non-git cwd or failure: keep no snapshot, but the epoch
                    // stays recorded above so we don't hammer `git` each tick.
                    self.gitByKey.removeValue(forKey: key)
                }
                Task { await self.refresh() }
            }
        }
    }

    /// F11: append one redacted tool-call summary to a session's ring buffer,
    /// capping at the last 10 (oldest dropped). Claude-Code-only, keyed to match
    /// the row injection. The summary is already redacted in Core — this only
    /// stores and displays it, never notifies/webhooks/syncs it.
    private func appendToolCall(sessionID: String, summary: ToolCallSummary) {
        let key = "claude-code/\(sessionID)"
        var list = toolCallsByKey[key] ?? []
        list.append(summary)
        if list.count > 10 { list.removeFirst(list.count - 10) }
        toolCallsByKey[key] = list
    }

    /// Day keys for every day of the current month up to today. Builds each
    /// date from fixed y/m/d components — `Calendar.date(bySetting:)` searches
    /// FORWARD, so it would roll earlier days into next month and drop them.
    private static func currentMonthDayKeys() -> [String] {
        let now = Date()
        let cal = Calendar.current
        let today = cal.component(.day, from: now)
        let year = cal.component(.year, from: now)
        let month = cal.component(.month, from: now)
        return (1...max(1, today)).compactMap { day in
            cal.date(from: DateComponents(year: year, month: month, day: day))
                .map { DailyCostHistory.key(for: $0) }
        }
    }

    /// Persist the impact ledger and refresh the published month summary.
    private func persistImpact() {
        // Keep ~2 months so the current-month view always has its data while the
        // stored blob stays bounded instead of growing a key per day forever.
        let cutoff = DailyCostHistory.key(for: Date().addingTimeInterval(-62 * 86400))
        impactLedger = ImpactLedger.pruned(impactLedger, keepingFrom: cutoff)
        if let data = try? JSONEncoder().encode(impactLedger) {
            UserDefaults.standard.set(data, forKey: "impactLedger")
        }
        impactThisMonth = ImpactLedger.summary(impactLedger, days: AppModel.currentMonthDayKeys())
    }

    /// Per-day per-agent dollars, session counts, and active minutes — the
    /// stats window's data. Local-day keyed and kept indefinitely so the
    /// window can show a week, three months, or all time. Session ids are
    /// retained only for today (dedup); past days collapse to counts.
    private var lastStatsTick = Date.distantPast
    private var lastActiveCredit = Date()

    private func recordStats(rows: [SessionRow]) async {
        // Bookkeeping every 30s is plenty; the charts show days.
        let now = Date()
        let anyWorking = rows.contains { $0.state == .working }
        // A backward clock jump (NTP correction, manual change, DST fall-back)
        // makes timeIntervalSince negative — which would freeze the 30s guard
        // indefinitely and credit negative active-minutes. Treat now < lastTick
        // as "due now" and clamp the credit to ≥ 0.
        if now < lastStatsTick { lastStatsTick = .distantPast }
        if now < lastActiveCredit { lastActiveCredit = now }
        guard now.timeIntervalSince(lastStatsTick) >= 30 || statsDays.isEmpty else { return }
        let sinceCredit = max(0, now.timeIntervalSince(lastActiveCredit))
        lastStatsTick = now
        lastActiveCredit = now

        let defaults = UserDefaults.standard
        let today = DailyCostHistory.key(for: now)

        let byAgent = defaults.dictionary(forKey: "costByAgent") as? [String: [String: Double]] ?? [:]
        let byProject = defaults.dictionary(forKey: "costByProject") as? [String: [String: Double]] ?? [:]
        let byModel = defaults.dictionary(forKey: "costByModel") as? [String: [String: Double]] ?? [:]
        var counts = defaults.dictionary(forKey: "sessionCounts") as? [String: Int] ?? [:]
        if let legacy = defaults.dictionary(forKey: "sessionsSeen") as? [String: [String]] {
            for (day, ids) in legacy where counts[day] == nil { counts[day] = ids.count }
            defaults.removeObject(forKey: "sessionsSeen")
        }
        // All session ids ever counted (all-time), so each session is counted
        // once — on its first-seen day — and a range sum is a distinct count.
        // Migrate the old today-only key if present.
        let countedIDs = Set(defaults.stringArray(forKey: "countedSessionIDs")
            ?? (defaults.dictionary(forKey: "sessionsSeenToday") as? [String: [String]])?
                .values.flatMap { $0 } ?? [])
        let activeMinutes = defaults.dictionary(forKey: "activeMinutes") as? [String: Double] ?? [:]

        // One consistent snapshot of today's breakdowns (not three racing calls).
        let breakdown = await store.todayBreakdown()
        // This machine's own ledger — always persisted locally as-is (never
        // overwritten with cross-machine data).
        let ledger = StatsLedger.ticked(
            .init(costByAgent: byAgent, costByProject: byProject, costByModel: byModel,
                  sessionCounts: counts,
                  countedSessionIDs: countedIDs,
                  activeMinutes: activeMinutes),
            todayKey: today,
            todayCostByAgent: breakdown.byAgent,
            todayCostByProject: breakdown.byProject,
            todayCostByModel: breakdown.byModel,
            visibleSessionIDs: rows.map(\.id),
            anyWorking: anyWorking,
            secondsSinceLastTick: sinceCredit)

        // Publish this machine's data to iCloud (own file, gated on change);
        // the DISPLAY ledger sums in siblings but is never persisted back.
        var displayLedger = ledger
        if syncStatsViaICloud {
            StatsSync.writeIfChanged(ledger)
            displayLedger = StatsSync.summedWithSiblings(ledger)
        }

        if ledger.costByAgent != byAgent {
            defaults.set(ledger.costByAgent, forKey: "costByAgent")
        }
        if ledger.costByProject != byProject {
            defaults.set(ledger.costByProject, forKey: "costByProject")
        }
        if ledger.costByModel != byModel {
            defaults.set(ledger.costByModel, forKey: "costByModel")
        }
        if ledger.sessionCounts != counts {
            defaults.set(ledger.sessionCounts, forKey: "sessionCounts")
        }
        if ledger.countedSessionIDs != countedIDs {
            defaults.set(Array(ledger.countedSessionIDs), forKey: "countedSessionIDs")
            defaults.removeObject(forKey: "sessionsSeenToday")   // superseded
        }
        if ledger.activeMinutes != activeMinutes {
            defaults.set(ledger.activeMinutes, forKey: "activeMinutes")
        }
        // The stats window reflects the DISPLAY ledger (this Mac, or the
        // cross-machine sum when sync is on) — not necessarily what's on disk.
        latestDisplayLedger = displayLedger
        let showAgent = displayLedger.costByAgent
        let showProject = displayLedger.costByProject
        let showModel = displayLedger.costByModel
        let showCounts = displayLedger.sessionCounts
        let showMinutes = displayLedger.activeMinutes

        let costTotals = defaults.dictionary(forKey: "costHistory") as? [String: Double] ?? [:]
        statsDays = DailyCostHistory.series(costTotals).map { entry in
            let key = DailyCostHistory.key(for: entry.day)
            let dayDollars = syncStatsViaICloud
                ? (showAgent[key]?.values.reduce(0, +) ?? entry.dollars)
                : entry.dollars
            return DayStat(day: entry.day, dollars: dayDollars,
                           byAgent: showAgent[key] ?? [:],
                           byProject: showProject[key] ?? [:],
                           byModel: showModel[key] ?? [:],
                           activeMinutes: showMinutes[key] ?? 0,
                           sessions: showCounts[key] ?? 0)
        }
    }

    /// Sunday from 6 PM local, once per ISO week: the week's cost, session
    /// count, and busiest project — from the same ledger the stats window
    /// shows. Quiet hours hold it (caller returns before us); the key is
    /// only recorded on delivery. If quiet hours cover the whole Sunday-evening
    /// due window, refresh() records `weeklyDigestPending` for the week, and
    /// this delivers it as a CATCH-UP on the first non-quiet tick still inside
    /// that same ISO week — so a "6 PM–8 AM" quiet setting no longer swallows
    /// the digest permanently.
    private func deliverWeeklyDigestIfDue() {
        guard weeklyDigestEnabled, !notificationsMuted,
              let ledger = latestDisplayLedger else { return }
        let defaults = UserDefaults.standard
        let now = Date()
        let fired = defaults.string(forKey: "weeklyDigestFired")
        let isDue = WeeklyDigest.isDue(now: now, lastFired: fired)
        // Catch-up for a digest held by quiet hours: refresh() recorded the
        // Sunday week key + time in weeklyDigestPending. Deliver on the first
        // non-quiet tick within ~36h (covers a "6 PM–8 AM" window that pushes
        // delivery into Monday — a new ISO week), keyed to the SUNDAY's week so
        // it can't double-fire, and computed AS OF that Sunday so the 7-day
        // window is the one the user expects.
        let pending = defaults.string(forKey: "weeklyDigestPending")
        let pendingAt = defaults.object(forKey: "weeklyDigestPendingAt") as? Double ?? 0
        let catchingUp = pending != nil && pending != fired
            && now.timeIntervalSince1970 - pendingAt < 36 * 3600
        guard isDue || catchingUp else { return }
        let asOf = (catchingUp && !isDue) ? Date(timeIntervalSince1970: pendingAt) : now
        let digest = WeeklyDigest.compute(ledger: ledger, now: asOf)
        defaults.set(pending ?? WeeklyDigest.weekKey(for: now), forKey: "weeklyDigestFired")
        defaults.removeObject(forKey: "weeklyDigestPending")
        defaults.removeObject(forKey: "weeklyDigestPendingAt")
        notificationManager.deliverWeeklyDigest(
            dollars: digest.dollars, sessions: digest.sessions,
            busiestProject: digest.busiestProject,
            planValue: costsArePlanValue, money: { [weak self] in
                self?.money($0) ?? String(format: "$%.2f", $0)
            })
    }

    /// Fold today's running total into the persisted 7-day history. Max
    /// guards against dips when old sessions prune out mid-day.
    /// Days recorded before the double-bill and sub-agent fixes are wrong in
    /// UserDefaults and max-merge can never walk them back. Rebuild them once
    /// from the transcripts. Days whose transcripts are gone keep what's stored.
    private func recomputeStatsHistoryIfNeeded() {
        let defaults = UserDefaults.standard
        // Bumped over time as cost math changed: v3 fixed Codex cached
        // double-counting, v4 re-keyed costByProject to the cwd basename, v5
        // recovers Codex sub-agent usage whose model was declared after its
        // token_count events (previously priced $0). Persisted totals are frozen,
        // so force one rebuild from the transcripts.
        guard defaults.integer(forKey: "statsRecomputeVersion") < 6 else { return }
        defaults.set(6, forKey: "statsRecomputeVersion")   // once per version, even if it throws
        let adapters = self.adapters
        // Same reason as the git snapshot above: never send `self` into a
        // detached task. The inner detached task captures only `adapters`
        // (Sendable) and returns Sendable `Totals`, so the heavy transcript
        // rebuild still runs off-main while `self` stays MainActor-bound.
        Task { @MainActor [weak self] in
            let totals = await Task.detached(priority: .utility) {
                StatsRecompute.run(adapters: adapters)
            }.value
            self?.applyRecomputedStats(totals)
        }
    }

    private func applyRecomputedStats(_ totals: StatsRecompute.Totals) {
        guard !totals.dayTotals.isEmpty else { return }
        let defaults = UserDefaults.standard
        var history = defaults.dictionary(forKey: "costHistory") as? [String: Double] ?? [:]
        var byAgent = defaults.dictionary(forKey: "costByAgent") as? [String: [String: Double]] ?? [:]
        var byProject = defaults.dictionary(forKey: "costByProject") as? [String: [String: Double]] ?? [:]
        var byModel = defaults.dictionary(forKey: "costByModel") as? [String: [String: Double]] ?? [:]

        // REPLACE, never max-merge: the stored value is the wrong one.
        for (day, dollars) in totals.dayTotals { history[day] = dollars }
        for (day, value) in totals.costByAgent { byAgent[day] = value }
        for (day, value) in totals.costByProject { byProject[day] = value }
        for (day, value) in totals.costByModel { byModel[day] = value }

        defaults.set(history, forKey: "costHistory")
        defaults.set(byAgent, forKey: "costByAgent")
        defaults.set(byProject, forKey: "costByProject")
        defaults.set(byModel, forKey: "costByModel")
        costHistoryCache = history   // keep the recordCostHistory mirror in sync
        costHistory = DailyCostHistory.series(history)
        rebuildSparkline()
        lastStatsTick = .distantPast   // let the next tick rebuild statsDays
        BabysitterLog.store.info(
            "recomputed \(totals.dayTotals.count, privacy: .public) days of cost history")

        // F8: on genuine first run, once the recompute has backfilled history,
        // reveal the pre-existing spend by opening the Stats window with an
        // all-time range and a one-line summary. Gated by a dedicated bool key so
        // it fires at most once, ever, and only when there IS a past to show
        // (days strictly before today). The auto-opener view observes
        // `firstRunStatsRequest`.
        let defaults2 = UserDefaults.standard
        if !defaults2.bool(forKey: "firstRunStatsShown"), !Self.isSnapshotMode {
            let todayKey = DailyCostHistory.key(for: Date())
            let prior = totals.dayTotals.filter { $0.key < todayKey }
            if !prior.isEmpty {
                let dollars = prior.values.reduce(0, +)
                firstRunStatsMessage = "Before today, your agents already cost you "
                    + money(dollars) + " across \(prior.count) day\(prior.count == 1 ? "" : "s")."
                firstRunStatsRequest &+= 1
            }
            defaults2.set(true, forKey: "firstRunStatsShown")
        }
    }

    /// In-memory mirror of the persisted "costHistory" dict so the 2s refresh
    /// tick doesn't decode the whole (up to 10-year) history out of UserDefaults
    /// every time. Write-through on change; `applyRecomputedStats` — the only
    /// other writer of that key — keeps it in sync too.
    private var costHistoryCache: [String: Double]?

    private func recordCostHistory(_ todayDollars: Double) {
        let saved = costHistoryCache
            ?? (UserDefaults.standard.dictionary(forKey: "costHistory") as? [String: Double] ?? [:])
        let updated = DailyCostHistory.updated(saved, now: Date(), dollars: todayDollars,
                                               keepDays: 3650)
        costHistoryCache = updated
        guard updated != saved else { return }
        UserDefaults.standard.set(updated, forKey: "costHistory")
        costHistory = DailyCostHistory.series(updated)
    }

    /// Warn once per day/week when spend crosses the user's budget. Week total
    /// is the last 7 local days of the persisted cost history.
    private func deliverBudgetAlerts(_ todayDollars: Double) {
        // 0 means "off" regardless of currency, so gate on the raw entered values.
        guard dailyBudget > 0 || weeklyBudget > 0 else { return }
        let defaults = UserDefaults.standard
        let now = Date()
        let history = defaults.dictionary(forKey: "costHistory") as? [String: Double] ?? [:]
        // Walk real calendar days, not fixed 86,400s steps — a DST fall-back day
        // is 25h, so multiplying seconds lands twice on the same key (double-
        // counting today) and skips a day. `date(byAdding:)` is DST-correct.
        let cal = Calendar.current
        var weekSpent = todayDollars
        for offset in 1..<7 {
            guard let day = cal.date(byAdding: .day, value: -offset, to: now) else { continue }
            weekSpent += history[DailyCostHistory.key(for: day)] ?? 0
        }
        // Budgets are entered/stored in the DISPLAY currency; spend totals are
        // USD. Convert the budget to USD so the comparison is apples-to-apples
        // (on INR, a ₹2000 budget was being compared as $2000 — ~97× too high).
        // CostBudgetPlanner is unchanged; only the units handed to it are fixed.
        let rate = effectiveRate > 0 ? effectiveRate : 1
        let dailyBudgetUSD = dailyBudget / rate
        let weeklyBudgetUSD = weeklyBudget / rate
        let outcome = CostBudgetPlanner.plan(
            todaySpent: todayDollars, dailyBudget: dailyBudgetUSD,
            dayKey: DailyCostHistory.key(for: now),
            weekSpent: weekSpent, weeklyBudget: weeklyBudgetUSD,
            weekKey: Self.isoWeekKey(now),
            alertedDayKey: defaults.string(forKey: "alertedCostDay"),
            alertedWeekKey: defaults.string(forKey: "alertedCostWeek"))
        defaults.set(outcome.alertedDayKey, forKey: "alertedCostDay")
        defaults.set(outcome.alertedWeekKey, forKey: "alertedCostWeek")
        for alert in outcome.alerts {
            notificationManager.deliverCostBudgetAlert(
                isWeekly: alert.isWeekly, spent: alert.spent,
                budget: alert.budget, money: { self.money($0) })
        }
    }

    private static func isoWeekKey(_ date: Date) -> String {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = .current
        let c = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return "\(c.yearForWeekOfYear ?? 0)-W\(c.weekOfYear ?? 0)"
    }

    // MARK: - Session history

    private func recordHistory(for rows: [SessionRow]) {
        guard !Self.isSnapshotMode else { return }
        var history = sessionHistory
        for row in rows {
            let entry = SessionHistoryEntry(
                id: "\(row.agentID)/\(row.id)", sessionID: row.id,
                agentID: row.agentID, agentName: row.agentName,
                project: row.projectName, cwd: row.cwd,
                startedAt: row.turnStartedAt, endedAt: Date(),
                dollars: row.cost.dollars, totalTokens: row.cost.totalTokens,
                transcriptPath: row.transcriptURL?.path,
                title: row.title,
                inputTokens: row.cost.inputTokens, outputTokens: row.cost.outputTokens,
                cacheReadTokens: row.cost.cacheReadTokens,
                cacheWriteTokens: row.cost.cacheWriteTokens,
                isActivityBased: row.isActivityBased)
            history = SessionHistoryLedger.record(entry, into: history)
        }
        guard history != sessionHistory else { return }
        sessionHistory = history
        if let data = try? JSONEncoder().encode(history) {
            // .atomic: a torn write (crash / power loss / full disk) must not
            // erase the user's entire history — the app's only durable record.
            // 0600: this holds 500 verbatim prompts, cwds and transcript paths;
            // harden it like HookEventWatcher does its log, not world-readable.
            try? data.write(to: Self.historyFileURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: Self.historyFileURL.path)
        }
    }

    private func loadSessionHistory() {
        guard let data = try? Data(contentsOf: Self.historyFileURL),
              let saved = try? JSONDecoder().decode([SessionHistoryEntry].self, from: data)
        else { return }
        sessionHistory = saved
    }

    private static let historyFileURL: URL = {
        let dir = PlatformPaths.applicationSupport("AgentBabysitter")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("session-history.json")
    }()

    // MARK: - Agent-drift health

    private var lastHealthCheck = Date.distantPast
    private var lastHealthResult: [UnreadableAgent] = []

    /// An installed+running agent whose data files are churning but yields no
    /// tracked sessions — likely a format change we can't parse. Surfaced as
    /// a menu warning so the promise ("I watch your agents") fails loudly.
    ///
    /// Guards against false alarms: (1) counts TRACKED sessions incl. hidden
    /// (an auto-hidden session isn't "unreadable"); (2) skips activity-based
    /// agents (Antigravity/Gemini/Manus) — they have no turns to parse, so
    /// "zero parsed" is normal, not drift; (3) throttled to ~30s since the
    /// directory scan isn't cheap.
    private func computeUnreadableAgents() async -> [UnreadableAgent] {
        let now = Date()
        guard now.timeIntervalSince(lastHealthCheck) >= 30 else { return lastHealthResult }
        lastHealthCheck = now
        let running = runningAgentIDs
        let tracked = await store.trackedSessionCounts()
        var flagged: [UnreadableAgent] = []
        for adapter in adapters
        where running.contains(adapter.id) && adapter.sessionsAreParsed {
            let recent = Self.dataRecentlyModified(adapter.transcriptRoot)
            if AgentHealth.status(running: true, dataRecentlyModified: recent,
                                  sessionsParsed: tracked[adapter.id] ?? 0) == .cannotRead {
                flagged.append(UnreadableAgent(id: adapter.id, name: adapter.displayName))
            }
        }
        lastHealthResult = flagged
        return flagged
    }

    /// True when the data root (or an immediate child) was written in the last
    /// ~10 minutes — evidence the agent is actively producing data. Child scan
    /// is capped so a huge data dir can't stall the check.
    private static func dataRecentlyModified(_ root: URL) -> Bool {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-600)
        func mtime(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
        }
        if mtime(root) > cutoff { return true }
        let children = ((try? fm.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.contentModificationDateKey], options: [])) ?? [])
            .prefix(200)
        return children.contains { mtime($0) > cutoff }
    }

    private func loadSyncedStats() async {
        // Merging happens on the next stats tick; nudge one now.
        statsDays = []
        await recordStats(rows: rows)
    }

    /// Alert once per window (5h and weekly independently) when an agent
    /// crosses the threshold; the decision logic lives in Core.
    private func deliverLimitAlerts(_ limits: [String: UsageLimitSnapshot]) {
        // Pace-corrected estimates everywhere — a stale 78% that's really
        // 84% should tint the icon and fire the 80% warning.
        let effective = limits.mapValues { snapshot in
            // Correct BOTH windows: a stale weekly 78% that's really 82%
            // must trip the 80% weekly alert too, or the reactive planner
            // (raw) and the pace planner (corrected) leave a silent band
            // between them.
            let estimate = UsageForecast.estimatedCurrentPercent(snapshot)
            let weeklyEstimate = snapshot.weeklyWindow
                .flatMap { UsageForecast.estimatedCurrentPercent($0) }
            guard estimate != nil || weeklyEstimate != nil else { return snapshot }
            return UsageLimitSnapshot(usedPercent: estimate ?? snapshot.usedPercent,
                                      windowMinutes: snapshot.windowMinutes,
                                      resetsAt: snapshot.resetsAt,
                                      capturedAt: snapshot.capturedAt,
                                      plan: snapshot.plan, isLive: snapshot.isLive,
                                      weeklyUsedPercent: weeklyEstimate ?? snapshot.weeklyUsedPercent,
                                      weeklyResetsAt: snapshot.weeklyResetsAt)
        }
        limitDanger = effective.values.contains {
            ($0.usedPercent ?? 0) >= 90 &&
            ($0.resetsAt.map { $0 > Date() } ?? true)
        }
        hottestLimitPercent = effective.values
            .filter { $0.resetsAt.map { $0 > Date() } ?? true }
            .compactMap(\.usedPercent).max()
        guard !notificationsMuted else { return }
        // RAW snapshots on purpose: the pace math extrapolates from
        // (usedPercent, capturedAt) itself — the `effective` map's corrected
        // percent with the old capturedAt would double-count the pace.
        deliverPaceWarnings(limits)
        guard notifyLimit else { return }
        let outcome = UsageAlertPlanner.plan(limits: effective,
                                             threshold: limitAlertThreshold,
                                             alertedFiveHour: alertedFiveHour,
                                             alertedWeekly: alertedWeekly)
        persistAlerted(outcome.alertedFiveHour, into: &alertedFiveHour, key: "alertedFiveHour")
        persistAlerted(outcome.alertedWeekly, into: &alertedWeekly, key: "alertedWeekly")
        for alert in outcome.alerts {
            notificationManager.deliverLimitAlert(agentName: agentDisplayName(alert.agentID),
                                                  agentID: alert.agentID,
                                                  usedPercent: alert.usedPercent,
                                                  resetsAt: alert.resetsAt,
                                                  windowMinutes: usageLimits[alert.agentID]?.windowMinutes ?? 300,
                                                  isWeekly: alert.isWeekly)
        }
    }

    /// The predictive counterpart: warns while still below the threshold when
    /// the pace says the window won't survive to its reset. When the reactive
    /// alert is off there is no one to hand off to above the threshold, so
    /// the pace band opens all the way up — otherwise the user who opted
    /// INTO predictive warnings would go silent exactly when danger peaks.
    private func deliverPaceWarnings(_ limits: [String: UsageLimitSnapshot]) {
        guard notifyPace else { return }
        // Running agents only — a closed app's pace is history, not a
        // prediction (mirrors the menu captions).
        let burning = limits.filter { runningAgentIDs.contains($0.key) }
        // The sliders gate the menu line from as low as 0%, but a BANNER for
        // an early-window burst is noise — alerts keep the hard 30% floor,
        // which the slider can raise but not lower.
        let outcome = PaceAlertPlanner.plan(limits: burning,
                                            // No reactive alert to hand off to → pace covers the
                                            // whole band up to 100% (unbounded, not a 101 sentinel).
                                            threshold: notifyLimit ? limitAlertThreshold : .infinity,
                                            minimumShortWindowPercent: max(PaceAlertPlanner.minimumUsedPercent, paceFiveHourFloor),
                                            minimumLongWindowPercent: max(PaceAlertPlanner.minimumUsedPercent, paceWeeklyFloor),
                                            alertedFiveHour: paceAlertedFiveHour,
                                            alertedWeekly: paceAlertedWeekly)
        persistAlerted(outcome.alertedFiveHour, into: &paceAlertedFiveHour,
                       key: "paceAlertedFiveHour")
        persistAlerted(outcome.alertedWeekly, into: &paceAlertedWeekly,
                       key: "paceAlertedWeekly")
        for alert in outcome.alerts {
            notificationManager.deliverPaceWarning(agentName: agentDisplayName(alert.agentID),
                                                   agentID: alert.agentID,
                                                   usedPercent: alert.usedPercent,
                                                   exhaustionAt: alert.exhaustionAt,
                                                   resetsAt: alert.resetsAt,
                                                   isWeekly: alert.isWeekly,
                                                   windowMinutes: usageLimits[alert.agentID]?.windowMinutes ?? 300)
        }
    }

    /// One copy of the compare/assign/UserDefaults dance the four alerted-
    /// window dictionaries all share (written only when changed — the 2s
    /// tick must not churn plists).
    private func persistAlerted(_ new: [String: Date], into current: inout [String: Date],
                                key: String) {
        guard new != current else { return }
        current = new
        UserDefaults.standard.set(new.mapValues(\.timeIntervalSince1970), forKey: key)
    }

    private func agentDisplayName(_ id: String) -> String {
        installedAgents.first { $0.id == id }?.name
            ?? adapters.first { $0.id == id }?.displayName ?? id
    }

    // MARK: - Preferences plumbing

    private func applyStoreConfiguration() {
        let configuration = SessionStore.Configuration(
            projectsRoot: projectsRoot,
            stallThreshold: stallThresholdMinutes * 60,
            precisionModeEnabled: precisionModeEnabled,
            adapters: adapters,
            doneAutoHide: Self.hideInterval(doneAutoHideMinutes))
        Task {
            await store.updateConfiguration(configuration)
            await refresh()
        }
    }

    private func applyPrecisionMode() {
        // The failure paths below revert the toggle, which fires the didSet and
        // re-enters here. Bail on that re-entry so we don't wipe the error we
        // just set (the whole point of the revert was to SHOW it).
        guard !suppressToggleApply else { return }
        if precisionModeEnabled {
            do {
                try HooksInstaller.install()
                hooksError = nil
                startHookWatcher()
            } catch {
                hooksError = error.localizedDescription
                suppressToggleApply = true
                precisionModeEnabled = false   // reverts the switch without wiping hooksError
                suppressToggleApply = false
                stopHookWatcherIfUnused()
                applyStoreConfiguration()
                return
            }
        } else {
            do {
                try HooksInstaller.uninstall()
                hooksError = nil
            } catch {
                hooksError = error.localizedDescription
            }
            // F11: tool-call summaries are Precision-mode data — drop the whole
            // feed when Precision is turned off so stale "doing: …" captions
            // don't linger on rows.
            toolCallsByKey.removeAll()
            stopHookWatcherIfUnused()
        }
        applyStoreConfiguration()
    }

    /// The zero-network Claude usage meter: a status-line helper that records
    /// the 5h % Claude Code computes for its terminal status line. Verified:
    /// hook payloads do NOT carry rate_limits and the desktop app never runs
    /// a status line, so terminal sessions are the only local source — the %
    /// is account-wide, so one terminal session covers desktop usage too.
    private func applyClaudeUsageMeter() {
        // See applyPrecisionMode: the revert re-enters via didSet; skip it so the
        // install error stays visible instead of being reset to nil.
        guard !suppressToggleApply else { return }
        if claudeUsageMeterEnabled {
            do {
                try StatusLineInstaller.install()
                hooksError = nil
                startHookWatcher()
            } catch {
                hooksError = error.localizedDescription
                suppressToggleApply = true
                claudeUsageMeterEnabled = false   // reverts without wiping hooksError
                suppressToggleApply = false
                capturedUsage = [:]
                stopHookWatcherIfUnused()
                Task { await refresh() }
            }
        } else {
            do {
                try StatusLineInstaller.uninstall()
                hooksError = nil
            } catch {
                hooksError = error.localizedDescription
            }
            capturedUsage = [:]
            stopHookWatcherIfUnused()
            Task { await refresh() }
        }
    }

    /// The event watcher tails one log shared by Precision-mode hooks and the
    /// meter's status-line helper — stop it only when neither feature is on.
    private func stopHookWatcherIfUnused() {
        guard !precisionModeEnabled, !claudeUsageMeterEnabled else { return }
        hookWatcher?.stop()
        hookWatcher = nil
    }

    private func startHookWatcher() {
        guard hookWatcher == nil else { return }
        let store = store
        let watcher = HookEventWatcher(onSignal: { [weak self] sessionID, signal in
            Task {
                await store.hookSignalReceived(sessionID: sessionID, signal)
                await self?.refresh()
            }
        }, onUsage: { [weak self] snapshot in
            Task { @MainActor in
                guard let self, self.claudeUsageMeterEnabled else { return }
                BabysitterLog.hooks.info(
                    "captured Claude usage \(Int(snapshot.usedPercent ?? -1))% from status line")
                self.capturedUsage["claude-code"] = snapshot
                await self.refresh()
            }
        }, onToolCall: { [weak self] sessionID, summary in
            // F11: tool-call surfacing is Precision-mode data. The watcher is
            // shared with the usage meter, so ignore tool calls unless Precision
            // is actually on (matches the row display, which only shows them
            // while Precision captures hooks).
            Task { @MainActor in
                guard let self, self.precisionModeEnabled else { return }
                self.appendToolCall(sessionID: sessionID, summary: summary)
                await self.refresh()
            }
        })
        watcher.start()
        hookWatcher = watcher
    }

    private func applyHotKey() {
        if hotKeyEnabled {
            hotKeyManager.register(comboID: hotKeyCombo)
        } else {
            hotKeyManager.unregister()
        }
    }

    /// The row the hotkey should jump to: same priority as the menu list.
    func neediestRow() -> SessionRow? {
        let priority: [SessionState: Int] = [.waitingForInput: 0, .stalled: 1,
                                             .working: 2, .done: 3, .ended: 4]
        return rows.min { (priority[$0.state] ?? 9) < (priority[$1.state] ?? 9) }
    }

    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            // Registration can succeed yet park the item pending user approval
            // (managed Macs, a prior "don't allow"). Say so instead of looking on.
            launchAtLoginStatus = SMAppService.mainApp.status == .requiresApproval
                ? "Approve Agent Babysitter under System Settings › General › Login Items to start it at login."
                : nil
        } catch {
            // Surface the failure the way liveUsageStatus is surfaced, rather than
            // letting the switch silently flip back with no explanation. Revert
            // under suppression so this doesn't re-enter and clobber the message.
            suppressToggleApply = true
            launchAtLogin = SMAppService.mainApp.status == .enabled
            suppressToggleApply = false
            launchAtLoginStatus = "Couldn't change Start at login: \(error.localizedDescription)"
        }
    }

    // MARK: - F2 reset preferences + clear stored data

    /// F2: wipe every preference THIS app owns and re-seed its documented
    /// defaults. Touches only this app's persistent domain — never another
    /// tool's data. Does NOT delete accumulated stat/history files (that is
    /// `deleteStoredData`). The caller MUST confirm first (destructive). The
    /// live @Published toggles are not re-read here — the Advanced-tab copy
    /// recommends a relaunch so every view rebinds to the re-seeded defaults.
    func resetAllSettings() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        UserDefaults.standard.removePersistentDomain(forName: id)
        AppModel.registerDefaults(.standard)
    }

    /// F2: delete accumulated stored DATA (cost/session/impact history), not
    /// settings. Clears only this app's own keys and files. The caller MUST
    /// confirm first (destructive).
    func deleteStoredData() {
        let d = UserDefaults.standard
        // The task's mandated key set, plus statsRecomputeVersion so the next
        // launch rebuilds history cleanly instead of trusting a now-empty cache.
        for key in ["costByAgent", "costByProject", "costByModel", "sessionCounts",
                    "countedSessionIDs", "activeMinutes", "impactLedger", "costHistory",
                    "statsRecomputeVersion"] {
            d.removeObject(forKey: key)
        }
        // Files: the session history, and the hook event log (truncated, not
        // deleted — the watcher keeps the same 0600 file across launches).
        try? FileManager.default.removeItem(at: AppModel.historyFileURL)
        if let handle = try? FileHandle(forWritingTo: HooksInstaller.defaultEventLogURL) {
            try? handle.truncate(atOffset: 0)
            try? handle.close()
        }
        // In-memory mirrors, so the UI reflects the wipe without a relaunch.
        statsDays = []
        costHistory = []          // didSet rebuilds the (now empty) sparkline
        sessionHistory = []
        impactThisMonth = ImpactLedger.Summary()
        impactLedger = ImpactLedger.Ledger()
        costHistoryCache = nil
        gitByKey = [:]
        gitInFlight = []
        gitAttemptedGrowth = [:]
        toolCallsByKey = [:]
    }

    /// Remove the Claude Code hooks and status-line helper this app installed,
    /// then quit — so trying the app is fully reversible without hand-editing
    /// ~/.claude/settings.json. Wire this to a "Quit and clean up" menu item;
    /// plain Quit intentionally leaves the hooks so the feature survives a
    /// restart. (Cross-file: the menu item lives in the app/menu layer, and a
    /// `--uninstall-hooks` CLI flag + the cask's `zap` stanza are the other
    /// halves of the full uninstall story.)
    func quitAndCleanUp() {
        try? HooksInstaller.uninstall()
        try? StatusLineInstaller.uninstall()
        NSApplication.shared.terminate(nil)
    }
}
