import Foundation

/// OpenAI Codex: `~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl`.
/// Rollout lines are `{timestamp, type, payload}`; this adapter normalizes
/// them into `TranscriptEntry` so the reducer, state engine, and cost display
/// work unchanged. Confirmed against real rollouts (Codex Desktop 0.142.3).
public struct CodexAdapter: AgentAdapter {

    public let id = "codex"
    public let displayName = "Codex"
    public let transcriptRoot: URL
    public let focusBundleIdentifiers = ["com.openai.codex"]
    public let cliExecutableNames = ["codex"]

    public init(transcriptRoot: URL = PlatformPaths.homeDirectory(".codex/sessions")) {
        self.transcriptRoot = transcriptRoot
    }

    public func recentTranscripts(maxAge: TimeInterval, now: Date) -> [SessionFileInfo] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: transcriptRoot,
                                             includingPropertiesForKeys:
                                                 [.contentModificationDateKey, .isRegularFileKey],
                                             options: [.skipsHiddenFiles]) else { return [] }
        var found: [SessionFileInfo] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  now.timeIntervalSince(modified) <= maxAge else { continue }
            found.append(SessionFileInfo(sessionID: sessionID(forTranscript: url),
                                         projectDirName: url.deletingLastPathComponent().lastPathComponent,
                                         lastModified: modified,
                                         url: url))
        }
        return found
    }

    public func isTranscript(path: String) -> Bool {
        path.hasPrefix(transcriptRoot.path) && path.hasSuffix(".jsonl")
    }

    /// Newest rollouts without walking the whole archive: the tree is
    /// `<root>/YYYY/MM/DD/rollout-*.jsonl`, so descend newest-first and stop
    /// once enough day-directories are collected. Cost is independent of how
    /// many years of history exist — Codex never prunes.
    ///
    /// `limit` is the recall budget for `usageFromDisk()`, not a display
    /// count: a rollout whose recent turns ran on a model-scoped allowance
    /// contributes NO plan-wide reading (see `tailRateLimits`), so the scan
    /// has to be able to step past several such files. 24 covers a full day
    /// of the author's busiest observed day (40 rollouts) minus the quiet
    /// ones, at one 64 KB tail-read each.
    ///
    /// `rescueEntryBudget` only reaches the unrecognized-layout fallback below.
    /// It is a parameter purely so a test can exercise the cap without
    /// materializing thousands of files: an untested break is an untested
    /// break, and this one is the only thing standing between a future Codex
    /// layout change and a full walk of an archive that is never pruned.
    func newestRollouts(limit: Int = 24, dayDirs: Int = 4,
                        rescueEntryBudget: Int = 2_000) -> [(url: URL, mtime: Date)] {
        let fm = FileManager.default
        func numericChildren(of dir: URL, nameLength: Int) -> [URL] {
            guard let entries = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]) else { return [] }
            return entries
                .filter { url in
                    let name = url.lastPathComponent
                    return name.count == nameLength && name.allSatisfy(\.isNumber)
                        && (try? url.resourceValues(forKeys: [.isDirectoryKey]))?
                            .isDirectory == true
                }
                // Zero-padded fixed-width names sort lexically == numerically.
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
        }
        // The prefixes cap the step-back so a long-idle install can't
        // degenerate into the full walk this method exists to avoid.
        var days: [URL] = []
        outer: for year in numericChildren(of: transcriptRoot, nameLength: 4).prefix(2) {
            for month in numericChildren(of: year, nameLength: 2).prefix(2) {
                for day in numericChildren(of: month, nameLength: 2) {
                    days.append(day)
                    if days.count >= dayDirs { break outer }
                }
            }
        }
        var files: [(url: URL, mtime: Date)] = []
        for day in days {
            guard let entries = try? fm.contentsOfDirectory(
                at: day,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]) else { continue }
            for url in entries where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(
                        forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                      values.isRegularFile == true,
                      let modified = values.contentModificationDate else { continue }
                files.append((url, modified))
            }
        }
        // Layout changed under us: fall back to a BOUNDED walk so a future
        // Codex layout degrades to "slower and approximate", never to
        // "silently nothing" — and never to a stall. `days.isEmpty` is true on
        // EVERY call in that state, not once, so the fallback cannot be the
        // unbounded recursive walk it used to be: Codex never prunes, and this
        // runs behind the store's disk-usage path.
        if days.isEmpty { files = boundedScan(maxEntries: rescueEntryBudget) }
        return Array(files.sorted { $0.mtime > $1.mtime }.prefix(limit))
    }

    /// Rescue scan for an unrecognized layout: at most `maxEntries` filesystem
    /// entries are examined, so the cost is flat however deep the archive is.
    /// Deliberately partial — an approximate "newest" beats a hang, and the
    /// enumerator's order is not newest-first, so what survives the cap is
    /// whatever the walk reached first.
    private func boundedScan(maxEntries: Int) -> [(url: URL, mtime: Date)] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: transcriptRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var files: [(url: URL, mtime: Date)] = []
        var examined = 0
        for case let url as URL in enumerator {
            examined += 1
            if examined > maxEntries { break }
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(
                      forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate else { continue }
            files.append((url, modified))
        }
        return files
    }

    public func usageSourceFile() -> URL? { newestRollouts(limit: 1).first?.url }

    /// Newest plan-wide quota across the newest rollouts, read from a tail of
    /// each. Session-independent on purpose: the weekly window stays true for
    /// days after the last turn, long past the store's 24h active window —
    /// which is exactly when the menu used to fall back to "no recent reading"
    /// for a quota with most of a week left on it.
    /// An escalated tail read is 4 MB, and a rollout whose recent turns were
    /// model-scoped will always trigger one (it has no plan-wide reading to
    /// find). Two such files exist on the author's disk today; without a cap,
    /// an archive full of them would turn one cache miss into a
    /// multi-hundred-millisecond stall on the store's actor. Newest first, so
    /// the budget is spent where a fresher reading could actually be.
    static let maxEscalatedTailReads = 3

    public func usageFromDisk() -> UsageLimitSnapshot? {
        let now = Date()
        var best: UsageLimitSnapshot?           // newest non-expired
        var newestOverall: UsageLimitSnapshot?  // fallback when all expired
        var escalations = 0
        for (url, mtime) in newestRollouts() {
            // Every reading in the tail, and never stopping at the first file
            // that yields one: on the author's disk 2026-07-22 the newest
            // rollout's tail held ONLY the model-scoped bucket, and the real
            // plan-wide 24% lived in the file written 16 seconds earlier.
            let scan = CodexRolloutParser.tailRateLimits(
                at: url, fileModified: mtime,
                allowEscalation: escalations < Self.maxEscalatedTailReads)
            if scan.escalated { escalations += 1 }
            for (limits, capturedAt) in scan.readings {
                guard let snapshot = CodexRolloutParser.planWideUsage(limits,
                                                                      capturedAt: capturedAt)
                else { continue }
                if (newestOverall?.capturedAt ?? .distantPast) < snapshot.capturedAt {
                    newestOverall = snapshot
                }
                guard !snapshot.isExpired(at: now) else { continue }
                if (best?.capturedAt ?? .distantPast) < snapshot.capturedAt {
                    best = snapshot
                }
            }
        }
        // All windows rolled over: hand back the most recent truth so the menu
        // renders its honest "reset" state rather than "no recent reading".
        return best ?? newestOverall
    }

    /// One quota bucket as Codex wrote it, before the plan-wide filter.
    public struct UsageBucket: Equatable, Sendable {
        public let limitID: String?
        /// nil for the plan-wide bucket; a model name ("GPT-5.3-Codex-Spark")
        /// for the separate per-model allowances that must not mask it.
        public let limitName: String?
        public let usedPercent: Double?
        public let windowMinutes: Int?
    }

    /// Diagnostic only (babysitter-debug): the distinct buckets present in the
    /// newest rollouts. If OpenAI ever labels the plan-wide bucket too,
    /// `usageFromDisk()` honestly returns nil and the menu says "no recent
    /// reading" — correct, but indistinguishable from a parser regression from
    /// the outside. This is what tells those two apart in a support report.
    public func recentUsageBuckets() -> [UsageBucket] {
        var seen: [UsageBucket] = []
        for (url, mtime) in newestRollouts() {
            // No escalation budget here: this runs once, by hand, in a support
            // session — never on the refresh tick.
            for (limits, _) in CodexRolloutParser.tailRateLimits(
                at: url, fileModified: mtime).readings {
                let bucket = UsageBucket(
                    limitID: limits["limit_id"] as? String,
                    limitName: limits["limit_name"] as? String,
                    usedPercent: (limits["primary"] as? [String: Any])?["used_percent"] as? Double,
                    windowMinutes: (limits["primary"] as? [String: Any])?["window_minutes"] as? Int)
                if !seen.contains(where: { $0.limitID == bucket.limitID
                                        && $0.limitName == bucket.limitName }) {
                    seen.append(bucket)
                }
            }
        }
        return seen
    }

    public func sessionID(forTranscript url: URL) -> String {
        // rollout-2026-06-28T20-07-23-<uuid>.jsonl → trailing 36-char uuid
        let stem = url.deletingPathExtension().lastPathComponent
        if stem.count > 36 {
            let uuid = String(stem.suffix(36))
            if uuid.allSatisfy({ $0.isHexDigit || $0 == "-" }) { return uuid }
        }
        return stem
    }

    /// Stateless variant — usage events are treated in isolation. The
    /// reader path below uses the stateful parser, which tracks the
    /// cumulative usage counter correctly.
    public func parseLine(_ line: Data) -> LineParseResult {
        CodexRolloutParser.parse(line, usageState: nil)
    }

    public func makeReader(url: URL) -> any SessionReading {
        TranscriptFileTailer(
            url: url,
            sessionID: sessionID(forTranscript: url),
            makeParser: {
                // token_count carries a CUMULATIVE total_token_usage; per-file
                // state turns it into deltas (real rollouts show overlapping
                // last_token_usage values that would over-count if summed).
                let state = CodexRolloutParser.UsageState()
                // The model lives on turn_context, which a sub-agent rollout can
                // emit AFTER dozens of token_count events — those would price at
                // $0. Seed the model from the file's first turn_context so early
                // usage is priced too.
                state.model = CodexRolloutParser.firstTurnContextModel(inFileAt: url)
                return TranscriptTailParser(parseLine: {
                    CodexRolloutParser.parse($0, usageState: state)
                })
            })
    }

    public func agentPIDs(psComm: String, psArgs: String) -> [Int32] {
        var pids = Set<Int32>()
        for line in psComm.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }),
                  let pid = Int32(trimmed[..<space]) else { continue }
            let command = trimmed[trimmed.index(after: space)...]
                .trimmingCharacters(in: .whitespaces)
            // CLI binary ("codex", any path) or the desktop app's exact
            // main binary — its Electron helpers ("Codex (Service)",
            // crashpad) must not count as sessions.
            if command.split(separator: "/").last == "codex"
                || command.hasSuffix("/Codex.app/Contents/MacOS/Codex") {
                pids.insert(pid)
            }
        }
        return pids.sorted()
    }

    /// Codex has no munged project dirs — match a process to the most
    /// recently modified session whose transcript-reported cwd equals the
    /// process cwd.
    public func match(processes: [RunningProcess],
                      candidates: [SessionMatchCandidate]) -> [String: Int32] {
        var byCWD = Dictionary(grouping: candidates.filter { $0.lastKnownCWD != nil },
                               by: { $0.lastKnownCWD! })
        for key in byCWD.keys {
            byCWD[key]!.sort { $0.lastModified > $1.lastModified }
        }
        let processesByCWD = Dictionary(grouping: processes, by: \.cwd)

        var match: [String: Int32] = [:]
        for (cwd, cwdProcesses) in processesByCWD {
            guard let sessions = byCWD[cwd] else { continue }
            for (session, process) in zip(sessions, cwdProcesses.sorted { $0.pid < $1.pid }) {
                match[session.sessionID] = process.pid
            }
        }
        // The desktop app's shell reports cwd "/" while its sessions carry
        // project paths, so cwd matching can never pair them - fall back to
        // pairing leftovers positionally (newest session, lowest pid),
        // exactly like the other desktop-app adapters.
        let unmatchedProcesses = processes
            .filter { process in !match.values.contains(process.pid) }
            .sorted { $0.pid < $1.pid }
        let unmatchedSessions = candidates
            .filter { match[$0.sessionID] == nil }
            .sorted { $0.lastModified > $1.lastModified }
        for (session, process) in zip(unmatchedSessions, unmatchedProcesses) {
            match[session.sessionID] = process.pid
        }
        return match
    }
}

