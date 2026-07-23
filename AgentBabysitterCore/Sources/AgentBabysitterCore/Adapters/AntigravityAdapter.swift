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
        //
        // HONESTY FLAG (documented, not fixed here — belongs to SessionStore,
        // outside this file's lane): the store captures this value once at
        // track-time. So a conversation first seen before Antigravity has
        // written its summary keeps the "#<hex>" stub for the life of that
        // tracked session, even though a later re-read here would now resolve a
        // title. A live upgrade would need SessionStore to re-resolve the label
        // per tick (memoized) rather than freeze the track-time SessionFileInfo.
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
    /// Verified against a live install (copied read-only, 7 rows): that one
    /// SQLite table carries a row per conversation for BOTH the desktop and CLI
    /// surfaces (its `app_data_dir` column is "antigravity" or "antigravity-cli"),
    /// keyed by `conversation_id`, which is exactly the transcript filename UUID
    /// (all 7 rows joined to a `<uuid>.db` on disk). Each row has a `title`
    /// (empty on every observed row), a model-written `preview` (e.g. "Skipping
    /// Permissions Security Flag"), plus `workspace_uris`/`project_id` context.
    /// We prefer `title`, then `preview`, and prepend a workspace/project name
    /// when one is genuinely present (see `composeLabel`).
    ///
    /// Best-effort: any failure — store absent (the CLI was never installed),
    /// no row yet (a live conversation before Antigravity has summarized it), or
    /// a read error — returns nil and the caller keeps the "#<hex>" stub.
    /// (Verified: 2 of the 8 CLI transcripts on disk had no summary row yet and
    /// so correctly fall back to the stub.) IDE-surface conversations are not in
    /// this store (their titles live only in the shared `state.vscdb` protobuf)
    /// and also fall back to the stub — both observed IDE transcripts were absent.
    func conversationLabel(forSessionID id: String) -> String? {
        Self.summaryLabel(
            summariesDB: geminiRoot
                .appendingPathComponent("antigravity-cli")
                .appendingPathComponent("conversation_summaries.db"),
            conversationID: id)
    }

    /// Extraction core (injected DB path so tests/probes can point it at a
    /// fixture). Opens the store read-only — never creating or writing it.
    ///
    /// The enriched read (title/preview + workspace/project context) is tried
    /// first; if this build's store predates the `workspace_uris`/`project_id`
    /// columns, `prepare` fails and we fall back to the minimal title/preview
    /// read so a readable label is never lost to a schema mismatch.
    static func summaryLabel(summariesDB db: URL, conversationID id: String) -> String? {
        guard FileManager.default.fileExists(atPath: db.path) else { return nil }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(db.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(handle); return nil
        }
        defer { sqlite3_close(handle) }
        if let label = queryLabel(
            handle,
            "SELECT title, preview, workspace_uris, project_id FROM conversation_summaries WHERE conversation_id = ? LIMIT 1",
            id: id, columns: 4) {
            return label
        }
        return queryLabel(
            handle,
            "SELECT title, preview FROM conversation_summaries WHERE conversation_id = ? LIMIT 1",
            id: id, columns: 2)
    }

    /// Runs one label query against an already-open read-only handle and folds
    /// the row through `composeLabel`. Returns nil on a prepare failure (older
    /// schema — the caller retries with fewer columns), an absent row, or an
    /// all-empty label. `columns` bounds how many columns the SQL actually
    /// selected so the 2-column fallback reads no out-of-range indices.
    private static func queryLabel(_ handle: OpaquePointer?, _ sql: String,
                                   id: String, columns: Int32) -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        // SQLITE_TRANSIENT — SQLite copies the id; mirrors AntigravityStateReader.
        sqlite3_bind_text(stmt, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        func column(_ i: Int32) -> String {
            i < columns ? (sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "") : ""
        }
        return composeLabel(title: column(0), preview: column(1),
                            workspaceURIs: column(2), projectID: column(3))
    }

    /// `project_id` values Antigravity writes when a conversation has no real
    /// workspace — internal placeholders, never a name worth showing. Verified
    /// as the ONLY `project_id` values across all 7 live rows, so on this
    /// machine enrichment adds nothing and the label stays the bare preview
    /// (behaviour-preserving); the enrichment fires only once a real workspace
    /// or project appears.
    static let placeholderProjectIDs: Set<String> = ["outside-of-project", "default-cli-project"]

    /// Fold a summary row into a display label. Pure — the probe/tests exercise
    /// it directly with the real column values. `core` is the first non-empty of
    /// [title, preview]; a workspace/project context is prepended as "ctx · core"
    /// when one is genuinely present and differs from the core. Returns nil when
    /// the row carries nothing usable, so the caller keeps the "#<hex>" stub.
    static func composeLabel(title: String, preview: String,
                             workspaceURIs: String, projectID: String) -> String? {
        let core = [title, preview]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        let context = projectContext(workspaceURIs: workspaceURIs, projectID: projectID)
        switch (context, core) {
        case let (ctx?, core?) where ctx != core: return "\(ctx) · \(core)"
        case let (_, core?):                       return core
        case let (ctx?, nil):                      return ctx
        default:                                   return nil
        }
    }

    /// A human workspace/project name for the row, or nil. Prefers a real
    /// filesystem name parsed from `workspace_uris`; otherwise a non-placeholder
    /// `project_id`. Both were empty / placeholder on every probed row, so this
    /// returns nil there — it never manufactures a name it cannot justify.
    static func projectContext(workspaceURIs: String, projectID: String) -> String? {
        if let workspace = workspaceBasename(fromURIs: workspaceURIs) { return workspace }
        let pid = projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pid.isEmpty && !placeholderProjectIDs.contains(pid) { return pid }
        return nil
    }

    /// Extract a folder name from `workspace_uris` — the container of workspace
    /// roots (JSON array / delimited list / single value). We pull a name only
    /// from an unambiguous `file://` URI or a bare absolute path (the first one
    /// found); anything else returns nil rather than guess a label. NOTE:
    /// `workspace_uris` was an empty string on all 7 probed rows, so this
    /// parsing is standard-`file://`-format logic that is verified for the
    /// empty/nil path but NOT confirmed against a populated live value.
    static func workspaceBasename(fromURIs raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        func token(after start: String.Index) -> String {
            // A path token ends at the next character that cannot sit inside a
            // list-encoded URI (quotes, commas, brackets, whitespace).
            String(trimmed[start...].prefix { ch in
                ch != "\"" && ch != "'" && ch != "," && ch != "]"
                    && ch != " " && ch != "\n" && ch != "\t" && ch != "\r"
            })
        }
        var pathPortion: String?
        if let range = trimmed.range(of: "file://") {
            pathPortion = token(after: range.upperBound)
        } else if trimmed.hasPrefix("/") {
            pathPortion = token(after: trimmed.startIndex)
        }
        guard var path = pathPortion, !path.isEmpty else { return nil }
        path = path.removingPercentEncoding ?? path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        let name = (path as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (name.isEmpty || name == "/") ? nil : name
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
