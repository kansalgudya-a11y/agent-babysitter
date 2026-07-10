import Foundation

/// One-time rebuild of the persisted per-day cost history, straight from the
/// transcripts on disk.
///
/// The stored ledger accumulated readings taken before two accuracy fixes:
/// a resumed session double-billed the conversation it copied from its parent,
/// and Claude Code's parallel sub-agents (nested under `<session>/subagents/`)
/// were never discovered at all. Those daily figures are max-merged into
/// UserDefaults, so they can never correct themselves — they have to be
/// recomputed from source.
public enum StatsRecompute {

    public struct Totals: Equatable, Sendable {
        /// day key ("yyyy-MM-dd") → total dollars across every agent.
        public var dayTotals: [String: Double] = [:]
        public var costByAgent: [String: [String: Double]] = [:]
        public var costByProject: [String: [String: Double]] = [:]
        public var costByModel: [String: [String: Double]] = [:]

        public init() {}
        /// Days we could rebuild. Days whose transcripts are gone aren't here,
        /// and the caller must leave those stored values alone.
        public var days: Set<String> { Set(dayTotals.keys) }
    }

    /// Reads EVERY transcript (no age limit) through ONE shared message-id
    /// registry, so a conversation copied into a resumed session is counted
    /// once. Nested sub-agent transcripts are included — that is where a large
    /// share of the spend actually lives.
    ///
    /// Pure I/O + arithmetic: no store, no process matching. Safe to run off
    /// the main thread.
    public static func run(adapters: [any AgentAdapter],
                           now: Date = Date(),
                           timeZone: TimeZone = .current) -> Totals {
        var totals = Totals()
        let claims = MessageIDClaims()

        for adapter in adapters {
            for info in adapter.recentTranscripts(maxAge: .greatestFiniteMagnitude, now: now) {
                guard let url = info.url else { continue }
                let reader = adapter.makeReader(url: url, sessionID: info.sessionID)
                reader.adoptCostClaims(claims)
                try? reader.refresh()

                let project = adapter.projectDirName(forTranscript: url)
                for (day, cost) in reader.dailyCosts where cost.dollars > 0 {
                    let key = LocalDay.key(of: day)
                    totals.dayTotals[key, default: 0] += cost.dollars
                    totals.costByAgent[key, default: [:]][adapter.id, default: 0] += cost.dollars
                    totals.costByProject[key, default: [:]][project, default: 0] += cost.dollars
                }
                for (day, byModel) in reader.dailyDollarsByModel {
                    let key = LocalDay.key(of: day)
                    for (model, dollars) in byModel where dollars > 0 {
                        totals.costByModel[key, default: [:]][model, default: 0] += dollars
                    }
                }
            }
        }
        return totals
    }
}
