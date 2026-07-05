import Foundation

/// Detects when we've lost the ability to read an installed agent — e.g. the
/// vendor changed its on-disk format, so its data files are churning but we
/// parse zero sessions from them. Pure so it's testable; the app supplies the
/// three observations.
public enum AgentHealth {

    public enum Status: Equatable, Sendable {
        case ok
        /// The app is running and writing, but nothing parses — likely a
        /// format change on their side that ours can't read.
        case cannotRead
    }

    /// `running`: a live process for the agent. `dataRecentlyModified`: its
    /// data root (or a child) changed within the recent window.
    /// `sessionsParsed`: how many sessions we successfully read.
    ///
    /// Only flags when all three point the same way — a running app that's
    /// actively writing yet yields no readable sessions. An idle-but-open app
    /// (no recent writes) or a quiet install never trips it, avoiding false
    /// alarms.
    public static func status(running: Bool,
                              dataRecentlyModified: Bool,
                              sessionsParsed: Int) -> Status {
        (running && dataRecentlyModified && sessionsParsed == 0) ? .cannotRead : .ok
    }
}
