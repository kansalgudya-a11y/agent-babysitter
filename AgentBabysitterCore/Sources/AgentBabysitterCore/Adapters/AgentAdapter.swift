import Foundation

/// A session known to an adapter, described for process matching.
public struct SessionMatchCandidate: Equatable, Sendable {
    public let sessionID: String
    /// Claude-style munged project dir name ("" when the layout has none).
    public let projectDirName: String
    /// cwd learned from transcript content, when available.
    public let lastKnownCWD: String?
    public let lastModified: Date

    public init(sessionID: String, projectDirName: String,
                lastKnownCWD: String?, lastModified: Date) {
        self.sessionID = sessionID
        self.projectDirName = projectDirName
        self.lastKnownCWD = lastKnownCWD
        self.lastModified = lastModified
    }
}

/// Everything agent-specific: where transcripts live, how to parse them into
/// the normalized `TranscriptEntry` stream, and how to tie files to live
/// processes. UI, state engine, reducer, and cost never touch agent details.
public protocol AgentAdapter: Sendable {
    /// Stable identifier ("claude-code", "codex").
    var id: String { get }
    var displayName: String { get }
    var transcriptRoot: URL { get }
    /// App bundle ids to activate when focusing a session of this agent
    /// (tried before the pid-ancestry walk). Also the install signal for
    /// desktop surfaces: present in LaunchServices == installed.
    var focusBundleIdentifiers: [String] { get }
    /// CLI executables this surface ships as (e.g. "claude", "agy"). The
    /// install signal for CLI surfaces: found on the login shell PATH ==
    /// installed. Empty for desktop-only surfaces.
    var cliExecutableNames: [String] { get }

    /// Launch scan: transcript files modified within `maxAge`.
    func recentTranscripts(maxAge: TimeInterval, now: Date) -> [SessionFileInfo]
    /// Whether a changed filesystem path is one of this adapter's transcripts.
    func isTranscript(path: String) -> Bool
    /// Session id for a transcript file.
    func sessionID(forTranscript url: URL) -> String
    /// Parse one transcript line into the normalized entry model.
    func parseLine(_ line: Data) -> LineParseResult
    /// Extract this agent's pids from `ps -axo pid=,comm=` / `pid=,args=`.
    func agentPIDs(psComm: String, psArgs: String) -> [Int32]
    /// Once a pid's cwd is resolved, whether it truly belongs to this agent.
    /// Defaults to true. Surfaces that BORROW another agent's process identity
    /// (OpenClaw's SDK surface reuses the `claude` process) override this so a
    /// plain `claude` process isn't miscounted as theirs — otherwise the agent
    /// reads as "running" whenever the host agent runs, faking presence and a
    /// format-drift warning.
    func claimsProcess(cwd: String) -> Bool
    /// Pair live processes with sessions; unmatched sessions read as Ended.
    func match(processes: [RunningProcess],
               candidates: [SessionMatchCandidate]) -> [String: Int32]
    /// Map a changed filesystem path to the transcript it belongs to
    /// (e.g. SQLite `-wal`/`-shm` siblings → the base `.db`).
    func canonicalTranscriptURL(forPath path: String) -> URL
    /// Reader for one transcript. Defaults to the line tailer.
    func makeReader(url: URL) -> any SessionReading
    /// Label used when a session has no known cwd to display.
    func projectDirName(forTranscript url: URL) -> String
    /// Cumulative network bytes for a live session process, when the
    /// adapter can provide them (used as a real-time activity signal for
    /// agents whose files don't record completion). nil = unsupported.
    func liveNetworkBytes(pid: Int32) -> Int?
    /// True when state comes from file activity rather than parsed turns —
    /// turn-completion notifications are unreliable for these and are
    /// suppressed.
    var isActivityBased: Bool { get }
    /// True when sessions are PARSED out of the agent's data (so "running +
    /// files churning + zero sessions parsed" is a real format-drift signal).
    /// False for pure activity watchers, where zero parsed is normal.
    /// Defaults to !isActivityBased; Cursor overrides — its state is
    /// activity-flavored but its sessions are parsed from the database.
    var sessionsAreParsed: Bool { get }
    /// True when the adapter wants the store's network-flow probe running
    /// for its live sessions (agents whose files don't record completion).
    var usesNetworkActivity: Bool { get }
    /// True when one file hosts many sessions — session identity comes from
    /// `recentTranscripts`, not the file path, and the store rediscovers
    /// sessions whenever the shared file changes.
    var multiSessionFiles: Bool { get }
    /// True when this agent can publish a subscription usage reading (parsed
    /// from its data or read from disk). False for agents that record no quota
    /// anywhere — they stay fully tracked (sessions, tokens, cost,
    /// notifications, drift checks) but are omitted from the usage-limits list
    /// rather than shown forever as "not shared by this app".
    var publishesUsageLimit: Bool { get }
    /// The file whose modification time gates a re-read of `usageFromDisk()`.
    /// nil when the adapter publishes no on-disk quota.
    ///
    /// It may cost a small directory descent (Codex has to find its newest
    /// rollout) but not a parse: the store re-resolves it at most every few
    /// seconds and then `stat`s the result on every 2s refresh tick, on its
    /// own executor.
    func usageSourceFile() -> URL?
    /// The account-wide quota this agent persists locally. Deliberately
    /// independent of any tracked session: a weekly quota is true whether or
    /// not the app is open, so it must outlive the store's 24h active window.
    func usageFromDisk() -> UsageLimitSnapshot?
    /// Reader for a specific session id inside a multi-session file.
    /// Defaults to the per-file reader.
    func makeReader(url: URL, sessionID: String) -> any SessionReading
}

