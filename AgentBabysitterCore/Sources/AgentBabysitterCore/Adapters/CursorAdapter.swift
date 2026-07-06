import Foundation
import SQLite3

/// Cursor's desktop app. Agent ("composer") sessions live as
/// `composerData:<uuid>` JSON records in
/// `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`
/// (SQLite + WAL, table cursorDiskKV) — layout verified against a real
/// install (schema _v16, 2026-07). Records carry `createdAt` /
/// `lastUpdatedAt` (ms epochs), a `status` string, and a `name`; freshly
/// created empty composers have no `lastUpdatedAt` and are not sessions.
///
/// The CLI (`cursor-agent`) surface is intentionally absent until its
/// session layout can be captured from a logged-in run.
public struct CursorAdapter: AgentAdapter {

    public let id = "cursor"
    public let displayName = "Cursor"
    public let transcriptRoot: URL
    public var focusBundleIdentifiers: [String] { ["com.todesktop.230313mzl4w4u92"] }
    public var isActivityBased: Bool { true }
    /// Composer sessions ARE parsed from the db, so a running Cursor whose db
    /// churns while zero composers parse is real drift — keep it checked.
    public var sessionsAreParsed: Bool { true }
    public var multiSessionFiles: Bool { true }

    public init(appSupport: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support")) {
        transcriptRoot = appSupport.appendingPathComponent("Cursor/User/globalStorage")
    }

    public var stateDBURL: URL { transcriptRoot.appendingPathComponent("state.vscdb") }

    /// Plan tier from Cursor's own state (`cursorAuth/stripeMembershipType`,
    /// verified on a real install). That's ALL Cursor persists about usage —
    /// no percentages exist locally; the real numbers live behind cursor.com
    /// with the session token, which the app layer's opt-in live fetch uses.
    public func usageFromDisk() -> UsageLimitSnapshot? {
        guard let membership = Self.itemTableValue(key: "cursorAuth/stripeMembershipType",
                                                   inStateDBAt: stateDBURL) else { return nil }
        let mtime = (try? FileManager.default.attributesOfItem(atPath: stateDBURL.path))
            .flatMap { $0[.modificationDate] as? Date } ?? Date()
        return UsageLimitSnapshot(usedPercent: nil, windowMinutes: 300, resetsAt: nil,
                                  capturedAt: mtime, plan: membership.capitalized)
    }

    /// The session token the app layer needs for the opt-in live fetch.
    public func storedAccessToken() -> String? {
        Self.itemTableValue(key: "cursorAuth/accessToken", inStateDBAt: stateDBURL)
    }

    public struct Composer: Equatable {
        public let id: String
        public let name: String?
        public let lastUpdatedAt: Date
        public let status: String
    }

    public func recentTranscripts(maxAge: TimeInterval, now: Date) -> [SessionFileInfo] {
        Self.composers(inStateDBAt: stateDBURL)
            .filter { now.timeIntervalSince($0.lastUpdatedAt) <= maxAge }
            .map { composer in
                SessionFileInfo(sessionID: composer.id,
                                projectDirName: composer.name ?? "#\(composer.id.prefix(8))",
                                lastModified: composer.lastUpdatedAt,
                                url: stateDBURL)
            }
    }

    /// All composers that have actually been used (lastUpdatedAt present).
    /// Every composer's reader shares one db, so the parse is memoized by the
    /// db's mtime: without it, N tracked composers would each re-copy the
    /// multi-MB SQLite file on every change (a copy-storm during active use).
    static func composers(inStateDBAt url: URL) -> [Composer] {
        ComposerCache.shared.composers(forDBAt: url) { parseComposers(inStateDBAt: url) }
    }

