import Foundation

/// Pure bookkeeping for "what Agent Babysitter caught for you": the discrete
/// wins it surfaced over time — stalls flagged, waiting pings delivered, spend
/// suggestions raised, and the dollars sitting on sessions it flagged. This is
/// the number that tells a user the app is earning its keep.
///
/// Unlike `StatsLedger` (whose per-day cost only ever grows, so it max-merges),
/// impact events are discrete: the app counts each episode once via its own
/// planners, then ADDS the delta here. Cross-machine display sums per day.
public enum ImpactLedger {

    public struct Ledger: Equatable, Sendable, Codable {
        public var stallsCaught: [String: Int]
        public var waitingPings: [String: Int]
        public var suggestions: [String: Int]
        public var dollarsFlagged: [String: Double]

        public init(stallsCaught: [String: Int] = [:],
                    waitingPings: [String: Int] = [:],
                    suggestions: [String: Int] = [:],
                    dollarsFlagged: [String: Double] = [:]) {
            self.stallsCaught = stallsCaught
            self.waitingPings = waitingPings
            self.suggestions = suggestions
            self.dollarsFlagged = dollarsFlagged
        }
    }

    /// Fold today's newly-observed events in (deltas ADD). The app supplies
    /// counts its episode logic already deduped — a stall counted once per
    /// stall episode, a ping once per delivery, a suggestion once per nudge.
    public static func recorded(_ ledger: Ledger, todayKey: String,
                                stalls: Int = 0, waits: Int = 0,
                                suggestions: Int = 0, dollarsFlagged: Double = 0) -> Ledger {
        var l = ledger
        if stalls != 0 { l.stallsCaught[todayKey, default: 0] += stalls }
        if waits != 0 { l.waitingPings[todayKey, default: 0] += waits }
        if suggestions != 0 { l.suggestions[todayKey, default: 0] += suggestions }
        if dollarsFlagged != 0 { l.dollarsFlagged[todayKey, default: 0] += dollarsFlagged }
        return l
    }

    /// Cross-machine total: SUM per day across each Mac's own ledger.
    public static func summed(_ ledgers: [Ledger]) -> Ledger {
        var out = Ledger()
        func addInt(_ into: inout [String: Int], _ from: [String: Int]) {
            for (k, v) in from { into[k, default: 0] += v }
        }
        for l in ledgers {
            addInt(&out.stallsCaught, l.stallsCaught)
            addInt(&out.waitingPings, l.waitingPings)
            addInt(&out.suggestions, l.suggestions)
            for (k, v) in l.dollarsFlagged { out.dollarsFlagged[k, default: 0] += v }
        }
        return out
    }

    /// Drop day keys older than `cutoffKey`. "yyyy-MM-dd" keys sort lexically
    /// = chronologically, so `>=` keeps the recent window and bounds the blob.
    public static func pruned(_ ledger: Ledger, keepingFrom cutoffKey: String) -> Ledger {
        func keep(_ d: [String: Int]) -> [String: Int] { d.filter { $0.key >= cutoffKey } }
        return Ledger(stallsCaught: keep(ledger.stallsCaught),
                      waitingPings: keep(ledger.waitingPings),
                      suggestions: keep(ledger.suggestions),
                      dollarsFlagged: ledger.dollarsFlagged.filter { $0.key >= cutoffKey })
    }

    public struct Summary: Equatable, Sendable {
        public var stalls: Int
        public var waits: Int
        public var suggestions: Int
        public var dollarsFlagged: Double

        public init(stalls: Int = 0, waits: Int = 0, suggestions: Int = 0, dollarsFlagged: Double = 0) {
            self.stalls = stalls; self.waits = waits
            self.suggestions = suggestions; self.dollarsFlagged = dollarsFlagged
        }

        /// True once there's anything worth showing.
        public var hasContent: Bool { stalls > 0 || waits > 0 || suggestions > 0 || dollarsFlagged > 0 }
    }

    /// Roll up totals over a set of day keys (e.g. this month, or last 7 days).
    public static func summary(_ ledger: Ledger, days: some Sequence<String>) -> Summary {
        var s = Summary()
        for day in days {
            s.stalls += ledger.stallsCaught[day] ?? 0
            s.waits += ledger.waitingPings[day] ?? 0
            s.suggestions += ledger.suggestions[day] ?? 0
            s.dollarsFlagged += ledger.dollarsFlagged[day] ?? 0
        }
        return s
    }
}