/// Maps one Codex rollout line into the normalized entry model.
enum CodexRolloutParser {

    /// Cumulative usage counter for one rollout file. `total_token_usage`
    /// is authoritative and monotonic within a counter epoch; a drop means
    /// the counter reset, so the new value counts fresh.
    final class UsageState: @unchecked Sendable {
        var input = 0
        var cachedInput = 0
        var output = 0
        /// Rollouts carry the model on `turn_context`, not on the usage
        /// events — remember it so token_count entries can be priced.
        var model: String?

        func delta(input newInput: Int, cachedInput newCached: Int,
                   output newOutput: Int) -> (input: Int, cachedInput: Int, output: Int) {
            func step(_ new: Int, _ old: inout Int) -> Int {
                let d = new >= old ? new - old : new  // reset → count fresh
                old = new
                return d
            }
            return (step(newInput, &input), step(newCached, &cachedInput),
                    step(newOutput, &output))
        }
    }

    /// The model on the file's first `turn_context`, read cheaply from the head
    /// of the file (turn_context is near the top). Used to seed the usage state
    /// so token_count events that precede it are still priced. nil when no
    /// turn_context appears within the scanned window.
    static func firstTurnContextModel(inFileAt url: URL,
                                      scanBytes: Int = 512 * 1024) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: scanBytes)) ?? Data()
        for line in data.split(separator: 0x0A) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  obj["type"] as? String == "turn_context",
                  let payload = obj["payload"] as? [String: Any],
                  let model = payload["model"] as? String else { continue }
            return model
        }
        return nil
    }

    static let usageTailWindow = 64 * 1024
    /// One escalation step. The longest line within the last 20 lines of any
    /// rollout measured 2,254,629 bytes, so a 64 KB window can land entirely
    /// inside one line and find nothing to parse.
    static let usageTailEscalation = 4 * 1024 * 1024

    /// One rollout's tail scan: what it found, and whether finding out cost
    /// the escalated read (so the caller can budget those across files).
    struct TailScan {
        var readings: [(limits: [String: Any], capturedAt: Date)]
        var escalated: Bool
    }

    /// Every `rate_limits` object in the tail of one rollout, still raw so
    /// both the reading and the bucket diagnostic can read the same scan.
    ///
    /// Tail-reading is mandatory, not an optimization: the largest rollout
    /// measured 2026-07-22 is 317,753,094 bytes and contains a single
    /// 36,114,765-byte line — bare line-iteration of that one file takes
    /// 165 ms, far past what a 2s tick on the store's actor can afford.
    ///
    /// The window escalates when the slice yields no PLAN-WIDE reading, not
    /// merely when it yields no parseable line: a reading sitting a few
    /// hundred KB back behind ordinary-sized lines was silently dropped by the
    /// old "did we parse anything at all" test.
    ///
    /// What no window can fix, measured over the author's real archive
    /// 2026-07-23: of the 63 rollouts holding a plan-wide reading, 61 hold
    /// their last one within 3,273 bytes of EOF — but two hold it 258,307,779
    /// and 300,105,435 bytes back, because those sessions switched to a
    /// model-scoped allowance ("GPT-5.3-Codex-Spark") and EVERY rate_limits
    /// line after the switch names it. Reaching those is a 300 MB read, so we
    /// deliberately don't: `usageFromDisk()` scans many rollouts and takes the
    /// newest plan-wide reading across all of them, which is what makes one
    /// model-scoped-only file a non-event instead of a blank row.
    static func tailRateLimits(at url: URL, fileModified: Date,
                               allowEscalation: Bool = true) -> TailScan {
        func lines(window: Int) -> [Data] {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
            defer { try? handle.close() }
            var data = Data()
            var offset: UInt64 = 0
            do {
                let size = try handle.seekToEnd()
                offset = size > UInt64(window) ? size - UInt64(window) : 0
                try handle.seek(toOffset: offset)
                data = try handle.readToEnd() ?? Data()
            } catch {
                return []
            }
            // A non-zero offset lands mid-line: drop that leading fragment so
            // it can't parse as garbage, and give up if the window holds no
            // newline at all (the whole slice is one partial line).
            if offset > 0 {
                guard let newline = data.firstIndex(of: 0x0A) else { return [] }
                data = data[data.index(after: newline)...]
            }
            return data.split(separator: 0x0A).map { Data($0) }
        }
        let marker = Data("rate_limits".utf8)
        func readings(in candidates: [Data]) -> [(limits: [String: Any], capturedAt: Date)] {
            var found: [(limits: [String: Any], capturedAt: Date)] = []
            for line in candidates {
                // Raw-bytes prefilter before JSONSerialization: load-bearing for
                // cost, or a multi-megabyte non-matching line gets fully parsed.
                // Malformed lines are skipped silently, matching the fail-soft
                // Cursor/Antigravity disk readers.
                guard line.range(of: marker) != nil,
                      let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      object["type"] as? String == "event_msg",
                      let payload = object["payload"] as? [String: Any],
                      payload["type"] as? String == "token_count",
                      let rateLimits = payload["rate_limits"] as? [String: Any]
                else { continue }
                // `capturedAt` is the event's own timestamp — the same field the
                // live reader path uses — CLAMPED to the file's mtime. The clamp
                // costs nothing (measured mtime − event timestamp: 0.0-0.15s across
                // the 10 newest rollouts) and guards two real failures: an
                // unclamped "now" would re-enable UsageForecast extrapolation on a
                // day-old reading, and would let a stale disk snapshot outrank a
                // genuinely fresh live one in UsageLimitLayering.
                let stamp = (object["timestamp"] as? String).flatMap(parseTimestamp) ?? fileModified
                found.append((rateLimits, min(stamp, fileModified)))
            }
            return found
        }

        let size = (try? FileManager.default
            .attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
        let found = readings(in: lines(window: usageTailWindow))
        // Escalate on "no plan-wide reading here", which SUBSUMES the old "no
        // parseable line here" (the window landed inside one huge line): a
        // slice full of model-scoped buckets parses perfectly and still has
        // nothing this adapter can publish.
        guard allowEscalation, size > usageTailWindow,
              !found.contains(where: { planWideUsage($0.limits, capturedAt: $0.capturedAt) != nil })
        else { return TailScan(readings: found, escalated: false) }
        let wider = readings(in: lines(window: usageTailEscalation))
        // Keep whichever slice actually found something to say: the wider read
        // is a superset, but if it also finds no plan-wide reading the narrow
        // result is no worse and the bucket diagnostic still gets its data.
        return TailScan(readings: wider.isEmpty ? found : wider, escalated: true)
    }

    /// Codex publishes several quota buckets under `rate_limits`, keyed by
    /// `limit_id`. The plan-wide bucket (`limit_name` absent or null) is what
    /// "Codex" means in the menu; model-scoped buckets ("GPT-5.3-Codex-Spark")
    /// are separate allowances that would otherwise mask it. Verified on disk
    /// 2026-07-22: the newest line in the newest rollout is a 0% Spark reading
    /// while the plan sits at 24%, written 16 seconds earlier — last-write-wins
    /// on the raw stream therefore renders a confident, wrong 0%. Keying on the
    /// ABSENCE of a model label rather than on the literal id "codex" means a
    /// vendor id rename degrades to "the same reading" instead of to nothing.
    static func planWideUsage(_ rateLimits: [String: Any],
                              capturedAt: Date) -> UsageLimitSnapshot? {
        // JSON `"limit_name":null` bridges to NSNull, so `as? String` yields
        // nil exactly as an absent key does — both mean plan-wide.
        if let name = rateLimits["limit_name"] as? String, !name.isEmpty { return nil }
        guard let primary = rateLimits["primary"] as? [String: Any],
              let usedPercent = primary["used_percent"] as? Double else { return nil }
        // Secondary is the weekly window when present. Codex readings observed
        // 2026-07 carry a WEEKLY primary (10080) with a null secondary, so the
        // window length must come from the data, never be assumed to be 5h.
        let secondary = rateLimits["secondary"] as? [String: Any]
        return UsageLimitSnapshot(
            usedPercent: usedPercent,
            windowMinutes: primary["window_minutes"] as? Int ?? 300,
            resetsAt: (primary["resets_at"] as? Double)
                .map { Date(timeIntervalSince1970: $0) },
            capturedAt: capturedAt,
            plan: rateLimits["plan_type"] as? String,
            weeklyUsedPercent: secondary?["used_percent"] as? Double,
            weeklyResetsAt: (secondary?["resets_at"] as? Double)
                .map { Date(timeIntervalSince1970: $0) })
    }

    static func parse(_ line: Data, usageState: UsageState?) -> LineParseResult {
        guard !line.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D || $0 == 0x0A })
        else { return .empty }
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = object["type"] as? String else {
            return .malformed
        }
        let payload = object["payload"] as? [String: Any] ?? [:]
        let timestamp = (object["timestamp"] as? String).flatMap(parseTimestamp)

        func entry(_ kind: TranscriptEntry.Kind,
                   sessionID: String? = nil,
                   cwd: String? = nil,
                   isSidechain: Bool = false,
                   entrypoint: String? = nil,
                   usageLimit: UsageLimitSnapshot? = nil) -> LineParseResult {
            .entry(TranscriptEntry(kind: kind, uuid: nil, timestamp: timestamp,
                                   sessionID: sessionID, cwd: cwd,
                                   isSidechain: isSidechain, entrypoint: entrypoint,
                                   usageLimit: usageLimit))
        }

        func usageOnlyAssistant(_ usage: TokenUsage) -> TranscriptEntry.Kind {
            // Model from the last turn_context (tracked in UsageState) so
            // the accumulator can price the tokens.
            .assistant(AssistantPayload(messageID: nil, model: usageState?.model,
                                        stopReason: nil,
                                        usage: usage, toolUses: [],
                                        hasText: false, hasThinking: false))
        }

        switch type {
        case "session_meta":
            let source = payload["source"] as? [String: Any]
            let isSubagent = source?["subagent"] != nil
                || (payload["thread_source"] as? String) == "subagent"
            return entry(.meta(rawType: type),
                         sessionID: payload["id"] as? String,
                         cwd: payload["cwd"] as? String,
                         isSidechain: isSubagent,
                         entrypoint: payload["originator"] as? String)

        case "turn_context":
            if let model = payload["model"] as? String {
                usageState?.model = model
            }
            return entry(.meta(rawType: type), cwd: payload["cwd"] as? String)

        case "response_item":
            switch payload["type"] as? String {
            case "message":
                let text = messageText(payload)
                switch payload["role"] as? String {
                case "user":
                    return entry(.user(UserPayload(text: text, toolResults: [])))
                case "assistant":
                    return entry(.assistant(AssistantPayload(
                        messageID: payload["id"] as? String, model: nil, stopReason: nil,
                        usage: nil, toolUses: [], hasText: true, hasThinking: false)))
                default:  // developer/system prompts
                    return entry(.meta(rawType: "message"))
                }
            case "function_call", "custom_tool_call", "local_shell_call":
                let callID = (payload["call_id"] as? String) ?? (payload["id"] as? String) ?? ""
                return entry(.assistant(AssistantPayload(
                    messageID: nil, model: nil, stopReason: nil, usage: nil,
                    toolUses: [ToolUseRef(id: callID,
                                          name: payload["name"] as? String ?? "tool")],
                    hasText: false, hasThinking: false)))
            case "function_call_output", "custom_tool_call_output":
                let callID = (payload["call_id"] as? String) ?? ""
                return entry(.user(UserPayload(
                    text: nil,
                    toolResults: [ToolResultRef(toolUseID: callID, isError: false)])))
            case "reasoning":
                return entry(.assistant(AssistantPayload(
                    messageID: nil, model: nil, stopReason: nil, usage: nil,
                    toolUses: [], hasText: false, hasThinking: true)))
            default:  // web_search_call etc. — server-side, never produces a
                      // client output, so it must not read as pending
                return entry(.meta(rawType: payload["type"] as? String ?? type))
            }

        case "event_msg":
            switch payload["type"] as? String {
            case "task_started":
                // Turn start marker — some rollouts (resumed/imported threads)
                // carry no user message item.
                return entry(.user(UserPayload(text: "[task started]", toolResults: [])))
            case "task_complete":
                return entry(.assistant(AssistantPayload(
                    messageID: nil, model: nil, stopReason: .endTurn, usage: nil,
                    toolUses: [], hasText: false, hasThinking: false)))
            case "turn_aborted":
                // Reuse the interruption convention: aborts clear pending tools.
                return entry(.user(UserPayload(text: "[Request interrupted by user]",
                                               toolResults: [])))
            case "token_count":
                let info = payload["info"] as? [String: Any]
                let totals = info?["total_token_usage"] as? [String: Any]
                    ?? info?["last_token_usage"] as? [String: Any]
                let input = totals?["input_tokens"] as? Int ?? 0
                let cached = totals?["cached_input_tokens"] as? Int ?? 0
                let output = totals?["output_tokens"] as? Int ?? 0
                // Some rollouts emit a corrupt reading — all components 0 but a
                // non-zero total_tokens. Feeding {0,0,0} to the cumulative delta
                // would look like a counter RESET and re-count the whole preceding
                // cumulative on the next real event. Skip the delta entirely and
                // leave the baseline untouched; the reading carries no usable split.
                let usage: TokenUsage
                if input == 0 && cached == 0 && output == 0 {
                    usage = TokenUsage(inputTokens: 0, outputTokens: 0,
                                       cacheCreationInputTokens: 0, cacheReadInputTokens: 0)
                } else {
                    let (dIn, dCached, dOut) = usageState?.delta(input: input,
                                                                 cachedInput: cached,
                                                                 output: output)
                        ?? (input, cached, output)
                    // OpenAI nests the cached prefix INSIDE input_tokens (verified on
                    // real rollouts: input_tokens + output_tokens == total_tokens, with
                    // cached ⊆ input), unlike Anthropic's disjoint buckets. Subtract it
                    // so `inputTokens` is the genuinely-new input and the cached prefix
                    // is only counted once, as cacheRead — otherwise it's billed at the
                    // full input rate AND the cache-read rate (a 3.4x cost over-charge).
                    usage = TokenUsage(inputTokens: max(0, dIn - dCached),
                                       outputTokens: dOut,
                                       cacheCreationInputTokens: 0,
                                       cacheReadInputTokens: dCached)
                }
                // Subscription window readings ride along on token_count.
                var limit: UsageLimitSnapshot?
                if let rateLimits = payload["rate_limits"] as? [String: Any] {
                    limit = planWideUsage(rateLimits, capturedAt: timestamp ?? Date())
                }
                // Usage-only: phase-neutral in the reducer (arrives after
                // task_complete). Priced when the model (from turn_context)
                // is in the table; otherwise tokens show unpriced.
                return entry(usageOnlyAssistant(usage), usageLimit: limit)
            default:  // agent_message/user_message duplicate response_items
                return entry(.meta(rawType: payload["type"] as? String ?? type))
            }

        default:
            return entry(.meta(rawType: type))
        }
    }

    private static func messageText(_ payload: [String: Any]) -> String? {
        guard let content = payload["content"] as? [[String: Any]] else {
            return payload["content"] as? String
        }
        let texts = content.compactMap { $0["text"] as? String }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    private static let isoWithFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let isoPlain = Date.ISO8601FormatStyle()

    private static func parseTimestamp(_ raw: String) -> Date? {
        (try? isoWithFraction.parse(raw)) ?? (try? isoPlain.parse(raw))
    }
}
