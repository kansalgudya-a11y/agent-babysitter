import Foundation

/// Where a session is within its current turn, as far as the transcript shows.
public enum TurnPhase: Equatable, Sendable {
    /// No prompt seen yet (fresh session or metadata-only transcript).
    case idle
    /// A prompt was submitted and the turn hasn't finished.
    case midTurn
    /// The last turn finished normally (`end_turn`, or a synthetic notice).
    case completed
    /// The user interrupted the turn.
    case aborted
}

/// Folds parsed transcript entries into the facts the state engine needs.
/// Pure accumulation — no clocks, no processes; feed it entries in file order.
public struct TranscriptReducer: Equatable, Sendable {

    public private(set) var turnPhase: TurnPhase = .idle
    public private(set) var pendingToolUseIDs: Set<String> = []
    /// Timestamp of the prompt that started the current (or just-finished)
    /// turn — the UI shows elapsed time from here.
    public private(set) var currentTurnStartedAt: Date?

    public init() {}

    public mutating func consume(_ entry: TranscriptEntry) {
        switch entry.kind {
        case .meta:
            break

        case .user(let payload):
            if !payload.toolResults.isEmpty {
                for result in payload.toolResults {
                    pendingToolUseIDs.remove(result.toolUseID)
                }
            } else if let text = payload.text {
                if text.hasPrefix("[Request interrupted") {
                    // Interrupt cancels in-flight tool calls; nothing will
                    // ever answer them, so they must not read as "waiting".
                    turnPhase = .aborted
                    pendingToolUseIDs.removeAll()
                } else {
                    turnPhase = .midTurn
                    currentTurnStartedAt = entry.timestamp
                }
            }

        case .assistant(let payload):
            for use in payload.toolUses {
                pendingToolUseIDs.insert(use.id)
            }
            switch payload.stopReason {
            case .endTurn, .stopSequence:
                // stop_sequence covers synthetic notices ("No response requested.")
                turnPhase = .completed
            default:
                // Usage-only bookkeeping entries (no content at all — e.g.
                // Codex token_count events, which arrive after task_complete)
                // must not reopen a finished turn.
                if payload.hasText || payload.hasThinking || !payload.toolUses.isEmpty {
                    turnPhase = .midTurn
                }
            }
        }
    }
}
