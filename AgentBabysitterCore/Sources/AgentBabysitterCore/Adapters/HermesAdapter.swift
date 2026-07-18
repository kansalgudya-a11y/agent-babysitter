import Foundation
import SQLite3

/// Hermes Agent (Nous Research). Every session — TUI and gateway — is a row in
/// one SQLite store at `~/.hermes/state.db` (WAL mode, verified on a real
/// install 2026-07). `sessions` carries the token/cost aggregates Hermes
/// prices for itself; `messages` carries the per-turn transcript this adapter
/// reads a real `TurnPhase` out of.
public struct HermesAdapter: AgentAdapter {

    public let id = "hermes"
    public let displayName = "Hermes"
    public let transcriptRoot: URL
    public var focusBundleIdentifiers: [String] {
        ["com.nousresearch.hermes", "com.nousresearch.hermes.setup"]
    }
    public var cliExecutableNames: [String] { ["hermes"] }
    /// One state.db hosts every session; identity comes from `recentTranscripts`,
    /// and the store rediscovers sessions on every change to the shared file.
    public var multiSessionFiles: Bool { true }

    /// NOT activity-based: `HermesSessionReader` derives a genuine `TurnPhase`
    /// from the last real message (role + finish_reason), so turn-completion is
    /// trustworthy and the store must NOT suppress its "done" notifications —
    /// unlike the mtime-only readers (`FileActivityReader`, Cursor) which infer
    /// state from file churn. Leaving this false keeps completion alerts on.
    public var isActivityBased: Bool { false }
    /// Sessions are PARSED out of the store's `sessions` table, so "Hermes
    /// running + state.db churning + zero sessions parsed" is real format drift
    /// worth flagging. (Also the `!isActivityBased` default, stated for clarity.)
    public var sessionsAreParsed: Bool { true }

    /// `timeZone` is threaded into the reader so day-bucket tests are
    /// deterministic; nil follows the live local zone.
    let timeZone: TimeZone?

