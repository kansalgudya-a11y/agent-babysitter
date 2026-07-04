import Foundation

/// One session as the UI shows it.
public struct SessionRow: Equatable, Sendable, Identifiable {
    public var id: String            // session UUID
    public var projectName: String   // human-friendly: last component of cwd
    public var state: SessionState
    public var turnStartedAt: Date?
    public var lastGrowthAt: Date?
    public var isUnreadable: Bool
    public var pid: Int32?
    public var cwd: String?
    public var cost: SessionCost
    /// "claude-desktop", "sdk-cli", … (from the transcript envelope).
    public var entrypoint: String?

    /// Session hosted by the Claude desktop app rather than a terminal.
    public var isDesktopApp: Bool {
        entrypoint?.hasPrefix("claude-desktop") == true
    }

    public init(id: String, projectName: String, state: SessionState,
                turnStartedAt: Date?, lastGrowthAt: Date?, isUnreadable: Bool,
                pid: Int32?, cwd: String?, cost: SessionCost = SessionCost(),
                entrypoint: String? = nil) {
        self.id = id
        self.projectName = projectName
        self.state = state
        self.turnStartedAt = turnStartedAt
        self.lastGrowthAt = lastGrowthAt
        self.isUnreadable = isUnreadable
        self.pid = pid
        self.cwd = cwd
        self.cost = cost
        self.entrypoint = entrypoint
    }
}

public struct MenuBarSummary: Equatable, Sendable {
    /// Worst active state (🟡 > 🔴 > 🟢 > 🔵), nil when everything is quiet.
    public var worstState: SessionState?
    /// Sessions that are not Ended.
    public var activeCount: Int

    public init(worstState: SessionState?, activeCount: Int) {
        self.worstState = worstState
        self.activeCount = activeCount
    }
}

