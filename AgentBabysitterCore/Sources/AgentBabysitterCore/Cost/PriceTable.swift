import Foundation

/// USD per million tokens for one model. Input, output, cache-write (per
/// TTL), and cache-read are priced separately — never lump cache with input.
public struct ModelPricing: Equatable, Sendable {
    public let inputPerMTok: Double
    public let outputPerMTok: Double
    public let cacheReadPerMTok: Double
    public let cacheWrite5mPerMTok: Double
    public let cacheWrite1hPerMTok: Double
}

/// Bundled price table keyed by model id. Unknown models return nil — the
/// UI shows token counts + "pricing unknown" rather than guessed dollars.
public struct PriceTable: Sendable {

    private let prices: [String: ModelPricing]

    public init(prices: [String: ModelPricing]) {
        self.prices = prices
    }

    public static let bundled: PriceTable = {
        guard let url = Bundle.module.url(forResource: "model-pricing", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let models = root["models"] as? [String: [String: Double]] else {
            return PriceTable(prices: [:])
        }
        var prices: [String: ModelPricing] = [:]
        for (id, fields) in models {
            guard let input = fields["input"], let output = fields["output"],
                  let read = fields["cacheRead"], let write5m = fields["cacheWrite5m"],
                  let write1h = fields["cacheWrite1h"] else { continue }
            prices[id] = ModelPricing(inputPerMTok: input, outputPerMTok: output,
                                      cacheReadPerMTok: read,
                                      cacheWrite5mPerMTok: write5m,
                                      cacheWrite1hPerMTok: write1h)
        }
        return PriceTable(prices: prices)
    }()

    public func pricing(forModel id: String) -> ModelPricing? {
        if let exact = prices[id] { return exact }
        // Full model ids carry a date suffix (claude-haiku-4-5-20251001)
        if let range = id.range(of: #"-\d{8}$"#, options: .regularExpression) {
            return prices[String(id[..<range.lowerBound])]
        }
        return nil
    }
}

/// Running cost for one session's transcript.
public struct SessionCost: Equatable, Sendable {
    public internal(set) var dollars: Double = 0
    /// All usage tokens counted so far (the display value when pricing is unknown).
    public internal(set) var totalTokens: Int = 0
    /// Token split — where the spend actually goes. Cache reads are cheap,
    /// cache writes and output aren't; surfacing this helps people optimize.
    public internal(set) var inputTokens: Int = 0
    public internal(set) var outputTokens: Int = 0
    public internal(set) var cacheReadTokens: Int = 0
    public internal(set) var cacheWriteTokens: Int = 0
    /// Models with real usage but no price entry — show "pricing unknown".
    public internal(set) var unknownModels: Set<String> = []

    public var hasUnknownPricing: Bool { !unknownModels.isEmpty }

    /// EVERY token the API processed, cache reads included. Cache reads are
    /// ~90%+ of real volume (they're re-sent each call and billed at a tenth
    /// the input rate), so this — not `totalTokens` — is the number that
    /// matches `/cost` and the usage console. Show this to users.
    public var allTokens: Int { totalTokens + cacheReadTokens }

    /// "812" / "42k" / "264.9M" / "1.2B" - rolls to the next unit past 999.
    public var formattedTokens: String { Self.abbreviatedCount(totalTokens) }

    /// Abbreviated `allTokens` — the figure the UI displays as "tok".
    public var formattedAllTokens: String { Self.abbreviatedCount(allTokens) }

    public static func abbreviatedCount(_ count: Int) -> String {
        func scaled(_ value: Double, _ unit: String) -> String {
            let text = String(format: "%.1f", value)
            return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + unit
        }
        switch count {
        case ..<1_000: return "\(count)"
        case ..<1_000_000: return "\(count / 1_000)k"
        case ..<1_000_000_000: return scaled(Double(count) / 1e6, "M")
        default: return scaled(Double(count) / 1e9, "B")
        }
    }

    public init() {}

