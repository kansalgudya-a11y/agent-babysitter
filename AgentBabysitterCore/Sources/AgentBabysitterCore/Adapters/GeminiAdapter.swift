import Foundation

/// Google Gemini — the macOS desktop app and the `gemini` CLI.
///
/// Verified layouts (from real files on disk, 2026-07):
///   - CLI: `~/.gemini/tmp/<project-dir-name>/chats/session-<ts>-<hash>.jsonl`
///     — first line is a session header (sessionId, projectHash, kind),
///     following lines are `$set` message updates. Google currently rejects
///     Code Assist free-tier logins for this client, so parsing beyond
///     activity is deliberately not attempted until real turns can be
///     verified; activity-based states are honest either way.
///   - Desktop app (com.google.GeminiMacOS, native): chat state cached in
///     `~/Library/Caches/com.google.GeminiMacOS/Gemini/<user>/ChatInfo*.store`
///     (SQLite + WAL). One activity-based row per user profile.
public struct GeminiAdapter: AgentAdapter {

    public enum Surface: String, CaseIterable, Sendable {
        case desktop = "gemini"
        case cli = "gemini-cli"

        var displayName: String {
            switch self {
            case .desktop: "Gemini"
            case .cli: "Gemini CLI"
            }
        }

        var bundleIdentifiers: [String] {
            switch self {
            case .desktop: ["com.google.GeminiMacOS"]
            case .cli: []
            }
        }
    }

    public let surface: Surface
    public let transcriptRoot: URL

    public var id: String { surface.rawValue }
    public var displayName: String { surface.displayName }
    public var focusBundleIdentifiers: [String] { surface.bundleIdentifiers }
    public var isActivityBased: Bool { true }

    public init(surface: Surface,
                home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.surface = surface
        switch surface {
        case .cli:
            transcriptRoot = home.appendingPathComponent(".gemini/tmp")
        case .desktop:
            transcriptRoot = home.appendingPathComponent(
                "Library/Caches/com.google.GeminiMacOS/Gemini")
        }
    }

    public static func allSurfaces(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [GeminiAdapter] {
        Surface.allCases.map { GeminiAdapter(surface: $0, home: home) }
    }

    public func recentTranscripts(maxAge: TimeInterval, now: Date) -> [SessionFileInfo] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: transcriptRoot,
                                             includingPropertiesForKeys:
                                                 [.contentModificationDateKey, .isRegularFileKey],
                                             options: [.skipsHiddenFiles]) else { return [] }
        var found: [SessionFileInfo] = []
        for case let url as URL in enumerator {
            guard isCanonicalTranscript(url),
                  let values = try? url.resourceValues(
                      forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modified = newestActivity(for: url,
                                                fallback: values.contentModificationDate),
                  now.timeIntervalSince(modified) <= maxAge else { continue }
            found.append(SessionFileInfo(sessionID: sessionID(forTranscript: url),
                                         projectDirName: projectDirName(forTranscript: url),
                                         lastModified: modified,
                                         url: url))
        }
        return found
    }

    /// SQLite writes land in the WAL long before the main file's mtime moves.
    private func newestActivity(for url: URL, fallback: Date?) -> Date? {
        var newest = fallback
        for suffix in ["-wal", "-shm"] {
            if let date = (try? FileManager.default.attributesOfItem(
                    atPath: url.path + suffix))?[.modificationDate] as? Date {
                newest = max(newest ?? .distantPast, date)
            }
        }
        return newest
    }

    private func isCanonicalTranscript(_ url: URL) -> Bool {
        switch surface {
        case .cli:
            return url.pathExtension == "jsonl"
                && url.lastPathComponent.hasPrefix("session-")
                && url.deletingLastPathComponent().lastPathComponent == "chats"
        case .desktop:
            return url.pathExtension == "store"
                && url.lastPathComponent.hasPrefix("ChatInfo")
        }
    }

    public func isTranscript(path: String) -> Bool {
        guard path.hasPrefix(transcriptRoot.path) else { return false }
        switch surface {
        case .cli:
            return path.hasSuffix(".jsonl") && path.contains("/chats/session-")
        case .desktop:
            return path.contains("ChatInfo")
                && (path.hasSuffix(".store") || path.hasSuffix(".store-wal")
                    || path.hasSuffix(".store-shm"))
        }
    }

    public func canonicalTranscriptURL(forPath path: String) -> URL {
        var path = path
        for suffix in ["-wal", "-shm"] where path.hasSuffix(".store" + suffix) {
            path = String(path.dropLast(suffix.count))
        }
        return URL(fileURLWithPath: path)
    }

    public func sessionID(forTranscript url: URL) -> String {
        switch surface {
        case .cli:
            // session-2026-07-04T23-29-6268f132.jsonl → the unique stem.
            return String(url.deletingPathExtension().lastPathComponent
                .dropFirst("session-".count))
        case .desktop:
            // One row per profile dir (user1, user2…).
            return url.deletingLastPathComponent().lastPathComponent
        }
    }

    public func projectDirName(forTranscript url: URL) -> String {
        switch surface {
        case .cli:
            // tmp/<project-dir-name>/chats/session-*.jsonl
            return url.deletingLastPathComponent()
                .deletingLastPathComponent().lastPathComponent
        case .desktop:
            return "Gemini chat"
        }
    }

    /// Never called — activity-based — but the protocol requires it.
    public func parseLine(_ line: Data) -> LineParseResult {
        .malformed
    }

    public func makeReader(url: URL) -> any SessionReading {
        // The desktop chat streams store writes while replying, then goes
        // silent - measured: zero idle writes - so 25s of quiet is a safe,
        // much snappier "done" than the default minute.
        FileActivityReader(url: url,
                           sessionID: sessionID(forTranscript: url),
                           entrypoint: displayName,
                           idleCutoff: surface == .desktop ? 25 : 60)
    }

    /// No cwd is recoverable from these processes; pair newest sessions
    /// with processes positionally, exactly like the Antigravity surfaces.
    public func match(processes: [RunningProcess],
                      candidates: [SessionMatchCandidate]) -> [String: Int32] {
        let recent = candidates.sorted { $0.lastModified > $1.lastModified }
        var match: [String: Int32] = [:]
        for (candidate, process) in zip(recent, processes.sorted { $0.pid < $1.pid }) {
            match[candidate.sessionID] = process.pid
        }
        return match
    }

    public func agentPIDs(psComm: String, psArgs: String) -> [Int32] {
        var pids: [Int32] = []
        let source = surface == .cli ? psArgs : psComm
        for rawLine in source.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let space = line.firstIndex(where: { $0 == " " || $0 == "\t" }),
                  let pid = Int32(line[..<space]) else { continue }
            let command = line[line.index(after: space)...]
                .trimmingCharacters(in: .whitespaces)
            switch surface {
            case .desktop:
                // Exact main binary; the always-running login-item launcher
                // (…/Helpers/GeminiAppLauncher.app/…) must NOT count as open.
                if command.hasSuffix("/Gemini.app/Contents/MacOS/Gemini") {
                    pids.append(pid)
                }
            case .cli:
                // Node-hosted: match the CLI entry path or package anywhere
                // in the arguments.
                if command.contains("@google/gemini-cli")
                    || command.contains("/bin/gemini") {
                    pids.append(pid)
                }
            }
        }
        return pids.sorted()
    }
}
