import Foundation

/// Merges Agent Babysitter's Notification/Stop hooks into Claude Code's
/// `~/.claude/settings.json` — Precision mode's exact waiting/done signals.
///
/// Non-destructive by contract: user hooks and settings are never touched,
/// our entries are identified by a marker in the command string, removal
/// strips only ours, and unparseable settings abort with an error before
/// anything is written.
public enum HooksInstaller {

    public struct SettingsError: Error, LocalizedError {
        public var errorDescription: String? {
            "~/.claude/settings.json could not be parsed. Nothing was changed — "
            + "fix or remove the file and try again."
        }
    }

    /// Identifies our hook entries inside settings.json.
    public static let marker = "agent-babysitter-hook-v1"

    public static let defaultEventLogURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AgentBabysitter/events.jsonl")

    private static let hookEvents = ["Notification", "Stop"]

    /// 5MB, mirrored by the watcher's cap. The guard lives in the shell so
    /// an orphaned install (app quit or deleted with the toggle on) can't
    /// grow the log unbounded — appends just stop until the app truncates.
    static let maxLogBytesShell = "5242880"

    private static func hookCommand(eventLogPath: String) -> String {
        // Hook stdin carries one JSON event; append it as a line to the event
        // log (file-drop transport, no sockets). umask keeps a freshly
        // created log private; stdin is always drained so the writer never
        // sees a broken pipe. The trailing comment is the removal marker.
        "umask 077; mkdir -p \"$(dirname '\(eventLogPath)')\"; "
        + "if [ \"$(stat -f%z '\(eventLogPath)' 2>/dev/null || echo 0)\" -lt \(maxLogBytesShell) ]; "
        + "then { cat; echo; } >> '\(eventLogPath)'; else cat >/dev/null; fi #\(marker)"
    }

    // MARK: - Pure transforms (testable without touching the filesystem)

    /// Returns settings JSON with our hooks merged in. `nil`/empty input is a
    /// fresh settings file. Throws on unparseable input — callers must not
    /// write anything in that case.
    public static func settingsWithHooksInstalled(
        _ data: Data?,
        eventLogPath: String = defaultEventLogURL.path
    ) throws -> Data {
        var root = try parse(data)
        var hooks = root["hooks"] as? [String: Any] ?? [:]

        let command = hookCommand(eventLogPath: eventLogPath)
        for event in hookEvents {
            var entries = hooks[event] as? [[String: Any]] ?? []
            if entries.contains(where: isOurs) {
                // Upgrade our entry in place when the command template has
                // changed since it was installed; never touch other entries.
                entries = entries.map { entry in
                    guard isOurs(entry), var inner = entry["hooks"] as? [[String: Any]] else {
                        return entry
                    }
                    inner = inner.map { hook in
                        guard (hook["command"] as? String)?.contains(marker) == true else {
                            return hook
                        }
                        var hook = hook
                        hook["command"] = command
                        return hook
                    }
                    var entry = entry
                    entry["hooks"] = inner
                    return entry
                }
            } else {
                entries.append(["hooks": [["type": "command", "command": command]]])
            }
            hooks[event] = entries
        }
        root["hooks"] = hooks
        return try serialize(root)
    }

