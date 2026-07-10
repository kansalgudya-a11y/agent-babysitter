import Foundation

/// What the session store needs from a per-session transcript reader.
/// Line-oriented agents use `TranscriptFileTailer`; agents with opaque
/// storage (Antigravity's SQLite/protobuf conversations) plug in readers
/// that derive facts from file activity instead.
public protocol SessionReading: AnyObject {
    var url: URL { get }
    var sessionID: String { get }
    var turnPhase: TurnPhase { get }
    var hasPendingToolUses: Bool { get }
    var currentTurnStartedAt: Date? { get }
    var lastGrowthAt: Date? { get }
    var lastKnownCWD: String? { get }
    var lastKnownEntrypoint: String? { get }
    var isSidechain: Bool { get }
    var isUnreadable: Bool { get }
    var cost: SessionCost { get }
    /// Cost bucketed by local day of entry timestamps (empty when the
    /// reader can't attribute usage).
    var dailyCosts: [Date: SessionCost] { get }
    /// Latest subscription rate-limit reading seen in this transcript.
    var usageLimit: UsageLimitSnapshot? { get }
    /// One-line caption of the user's last real prompt — "what this session
    /// is working on". Nil when the format doesn't expose prompts.
    var lastPromptTitle: String? { get }
    /// Dollars per model per local day (empty when unattributable).
    var dailyDollarsByModel: [Date: [String: Double]] { get }
    /// Pick up whatever changed on disk since the last call.
    func refresh() throws
    /// Adopt the store-wide message-id registry so a conversation copied into a
    /// resumed session's transcript is counted once, not once per file.
    func adoptCostClaims(_ claims: MessageIDClaims)
}

public extension SessionReading {
    var lastPromptTitle: String? { nil }
    var dailyDollarsByModel: [Date: [String: Double]] { [:] }
    /// Readers that report no usage have nothing to dedupe.
    func adoptCostClaims(_ claims: MessageIDClaims) {}
}

extension TranscriptFileTailer: SessionReading {
    public var turnPhase: TurnPhase { reducer.turnPhase }
    public var hasPendingToolUses: Bool { !reducer.pendingToolUseIDs.isEmpty }
    public var currentTurnStartedAt: Date? { reducer.currentTurnStartedAt }
    public var cost: SessionCost { costAccumulator.cost }
    public var dailyCosts: [Date: SessionCost] { costAccumulator.dailyCosts }
    public var usageLimit: UsageLimitSnapshot? { lastUsageLimit }
    public var lastPromptTitle: String? { reducer.lastUserPrompt }
    public var dailyDollarsByModel: [Date: [String: Double]] { costAccumulator.dailyDollarsByModel }

    public func refresh() throws {
        _ = try catchUp()
    }
}

/// Growth-only reader for sessions whose content can't be parsed (no public
/// schema). Honest capability: Working while the store file (and its
/// -wal/-shm siblings) is being written, Done once quiet, Ended when the
/// process goes away. It never claims Waiting or Stalled, and it reports no
/// usage.
public final class FileActivityReader: SessionReading {

    public let url: URL
    public let sessionID: String
    public let lastKnownCWD: String? = nil
    public let lastKnownEntrypoint: String?
    public let isSidechain = false
    public let isUnreadable = false
    public let hasPendingToolUses = false
    public let cost = SessionCost()
    public let dailyCosts: [Date: SessionCost] = [:]
    public let usageLimit: UsageLimitSnapshot? = nil

    public private(set) var lastGrowthAt: Date?
    public private(set) var currentTurnStartedAt: Date?

    /// Quiet for longer than this → the turn is considered over.
    private let idleCutoff: TimeInterval
    private let now: @Sendable () -> Date

    public var turnPhase: TurnPhase {
        guard let growth = lastGrowthAt else { return .completed }
        return now().timeIntervalSince(growth) < idleCutoff ? .midTurn : .completed
    }

    public init(url: URL, sessionID: String, entrypoint: String?,
                idleCutoff: TimeInterval = 60,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.url = url
        self.sessionID = sessionID
        self.lastKnownEntrypoint = entrypoint
        self.idleCutoff = idleCutoff
        self.now = now
    }

    public func refresh() throws {
        let fm = FileManager.default
        var newest: Date?
        for path in [url.path, url.path + "-wal", url.path + "-shm"] {
            if let modified = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date {
                newest = max(newest ?? .distantPast, modified)
            }
        }
        guard let newest else { return }
        if let previous = lastGrowthAt {
            // A fresh burst of writes after a quiet gap starts a new "turn"
            if newest > previous, now().timeIntervalSince(previous) >= idleCutoff {
                currentTurnStartedAt = newest
            }
        } else {
            currentTurnStartedAt = newest
        }
        lastGrowthAt = max(lastGrowthAt ?? .distantPast, newest)
    }
}
