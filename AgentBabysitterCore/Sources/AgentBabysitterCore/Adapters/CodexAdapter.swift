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

    public func parseLine(_ line: Data) -> LineParseResult {
        CodexRolloutParser.parse(line)
    }

    public func agentPIDs(psComm: String, psArgs: String) -> [Int32] {
        var pids = Set<Int32>()
        for line in psComm.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }),
                  let pid = Int32(trimmed[..<space]) else { continue }
            let command = trimmed[trimmed.index(after: space)...]
                .trimmingCharacters(in: .whitespaces)
            if command.split(separator: "/").last == "codex" {
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
        return match
    }
}

/// Maps one Codex rollout line into the normalized entry model.
enum CodexRolloutParser {

    static func parse(_ line: Data) -> LineParseResult {
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
                   entrypoint: String? = nil) -> LineParseResult {
            .entry(TranscriptEntry(kind: kind, uuid: nil, timestamp: timestamp,
                                   sessionID: sessionID, cwd: cwd,
                                   isSidechain: isSidechain, entrypoint: entrypoint))
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
                let last = info?["last_token_usage"] as? [String: Any]
                let usage = TokenUsage(
                    inputTokens: last?["input_tokens"] as? Int ?? 0,
                    outputTokens: last?["output_tokens"] as? Int ?? 0,
                    cacheCreationInputTokens: 0,
                    cacheReadInputTokens: last?["cached_input_tokens"] as? Int ?? 0)
                // Usage-only: phase-neutral in the reducer (arrives after
                // task_complete). Model pricing is unknown by design — token
                // counts are shown, dollars are never guessed.
                return entry(usageOnlyAssistant(usage))
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