    /// Returns settings JSON with only our hooks removed.
    public static func settingsWithHooksRemoved(_ data: Data?) throws -> Data {
        var root = try parse(data)
        guard var hooks = root["hooks"] as? [String: Any] else {
            return try serialize(root)
        }
        for event in hookEvents {
            guard let entries = hooks[event] as? [[String: Any]] else { continue }
            let kept = entries.compactMap { entry -> [String: Any]? in
                guard var inner = entry["hooks"] as? [[String: Any]] else { return entry }
                inner.removeAll { ($0["command"] as? String)?.contains(marker) == true }
                guard !inner.isEmpty else { return nil }
                var entry = entry
                entry["hooks"] = inner
                return entry
            }
            if kept.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = kept
            }
        }
        root["hooks"] = hooks
        return try serialize(root)
    }

    public static func isInstalled(in data: Data?) -> Bool {
        guard let data, let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains(marker)
    }

    // MARK: - File wrappers

    public static let defaultSettingsURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/settings.json")

    public static func install(settingsURL: URL = defaultSettingsURL,
                               eventLogPath: String = defaultEventLogURL.path) throws {
        let current = try? Data(contentsOf: settingsURL)
        let updated = try settingsWithHooksInstalled(current, eventLogPath: eventLogPath)
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try updated.write(to: settingsURL, options: .atomic)
    }

    public static func uninstall(settingsURL: URL = defaultSettingsURL) throws {
        guard let current = try? Data(contentsOf: settingsURL) else { return }
        let updated = try settingsWithHooksRemoved(current)
        try updated.write(to: settingsURL, options: .atomic)
    }

    // MARK: - Internals

    private static func isOurs(_ entry: [String: Any]) -> Bool {
        (entry["hooks"] as? [[String: Any]] ?? [])
            .contains { ($0["command"] as? String)?.contains(marker) == true }
    }

    private static func parse(_ data: Data?) throws -> [String: Any] {
        guard let data, !data.isEmpty else { return [:] }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw SettingsError()
        }
        return root
    }

    private static func serialize(_ root: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: root,
                                   options: [.prettyPrinted, .sortedKeys])
    }
}

/// Parses one line of the event log. Hook events and status-line updates
/// share the log; a hook line carries `hook_event_name`, a status-line line
/// doesn't, and either may carry `rate_limits` — Claude Code includes the
/// subscription 5-hour window in both payloads, which is how the app shows a
/// real usage % with zero network.
public enum HookEventParser {

    public struct Event {
        public let signal: (sessionID: String, kind: HookSignal.Kind)?
        public let usage: UsageLimitSnapshot?
    }

    public static func parse(line: Data) -> Event? {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            return nil
        }

        var signal: (String, HookSignal.Kind)?
        if let sessionID = object["session_id"] as? String {
            switch object["hook_event_name"] as? String {
            case "Notification": signal = (sessionID, .waitingForInput)
            case "Stop": signal = (sessionID, .turnCompleted)
            default: break
            }
        }

        let usage = usageSnapshot(from: object)
        guard signal != nil || usage != nil else { return nil }
        return Event(signal: signal, usage: usage)
    }

    /// `rate_limits.five_hour` (plus `seven_day` when present) as Claude Code
    /// emits them: `used_percentage` 0–100 plus an ISO-8601 or epoch `resets_at`.
    static func usageSnapshot(from object: [String: Any]) -> UsageLimitSnapshot? {
        guard let rateLimits = object["rate_limits"] as? [String: Any],
              let fiveHour = rateLimits["five_hour"] as? [String: Any],
              let usedPercent = doubleValue(fiveHour["used_percentage"]) else {
            return nil
        }
        let sevenDay = rateLimits["seven_day"] as? [String: Any]
        return UsageLimitSnapshot(usedPercent: min(max(usedPercent, 0), 100),
                                  windowMinutes: 300,
                                  resetsAt: date(from: fiveHour["resets_at"]),
                                  capturedAt: Date(),
                                  plan: "subscription",
                                  weeklyUsedPercent: sevenDay.flatMap { doubleValue($0["used_percentage"]) }
                                      .map { min(max($0, 0), 100) },
                                  weeklyResetsAt: sevenDay.flatMap { date(from: $0["resets_at"]) })
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        return nil
    }

    private static func date(from value: Any?) -> Date? {
        if let epoch = doubleValue(value) { return Date(timeIntervalSince1970: epoch) }
        if let text = value as? String {
            return ISO8601DateFormatter().date(from: text)
                ?? {
                    let f = ISO8601DateFormatter()
                    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    return f.date(from: text)
                }()
        }
        return nil
    }
}
