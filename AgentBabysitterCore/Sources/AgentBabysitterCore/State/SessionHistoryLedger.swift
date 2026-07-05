import Foundation

/// A finished session, kept so the user can answer "what did I run today?"
/// The store only retains ~24h of live sessions; this is the durable log.
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

    public init(id: String, sessionID: String, agentID: String, agentName: String,
                project: String, cwd: String?, startedAt: Date?, endedAt: Date,
                dollars: Double, totalTokens: Int, transcriptPath: String?) {
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
    }
}

/// Pure record/prune for the session history log; the app persists the array.
public enum SessionHistoryLedger {

    /// Insert or update an entry (keyed by id), newest first, capped at `keep`.
    /// Re-recording the same session (it revived then finished again) refreshes
    /// its row in place rather than duplicating.
    public static func record(_ entry: SessionHistoryEntry,
                              into history: [SessionHistoryEntry],
                              keep: Int = 500) -> [SessionHistoryEntry] {
        var out = history.filter { $0.id != entry.id }
        out.insert(entry, at: 0)
        out.sort { $0.endedAt > $1.endedAt }
        if out.count > keep { out = Array(out.prefix(keep)) }
        return out
    }
}
