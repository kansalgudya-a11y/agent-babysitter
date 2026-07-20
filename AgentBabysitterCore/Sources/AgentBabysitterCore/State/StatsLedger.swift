import Foundation

/// Pure bookkeeping for the stats window: per-day per-agent dollars,
/// distinct session counts, and active minutes. The app layer persists the
/// result; this stays testable.
public enum StatsLedger {

    public struct Ledger: Equatable {
        public var costByAgent: [String: [String: Double]]
        public var costByProject: [String: [String: Double]]
        public var costByModel: [String: [String: Double]]
        public var sessionCounts: [String: Int]
        /// Every session id ever counted (all-time, persisted). A session is
        /// counted ONCE, on the day it was first seen, so summing sessionCounts
        /// across a range gives DISTINCT sessions — a multi-day session no longer
        /// adds one per day it was alive.
        public var countedSessionIDs: Set<String>
        public var activeMinutes: [String: Double]

        public init(costByAgent: [String: [String: Double]] = [:],
                    costByProject: [String: [String: Double]] = [:],
                    costByModel: [String: [String: Double]] = [:],
                    sessionCounts: [String: Int] = [:],
                    countedSessionIDs: Set<String> = [],
                    activeMinutes: [String: Double] = [:]) {
            self.costByAgent = costByAgent
            self.costByProject = costByProject
            self.costByModel = costByModel
            self.sessionCounts = sessionCounts
            self.countedSessionIDs = countedSessionIDs
            self.activeMinutes = activeMinutes
        }
    }

    /// Cross-machine total: SUM per day across distinct machines' ledgers.
    /// Each machine's file already holds its own per-day totals, so summing
    /// gives the household figure (max would only surface the busiest Mac).
    /// Used for the merged DISPLAY view only — never written back to a
    /// machine's own ledger (which stays this-machine-only).
    public static func summed(_ ledgers: [Ledger]) -> Ledger {
        func addNested(_ into: inout [String: [String: Double]],
                       _ from: [String: [String: Double]]) {
            for (day, inner) in from {
                var row = into[day] ?? [:]
                for (key, value) in inner { row[key, default: 0] += value }
                into[day] = row
            }
        }
        var out = Ledger()
        for ledger in ledgers {
            addNested(&out.costByAgent, ledger.costByAgent)
            addNested(&out.costByProject, ledger.costByProject)
            addNested(&out.costByModel, ledger.costByModel)
            for (day, n) in ledger.sessionCounts { out.sessionCounts[day, default: 0] += n }
            for (day, m) in ledger.activeMinutes { out.activeMinutes[day, default: 0] += m }
        }
        return out
    }

    /// Combine two ledgers by taking the max per day — used WITHIN one machine
    /// over time (cost/counts only grow within a day, so max guards against
    /// dips when sessions prune). Session-id sets union.
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
                      costByModel: mergeNested(a.costByModel, b.costByModel),
                      sessionCounts: mergeMax(a.sessionCounts, b.sessionCounts),
                      countedSessionIDs: a.countedSessionIDs.union(b.countedSessionIDs),
                      activeMinutes: mergeMax(a.activeMinutes, b.activeMinutes))
    }

    /// One tick: fold today's readings in. Max-merge guards against dips
    /// when sessions prune; the active-time credit is capped so a sleep/wake
    /// gap can't award hours.
    public static func ticked(_ ledger: Ledger, todayKey: String,
                              todayCostByAgent: [String: Double],
                              todayCostByProject: [String: Double] = [:],
                              todayCostByModel: [String: Double] = [:],
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

        var todayModels = ledger.costByModel[todayKey] ?? [:]
        for (model, dollars) in todayCostByModel {
            todayModels[model] = max(todayModels[model] ?? 0, dollars)
        }
        ledger.costByModel[todayKey] = todayModels

        // Count each session once, on its first-seen day, so a range sum is the
        // distinct-session count (not sessions-times-days-alive).
        for id in visibleSessionIDs where !ledger.countedSessionIDs.contains(id) {
            ledger.countedSessionIDs.insert(id)
            ledger.sessionCounts[todayKey, default: 0] += 1
        }

        if anyWorking {
            ledger.activeMinutes[todayKey, default: 0]
                += min(secondsSinceLastTick, 60) / 60
        }
        return ledger
    }
}
