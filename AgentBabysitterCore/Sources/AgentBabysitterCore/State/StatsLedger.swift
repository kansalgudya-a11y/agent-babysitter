import Foundation

/// Pure bookkeeping for the stats window: per-day per-agent dollars,
/// distinct session counts, and active minutes. The app layer persists the
/// result; this stays testable.
public enum StatsLedger {

    public struct Ledger: Equatable {
        public var costByAgent: [String: [String: Double]]
        public var sessionCounts: [String: Int]
        public var todaySessionIDs: Set<String>
        public var activeMinutes: [String: Double]

        public init(costByAgent: [String: [String: Double]] = [:],
                    sessionCounts: [String: Int] = [:],
                    todaySessionIDs: Set<String> = [],
                    activeMinutes: [String: Double] = [:]) {
            self.costByAgent = costByAgent
            self.sessionCounts = sessionCounts
            self.todaySessionIDs = todaySessionIDs
            self.activeMinutes = activeMinutes
        }
    }

    /// One tick: fold today's readings in. Max-merge guards against dips
    /// when sessions prune; the active-time credit is capped so a sleep/wake
    /// gap can't award hours.
    public static func ticked(_ ledger: Ledger, todayKey: String,
                              todayCostByAgent: [String: Double],
                              visibleSessionIDs: some Sequence<String>,
                              anyWorking: Bool,
                              secondsSinceLastTick: TimeInterval) -> Ledger {
        var ledger = ledger
        var today = ledger.costByAgent[todayKey] ?? [:]
        for (agent, dollars) in todayCostByAgent {
            today[agent] = max(today[agent] ?? 0, dollars)
        }
        ledger.costByAgent[todayKey] = today

        ledger.todaySessionIDs.formUnion(visibleSessionIDs)
        ledger.sessionCounts[todayKey] = ledger.todaySessionIDs.count

        if anyWorking {
            ledger.activeMinutes[todayKey, default: 0]
                += min(secondsSinceLastTick, 60) / 60
        }
        return ledger
    }
}
