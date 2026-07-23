import Foundation
import SQLite3

/// Google Antigravity (desktop app, IDE, and `agy` CLI). Conversations live
/// at `~/.gemini/<surface>/conversations/<uuid>.db` — SQLite with protobuf
/// step payloads and no public schema, so this adapter is deliberately
/// activity-based: Working while the conversation DB is being written, Done
/// when quiet, Ended when the surface's process exits. It never claims
/// Waiting/Stalled and reports no usage (both are locked inside protobuf).
///
/// One adapter instance per surface; each has its own root and process
/// identity.
public struct AntigravityAdapter: AgentAdapter {

    public enum Surface: String, CaseIterable, Sendable {
        case desktop = "antigravity"
        case ide = "antigravity-ide"
        case cli = "antigravity-cli"

        var displayName: String {
            switch self {
            case .desktop: "Antigravity"
            case .ide: "Antigravity IDE"
            case .cli: "Antigravity CLI"
            }
        }

        var bundleIdentifiers: [String] {
            switch self {
            case .desktop: ["com.google.antigravity"]
            case .ide: ["com.google.antigravity-ide"]
            case .cli: []
            }
        }

        /// Whether a `ps comm=` value is this surface's session process.
        /// App surfaces match the full main-binary path (avoiding the dozens
        /// of Electron helpers); the CLI matches by basename — Go reports it
        /// as a bare "agy" with no path.
        func matchesProcess(command: String) -> Bool {
            switch self {
            case .desktop:
                return command.hasSuffix("/Antigravity.app/Contents/MacOS/Antigravity")
            case .ide:
                return command.hasSuffix("/Antigravity IDE.app/Contents/MacOS/Electron")
            case .cli:
                return command == "agy" || command.hasSuffix("/agy")
            }
        }
    }

    public let surface: Surface
    public let transcriptRoot: URL

    public var id: String { surface.rawValue }
    public var displayName: String { surface.displayName }
    public var focusBundleIdentifiers: [String] { surface.bundleIdentifiers }
    public var cliExecutableNames: [String] { surface == .cli ? ["agy"] : [] }

    public init(surface: Surface,
                geminiRoot: URL = PlatformPaths.homeDirectory(".gemini")) {
        self.surface = surface
        self.transcriptRoot = geminiRoot
            .appendingPathComponent(surface.rawValue)
            .appendingPathComponent("conversations")
    }

    public static func allSurfaces(
        geminiRoot: URL = PlatformPaths.homeDirectory(".gemini")
    ) -> [AntigravityAdapter] {
        Surface.allCases.map { AntigravityAdapter(surface: $0, geminiRoot: geminiRoot) }
    }

    public func recentTranscripts(maxAge: TimeInterval, now: Date) -> [SessionFileInfo] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(
            at: transcriptRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        var found: [SessionFileInfo] = []
        for file in files where file.pathExtension == "db" {
            guard let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate,
                  now.timeIntervalSince(modified) <= maxAge else { continue }
            found.append(SessionFileInfo(sessionID: sessionID(forTranscript: file),
                                         projectDirName: projectDirName(forTranscript: file),
                                         lastModified: modified,
                                         url: file))
        }
        return found
    }

    public func isTranscript(path: String) -> Bool {
        path.hasPrefix(transcriptRoot.path)
            && (path.hasSuffix(".db") || path.hasSuffix(".db-wal") || path.hasSuffix(".db-shm"))
    }

    public func canonicalTranscriptURL(forPath path: String) -> URL {
        var path = path
        for suffix in ["-wal", "-shm"] where path.hasSuffix(".db" + suffix) {
            path = String(path.dropLast(suffix.count))
        }
        return URL(fileURLWithPath: path)
    }

