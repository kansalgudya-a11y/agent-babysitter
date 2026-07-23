import Foundation
import AgentBabysitterCore

/// Optional cross-machine stats: each Mac writes its OWN ledger to a
/// per-machine file in iCloud Drive; for display we sum every machine's file
/// so "all-time" spans all your Macs. The merged view is never written back to
/// a machine's own ledger. Opt-in. No iCloud entitlement needed — the app
/// isn't sandboxed. Main-actor isolated: only ever called from the model.
///
/// Honesty note: the ledger is keyed by agent id, model id and PROJECT FOLDER
/// NAME — so turning this on copies the names of the folders you work in (not
/// only aggregate numbers) into iCloud Drive. `ownFileURL` exposes exactly what
/// leaves this Mac, and `removeOwnFile()` deletes it again when sync is turned
/// off. Transcripts and prompts are never part of the wire.
@MainActor
enum StatsSync {

    /// Outcome of the last `writeIfChanged`, so the model/UI can tell the user
    /// when the toggle is ON but nothing is actually leaving: iCloud Drive isn't
    /// set up (`.unavailable`), or a write failed (`.failed`). Silent success
    /// AND silent failure — a toggle that did nothing forever — was the old bug.
    enum SyncStatus: Equatable {
        case idle
        case written        // a fresh file was written this call
        case upToDate       // nothing changed since last write
        case unavailable    // no iCloud Drive folder — the toggle is a no-op here
        case failed(String) // encode or write error
    }

    private(set) static var lastStatus: SyncStatus = .idle

    private static var folderCache: (at: Date, url: URL?)?

    private static var folder: URL? {
        if let cache = folderCache, Date().timeIntervalSince(cache.at) < 300 {
            return cache.url
        }
        var result: URL?
        if let base = PlatformPaths.iCloudDrive,
           FileManager.default.fileExists(atPath: base.path) {
            let dir = base.appendingPathComponent("AgentBabysitter")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            result = dir
        }
        folderCache = (Date(), result)
        return result
    }

    /// The exact bytes last written, to skip no-op writes. Compared whole so
    /// ANY field change (counts, minutes, re-keyed projects) triggers a write —
    /// a partial hash of just the cost sums missed those.
    private static var lastWrittenData: Data?

    /// Stable per-machine id so this Mac always writes the same file.
    private static var machineID: String {
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: "machineID") { return id }
        let id = UUID().uuidString.prefix(8).lowercased()
        defaults.set(String(id), forKey: "machineID")
        return String(id)
    }

    private struct Wire: Codable {
        var costByAgent: [String: [String: Double]]
        var costByProject: [String: [String: Double]]
        /// Optional: files written by pre-0.8.0 builds don't carry it.
        var costByModel: [String: [String: Double]]?
        var sessionCounts: [String: Int]
        var activeMinutes: [String: Double]
    }

    /// Write THIS machine's own ledger (never a merged one) to its own file,
    /// skipping the write when nothing changed since last time. Records the
    /// outcome in `lastStatus` so an on-but-doing-nothing state is visible.
    static func writeIfChanged(_ ownLedger: StatsLedger.Ledger) {
        guard let folder else { lastStatus = .unavailable; return }
        let wire = Wire(costByAgent: ownLedger.costByAgent, costByProject: ownLedger.costByProject,
                        costByModel: ownLedger.costByModel,
                        sessionCounts: ownLedger.sessionCounts, activeMinutes: ownLedger.activeMinutes)
        // Sorted keys → identical contents always encode to identical bytes, so
        // the byte-compare below is a true "did anything change" check.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(wire) else {
            lastStatus = .failed("Couldn't encode stats for sync.")
            return
        }
        guard data != lastWrittenData else { lastStatus = .upToDate; return }
        do {
            try data.write(to: folder.appendingPathComponent("stats-\(machineID).json"))
            lastWrittenData = data
            lastStatus = .written
        } catch {
            lastStatus = .failed(error.localizedDescription)
        }
    }

    /// THIS machine's own synced file, if the iCloud folder exists — for a
    /// "Show synced file in Finder" affordance and for `removeOwnFile`. It is
    /// the exact set of bytes this Mac uploads.
    static var ownFileURL: URL? {
        folder.map { $0.appendingPathComponent("stats-\(machineID).json") }
    }

    /// Delete THIS machine's file from iCloud (e.g. when the user turns sync
    /// off). We only ever touch our own file; siblings' files stay theirs.
    /// Returns false if the folder is unavailable or the removal failed.
    @discardableResult
    static func removeOwnFile() -> Bool {
        guard let url = ownFileURL else { lastStatus = .unavailable; return false }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            lastWrittenData = nil   // so re-enabling sync writes a fresh file
            lastStatus = .idle
            return true
        } catch {
            lastStatus = .failed(error.localizedDescription)
            return false
        }
    }

    /// A DISPLAY-only view summing this machine's ledger with every sibling's
    /// (each file holds one machine's totals). Never persisted back locally.
    static func summedWithSiblings(_ local: StatsLedger.Ledger) -> StatsLedger.Ledger {
        guard let folder,
              let files = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil) else { return local }
        var ledgers = [local]
        let ours = "stats-\(machineID).json"
        for file in files where file.pathExtension == "json" && file.lastPathComponent != ours {
            guard let data = try? Data(contentsOf: file),
                  let wire = try? JSONDecoder().decode(Wire.self, from: data) else { continue }
            ledgers.append(StatsLedger.Ledger(
                costByAgent: wire.costByAgent, costByProject: wire.costByProject,
                costByModel: wire.costByModel ?? [:],
                sessionCounts: wire.sessionCounts, countedSessionIDs: [],
                activeMinutes: wire.activeMinutes))
        }
        return StatsLedger.summed(ledgers)
    }
}
