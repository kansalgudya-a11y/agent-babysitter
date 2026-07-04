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

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: ["stallThresholdMinutes": 5.0,
                                     "notifyWaiting": true,
                                     "notifyDone": true,
                                     "notifyStalled": true])
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
        precisionModeEnabled = precision
        launchAtLogin = SMAppService.mainApp.status == .enabled
        notificationManager.rowProvider = { [weak self] sessionID in
            self?.rows.first { $0.id == sessionID }
        }
        notificationManager.primeAuthorization()
        start()
        if precision { applyPrecisionMode() }
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

        // States drift as time passes with no events (working -> stalled),
        // and elapsed-time labels need re-rendering.
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
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
        adoptNewlyInstalledAgents()
        let rows = await store.rows()
        let summary = await store.menuBarSummary()
        let degraded = await store.isProcessDetectionDegraded
        let todayCost = await store.todayCost()
        let usageLimits = await store.usageLimits()
        self.rows = rows
        self.usageLimits = usageLimits
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
            hookWatcher?.stop()
            hookWatcher = nil
            do {
                try HooksInstaller.uninstall()
            } catch {
                hooksError = error.localizedDescription
            }
        }
        applyStoreConfiguration()
    }

    private func startHookWatcher() {
        guard hookWatcher == nil else { return }
        let store = store
        let watcher = HookEventWatcher { [weak self] sessionID, signal in
            Task {
                await store.hookSignalReceived(sessionID: sessionID, signal)
                await self?.refresh()
            }
        }
        watcher.start()
        hookWatcher = watcher
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
