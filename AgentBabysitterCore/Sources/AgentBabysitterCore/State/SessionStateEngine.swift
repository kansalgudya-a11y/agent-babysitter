import Foundation

public enum SessionState: Equatable, Sendable, CaseIterable {
    case working          // 🟢 transcript actively growing
    case waitingForInput  // 🟡 blocked on the user (permission prompt)
    case done             // 🔵 turn finished, process idle at the prompt
    case stalled          // 🔴 mid-turn but nothing happening
    case ended            // ⚫ no live process

    /// Menu bar aggregation: the state most worth the user's attention.
    /// Priority 🟡 > 🔴 > 🟢 > 🔵; ended sessions don't participate.
    public static func worst(of states: some Sequence<SessionState>) -> SessionState? {
        let priority: [SessionState: Int] = [.waitingForInput: 3, .stalled: 2, .working: 1, .done: 0]
        return states.filter { $0 != .ended }.max { priority[$0]! < priority[$1]! }
    }
}

/// An event delivered by the Precision-mode hooks (exact signals from Claude
/// Code itself, no heuristics).
public struct HookSignal: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case waitingForInput  // Notification hook
        case turnCompleted    // Stop hook
        case toolStarted      // PreToolUse hook — a tool began EXECUTING, so
                              // any permission prompt was approved: working,
                              // however long the tool runs
    }
    public let kind: Kind
    public let timestamp: Date
    /// What the agent said: the permission/question text for
    /// waitingForInput, the reply's first line for turnCompleted, the tool
    /// name for toolStarted.
    public let detail: String?

    public init(kind: Kind, timestamp: Date, detail: String? = nil) {
        self.kind = kind
        self.timestamp = timestamp
        self.detail = detail
    }
}

/// Everything known about a session at evaluation time.
public struct SessionSignals: Equatable, Sendable {
    public var processAlive: Bool
    public var lastGrowthAt: Date?
    public var turnPhase: TurnPhase
    public var hasPendingToolUses: Bool
    public var latestHookEvent: HookSignal?
    public var precisionModeEnabled: Bool

    public init(processAlive: Bool, lastGrowthAt: Date?, turnPhase: TurnPhase,
                hasPendingToolUses: Bool, latestHookEvent: HookSignal? = nil,
                precisionModeEnabled: Bool = false) {
        self.processAlive = processAlive
        self.lastGrowthAt = lastGrowthAt
        self.turnPhase = turnPhase
        self.hasPendingToolUses = hasPendingToolUses
        self.latestHookEvent = latestHookEvent
        self.precisionModeEnabled = precisionModeEnabled
    }
}

/// Pure state evaluation — call it on every FSEvents callback, process poll,
/// hook event, or timer tick. Precedence: dead process > hook events >
/// transcript heuristics.
public enum SessionStateEngine {

    public static func evaluate(_ signals: SessionSignals,
                                at now: Date,
                                stallThreshold: TimeInterval = 300,
                                workingWindow: TimeInterval = 10) -> SessionState {
        guard signals.processAlive else { return .ended }

        // A hook event outranks heuristics unless the transcript has grown
        // since it fired (the session has visibly moved on).
        if signals.precisionModeEnabled, let hook = signals.latestHookEvent,
           hook.timestamp >= (signals.lastGrowthAt ?? .distantPast) {
            switch hook.kind {
            case .waitingForInput: return .waitingForInput
            case .turnCompleted: return .done
            case .toolStarted: return .working  // runs however long the tool does
            }
        }

        switch signals.turnPhase {
        case .idle, .completed, .aborted:
            // Not in a turn. Meta lines may keep appending after end_turn;
            // that growth isn't "working".
            return .done

        case .midTurn:
            let growthAge = signals.lastGrowthAt.map { now.timeIntervalSince($0) }
                ?? .greatestFiniteMagnitude
            if growthAge < workingWindow {
                return .working  // streaming right now
            }
            if signals.hasPendingToolUses, !signals.precisionModeEnabled {
                // tool_use written, no result, output quiet. In the transcript
                // alone a permission prompt and a long-running tool look
                // IDENTICAL, so this guess is heuristic-mode only — with hooks
                // on, real prompts arrive exactly via the Notification hook,
                // and this guess would mislabel every slow build as waiting.
                return .waitingForInput
            }
            return growthAge >= stallThreshold ? .stalled : .working
        }
    }
}
