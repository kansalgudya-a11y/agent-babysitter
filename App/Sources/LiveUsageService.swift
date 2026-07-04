import Foundation
import AgentBabysitterCore

/// Opt-in online usage fetcher. OFF by default — the app makes no network
/// calls unless the user enables "Live usage". Only ever talks to each
/// vendor's canonical host using the user's own existing credential, so a
/// token can never be sent anywhere unintended. Any failure (offline, no
/// credential, unexpected shape) yields nil and the row falls back to the
/// on-disk / "not shared" state; nothing crashes or blocks.
///
/// Claude Code: the subscription 5-hour window is returned inline in every
/// `/v1/messages` response as `rate_limits.five_hour.used_percentage`
/// (present for Pro/Max subscribers). We make one tiny 1-token request to
/// read it. Credential resolution mirrors the SDK: ANTHROPIC_API_KEY, then
/// the Claude Code CLI OAuth token in the keychain.
actor LiveUsageService {

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.httpShouldSetCookies = false
        session = URLSession(configuration: config)
    }

    /// Live snapshots per agent id. Empty when disabled or nothing resolved.
    func fetch(enabled: Bool) async -> [String: UsageLimitSnapshot] {
        guard enabled else { return [:] }
        var out: [String: UsageLimitSnapshot] = [:]
        if let claude = await fetchClaudeCode() {
            out["claude-code"] = claude
        }
        return out
    }

    // MARK: - Claude Code

    private func fetchClaudeCode() async -> UsageLimitSnapshot? {
        guard let credential = ClaudeCredential.resolve() else { return nil }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        credential.apply(to: &request)
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": "claude-haiku-4-5",
            "max_tokens": 1,
            "messages": [["role": "user", "content": "hi"]],
        ])

        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rateLimits = root["rate_limits"] as? [String: Any],
              let fiveHour = rateLimits["five_hour"] as? [String: Any],
              let usedPercent = fiveHour["used_percentage"] as? Double else {
            BabysitterLog.process.info("live Claude usage unavailable")
            return nil
        }
        let resets = (fiveHour["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
        return UsageLimitSnapshot(usedPercent: usedPercent, windowMinutes: 300,
                                  resetsAt: resets, capturedAt: Date(),
                                  plan: (root["model"] as? String).map { _ in "subscription" },
                                  isLive: true)
    }
}

/// A usable Claude credential, resolved without ever printing or storing it.
private enum ClaudeCredential {
    case apiKey(String)
    case oauth(String)

    func apply(to request: inout URLRequest) {
        switch self {
        case .apiKey(let key):
            request.setValue(key, forHTTPHeaderField: "x-api-key")
        case .oauth(let token):
            request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        }
    }

    static func resolve() -> ClaudeCredential? {
        if let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty {
            return .apiKey(key)
        }
        if let token = keychainOAuthToken() { return .oauth(token) }
        return nil
    }

    /// The Claude Code CLI stores its OAuth token in the login keychain under
    /// this service; read the access_token only.
    private static func keychainOAuthToken() -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else {
            _ = query.removeValue(forKey: kSecReturnData as String)
            return nil
        }
        return token
    }
}