    public func sessionID(forTranscript url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    /// Never called — this adapter reads activity, not lines — but the
    /// protocol requires it. Any content is opaque.
    public func parseLine(_ line: Data) -> LineParseResult {
        .malformed
    }

    public func makeReader(url: URL) -> any SessionReading {
        FileActivityReader(url: url,
                           sessionID: sessionID(forTranscript: url),
                           entrypoint: displayName)
    }

    public func projectDirName(forTranscript url: URL) -> String {
        let id = sessionID(forTranscript: url)
        // Prefer the readable title Antigravity itself recorded for the
        // conversation; the hex stub is only the last resort (a brand-new
        // conversation has no summary yet). The agent badge already names the
        // surface, and there is no readable cwd to fall back on.
        if let label = conversationLabel(forSessionID: id) { return label }
        return "#\(id.prefix(8))"
    }

    /// Root of the shared `~/.gemini` tree, recovered from `transcriptRoot`
    /// (which `init` builds as `<geminiRoot>/<surface>/conversations`).
    private var geminiRoot: URL {
        transcriptRoot.deletingLastPathComponent().deletingLastPathComponent()
    }

    /// A human-readable label for a conversation UUID, read from Antigravity's
    /// own summary store at `<geminiRoot>/antigravity-cli/conversation_summaries.db`.
    /// Verified against a live install: that one SQLite table carries a row per
    /// conversation for BOTH the desktop and CLI surfaces (its `app_data_dir`
    /// column is "antigravity" or "antigravity-cli"), each with a `title`
    /// (usually empty) and a model-written `preview` (e.g. "Skipping Permissions
    /// Security Flag"). We prefer `title`, then `preview`.
    ///
    /// Best-effort: any failure — store absent (the CLI was never installed),
    /// no row yet (a live conversation before Antigravity has summarized it), or
    /// a read error — returns nil and the caller keeps the "#<hex>" stub.
    /// IDE-surface conversations are not in this store (their titles live only
    /// in the shared `state.vscdb` protobuf) and also fall back to the stub.
    func conversationLabel(forSessionID id: String) -> String? {
        Self.summaryLabel(
            summariesDB: geminiRoot
                .appendingPathComponent("antigravity-cli")
                .appendingPathComponent("conversation_summaries.db"),
            conversationID: id)
    }

    /// Extraction core (injected DB path so tests/probes can point it at a
    /// fixture). Opens the store read-only — never creating or writing it.
    static func summaryLabel(summariesDB db: URL, conversationID id: String) -> String? {
        guard FileManager.default.fileExists(atPath: db.path) else { return nil }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(db.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(handle); return nil
        }
        defer { sqlite3_close(handle) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            handle,
            "SELECT title, preview FROM conversation_summaries WHERE conversation_id = ? LIMIT 1",
            -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        // SQLITE_TRANSIENT — SQLite copies the id; mirrors AntigravityStateReader.
        sqlite3_bind_text(stmt, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        func column(_ i: Int32) -> String {
            sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? ""
        }
        for label in [column(0), column(1)] {
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    public var isActivityBased: Bool { true }

    /// Shared account-state file all surfaces sync to.
    public static let defaultStateDBURL = PlatformPaths.applicationSupport("Antigravity IDE/User/globalStorage/state.vscdb")

    /// Every surface resolves the SAME shared file, which is what lets the
    /// store parse it once and fan the one reading out to all three ids.
    public func usageSourceFile() -> URL? { Self.defaultStateDBURL }

    /// Protocol witness for the injectable reader below. A method with a
    /// defaulted parameter cannot witness a zero-parameter requirement, so the
    /// injection point keeps its explicit argument and this forwards the live
    /// path — no default value on both, which would be an ambiguous overload.
    public func usageFromDisk() -> UsageLimitSnapshot? {
        usageFromDisk(appSupport: PlatformPaths.applicationSupport)
    }

    /// Account status from the Antigravity IDE's stored state: plan tier
    /// ("Google AI Pro") plus the five-hour quota used % and reset time that
    /// the app's own Model Quota page displays. `capturedAt` is the state
    /// file's mtime so staleness is honest. Returns nil when the IDE isn't
    /// installed or the state can't be read.
    public func usageFromDisk(appSupport: URL) -> UsageLimitSnapshot? {
        let db = appSupport.path == PlatformPaths.applicationSupport.path
            ? Self.defaultStateDBURL
            : appSupport.appendingPathComponent("Antigravity IDE/User/globalStorage/state.vscdb")
        guard let data = try? Data(contentsOf: db),
              let status = AntigravityStateReader.accountStatus(inStateDB: data) else {
            return nil
        }
        let mtime = (try? FileManager.default.attributesOfItem(atPath: db.path))
            .flatMap { $0[.modificationDate] as? Date } ?? Date()
        return UsageLimitSnapshot(usedPercent: status.fiveHourUsedPercent,
                                  windowMinutes: 300,
                                  resetsAt: status.fiveHourResetsAt,
                                  capturedAt: mtime,
                                  plan: status.plan)
    }

    public func agentPIDs(psComm: String, psArgs: String) -> [Int32] {
        var pids: [Int32] = []
        for rawLine in psComm.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let space = line.firstIndex(where: { $0 == " " || $0 == "\t" }),
                  let pid = Int32(line[..<space]) else { continue }
            let command = line[line.index(after: space)...]
                .trimmingCharacters(in: .whitespaces)
            if surface.matchesProcess(command: command) {
                pids.append(pid)
            }
        }
        return pids.sorted()
    }

    /// Conversations don't record a cwd we can read, so match most recently
    /// active sessions to this surface's processes, newest first.
    public func match(processes: [RunningProcess],
                      candidates: [SessionMatchCandidate]) -> [String: Int32] {
        let recent = candidates.sorted { $0.lastModified > $1.lastModified }
        var match: [String: Int32] = [:]
        for (candidate, process) in zip(recent, processes.sorted { $0.pid < $1.pid }) {
            match[candidate.sessionID] = process.pid
        }
        return match
    }
}
