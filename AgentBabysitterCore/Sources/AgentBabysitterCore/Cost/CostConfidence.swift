import Foundation

/// How much to trust a session's dollar figure. Cost here is computed locally
/// from captured token usage × published API prices — a good-faith estimate,
/// not a vendor invoice. The one case that quietly misleads is a session whose
/// usage includes a model we have no price for: those tokens add $0, so the
/// total reads LOWER than reality. Surfacing that keeps the hero number honest.
public enum CostConfidence {

    public enum Level: Equatable, Sendable {
        /// Every model in this session is priced — a faithful estimate.
        case estimated
        /// Some usage is priced and some isn't (unknown model) — the shown
        /// dollars are a FLOOR; the real cost is higher.
        case partial
        /// Nothing could be priced (only unknown models) — show tokens, not $.
        case unpriced
    }

    public static func level(for cost: SessionCost) -> Level {
        if cost.dollars > 0 { return cost.hasUnknownPricing ? .partial : .estimated }
        return cost.hasUnknownPricing ? .unpriced : .estimated
    }

    /// A short prefix for the dollar figure: "~" for a clean estimate, "≥" when
    /// it's a known undercount. (`unpriced` shows no dollars at all.)
    public static func amountPrefix(_ level: Level) -> String {
        switch level {
        case .estimated: return "~"
        case .partial:   return "≥"
        case .unpriced:  return ""
        }
    }

    /// One-line explanation for a tooltip / accessibility label.
    public static func detail(_ level: Level, unknownModels: Set<String>) -> String {
        switch level {
        case .estimated:
            return "Estimated from published API prices for every model used."
        case .partial:
            let names = unknownModels.sorted().joined(separator: ", ")
            let which = names.isEmpty ? "a model with no public price" : names
            return "A floor, not the full cost — usage from \(which) isn't priced yet, so the real total is higher."
        case .unpriced:
            return "No published price for this model yet — showing tokens instead of an estimate."
        }
    }
}
