import Foundation

/// A display currency. Costs are always computed in USD (vendor list prices
/// are USD); a currency is just how the user prefers to SEE them, applied via
/// an exchange rate. USD is the default and needs no rate (and no network).
public struct Currency: Equatable, Sendable, Codable, Hashable {
    public let code: String        // ISO 4217, e.g. "USD", "INR"
    public let symbol: String      // "$", "₹"
    public let name: String        // "US Dollar"
    public let fractionDigits: Int // 2 for most, 0 for JPY/KRW

    public init(code: String, symbol: String, name: String, fractionDigits: Int = 2) {
        self.code = code
        self.symbol = symbol
        self.name = name
        self.fractionDigits = fractionDigits
    }
}

public extension Currency {
    static let usd = Currency(code: "USD", symbol: "$", name: "US Dollar")

    /// Common currencies, all present in the exchange-rate feed. USD first.
    static let catalog: [Currency] = [
        usd,
        Currency(code: "EUR", symbol: "€", name: "Euro"),
        Currency(code: "GBP", symbol: "£", name: "British Pound"),
        Currency(code: "INR", symbol: "₹", name: "Indian Rupee"),
        Currency(code: "JPY", symbol: "¥", name: "Japanese Yen", fractionDigits: 0),
        Currency(code: "CNY", symbol: "CN¥", name: "Chinese Yuan"),
        Currency(code: "CAD", symbol: "C$", name: "Canadian Dollar"),
        Currency(code: "AUD", symbol: "A$", name: "Australian Dollar"),
        Currency(code: "SGD", symbol: "S$", name: "Singapore Dollar"),
        Currency(code: "CHF", symbol: "Fr", name: "Swiss Franc"),
        Currency(code: "BRL", symbol: "R$", name: "Brazilian Real"),
        Currency(code: "KRW", symbol: "₩", name: "South Korean Won", fractionDigits: 0),
        Currency(code: "AED", symbol: "AED", name: "UAE Dirham"),
    ]

    static func byCode(_ code: String) -> Currency? {
        catalog.first { $0.code == code }
    }
}

/// Turns a USD amount into a currency-formatted string. Kept pure and in Core
/// so it's unit-tested; the app supplies the fetched rate.
public enum CurrencyFormatter {

    /// e.g. `usd 1.22, INR @ 83.2 → "~₹101.50"`. `rate` is USD→currency;
    /// USD passes rate 1. The tilde marks it as an estimate (from token usage).
    public static func string(usd: Double, currency: Currency, rate: Double,
                              approximate: Bool = true) -> String {
        let value = usd * (currency.code == "USD" ? 1 : rate)
        let number = decimalFormatter(currency.fractionDigits)
            .string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
        return "\(approximate ? "~" : "")\(currency.symbol)\(number)"
    }

    /// Compact form for the tight menu-bar slot: no decimals, k/M past 10k.
    public static func compact(usd: Double, currency: Currency, rate: Double) -> String {
        let value = usd * (currency.code == "USD" ? 1 : rate)
        let magnitude: String
        switch abs(value) {
        case ..<10_000: magnitude = String(Int(value.rounded()))
        case ..<1_000_000: magnitude = trimmed(value / 1_000) + "k"
        default: magnitude = trimmed(value / 1_000_000) + "M"
        }
        return "\(currency.symbol)\(magnitude)"
    }

    private static func trimmed(_ value: Double) -> String {
        let text = String(format: "%.1f", value)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }

    /// NumberFormatters are expensive to build; only two shapes are ever
    /// needed (0 and 2 fraction digits), so cache them. Guarded by a lock —
    /// formatting can run from any thread that renders a cost label.
    private static let formatterLock = NSLock()
    private nonisolated(unsafe) static var formatterCache: [Int: NumberFormatter] = [:]

    private static func decimalFormatter(_ digits: Int) -> NumberFormatter {
        formatterLock.lock()
        defer { formatterLock.unlock() }
        if let cached = formatterCache[digits] { return cached }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        formatter.groupingSeparator = ","
        formatter.usesGroupingSeparator = true
        formatterCache[digits] = formatter
        return formatter
    }
}

/// Pure parsing for the exchange-rate feed (open.er-api.com/v6/latest/USD),
/// which needs no API key and sends no user data. Shape:
/// `{"result":"success","rates":{"INR":83.2,"EUR":0.92,…},"time_last_update_unix":…}`
public enum CurrencyRateParsing {

    public struct Rates: Equatable, Sendable {
        public let base: String
        public let updatedAt: Date?
        public let rates: [String: Double]
        public func rate(for code: String) -> Double? {
            code == base ? 1 : rates[code]
        }
    }

    public static func parse(_ data: Data) -> Rates? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (root["result"] as? String) == "success",
              let rawRates = root["rates"] as? [String: Any] else { return nil }
        var rates: [String: Double] = [:]
        for (code, value) in rawRates {
            if let number = (value as? NSNumber)?.doubleValue { rates[code] = number }
        }
        guard !rates.isEmpty else { return nil }
        let updated = (root["time_last_update_unix"] as? NSNumber)
            .map { Date(timeIntervalSince1970: $0.doubleValue) }
        return Rates(base: (root["base_code"] as? String) ?? "USD",
                     updatedAt: updated, rates: rates)
    }
}
