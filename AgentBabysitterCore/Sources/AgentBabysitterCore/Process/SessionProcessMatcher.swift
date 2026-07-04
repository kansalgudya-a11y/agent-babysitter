import Foundation

/// A transcript file on disk, described by what the matcher needs.
public struct SessionFileInfo: Equatable, Sendable {
    public let sessionID: String
    /// Name of the directory holding this transcript (the munged cwd for
    /// Claude Code; a date component for Codex — only meaningful to the
    /// adapter that produced it).
    public let projectDirName: String
    public let lastModified: Date
    /// Transcript file location (filled by launch scans).
    public let url: URL?

    public init(sessionID: String, projectDirName: String, lastModified: Date,
                url: URL? = nil) {
        self.sessionID = sessionID
        self.projectDirName = projectDirName
        self.lastModified = lastModified
        self.url = url
    }
}

public enum SessionProcessMatcher {

    /// Claude Code's project-directory munging: every character outside
    /// [A-Za-z0-9] becomes "-". Verified against real dirs, e.g.
    /// `/Users/x/.openclaw/workspace` → `-Users-x--openclaw-workspace`.
    public static func projectDirName(forCWD cwd: String) -> String {
        String(cwd.map { char in
            char.isASCII && (char.isLetter || char.isNumber) ? char : "-"
        })
    }

    /// Pair live processes with transcripts: a process belongs to the project
    /// dir matching its munged cwd; within a dir, the most recently modified
    /// transcript claims a process first. Sessions left unpaired have no live
    /// process (→ Ended); processes left unpaired have no transcript yet.
    public static func match(processes: [RunningProcess],
                             sessions: [SessionFileInfo]) -> [String: Int32] {
        var sessionsByDir: [String: [SessionFileInfo]] = Dictionary(grouping: sessions,
                                                                    by: \.projectDirName)
        for key in sessionsByDir.keys {
            sessionsByDir[key]!.sort { $0.lastModified > $1.lastModified }
        }

        let processesByDir = Dictionary(grouping: processes) { projectDirName(forCWD: $0.cwd) }

        var match: [String: Int32] = [:]
        for (dir, dirProcesses) in processesByDir {
            guard let dirSessions = sessionsByDir[dir] else { continue }
            for (session, process) in zip(dirSessions, dirProcesses.sorted { $0.pid < $1.pid }) {
                match[session.sessionID] = process.pid
            }
        }
        return match
    }
}
