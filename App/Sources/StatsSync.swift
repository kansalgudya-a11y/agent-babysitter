import Foundation
import AgentBabysitterCore

/// Optional cross-machine stats: each Mac writes its ledger to a per-machine
/// file in iCloud Drive; on read we merge every machine's file so "all-time"
/// really means all your Macs. Opt-in. No iCloud entitlement needed — the app
/// isn't sandboxed, so the iCloud Drive folder is a plain path. Merge is the
/// ledger's conflict-free max-per-day, so order and races don't matter.
enum StatsSync {

    private static var folder: URL? {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        guard FileManager.default.fileExists(atPath: base.path) else { return nil }
        let dir = base.appendingPathComponent("AgentBabysitter")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

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

    static func write(_ ledger: StatsLedger.Ledger) {
        guard let folder else { return }
        let wire = Wire(costByAgent: ledger.costByAgent, costByProject: ledger.costByProject,
                        sessionCounts: ledger.sessionCounts, activeMinutes: ledger.activeMinutes)
        guard let data = try? JSONEncoder().encode(wire) else { return }
        try? data.write(to: folder.appendingPathComponent("stats-\(machineID).json"))
    }

    /// Merge `local` with every sibling machine's file (skipping our own).
    static func mergedWithSiblings(_ local: StatsLedger.Ledger) -> StatsLedger.Ledger {
        guard let folder,
              let files = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil) else { return local }
        var merged = local
        let ours = "stats-\(machineID).json"
        for file in files where file.pathExtension == "json" && file.lastPathComponent != ours {
            guard let data = try? Data(contentsOf: file),
                  let wire = try? JSONDecoder().decode(Wire.self, from: data) else { continue }
            let sibling = StatsLedger.Ledger(
                costByAgent: wire.costByAgent, costByProject: wire.costByProject,
                sessionCounts: wire.sessionCounts, todaySessionIDs: [],
                activeMinutes: wire.activeMinutes)
            merged = StatsLedger.merged(merged, sibling)
        }
        return merged
    }
}
