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
    /// "claude-desktop", "sdk-cli", "Codex Desktop", … (transcript envelope).
    public var entrypoint: String?
    /// Which agent owns this session ("claude-code", "codex") + display name.
    public var agentID: String
    public var agentName: String

    /// Session hosted by a desktop app rather than a terminal.
    public var isDesktopApp: Bool {
        entrypoint?.hasPrefix("claude-desktop") == true
            || entrypoint?.hasPrefix("Codex Desktop") == true
    }

    public init(id: String, projectName: String, state: SessionState,
                turnStartedAt: Date?, lastGrowthAt: Date?, isUnreadable: Bool,
                pid: Int32?, cwd: String?, cost: SessionCost = SessionCost(),
                entrypoint: String? = nil,
                agentID: String = "claude-code", agentName: String = "Claude Code") {
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
        self.agentID = agentID
        self.agentName = agentName
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

        /// Monitored agents. Defaults to Claude Code rooted at `projectsRoot`.
        public var adapters: [any AgentAdapter]

        public init(projectsRoot: URL,
                    stallThreshold: TimeInterval = 300,
                    workingWindow: TimeInterval = 10,
                    activeWindow: TimeInterval = 24 * 3600,
                    precisionModeEnabled: Bool = false,
                    adapters: [any AgentAdapter]? = nil) {
            self.projectsRoot = projectsRoot
            self.stallThreshold = stallThreshold
            self.workingWindow = workingWindow
            self.activeWindow = activeWindow
            self.precisionModeEnabled = precisionModeEnabled
            self.adapters = adapters ?? [ClaudeCodeAdapter(transcriptRoot: projectsRoot)]
        }
    }

    private struct TrackedSession {
        let tailer: TranscriptFileTailer
        let adapter: any AgentAdapter
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
        for adapter in configuration.adapters {
            for info in adapter.recentTranscripts(maxAge: configuration.activeWindow,
                                                  now: Date()) {
                guard let url = info.url else { continue }
                track(url: url, adapter: adapter, projectDirName: info.projectDirName)
            }
        }
    }

    /// FSEvents callback: paths that changed under any adapter root.
    public func transcriptsChanged(paths: [String]) {
        for path in paths {
            guard let adapter = configuration.adapters.first(where: { $0.isTranscript(path: path) })
            else { continue }
            let url = URL(fileURLWithPath: path)
            track(url: url, adapter: adapter,
                  projectDirName: url.deletingLastPathComponent().lastPathComponent)
        }
        rematch()
    }

    public func processesUpdated(_ update: ProcessWatcher.Update) {
        isProcessDetectionDegraded = update.degraded
        guard !update.degraded else { return }  // keep last known liveness
        latestProcessesByAdapter = update.processesByAdapter
        rematch()
    }

    public func hookSignalReceived(sessionID: String, _ signal: HookSignal) {
        sessions[sessionID]?.latestHookSignal = signal
    }

    // MARK: - Output

    public func rows(at now: Date = Date()) -> [SessionRow] {
        var rows: [SessionRow] = []
        for (id, tracked) in sessions where tracked.everHadProcess && !tracked.tailer.isSidechain {
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
                entrypoint: tracked.tailer.lastKnownEntrypoint,
                agentID: tracked.adapter.id,
                agentName: tracked.adapter.displayName))
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

    private var latestProcessesByAdapter: [String: [RunningProcess]] = [:]

    private func track(url: URL, adapter: any AgentAdapter, projectDirName: String) {
        let id = adapter.sessionID(forTranscript: url)
        if sessions[id] == nil {
            sessions[id] = TrackedSession(tailer: TranscriptFileTailer(url: url, adapter: adapter),
                                          adapter: adapter,
                                          projectDirName: projectDirName)
        }
        _ = try? sessions[id]?.tailer.catchUp()
    }

    private func rematch() {
        for adapter in configuration.adapters {
            let candidates = sessions.compactMap { id, tracked -> SessionMatchCandidate? in
                guard tracked.adapter.id == adapter.id else { return nil }
                return SessionMatchCandidate(
                    sessionID: id,
                    projectDirName: tracked.projectDirName,
                    lastKnownCWD: tracked.tailer.lastKnownCWD,
                    lastModified: tracked.tailer.lastGrowthAt ?? .distantPast)
            }
            let match = adapter.match(processes: latestProcessesByAdapter[adapter.id] ?? [],
                                      candidates: candidates)
            for candidate in candidates {
                let pid = match[candidate.sessionID]
                sessions[candidate.sessionID]?.pid = pid
                if pid != nil { sessions[candidate.sessionID]?.everHadProcess = true }
            }
        }
    }
}
