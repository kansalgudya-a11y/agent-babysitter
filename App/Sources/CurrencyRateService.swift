import Foundation
import AgentBabysitterCore

/// Fetches USD→currency exchange rates from a free, no-key feed and caches
/// them. Only ever runs when the user has chosen a non-USD display currency —
/// the default (USD) stays fully offline. Sends no user data: it only asks
/// for public rates against USD, so it's privacy-safe despite being a network
/// call. Rates change slowly, so a cached value is refreshed at most daily.
actor CurrencyRateService {

    private let session: URLSession
    private let staleAfter: TimeInterval = 24 * 3600

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.httpShouldSetCookies = false
        session = URLSession(configuration: config)
    }

    struct CachedRate: Codable, Equatable {
        var code: String
        var rate: Double
        var fetchedAt: Date
    }

    /// Returns the USD→`code` rate, using the cache when it's fresh for that
    /// same currency, otherwise fetching. nil when offline with no usable
    /// cache. USD short-circuits to 1 with no network.
    func rate(for code: String, cached: CachedRate?) async -> CachedRate? {
        if code == "USD" { return CachedRate(code: "USD", rate: 1, fetchedAt: Date()) }
        if let cached, cached.code == code,
           Date().timeIntervalSince(cached.fetchedAt) < staleAfter {
            return cached
        }
        guard let url = URL(string: "https://open.er-api.com/v6/latest/USD"),
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let rates = CurrencyRateParsing.parse(data),
              let rate = rates.rate(for: code) else {
            // Keep the last good value only if it's for THIS currency — never
            // hand back another currency's rate to be shown under this symbol.
            return cached?.code == code ? cached : nil
        }
        return CachedRate(code: code, rate: rate, fetchedAt: Date())
    }
}