public extension AgentAdapter {
    func liveNetworkBytes(pid: Int32) -> Int? { nil }

    func claimsProcess(cwd: String) -> Bool { true }

    func canonicalTranscriptURL(forPath path: String) -> URL {
        URL(fileURLWithPath: path)
    }

    func makeReader(url: URL) -> any SessionReading {
        TranscriptFileTailer(url: url, adapter: self)
    }

    func projectDirName(forTranscript url: URL) -> String {
        url.deletingLastPathComponent().lastPathComponent
    }

    var isActivityBased: Bool { false }

    var sessionsAreParsed: Bool { !isActivityBased }

    var cliExecutableNames: [String] { [] }

    var usesNetworkActivity: Bool { false }

    var multiSessionFiles: Bool { false }

    /// Defaults TRUE on purpose: a new adapter that does publish a reading
    /// must never have it silently dropped. The cost of the wrong default is
    /// a visible "not shared by this app" row until someone sets the flag.
    var publishesUsageLimit: Bool { true }

    func usageSourceFile() -> URL? { nil }

    func usageFromDisk() -> UsageLimitSnapshot? { nil }

    func makeReader(url: URL, sessionID: String) -> any SessionReading {
        makeReader(url: url)
    }
}

/// Claude Code: `~/.claude/projects/<munged-cwd>/<session-uuid>.jsonl`.
public struct ClaudeCodeAdapter: AgentAdapter {

    public let id = "claude-code"
    public let displayName = "Claude Code"
    public let transcriptRoot: URL
    public let focusBundleIdentifiers = ["com.anthropic.claudefordesktop"]
    public let cliExecutableNames = ["claude"]

    /// Project dirs this adapter must leave to someone else. Some agents drive
    /// Claude Code through its SDK and write Claude-Code-FORMAT transcripts under
    /// our root; whoever registers that agent passes its predicate here, because
    /// a file may be tracked by only ONE adapter — `SessionStore.transcriptsChanged`
    /// dispatches a path to the FIRST adapter whose `isTranscript` matches, and the
    /// store-wide `MessageIDClaims` then hands the cost to whichever reads first,
    /// leaving the other row at $0.
    ///
    /// Defaults to excluding nothing: a store that does not register the other
    /// agent must still count these sessions, or their spend silently vanishes.
    private let excludeProjectDir: @Sendable (String) -> Bool

    public init(transcriptRoot: URL = PlatformPaths.homeDirectory(".claude/projects"),
                excludeProjectDir: @escaping @Sendable (String) -> Bool = { _ in false }) {
        self.transcriptRoot = transcriptRoot
        self.excludeProjectDir = excludeProjectDir
    }

    public func recentTranscripts(maxAge: TimeInterval, now: Date) -> [SessionFileInfo] {
        SessionDirectoryScanner.recentTranscripts(
            under: transcriptRoot, maxAge: maxAge, now: now,
            excludeProjectDir: excludeProjectDir)
    }

    public func isTranscript(path: String) -> Bool {
        guard path.hasPrefix(transcriptRoot.path), path.hasSuffix(".jsonl") else { return false }
        let project = SessionDirectoryScanner.projectDirName(
            for: URL(fileURLWithPath: path), under: transcriptRoot)
        return !excludeProjectDir(project)
    }

    /// Sub-agent transcripts nest under `<project>/<session>/subagents/`, so the
    /// immediate parent directory ("subagents") is not the project — walk back
    /// to the component directly under the root.
    public func projectDirName(forTranscript url: URL) -> String {
        SessionDirectoryScanner.projectDirName(for: url, under: transcriptRoot)
    }

    public func sessionID(forTranscript url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    public func parseLine(_ line: Data) -> LineParseResult {
        TranscriptLineParser.parse(line)
    }

    public func agentPIDs(psComm: String, psArgs: String) -> [Int32] {
        Array(Set(ProcessOutputParser.claudePIDs(fromPSComm: psComm))
            .union(ProcessOutputParser.claudePIDs(fromPS: psArgs))).sorted()
    }

    public func match(processes: [RunningProcess],
                      candidates: [SessionMatchCandidate]) -> [String: Int32] {
        SessionProcessMatcher.match(
            processes: processes,
            sessions: candidates.map {
                SessionFileInfo(sessionID: $0.sessionID,
                                projectDirName: $0.projectDirName,
                                lastModified: $0.lastModified)
            })
    }
}
