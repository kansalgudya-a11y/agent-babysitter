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
/// Known limitation (not yet addressed): even a successful activate brings the
/// owning app forward at the application level, not the specific window/tab —
/// a raise of the exact TTY-owning window would need the Accessibility API or a
/// scripting bridge, gated on a permission prompt. Tracked as future work.
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
}
