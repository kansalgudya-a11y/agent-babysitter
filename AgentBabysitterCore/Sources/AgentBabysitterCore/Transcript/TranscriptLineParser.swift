import Foundation

public enum LineParseResult: Equatable, Sendable {
    case entry(TranscriptEntry)
    /// Whitespace-only line — skipped, not counted as malformed.
    case empty
    /// Undecodable line — skip and count; sessions with many of these get
    /// flagged unreadable upstream.
    case malformed
}

/// Parses one JSONL transcript line. Tolerant by design: only `type` is
/// required; every other field is optional so schema drift degrades a line
/// to partial data instead of a parse failure.
public enum TranscriptLineParser {

    public static func parse(_ line: String) -> LineParseResult {
        parse(Data(line.utf8))
    }

    public static func parse(_ line: Data) -> LineParseResult {
        guard !isBlank(line) else { return .empty }
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = object["type"] as? String else {
            return .malformed
        }
        return .entry(entry(type: type, object: object))
    }

    // MARK: - Entry assembly

    private static func entry(type: String, object: [String: Any]) -> TranscriptEntry {
        let kind: TranscriptEntry.Kind
        switch type {
        case "user":
            kind = .user(userPayload(object["message"] as? [String: Any]))
        case "assistant":
            kind = .assistant(assistantPayload(object["message"] as? [String: Any]))
        default:
            kind = .meta(rawType: type)
        }
        return TranscriptEntry(
            kind: kind,
            uuid: object["uuid"] as? String,
            timestamp: (object["timestamp"] as? String).flatMap(parseTimestamp),
            sessionID: object["sessionId"] as? String,
            cwd: object["cwd"] as? String,
            isSidechain: object["isSidechain"] as? Bool ?? false
        )
    }

    private static func userPayload(_ message: [String: Any]?) -> UserPayload {
        // content is either a plain string or an array of blocks
        if let plain = message?["content"] as? String {
            return UserPayload(text: plain, toolResults: [])
        }
        var texts: [String] = []
        var results: [ToolResultRef] = []
        for block in message?["content"] as? [[String: Any]] ?? [] {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String { texts.append(text) }
            case "tool_result":
                if let id = block["tool_use_id"] as? String {
                    results.append(ToolResultRef(toolUseID: id,
                                                 isError: block["is_error"] as? Bool ?? false))
                }
            default:
                break
            }
        }
        return UserPayload(text: texts.isEmpty ? nil : texts.joined(separator: "\n"),
                           toolResults: results)
    }

    private static func assistantPayload(_ message: [String: Any]?) -> AssistantPayload {
        var toolUses: [ToolUseRef] = []
        var hasText = false
        var hasThinking = false
        for block in message?["content"] as? [[String: Any]] ?? [] {
            switch block["type"] as? String {
            case "text": hasText = true
            case "thinking": hasThinking = true
            case "tool_use":
                if let id = block["id"] as? String, let name = block["name"] as? String {
                    toolUses.append(ToolUseRef(id: id, name: name))
                }
            default:
                break
            }
        }
        return AssistantPayload(
            messageID: message?["id"] as? String,
            model: message?["model"] as? String,
            stopReason: (message?["stop_reason"] as? String).map(StopReason.init(rawValue:)),
            usage: (message?["usage"] as? [String: Any]).flatMap(tokenUsage),
            toolUses: toolUses,
            hasText: hasText,
            hasThinking: hasThinking
        )
    }

    private static func tokenUsage(_ usage: [String: Any]) -> TokenUsage? {
        // input/output are the schema's baseline; cache fields default to 0
        guard let input = usage["input_tokens"] as? Int,
              let output = usage["output_tokens"] as? Int else { return nil }
        return TokenUsage(
            inputTokens: input,
            outputTokens: output,
            cacheCreationInputTokens: usage["cache_creation_input_tokens"] as? Int ?? 0,
            cacheReadInputTokens: usage["cache_read_input_tokens"] as? Int ?? 0
        )
    }

    // MARK: - Timestamps

    private static let isoWithFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let isoPlain = Date.ISO8601FormatStyle()

    private static func parseTimestamp(_ raw: String) -> Date? {
        (try? isoWithFraction.parse(raw)) ?? (try? isoPlain.parse(raw))
    }

    private static func isBlank(_ data: Data) -> Bool {
        data.allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D || $0 == 0x0A }
    }
}
