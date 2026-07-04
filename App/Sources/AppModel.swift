import Foundation
import SwiftUI
import ServiceManagement
import AgentBabysitterCore

/// Main-actor view model: owns the store and watchers, republishes their
/// state for SwiftUI. All heavy lifting stays in AgentBabysitterCore.
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
    @Published private(set) var costHistory: [(day: Date, dollars: Double)] = []
    /// Week stats, persisted per local day: per-agent dollars, distinct
    /// sessions seen, and minutes with at least one agent working.
    @Published private(set) var weekStats = WeekStats()
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
    @Published var notificationsMuted: Bool {
        didSet { UserDefaults.standard.set(notificationsMuted, forKey: "notificationsMuted") }
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
    /// What the menu bar icon shows: "status", "cost", or "limit".
    @Published var menuBarStyle: String {
        didSet { UserDefaults.standard.set(menuBarStyle, forKey: "menuBarStyle") }
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

    private let projectsRoot: URL
    private let adapters: [any AgentAdapter] =
        [ClaudeCodeAdapter(), CodexAdapter()] + AntigravityAdapter.allSurfaces()
    private let store: SessionStore
    private let processWatcher: ProcessWatcher
    private var fsWatchers: [FSEventsWatcher] = []
    private var watchedRoots: Set<URL> = []
    private var hookWatcher: HookEventWatcher?
    private var refreshTimer: Timer?
    private var onboardingPollTimer: Timer?
    private var notificationPlanner = NotificationPlanner()
    private let notificationManager = NotificationManager()
    private let liveUsageService = LiveUsageService()
    private let hotKeyManager = HotKeyManager()
    private var liveUsage: [String: UsageLimitSnapshot] = [:]
    private var liveUsageTimer: Timer?
    /// Zero-network Claude usage captured from status-line/hook events.
    /// Persisted so an app restart doesn't lose a still-valid reading.
    private var capturedUsage: [String: UsageLimitSnapshot] = [:] {
        didSet {
            let data = try? JSONEncoder().encode(capturedUsage)
            UserDefaults.standard.set(data, forKey: "capturedUsage")
        }
    }
    /// Limit alerts fire once per window per agent; keyed by reset time and
    /// persisted so a relaunch doesn't re-alert the same window.
    private var alertedFiveHour: [String: Date] =
        (UserDefaults.standard.dictionary(forKey: "alertedFiveHour") as? [String: Double] ?? [:])
            .mapValues(Date.init(timeIntervalSince1970:))
    private var alertedWeekly: [String: Date] =
        (UserDefaults.standard.dictionary(forKey: "alertedWeekly") as? [String: Double] ?? [:])
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
                                     "limitAlertThreshold": 80.0,
                                     "hotKeyEnabled": true,
                                     "menuBarStyle": "status"])
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        projectsRoot = root
        let stallMinutes = defaults.double(forKey: "stallThresholdMinutes")
        let precision = defaults.bool(forKey: "precisionModeEnabled")
        store = SessionStore(configuration: .init(projectsRoot: root,
                                                  stallThreshold: stallMinutes * 60,
                                                  precisionModeEnabled: precision,
                                                  adapters: adapters))
        processWatcher = ProcessWatcher(adapters: adapters)
        notificationsMuted = defaults.bool(forKey: "notificationsMuted")
        stallThresholdMinutes = stallMinutes
        notifyWaiting = defaults.bool(forKey: "notifyWaiting")
        notifyDone = defaults.bool(forKey: "notifyDone")
        notifyStalled = defaults.bool(forKey: "notifyStalled")
        notifyLimit = defaults.bool(forKey: "notifyLimit")
        limitAlertThreshold = defaults.double(forKey: "limitAlertThreshold")
        hotKeyEnabled = defaults.bool(forKey: "hotKeyEnabled")
        menuBarStyle = defaults.string(forKey: "menuBarStyle") ?? "status"
        precisionModeEnabled = precision
        claudeUsageMeterEnabled = defaults.bool(forKey: "claudeUsageMeterEnabled")
        liveUsageEnabled = defaults.bool(forKey: "liveUsageEnabled")
        launchAtLogin = SMAppService.mainApp.status == .enabled
        if let data = defaults.data(forKey: "capturedUsage"),
           let saved = try? JSONDecoder().decode([String: UsageLimitSnapshot].self, from: data) {
            capturedUsage = saved.filter { Date().timeIntervalSince($0.value.capturedAt) < 300 * 60 }
        }
        guard !Self.isSnapshotMode else { return }
        notificationManager.rowProvider = { [weak self] sessionID in
            self?.rows.first { $0.id == sessionID }
        }
        hotKeyManager.target = { [weak self] in self?.neediestRow() }
        applyHotKey()
        notificationManager.primeAuthorization()
        start()
        if precision { applyPrecisionMode() }
        if claudeUsageMeterEnabled { applyClaudeUsageMeter() }
        if liveUsageEnabled { Task { await refreshLiveUsage(forceFetch: true) } }
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
                      processDetectionDegraded: Bool = false) {
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
        if forceFetch || runningAgentIDs.contains("claude-code") {
            let result = await liveUsageService.fetch(enabled: true)
            liveUsage = result.limits
            liveUsageStatus = result.failure
            await refresh()
        }
        liveUsageTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.liveUsageEnabled,
                      self.runningAgentIDs.contains("claude-code") else { return }
                let result = await self.liveUsageService.fetch(enabled: true)
                self.liveUsage = result.limits
                self.liveUsageStatus = result.failure
                await self.refresh()
            }
        }
    }

    func dismissWelcome() {
        welcomeDismissed = true
        UserDefaults.standard.set(true, forKey: "welcomeDismissed")
    }

    func resetWelcome() {
        welcomeDismissed = false
        UserDefaults.standard.set(false, forKey: "welcomeDismissed")
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

    private func adaptRefreshCadence() {
        if !rows.isEmpty { lastRowsSeenAt = Date() }
        let quiet = rows.isEmpty && Date().timeIntervalSince(lastRowsSeenAt) > 120
        let desired: TimeInterval = quiet ? 30 : 2
        if desired != refreshInterval { scheduleRefreshTimer(interval: desired) }
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
        capturedUsage = capturedUsage.filter {
            Date().timeIntervalSince($0.value.capturedAt) < 300 * 60
        }
        usageLimits = UsageLimitLayering.merged(base: usageLimits,
                                                overlays: [capturedUsage, liveUsage])
        self.rows = rows
        self.usageLimits = usageLimits
        self.runningAgentIDs = await store.runningAgentIDs()
        self.installedAgents = adapters
            .filter { FileManager.default.fileExists(atPath: $0.transcriptRoot.path) }
            .map { (id: $0.id, name: $0.displayName) }
        // Mirror for support/debugging: `defaults read app.agentbabysitter.AgentBabysitter debugUsageLimits`
        UserDefaults.standard.set(
            usageLimits.mapValues { "\($0.usedPercent.map { String(Int($0)) } ?? "-")% \($0.plan ?? "")" },
            forKey: "debugUsageLimits")
        UserDefaults.standard.set(
            "installed: \(installedAgents.map(\.id).sorted().joined(separator: " ")) | running: \(runningAgentIDs.sorted().joined(separator: " "))",
            forKey: "debugAgents")
        deliverLimitAlerts(usageLimits)
        recordCostHistory(todayCost.dollars)
        await recordWeekStats(rows: rows)
        adaptRefreshCadence()
        self.summary = summary
        self.processDetectionDegraded = degraded
        self.todayCost = todayCost

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
    }

    /// Per-day per-agent dollars, session ids, and active minutes — the
    /// stats window's data. All local-day keyed, pruned to 7 days.
    private func recordWeekStats(rows: [SessionRow]) async {
        let defaults = UserDefaults.standard
        let today = DailyCostHistory.key(for: Date())

        var byAgent = defaults.dictionary(forKey: "costByAgent") as? [String: [String: Double]] ?? [:]
        let todayAgents = await store.todayCostByAgent()
        var mergedToday = byAgent[today] ?? [:]
        for (agent, dollars) in todayAgents {
            mergedToday[agent] = max(mergedToday[agent] ?? 0, dollars)
        }
        byAgent[today] = mergedToday

        var sessionsSeen = defaults.dictionary(forKey: "sessionsSeen") as? [String: [String]] ?? [:]
        var todayIDs = Set(sessionsSeen[today] ?? [])
        todayIDs.formUnion(rows.map(\.id))
        sessionsSeen[today] = Array(todayIDs)

        var activeMinutes = defaults.dictionary(forKey: "activeMinutes") as? [String: Double] ?? [:]
        let tick = Date()
        if rows.contains(where: { $0.state == .working }) {
            // Cap a tick's credit so a sleep/wake gap doesn't award hours.
            let delta = min(tick.timeIntervalSince(lastActiveTick), 60) / 60
            activeMinutes[today, default: 0] += delta
        }
        lastActiveTick = tick

        // Prune everything to the trailing week.
        let liveKeys = Set((0..<7).map {
            DailyCostHistory.key(for: Date().addingTimeInterval(Double(-$0) * 86_400))
        })
        byAgent = byAgent.filter { liveKeys.contains($0.key) }
        sessionsSeen = sessionsSeen.filter { liveKeys.contains($0.key) }
        activeMinutes = activeMinutes.filter { liveKeys.contains($0.key) }
        defaults.set(byAgent, forKey: "costByAgent")
        defaults.set(sessionsSeen, forKey: "sessionsSeen")
        defaults.set(activeMinutes, forKey: "activeMinutes")

        weekStats = WeekStats(
            costByAgent: byAgent.values.reduce(into: [:]) { totals, day in
                for (agent, dollars) in day { totals[agent, default: 0] += dollars }
            },
            sessionCount: sessionsSeen.values.reduce(0) { $0 + $1.count },
            activeMinutes: activeMinutes.values.reduce(0, +))
    }

    /// Fold today's running total into the persisted 7-day history. Max
    /// guards against dips when old sessions prune out mid-day.
    private func recordCostHistory(_ todayDollars: Double) {
        let saved = UserDefaults.standard.dictionary(forKey: "costHistory") as? [String: Double] ?? [:]
        let updated = DailyCostHistory.updated(saved, now: Date(), dollars: todayDollars)
        UserDefaults.standard.set(updated, forKey: "costHistory")
        costHistory = DailyCostHistory.series(updated)
    }

    /// Alert once per window (5h and weekly independently) when an agent
    /// crosses the threshold; the decision logic lives in Core.
    private func deliverLimitAlerts(_ limits: [String: UsageLimitSnapshot]) {
        // Pace-corrected estimates everywhere — a stale 78% that's really
        // 84% should tint the icon and fire the 80% warning.
        let effective = limits.mapValues { snapshot in
            guard let estimate = UsageForecast.estimatedCurrentPercent(snapshot) else {
                return snapshot
            }
            return UsageLimitSnapshot(usedPercent: estimate,
                                      windowMinutes: snapshot.windowMinutes,
                                      resetsAt: snapshot.resetsAt,
                                      capturedAt: snapshot.capturedAt,
                                      plan: snapshot.plan, isLive: snapshot.isLive,
                                      weeklyUsedPercent: snapshot.weeklyUsedPercent,
                                      weeklyResetsAt: snapshot.weeklyResetsAt)
        }
        limitDanger = effective.values.contains {
            ($0.usedPercent ?? 0) >= 90 &&
            ($0.resetsAt.map { $0 > Date() } ?? true)
        }
        hottestLimitPercent = effective.values
            .filter { $0.resetsAt.map { $0 > Date() } ?? true }
            .compactMap(\.usedPercent).max()
        guard notifyLimit, !notificationsMuted else { return }
        let outcome = UsageAlertPlanner.plan(limits: effective,
                                             threshold: limitAlertThreshold,
                                             alertedFiveHour: alertedFiveHour,
                                             alertedWeekly: alertedWeekly)
        alertedFiveHour = outcome.alertedFiveHour
        alertedWeekly = outcome.alertedWeekly
        UserDefaults.standard.set(alertedFiveHour.mapValues(\.timeIntervalSince1970),
                                  forKey: "alertedFiveHour")
        UserDefaults.standard.set(alertedWeekly.mapValues(\.timeIntervalSince1970),
                                  forKey: "alertedWeekly")
        for alert in outcome.alerts {
            let name = installedAgents.first { $0.id == alert.agentID }?.name
                ?? adapters.first { $0.id == alert.agentID }?.displayName ?? alert.agentID
            notificationManager.deliverLimitAlert(agentName: name, agentID: alert.agentID,
                                                  usedPercent: alert.usedPercent,
                                                  resetsAt: alert.resetsAt,
                                                  isWeekly: alert.isWeekly)
        }
    }

    // MARK: - Preferences plumbing

    private func applyStoreConfiguration() {
        let configuration = SessionStore.Configuration(
            projectsRoot: projectsRoot,
            stallThreshold: stallThresholdMinutes * 60,
            precisionModeEnabled: precisionModeEnabled,
            adapters: adapters)
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
        if hotKeyEnabled { hotKeyManager.register() } else { hotKeyManager.unregister() }
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