    private static func parseComposers(inStateDBAt url: URL) -> [Composer] {
        guard let rows = copiedQuery(storeAt: url) else { return [] }
        var composers: [Composer] = []
        for (key, json) in rows {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8)))
                    as? [String: Any],
                  let composerID = object["composerId"] as? String,
                  key == "composerData:\(composerID)",
                  let updatedMS = object["lastUpdatedAt"] as? Double else { continue }
            composers.append(Composer(
                id: composerID,
                name: (object["name"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                lastUpdatedAt: Date(timeIntervalSince1970: updatedMS / 1000),
                status: object["status"] as? String ?? "none"))
        }
        return composers
    }

    private static func copiedQuery(storeAt url: URL) -> [(String, String)]? {
        withCopiedDB(at: url) { db in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db,
                "SELECT key, value FROM cursorDiskKV WHERE key LIKE 'composerData:%'",
                -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            var rows: [(String, String)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let k = sqlite3_column_text(stmt, 0),
                      let v = sqlite3_column_text(stmt, 1) else { continue }
                rows.append((String(cString: k), String(cString: v)))
            }
            return rows
        }
    }

    static func itemTableValue(key: String, inStateDBAt url: URL) -> String? {
        withCopiedDB(at: url) { db in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = ?",
                                     -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, key, -1,
                              unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            guard sqlite3_step(stmt) == SQLITE_ROW,
                  let value = sqlite3_column_text(stmt, 0) else { return nil }
            return String(cString: value)
        }
    }

    /// Cursor holds the db + WAL open; copy the trio and read the copy.
    private static func withCopiedDB<T>(at url: URL,
                                        _ body: (OpaquePointer) -> T?) -> T? {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory
            .appendingPathComponent("cursor-state-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmpDir) }
        do {
            try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            let base = tmpDir.appendingPathComponent("db.vscdb")
            try fm.copyItem(at: url, to: base)
            for suffix in ["-wal", "-shm"] where fm.fileExists(atPath: url.path + suffix) {
                try fm.copyItem(atPath: url.path + suffix, toPath: base.path + suffix)
            }
            var db: OpaquePointer?
            guard sqlite3_open_v2(base.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
                sqlite3_close(db); return nil
            }
            defer { sqlite3_close(db) }
            return db.flatMap(body)
        } catch {
            return nil
        }
    }

    public func isTranscript(path: String) -> Bool {
        path.hasPrefix(transcriptRoot.path) && path.contains("state.vscdb")
    }

    public func canonicalTranscriptURL(forPath path: String) -> URL {
        var path = path
        for suffix in ["-wal", "-shm"] where path.hasSuffix(".vscdb" + suffix) {
            path = String(path.dropLast(suffix.count))
        }
        return URL(fileURLWithPath: path)
    }

    public func sessionID(forTranscript url: URL) -> String {
        // Sessions are rows inside one db; identity comes from
        // recentTranscripts. For a bare file path, use the db itself.
        "cursor-state"
    }

    public func parseLine(_ line: Data) -> LineParseResult { .malformed }

    public func makeReader(url: URL) -> any SessionReading {
        // Placeholder for protocol completeness; the store uses
        // makeReader(url:sessionID:) below via SessionFileInfo identity.
        CursorComposerReader(storeURL: url, composerID: "cursor-state")
    }

    public func makeReader(url: URL, sessionID: String) -> any SessionReading {
        CursorComposerReader(storeURL: url, composerID: sessionID)
    }

    public func projectDirName(forTranscript url: URL) -> String { "Cursor" }

    public func match(processes: [RunningProcess],
                      candidates: [SessionMatchCandidate]) -> [String: Int32] {
        let recent = candidates.sorted { $0.lastModified > $1.lastModified }
        var match: [String: Int32] = [:]
        for (candidate, process) in zip(recent, processes.sorted { $0.pid < $1.pid }) {
            match[candidate.sessionID] = process.pid
        }
        // One Cursor process hosts every composer — share the first pid.
        if let pid = processes.sorted(by: { $0.pid < $1.pid }).first?.pid {
            for candidate in candidates where match[candidate.sessionID] == nil {
                match[candidate.sessionID] = pid
            }
        }
        return match
    }

    public func agentPIDs(psComm: String, psArgs: String) -> [Int32] {
        var pids: [Int32] = []
        for rawLine in psComm.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let space = line.firstIndex(where: { $0 == " " || $0 == "\t" }),
                  let pid = Int32(line[..<space]) else { continue }
            let command = line[line.index(after: space)...]
                .trimmingCharacters(in: .whitespaces)
            if command.hasSuffix("/Cursor.app/Contents/MacOS/Cursor") {
                pids.append(pid)
            }
        }
        return pids.sorted()
    }
}

