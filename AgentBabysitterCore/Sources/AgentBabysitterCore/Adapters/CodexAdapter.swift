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

    public init(transcriptRoot: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/sessions")) {
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
            .assistant(AssistantPayload(messageID: nil, model: nil, stopReason: nil,
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
                let (dIn, dCached, dOut) = usageState?.delta(input: input,
                                                             cachedInput: cached,
                                                             output: output)
                    ?? (input, cached, output)
                let usage = TokenUsage(inputTokens: dIn,
                                       outputTokens: dOut,
                                       cacheCreationInputTokens: 0,
                                       cacheReadInputTokens: dCached)
                // Subscription 5h/weekly window readings ride along on
                // token_count. Primary is the 300-minute window.
                var limit: UsageLimitSnapshot?
                if let rateLimits = payload["rate_limits"] as? [String: Any],
                   let primary = rateLimits["primary"] as? [String: Any],
                   let usedPercent = primary["used_percent"] as? Double {
                    let resets = (primary["resets_at"] as? Double)
                        .map { Date(timeIntervalSince1970: $0) }
                    // Secondary is the weekly window when present.
                    let secondary = rateLimits["secondary"] as? [String: Any]
                    limit = UsageLimitSnapshot(
                        usedPercent: usedPercent,
                        windowMinutes: primary["window_minutes"] as? Int ?? 300,
                        resetsAt: resets,
                        capturedAt: timestamp ?? Date(),
                        plan: rateLimits["plan_type"] as? String,
                        weeklyUsedPercent: secondary?["used_percent"] as? Double,
                        weeklyResetsAt: (secondary?["resets_at"] as? Double)
                            .map { Date(timeIntervalSince1970: $0) })
                }
                // Usage-only: phase-neutral in the reducer (arrives after
                // task_complete). Model pricing is unknown by design — token
                // counts are shown, dollars are never guessed.
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
