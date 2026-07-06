import Foundation

/// Decides which limit alerts to fire — pure logic, unit-tested, so the app
/// layer only forwards results to the notification center.
public enum UsageAlertPlanner {

    public struct Alert: Equatable, Sendable {
        public let agentID: String
        public let isWeekly: Bool
        public let usedPercent: Double
        public let resetsAt: Date?
    }

    public struct Outcome: Equatable, Sendable {
        public let alerts: [Alert]
        public let alertedFiveHour: [String: Date]
        public let alertedWeekly: [String: Date]
    }

    /// One alert per agent per window, both the 5-hour and the weekly.
    /// A reading whose window already reset is stale — never alert on it.
    public static func plan(limits: [String: UsageLimitSnapshot],
                            threshold: Double,
                            alertedFiveHour: [String: Date],
                            alertedWeekly: [String: Date],
                            now: Date = Date()) -> Outcome {
        var alerts: [Alert] = []
        var fiveHour = alertedFiveHour
        var weekly = alertedWeekly

        for (agentID, limit) in limits.sorted(by: { $0.key < $1.key }) {
            if let used = limit.usedPercent, used >= threshold,
               limit.resetsAt.map({ $0 > now }) ?? true {
                let window = limit.resetsAt ?? bucket(now, seconds: 18_000)
                if fiveHour[agentID] != window {
                    fiveHour[agentID] = window
                    alerts.append(Alert(agentID: agentID, isWeekly: false,
                                        usedPercent: used, resetsAt: limit.resetsAt))
                }
            }
            if let used = limit.weeklyUsedPercent, used >= threshold,
               limit.weeklyResetsAt.map({ $0 > now }) ?? true {
                let window = limit.weeklyResetsAt ?? bucket(now, seconds: 7 * 86_400)
                if weekly[agentID] != window {
                    weekly[agentID] = window
                    alerts.append(Alert(agentID: agentID, isWeekly: true,
                                        usedPercent: used, resetsAt: limit.weeklyResetsAt))
                }
            }
        }
        return Outcome(alerts: alerts, alertedFiveHour: fiveHour, alertedWeekly: weekly)
    }

    private static func bucket(_ now: Date, seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970:
            (now.timeIntervalSince1970 / seconds).rounded(.down) * seconds)
    }
}

/// Fires the *predictive* limit warning: not "you crossed 80%" but "at this
/// pace you hit the wall at 2:14 PM — before the window resets". Complements
/// UsageAlertPlanner, which stays reactive: pace warns in the band between
/// `minUsedPercent` and the reactive threshold, and goes quiet above it so
/// the two never stack banners for the same reading.
public enum PaceAlertPlanner {

    public struct Alert: Equatable, Sendable {
        public let agentID: String
        public let isWeekly: Bool
        public let usedPercent: Double
        /// When the current pace crosses 100%.
        public let exhaustionAt: Date
        /// When the window would have reset anyway.
        public let resetsAt: Date
    }

    public struct Outcome: Equatable, Sendable {
        public let alerts: [Alert]
        public let alertedFiveHour: [String: Date]
        public let alertedWeekly: [String: Date]
    }

    /// Early-window pace looks alarming after any burst, so a projection only
    /// counts once real usage has accumulated…
    public static let minimumUsedPercent = 30.0
    /// …and only when it lands meaningfully before the reset.
    public static let minimumShortfall: TimeInterval = 10 * 60

    /// One warning per agent per window (5h and weekly independently),
    /// deduped by reset time exactly like UsageAlertPlanner.
    public static func plan(limits: [String: UsageLimitSnapshot],
                            threshold: Double,
                            alertedFiveHour: [String: Date],
                            alertedWeekly: [String: Date],
                            now: Date = Date()) -> Outcome {
        var alerts: [Alert] = []
        var fiveHour = alertedFiveHour
        var weekly = alertedWeekly

        for (agentID, limit) in limits.sorted(by: { $0.key < $1.key }) {
            if let alert = evaluate(agentID: agentID, snapshot: limit,
                                    isWeekly: false, threshold: threshold, now: now),
               fiveHour[agentID] != alert.resetsAt {
                fiveHour[agentID] = alert.resetsAt
                alerts.append(alert)
            }
            // The weekly fields ride on the same snapshot; the pace math is
            // window-agnostic, so lift them into a snapshot of their own.
            if let weeklyUsed = limit.weeklyUsedPercent,
               let weeklyResets = limit.weeklyResetsAt {
                let synthetic = UsageLimitSnapshot(usedPercent: weeklyUsed,
                                                   windowMinutes: 7 * 24 * 60,
                                                   resetsAt: weeklyResets,
                                                   capturedAt: limit.capturedAt,
                                                   plan: nil, isLive: limit.isLive,
                                                   weeklyUsedPercent: nil,
                                                   weeklyResetsAt: nil)
                if let alert = evaluate(agentID: agentID, snapshot: synthetic,
                                        isWeekly: true, threshold: threshold, now: now),
                   weekly[agentID] != alert.resetsAt {
                    weekly[agentID] = alert.resetsAt
                    alerts.append(alert)
                }
            }
        }
        return Outcome(alerts: alerts, alertedFiveHour: fiveHour, alertedWeekly: weekly)
    }