/// Reads one composer's record per refresh: real timestamps from the JSON,
/// plus a status hint. Unknown-active statuses count as working; the
/// timestamps bound it either way.
public final class CursorComposerReader: SessionReading {

    public let url: URL
    public let sessionID: String
    public let lastKnownCWD: String? = nil
    public let lastKnownEntrypoint: String? = "Cursor"
    public let isSidechain = false
    public let isUnreadable = false
    public let hasPendingToolUses = false
    public let cost = SessionCost()
    public let dailyCosts: [Date: SessionCost] = [:]
    public let usageLimit: UsageLimitSnapshot? = nil

    public private(set) var lastGrowthAt: Date?
    public private(set) var currentTurnStartedAt: Date?
    private var status = "none"
    private var lastDiskState: (Date, Date)?

    /// Statuses seen at rest on a real install; anything else is treated
    /// as in-flight, bounded by the freshness of lastUpdatedAt.
    static let restingStatuses: Set<String> = ["none", "completed", "aborted", "error", ""]

    public var turnPhase: TurnPhase {
        if !Self.restingStatuses.contains(status), let growth = lastGrowthAt,
           Date().timeIntervalSince(growth) < 10 * 60 {
            return .midTurn
        }
        // Fresh record updates also mean activity even when status rests.
        if let growth = lastGrowthAt, Date().timeIntervalSince(growth) < 8 {
            return .midTurn
        }
        return .completed
    }

    init(storeURL: URL, composerID: String) {
        self.url = storeURL
        self.sessionID = composerID
    }

    public func refresh() throws {
        let fm = FileManager.default
        func mtime(_ path: String) -> Date {
            (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date ?? .distantPast
        }
        let disk = (mtime(url.path), mtime(url.path + "-wal"))
        guard lastDiskState.map({ $0 != disk }) ?? true else { return }
        lastDiskState = disk

        guard let composer = CursorAdapter.composers(inStateDBAt: url)
            .first(where: { $0.id == sessionID }) else { return }
        status = composer.status
        if lastGrowthAt == nil || composer.lastUpdatedAt > lastGrowthAt! {
            if turnPhase == .completed { currentTurnStartedAt = composer.lastUpdatedAt }
            lastGrowthAt = composer.lastUpdatedAt
        }
    }
}

/// Memoizes the composer parse by the db's mtime (base + WAL). Every
/// CursorComposerReader shares one state.vscdb, so on a db change all N
/// readers would otherwise each copy and re-parse a multi-MB file; with this
/// the first parses and the rest read the cached result. Thread-safe because
/// readers refresh on the store actor but the class itself makes no isolation
/// promises.
private final class ComposerCache: @unchecked Sendable {
    static let shared = ComposerCache()
    private let lock = NSLock()
    private var cachedPath: String?
    private var cachedMtime: Date?
    private var cached: [CursorAdapter.Composer] = []

    func composers(forDBAt url: URL,
                   parse: () -> [CursorAdapter.Composer]) -> [CursorAdapter.Composer] {
        let mtime = Self.combinedMtime(url)
        lock.lock()
        if cachedPath == url.path, cachedMtime == mtime {
            defer { lock.unlock() }
            return cached
        }
        lock.unlock()
        // Parse outside the lock (it copies a file); a redundant parse under
        // rare races is harmless and still cheaper than N copies.
        let parsed = parse()
        lock.lock()
        cachedPath = url.path
        cachedMtime = mtime
        cached = parsed
        lock.unlock()
        return parsed
    }

    /// Newest of the db and its WAL sibling — the WAL is where Cursor's live
    /// writes land before checkpoint.
    private static func combinedMtime(_ url: URL) -> Date {
        let fm = FileManager.default
        var newest = Date.distantPast
        for path in [url.path, url.path + "-wal"] {
            if let m = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date {
                newest = max(newest, m)
            }
        }
        return newest
    }
}
