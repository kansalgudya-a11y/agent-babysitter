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

    public static let defaultEventLogURL = PlatformPaths.applicationSupport("AgentBabysitter/events.jsonl")

    /// PreToolUse fires when a tool starts EXECUTING (after any permission
    /// approval), which is what lets the app tell "waiting on a prompt" from
    /// "running a long build". Installed idempotently at every launch, so
    /// existing installs pick new events up automatically.
    private static let hookEvents = ["Notification", "Stop", "PreToolUse"]

    /// 5MB, mirrored by the watcher's cap. The guard lives in the shell so
    /// an orphaned install (app quit or deleted with the toggle on) can't
    /// grow the log unbounded — appends just stop until the app truncates.
    static let maxLogBytesShell = "5242880"

    private static func hookCommand(event: String, eventLogPath: String) -> String {
        // Hook stdin carries one single-line JSON event (file-drop transport,
        // no sockets). Shared shell: umask keeps a freshly created log private;
        // the size guard lives in the shell so an orphaned install (app quit or
        // deleted with the toggle on) can't grow the log unbounded — appends
        // just stop until the app truncates. The log directory is created once
        // at install time (and re-created at every launch), so the per-call hot
        // path no longer spawns `mkdir`/`dirname`. The trailing comment is the
        // removal marker.
        let sizeGuard =
            "[ \"$(stat -f%z '\(eventLogPath)' 2>/dev/null || echo 0)\" -lt \(maxLogBytesShell) ]"
        let writer: String
        if event == "PreToolUse" {
            // PreToolUse fires on EVERY tool call and its payload is the only
            // one carrying `tool_input` — the raw shell command lines and file
            // contents the app never reads. It consumes only session_id +
            // tool_name from this event (verified: hook payloads carry no
            // rate_limits — that arrives via the status-line writer), so awk
            // reconstructs a minimal line and none of the verbatim payload ever
            // reaches disk. awk reads stdin to EOF — draining it so the writer
            // never sees a broken pipe — and appends via its own redirection,
            // so a missing log directory degrades to a silent no-op rather than
            // an unwritten, undrained call.
            writer = "awk '\(preToolUseAwk(eventLogPath: eventLogPath))' 2>/dev/null"
        } else {
            // Notification/Stop are infrequent and carry no `tool_input`; their
            // message / last_assistant_message text IS consumed, so append the
            // event verbatim. `echo` terminates the line; the else-branch drains
            // stdin so a capped log still never breaks the writer's pipe.
            writer = "{ cat; echo; } >> '\(eventLogPath)'"
        }
        return "umask 077; if \(sizeGuard); then \(writer); else cat >/dev/null; fi #\(marker)"
    }

    /// awk program (single-quoted inside the hook shell) that extracts only
    /// `session_id` and `tool_name` from a PreToolUse payload and appends a
    /// minimal JSON line — never `tool_input`. `\42` is the double-quote
    /// character; the octal escape keeps emitted quotes clear of the enclosing
    /// shell and Swift quoting. First-match is correct because both fields
    /// serialize before `tool_input` in Claude Code's payload and no observed
    /// `tool_input` value carries a look-alike key; a line without a session_id
    /// prints nothing and the parser skips it.
    private static func preToolUseAwk(eventLogPath: String) -> String {
        "match($0,/\"session_id\"[ \\t]*:[ \\t]*\"[^\"]*\"/){s=substr($0,RSTART,RLENGTH);sub(/^\"session_id\"[ \\t]*:[ \\t]*\"/,\"\",s);sub(/\"$/,\"\",s)}"
        + " match($0,/\"tool_name\"[ \\t]*:[ \\t]*\"[^\"]*\"/){t=substr($0,RSTART,RLENGTH);sub(/^\"tool_name\"[ \\t]*:[ \\t]*\"/,\"\",t);sub(/\"$/,\"\",t)}"
        + " END{if(s!=\"\")printf(\"{\\42hook_event_name\\42:\\42PreToolUse\\42,\\42session_id\\42:\\42%s\\42,\\42tool_name\\42:\\42%s\\42}\\n\",s,t) >> \"\(eventLogPath)\"}"
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

        for event in hookEvents {
            // The command differs per event (PreToolUse is minimised), so it is
            // computed here — both to append fresh entries and to upgrade ours
            // in place when the template changed since it was installed.
            let command = hookCommand(event: event, eventLogPath: eventLogPath)
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

    public static let defaultSettingsURL = PlatformPaths.homeDirectory(".claude/settings.json")

    public static func install(settingsURL: URL = defaultSettingsURL,
                               eventLogPath: String = defaultEventLogURL.path) throws {
        // Create the event-log directory once, here, so the per-tool-call hook
        // never has to spawn `mkdir`/`dirname` on its hot path.
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: eventLogPath).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try rewriteSettings(at: settingsURL) {
            try settingsWithHooksInstalled($0, eventLogPath: eventLogPath)
        }
    }

    public static func uninstall(settingsURL: URL = defaultSettingsURL) throws {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return }
        try rewriteSettings(at: settingsURL) {
            try settingsWithHooksRemoved($0)
        }
    }

    /// Read → transform → write, re-reading the file immediately before the
    /// write and rebasing onto any concurrent edit. Claude Code writes the same
    /// `settings.json` (permission grants, model, etc.); a naive read-then-write
    /// clobbers whatever it wrote in between, so a permission the user just
    /// changed would vanish. If the on-disk bytes changed since we read them we
    /// re-apply the transform to the newer copy instead. The transform is
    /// idempotent (it keys off `marker`), so rebasing preserves both edits. A
    /// residual TOCTOU window remains — nothing short of file locking, which
    /// Claude Code doesn't participate in, can close it — but the common race is
    /// narrowed to microseconds and the lost-edit case is avoided.
    private static func rewriteSettings(at url: URL,
                                        _ transform: (Data?) throws -> Data) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var baseline = try? Data(contentsOf: url)
        for _ in 0..<4 {
            let updated = try transform(baseline)
            let latest = try? Data(contentsOf: url)
            guard latest == baseline else {   // concurrent writer — rebase and retry
                baseline = latest
                continue
            }
            try updated.write(to: url, options: .atomic)
            return
        }
        // Persistent concurrent writer: apply once onto the latest content so we
        // still make progress rather than spinning.
        try transform(try? Data(contentsOf: url)).write(to: url, options: .atomic)
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
        public let signal: (sessionID: String, kind: HookSignal.Kind, detail: String?)?
        public let usage: UsageLimitSnapshot?
    }

    public static func parse(line: Data) -> Event? {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            return nil
        }

        var signal: (String, HookSignal.Kind, String?)?
        if let sessionID = object["session_id"] as? String {
            switch object["hook_event_name"] as? String {
            case "Notification":
                signal = (sessionID, .waitingForInput, detail(object["message"]))
            case "Stop":
                signal = (sessionID, .turnCompleted, detail(object["last_assistant_message"]))
            case "PreToolUse":
                signal = (sessionID, .toolStarted, detail(object["tool_name"]))
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

    /// First line, trimmed, capped — notification banners are one-liners.
    private static func detail(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let firstLine = text.split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !firstLine.isEmpty else { return nil }
        return firstLine.count > 120 ? String(firstLine.prefix(117)) + "…" : firstLine
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
