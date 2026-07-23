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
    /// The latest hook signal's text, when Precision mode captured one:
    /// the pending question for waiting rows, the reply's first line for
    /// done rows. Nil without hooks.
    public var hookDetail: HookSignal?
    /// "What it's working on": the user's last real prompt, one line.
    /// Nil for agents whose storage doesn't expose prompts.
    public var title: String?
    /// Error text when the session's LATEST assistant turn was an API error
    /// (Claude Code's synthetic `isApiErrorMessage` line) — the row is
    /// currently failing. Nil when the last output was healthy: an annotation
    /// carried alongside the state, not a new lifecycle state.
    public var apiError: String?

    /// Session hosted by a desktop app rather than a terminal.
    public var isDesktopApp: Bool {
        entrypoint?.hasPrefix("claude-desktop") == true
            || entrypoint?.hasPrefix("Codex Desktop") == true
            || entrypoint == "Antigravity"
            || entrypoint == "Antigravity IDE"
            || entrypoint == "Gemini"
            || entrypoint == "Cursor"
            || entrypoint == "Manus"
    }

    public init(id: String, projectName: String, state: SessionState,
                turnStartedAt: Date?, lastGrowthAt: Date?, isUnreadable: Bool,
                pid: Int32?, cwd: String?, cost: SessionCost = SessionCost(),
                entrypoint: String? = nil,
                agentID: String = "claude-code", agentName: String = "Claude Code",
                transcriptURL: URL? = nil, isActivityBased: Bool = false,
                hookDetail: HookSignal? = nil, title: String? = nil,
                apiError: String? = nil) {
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
        self.hookDetail = hookDetail
        self.title = title
        self.apiError = apiError
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

        /// Hide finished (done/ended) rows this long after their last
        /// activity; nil keeps them until the active-window prune. Costs and
        /// limits still include hidden sessions.
        public var doneAutoHide: TimeInterval?

        /// How long a resolved `usageSourceFile()` is trusted before being
        /// resolved again. Not free for every adapter (Codex's is a directory
        /// descent) and the refresh tick is 2s, so this is what keeps a closed
        /// agent's quota row from costing a directory walk every tick.
        public var usageSourceRecheck: TimeInterval

        /// Ceiling on how long a cached on-disk reading may be served while
        /// its source file's mtime is unchanged — the safety net for an mtime
        /// that can never change again (see `diskUsage(for:source:)`).
        public var usageRereadInterval: TimeInterval

        public init(projectsRoot: URL,
                    stallThreshold: TimeInterval = 300,
                    workingWindow: TimeInterval = 10,
                    activeWindow: TimeInterval = 24 * 3600,
                    precisionModeEnabled: Bool = false,
                    adapters: [any AgentAdapter]? = nil,
                    doneAutoHide: TimeInterval? = 10 * 60,
                    usageSourceRecheck: TimeInterval = 15,
                    usageRereadInterval: TimeInterval = 600) {
            self.usageSourceRecheck = usageSourceRecheck
            self.usageRereadInterval = usageRereadInterval
            self.projectsRoot = projectsRoot
            self.stallThreshold = stallThreshold
            self.workingWindow = workingWindow
            self.activeWindow = activeWindow
            self.precisionModeEnabled = precisionModeEnabled
            self.adapters = adapters ?? [ClaudeCodeAdapter(transcriptRoot: projectsRoot)]
            self.doneAutoHide = doneAutoHide
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
    /// Shared across every session's cost accumulator: a resumed transcript
    /// repeats the earlier session's messages verbatim, so bill each once.
    private let costClaims = MessageIDClaims()
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
                // Parse each transcript inside its own autorelease pool. The
                // first refresh of a large file bridges autoreleased JSON
                // objects (NSString/NSDictionary out of JSONSerialization) that
                // would otherwise accumulate until this whole scan returns —
                // the driver of the launch/rescan memory peak. Draining per file
                // caps the peak at roughly one file's worth. (Deeper streaming
                // reads live in the reader, not here — see report.)
                autoreleasepool {
                    track(url: url, adapter: adapter,
                          projectDirName: info.projectDirName,
                          sessionID: info.sessionID)
                }
            }
        }
    }

    /// FSEvents callback: paths that changed under any adapter root.
    public func transcriptsChanged(paths: [String]) {
        for path in paths {
            guard let adapter = configuration.adapters.first(where: { $0.isTranscript(path: path) })
            else { continue }
            if adapter.multiSessionFiles {
                // Session identity lives INSIDE the file - re-discover.
                for info in adapter.recentTranscripts(maxAge: configuration.activeWindow,
                                                      now: Date()) {
                    guard let url = info.url else { continue }
                    track(url: url, adapter: adapter,
                          projectDirName: info.projectDirName,
                          sessionID: info.sessionID)
                }
            } else {
                let url = adapter.canonicalTranscriptURL(forPath: path)
                track(url: url, adapter: adapter,
                      projectDirName: adapter.projectDirName(forTranscript: url))
            }
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

    /// A Claude Code sub-agent transcript lives at
    /// `<project>/<parentSessionID>/subagents/agent-*.jsonl` — recover the parent
    /// session id from that path so its spend can roll into the parent's row.
    /// nil when the layout isn't the nested-subagent shape (e.g. Codex).
    static func parentSessionID(forSidechain url: URL) -> String? {
        let subagentsDir = url.deletingLastPathComponent()
        guard subagentsDir.lastPathComponent == "subagents" else { return nil }
        let parent = subagentsDir.deletingLastPathComponent().lastPathComponent
        return parent.isEmpty ? nil : parent
    }

    public func rows(at now: Date = Date(),
                     includeHidden: Bool = false) -> [SessionRow] {
        reconcileWithDisk()
        prune(at: now)
        // Sub-agents (sidechains) spend real money that lands in the day total
        // but get no row of their own — that's the "money with no source" a user
        // sees. Roll each one's cost into the row of the session that spawned it
        // (Claude Code nests them at <project>/<parentID>/subagents/…), so the
        // visible rows account for it. The day total is unaffected — it already
        // sums every session directly.
        var sidechainCostByParent: [String: SessionCost] = [:]
        // A parent that is only delegating writes nothing to its OWN transcript
        // while its sub-agents run, so on its own liveness it would slide to
        // Stalled/Ended. Fold the newest sidechain growth into the parent's
        // liveness (used at `effectiveGrowth` below) so a delegating session
        // stays Working while its children are actively writing.
        var sidechainGrowthByParent: [String: Date] = [:]
        for (_, tracked) in sessions where tracked.reader.isSidechain {
            guard let parentID = Self.parentSessionID(forSidechain: tracked.reader.url)
            else { continue }
            let parentKey = "\(tracked.adapter.id)/\(parentID)"
            sidechainCostByParent[parentKey, default: SessionCost()].merge(tracked.reader.cost)
            if let growth = tracked.reader.lastGrowthAt {
                sidechainGrowthByParent[parentKey] =
                    [sidechainGrowthByParent[parentKey], growth].compactMap { $0 }.max()
            }
        }
        var rows: [SessionRow] = []
        for (_, tracked) in sessions where tracked.everHadProcess && !tracked.reader.isSidechain {
            if let dismissedAfter = tracked.dismissedAfter,
               (tracked.reader.lastGrowthAt ?? .distantPast) <= dismissedAfter {
                continue
            }
            // Real-time network signal: a streaming reply is continuous
            // flow. Sampling shells nettop, which can stall, so it runs in
            // a detached probe loop - rows() only reads the cached result.
            let key = "\(tracked.adapter.id)/\(tracked.reader.sessionID)"
            if let pid = tracked.pid, tracked.adapter.usesNetworkActivity {
                startNetProbeIfNeeded(key: key, pid: pid, adapter: tracked.adapter)
            }
            let effectiveGrowth = [tracked.reader.lastGrowthAt, netActiveAt[key],
                                   sidechainGrowthByParent[key]]
                .compactMap { $0 }.max()
            let signals = SessionSignals(
                processAlive: tracked.pid != nil,
                lastGrowthAt: effectiveGrowth,
                turnPhase: tracked.reader.turnPhase,
                hasPendingToolUses: tracked.reader.hasPendingToolUses,
                latestHookEvent: tracked.latestHookSignal,
                precisionModeEnabled: configuration.precisionModeEnabled)
            let state = SessionStateEngine.evaluate(signals, at: now,
                                                    stallThreshold: configuration.stallThreshold,
                                                    workingWindow: configuration.workingWindow)
            // Finished sessions tidy themselves away after a while; a new
            // write revives the row (state re-derives every refresh).
            // includeHidden serves lookups that must reach them anyway,
            // like clicking an older notification.
            if !includeHidden, let hideAfter = configuration.doneAutoHide,
               state == .done || state == .ended,
               now.timeIntervalSince(tracked.reader.lastGrowthAt ?? .distantPast) > hideAfter {
                continue
            }
            let cwd = tracked.reader.lastKnownCWD
            var combinedCost = tracked.reader.cost
            if let subCost = sidechainCostByParent[key] { combinedCost.merge(subCost) }
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
                cost: combinedCost,
                entrypoint: tracked.reader.lastKnownEntrypoint,
                agentID: tracked.adapter.id,
                agentName: tracked.adapter.displayName,
                transcriptURL: tracked.reader.url,
                isActivityBased: tracked.adapter.isActivityBased,
                hookDetail: tracked.latestHookSignal,
                title: tracked.reader.lastPromptTitle,
                apiError: tracked.reader.lastAPIError))
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

    /// Summary from rows the caller already fetched. The hot refresh path builds
    /// the row list once and passes it here instead of paying a second full
    /// `rows()` pass (which re-copies every session's cost). `nonisolated` so the
    /// caller derives it without a second actor hop. The zero-arg overload above
    /// stays for the debug CLI and tests.
    public nonisolated func menuBarSummary(from rows: [SessionRow]) -> MenuBarSummary {
        MenuBarSummary(worstState: SessionState.worst(of: rows.map(\.state)),
                       activeCount: rows.filter { $0.state != .ended }.count)
    }

    /// Dollars attributed to entries whose own timestamps fall today —
    /// sessions spanning midnight contribute only today's portion. Includes
    /// sessions hidden from the row list; recomputed from transcripts, no
    /// cost database.
    public func todayCost(at now: Date = Date(),
                          timeZone: TimeZone = .current) -> SessionCost {
        let midnight = LocalDay.start(of: now, timeZone: timeZone)
        var total = SessionCost()
        for (_, tracked) in sessions {
            guard let daily = tracked.reader.dailyCosts[midnight] else { continue }
            total.dollars += daily.dollars
            total.totalTokens += daily.totalTokens
            total.inputTokens += daily.inputTokens
            total.outputTokens += daily.outputTokens
            total.cacheReadTokens += daily.cacheReadTokens
            total.cacheWriteTokens += daily.cacheWriteTokens
            total.unknownModels.formUnion(daily.unknownModels)
        }
        return total
    }

    /// Today's dollars per agent — the stats view's raw material.
    public func todayCostByAgent(at now: Date = Date(),
                                 timeZone: TimeZone = .current) -> [String: Double] {
        let midnight = LocalDay.start(of: now, timeZone: timeZone)
        var totals: [String: Double] = [:]
        for (_, tracked) in sessions {
            guard let daily = tracked.reader.dailyCosts[midnight] else { continue }
            totals[tracked.adapter.id, default: 0] += daily.dollars
        }
        return totals
    }

    /// Today's dollars grouped by project (cwd folder name), for the stats
    /// window's per-project breakdown. Sessions with no readable cwd fall
    /// under their display label.
    public func todayCostByProject(at now: Date = Date(),
                                   timeZone: TimeZone = .current) -> [String: Double] {
        let midnight = LocalDay.start(of: now, timeZone: timeZone)
        var totals: [String: Double] = [:]
        for (_, tracked) in sessions {
            guard let daily = tracked.reader.dailyCosts[midnight], daily.dollars > 0 else { continue }
            let project = tracked.reader.lastKnownCWD
                .map { URL(fileURLWithPath: $0).lastPathComponent } ?? tracked.projectDirName
            totals[project, default: 0] += daily.dollars
        }
        return totals
    }

    /// Today's dollars per model across all sessions (priced models only).
    public func todayCostByModel(at now: Date = Date(),
                                 timeZone: TimeZone = .current) -> [String: Double] {
        let midnight = LocalDay.start(of: now, timeZone: timeZone)
        var totals: [String: Double] = [:]
        for (_, tracked) in sessions {
            for (model, dollars) in tracked.reader.dailyDollarsByModel[midnight] ?? [:] {
                totals[model, default: 0] += dollars
            }
        }
        return totals
    }

    public struct TodayBreakdown: Sendable {
        public let byAgent: [String: Double]
        public let byProject: [String: Double]
        public let byModel: [String: Double]
    }

    /// All three of today's breakdowns from ONE consistent pass over the
    /// sessions. Computing them as three separate actor calls let a session's
    /// `dailyCosts` mutate between them, so the per-model total could disagree
    /// with the per-agent total for the same tick.
    public func todayBreakdown(at now: Date = Date(),
                               timeZone: TimeZone = .current) -> TodayBreakdown {
        let midnight = LocalDay.start(of: now, timeZone: timeZone)
        var byAgent: [String: Double] = [:]
        var byProject: [String: Double] = [:]
        var byModel: [String: Double] = [:]
        for (_, tracked) in sessions {
            if let daily = tracked.reader.dailyCosts[midnight] {
                byAgent[tracked.adapter.id, default: 0] += daily.dollars
                if daily.dollars > 0 {
                    let project = tracked.reader.lastKnownCWD
                        .map { URL(fileURLWithPath: $0).lastPathComponent } ?? tracked.projectDirName
                    byProject[project, default: 0] += daily.dollars
                }
            }
            for (model, dollars) in tracked.reader.dailyDollarsByModel[midnight] ?? [:] {
                byModel[model, default: 0] += dollars
            }
        }
        return TodayBreakdown(byAgent: byAgent, byProject: byProject, byModel: byModel)
    }

    /// Latest rate-limit reading per agent, newest capture wins. Agents that
    /// persist an account-wide quota locally (Codex rollouts, Cursor's state
    /// db, Antigravity's IDE state) fill any id no live session supplies —
    /// those quotas are account-wide and stay valid for days, so they must
    /// outlive the 24h active window that drops the session they were written
    /// in. Claude Code has no on-disk data (the app layer may add a live one).
    ///
    /// Gemini is deliberately left with NO snapshot. Its real usage %
    /// (the numbers on gemini.google.com/usage) is fetched live by the
    /// Gemini app from Google's servers behind a web login and is never
    /// written to disk — verified: the desktop app only logs "0 modes
    /// over quota", and the CLI OAuth token reaches Code Assist (tier
    /// only, no %). Showing Antigravity's plan tier here was misleading,
    /// so the UI links straight to the usage page instead.
    public func usageLimits() -> [String: UsageLimitSnapshot] {
        var latest: [String: UsageLimitSnapshot] = [:]
        for (_, tracked) in sessions {
            guard tracked.adapter.publishesUsageLimit,
                  let limit = tracked.reader.usageLimit else { continue }
            if let existing = latest[tracked.adapter.id],
               existing.capturedAt >= limit.capturedAt { continue }
            latest[tracked.adapter.id] = limit
        }
        // Fill holes only: a live session's reading always wins, and the guard
        // runs BEFORE the adapter resolves its source file, so a running agent
        // costs nothing here.
        var reachable: Set<String> = []
        for adapter in configuration.adapters
        where adapter.publishesUsageLimit && latest[adapter.id] == nil {
            guard let source = diskUsageSource(for: adapter) else { continue }
            reachable.insert(source.path)
            if let usage = diskUsage(for: adapter, source: source) { latest[adapter.id] = usage }
        }
        // Bound the cache to the sources still in play. It is keyed by PATH,
        // and Codex's path is whichever rollout is newest — a new one per
        // session — so without this it grows one dead entry per Codex session
        // for the lifetime of a process that runs for weeks. Dropping an entry
        // costs at most one re-read the next time that path is resolved.
        if diskUsageCache.count > reachable.count {
            diskUsageCache = diskUsageCache.filter { reachable.contains($0.key) }
        }
        return latest
    }

    /// Agents whose app/CLI currently has a matching process — "open".
    public func runningAgentIDs() -> Set<String> {
        Set(latestProcessesByAdapter.filter { !$0.value.isEmpty }.keys)
    }

    /// How many sessions we currently track per agent — INCLUDING ones hidden
    /// from the row list. The drift check uses this (not visible rows) so an
    /// agent whose sessions are merely auto-hidden isn't mistaken for one we
    /// can no longer read.
    public func trackedSessionCounts() -> [String: Int] {
        var counts: [String: Int] = [:]
        for (_, tracked) in sessions where !tracked.reader.isSidechain {
            counts[tracked.adapter.id, default: 0] += 1
        }
        return counts
    }

    /// Keyed by SOURCE PATH, not adapter id: Antigravity's three surfaces all
    /// resolve the same shared state.vscdb, so they share one parse (the old
    /// bespoke fan-out loop's behaviour, preserved). Path+mtime, not mtime
    /// alone — the caches this replaced keyed on mtime only, a latent bug if a
    /// root changes under `updateConfiguration(_:)`. Negative results are
    /// cached too: a missing or corrupt source must cost one stat per tick,
    /// not one parse.
    private var diskUsageCache: [String: (mtime: Date, readAt: Date,
                                          usage: UsageLimitSnapshot?)] = [:]
    /// Resolved source path per adapter id — see `diskUsageSource(for:)`.
    private var diskUsageSources: [String: (url: URL?, resolvedAt: Date)] = [:]
    /// Resolving the source is NOT uniformly cheap: Cursor and Antigravity
    /// return a constant path, but Codex's is a directory descent (measured on
    /// the author's archive: ~5 `contentsOfDirectory` calls, 51 stats and a
    /// 51-element sort, 0.62 ms) and it would otherwise run on every 2s tick
    /// for as long as Codex is closed — precisely the state this fallback
    /// exists to serve, and one that lasts days. Re-resolve at most once per
    /// `configuration.usageSourceRecheck`; the `stat` in `diskUsage` still
    /// runs every tick, so a CHANGED file is still picked up immediately.
    private func diskUsageSource(for adapter: any AgentAdapter) -> URL? {
        let now = Date()
        if let cached = diskUsageSources[adapter.id],
           now.timeIntervalSince(cached.resolvedAt) < configuration.usageSourceRecheck,
           now >= cached.resolvedAt {
            return cached.url
        }
        let url = adapter.usageSourceFile()
        diskUsageSources[adapter.id] = (url, now)
        return url
    }

    /// Reading these sources is expensive — a multi-MB SQLite copy for
    /// Cursor/Antigravity, tail-reads across many rollouts for Codex — and the
    /// refresh tick runs every 2s on this actor. The mtime gate keeps the
    /// steady-state cost at one `stat` plus (at most every 15s) one source
    /// resolution.
    ///
    /// The age ceiling is a safety net for the one way an mtime gate can wedge
    /// permanently: a file whose mtime is in the future or otherwise frozen
    /// (restored from backup, synced from another machine, bad clock) would
    /// otherwise compare equal forever and pin a stale reading on screen with
    /// no error and no way out. One re-read per 10 minutes is not a cost worth
    /// defending against.
    private func diskUsage(for adapter: any AgentAdapter, source: URL) -> UsageLimitSnapshot? {
        guard let mtime = Self.modificationDate(ofPath: source.path) else { return nil }
        let now = Date()
        if let cache = diskUsageCache[source.path], cache.mtime == mtime,
           now.timeIntervalSince(cache.readAt) < configuration.usageRereadInterval,
           now >= cache.readAt {
            return cache.usage
        }
        let usage = adapter.usageFromDisk()
        diskUsageCache[source.path] = (mtime, now, usage)
        return usage
    }

    // MARK: - Internals

    private var latestProcessesByAdapter: [String: [RunningProcess]] = [:]
    /// Network-flow sampling for adapters that provide it: last cumulative
    /// byte count per session key, and when flow was last observed.
    private var netSamples: [String: (bytes: Int, at: Date)] = [:]
    private var netActiveAt: [String: Date] = [:]
    private var netProbes: [String: Task<Void, Never>] = [:]
    private var reconcileMtimes: [String: Date] = [:]

    /// File mtime via a single `stat(2)`. `FileManager.attributesOfItem` builds
    /// a whole attribute dictionary (owner, permissions, type, four dates…) to
    /// hand back the one field we read, and — per the audit's measurement — is
    /// ~35x more expensive; this runs for every tracked transcript on every 2s
    /// tick, so the difference is the biggest slice of the app's resting CPU.
    /// Returns nil when the path can't be stat'd (missing/unreadable).
    private static func modificationDate(ofPath path: String) -> Date? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                    + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
    }

    /// FSEvents occasionally drops events (observed live: a session grew
    /// and the app never heard). A cheap stat per tracked transcript on
    /// every rows() pass guarantees growth is noticed within one tick.
    private func reconcileWithDisk() {
        for (key, tracked) in sessions {
            let url = tracked.reader.url
            var newest = Self.modificationDate(ofPath: url.path) ?? .distantPast
            for suffix in ["-wal", "-shm"] {
                if let m = Self.modificationDate(ofPath: url.path + suffix) {
                    newest = max(newest, m)
                }
            }
            if let seen = reconcileMtimes[key], newest <= seen { continue }
            reconcileMtimes[key] = newest
            try? sessions[key]?.reader.refresh()
        }
    }

    /// Detached loop: sample the adapter's byte counter every 2.5s, record
    /// activity on >2KB deltas, stop when the session loses that process.
    private func startNetProbeIfNeeded(key: String, pid: Int32, adapter: any AgentAdapter) {
        guard netProbes[key] == nil else { return }
        netProbes[key] = Task.detached { [weak self] in
            defer { Task { [weak self] in await self?.clearNetProbe(key: key) } }
            while !Task.isCancelled {
                guard let self else { return }
                guard await self.sessionStillHas(pid: pid, key: key) else { return }
                if let bytes = adapter.liveNetworkBytes(pid: pid) {
                    await self.recordNetSample(key: key, bytes: bytes)
                }
                try? await Task.sleep(nanoseconds: 2_500_000_000)
            }
        }
    }

    private func sessionStillHas(pid: Int32, key: String) -> Bool {
        sessions[key]?.pid == pid
    }

    private func recordNetSample(key: String, bytes: Int) {
        if let last = netSamples[key], bytes - last.bytes > 2048 {
            netActiveAt[key] = Date()
        }
        netSamples[key] = (bytes, Date())
    }

    private func clearNetProbe(key: String) {
        netProbes[key] = nil
    }

    private func track(url: URL, adapter: any AgentAdapter, projectDirName: String,
                       sessionID: String? = nil) {
        let id = sessionID ?? adapter.sessionID(forTranscript: url)
        let key = "\(adapter.id)/\(id)"
        if sessions[key] == nil {
            BabysitterLog.store.info("tracking session \(key, privacy: .public)")
            let reader = adapter.makeReader(url: url, sessionID: id)
            // Share one message-id registry across every session so a resumed
            // transcript's copied conversation isn't billed a second time.
            reader.adoptCostClaims(costClaims)
            sessions[key] = TrackedSession(reader: reader,
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
            // Hand its messages back so a surviving transcript that also holds
            // them (a resume of this session) can count them instead.
            if let reader = sessions[key]?.reader {
                costClaims.release(owner: reader.sessionID)
            }
            sessions.removeValue(forKey: key)
            // Every per-session dictionary keyed by the same key must be pruned
            // in lockstep, or a process that runs for weeks accumulates one dead
            // entry apiece for every session it ever saw. The net probe would
            // self-clear via its own defer once its pid goes nil, but cancel it
            // here so the detached loop stops now instead of on its next wake.
            netSamples.removeValue(forKey: key)
            netActiveAt.removeValue(forKey: key)
            reconcileMtimes.removeValue(forKey: key)
            netProbes.removeValue(forKey: key)?.cancel()
        }
        pendingHookSignals = pendingHookSignals.filter { _, signal in
            signal.timestamp >= cutoff
        }
    }

    private func rematch() {
        for adapter in configuration.adapters {
            let candidates = sessions.compactMap { key, tracked -> SessionMatchCandidate? in
                // Sidechains (sub-agent transcripts) never compete for a process.
                // A Claude Code sub-agent lives in the SAME project dir as its
                // parent and, while it is being written, is the newest transcript
                // there — so the matcher (newest-first within a dir) would award
                // the parent's single pid to the sidechain. The parent transcript
                // would then read unpaired → Ended → auto-hidden, and the live
                // parent gets no row at all during exactly the fan-out workload
                // this app exists for. Excluding sidechains leaves the parent as
                // the sole candidate in its dir, so it keeps the pid and its row.
                guard tracked.adapter.id == adapter.id, !tracked.reader.isSidechain
                else { return nil }
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
        // A sidechain must never carry a pid: it is excluded from matching above,
        // so any pid it still holds is stale (assigned in an earlier tick before
        // its first line revealed `isSidechain`). Clear it so a sidechain can
        // never be read as "alive" — it contributes only cost and growth to its
        // parent, never a process. (Collect keys first, then mutate, to avoid
        // overlapping access to `sessions`.)
        let sidechainKeys = sessions.compactMap { key, tracked in
            tracked.reader.isSidechain ? key : nil
        }
        for key in sidechainKeys { sessions[key]?.pid = nil }
    }
}
