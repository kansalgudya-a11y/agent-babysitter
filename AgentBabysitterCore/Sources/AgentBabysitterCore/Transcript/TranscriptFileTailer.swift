import Foundation

/// Tracks one transcript file: reads only bytes appended since the last call,
/// feeds them through the parser into a reducer, and remembers growth times
/// from file mtime (so a launch scan of an old transcript doesn't read as
/// fresh activity).
public final class TranscriptFileTailer {

    public let url: URL
    /// Session id, derived from the transcript filename by the adapter.
    public let sessionID: String

    public private(set) var reducer = TranscriptReducer()
    public private(set) var costAccumulator = CostAccumulator()
    public private(set) var lastGrowthAt: Date?
    /// cwd from the most recent entry that carried one.
    public private(set) var lastKnownCWD: String?
    /// entrypoint from the most recent entry that carried one
    /// ("claude-desktop", "sdk-cli", "Codex Desktop", …).
    public private(set) var lastKnownEntrypoint: String?
    /// True once any entry marks this session as a subagent/sidechain —
    /// hidden from the session list.
    public private(set) var isSidechain = false
    /// Latest rate-limit reading in file order.
    public private(set) var lastUsageLimit: UsageLimitSnapshot?
    /// Error text of the MOST RECENT assistant turn, but only when that turn
    /// was an API error (top-level `isApiErrorMessage`); nil once a later
    /// healthy assistant turn clears it. A session that erred and then
    /// recovered must not read as erroring — only a current failure counts.
    public private(set) var lastAPIError: String?

    private let makeParser: @Sendable () -> TranscriptTailParser
    private var offset: UInt64 = 0
    private var parser: TranscriptTailParser
    /// Store-wide message-id registry, so a conversation copied into a resumed
    /// session's transcript is billed once, not once per file.
    private var claims: MessageIDClaims?

    /// Called by the store right after the reader is built (before any read).
    public func adoptCostClaims(_ claims: MessageIDClaims) {
        self.claims = claims
        costAccumulator = CostAccumulator(claims: claims, owner: sessionID)
    }

    /// A transcript with this many undecodable lines is presumed corrupt;
    /// keep watching others but stop trusting this one.
    public static let unreadableThreshold = 50

    public var isUnreadable: Bool {
        parser.malformedLineCount > Self.unreadableThreshold
    }

    /// Claude Code layout/schema (tests and default wiring).
    public convenience init(url: URL) {
        self.init(url: url, adapter: ClaudeCodeAdapter())
    }

    public convenience init(url: URL, adapter: any AgentAdapter) {
        self.init(url: url,
                  sessionID: adapter.sessionID(forTranscript: url),
                  makeParser: { TranscriptTailParser(parseLine: { adapter.parseLine($0) }) })
    }

    /// Designated: a fresh parser per (re)build so adapters can hand out
    /// stateful line parsers (e.g. Codex's cumulative usage counter).
    public init(url: URL, sessionID: String,
                makeParser: @escaping @Sendable () -> TranscriptTailParser) {
        self.url = url
        self.sessionID = sessionID
        self.makeParser = makeParser
        self.parser = makeParser()
    }

    /// Read appended bytes (if any) and fold them into the reducer.
    /// Returns the newly parsed entries.
    public func catchUp() throws -> [TranscriptEntry] {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? UInt64) ?? 0

        if size < offset {
            // File shrank — rebuild from scratch rather than reading garbage.
            // Free our claims first: re-reading must be able to count our own
            // messages again instead of skipping them as "already seen".
            offset = 0
            parser = makeParser()
            reducer = TranscriptReducer()
            claims?.release(owner: sessionID)
            costAccumulator = CostAccumulator(claims: claims, owner: sessionID)
            // The rebuild recomputes lastAPIError only if the shrunken file still
            // has an assistant line; clear it so a compaction to assistant-less
            // content can't leave a stale error banner on the row.
            lastAPIError = nil
        }
        guard size > offset else { return [] }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: Int(size - offset)) ?? Data()
        offset += UInt64(data.count)

        let entries = parser.consume(data)
        for entry in entries {
            reducer.consume(entry)
            costAccumulator.consume(entry)
            if let cwd = entry.cwd { lastKnownCWD = cwd }
            if let entrypoint = entry.entrypoint { lastKnownEntrypoint = entrypoint }
            if entry.isSidechain { isSidechain = true }
            if let limit = entry.usageLimit { lastUsageLimit = limit }
            // File order is chronological: each assistant turn overwrites the
            // verdict — an error sets it, a healthy turn clears it.
            if case .assistant(let payload) = entry.kind {
                // An error line with an empty text block must still show a
                // caption, not a blank warning triangle — treat "" as absent.
                let text = payload.firstText.flatMap { $0.isEmpty ? nil : $0 }
                lastAPIError = payload.isAPIError ? (text ?? "API error") : nil
            }
        }
        lastGrowthAt = attributes[.modificationDate] as? Date ?? Date()
        return entries
    }
}

/// Launch-time enumeration of `~/.claude/projects/`: every `<project-dir>/
/// <session-uuid>.jsonl` modified within `maxAge`.
public enum SessionDirectoryScanner {

    /// Walks the whole tree, not just `<root>/<project>/*.jsonl`. Claude Code's
    /// parallel sub-agents (the Task tool) write to
    /// `<root>/<project>/<session>/subagents/agent-*.jsonl` — a one-level scan
    /// never sees them, so their spend went uncounted entirely.
    /// `excludeProjectDir` lets a caller drop whole project dirs it must not
    /// claim — Claude Code passes it OpenClaw's SDK workspaces so those aren't
    /// tracked twice (once per adapter); see `ClaudeCodeAdapter.isTranscript`.
    public static func recentTranscripts(under root: URL,
                                         maxAge: TimeInterval,
                                         now: Date = Date(),
                                         excludeProjectDir: (String) -> Bool = { _ in false })
        -> [SessionFileInfo] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]) else { return [] }

        var found: [SessionFileInfo] = []
        for case let file as URL in walker where file.pathExtension == "jsonl" {
            guard let values = try? file.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  now.timeIntervalSince(modified) <= maxAge else { continue }
            let project = projectDirName(for: file, under: root)
            if excludeProjectDir(project) { continue }
            found.append(SessionFileInfo(
                sessionID: file.deletingPathExtension().lastPathComponent,
                projectDirName: project,
                lastModified: modified,
                url: file))
        }
        return found
    }

    /// The `<project>` component directly under the transcript root. A
    /// sub-agent's immediate parent is "subagents", which is not a project.
    public static func projectDirName(for file: URL, under root: URL) -> String {
        let rootParts = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let fileParts = file.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard fileParts.count > rootParts.count,
              Array(fileParts.prefix(rootParts.count)) == rootParts else {
            return file.deletingLastPathComponent().lastPathComponent
        }
        return fileParts[rootParts.count]
    }
}
