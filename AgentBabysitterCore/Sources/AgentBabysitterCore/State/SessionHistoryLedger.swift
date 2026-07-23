import Foundation

/// A finished session, kept so the user can answer "what did I run today?"
/// The live store only retains ~24h of active sessions; this is the durable
/// log. Retention is by AGE (the last `SessionHistoryLedger.defaultMaxAgeDays`
/// of finished sessions), not a fixed entry count — see `record`.
public struct SessionHistoryEntry: Equatable, Sendable, Codable, Identifiable {
    public let id: String            // agentID/sessionID — stable, dedupes
    public let sessionID: String
    public let agentID: String
    public let agentName: String
    public let project: String
    public let cwd: String?
    public let startedAt: Date?
    public let endedAt: Date
    public let dollars: Double
    public let totalTokens: Int
    public let transcriptPath: String?
    /// The user's last prompt ("what it was working on"). Optional so
    /// history files written before this field decode unchanged.
    public var title: String?
    /// The token split, persisted so the four-way breakdown survives after the
    /// agent's transcripts are pruned. Optional: entries written before this
    /// existed decode with nil, and fall back to the totalTokens-only figure.
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cacheReadTokens: Int?
    public var cacheWriteTokens: Int?
    /// True for activity-based agents (Cursor/Gemini/…) that record no tokens on
    /// disk — the view shows "no token data" instead of a false "—"/"0 tok".
    /// Optional so entries written before this field decode unchanged.
    public var isActivityBased: Bool?

    public init(id: String, sessionID: String, agentID: String, agentName: String,
                project: String, cwd: String?, startedAt: Date?, endedAt: Date,
                dollars: Double, totalTokens: Int, transcriptPath: String?,
                title: String? = nil, inputTokens: Int? = nil, outputTokens: Int? = nil,
                cacheReadTokens: Int? = nil, cacheWriteTokens: Int? = nil,
                isActivityBased: Bool? = nil) {
        self.id = id
        self.sessionID = sessionID
        self.agentID = agentID
        self.agentName = agentName
        self.project = project
        self.cwd = cwd
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.dollars = dollars
        self.totalTokens = totalTokens
        self.transcriptPath = transcriptPath
        self.title = title
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.isActivityBased = isActivityBased
    }

    /// Reconstructs a `SessionCost` for display. Legacy entries (no persisted
    /// split) yield a cost carrying only `totalTokens`, so `hasTokens` is false
    /// and the view falls back to the single legacy figure rather than a bogus
    /// all-zero breakdown.
    public var cost: SessionCost {
        SessionCost(dollars: dollars, totalTokens: totalTokens,
                    inputTokens: inputTokens ?? 0, outputTokens: outputTokens ?? 0,
                    cacheReadTokens: cacheReadTokens ?? 0,
                    cacheWriteTokens: cacheWriteTokens ?? 0)
    }
}

/// Pure record/prune for the session history log; the app persists the array.
public enum SessionHistoryLedger {

    /// Default retention window, in days. Sessions whose `endedAt` is within this
    /// many days of `now` are kept; older ones age out. This replaces the old
    /// fixed 500-entry cap: on a busy machine 500 entries was only ~7 days (a
    /// verified audit finding), so one heavy day silently evicted the entire
    /// back-history and "what did I run last month?" became unanswerable.
    /// Age-capping keeps a predictable window no matter how many sessions run.
    public static let defaultMaxAgeDays: Double = 90

    /// Absolute ceiling on array length — a safety backstop, NOT the retention
    /// policy (age is). It only bounds the in-memory / on-disk JSON array against
    /// pathological growth, and is set far above what the age window holds for a
    /// normal user, so in practice age is always the limit that bites first.
    public static let defaultKeep: Int = 10_000

    /// Insert or update an entry (keyed by id), newest first.
    ///
    /// Retention is by AGE: entries whose `endedAt` is older than `maxAgeDays`
    /// (measured from `now`) are dropped. `keep` is only a high absolute backstop
    /// on the array length, not the primary limit. The just-recorded `entry`
    /// always survives (its `endedAt` is ~`now`).
    ///
    /// Re-recording the same session (it revived then finished again) refreshes
    /// its row in place rather than duplicating.
    public static func record(_ entry: SessionHistoryEntry,
                              into history: [SessionHistoryEntry],
                              maxAgeDays: Double = defaultMaxAgeDays,
                              keep: Int = defaultKeep,
                              now: Date = Date()) -> [SessionHistoryEntry] {
        var out = history.filter { $0.id != entry.id }
        out.insert(entry, at: 0)
        out.sort { $0.endedAt > $1.endedAt }
        // Primary cap: drop sessions finished more than maxAgeDays ago. The
        // just-recorded entry is never dropped here (guarantees record() never
        // discards its own argument), though in-app that is moot — AppModel
        // always records with endedAt == Date(), i.e. inside the window. A
        // non-positive maxAgeDays disables age capping (backstop only).
        if maxAgeDays > 0 {
            let cutoff = now.addingTimeInterval(-maxAgeDays * 24 * 3600)
            out.removeAll { $0.endedAt < cutoff && $0.id != entry.id }
        }
        // Safety backstop only: bound the array length. A non-positive keep
        // disables it. This is deliberately NOT how normal history is trimmed.
        if keep > 0, out.count > keep { out = Array(out.prefix(keep)) }
        return out
    }
}
