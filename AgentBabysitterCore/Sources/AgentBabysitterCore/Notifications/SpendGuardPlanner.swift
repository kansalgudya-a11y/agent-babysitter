import Foundation

/// Advisory spend guard. Watches working sessions and, when one is burning
/// money fast or has quietly run up a large bill, raises a one-time
/// SUGGESTION — it never pauses, throttles, or stops the user's work. Every
/// alert is a nudge the user can act on or ignore.
///
/// Pure + stateful so it's testable; the app applies its own gates (toggle,
/// quiet hours, paused notifications) before surfacing anything.
public struct SpendGuardPlanner: Equatable, Sendable {

    public struct Config: Equatable, Sendable {
        /// Flag a working session whose measured burn exceeds this ($/min).
        public var burnRatePerMinute: Double
        /// Flag when a single session's running total crosses this ($).
        public var sessionBudget: Double
        /// Floor before any burn nudge fires — keeps cheap sessions quiet.
        public var minimumDollars: Double
        /// How long a burn-measurement window is; a full minute of real spend
        /// is averaged so a single tick's jump can't trip a false alarm.
        public var window: TimeInterval

        public init(burnRatePerMinute: Double = 1.5, sessionBudget: Double = 25,
                    minimumDollars: Double = 2, window: TimeInterval = 60) {
            self.burnRatePerMinute = burnRatePerMinute
            self.sessionBudget = sessionBudget
            self.minimumDollars = minimumDollars
            self.window = window
        }
    }

    public enum Kind: Equatable, Sendable {
        /// Recent burn rate is high while the session is actively working.
        case burningFast
        /// Running total has crossed the per-session budget.
        case crossedBudget
    }

    /// A nudge for one session. Numbers only — the app formats them through its
    /// display-currency `money` closure and builds copy via `message(...)`, so
    /// nudges respect the user's currency. Acting on it is always their choice.
    public struct Suggestion: Equatable, Sendable, Identifiable {
        public var id: String
        public var projectName: String
        public var agentName: String
        public var kind: Kind
        public var dollars: Double
        public var burnRatePerMinute: Double

        public init(id: String, projectName: String, agentName: String, kind: Kind,
                    dollars: Double, burnRatePerMinute: Double) {
            self.id = id; self.projectName = projectName; self.agentName = agentName
            self.kind = kind; self.dollars = dollars
            self.burnRatePerMinute = burnRatePerMinute
        }
    }

    private struct Track: Equatable, Sendable {
        var windowStart: Date
        var windowStartDollars: Double
        var lastBurn: Double        // $/min over the last completed window
        var burnFired: Bool
        var budgetFired: Bool
    }
    private var tracks: [String: Track] = [:]

    public init() {}

    /// Feed every refresh; returns suggestions newly due this tick (each kind
    /// at most once per session, reset when the session leaves the list).
    public mutating func evaluate(rows: [SessionRow], config: Config = Config(),
                                  now: Date = Date()) -> [Suggestion] {
        var out: [Suggestion] = []
        var seen: Set<String> = []
        for row in rows {
            seen.insert(row.id)
            let dollars = row.cost.dollars
            var t = tracks[row.id] ?? Track(windowStart: now, windowStartDollars: dollars,
                                            lastBurn: 0, burnFired: false, budgetFired: false)

            // Close the burn window once a full window of wall-clock has passed,
            // averaging real spend across it so single-tick jumps can't spike.
            let elapsed = now.timeIntervalSince(t.windowStart)
            if elapsed >= config.window {
                let gained = max(0, dollars - t.windowStartDollars)
                t.lastBurn = gained / (elapsed / 60)
                t.windowStart = now
                t.windowStartDollars = dollars
            }

            if row.state == .working, dollars >= config.minimumDollars,
               t.lastBurn >= config.burnRatePerMinute, !t.burnFired {
                t.burnFired = true
                out.append(Suggestion(id: row.id, projectName: row.projectName,
                                      agentName: row.agentName, kind: .burningFast,
                                      dollars: dollars, burnRatePerMinute: t.lastBurn))
            }
            if row.state == .working, dollars >= config.sessionBudget, !t.budgetFired {
                t.budgetFired = true
                out.append(Suggestion(id: row.id, projectName: row.projectName,
                                      agentName: row.agentName, kind: .crossedBudget,
                                      dollars: dollars, burnRatePerMinute: t.lastBurn))
            }
            tracks[row.id] = t
        }
        tracks = tracks.filter { seen.contains($0.key) }
        return out
    }

    /// Advisory copy from PRE-FORMATTED currency strings (the app formats the
    /// numbers via its display-currency `money` closure). Always a suggestion
    /// to look, never an instruction to stop.
    public static func message(_ kind: Kind, project: String,
                               dollarsText: String, burnText: String) -> String {
        switch kind {
        case .burningFast:
            return "\(project) is spending \(burnText)/min right now (\(dollarsText) so far). Might be worth a peek — if it's looping or over-thinking, a nudge or a cheaper model could save the rest."
        case .crossedBudget:
            return "\(project) has passed \(dollarsText) this session. If it's still on track, no worries — if not, now's a good time to jump in."
        }
    }
}
