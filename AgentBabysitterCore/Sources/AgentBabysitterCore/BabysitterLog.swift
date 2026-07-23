import os
import OSLog

/// Central loggers — view with `log stream --predicate 'subsystem ==
/// "app.agentbabysitter"'` or Console.app. Session ids and file paths are
/// logged public (they're the user's own data on their own machine);
/// transcript content is never logged.
///
/// Note on persistence: only `.notice`/`.error`/`.fault` are written to the
/// unified-log store and survive to be read back by `recentLines(...)` below;
/// `.debug`/`.info` live in an in-memory ring that is gone by the time anyone
/// asks. So a decision point that "Copy diagnostics" must be able to explain
/// after the fact (adapter detected/rejected + reason, live-usage failure
/// reason, hook install result, first event received) has to be logged at
/// `.notice` or higher.
public enum BabysitterLog {
    /// The subsystem every logger below shares — also the read-back filter.
    public static let subsystem = "app.agentbabysitter"

    public static let store = Logger(subsystem: subsystem, category: "store")
    public static let watcher = Logger(subsystem: subsystem, category: "watcher")
    public static let process = Logger(subsystem: subsystem, category: "process")
    public static let hooks = Logger(subsystem: subsystem, category: "hooks")

    /// The most recent persisted log lines from THIS process (newest last), for
    /// "Copy diagnostics" to embed so a "shows nothing for my agent" report
    /// arrives with the decision trail attached instead of a blank.
    ///
    /// Reads only our own process's entries (`.currentProcessIdentifier` scope,
    /// which needs no logging entitlement) and only our subsystem. Best-effort:
    /// returns [] if the store is unavailable. Remember only `.notice`+ persist
    /// (see the type note) — `.debug`/`.info` never appear here.
    public static func recentLines(limit: Int = 200, sinceMinutes: Int = 60) -> [String] {
        guard let logStore = try? OSLogStore(scope: .currentProcessIdentifier) else { return [] }
        let start = logStore.position(date: Date(timeIntervalSinceNow: Double(-sinceMinutes) * 60))
        guard let entries = try? logStore.getEntries(
            at: start,
            matching: NSPredicate(format: "subsystem == %@", subsystem)) else { return [] }
        let stamp = ISO8601DateFormatter()
        var lines: [String] = []
        for case let entry as OSLogEntryLog in entries {
            lines.append("\(stamp.string(from: entry.date)) [\(entry.category)] \(entry.composedMessage)")
        }
        return Array(lines.suffix(max(0, limit)))
    }
}
