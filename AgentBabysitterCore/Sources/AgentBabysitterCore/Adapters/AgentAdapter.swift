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
    /// (tried before the pid-ancestry walk).
    var focusBundleIdentifiers: [String] { get }

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
    /// True when state comes from file activity rather than parsed turns —
    /// turn-completion notifications are unreliable for these and are
    /// suppressed.
    var isActivityBased: Bool { get }
}

public extension AgentAdapter {
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
}

/// Claude Code: `~/.claude/projects/<munged-cwd>/<session-uuid>.jsonl`.
public struct ClaudeCodeAdapter: AgentAdapter {

    public let id = "claude-code"
    public let displayName = "Claude Code"
    public let transcriptRoot: URL
    public let focusBundleIdentifiers = ["com.anthropic.claudefordesktop"]

    public init(transcriptRoot: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects")) {
        self.transcriptRoot = transcriptRoot
    }

    public func recentTranscripts(maxAge: TimeInterval, now: Date) -> [SessionFileInfo] {
        SessionDirectoryScanner.recentTranscripts(under: transcriptRoot, maxAge: maxAge, now: now)
    }

    public func isTranscript(path: String) -> Bool {
        path.hasPrefix(transcriptRoot.path) && path.hasSuffix(".jsonl")
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
