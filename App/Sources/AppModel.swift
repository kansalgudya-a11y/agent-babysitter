import Foundation
import SwiftUI
import ServiceManagement
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
    /// early-window noise. Separate knobs for the 5-hour and weekly windows;
    /// both gate the menu caption and the pace notification alike.
    @Published var paceFiveHourFloor: Double {
        didSet { UserDefaults.standard.set(paceFiveHourFloor, forKey: "paceFiveHourFloor") }
    }
    @Published var paceWeeklyFloor: Double {
        didSet { UserDefaults.standard.set(paceWeeklyFloor, forKey: "paceWeeklyFloor") }
    }
    /// Warn when today's / this week's estimated spend crosses this many USD.
    /// 0 = off. Alert fires once per day / week.
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
    /// Hottest pace-corrected 5h usage across agents, for the "limit" style.
    @Published private(set) var hottestLimitPercent: Double?
    @Published var launchAtLogin: Bool {
        didSet {
            guard oldValue != launchAtLogin else { return }
            applyLaunchAtLogin()
        }
    }
    @Published private(set) var hooksError: String?
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
    private var spendGuardPlanner = SpendGuardPlanner()
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

    init() {
        let defaults = UserDefaults.standard
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
                                     "doneAutoHideMinutes": 10.0])
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
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
        if let data = defaults.data(forKey: "impactLedger"),
           let l = try? JSONDecoder().decode(ImpactLedger.Ledger.self, from: data) {
            impactLedger = l
        }
        impactThisMonth = ImpactLedger.summary(impactLedger, days: AppModel.currentMonthDayKeys())
        weeklyDigestEnabled = defaults.bool(forKey: "weeklyDigestEnabled")
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
        notificationManager.primeAuthorization()
        start()
        if precision { applyPrecisionMode() }
        if claudeUsageMeterEnabled { applyClaudeUsageMeter() }
        if liveUsageEnabled { Task { await refreshLiveUsage(forceFetch: true) } }
        startCurrencyRateRefresh()
        scheduleUpdateCheck()
        loadSessionHistory()
    }

    private var notifiedUnreadable: Set<String> = []
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
        let desired: TimeInterval = quiet ? 30 : 2
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
                Task {
                    await store.transcriptsChanged(paths: paths)
                    await self?.refresh()
                }
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

    private func refresh() async {
        recomputeStatsHistoryIfNeeded()   // one-shot; guarded by a version key
        adoptNewlyInstalledAgents()
        let rows = await store.rows()
        let summary = await store.menuBarSummary()
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
        let departed = Set(self.rows.map(\.id)).subtracting(rows.map(\.id))
        if !departed.isEmpty {
            notificationManager.removeDelivered(sessionIDs: Array(departed))
            recordHistory(for: self.rows.filter { departed.contains($0.id) })
        }
        self.rows = rows
        self.usageLimits = usageLimits
        self.runningAgentIDs = await store.runningAgentIDs()
        // "Installed" = the app bundle is registered or the CLI is on PATH.
        // A live/running agent always counts too, so an actual session can
        // never be hidden by a detection miss. Uninstalled apps never appear.
        let installedIDs = AgentInstallDetector.installedIDs(among: adapters)
            .union(runningAgentIDs)
        self.installedAgents = adapters
            .filter { installedIDs.contains($0.id) }
            .map { (id: $0.id, name: $0.displayName) }
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
        self.unreadableAgents = await computeUnreadableAgents()
        recordCostHistory(todayCost.dollars)
        await recordStats(rows: rows)
        adaptRefreshCadence()
        self.summary = summary
        self.processDetectionDegraded = degraded
        self.todayCost = todayCost

        // Quiet hours silence every banner (the menu still updates live).
        guard !isQuietNow else { return }
        deliverLimitAlerts(usageLimits)
        deliverBudgetAlerts(todayCost.dollars)
        deliverWeeklyDigestIfDue()
        for agent in unreadableAgents where notifiedUnreadable.insert(agent.id).inserted {
            notificationManager.deliverCannotRead(agentName: agent.name, agentID: agent.id)
        }
        notifiedUnreadable.formIntersection(unreadableAgents.map(\.id))  // re-arm once healthy

        // Activity-based agents (Antigravity) infer turn ends from write
        // gaps; a long think would flap Done/Working and spam notifications.
        let notifiableRows = rows.filter { !$0.isActivityBased }
        let events = notificationPlanner.events(for: rows)
            .filter { event in notifiableRows.contains { $0.id == event.sessionID } }
        var enabledKinds: Set<NotificationEvent.Kind> = []
        if notifyWaiting { enabledKinds.insert(.waitingForInput) }
        if notifyDone { enabledKinds.insert(.turnCompleted) }
        if notifyStalled { enabledKinds.insert(.stalled) }
        notificationManager.deliver(events, rows: rows,
                                    muted: notificationsMuted,
                                    enabledKinds: enabledKinds,
                                    stallThresholdMinutes: Int(stallThresholdMinutes))

        // Opt-in follow-up for waiting sessions the user missed. While muted
        // (or in quiet hours, which returns above) the planner is paused; a
        // session still waiting past the interval when banners resume
        // reminds right away — you asked to be caught up.
        if waitingReminderEnabled, !notificationsMuted {
            let due = waitingReminderPlanner.dueReminders(
                rows: rows, interval: waitingReminderMinutes * 60)
            for id in due {
                guard let row = rows.first(where: { $0.id == id }) else { continue }
                notificationManager.deliverWaitingReminder(
                    row: row, minutes: Int(waitingReminderMinutes))
            }
        }

        // Advisory spend guard — a nudge to look, never a pause. Paused while
        // muted (like the waiting reminder) so a nudge is never silently
        // consumed by the planner's once-per-episode flag; a still-fast session
        // nudges once banners resume.
        var newSuggestions = 0
        var dollarsFlagged = 0.0
        if spendGuardEnabled, !notificationsMuted {
            let suggestions = spendGuardPlanner.evaluate(
                rows: rows,
                config: SpendGuardPlanner.Config(sessionBudget: max(1, spendGuardBudget)))
            var flaggedSessions: Set<String> = []   // a session counts once even if both kinds fire
            for s in suggestions {
                notificationManager.deliverSpendSuggestion(s)
                newSuggestions += 1
                if flaggedSessions.insert(s.id).inserted { dollarsFlagged += s.dollars }
            }
        }

        // Record only what we actually surfaced: stall/wait edges for the
        // categories still enabled and not muted (quiet hours already returned
        // above), plus the spend nudges delivered this tick.
        let delivering = !notificationsMuted
        let newStalls = (delivering && notifyStalled) ? events.filter { $0.kind == .stalled }.count : 0
        let newWaits = (delivering && notifyWaiting) ? events.filter { $0.kind == .waitingForInput }.count : 0
        if newStalls > 0 || newWaits > 0 || newSuggestions > 0 || dollarsFlagged > 0 {
            impactLedger = ImpactLedger.recorded(
                impactLedger, todayKey: DailyCostHistory.key(for: Date()),
                stalls: newStalls, waits: newWaits,
                suggestions: newSuggestions, dollarsFlagged: dollarsFlagged)
            persistImpact()
        }
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
        guard now.timeIntervalSince(lastStatsTick) >= 30 || statsDays.isEmpty else { return }
        let sinceCredit = now.timeIntervalSince(lastActiveCredit)
        lastStatsTick = now
        lastActiveCredit = now

        let defaults = UserDefaults.standard
        let today = DailyCostHistory.key(for: now)

        var byAgent = defaults.dictionary(forKey: "costByAgent") as? [String: [String: Double]] ?? [:]
        var byProject = defaults.dictionary(forKey: "costByProject") as? [String: [String: Double]] ?? [:]
        let byModel = defaults.dictionary(forKey: "costByModel") as? [String: [String: Double]] ?? [:]
        var counts = defaults.dictionary(forKey: "sessionCounts") as? [String: Int] ?? [:]
        if let legacy = defaults.dictionary(forKey: "sessionsSeen") as? [String: [String]] {
            for (day, ids) in legacy where counts[day] == nil { counts[day] = ids.count }
            defaults.removeObject(forKey: "sessionsSeen")
        }
        let todaySeen = defaults.dictionary(forKey: "sessionsSeenToday") as? [String: [String]] ?? [:]
        var activeMinutes = defaults.dictionary(forKey: "activeMinutes") as? [String: Double] ?? [:]

        // This machine's own ledger — always persisted locally as-is (never
        // overwritten with cross-machine data).
        let ledger = StatsLedger.ticked(
            .init(costByAgent: byAgent, costByProject: byProject, costByModel: byModel,
                  sessionCounts: counts,
                  todaySessionIDs: Set(todaySeen[today] ?? []),
                  activeMinutes: activeMinutes),
            todayKey: today,
            todayCostByAgent: await store.todayCostByAgent(),
            todayCostByProject: await store.todayCostByProject(),
            todayCostByModel: await store.todayCostByModel(),
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
        if Set(todaySeen[today] ?? []) != ledger.todaySessionIDs || todaySeen.count != 1 {
            defaults.set([today: Array(ledger.todaySessionIDs)], forKey: "sessionsSeenToday")
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
    /// only recorded on delivery, so a held digest fires later that evening.
    private func deliverWeeklyDigestIfDue() {
        guard weeklyDigestEnabled, !notificationsMuted,
              let ledger = latestDisplayLedger else { return }
        let defaults = UserDefaults.standard
        guard WeeklyDigest.isDue(now: Date(),
                                 lastFired: defaults.string(forKey: "weeklyDigestFired"))
        else { return }
        let digest = WeeklyDigest.compute(ledger: ledger)
        defaults.set(WeeklyDigest.weekKey(for: Date()), forKey: "weeklyDigestFired")
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
        // Bumped to 3: the Codex cached-token double-count fix and the two added
        // model prices change historical dollars, but persisted daily totals are
        // frozen (StatsLedger max-merges, never lowers). Force one rebuild from
        // the transcripts so old Codex over-counts self-correct.
        guard defaults.integer(forKey: "statsRecomputeVersion") < 3 else { return }
        defaults.set(3, forKey: "statsRecomputeVersion")   // once per version, even if it throws
        let adapters = self.adapters
        Task.detached(priority: .utility) { [weak self] in
            let totals = StatsRecompute.run(adapters: adapters)
            await MainActor.run { self?.applyRecomputedStats(totals) }
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
        costHistory = DailyCostHistory.series(history)
        rebuildSparkline()
        lastStatsTick = .distantPast   // let the next tick rebuild statsDays
        BabysitterLog.store.info(
            "recomputed \(totals.dayTotals.count, privacy: .public) days of cost history")
    }

    private func recordCostHistory(_ todayDollars: Double) {
        let saved = UserDefaults.standard.dictionary(forKey: "costHistory") as? [String: Double] ?? [:]
        let updated = DailyCostHistory.updated(saved, now: Date(), dollars: todayDollars,
                                               keepDays: 3650)
        guard updated != saved else { return }
        UserDefaults.standard.set(updated, forKey: "costHistory")
        costHistory = DailyCostHistory.series(updated)
    }

    /// Warn once per day/week when spend crosses the user's budget. Week total
    /// is the last 7 local days of the persisted cost history.
    private func deliverBudgetAlerts(_ todayDollars: Double) {
        guard dailyBudget > 0 || weeklyBudget > 0 else { return }
        let defaults = UserDefaults.standard
        let now = Date()
        let history = defaults.dictionary(forKey: "costHistory") as? [String: Double] ?? [:]
        var weekSpent = todayDollars
        for offset in 1..<7 {
            let key = DailyCostHistory.key(for: now.addingTimeInterval(Double(-offset) * 86_400))
            weekSpent += history[key] ?? 0
        }
        let outcome = CostBudgetPlanner.plan(
            todaySpent: todayDollars, dailyBudget: dailyBudget,
            dayKey: DailyCostHistory.key(for: now),
            weekSpent: weekSpent, weeklyBudget: weeklyBudget,
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
                cacheWriteTokens: row.cost.cacheWriteTokens)
            history = SessionHistoryLedger.record(entry, into: history)
        }
        guard history != sessionHistory else { return }
        sessionHistory = history
        if let data = try? JSONEncoder().encode(history) {
            try? data.write(to: Self.historyFileURL)
        }
    }

    private func loadSessionHistory() {
        guard let data = try? Data(contentsOf: Self.historyFileURL),
              let saved = try? JSONDecoder().decode([SessionHistoryEntry].self, from: data)
        else { return }
        sessionHistory = saved
    }

    private static let historyFileURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AgentBabysitter")
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
                                            minimumFiveHourPercent: max(PaceAlertPlanner.minimumUsedPercent, paceFiveHourFloor),
                                            minimumWeeklyPercent: max(PaceAlertPlanner.minimumUsedPercent, paceWeeklyFloor),
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
        hooksError = nil
        if precisionModeEnabled {
            do {
                try HooksInstaller.install()
                startHookWatcher()
            } catch {
                hooksError = error.localizedDescription
                precisionModeEnabled = false
                return
            }
        } else {
            do {
                try HooksInstaller.uninstall()
            } catch {
                hooksError = error.localizedDescription
            }
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
        hooksError = nil
        if claudeUsageMeterEnabled {
            do {
                try StatusLineInstaller.install()
                startHookWatcher()
            } catch {
                hooksError = error.localizedDescription
                claudeUsageMeterEnabled = false
            }
        } else {
            do {
                try StatusLineInstaller.uninstall()
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
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
