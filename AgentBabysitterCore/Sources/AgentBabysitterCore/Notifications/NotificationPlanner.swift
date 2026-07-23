import Foundation

public struct NotificationEvent: Equatable, Hashable, Sendable {
    public enum Kind: Equatable, Hashable, Sendable {
        case waitingForInput
        case turnCompleted
        case stalled
    }
    public let sessionID: String
    public let kind: Kind

    public init(sessionID: String, kind: Kind) {
        self.sessionID = sessionID
        self.kind = kind
    }
}

/// Turns successive row snapshots into notification edges:
/// - waiting: once per waiting episode. This INCLUDES the first time the planner
///   sees a session that is already `.waitingForInput` — you open the app
///   precisely when you suspect an agent is blocked, and a session already
///   sitting on a question is the flagship thing to surface. It fires once, then
///   `previous == .waiting` suppresses re-fires until the episode ends.
/// - turn completed: once per turn (on the transition into done). Suppressed on
///   first sight — a launch scan of a screen full of already-finished sessions
///   must not ding for each one.
/// - stalled: once per stall, reset when the session resumes, but no more often
///   than `stallCooldown` apart. A session flapping stalled↔working through a
///   long chain of slow tool calls therefore dings at most once per cooldown
///   instead of every cycle. Suppressed on first sight (same launch-scan reason
///   as done).
public struct NotificationPlanner: Sendable {

    private var previousStates: [String: SessionState] = [:]
    /// When each session last fired a `.stalled` edge. Used only to rate-limit
    /// re-stalls across flapping; deliberately NOT cleared when the session
    /// resumes (that flap is exactly what we are damping), only when the session
    /// is forgotten.
    private var lastStallFiredAt: [String: Date] = [:]

    public init() {}

    /// `now`/`stallCooldown` are defaulted so existing call sites (`events(for:)`)
    /// keep compiling. `stallCooldown` defaults to 600 s = 2x the registered
    /// 5-min stall threshold; the app may pass a value derived from the user's
    /// own stall setting for an exact 2x.
    public mutating func events(for rows: [SessionRow],
                                now: Date = Date(),
                                stallCooldown: TimeInterval = 600) -> [NotificationEvent] {
        var events: [NotificationEvent] = []
        var currentStates: [String: SessionState] = [:]

        for row in rows {
            currentStates[row.id] = row.state
            if let previous = previousStates[row.id] {
                if previous == row.state { continue }  // no change
                switch row.state {
                case .waitingForInput:
                    events.append(NotificationEvent(sessionID: row.id, kind: .waitingForInput))
                case .done where previous != .ended:
                    events.append(NotificationEvent(sessionID: row.id, kind: .turnCompleted))
                case .stalled:
                    if shouldFireStall(row.id, now: now, cooldown: stallCooldown) {
                        events.append(NotificationEvent(sessionID: row.id, kind: .stalled))
                    }
                default:
                    break
                }
            } else if row.state == .waitingForInput {
                // First sight: an already-waiting session fires (a blocked agent
                // must never sit unnoticed). Done/stalled stay quiet so opening
                // the app doesn't spam a list of work the user can already see.
                events.append(NotificationEvent(sessionID: row.id, kind: .waitingForInput))
            }
        }

        // Ended (or vanished) sessions are forgotten so a resurrected id is
        // treated as a fresh first sight; keep the stall-cooldown map aligned to
        // exactly that retained set.
        previousStates = currentStates.filter { $0.value != .ended }
        lastStallFiredAt = lastStallFiredAt.filter { previousStates[$0.key] != nil }
        return events
    }

    /// One stall banner per session per `cooldown`; records the fire time so the
    /// next stall within the window is suppressed. Not reset on resume.
    private mutating func shouldFireStall(_ id: String, now: Date,
                                          cooldown: TimeInterval) -> Bool {
        if let last = lastStallFiredAt[id], now.timeIntervalSince(last) < cooldown {
            return false
        }
        lastStallFiredAt[id] = now
        return true
    }
}
