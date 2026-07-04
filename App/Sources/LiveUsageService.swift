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
        guard let (credential, planHint) = ClaudeCredential.resolve() else { return nil }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        credential.apply(to: &request)
        // Smallest request that returns the limit: the unified headers ride
        // only on successful /v1/messages responses (verified live — absent
        // from 400s, count_tokens, and the response body).
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": "claude-haiku-4-5",
            "max_tokens": 1,
            "messages": [["role": "user", "content": "hi"]],
        ])

        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let snapshot = Self.snapshot(fromHeadersOf: http, plan: planHint) else {
            BabysitterLog.process.info("live Claude usage unavailable")
            return nil
        }
        return snapshot
    }

    /// `anthropic-ratelimit-unified-5h-utilization` is a 0–1 fraction;
    /// `…-5h-reset` is epoch seconds.
    static func snapshot(fromHeadersOf http: HTTPURLResponse, plan: String?) -> UsageLimitSnapshot? {
        guard let text = http.value(forHTTPHeaderField: "anthropic-ratelimit-unified-5h-utilization"),
              let fraction = Double(text) else { return nil }
        let resets = http.value(forHTTPHeaderField: "anthropic-ratelimit-unified-5h-reset")
            .flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        return UsageLimitSnapshot(usedPercent: min(max(fraction * 100, 0), 100),
                                  windowMinutes: 300, resetsAt: resets,
                                  capturedAt: Date(), plan: plan ?? "subscription",
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

    /// Subscription OAuth sources first — only those reflect the 5h window.
    /// The desktop app doesn't log the CLI in, but its own claude process
    /// carries the token in env; reading env of the user's own processes is
    /// local and lets Live usage work on desktop-only machines. Returns the
    /// credential plus a plan hint when the source knows it ("pro"/"max").
    static func resolve() -> (ClaudeCredential, plan: String?)? {
        if let token = keychainOAuthToken() { return (.oauth(token), nil) }
        if let found = runningProcessOAuth() { return (.oauth(found.token), found.plan) }
        if let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty {
            return (.apiKey(key), nil)
        }
        return nil
    }

    private static func runningProcessOAuth() -> (token: String, plan: String?)? {
        guard let pids = shell("/usr/bin/pgrep", ["-x", "claude"]) else { return nil }
        for pid in pids.split(separator: "\n").prefix(8) {
            guard let env = shell("/bin/ps", ["eww", "-o", "command=", "-p", String(pid)]),
                  let token = envValue("CLAUDE_CODE_OAUTH_TOKEN", inProcessEnv: env),
                  token.count > 20 else { continue }
            return (token, envValue("CLAUDE_CODE_SUBSCRIPTION_TYPE", inProcessEnv: env))
        }
        return nil
    }

    /// `ps eww` output is the command line followed by space-separated
    /// VAR=value pairs; both values here are single tokens, so splitting on
    /// whitespace is safe.
    static func envValue(_ name: String, inProcessEnv output: String) -> String? {
        for word in output.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
            if word.hasPrefix("\(name)=") {
                let value = String(word.dropFirst(name.count + 1))
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    private static func shell(_ launchPath: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
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
