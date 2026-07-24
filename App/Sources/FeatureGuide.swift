import Foundation

/// The single source of truth for the welcome tour and "what's new".
///
/// MAINTENANCE CONTRACT: every user-visible feature gets one entry here,
/// tagged with the marketing version that shipped it. The tour renders all
/// of them; users who updated see NEW badges on entries newer than the
/// version they last viewed. Nothing else needs touching.
///
/// The versions below are the real release tags (project.yml MARKETING_VERSION
/// reached 0.11.3); each 0.7.0–0.11.3 entry describes a feature that actually
/// shipped in that release — traced to the commit that landed it, never
/// invented. Before this backfill the newest tip was 0.6.0, so an updater on
/// 0.11.x saw no "what's new" at all; every entry after 0.6.0 here is what
/// closed that five-release gap.
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
            Tip(version: "0.6.0", symbol: "plus.app",
                title: "Cursor and Manus join the family",
                detail: "Cursor's agent (composer) sessions and Manus desktop tasks are watched too — same dots, same click-to-jump, still zero setup."),
            Tip(version: "0.1.0", symbol: "circle.fill",
                title: "The dots tell the story",
                detail: "🟢 working · 🟡 needs you · 🔵 done · 🔴 maybe stuck · ⚫ ended. The menu bar shows the session that most needs attention, with a count."),
            Tip(version: "0.1.0", symbol: "cursorarrow.click.2",
                title: "Click a session to jump to it",
                detail: "Focuses the right terminal window or app. Right-click for the session log, copying the id, or hiding the row."),
            // 0.8.0 shipped session titles (commit 6db1735) — the row's
            // `title` is the user's last real prompt, one line.
            Tip(version: "0.8.0", symbol: "text.alignleft",
                title: "See what each agent is working on",
                detail: "Every row carries a one-line title — the agent's own last prompt — so you can tell the checkout refactor from the docs pass without opening anything."),
            Tip(version: "0.5.0", symbol: "clock.badge.checkmark",
                title: "Finished sessions tidy themselves away",
                detail: "Done and ended sessions hide 10 minutes after their last activity (configurable in Settings, or never). Any new activity brings them right back."),
            Tip(version: "0.1.0", symbol: "gearshape",
                title: "Exact status from Claude Code",
                detail: "An optional toggle uses Claude's own notifications so \"needs you\" and \"done\" are exact instead of inferred. One reversible entry in Claude's settings — nothing else touched."),
        ]),
        Section(name: "Limits & forecasting", tips: [
            // Names the feature, so it can't be window-specific: each agent
            // meters a different window (Claude 5 hours, Codex a week, Cursor
            // a billing cycle, Manus a day).
            //
            // The window-naming claim is scoped to the rows that actually
            // carry a name on screen. A live 5-hour row deliberately doesn't
            // (see MenuContent.limitCaption: a tag is noise on a window that
            // refills before your coffee, and its reset clock already says as
            // much), so "every row names its own window" was advertising
            // something the user could see wasn't happening.
            Tip(version: "0.2.0", symbol: "gauge.with.needle",
                title: "Real usage limits, 0–100",
                detail: "Each agent's bar comes from its own data: Codex writes it to disk, Claude via the offline meter or opt-in live check, Antigravity from its synced account state. Every row shows when it resets, and the longer windows say which one they are — Codex's weekly, Cursor's billing cycle, Manus's daily. Never guessed."),
            Tip(version: "0.3.0", symbol: "chart.line.uptrend.xyaxis",
                title: "Pace forecasting",
                detail: "Readings age between turns, so stale numbers are corrected (\"≈9%\") — and when your pace will exhaust the window before it resets, the row warns you how early."),
            // 0.9.0 deepened pace into a clock-time ETA (commit 05d09cd), made
            // the pace line always visible — green when fine, amber when not
            // (b56bddc) — and scoped it to running apps only (290056d).
            Tip(version: "0.9.0", symbol: "clock.badge.exclamationmark",
                title: "Pace, down to the clock",
                detail: "The pace line is always there now — green while you're on track, amber when your current rate will drain the window before it resets, with the clock time it would happen. Shown only for apps that are actually open."),
            // The quoted string must match what MenuContent actually renders:
            // this said "week 23%" while the row said "weekly 23%", so the
            // guide documented both names for one window.
            Tip(version: "0.3.0", symbol: "calendar",
                title: "Weekly windows too",
                detail: "\"weekly 23%\" under each bar where the agent publishes a second, 7-day window, coloring up as it fills."),
            // 0.11.3 (commit 328b624): Codex's weekly quota is read straight
            // off disk, so a closed Codex still answers "how much is left, when
            // does it reset" instead of vanishing from the list.
            Tip(version: "0.11.3", symbol: "calendar.badge.clock",
                title: "Your Codex weekly, even when Codex is closed",
                detail: "The 7-day quota is read straight off disk, so a shut Codex still shows how much is left and when it rolls over — dimmed, with how old the reading is."),
            Tip(version: "0.12.0", symbol: "arrow.trianglehead.branch",
                title: "See what the agent actually changed",
                detail: "A finished session now shows its diff — \"+184 −12 · 6 files · 2 uncommitted\" — read straight from git, so you can tell useful work from a wasted turn without opening the repo."),
            Tip(version: "0.12.0", symbol: "terminal",
                title: "What it's running, not just \"Bash\"",
                detail: "Rows show the actual command the agent is running, with anything secret-shaped stripped out first. The drill-in keeps the last few."),
            Tip(version: "0.12.0", symbol: "bell.badge",
                title: "Alerts that can't go quietly missing",
                detail: "The app now checks macOS actually lets it notify, stops burning an alert it couldn't deliver, and pings you about a session that was already stuck when you opened it — the one case it used to stay silent on."),
            Tip(version: "0.12.0", symbol: "checkmark.seal",
                title: "Honest numbers",
                detail: "The old \"caught $X before it ran away\" line is gone — it counted money the app never saved. Budgets now compare in your own currency, and agents that can't report cost say \"activity only\" instead of implying zero."),
            // Title and detail describe the same rule, and both match the
            // menu's own control ("Show fewer" / "Show all") — the list stopped
            // being open-apps-only when a closed agent's account quota earned
            // its place in it.
            Tip(version: "0.2.0", symbol: "rectangle.expand.vertical",
                title: "Open apps and current readings by default",
                detail: "The limits list shows agents that are open right now, plus any agent holding a reading it can still speak about — dimmed, with how old it is; \"Show all\" expands to every installed agent that reports one."),
        ]),
        Section(name: "Notifications", tips: [
            Tip(version: "0.1.0", symbol: "bell",
                title: "Only what matters",
                detail: "An agent needs input, finished, or looks stuck — each its own toggle, all paused at once with the bell button."),
            Tip(version: "0.3.0", symbol: "text.bubble",
                title: "Banners you can act on",
                detail: "With exact status on, banners show the actual question (\"Claude needs permission to use Bash\") and what a finished turn said — plus a 10-minute snooze button."),
            // 0.8.0 (commit 6db1735): a waiting session re-alerts once so a
            // pending question doesn't sit unanswered.
            Tip(version: "0.8.0", symbol: "bell.badge",
                title: "A second nudge if you miss the first",
                detail: "A session that's been waiting on you re-alerts once, so a pending question doesn't sit unanswered while you're heads-down elsewhere."),
            // 0.8.0 (commit 6db1735): the optional weekly digest.
            Tip(version: "0.8.0", symbol: "list.bullet.rectangle",
                title: "Your week in one notification",
                detail: "An optional weekly digest sums up the last seven days — cost, active time, and sessions watched — in a single summary."),
            Tip(version: "0.2.0", symbol: "exclamationmark.triangle",
                title: "Limit alerts",
                detail: "One heads-up per window when usage crosses your threshold (default 80%), so a long task can't silently burn the whole window. The menu bar shows ⚠️ at 90%+."),
            // 0.10.0 shipped the advisory spend guard (commit 0972353); 0.11.2
            // (eb58ce4) stopped it repeating after a restart.
            Tip(version: "0.10.0", symbol: "shield.lefthalf.filled",
                title: "An advisory spend guard",
                detail: "Set a monthly budget and get one gentle heads-up as spend approaches it — advisory only, never a block, and it won't nag again just because you restarted."),
        ]),
        Section(name: "Cost & stats", tips: [
            Tip(version: "0.3.2", symbol: "chart.bar",
                title: "Stats: today, week, 3 months, all time",
                detail: "How long your agents worked while you did other things, sessions watched, and cost per agent — accumulating from the day you installed."),
            // 0.8.0 (commit 6db1735): per-model cost breakdown, a month range,
            // and an end-of-month projection.
            Tip(version: "0.8.0", symbol: "cpu",
                title: "Costs by model, and the month ahead",
                detail: "Stats break spend down per model, and a month range projects where you'll land by the last day at your current rate."),
            // 0.9.0 (commit b6e12d1): OpenAI list prices for Codex, and price +
            // tokens shown together on every row, plus user-set pace floors.
            Tip(version: "0.9.0", symbol: "dollarsign.arrow.circlepath",
                title: "Real dollars for Codex too",
                detail: "OpenAI list prices power Codex's costs, and every row shows price and tokens side by side — plus you pick how early the pace warnings start."),
            // 0.10.0 (commit 5876ec9): session drill-in, menu-bar cost
            // sparkline, and one-click live usage.
            Tip(version: "0.10.0", symbol: "arrow.up.left.and.arrow.down.right",
                title: "Open a session, read the whole story",
                detail: "Click any row to expand it — the full prompt, the pending question, timings, and the working folder. A 7-day spend sparkline can ride in the menu bar, and exact Claude usage is one click from an empty row."),
            // 0.10.0 token accuracy: every token incl. cache reads (791942c),
            // parallel sub-agents counted (910616f), message ids deduped so
            // nothing is double-charged (81c2e1f), and a cost-confidence flag
            // on less-certain estimates (0972353).
            Tip(version: "0.10.0", symbol: "number.circle",
                title: "Every token counted, once",
                detail: "Costs now include every token processed — cache reads included — follow Claude Code's parallel sub-agents, and dedupe message ids so nothing is charged twice. Less-certain estimates are flagged, never dressed up as exact."),
            // 0.10.0 (commit 0972353): the impact ledger — the running monthly
            // tally behind the menu-bar totals.
            Tip(version: "0.10.0", symbol: "book.closed",
                title: "A ledger of the month's work",
                detail: "The impact ledger keeps a running tally of what your agents did this month and what it cost — the number behind the menu-bar totals."),
            Tip(version: "0.5.1", symbol: "square.and.arrow.up",
                title: "Export your stats",
                detail: "Every recorded day as CSV — date, cost, active minutes, sessions, per-agent dollars — from the stats window. Pick your hotkey chord in Settings too."),
            Tip(version: "0.1.0", symbol: "dollarsign.circle",
                title: "Honest cost estimates",
                detail: "Computed from token usage at API list prices. On a subscription it's not an extra charge — it shows the value of your usage. Unknown models show tokens, never guessed dollars."),
        ]),
        Section(name: "Power tools", tips: [
            Tip(version: "0.3.0", symbol: "keyboard",
                title: "⌥⌘B from anywhere",
                detail: "Jumps straight to the session that most needs you — waiting first, then stuck, then working."),
            Tip(version: "0.3.0", symbol: "menubar.rectangle",
                title: "Your menu bar, your choice",
                detail: "Show status + count, today's cost, or the hottest limit % — pick in Settings → General."),
        ]),
        Section(name: "Budgets, history & sync", tips: [
            // All four landed in 0.7.0 (commit 6406842, "Close reviewer/user
            // gaps: budgets, quiet hours, history, per-project, sync, drift").
            Tip(version: "0.7.0", symbol: "creditcard",
                title: "Set a monthly budget",
                detail: "Tell the app what you mean to spend each month; it tracks against that figure so a busy week isn't a surprise."),
            Tip(version: "0.7.0", symbol: "moon.zzz",
                title: "Quiet hours",
                detail: "Choose hours when notifications stay silent — overnight, in meetings — while the dots keep updating as always."),
            Tip(version: "0.7.0", symbol: "clock.arrow.circlepath",
                title: "A log of finished sessions",
                detail: "The history window lists sessions that have wrapped — which agent, which project, how long, and what they cost."),
            Tip(version: "0.7.0", symbol: "folder.badge.gearshape",
                title: "Per-project costs, synced across Macs",
                detail: "Spend is broken out by project, and your settings follow you between Macs over iCloud — no account, no server."),
        ]),
        Section(name: "Private by design", tips: [
            Tip(version: "0.1.0", symbol: "lock.shield",
                title: "Everything runs on your Mac",
                detail: "The app reads your agents' own files and collects nothing. The only network features — live Claude usage, license activation, update check — are opt-in, labeled, and single-purpose."),
            // 0.11.x whole-app accuracy audit (commits 1a7542f, 9b4f59d,
            // 4841cfe): consistent rows/limits/stats, and honest degraded
            // state when macOS limits what the app can read.
            Tip(version: "0.11.0", symbol: "checkmark.seal",
                title: "Honest when it can't see everything",
                detail: "When macOS limits what the app can read, it says so on the affected rows instead of inventing numbers — and a whole-app accuracy pass keeps rows, limits, and stats consistent with each other."),
        ]),
    ]

    static var allTips: [Tip] { sections.flatMap(\.tips) }

    /// Tips introduced after the given version (numeric compare).
    static func tipsNewer(than version: String) -> [Tip] {
        allTips.filter { $0.version.compare(version, options: .numeric) == .orderedDescending }
    }
}
