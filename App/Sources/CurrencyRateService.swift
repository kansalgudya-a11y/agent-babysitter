import Foundation
import AgentBabysitterCore

/// Fetches USD→currency exchange rates from a free, no-key public feed
/// (`open.er-api.com`) and caches them. This is a network call, and it is one
/// of the app's opt-in outbound features: it runs ONLY while the user has
/// chosen a non-USD display currency — choosing that currency is the opt-in.
/// The default (USD) stays fully offline and makes no request. It sends no
/// user data: the request asks only for public USD rates, so nothing about
/// the user leaves the Mac. Rates change slowly, so a cached value is
/// refreshed at most daily.
///
/// Honesty note: any UI copy claiming the app makes "no network connections"
/// is false while a non-USD currency is selected — that copy must name this
/// feed alongside the other opt-in calls (live usage, update check). Those
/// strings live outside this file (PreferencesView, StatsView, FeatureGuide).
actor CurrencyRateService {

    private let session: URLSession
    /// Free fiat feeds publish ~daily, but we keep the displayed rate live by
    /// re-fetching often; a short TTL lets the periodic refresh actually pull
    /// a new value while still de-duping bursts (launch + currency change).
    private let staleAfter: TimeInterval = 10 * 60

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
