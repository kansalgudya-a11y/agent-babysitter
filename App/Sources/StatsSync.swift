import Foundation
import AgentBabysitterCore

/// Optional cross-machine stats: each Mac writes its OWN ledger to a
/// per-machine file in iCloud Drive; for display we sum every machine's file
/// so "all-time" spans all your Macs. The merged view is never written back to
/// a machine's own ledger. Opt-in. No iCloud entitlement needed — the app
/// isn't sandboxed. Main-actor isolated: only ever called from the model.
@MainActor
enum StatsSync {

    private static var folderCache: (at: Date, url: URL?)?

    private static var folder: URL? {
        if let cache = folderCache, Date().timeIntervalSince(cache.at) < 300 {
            return cache.url
        }
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        var result: URL?
        if FileManager.default.fileExists(atPath: base.path) {
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
        var sessionCounts: [String: Int]
        var activeMinutes: [String: Double]
    }

    /// Write THIS machine's own ledger (never a merged one) to its own file,
    /// skipping the write when nothing changed since last time.
    static func writeIfChanged(_ ownLedger: StatsLedger.Ledger) {
        guard let folder else { return }
        let wire = Wire(costByAgent: ownLedger.costByAgent, costByProject: ownLedger.costByProject,
                        sessionCounts: ownLedger.sessionCounts, activeMinutes: ownLedger.activeMinutes)
        // Sorted keys → identical contents always encode to identical bytes, so
        // the byte-compare below is a true "did anything change" check.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(wire) else { return }
        guard data != lastWrittenData else { return }
        try? data.write(to: folder.appendingPathComponent("stats-\(machineID).json"))
        lastWrittenData = data
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
                sessionCounts: wire.sessionCounts, todaySessionIDs: [],
                activeMinutes: wire.activeMinutes))
        }
        return StatsLedger.summed(ledgers)
    }
}
