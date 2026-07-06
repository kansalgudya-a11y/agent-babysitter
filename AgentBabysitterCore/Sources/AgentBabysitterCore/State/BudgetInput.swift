import Foundation

/// Parses/formats the free-typed budget fields. In Core so it's unit-tested;
/// the Settings TextField edits a plain string and routes through this.
public enum BudgetInput {

    /// Lenient parse of typed money → USD amount. Accepts a comma OR dot as
    /// the decimal mark, ignores currency symbols/spaces, keeps only the FIRST
    /// decimal point (so "1.234.56" doesn't collapse to a wrong number), and
    /// clamps to ≥ 0. Empty / unparseable → 0 (= budget off).
    public static func parse(_ text: String) -> Double {
        var seenDot = false
        var cleaned = ""
        for ch in text.replacingOccurrences(of: ",", with: ".") {
            if ch.isNumber {
                cleaned.append(ch)
            } else if ch == ".", !seenDot {
                seenDot = true
                cleaned.append(ch)
            }
            // any later dot, or any other character, is dropped
        }
        return max(0, Double(cleaned) ?? 0)
    }

    /// Amount → editable string; 0 shows as empty ("off"), whole numbers drop
    /// the decimals, fractions keep up to two.
    public static func format(_ value: Double) -> String {
        guard value > 0 else { return "" }
        if value == value.rounded() { return String(Int(value)) }
        return String(format: "%.2f", value)
    }
}
