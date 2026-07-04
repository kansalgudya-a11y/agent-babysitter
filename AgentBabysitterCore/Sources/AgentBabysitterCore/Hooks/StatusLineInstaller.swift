import Foundation

/// Installs a tiny status-line helper into Claude Code's settings that
/// records each status update (which includes the subscription
/// `rate_limits.five_hour` numbers Claude Code already computes) into the
/// same event log the hook watcher tails. Zero network.
///
/// Non-destructive by the same contract as `HooksInstaller`: an existing
/// user status line is preserved — its exact configuration is backed up to a
/// sidecar file, and our wrapper pipes every update through the original
/// command so its output still renders. Disabling restores the original
/// exactly; unparseable settings abort before any write.
public enum StatusLineInstaller {

    public static let marker = "agent-babysitter-statusline-v1"

    public static let defaultBackupURL = HooksInstaller.defaultEventLogURL
        .deletingLastPathComponent()
        .appendingPathComponent("original-statusline.json")
    public static let defaultOriginalCommandURL = HooksInstaller.defaultEventLogURL
        .deletingLastPathComponent()
        .appendingPathComponent("original-statusline-command.sh")

    // MARK: - Pure transforms

    /// Returns (updated settings JSON, original statusLine object to back up,
    /// original command text to write for pass-through — nil when there was
    /// no original or it had no command).
    public static func settingsWithStatusLineInstalled(
        _ data: Data?,
        eventLogPath: String = HooksInstaller.defaultEventLogURL.path,
        originalCommandPath: String = defaultOriginalCommandURL.path
    ) throws -> (settings: Data, backup: Data?, originalCommand: String?) {
        var root = try parse(data)

        let existing = root["statusLine"] as? [String: Any]
        func wrapperCommand(passthrough: Bool) -> String {
            // Size-guarded like the hook command, so an orphaned install
            // can't grow the log unbounded; `|| true` keeps the status line
            // exiting clean when the guard skips the append.
            var command = "input=$(cat); umask 077; "
            + "[ \"$(stat -f%z '\(eventLogPath)' 2>/dev/null || echo 0)\" -lt \(HooksInstaller.maxLogBytesShell) ] "
            + "&& printf '%s\\n' \"$input\" >> '\(eventLogPath)' || true"
            if passthrough {
                command += "; printf '%s' \"$input\" | /bin/sh '\(originalCommandPath)'"
            }
            return command + " #\(marker)"
        }

        if let existing, let current = existing["command"] as? String, current.contains(marker) {
            // Ours already — upgrade the command in place when the template
            // changed, preserving whether it passes through to an original.
            let upgraded = wrapperCommand(passthrough: current.contains(originalCommandPath))
            if upgraded != current {
                var statusLine = existing
                statusLine["command"] = upgraded
                root["statusLine"] = statusLine
            }
            return (try serialize(root), nil, nil)
        }

        let originalCommand = existing?["command"] as? String
        let command = wrapperCommand(passthrough: originalCommand != nil)

        var statusLine = existing ?? [:]
        statusLine["type"] = "command"
        statusLine["command"] = command
        root["statusLine"] = statusLine

        let backup = existing.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        return (try serialize(root), backup, originalCommand)
    }

    /// Returns settings with our status line removed — restoring the backed
    /// up original when one exists, otherwise deleting the key. Foreign
    /// status lines are never touched.
    public static func settingsWithStatusLineRemoved(
        _ data: Data?, backup: Data?
    ) throws -> Data {
        var root = try parse(data)
        guard let current = root["statusLine"] as? [String: Any],
              (current["command"] as? String)?.contains(marker) == true else {
            return try serialize(root)  // not ours — leave alone
        }
        if let backup,
           let original = (try? JSONSerialization.jsonObject(with: backup)) as? [String: Any] {
            root["statusLine"] = original
        } else {
            root.removeValue(forKey: "statusLine")
        }
        return try serialize(root)
    }

    public static func isInstalled(in data: Data?) -> Bool {
        guard let data, let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains(marker)
    }

    // MARK: - File wrappers

    public static func install(settingsURL: URL = HooksInstaller.defaultSettingsURL,
                               eventLogPath: String = HooksInstaller.defaultEventLogURL.path,
                               backupURL: URL = defaultBackupURL,
                               originalCommandURL: URL = defaultOriginalCommandURL) throws {
        let current = try? Data(contentsOf: settingsURL)
        let result = try settingsWithStatusLineInstalled(
            current, eventLogPath: eventLogPath,
            originalCommandPath: originalCommandURL.path)
        let dir = backupURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let backup = result.backup {
            try backup.write(to: backupURL, options: .atomic)
        }
        if let original = result.originalCommand {
            try Data(original.utf8).write(to: originalCommandURL, options: .atomic)
        }
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try result.settings.write(to: settingsURL, options: .atomic)
        BabysitterLog.hooks.info("status line capture installed")
    }

    public static func uninstall(settingsURL: URL = HooksInstaller.defaultSettingsURL,
                                 backupURL: URL = defaultBackupURL,
                                 originalCommandURL: URL = defaultOriginalCommandURL) throws {
        guard let current = try? Data(contentsOf: settingsURL) else { return }
        let backup = try? Data(contentsOf: backupURL)
        let updated = try settingsWithStatusLineRemoved(current, backup: backup)
        try updated.write(to: settingsURL, options: .atomic)
        try? FileManager.default.removeItem(at: backupURL)
        try? FileManager.default.removeItem(at: originalCommandURL)
        BabysitterLog.hooks.info("status line capture removed")
    }

    // MARK: - Internals (shared contract with HooksInstaller)

    private static func parse(_ data: Data?) throws -> [String: Any] {
        guard let data, !data.isEmpty else { return [:] }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw HooksInstaller.SettingsError()
        }
        return root
    }

    private static func serialize(_ root: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: root,
                                   options: [.prettyPrinted, .sortedKeys])
    }
}
