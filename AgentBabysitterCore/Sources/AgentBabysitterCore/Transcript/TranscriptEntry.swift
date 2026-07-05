import Foundation

/// Token usage as reported in an assistant entry's `message.usage`.
///
/// Cache-write and cache-read tokens are priced differently from plain input
/// tokens and must never be lumped together.
public struct TokenUsage: Equatable, Sendable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheCreationInputTokens: Int
    public let cacheReadInputTokens: Int
    /// TTL breakdown of cache writes — 5m and 1h are billed at different
    /// rates (1.25x vs 2x input). Claude Code writes 1h entries, so lumping
    /// the aggregate under one rate would misprice most real sessions.
    public let cacheCreation5mTokens: Int
    public let cacheCreation1hTokens: Int

    public init(inputTokens: Int, outputTokens: Int,
                cacheCreationInputTokens: Int, cacheReadInputTokens: Int,
                cacheCreation5mTokens: Int? = nil, cacheCreation1hTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        if cacheCreation5mTokens == nil && cacheCreation1hTokens == nil {
            // No breakdown in the schema: treat the aggregate as 5m (the
            // API's default TTL).
            self.cacheCreation5mTokens = cacheCreationInputTokens
            self.cacheCreation1hTokens = 0
        } else {
            self.cacheCreation5mTokens = cacheCreation5mTokens ?? 0
            self.cacheCreation1hTokens = cacheCreation1hTokens ?? 0
        }
    }

    /// Tokens of NEW work: input, output, and freshly cached content.
    /// Cache re-reads are deliberately excluded — the same context is
    /// re-read on every call, so counting it inflates a normal day's usage
    /// ~100x (a real day measured 2.6M new tokens vs 266M with re-reads).
    /// Their (cheap) price still lands in the dollar estimate.
    public var totalTokens: Int {
        inputTokens + outputTokens + cacheCreationInputTokens
    }
}

public enum StopReason: Equatable, Sendable {
    case toolUse
    case endTurn
    case stopSequence
    case other(String)

    init(rawValue: String) {
        switch rawValue {
        case "tool_use": self = .toolUse
        case "end_turn": self = .endTurn
        case "stop_sequence": self = .stopSequence
        default: self = .other(rawValue)
        }
    }
}

/// A `tool_use` content block: the model asked to run a tool.
public struct ToolUseRef: Equatable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// A `tool_result` content block: a tool's output delivered back to the model.
public struct ToolResultRef: Equatable, Sendable {
    public let toolUseID: String
    public let isError: Bool

    public init(toolUseID: String, isError: Bool) {
        self.toolUseID = toolUseID
        self.isError = isError
    }
}

/// One `type: "assistant"` line. A single API message is written as several
/// consecutive lines (one per content block), each repeating the same
/// `messageID` and the full identical `usage` — dedupe by `messageID` before
/// summing costs.
public struct AssistantPayload: Equatable, Sendable {
    public let messageID: String?
    public let model: String?
    public let stopReason: StopReason?
    public let usage: TokenUsage?
    public let toolUses: [ToolUseRef]
    public let hasText: Bool
    public let hasThinking: Bool
}

/// One `type: "user"` line: either a real prompt (`text`) or tool results
/// flowing back to the model (`toolResults`).
public struct UserPayload: Equatable, Sendable {
    /// Prompt text, or protocol notices like "[Request interrupted by user]".
    public let text: String?
    public let toolResults: [ToolResultRef]
}

/// A subscription rate-limit reading an agent wrote into its transcript
/// (Codex embeds one per token_count). `usedPercent` is 0-100 of the window.
public struct UsageLimitSnapshot: Equatable, Sendable, Codable {
    /// 0-100 of the window. nil when the plan is known but the percentage
    /// isn't published anywhere readable (e.g. Antigravity offline).
    public let usedPercent: Double?
    public let windowMinutes: Int
    public let resetsAt: Date?
    public let capturedAt: Date
    public let plan: String?
    /// True when fetched over the network (opt-in), false when read from disk.
    public let isLive: Bool
    /// The 7-day window, when the agent publishes one alongside the 5-hour.
    public let weeklyUsedPercent: Double?
    public let weeklyResetsAt: Date?

    public init(usedPercent: Double?, windowMinutes: Int, resetsAt: Date?,
                capturedAt: Date, plan: String?, isLive: Bool = false,
                weeklyUsedPercent: Double? = nil, weeklyResetsAt: Date? = nil) {
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
        self.capturedAt = capturedAt
        self.plan = plan
        self.isLive = isLive
        self.weeklyUsedPercent = weeklyUsedPercent
        self.weeklyResetsAt = weeklyResetsAt
    }
}

/// A single parsed transcript line.
public struct TranscriptEntry: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case user(UserPayload)
        case assistant(AssistantPayload)
        /// Any other line type (queue-operation, ai-title, attachment, system, …).
        /// Irrelevant to state and cost, but still counts as file growth.
        case meta(rawType: String)
    }

    public let kind: Kind
    public let uuid: String?
    public let timestamp: Date?
    public let sessionID: String?
    public let cwd: String?
    public let isSidechain: Bool
    /// What launched the session: "claude-desktop" (desktop app),
    /// "sdk-cli" (CLI/SDK), … — drives focus-on-click and the row badge.
    public let entrypoint: String?
    /// Rate-limit reading carried by this line, when the agent records one.
    public let usageLimit: UsageLimitSnapshot?

    public init(kind: Kind, uuid: String?, timestamp: Date?, sessionID: String?,
                cwd: String?, isSidechain: Bool, entrypoint: String? = nil,
                usageLimit: UsageLimitSnapshot? = nil) {
        self.kind = kind
        self.uuid = uuid
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.cwd = cwd
        self.isSidechain = isSidechain
        self.entrypoint = entrypoint
        self.usageLimit = usageLimit
    }
}
