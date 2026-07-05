import Foundation

/// Pure bookkeeping for the stats window: per-day per-agent dollars,
/// distinct session counts, and active minutes. The app layer persists the
/// result; this stays testable.
public enum StatsLedger {

    public struct Ledger: Equatable {
        public var costByAgent: [String: [String: Double]]
        public var costByProject: [String: [String: Double]]
        public var sessionCounts: [String: Int]
        public var todaySessionIDs: Set<String>
        public var activeMinutes: [String: Double]

        public init(costByAgent: [String: [String: Double]] = [:],
                    costByProject: [String: [String: Double]] = [:],
                    sessionCounts: [String: Int] = [:],
                    todaySessionIDs: Set<String> = [],
                    activeMinutes: [String: Double] = [:]) {
            self.costByAgent = costByAgent
            self.costByProject = costByProject
            self.sessionCounts = sessionCounts
            self.todaySessionIDs = todaySessionIDs
            self.activeMinutes = activeMinutes
        }
    }

    /// Combine two ledgers (e.g. this Mac's and a sibling Mac's synced copy)
    /// by taking the max per day — cost and counts only ever grow within a
    /// day, so max is the right, conflict-free merge. Session-id sets union.
    public static func merged(_ a: Ledger, _ b: Ledger) -> Ledger {
        func mergeNested(_ x: [String: [String: Double]],
                         _ y: [String: [String: Double]]) -> [String: [String: Double]] {
            var out = x
            for (day, inner) in y {
                var row = out[day] ?? [:]
                for (key, value) in inner { row[key] = max(row[key] ?? 0, value) }
                out[day] = row
            }
            return out
        }
        func mergeMax<V: Comparable>(_ x: [String: V], _ y: [String: V]) -> [String: V] {
            var out = x
            for (k, v) in y { out[k] = Swift.max(out[k] ?? v, v) }
            return out
        }
        return Ledger(costByAgent: mergeNested(a.costByAgent, b.costByAgent),
                      costByProject: mergeNested(a.costByProject, b.costByProject),
                      sessionCounts: mergeMax(a.sessionCounts, b.sessionCounts),
                      todaySessionIDs: a.todaySessionIDs.union(b.todaySessionIDs),
                      activeMinutes: mergeMax(a.activeMinutes, b.activeMinutes))
    }

    /// One tick: fold today's readings in. Max-merge guards against dips
    /// when sessions prune; the active-time credit is capped so a sleep/wake
    /// gap can't award hours.
    public static func ticked(_ ledger: Ledger, todayKey: String,
                              todayCostByAgent: [String: Double],
                              todayCostByProject: [String: Double] = [:],
                              visibleSessionIDs: some Sequence<String>,
                              anyWorking: Bool,
                              secondsSinceLastTick: TimeInterval) -> Ledger {
        var ledger = ledger
        var today = ledger.costByAgent[todayKey] ?? [:]
        for (agent, dollars) in todayCostByAgent {
            today[agent] = max(today[agent] ?? 0, dollars)
        }
        ledger.costByAgent[todayKey] = today

        var todayProjects = ledger.costByProject[todayKey] ?? [:]
        for (project, dollars) in todayCostByProject {
            todayProjects[project] = max(todayProjects[project] ?? 0, dollars)
        }
        ledger.costByProject[todayKey] = todayProjects

        ledger.todaySessionIDs.formUnion(visibleSessionIDs)
        ledger.sessionCounts[todayKey] = ledger.todaySessionIDs.count

        if anyWorking {
            ledger.activeMinutes[todayKey, default: 0]
                += min(secondsSinceLastTick, 60) / 60
        }
        return ledger
    }
}
