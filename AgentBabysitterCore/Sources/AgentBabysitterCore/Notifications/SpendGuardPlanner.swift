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
    /// Sessions already nudged in a PREVIOUS launch. The tracks live in memory,
    /// so without this a quit-and-reopen re-fires every nudge the user already
    /// saw for a still-running session. Pruned each `evaluate` to only sessions
    /// still in the live set (see the `formIntersection` there) so they cannot
    /// accumulate dead session UUIDs across launches.
    private var restoredBurnFired: Set<String> = []
    private var restoredBudgetFired: Set<String> = []

    public init() {}

    /// Seed the already-nudged sessions from persisted state at launch.
    public init(firedBurn: Set<String>, firedBudget: Set<String>) {
        restoredBurnFired = firedBurn
        restoredBudgetFired = firedBudget
    }

    /// Sessions that have been nudged, for the app layer to persist. Includes
    /// restored ids so a session pruned from `tracks` isn't re-nudged later.
    public var firedBurn: Set<String> {
        restoredBurnFired.union(tracks.filter(\.value.burnFired).keys)
    }
    public var firedBudget: Set<String> {
        restoredBudgetFired.union(tracks.filter(\.value.budgetFired).keys)
    }

    /// Feed every refresh; returns suggestions newly due this tick (each kind
    /// at most once per session, reset when the session leaves the list).
    public mutating func evaluate(rows: [SessionRow], config: Config = Config(),
                                  now: Date = Date()) -> [Suggestion] {
        var out: [Suggestion] = []
        var seen: Set<String> = []
        for row in rows {
            seen.insert(row.id)
            let dollars = row.cost.dollars
            // A first sighting inherits whatever this session was already
            // nudged for before the app restarted.
            var t = tracks[row.id] ?? Track(windowStart: now, windowStartDollars: dollars,
                                            lastBurn: 0,
                                            burnFired: restoredBurnFired.contains(row.id),
                                            budgetFired: restoredBudgetFired.contains(row.id))

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
        // Bound the restored sets. A previously-nudged id no longer in the live
        // set is a session that has aged out of SessionStore's retention window;
        // ids are unique per run, so it can never return. Without this prune the
        // restored{Burn,Budget}Fired sets — which the app re-persists to
        // UserDefaults on every nudging tick — would grow by one 36-char UUID
        // per nudged session across every launch and never shrink. Tying their
        // lifetime to `seen` prunes them exactly when the session ages out; a
        // still-running nudged session stays in `seen`, so it is never re-nudged.
        restoredBurnFired.formIntersection(seen)
        restoredBudgetFired.formIntersection(seen)
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
