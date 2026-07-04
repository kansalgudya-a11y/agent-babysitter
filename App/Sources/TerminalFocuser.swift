import AppKit
import AgentBabysitterCore

/// Brings the window owning a session to the front. Desktop-app sessions
/// activate the Claude app directly; terminal sessions walk the session
/// process's ancestors until one of them is a real application
/// (claude → zsh → login → iTerm2); unknown owners fall back to the first
/// running terminal in preference order.
@MainActor
enum TerminalFocuser {

    static let claudeDesktopBundleID = "com.anthropic.claudefordesktop"

    /// Preference order for the fallback when no ancestor is an app.
    static let terminalBundleIDs = [
        "com.googlecode.iterm2",
        "com.apple.Terminal",
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "io.alacritty",
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92",  // Cursor
        claudeDesktopBundleID,
        "com.openai.codex",
    ]

    /// Per-agent desktop apps, tried first for desktop-hosted sessions.
    static let agentBundleIDs: [String: [String]] = [
        "claude-code": ["com.anthropic.claudefordesktop"],
        "codex": ["com.openai.codex"],
        "antigravity": ["com.google.antigravity"],
        "antigravity-ide": ["com.google.antigravity-ide"],
    ]

    static func focusSession(_ row: SessionRow) {
        if row.isDesktopApp {
            for bundleID in agentBundleIDs[row.agentID] ?? [] where activate(bundleID: bundleID) {
                return
            }
        }
        if let pid = row.pid {
            for ancestor in ProcessAncestry.ancestorPIDs(of: pid) {
                if let app = NSRunningApplication(processIdentifier: ancestor),
                   app.activationPolicy == .regular {
                    app.activate()
                    return
                }
            }
        }
        focusAnyTerminal()
    }

    @discardableResult
    private static func activate(bundleID: String) -> Bool {
        guard let app = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == bundleID }) else { return false }
        app.activate()
        return true
    }

    private static func focusAnyTerminal() {
        for bundleID in terminalBundleIDs where activate(bundleID: bundleID) {
            return
        }
    }
}
