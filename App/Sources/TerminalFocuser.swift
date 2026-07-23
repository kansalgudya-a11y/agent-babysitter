import AppKit
import AgentBabysitterCore

/// Brings the app owning a session to the front. Desktop-app sessions activate
/// the agent's own app directly; terminal sessions walk the session process's
/// ancestors until one of them is a real application
/// (claude → zsh → login → iTerm2).
///
/// When neither path can tie the session to a running app, `focusSession`
/// returns `false` and does nothing — it deliberately does NOT front an
/// arbitrary terminal. A blind "activate the first terminal in a fixed list"
/// fallback used to send the user to the wrong window (often a terminal that
/// never ran the session) with no way to tell the app had guessed; degrading
/// to an honest no-op, and letting the caller say "couldn't locate it", is
/// strictly better than teleporting the user somewhere unrelated.
///
/// F9 tier a: when Core captured the session's controlling tty and the owning
/// app is a scriptable terminal (Apple Terminal or iTerm2), `focusSession`
/// first raises the exact tab/window that owns that tty via AppleScript, and
/// only falls back to application-level activation when that can't be done
/// (unknown terminal, no tty, Automation permission denied, or no matching
/// tab). The scripts SELECT a tab and never type into it — no stdin injection.
@MainActor
enum TerminalFocuser {

    static let claudeDesktopBundleID = "com.anthropic.claudefordesktop"

    /// Per-agent desktop apps, tried first for desktop-hosted sessions.
    static let agentBundleIDs: [String: [String]] = [
        "claude-code": [claudeDesktopBundleID],
        "codex": ["com.openai.codex"],
        "hermes": ["com.nousresearch.hermes", "com.nousresearch.hermes.setup"],
        // OpenClaw ships no macOS .app (CLI-only, like antigravity-cli/gemini-cli),
        // so it gets no entry — focus falls back to the session's process ancestry.
        "antigravity": ["com.google.antigravity"],
        "antigravity-ide": ["com.google.antigravity-ide"],
        "gemini": ["com.google.GeminiMacOS"],
        "cursor": ["com.todesktop.230313mzl4w4u92"],
        "manus": ["im.manus.desktop"],
    ]

    /// Front the app owning `row`. Returns `true` when a specific owning app was
    /// found and activated, `false` when the session could not be tied to any
    /// running app (nothing is fronted). Callers should surface the `false` case
    /// ("couldn't find that session's window") rather than leave the click
    /// looking ignored.
    @discardableResult
    static func focusSession(_ row: SessionRow) -> Bool {
        if row.isDesktopApp {
            for bundleID in agentBundleIDs[row.agentID] ?? [] where activate(bundleID: bundleID) {
                return true
            }
        }
        if let pid = row.pid {
            // The session's own process first: for desktop-app agents the
            // matched pid IS the app, so this focuses correctly even for
            // agents with no bundle-id mapping.
            for ancestor in [pid] + ProcessAncestry.ancestorPIDs(of: pid) {
                if let app = NSRunningApplication(processIdentifier: ancestor),
                   app.activationPolicy == .regular {
                    // F9 tier a: this GUI ancestor is the terminal (or app)
                    // hosting the session. If it's a terminal we can script and
                    // Core captured the session's tty, raise that exact tab
                    // first; the terminal is already running (it's an ancestor
                    // of the live pid) so the `tell` block can't spawn a new
                    // one. Any failure degrades to app-level activation below.
                    if let bundleID = app.bundleIdentifier, let tty = row.tty,
                       selectTab(inTerminal: bundleID, tty: tty) {
                        return true
                    }
                    app.activate()
                    return true
                }
            }
        }
        // Could not identify the owning app (no desktop match, and either no pid
        // — a finished session — or its ancestry holds no GUI app). Do NOT front
        // a random terminal: that guess is wrong more often than right and gives
        // the user no signal it happened. Report failure and let the caller say so.
        return false
    }

    @discardableResult
    private static func activate(bundleID: String) -> Bool {
        guard let app = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == bundleID }) else { return false }
        app.activate()
        return true
    }

    // MARK: - F9 tier a: TTY-targeted tab selection

    /// AppleScript, per scriptable terminal, that raises the tab/window whose
    /// controlling terminal owns `<TTY>`. Core captures the device in `ps`'s
    /// bare form (`ttys001`); Terminal.app and iTerm2 report the full
    /// `/dev/ttys001`, so the scripts match on the SUFFIX (`ends with`) rather
    /// than on equality. Each match is wrapped in `try` so a window/tab that
    /// refuses to report a tty (busy, closing) is skipped instead of aborting
    /// the scan, and the script returns the literal `found` only when it both
    /// located AND selected the tab. Terminals not listed here are never
    /// scripted — the caller falls back to plain application activation. The
    /// scripts only SELECT; they never send keystrokes (no stdin injection).
    private static let tabSelectScripts: [String: String] = [
        "com.apple.Terminal": """
        tell application "Terminal"
          repeat with w in windows
            repeat with t in tabs of w
              try
                if (tty of t) ends with "<TTY>" then
                  set selected of t to true
                  try
                    set frontmost of w to true
                  end try
                  activate
                  return "found"
                end if
              end try
            end repeat
          end repeat
        end tell
        """,
        "com.googlecode.iterm2": """
        tell application "iTerm2"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                try
                  if (tty of s) ends with "<TTY>" then
                    tell w to select
                    tell t to select
                    tell s to select
                    activate
                    return "found"
                  end if
                end try
              end repeat
            end repeat
          end repeat
        end tell
        """,
    ]

    /// Raise the tab whose controlling tty ends with `tty` inside the scriptable
    /// terminal `bundleID`. Returns true ONLY when the AppleScript ran without
    /// error and reported it found the tab; false for an unknown terminal, a
    /// malformed tty, a denied Automation permission, or no matching tab — so
    /// the caller degrades to app-level activation instead of a dead click.
    private static func selectTab(inTerminal bundleID: String, tty: String) -> Bool {
        guard let template = tabSelectScripts[bundleID] else { return false }
        // Defence in depth: the tty originates from `ps` and is expected to be a
        // bare device token (`ttys001`, `console`). Strip a `/dev/` prefix if a
        // future capture format adds one, then refuse anything that isn't purely
        // alphanumeric so it can never break out of the AppleScript string
        // literal and turn tab selection into script injection.
        let token = tty.hasPrefix("/dev/") ? String(tty.dropFirst("/dev/".count)) : tty
        guard !token.isEmpty, token.allSatisfy({ $0.isLetter || $0.isNumber }) else { return false }
        let source = template.replacingOccurrences(of: "<TTY>", with: token)
        guard let script = NSAppleScript(source: source) else { return false }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        // A non-nil error dict means the terminal isn't scriptable, Automation
        // was denied, or the script raised — all "couldn't target the tab".
        guard errorInfo == nil else { return false }
        return result.stringValue == "found"
    }
}