/// Fuses transcript tailers, the process watcher, and (later) hook signals
/// into rows the menu bar renders. All mutation happens inside the actor;
/// callers push events in and pull row snapshots out.
public actor SessionStore {

    public struct Configuration: Sendable {
        public var projectsRoot: URL
        public var stallThreshold: TimeInterval
        public var workingWindow: TimeInterval
        public var activeWindow: TimeInterval
        public var precisionModeEnabled: Bool

        public init(projectsRoot: URL,
                    stallThreshold: TimeInterval = 300,
                    workingWindow: TimeInterval = 10,
                    activeWindow: TimeInterval = 24 * 3600,
                    precisionModeEnabled: Bool = false) {
            self.projectsRoot = projectsRoot
            self.stallThreshold = stallThreshold
            self.workingWindow = workingWindow
            self.activeWindow = activeWindow
            self.precisionModeEnabled = precisionModeEnabled
        }
    }

    private struct TrackedSession {
        let tailer: TranscriptFileTailer
        let projectDirName: String
        var pid: Int32?
        /// Sessions never seen with a process stay hidden (launch scan finds
        /// a day's worth of dead transcripts).
        var everHadProcess = false
        var latestHookSignal: HookSignal?
    }

    public private(set) var configuration: Configuration
    public private(set) var isProcessDetectionDegraded = false

    private var sessions: [String: TrackedSession] = [:]

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    public func updateConfiguration(_ configuration: Configuration) {
        self.configuration = configuration
    }

    // MARK: - Event intake

    /// Launch scan: pick up transcripts modified within the active window.
    public func bootstrap() {
        let found = SessionDirectoryScanner.recentTranscripts(under: configuration.projectsRoot,
                                                              maxAge: configuration.activeWindow)
        for info in found {
            let url = configuration.projectsRoot
                .appendingPathComponent(info.projectDirName)
                .appendingPathComponent("\(info.sessionID).jsonl")
            track(url: url, projectDirName: info.projectDirName)
        }
    }

    /// FSEvents callback: paths that changed under the projects root.
    public func transcriptsChanged(paths: [String]) {
        for path in paths where path.hasSuffix(".jsonl") {
            let url = URL(fileURLWithPath: path)
            let projectDirName = url.deletingLastPathComponent().lastPathComponent
            track(url: url, projectDirName: projectDirName)
        }
        rematch()
    }

    public func processesUpdated(_ update: ProcessWatcher.Update) {
        isProcessDetectionDegraded = update.degraded
        guard !update.degraded else { return }  // keep last known liveness
        latestProcesses = update.processes
        rematch()
    }

    public func hookSignalReceived(sessionID: String, _ signal: HookSignal) {
        sessions[sessionID]?.latestHookSignal = signal
    }

    // MARK: - Output

    public func rows(at now: Date = Date()) -> [SessionRow] {
        var rows: [SessionRow] = []
        for (id, tracked) in sessions where tracked.everHadProcess {
            let signals = SessionSignals(
                processAlive: tracked.pid != nil,
                lastGrowthAt: tracked.tailer.lastGrowthAt,
                turnPhase: tracked.tailer.reducer.turnPhase,
                hasPendingToolUses: !tracked.tailer.reducer.pendingToolUseIDs.isEmpty,
                latestHookEvent: tracked.latestHookSignal,
                precisionModeEnabled: configuration.precisionModeEnabled)
            let state = SessionStateEngine.evaluate(signals, at: now,
                                                    stallThreshold: configuration.stallThreshold,
                                                    workingWindow: configuration.workingWindow)
            let cwd = tracked.tailer.lastKnownCWD
            rows.append(SessionRow(
                id: id,
                projectName: cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
                    ?? tracked.projectDirName,
                state: state,
                turnStartedAt: tracked.tailer.reducer.currentTurnStartedAt,
                lastGrowthAt: tracked.tailer.lastGrowthAt,
                isUnreadable: tracked.tailer.isUnreadable,
                pid: tracked.pid,
                cwd: cwd,
                cost: tracked.tailer.costAccumulator.cost,
                entrypoint: tracked.tailer.lastKnownEntrypoint))
        }
        let priority: [SessionState: Int] = [.waitingForInput: 0, .stalled: 1, .working: 2,
                                             .done: 3, .ended: 4]
        return rows.sorted {
            (priority[$0.state]!, $0.projectName, $0.id)
                < (priority[$1.state]!, $1.projectName, $1.id)
        }
    }

    public func menuBarSummary(at now: Date = Date()) -> MenuBarSummary {
        let states = rows(at: now).map(\.state)
        return MenuBarSummary(worstState: SessionState.worst(of: states),
                              activeCount: states.filter { $0 != .ended }.count)
    }

    /// Dollars across every transcript modified since local midnight —
    /// including sessions hidden from the row list (no live process).
    /// Recomputed from transcripts; there is no cost database.
    public func todayCost(at now: Date = Date(),
                          calendar: Calendar = .current) -> SessionCost {
        let midnight = calendar.startOfDay(for: now)
        var total = SessionCost()
        for (_, tracked) in sessions {
            guard let growth = tracked.tailer.lastGrowthAt, growth >= midnight else { continue }
            let cost = tracked.tailer.costAccumulator.cost
            total.dollars += cost.dollars
            total.totalTokens += cost.totalTokens
            total.unknownModels.formUnion(cost.unknownModels)
        }
        return total
    }

    // MARK: - Internals

    private var latestProcesses: [RunningProcess] = []

    private func track(url: URL, projectDirName: String) {
        if sessions[url.deletingPathExtension().lastPathComponent] == nil {
            let tailer = TranscriptFileTailer(url: url)
            sessions[tailer.sessionID] = TrackedSession(tailer: tailer,
                                                        projectDirName: projectDirName)
        }
        let id = url.deletingPathExtension().lastPathComponent
        _ = try? sessions[id]?.tailer.catchUp()
    }

    private func rematch() {
        let infos = sessions.map { id, tracked in
            SessionFileInfo(sessionID: id,
                            projectDirName: tracked.projectDirName,
                            lastModified: tracked.tailer.lastGrowthAt ?? .distantPast)
        }
        let match = SessionProcessMatcher.match(processes: latestProcesses, sessions: infos)
        for id in sessions.keys {
            let pid = match[id]
            sessions[id]?.pid = pid
            if pid != nil { sessions[id]?.everHadProcess = true }
        }
    }
}