    public init(transcriptRoot: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".hermes"),
                timeZone: TimeZone? = nil) {
        self.transcriptRoot = transcriptRoot
        self.timeZone = timeZone
    }

    public var stateDBURL: URL { transcriptRoot.appendingPathComponent("state.db") }

    // MARK: - Session discovery

    public func recentTranscripts(maxAge: TimeInterval, now: Date) -> [SessionFileInfo] {
        let stateDBURL = self.stateDBURL
        let rows = Self.withCopiedDB(at: stateDBURL) { db -> [SessionFileInfo] in
            var stmt: OpaquePointer?
            // Skip archived rows (archived truthy). last_ts = newest message for
            // the session, so a session's freshness tracks its transcript, not
            // the shared file's mtime.
            let sql = """
            SELECT s.id, s.cwd, s.git_repo_root, s.started_at,
                   (SELECT MAX(m.timestamp) FROM messages m WHERE m.session_id = s.id)
            FROM sessions s
            WHERE s.archived IS NULL OR s.archived = 0
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            var found: [SessionFileInfo] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let idC = sqlite3_column_text(stmt, 0) else { continue }
                let id = String(cString: idC)
                let cwd = Self.columnText(stmt, 1)
                let repo = Self.columnText(stmt, 2)
                let startedAt = sqlite3_column_double(stmt, 3)
                let lastTs = sqlite3_column_type(stmt, 4) == SQLITE_NULL
                    ? startedAt : sqlite3_column_double(stmt, 4)
                let modified = Date(timeIntervalSince1970: lastTs)
                guard now.timeIntervalSince(modified) <= maxAge else { continue }
                // Project label: cwd folder, else repo folder, else the agent id.
                let project: String
                if let cwd, !cwd.isEmpty {
                    project = URL(fileURLWithPath: cwd).lastPathComponent
                } else if let repo, !repo.isEmpty {
                    project = URL(fileURLWithPath: repo).lastPathComponent
                } else {
                    project = "hermes"
                }
                found.append(SessionFileInfo(sessionID: id, projectDirName: project,
                                             lastModified: modified, url: stateDBURL))
            }
            return found
        }
        return rows ?? []
    }

    public func isTranscript(path: String) -> Bool {
        let base = stateDBURL.path
        return path == base || path == base + "-wal" || path == base + "-shm"
    }

    public func canonicalTranscriptURL(forPath path: String) -> URL {
        // Every write to the store lands on state.db or its WAL/shm siblings —
        // collapse all three to the base db the reader opens.
        for suffix in ["-wal", "-shm"] where path.hasSuffix("state.db" + suffix) {
            return stateDBURL
        }
        return URL(fileURLWithPath: path)
    }

    public func sessionID(forTranscript url: URL) -> String {
        // No per-session file exists — every session is a row inside state.db.
        // Real identity is supplied by recentTranscripts()/SessionFileInfo, and
        // the store reads sessions through makeReader(url:sessionID:). This
        // stand-in only labels a bare db path.
        "hermes-state"
    }

    /// Never invoked: multiSessionFiles routes reads through makeReader(url:
    /// sessionID:), not the line tailer, so there is no line to parse.
    public func parseLine(_ line: Data) -> LineParseResult { .malformed }

    public func projectDirName(forTranscript url: URL) -> String { "Hermes" }

    public func makeReader(url: URL) -> any SessionReading {
        // Protocol completeness; the store always calls the sessionID variant.
        HermesSessionReader(storeURL: url, sessionID: "hermes-state", timeZone: timeZone)
    }

    public func makeReader(url: URL, sessionID: String) -> any SessionReading {
        HermesSessionReader(storeURL: url, sessionID: sessionID, timeZone: timeZone)
    }

    // MARK: - Process matching

    public func agentPIDs(psComm: String, psArgs: String) -> [Int32] {
        var pids = Set<Int32>()
        // comm is the bare executable path — the CLI wrapper (~/.local/bin/hermes)
        // runs as `hermes` itself.
        for rawLine in psComm.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let space = line.firstIndex(where: { $0 == " " || $0 == "\t" }),
                  let pid = Int32(line[..<space]) else { continue }
            let command = line[line.index(after: space)...].trimmingCharacters(in: .whitespaces)
            if command.split(separator: "/").last == "hermes" { pids.insert(pid) }
        }
        // The gateway runs as `…/venv/bin/python …/venv/bin/hermes gateway`, so
        // the `hermes` executable is an ARGUMENT, not comm. Match any argv token
        // whose basename is `hermes`. CRITICAL: Hermes bundles its own Node at
        // ~/.hermes/node/, which here runs an UNRELATED tool (claude-mem's
        // mcp-server.cjs); reject that whole runtime so a naive "contains
        // hermes" never attributes those Node pids to us.
        for rawLine in psArgs.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let space = line.firstIndex(where: { $0 == " " || $0 == "\t" }),
                  let pid = Int32(line[..<space]) else { continue }
            let args = line[line.index(after: space)...].trimmingCharacters(in: .whitespaces)
            if args.contains("/.hermes/node/") { continue }
            let tokens = args.split(separator: " ", omittingEmptySubsequences: true)
            if tokens.contains(where: { $0.split(separator: "/").last == "hermes" }) {
                pids.insert(pid)
            }
        }
        return pids.sorted()
    }

    public func match(processes: [RunningProcess],
                      candidates: [SessionMatchCandidate]) -> [String: Int32] {
        // Pair the most-recently-active sessions to live processes 1:1; leftover
        // sessions get no pid and read as Ended. Deliberately NO fan-out: Hermes
        // derives a real `TurnPhase`, so handing a spare pid to an abandoned
        // mid-turn session from hours ago would surface it as a false `.stalled`
        // (and fire a stalled alert). Erring toward a silent Ended beats a false
        // alarm for a babysitter. Contrast the activity-based OpenClaw gateway,
        // which can never be `.stalled` and so does fan out.
        let recent = candidates.sorted { $0.lastModified > $1.lastModified }
        var match: [String: Int32] = [:]
        for (candidate, process) in zip(recent, processes.sorted { $0.pid < $1.pid }) {
            match[candidate.sessionID] = process.pid
        }
        return match
    }

    // MARK: - Safe WAL read

    /// Hermes holds state.db + its WAL open; copy the trio to a scratch file and
    /// open the COPY read-only (a plain read-only open of a live WAL db without
    /// its siblings fails with SQLITE_CANTOPEN). The user's db is never opened.
    static func withCopiedDB<T>(at url: URL, _ body: (OpaquePointer) -> T?) -> T? {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory
            .appendingPathComponent("hermes-state-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmpDir) }
        do {
            try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            let base = tmpDir.appendingPathComponent("state.db")
            try fm.copyItem(at: url, to: base)
            for suffix in ["-wal", "-shm"] where fm.fileExists(atPath: url.path + suffix) {
                try fm.copyItem(atPath: url.path + suffix, toPath: base.path + suffix)
            }
            var db: OpaquePointer?
            guard sqlite3_open_v2(base.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
                sqlite3_close(db); return nil
            }
            defer { sqlite3_close(db) }
            return db.flatMap(body)
        } catch {
            return nil
        }
    }

    static func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let c = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: c)
    }
}

/// Reads one Hermes session out of the shared state.db per refresh. Every fact
/// derives from real rows: the turn phase from the last message, the cost from
/// the session's own aggregates (Hermes prices itself — we never touch our
/// PriceTable for it).
public final class HermesSessionReader: SessionReading {

    public let url: URL
    public let sessionID: String
    public let lastKnownEntrypoint: String? = "Hermes"
    public let usageLimit: UsageLimitSnapshot? = nil

    public private(set) var turnPhase: TurnPhase = .idle
    public private(set) var hasPendingToolUses = false
    public private(set) var currentTurnStartedAt: Date?
    public private(set) var lastGrowthAt: Date?
    public private(set) var lastKnownCWD: String?
    public private(set) var isSidechain = false
    public private(set) var isUnreadable = false
    public private(set) var cost = SessionCost()
    public private(set) var dailyCosts: [Date: SessionCost] = [:]
    public private(set) var dailyDollarsByModel: [Date: [String: Double]] = [:]
    public private(set) var lastPromptTitle: String?

    private let timeZone: TimeZone?
    private var lastSignature: DiskSignature?

    init(storeURL: URL, sessionID: String, timeZone: TimeZone? = nil) {
        self.url = storeURL
        self.sessionID = sessionID
        self.timeZone = timeZone
    }

    public func refresh() throws {
        // Cheap no-op when nothing changed: the shared db is multi-MB, so skip
        // the copy+query unless state.db (or its WAL) grew or its mtime moved.
        let signature = DiskSignature(dbPath: url.path)
        if let lastSignature, lastSignature == signature { return }

        guard let snapshot = HermesAdapter.withCopiedDB(at: url, { db in
            self.read(db)
        }) else {
            // A torn copy or a failed query must not be reported as a healthy
            // $0 session: keep the last good snapshot and stay unreadable. The
            // signature is NOT advanced, so the next tick retries instead of
            // latching until state.db happens to change again.
            isUnreadable = true
            return
        }
        lastSignature = signature
        isUnreadable = false
        turnPhase = snapshot.turnPhase
        hasPendingToolUses = snapshot.hasPendingToolUses
        currentTurnStartedAt = snapshot.currentTurnStartedAt
        lastGrowthAt = snapshot.lastGrowthAt
        lastKnownCWD = snapshot.lastKnownCWD
        isSidechain = snapshot.isSidechain
        lastPromptTitle = snapshot.lastPromptTitle
        cost = snapshot.cost
        dailyCosts = snapshot.dailyCosts
        dailyDollarsByModel = snapshot.dailyDollarsByModel
    }

    // MARK: - Reading

    private struct Message {
        let role: String
        let content: String?
        let finishReason: String?
        let timestamp: Double
    }

    private struct Snapshot {
        var turnPhase: TurnPhase = .idle
        var hasPendingToolUses = false
        var currentTurnStartedAt: Date?
        var lastGrowthAt: Date?
        var lastKnownCWD: String?
        var isSidechain = false
        var lastPromptTitle: String?
        var cost = SessionCost()
        var dailyCosts: [Date: SessionCost] = [:]
        var dailyDollarsByModel: [Date: [String: Double]] = [:]
    }

    /// nil means the read FAILED (prepare/step error) — the caller keeps its last
    /// good snapshot. A session that simply has no row yet returns an idle,
    /// zero-cost snapshot, which is a legitimate "readable but empty" answer.
    private func read(_ db: OpaquePointer) -> Snapshot? {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var snapshot = Snapshot()

        // --- sessions row: cost + metadata (Hermes' own numbers) ---
        // `listable` mirrors hermes-agent's own picker rule (hermes_state.py):
        // a child session stays visible only when it is a /branch — subagent runs
        // and compression continuations are hidden. `parent_session_id != NULL`
        // alone would wrongly hide branches.
        var sessionStmt: OpaquePointer?
        // json_extract raises "malformed JSON" on any non-JSON model_config —
        // and '' is non-NULL, so COALESCE(…, '{}') does NOT guard it; nor does
        // `json_valid(x) AND json_extract(x)` (SQLite still evaluates json_extract
        // and errors the whole step, leaving the session forever unreadable —
        // verified). CASE only evaluates its THEN branch, so json_extract runs
        // solely on valid JSON; blank/garbage config just means "not a branch".
        let sessionSQL = """
        SELECT s.model, s.cwd, s.git_repo_root, s.title,
               s.input_tokens, s.output_tokens, s.cache_read_tokens, s.cache_write_tokens,
               s.actual_cost_usd, s.estimated_cost_usd,
               (s.parent_session_id IS NULL
                OR (CASE WHEN json_valid(s.model_config)
                         THEN json_extract(s.model_config, '$._branched_from') END) IS NOT NULL
                OR EXISTS (SELECT 1 FROM sessions p
                           WHERE p.id = s.parent_session_id
                             AND p.end_reason = 'branched'
                             AND s.started_at >= p.ended_at)) AS listable,
               s.started_at
        FROM sessions s WHERE s.id = ?
        """
        guard sqlite3_prepare_v2(db, sessionSQL, -1, &sessionStmt, nil) == SQLITE_OK else {
            sqlite3_finalize(sessionStmt)
            return nil
        }
        sqlite3_bind_text(sessionStmt, 1, sessionID, -1, transient)
        let sessionStep = sqlite3_step(sessionStmt)
        guard sessionStep == SQLITE_ROW else {
            sqlite3_finalize(sessionStmt)
            return sessionStep == SQLITE_DONE ? snapshot : nil
        }
        let model = HermesAdapter.columnText(sessionStmt, 0)
        let cwd = HermesAdapter.columnText(sessionStmt, 1)
        let title = HermesAdapter.columnText(sessionStmt, 3)
        let inputTokens = Int(sqlite3_column_int64(sessionStmt, 4))
        // `reasoning_tokens` is deliberately not read: it is a SUBSET of
        // output_tokens, not a sibling (hermes-agent/cli.py prints it as
        // "↳ Reasoning (subset)"), so adding it would bill thinking twice.
        let outputTokens = Int(sqlite3_column_int64(sessionStmt, 5))
        let cacheReadTokens = Int(sqlite3_column_int64(sessionStmt, 6))
        let cacheWriteTokens = Int(sqlite3_column_int64(sessionStmt, 7))
        let actualCost = sqlite3_column_type(sessionStmt, 8) == SQLITE_NULL
            ? nil : sqlite3_column_double(sessionStmt, 8)
        let estimatedCost = sqlite3_column_type(sessionStmt, 9) == SQLITE_NULL
            ? nil : sqlite3_column_double(sessionStmt, 9)
        snapshot.isSidechain = sqlite3_column_int64(sessionStmt, 10) == 0
        // started_at (NOT NULL in Hermes' schema) is the STABLE day key for cost:
        // a session's day must never move, or a session spanning midnight would
        // re-land its whole lifetime cost on a second day while StatsLedger's
        // per-day max keeps the first — double-counting in multi-day totals.
        let startedAt = Date(timeIntervalSince1970: sqlite3_column_double(sessionStmt, 11))
        sqlite3_finalize(sessionStmt)

        snapshot.lastKnownCWD = (cwd?.isEmpty == false) ? cwd : nil

        // --- messages: ordered oldest → newest for phase + growth ---
        var messages: [Message] = []
        var msgStmt: OpaquePointer?
        let msgSQL = """
        SELECT role, content, finish_reason, timestamp
        FROM messages WHERE session_id = ? ORDER BY timestamp ASC, id ASC
        """
        guard sqlite3_prepare_v2(db, msgSQL, -1, &msgStmt, nil) == SQLITE_OK else {
            sqlite3_finalize(msgStmt)
            return nil
        }
        sqlite3_bind_text(msgStmt, 1, sessionID, -1, transient)
        // A torn WAL copy can error mid-iteration; that must surface as nil (keep
        // the last-good snapshot, retry) — NOT be swallowed like SQLITE_DONE,
        // which would commit a truncated message list as an authoritative,
        // wrong turn phase and latch it until state.db next changes.
        var msgStep = sqlite3_step(msgStmt)
        while msgStep == SQLITE_ROW {
            if let roleC = sqlite3_column_text(msgStmt, 0) {
                messages.append(Message(
                    role: String(cString: roleC),
                    content: HermesAdapter.columnText(msgStmt, 1),
                    finishReason: HermesAdapter.columnText(msgStmt, 2),
                    timestamp: sqlite3_column_double(msgStmt, 3)))
            }
            msgStep = sqlite3_step(msgStmt)
        }
        sqlite3_finalize(msgStmt)
        guard msgStep == SQLITE_DONE else { return nil }

        // newest timestamp (rows are ascending) = growth signal.
        let lastGrowthAt = messages.last.map { Date(timeIntervalSince1970: $0.timestamp) }
        snapshot.lastGrowthAt = lastGrowthAt

        // Turn phase from the LAST non-system message.
        let lastReal = messages.last(where: { $0.role != "system" })
        if let lastReal {
            switch lastReal.role {
            case "assistant":
                // finish_reason "tool_calls" ⇒ the model asked for a tool and
                // owes more once it returns; anything else is a terminal reply.
                snapshot.turnPhase = lastReal.finishReason == "tool_calls" ? .midTurn : .completed
            case "tool":     snapshot.turnPhase = .midTurn  // result in, reply pending
            case "user":     snapshot.turnPhase = .midTurn  // the agent owes a reply
            default:         snapshot.turnPhase = .completed
            }
        } else {
            snapshot.turnPhase = .idle
        }
        // Pending tool use: the last real message is an assistant tool_calls turn
        // with no tool row after it (guaranteed, since it is the last one).
        snapshot.hasPendingToolUses =
            lastReal?.role == "assistant" && lastReal?.finishReason == "tool_calls"

        // Current turn starts at the most recent user prompt while unfinished.
        if snapshot.turnPhase == .midTurn,
           let lastUser = messages.last(where: { $0.role == "user" }) {
            snapshot.currentTurnStartedAt = Date(timeIntervalSince1970: lastUser.timestamp)
        }

        // Title: the session's own title, else a one-line take of the newest prompt.
        if let title, !title.isEmpty {
            snapshot.lastPromptTitle = title
        } else if let prompt = messages.last(where: { $0.role == "user" })?.content,
                  let line = Self.oneLine(prompt) {
            snapshot.lastPromptTitle = line
        }

        // --- cost: Hermes' own dollars; our PriceTable is deliberately unused ---
        // totalTokens uses the app-wide definition (input + output + cache-write);
        // cache reads are billed but excluded from the headline count.
        let totalTokens = inputTokens + outputTokens + cacheWriteTokens
        var unknownModels: Set<String> = []
        let dollars: Double
        if let actualCost {
            dollars = actualCost
        } else if let estimatedCost {
            // A real 0.0 from a :free model is a KNOWN price, not unknown.
            dollars = estimatedCost
        } else {
            // Both NULL ⇒ Hermes never priced it: 0 dollars, and flag the model
            // so the UI shows "≥" (cost floor) rather than "~" (estimate).
            dollars = 0
            unknownModels.insert(model?.isEmpty == false ? model! : "unknown")
        }
        let sessionCost = SessionCost(
            dollars: dollars, totalTokens: totalTokens, unknownModels: unknownModels,
            inputTokens: inputTokens, outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens, cacheWriteTokens: cacheWriteTokens)
        snapshot.cost = sessionCost

        // Distribute the session's cumulative cost across the local days its
        // messages fall on, proportional to messages-per-day. Hermes exposes no
        // per-message cost, but attributing by message count is STABLE — a
        // message's day never changes — so a session spanning midnight is neither
        // double-counted (as a moving single-day key would be, via StatsLedger's
        // per-day max) nor zeroed for today (as a fixed start-day key would be).
        // Not exact per day, but the total reconciles: the most recent day absorbs
        // the rounding remainder.
        let tz = timeZone ?? .current
        func part(dollars: Double, total: Int, input: Int, output: Int,
                  cacheR: Int, cacheW: Int) -> SessionCost {
            SessionCost(dollars: dollars, totalTokens: total, unknownModels: unknownModels,
                        inputTokens: input, outputTokens: output,
                        cacheReadTokens: cacheR, cacheWriteTokens: cacheW)
        }
        var countsByDay: [Date: Int] = [:]
        for m in messages {
            let d = LocalDay.start(of: Date(timeIntervalSince1970: m.timestamp), timeZone: tz)
            countsByDay[d, default: 0] += 1
        }
        if countsByDay.isEmpty {
            // No messages yet, but the session row already carries cost — attribute
            // the whole of it to the start day rather than dropping it.
            let day = LocalDay.start(of: startedAt, timeZone: tz)
            snapshot.dailyCosts[day] = sessionCost
            if let model, !model.isEmpty, dollars > 0 {
                snapshot.dailyDollarsByModel[day] = [model: dollars]
            }
        } else {
            let totalMsgs = messages.count
            let days = countsByDay.keys.sorted()
            var used = (d: 0.0, t: 0, i: 0, o: 0, cr: 0, cw: 0)
            for (idx, day) in days.enumerated() {
                let dayCost: SessionCost
                if idx == days.count - 1 {
                    // Exact remainder so the per-day parts sum to the session total.
                    dayCost = part(dollars: dollars - used.d, total: totalTokens - used.t,
                                   input: inputTokens - used.i, output: outputTokens - used.o,
                                   cacheR: cacheReadTokens - used.cr, cacheW: cacheWriteTokens - used.cw)
                } else {
                    let f = Double(countsByDay[day]!) / Double(totalMsgs)
                    func s(_ n: Int) -> Int { Int((Double(n) * f).rounded()) }
                    dayCost = part(dollars: dollars * f, total: s(totalTokens),
                                   input: s(inputTokens), output: s(outputTokens),
                                   cacheR: s(cacheReadTokens), cacheW: s(cacheWriteTokens))
                    used = (used.d + dayCost.dollars, used.t + dayCost.totalTokens,
                            used.i + dayCost.inputTokens, used.o + dayCost.outputTokens,
                            used.cr + dayCost.cacheReadTokens, used.cw + dayCost.cacheWriteTokens)
                }
                snapshot.dailyCosts[day] = dayCost
                if let model, !model.isEmpty, dayCost.dollars > 0 {
                    snapshot.dailyDollarsByModel[day] = [model: dayCost.dollars]
                }
            }
        }
        return snapshot
    }

    /// First non-empty line, whitespace-trimmed, capped for a caption.
    private static func oneLine(_ text: String, limit: Int = 80) -> String? {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count <= limit { return trimmed }
        return String(trimmed.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// state.db + its WAL, by mtime and size — the cheap "did anything change?"
/// fingerprint the reader gates its copy on.
private struct DiskSignature: Equatable {
    let dbMtime: Date
    let dbSize: Int
    let walMtime: Date
    let walSize: Int

    init(dbPath: String) {
        let fm = FileManager.default
        func stat(_ path: String) -> (Date, Int) {
            let attrs = try? fm.attributesOfItem(atPath: path)
            return ((attrs?[.modificationDate] as? Date) ?? .distantPast,
                    (attrs?[.size] as? Int) ?? 0)
        }
        (dbMtime, dbSize) = stat(dbPath)
        (walMtime, walSize) = stat(dbPath + "-wal")
    }
}
