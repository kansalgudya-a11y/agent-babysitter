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

    public enum Claim: Equatable, Sendable {
        /// Nobody had it: count it in full.
        case granted
        /// This owner already counted it. Claude Code writes an assistant
        /// message as several lines whose usage GROWS, so the owner may revise
        /// its figure upward — but never bill it twice.
        case alreadyOwned
        /// Another transcript already billed it (a resumed session's copy).
        case ownedByOther
    }

    public init() {}

    /// Who, if anyone, may count this message.
    public func claim(_ messageID: String, owner: String) -> Claim {
        lock.lock(); defer { lock.unlock() }
        if let existing = owners[messageID] {
            return existing == owner ? .alreadyOwned : .ownedByOther
        }
        owners[messageID] = owner
        return .granted
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
