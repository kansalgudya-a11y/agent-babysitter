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
    /// Models with real usage but no price entry — show "pricing unknown".
    public internal(set) var unknownModels: Set<String> = []

    public var hasUnknownPricing: Bool { !unknownModels.isEmpty }

    public init() {}

    /// For previews/fixtures.
    public init(dollars: Double, totalTokens: Int = 0, unknownModels: Set<String> = []) {
        self.dollars = dollars
        self.totalTokens = totalTokens
        self.unknownModels = unknownModels
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

    private let table: PriceTable
    private let calendar: Calendar
    private var seenMessageIDs: Set<String> = []

    public init(table: PriceTable = .bundled, calendar: Calendar = .current) {
        self.table = table
        self.calendar = calendar
    }

    public mutating func consume(_ entry: TranscriptEntry) {
        guard case .assistant(let payload) = entry.kind,
              let usage = payload.usage, usage.totalTokens > 0 else { return }
        if let id = payload.messageID {
            guard seenMessageIDs.insert(id).inserted else { return }
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

        cost.totalTokens += usage.totalTokens
        cost.dollars += dollars
        if let unknownModel { cost.unknownModels.insert(unknownModel) }

        let day = calendar.startOfDay(for: entry.timestamp ?? Date())
        var daily = dailyCosts[day] ?? SessionCost()
        daily.totalTokens += usage.totalTokens
        daily.dollars += dollars
        if let unknownModel { daily.unknownModels.insert(unknownModel) }
        dailyCosts[day] = daily
    }
}