    private static func evaluate(agentID: String, snapshot: UsageLimitSnapshot,
                                 isWeekly: Bool, threshold: Double,
                                 now: Date) -> Alert? {
        guard let used = snapshot.usedPercent,
              used >= minimumUsedPercent, used < threshold,
              let resets = snapshot.resetsAt,
              let exhaustion = UsageForecast.projectedExhaustion(snapshot, now: now),
              resets.timeIntervalSince(exhaustion) >= minimumShortfall else { return nil }
        return Alert(agentID: agentID, isWeekly: isWeekly, usedPercent: used,
                     exhaustionAt: exhaustion, resetsAt: resets)
    }
}

/// Fires a heads-up when spend crosses a daily or weekly budget — once per
/// window (keyed by the local day / ISO week), so a long task can't quietly
/// blow the budget but you're not re-pinged all day. A budget of 0 is off.
public enum CostBudgetPlanner {

    public struct Alert: Equatable, Sendable {
        public let isWeekly: Bool
        public let spent: Double
        public let budget: Double
    }

    public struct Outcome: Equatable, Sendable {
        public let alerts: [Alert]
        public let alertedDayKey: String?
        public let alertedWeekKey: String?
    }

    /// `todaySpent`/`weekSpent` in USD; `dayKey`/`weekKey` identify the current
    /// windows (e.g. "2026-07-06" and "2026-W27"); the alerted keys are what
    /// last fired.
    public static func plan(todaySpent: Double, dailyBudget: Double, dayKey: String,
                            weekSpent: Double, weeklyBudget: Double, weekKey: String,
                            alertedDayKey: String?, alertedWeekKey: String?) -> Outcome {
        var alerts: [Alert] = []
        var day = alertedDayKey
        var week = alertedWeekKey
        if dailyBudget > 0, todaySpent >= dailyBudget, alertedDayKey != dayKey {
            day = dayKey
            alerts.append(Alert(isWeekly: false, spent: todaySpent, budget: dailyBudget))
        }
        if weeklyBudget > 0, weekSpent >= weeklyBudget, alertedWeekKey != weekKey {
            week = weekKey
            alerts.append(Alert(isWeekly: true, spent: weekSpent, budget: weeklyBudget))
        }
        return Outcome(alerts: alerts, alertedDayKey: day, alertedWeekKey: week)
    }
}

/// Local-day cost buckets persisted by the app (the store only retains 24h
/// of sessions, so history must accumulate outside it).
public enum DailyCostHistory {

    // ISO8601DateFormatter isn't Sendable; building per call keeps this pure
    // (it's on a 2s tick at most — negligible).
    private static func formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = .current
        return formatter
    }

    /// Local calendar day as "yyyy-MM-dd" — shares LocalDay's definition so
    /// the history/stats and the menu's today cost always agree.
    public static func key(for date: Date) -> String {
        LocalDay.key(of: date)
    }

    /// Folds today's running total in (max guards against dips when old
    /// sessions prune out mid-day) and drops entries older than `keepDays`.
    public static func updated(_ history: [String: Double], now: Date,
                               dollars: Double, keepDays: Int = 7) -> [String: Double] {
        var history = history
        let todayKey = key(for: now)
        history[todayKey] = max(history[todayKey] ?? 0, dollars)
        let cutoff = now.addingTimeInterval(-Double(keepDays) * 86_400)
        return history.filter { entry, _ in
            formatter().date(from: entry).map { $0 > cutoff } ?? false
        }
    }

    public static func series(_ history: [String: Double]) -> [(day: Date, dollars: Double)] {
        history
            .compactMap { key, dollars in formatter().date(from: key).map { ($0, dollars) } }
            .sorted { $0.0 < $1.0 }
    }
}

/// Layers usage readings from multiple sources over the on-disk base — for
/// the same agent the newest capture wins, except that a base reading with a
/// real percentage is never displaced by an older overlay.
public enum UsageLimitLayering {

    public static func merged(base: [String: UsageLimitSnapshot],
                              overlays: [[String: UsageLimitSnapshot]]) -> [String: UsageLimitSnapshot] {
        var merged = base
        for overlay in overlays {
            for (agentID, snapshot) in overlay {
                if let current = merged[agentID], current.usedPercent != nil,
                   current.capturedAt > snapshot.capturedAt { continue }
                merged[agentID] = snapshot
            }
        }
        return merged
    }
}
