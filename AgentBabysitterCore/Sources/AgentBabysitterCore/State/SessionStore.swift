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
    /// The transcript/conversation file backing this row.
    public var transcriptURL: URL?
    /// State derives from file activity (no parsed turns) — see AgentAdapter.
    public var isActivityBased: Bool

    /// Session hosted by a desktop app rather than a terminal.
    public var isDesktopApp: Bool {
        entrypoint?.hasPrefix("claude-desktop") == true
            || entrypoint?.hasPrefix("Codex Desktop") == true
            || entrypoint == "Antigravity"
            || entrypoint == "Antigravity IDE"
    }

    public init(id: String, projectName: String, state: SessionState,
                turnStartedAt: Date?, lastGrowthAt: Date?, isUnreadable: Bool,
                pid: Int32?, cwd: String?, cost: SessionCost = SessionCost(),
                entrypoint: String? = nil,
                agentID: String = "claude-code", agentName: String = "Claude Code",
                transcriptURL: URL? = nil, isActivityBased: Bool = false) {
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
        self.transcriptURL = transcriptURL
        self.isActivityBased = isActivityBased
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
        let reader: any SessionReading
        let adapter: any AgentAdapter
        let projectDirName: String
        var pid: Int32?
        /// Sessions never seen with a process stay hidden (launch scan finds
        /// a day's worth of dead transcripts).
        var everHadProcess = false
        var latestHookSignal: HookSignal?
        /// User dismissed the row; cleared automatically on new activity.
        var dismissedAfter: Date?
    }

    public private(set) var configuration: Configuration
    public private(set) var isProcessDetectionDegraded = false

    /// Keyed by "<adapterID>/<sessionID>" — session ids are only unique per
    /// agent.
    private var sessions: [String: TrackedSession] = [:]
    /// Hook signals that arrived before their session was tracked (hooks can
    /// beat FSEvents latency for brand-new sessions).
    private var pendingHookSignals: [String: HookSignal] = [:]

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
            let url = adapter.canonicalTranscriptURL(forPath: path)
            track(url: url, adapter: adapter,
                  projectDirName: adapter.projectDirName(forTranscript: url))
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
        // Hooks are a Claude Code feature; route within that namespace.
        let key = "claude-code/\(sessionID)"
        if sessions[key] != nil {
            sessions[key]?.latestHookSignal = signal
        } else {
            pendingHookSignals[key] = signal
        }
    }

    /// Hide a session row until it shows new activity.
    public func dismissSession(id: String, agentID: String) {
        let key = "\(agentID)/\(id)"
        // Two-step to avoid overlapping dictionary access (exclusivity).
        guard var tracked = sessions[key] else { return }
        tracked.dismissedAfter = tracked.reader.lastGrowthAt ?? Date()
        sessions[key] = tracked
    }

    // MARK: - Output

    public func rows(at now: Date = Date()) -> [SessionRow] {
        prune(at: now)
        var rows: [SessionRow] = []
        for (_, tracked) in sessions where tracked.everHadProcess && !tracked.reader.isSidechain {
            if let dismissedAfter = tracked.dismissedAfter,
               (tracked.reader.lastGrowthAt ?? .distantPast) <= dismissedAfter {
                continue
            }
            let signals = SessionSignals(
                processAlive: tracked.pid != nil,
                lastGrowthAt: tracked.reader.lastGrowthAt,
                turnPhase: tracked.reader.turnPhase,
                hasPendingToolUses: tracked.reader.hasPendingToolUses,
                latestHookEvent: tracked.latestHookSignal,
                precisionModeEnabled: configuration.precisionModeEnabled)
            let state = SessionStateEngine.evaluate(signals, at: now,
                                                    stallThreshold: configuration.stallThreshold,
                                                    workingWindow: configuration.workingWindow)
            let cwd = tracked.reader.lastKnownCWD
            rows.append(SessionRow(
                id: tracked.reader.sessionID,
                projectName: cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
                    ?? tracked.projectDirName,
                state: state,
                turnStartedAt: tracked.reader.currentTurnStartedAt,
                lastGrowthAt: tracked.reader.lastGrowthAt,
                isUnreadable: tracked.reader.isUnreadable,
                pid: tracked.pid,
                cwd: cwd,
                cost: tracked.reader.cost,
                entrypoint: tracked.reader.lastKnownEntrypoint,
                agentID: tracked.adapter.id,
                agentName: tracked.adapter.displayName,
                transcriptURL: tracked.reader.url,
                isActivityBased: tracked.adapter.isActivityBased))
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

    /// Dollars attributed to entries whose own timestamps fall today —
    /// sessions spanning midnight contribute only today's portion. Includes
    /// sessions hidden from the row list; recomputed from transcripts, no
    /// cost database.
    public func todayCost(at now: Date = Date(),
                          calendar: Calendar = .current) -> SessionCost {
        let midnight = calendar.startOfDay(for: now)
        var total = SessionCost()
        for (_, tracked) in sessions {
            guard let daily = tracked.reader.dailyCosts[midnight] else { continue }
            total.dollars += daily.dollars
            total.totalTokens += daily.totalTokens
            total.unknownModels.formUnion(daily.unknownModels)
        }
        return total
    }

    /// Latest rate-limit reading per agent, newest capture wins. Codex writes
    /// a real percentage to disk; Antigravity contributes its plan name (from
    /// the IDE's stored state, no percentage exists locally); Claude Code has
    /// no on-disk data (the app layer may add a live reading).
    public func usageLimits() -> [String: UsageLimitSnapshot] {
        var latest: [String: UsageLimitSnapshot] = [:]
        for (_, tracked) in sessions {
            guard let limit = tracked.reader.usageLimit else { continue }
            if let existing = latest[tracked.adapter.id],
               existing.capturedAt >= limit.capturedAt { continue }
            latest[tracked.adapter.id] = limit
        }
        // Antigravity: fill the five-hour quota (and plan) from the IDE state
        // for every installed surface — the same numbers the app's own Model
        // Quota page shows, read from disk with zero network. The quota is
        // account-wide, so it's valid whether or not a session is running.
        if let usage = antigravityUsage() {
            for adapter in configuration.adapters
            where adapter.id.hasPrefix("antigravity") && latest[adapter.id] == nil {
                latest[adapter.id] = usage
            }
        }
        return latest
    }

    /// Agents whose app/CLI currently has a matching process — "open".
    public func runningAgentIDs() -> Set<String> {
        Set(latestProcessesByAdapter.filter { !$0.value.isEmpty }.keys)
    }

    private var antigravityUsageCache: (mtime: Date, usage: UsageLimitSnapshot?)?

    /// The state file is a few MB of SQLite copied to a temp file to read;
    /// cache by mtime so the 2s refresh tick doesn't reparse it.
    private func antigravityUsage() -> UsageLimitSnapshot? {
        guard configuration.adapters.contains(where: { $0.id.hasPrefix("antigravity") }),
              let mtime = (try? FileManager.default.attributesOfItem(
                  atPath: AntigravityAdapter.defaultStateDBURL.path))?[.modificationDate] as? Date
        else { return nil }
        if let cache = antigravityUsageCache, cache.mtime == mtime { return cache.usage }
        var usage: UsageLimitSnapshot?
        for case let adapter as AntigravityAdapter in configuration.adapters {
            if let found = adapter.usageFromDisk() { usage = found; break }
        }
        antigravityUsageCache = (mtime, usage)
        return usage
    }

    // MARK: - Internals

    private var latestProcessesByAdapter: [String: [RunningProcess]] = [:]

    private func track(url: URL, adapter: any AgentAdapter, projectDirName: String) {
        let key = "\(adapter.id)/\(adapter.sessionID(forTranscript: url))"
        if sessions[key] == nil {
            BabysitterLog.store.info("tracking session \(key, privacy: .public)")
            sessions[key] = TrackedSession(reader: adapter.makeReader(url: url),
                                           adapter: adapter,
                                           projectDirName: projectDirName)
            if let buffered = pendingHookSignals.removeValue(forKey: key) {
                sessions[key]?.latestHookSignal = buffered
            }
        }
        try? sessions[key]?.reader.refresh()
    }

    /// Drop sessions with no live process and no activity inside the active
    /// window — a long-running app would otherwise accumulate every session
    /// it ever saw.
    private func prune(at now: Date) {
        let cutoff = now.addingTimeInterval(-configuration.activeWindow)
        let stale = sessions.filter { _, tracked in
            tracked.pid == nil
                && (tracked.reader.lastGrowthAt ?? .distantPast) < cutoff
        }.keys
        for key in stale {
            BabysitterLog.store.info("pruning idle session \(key, privacy: .public)")
            sessions.removeValue(forKey: key)
        }
        pendingHookSignals = pendingHookSignals.filter { _, signal in
            signal.timestamp >= cutoff
        }
    }

    private func rematch() {
        for adapter in configuration.adapters {
            let candidates = sessions.compactMap { key, tracked -> SessionMatchCandidate? in
                guard tracked.adapter.id == adapter.id else { return nil }
                return SessionMatchCandidate(
                    sessionID: key,
                    projectDirName: tracked.projectDirName,
                    lastKnownCWD: tracked.reader.lastKnownCWD,
                    lastModified: tracked.reader.lastGrowthAt ?? .distantPast)
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
