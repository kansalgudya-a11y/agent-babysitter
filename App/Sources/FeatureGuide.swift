import Foundation

/// The single source of truth for the welcome tour and "what's new".
///
/// MAINTENANCE CONTRACT: every user-visible feature gets one entry here,
/// tagged with the marketing version that shipped it. The tour renders all
/// of them; users who updated see NEW badges on entries newer than the
/// version they last viewed. Nothing else needs touching.
enum FeatureGuide {

    struct Tip: Identifiable {
        let version: String      // marketing version that introduced it
        let symbol: String       // SF Symbol
        let title: String
        let detail: String
        var id: String { title }
    }

    struct Section: Identifiable {
        let name: String
        let tips: [Tip]
        var id: String { name }
    }

    static let sections: [Section] = [
        Section(name: "Watching your agents", tips: [
            Tip(version: "0.1.0", symbol: "eye",
                title: "Every session, one glance",
                detail: "Claude Code, Codex, Antigravity, and Gemini — desktop apps, IDEs, and CLIs — appear here automatically the moment they run. No setup, ever."),
            Tip(version: "0.1.0", symbol: "circle.fill",
                title: "The dots tell the story",
                detail: "🟢 working · 🟡 needs you · 🔵 done · 🔴 maybe stuck · ⚫ ended. The menu bar shows the session that most needs attention, with a count."),
            Tip(version: "0.1.0", symbol: "cursorarrow.click.2",
                title: "Click a session to jump to it",
                detail: "Focuses the right terminal window or app. Right-click for the session log, copying the id, or hiding the row."),
            Tip(version: "0.5.0", symbol: "clock.badge.checkmark",
                title: "Finished sessions tidy themselves away",
                detail: "Done and ended sessions hide 10 minutes after their last activity (configurable in Settings, or never). Any new activity brings them right back."),
            Tip(version: "0.1.0", symbol: "gearshape",
                title: "Exact status from Claude Code",
                detail: "An optional toggle uses Claude's own notifications so \"needs you\" and \"done\" are exact instead of inferred. One reversible entry in Claude's settings — nothing else touched."),
        ]),
        Section(name: "Limits & forecasting", tips: [
            Tip(version: "0.2.0", symbol: "gauge.with.needle",
                title: "Real 5-hour limits, 0–100",
                detail: "Each agent's bar comes from its own data: Codex writes it to disk, Claude via the offline meter or opt-in live check, Antigravity from its synced account state. Never guessed."),
            Tip(version: "0.3.0", symbol: "chart.line.uptrend.xyaxis",
                title: "Pace forecasting",
                detail: "Readings age between turns, so stale numbers are corrected (\"≈9%\") — and when your pace will exhaust the window before it resets, the row warns you how early."),
            Tip(version: "0.3.0", symbol: "calendar",
                title: "Weekly windows too",
                detail: "\"week 23%\" under each bar where the agent publishes it, coloring up as it fills."),
            Tip(version: "0.2.0", symbol: "rectangle.expand.vertical",
                title: "Open apps by default, everything on demand",
                detail: "The limits list shows agents that are open right now; \"Show all\" expands to every installed agent with its last known reading."),
        ]),
        Section(name: "Notifications", tips: [
            Tip(version: "0.1.0", symbol: "bell",
                title: "Only what matters",
                detail: "An agent needs input, finished, or looks stuck — each its own toggle, all paused at once with the bell button."),
            Tip(version: "0.3.0", symbol: "text.bubble",
                title: "Banners you can act on",
                detail: "With exact status on, banners show the actual question (\"Claude needs permission to use Bash\") and what a finished turn said — plus a 10-minute snooze button."),
            Tip(version: "0.2.0", symbol: "exclamationmark.triangle",
                title: "Limit alerts",
                detail: "One heads-up per window when usage crosses your threshold (default 80%), so a long task can't silently burn the whole window. The menu bar shows ⚠️ at 90%+."),
        ]),
        Section(name: "Power tools", tips: [
            Tip(version: "0.3.0", symbol: "keyboard",
                title: "⌥⌘B from anywhere",
                detail: "Jumps straight to the session that most needs you — waiting first, then stuck, then working."),
            Tip(version: "0.3.0", symbol: "menubar.rectangle",
                title: "Your menu bar, your choice",
                detail: "Show status + count, today's cost, or the hottest limit % — pick in Settings → General."),
            Tip(version: "0.3.2", symbol: "chart.bar",
                title: "Stats: today, week, 3 months, all time",
                detail: "How long your agents worked while you did other things, sessions watched, and cost per agent — accumulating from the day you installed."),
            Tip(version: "0.5.1", symbol: "square.and.arrow.up",
                title: "Export your stats",
                detail: "Every recorded day as CSV — date, cost, active minutes, sessions, per-agent dollars — from the stats window. Pick your hotkey chord in Settings too."),
            Tip(version: "0.1.0", symbol: "dollarsign.circle",
                title: "Honest cost estimates",
                detail: "Computed from token usage at API list prices. On a subscription it's not an extra charge — it shows the value of your usage. Unknown models show tokens, never guessed dollars."),
        ]),
        Section(name: "Private by design", tips: [
            Tip(version: "0.1.0", symbol: "lock.shield",
                title: "Everything runs on your Mac",
                detail: "The app reads your agents' own files and collects nothing. The only network features — live Claude usage, license activation, update check — are opt-in, labeled, and single-purpose."),
        ]),
    ]

    static var allTips: [Tip] { sections.flatMap(\.tips) }

    /// Tips introduced after the given version (numeric compare).
    static func tipsNewer(than version: String) -> [Tip] {
        allTips.filter { $0.version.compare(version, options: .numeric) == .orderedDescending }
    }
}
