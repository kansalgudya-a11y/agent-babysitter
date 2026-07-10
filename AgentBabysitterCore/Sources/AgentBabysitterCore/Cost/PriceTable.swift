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

    /// Billed volume: new work PLUS every cache re-read. Useful for explaining
    /// a bill, misleading as a headline.
    ///
    /// A cached prefix is re-sent on every call, so this counts the same tokens
    /// once per request — a 400k-token context over 4,500 calls reads as ~1.8B
    /// "tokens" though only ~400k distinct tokens ever existed. Never show this
    /// as "tokens used"; `totalTokens` (new work) is that number.
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
    /// What we've already billed for a message, so a later streaming line that
    /// carries the message's FINAL usage can revise the figure instead of being
    /// dropped (early lines report `output_tokens: 1`).
    private struct Counted {
        var usage: TokenUsage
        var dollars: Double
        var day: Date?
    }
    private var counted: [String: Counted] = [:]
    /// Store-wide dedupe. A resumed/forked session's transcript repeats the
    /// earlier session's messages verbatim; without a shared registry each file
    /// bills them again. nil = stand-alone (tests) → per-file dedupe.
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

        // Another transcript already billed this message (a resumed session
        // copies its parent's conversation verbatim) — never bill it twice.
        if let id = payload.messageID, let claims,
           claims.claim(id, owner: owner) == .ownedByOther { return }

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

        // An undated entry can't be attributed to a day. Charging it to "now"
        // would silently move an old session's spend into today; the session's
        // own total still counts it.
        let day = entry.timestamp.map {
            LocalDay.start(of: $0, timeZone: timeZoneOverride ?? .current)
        }

        if let id = payload.messageID, let previous = counted[id] {
            // Same message again. Claude Code streams one assistant message as
            // several lines, each repeating usage as it GROWS; only the last
            // line is the real bill. Replace what we billed, keeping the
            // message in the day bucket it was first attributed to.
            guard billable(usage) > billable(previous.usage) else { return }
            apply(previous.usage, dollars: previous.dollars, unknownModel: nil,
                  day: previous.day, model: payload.model, sign: -1)
            apply(usage, dollars: dollars, unknownModel: unknownModel,
                  day: previous.day, model: payload.model, sign: 1)
            counted[id] = Counted(usage: usage, dollars: dollars, day: previous.day)
            return
        }

        apply(usage, dollars: dollars, unknownModel: unknownModel,
              day: day, model: payload.model, sign: 1)
        if let id = payload.messageID {
            counted[id] = Counted(usage: usage, dollars: dollars, day: day)
        }
    }

    private func billable(_ usage: TokenUsage) -> Int {
        usage.totalTokens + usage.cacheReadInputTokens
    }

    /// Fold one message in (`sign: 1`) or back out (`sign: -1`).
    private mutating func apply(_ usage: TokenUsage, dollars: Double, unknownModel: String?,
                                day: Date?, model: String?, sign: Int) {
        cost.add(usage: usage, dollars: dollars, unknownModel: unknownModel, sign: sign)
        guard let day else { return }
        var daily = dailyCosts[day] ?? SessionCost()
        daily.add(usage: usage, dollars: dollars, unknownModel: unknownModel, sign: sign)
        dailyCosts[day] = daily
        if dollars > 0, let model {
            dailyDollarsByModel[day, default: [:]][model, default: 0] += Double(sign) * dollars
        }
    }
}

extension SessionCost {
    /// Fold one message's usage in (`sign: 1`) or back out (`sign: -1`) — the
    /// latter when a later streaming line supersedes what we already billed.
    mutating func add(usage: TokenUsage, dollars: Double, unknownModel: String?, sign: Int = 1) {
        totalTokens += sign * usage.totalTokens
        inputTokens += sign * usage.inputTokens
        outputTokens += sign * usage.outputTokens
        cacheReadTokens += sign * usage.cacheReadInputTokens
        cacheWriteTokens += sign * usage.cacheCreationInputTokens
        self.dollars += Double(sign) * dollars
        if let unknownModel { unknownModels.insert(unknownModel) }
    }
}
