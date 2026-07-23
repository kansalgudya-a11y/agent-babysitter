import Foundation
import AgentBabysitterCore

/// Opt-in online usage fetcher. OFF by default — the app makes no network
/// calls unless the user enables "Live usage". Only ever talks to each
/// vendor's canonical host using the user's own existing credential, so a
/// token can never be sent anywhere unintended. Any failure (offline, no
/// credential, unexpected shape) yields a reason string instead of data —
/// shown in Settings so the toggle never fails silently.
///
/// Claude Code: the subscription windows ride on the response headers of a
/// successful `/v1/messages` call (`anthropic-ratelimit-unified-*`), so the
/// probe is the smallest valid request — one haiku token. That token counts
/// against the very quota being measured (disclosed in the toggle copy).
///
/// Durability note (honest): the Cursor and Manus reads replay the login
/// token each vendor already stored on this Mac against that vendor's own
/// private, undocumented dashboard/RPC endpoint. The vendors have not
/// sanctioned this use, and any of them can change shape or auth in a routine
/// release — at which point that agent's reading goes unavailable. Failures
/// here become a reason string (returned for the Claude probe, logged for the
/// others). Rendering a per-agent "reading unavailable — format changed"
/// state instead of a blank, and disclosing this in the tour/Settings copy,
/// live outside this file (menu + preferences). Keep every reading opt-in.
actor LiveUsageService {

    enum Outcome {
        case snapshot(UsageLimitSnapshot)
        case unavailable(reason: String)
    }

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.httpShouldSetCookies = false
        session = URLSession(configuration: config)
    }

    /// Live snapshots per agent id, plus a user-readable reason when a
    /// fetch produced nothing. `agents` limits which vendors are asked —
    /// the Claude probe costs a token, so it only runs while Claude is
    /// actually in use.
    func fetch(enabled: Bool,
               agents: Set<String> = ["claude-code", "cursor", "manus"]) async
        -> (limits: [String: UsageLimitSnapshot], failure: String?) {
        guard enabled else { return ([:], nil) }
        var limits: [String: UsageLimitSnapshot] = [:]
        var failure: String?
        if agents.contains("claude-code") {
            switch await fetchClaudeCode() {
            case .snapshot(let snapshot):
                limits["claude-code"] = snapshot
            case .unavailable(let reason):
                BabysitterLog.process.info("live Claude usage unavailable: \(reason, privacy: .public)")
                failure = reason
            }
        }
        // Cursor and Manus ride the same toggle; each skipped silently when
        // not installed or not logged in (nothing to fetch with).
        if agents.contains("cursor"), let outcome = await fetchCursor() {
            if case .snapshot(let snapshot) = outcome { limits["cursor"] = snapshot }
            else if case .unavailable(let reason) = outcome {
                BabysitterLog.process.info("live Cursor usage unavailable: \(reason, privacy: .public)")
            }
        }
        if agents.contains("manus"), let outcome = await fetchManus() {
            if case .snapshot(let snapshot) = outcome { limits["manus"] = snapshot }
            else if case .unavailable(let reason) = outcome {
                BabysitterLog.process.info("live Manus usage unavailable: \(reason, privacy: .public)")
            }
        }
        return (limits, failure)
    }

    // MARK: - Cursor

    /// Cursor's own dashboard endpoint, authenticated with the session token
    /// Cursor already stores on this Mac (`cursorAuth/accessToken`). Verified
    /// live: `POST /api/usage-summary` returns the "Included Usage NN%" and
    /// billing-cycle reset the Cursor app itself shows. nil = Cursor
    /// absent/logged out; not an error worth surfacing.
    private func fetchCursor() async -> Outcome? {
        let adapter = CursorAdapter()
        guard FileManager.default.fileExists(atPath: adapter.stateDBURL.path),
              let token = adapter.storedAccessToken(),
              let userID = CursorUsageParsing.userID(fromSessionJWT: token) else { return nil }
        var request = URLRequest(url: URL(string: "https://cursor.com/api/usage-summary")!)
        request.httpMethod = "POST"
        request.setValue("WorkosCursorSessionToken=\(userID)%3A%3A\(token)",
                         forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The endpoint rejects requests without a matching origin.
        request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        request.httpBody = Data("{}".utf8)
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            return .unavailable(reason: "cursor.com didn't answer — connection or expired login")
        }
        guard let snapshot = CursorUsageParsing.snapshot(fromSummaryJSON: data) else {
            return .unavailable(reason: "cursor.com answered with an unrecognized shape")
        }
        return .snapshot(snapshot)
    }

    /// Manus's credit balance via its Connect-RPC endpoint, authenticated
    /// with the `session_id` JWT Manus already stores on this Mac (it's the
    /// Bearer token the app itself sends). Verified live against
    /// `user.v1.UserService/GetAvailableCredits`. nil = Manus absent/logged
    /// out. Only ever contacts api.manus.im.
    private func fetchManus() async -> Outcome? {
        let adapter = ManusAdapter()
        guard let token = adapter.storedSessionToken() else { return nil }
        func post(_ path: String) async -> Data? {
            var request = URLRequest(url: URL(string: "https://api.manus.im/\(path)")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
            request.setValue("desktop", forHTTPHeaderField: "x-client-type")
            request.httpBody = Data("{}".utf8)
            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return data
        }
        guard let creditsData = await post("user.v1.UserService/GetAvailableCredits") else {
            return .unavailable(reason: "api.manus.im didn't answer — connection or expired login")
        }
        // Plan tier is a bonus; the credits snapshot stands without it.
        var plan: String?
        if let infoData = await post("user.v1.UserService/UserInfo"),
           let info = (try? JSONSerialization.jsonObject(with: infoData)) as? [String: Any] {
            plan = info["membershipVersion"] as? String
        }
        guard let snapshot = ManusUsageParsing.snapshot(fromJSON: creditsData, plan: plan) else {
            return .unavailable(reason: "api.manus.im answered with an unrecognized shape")
        }
        return .snapshot(snapshot)
    }

    // MARK: - Claude Code

    private func fetchClaudeCode() async -> Outcome {
        guard let (credential, planHint) = ClaudeCredential.resolve() else {
            return .unavailable(reason: "No Claude login found. Open the Claude app, "
                + "or run /login in the claude CLI, then try again.")
        }
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

        guard let (_, response) = try? await session.data(for: request) else {
            return .unavailable(reason: "Couldn't reach api.anthropic.com — check your connection.")
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            return .unavailable(reason: "Anthropic returned an error (\(code)). "
                + "Your login may have expired — open the Claude app once and retry.")
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        guard let snapshot = ClaudeLiveParsing.snapshot(fromHeaders: headers, plan: planHint) else {
            return .unavailable(reason: "The response had no usage headers — "
                + "these appear for Pro/Max subscriptions only.")
        }
        return .snapshot(snapshot)
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

    /// Order is deliberate, and the running-process path is a known, bounded
    /// secret surface we keep on purpose. The running `claude` process carries
    /// both the OAuth token AND the subscription tier in its environment, so
    /// it is tried first: it needs no keychain prompt, and it is the only
    /// source that yields the plan label — the keychain item (below) holds the
    /// token but not the tier, so preferring it would degrade the menu's
    /// "pro"/"max" caption to a generic "subscription" (Core falls back to that
    /// when plan is nil; verified in ClaudeLiveParsing.snapshot). macOS exposes
    /// no way to read a single environment variable of another process, so
    /// `runningProcessOAuth` unavoidably reads the whole environment of the
    /// user's own `claude` processes — but nothing is transmitted, written, or
    /// retained beyond extracting the two values, and only the user's own
    /// processes are scanned. The keychain item is the no-env fallback (a
    /// one-time macOS prompt); an API key is last (authenticates, but usually
    /// publishes no subscription windows).
    static func resolve() -> (ClaudeCredential, plan: String?)? {
        if let found = runningProcessOAuth() { return (.oauth(found.token), found.plan) }
        if let token = keychainOAuthToken() { return (.oauth(token), nil) }
        if let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty {
            return (.apiKey(key), nil)
        }
        return nil
    }

    private static func runningProcessOAuth() -> (token: String, plan: String?)? {
        guard let pids = shell("/usr/bin/pgrep", ["-x", "claude"]) else { return nil }
        for pid in pids.split(separator: "\n").prefix(8) {
            guard let env = shell("/bin/ps", ["eww", "-o", "command=", "-p", String(pid)]),
                  let token = ClaudeLiveParsing.envValue("CLAUDE_CODE_OAUTH_TOKEN",
                                                         inProcessEnv: env),
                  token.count > 20 else { continue }
            return (token, ClaudeLiveParsing.envValue("CLAUDE_CODE_SUBSCRIPTION_TYPE",
                                                      inProcessEnv: env))
        }
        return nil
    }

    /// The Claude Code CLI stores its OAuth token in the login keychain under
    /// this service; read the access_token only.
    private static func keychainOAuthToken() -> String? {
        let query: [String: Any] = [
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
            return nil
        }
        return token
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
}
