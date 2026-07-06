import Foundation

/// Pace math over a single usage reading. Agents write their used-% only
/// when turns complete, so a reading can be an hour old while usage keeps
/// accruing — extrapolating the pace both corrects the displayed number
/// ("≈9%" instead of a stale 7%) and powers the forecast ("on pace to run
/// out 40m before reset"). Window start is `resetsAt - windowMinutes`;
/// pace is assumed linear across the window, which matches how the vendors
/// themselves describe consumption.
public enum UsageForecast {

    /// Don't extrapolate off almost-nothing: tiny elapsed time or tiny
    /// usage make the linear pace meaningless.
    static let minimumElapsed: TimeInterval = 20 * 60
    static let minimumPercent = 3.0
    /// A fresh reading is truth; only estimate once it has actually aged.
    static let staleAfter: TimeInterval = 10 * 60
    /// A projection is only as trustworthy as the reading behind it. Past
    /// this age the pace is history, not a forecast — a Friday reading must
    /// not project a "hit the limit" line all weekend. Enforced by both
    /// forecast calls so every consumer (menu caption AND notification)
    /// inherits the same freshness policy.
    public static let maximumStaleness: TimeInterval = 60 * 60

    /// The pace-corrected "probably right now" percentage, or nil when the
    /// raw reading should be shown as-is (fresh, unmeasurable, or expired).
    public static func estimatedCurrentPercent(_ snapshot: UsageLimitSnapshot,
                                               now: Date = Date()) -> Double? {
        guard let used = snapshot.usedPercent,
              let resets = snapshot.resetsAt, resets > now,
              now.timeIntervalSince(snapshot.capturedAt) > staleAfter,
              used >= minimumPercent else { return nil }
        let windowStart = resets.addingTimeInterval(-Double(snapshot.windowMinutes) * 60)
        let elapsedAtCapture = snapshot.capturedAt.timeIntervalSince(windowStart)
        guard elapsedAtCapture >= minimumElapsed else { return nil }
        let estimate = used * now.timeIntervalSince(windowStart) / elapsedAtCapture
        // Usage never goes down within a window; cap at full.
        return min(max(estimate, used), 100)
    }

    /// When the current pace crosses 100% before the window resets, the
    /// moment it happens — nil when the pace comfortably outlasts the reset.
    public static func projectedExhaustion(_ snapshot: UsageLimitSnapshot,
                                           now: Date = Date()) -> Date? {
        guard let used = snapshot.usedPercent, used >= minimumPercent,
              let resets = snapshot.resetsAt, resets > now,
              now.timeIntervalSince(snapshot.capturedAt) <= maximumStaleness else { return nil }
        let windowStart = resets.addingTimeInterval(-Double(snapshot.windowMinutes) * 60)
        let elapsedAtCapture = snapshot.capturedAt.timeIntervalSince(windowStart)
        guard elapsedAtCapture >= minimumElapsed else { return nil }
        let exhaustion = windowStart.addingTimeInterval(elapsedAtCapture * 100 / used)
        guard exhaustion < resets, exhaustion > now else { return nil }
        return exhaustion
    }

    /// The other side of the coin: where the current pace lands by the time
    /// the window resets — "on pace for ~62%". nil when the pace can't be
    /// measured yet; values over 100 mean the exhaustion path applies (or a
    /// stale reading already burned past its pace), so callers showing a
    /// reassuring line should ignore them.
    public static func projectedPercentAtReset(_ snapshot: UsageLimitSnapshot,
                                               now: Date = Date()) -> Double? {
        guard let used = snapshot.usedPercent, used >= minimumPercent,
              let resets = snapshot.resetsAt, resets > now,
              now.timeIntervalSince(snapshot.capturedAt) <= maximumStaleness else { return nil }
        let windowStart = resets.addingTimeInterval(-Double(snapshot.windowMinutes) * 60)
        let elapsedAtCapture = snapshot.capturedAt.timeIntervalSince(windowStart)
        guard elapsedAtCapture >= minimumElapsed else { return nil }
        return used * Double(snapshot.windowMinutes) * 60 / elapsedAtCapture
    }
}