    /// For previews/fixtures.
    public init(dollars: Double, totalTokens: Int = 0, unknownModels: Set<String> = [],
                inputTokens: Int = 0, outputTokens: Int = 0,
                cacheReadTokens: Int = 0, cacheWriteTokens: Int = 0) {
        self.dollars = dollars
        self.totalTokens = totalTokens
        self.unknownModels = unknownModels
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
    }
}

/// Folds transcript entries into dollars. One API message is written as
/// several JSONL lines each repeating the full usage, so usage counts once
/// per unique `messageID`.
public struct CostAccumulator: Sendable {

    public private(set) var cost = SessionCost()
    /// Cost bucketed by local day of the entry's own timestamp — "today"
    /// totals count what actually happened today, not whole files whose
    /// mtime is today (a session spanning midnight would otherwise
    /// double-attribute).
    public private(set) var dailyCosts: [Date: SessionCost] = [:]
    /// Dollars per model per local day — the "where does the spend go"
    /// split (Opus vs Sonnet vs Haiku). Only priced models appear; unknown
    /// ones already surface as "pricing unknown".
    public private(set) var dailyDollarsByModel: [Date: [String: Double]] = [:]

    private let table: PriceTable
    /// nil = follow the live local timezone per entry (never frozen); tests
    /// pin an explicit zone for determinism.
    private let timeZoneOverride: TimeZone?
    private var seenMessageIDs: Set<String> = []
    /// Store-wide dedupe. A resumed/forked session's transcript repeats the
    /// earlier session's messages verbatim; without a shared registry each file
    /// bills them again. nil = stand-alone (tests) → per-file dedupe as before.
    private let claims: MessageIDClaims?
    private let owner: String

    public init(table: PriceTable = .bundled, timeZone: TimeZone? = nil,
                claims: MessageIDClaims? = nil, owner: String = "") {
        self.table = table
        self.timeZoneOverride = timeZone
        self.claims = claims
        self.owner = owner
    }

    public mutating func consume(_ entry: TranscriptEntry) {
        // `totalTokens` counts new work only, so a message that is nothing but
        // cache reads would be skipped — and those reads are billed. Admit any
        // message with real usage of any kind.
        guard case .assistant(let payload) = entry.kind, let usage = payload.usage,
              usage.totalTokens > 0 || usage.cacheReadInputTokens > 0 else { return }
        if let id = payload.messageID {
            if let claims {
                guard claims.claim(id, owner: owner) else { return }
            } else {
                guard seenMessageIDs.insert(id).inserted else { return }
            }
        }

        var dollars = 0.0
        var unknownModel: String?
        if let model = payload.model, let pricing = table.pricing(forModel: model) {
            dollars = (Double(usage.inputTokens) * pricing.inputPerMTok
                + Double(usage.outputTokens) * pricing.outputPerMTok
                + Double(usage.cacheReadInputTokens) * pricing.cacheReadPerMTok
                + Double(usage.cacheCreation5mTokens) * pricing.cacheWrite5mPerMTok
                + Double(usage.cacheCreation1hTokens) * pricing.cacheWrite1hPerMTok) / 1_000_000
        } else {
            unknownModel = payload.model ?? "unknown"
        }

        cost.add(usage: usage, dollars: dollars, unknownModel: unknownModel)

        // An undated entry can't be attributed to a day. Charging it to "now"
        // would silently move an old session's spend into today; the session's
        // own total still counts it.
        guard let timestamp = entry.timestamp else { return }
        let day = LocalDay.start(of: timestamp, timeZone: timeZoneOverride ?? .current)
        var daily = dailyCosts[day] ?? SessionCost()
        daily.add(usage: usage, dollars: dollars, unknownModel: unknownModel)
        dailyCosts[day] = daily
        if dollars > 0, let model = payload.model {
            dailyDollarsByModel[day, default: [:]][model, default: 0] += dollars
        }
    }
}

extension SessionCost {
    /// Fold one message's usage in: total + the input/output/cache split.
    mutating func add(usage: TokenUsage, dollars: Double, unknownModel: String?) {
        totalTokens += usage.totalTokens
        inputTokens += usage.inputTokens
        outputTokens += usage.outputTokens
        cacheReadTokens += usage.cacheReadInputTokens
        cacheWriteTokens += usage.cacheCreationInputTokens
        self.dollars += dollars
        if let unknownModel { unknownModels.insert(unknownModel) }
    }
}
