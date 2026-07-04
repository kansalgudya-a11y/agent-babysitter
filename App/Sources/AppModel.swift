import Foundation
import SwiftUI
import AgentBabysitterCore

/// Main-actor view model: owns the store and watchers, republishes their
/// state for SwiftUI. All heavy lifting stays in AgentBabysitterCore.
@MainActor
final class AppModel: ObservableObject {

    @Published private(set) var rows: [SessionRow] = []
    @Published private(set) var summary = MenuBarSummary(worstState: nil, activeCount: 0)
    @Published private(set) var processDetectionDegraded = false
    @Published private(set) var claudeDirectoryMissing = false
    @Published private(set) var todayCost = SessionCost()
    @Published var notificationsMuted: Bool {
        didSet { UserDefaults.standard.set(notificationsMuted, forKey: "notificationsMuted") }
    }

    private let projectsRoot: URL
    private let store: SessionStore
    private let processWatcher: ProcessWatcher
    private var fsWatcher: FSEventsWatcher?
    private var refreshTimer: Timer?
    private var notificationPlanner = NotificationPlanner()
    private let notificationManager = NotificationManager()
    private let stallThreshold: TimeInterval = 300

    init() {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        projectsRoot = root
        store = SessionStore(configuration: .init(projectsRoot: root))
        processWatcher = ProcessWatcher()
        notificationsMuted = UserDefaults.standard.bool(forKey: "notificationsMuted")
        notificationManager.rowProvider = { [weak self] sessionID in
            self?.rows.first { $0.id == sessionID }
        }
        start()
    }

    func retryDetection() {
        start()
    }

    private func start() {
        guard FileManager.default.fileExists(atPath: projectsRoot.path) else {
            // Onboarding: Claude Code not installed / never run. Idle cheaply
            // until the user hits Retry.
            claudeDirectoryMissing = true
            return
        }
        claudeDirectoryMissing = false

        let store = store
        Task {
            await store.bootstrap()
            await self.refresh()
        }

        let watcher = FSEventsWatcher(
            url: projectsRoot,
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
        fsWatcher = watcher

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

    private func refresh() async {
        let rows = await store.rows()
        let summary = await store.menuBarSummary()
        let degraded = await store.isProcessDetectionDegraded
        let todayCost = await store.todayCost()
        self.rows = rows
        self.summary = summary
        self.processDetectionDegraded = degraded
        self.todayCost = todayCost

        let events = notificationPlanner.events(for: rows)
        notificationManager.deliver(events, rows: rows,
                                    muted: notificationsMuted,
                                    enabledKinds: [.waitingForInput, .turnCompleted, .stalled],
                                    stallThresholdMinutes: Int(stallThreshold / 60))
    }
}
