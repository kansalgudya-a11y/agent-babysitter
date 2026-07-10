import Foundation

/// One registry of assistant `message.id`s already counted, shared by every
/// session in a store.
///
/// Resuming or forking a Claude Code session copies the whole prior
/// conversation — same `message.id`s, same `usage` — into a NEW transcript
/// file. Deduping only *within* a file therefore bills those same API messages
/// once per file: measured against real transcripts that inflated the total by
/// ~19%, and by ~2x on days when a session was resumed.
///
/// First claim wins: whichever session reads a message first owns it, so the
/// spend is counted exactly once no matter how many transcripts carry a copy.
public final class MessageIDClaims: @unchecked Sendable {

    private var owners: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    /// True when `owner` may count this message — i.e. nobody has yet.
    public func claim(_ messageID: String, owner: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard owners[messageID] == nil else { return false }
        owners[messageID] = owner
        return true
    }

    /// Forget everything `owner` claimed. Its transcript is being re-read from
    /// the start (file shrank, or the session went away), so it must be free to
    /// count its own messages again rather than skip them as "already seen".
    public func release(owner: String) {
        lock.lock(); defer { lock.unlock() }
        owners = owners.filter { $0.value != owner }
    }

    /// How many distinct messages have been counted (diagnostics/tests).
    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return owners.count
    }
}
