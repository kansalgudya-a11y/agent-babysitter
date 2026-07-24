import SwiftUI
import AppKit
import AgentBabysitterCore

/// Renders every notable UI state to PNGs for visual QA:
/// `AgentBabysitter --ui-snapshots <dir>`. Exits when done — never runs in
/// a normal launch.
@MainActor
enum UISnapshots {

    /// Fixture prefs go into the volatile argument domain: they override
    /// disk for this process only and are never written back — QA runs on a
    /// dev machine must not corrupt that user's real settings.
    static func setFixturePref(_ value: Any, forKey key: String) {
        var domain = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        domain[key] = value
        UserDefaults.standard.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
    }

    static func runIfRequested() {
        guard let flagIndex = CommandLine.arguments.firstIndex(of: "--ui-snapshots"),
              CommandLine.arguments.count > flagIndex + 1 else { return }
        let directory = URL(fileURLWithPath: CommandLine.arguments[flagIndex + 1])
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Defer past app launch so AppKit windows can lay out, then exit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            render(into: directory)
            exit(0)
        }
    }

    /// ImageRenderer draws SwiftUI-native content (text, layout, shapes)
    /// faithfully; AppKit-backed controls (buttons, progress bars) appear as
    /// placeholder blobs at their correct frames — fine for layout QA.
    private static func render(into directory: URL) {
        for (name, view) in fixtures() {
            for scheme in [ColorScheme.light, .dark] {
                let renderer = ImageRenderer(content: AnyView(view
                    .environment(\.colorScheme, scheme)
                    .background(scheme == .dark ? Color(white: 0.13) : .white)))
                renderer.scale = 2
                guard let image = renderer.nsImage,
                      let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else {
                    FileHandle.standardError.write(Data("RENDER FAILED: \(name)\n".utf8))
                    continue
                }
                let suffix = scheme == .dark ? "dark" : "light"
                try? png.write(to: directory.appendingPathComponent("\(name)-\(suffix).png"))
            }
        }
        print("snapshots written")
    }

    // MARK: - Fixtures

    private static func fixtures() -> [(String, AnyView)] {
        var results: [(String, AnyView)] = []

        func menu(_ name: String, showAll: Bool = false,
                  _ configure: (AppModel) -> Void) {
            // Pin every pref a fixture depends on - renders must not vary
            // with the dev machine's real settings.
            setFixturePref(false, forKey: "showAllLimits")
            setFixturePref(false, forKey: "claudeUsageMeterEnabled")
            setFixturePref(false, forKey: "liveUsageEnabled")
            setFixturePref("USD", forKey: "currencyCode")
            let model = AppModel()
            configure(model)
            results.append((name, AnyView(MenuContent(model: model,
                                                      forceShowAllLimits: showAll))))
        }

        let now = Date()
        let activityAgents: Set<String> = ["antigravity", "antigravity-ide",
                                           "antigravity-cli", "cursor", "gemini",
                                           "gemini-cli", "manus", "openclaw"]
        func row(_ id: String, _ project: String, _ state: SessionState,
                 agent: (String, String) = ("claude-code", "Claude Code"),
                 entrypoint: String? = nil, dollars: Double = 0,
                 startedMinutesAgo: Double = 6, unreadable: Bool = false,
                 title: String? = nil, cost: SessionCost? = nil) -> SessionRow {
            SessionRow(id: id, projectName: project, state: state,
                       turnStartedAt: now.addingTimeInterval(-startedMinutesAgo * 60),
                       lastGrowthAt: now.addingTimeInterval(-30), isUnreadable: unreadable,
                       pid: 123, cwd: nil,
                       // Tokens derived from dollars (~$25/M blended) so the
                       // rows exercise the price+tokens trailing block.
                       cost: cost ?? SessionCost(dollars: dollars,
                                                 totalTokens: Int(dollars * 40_000)),
                       entrypoint: entrypoint, agentID: agent.0, agentName: agent.1,
                       isActivityBased: activityAgents.contains(agent.0), title: title)
        }

        func limit(_ used: Double?, plan: String?, resetsInMinutes: Double = 135,
                   weekly: Double? = nil, weeklyResetsInDays: Double = 3.4,
                   live: Bool = false,
                   capturedMinutesAgo: Double = 2,
                   windowMinutes: Int = 300) -> UsageLimitSnapshot {
            UsageLimitSnapshot(usedPercent: used, windowMinutes: windowMinutes,
                               resetsAt: now.addingTimeInterval(resetsInMinutes * 60),
                               capturedAt: now.addingTimeInterval(-capturedMinutesAgo * 60),
                               plan: plan,
                               isLive: live, weeklyUsedPercent: weekly,
                               weeklyResetsAt: now.addingTimeInterval(weeklyResetsInDays * 86_400))
        }

        let allInstalled = [("claude-code", "Claude Code"), ("codex", "Codex"),
                            ("antigravity", "Antigravity"),
                            ("antigravity-ide", "Antigravity IDE"),
                            ("antigravity-cli", "Antigravity CLI")]
        let history = (0..<7).map { (day: now.addingTimeInterval(Double($0 - 6) * 86_400),
                                     dollars: [12.0, 48.2, 3.1, 96.4, 0, 157.5, 22.9][$0]) }

        menu("menu-normal") { model in
            model.applyFixture(
                rows: [row("a", "checkout-service", .working, dollars: 12.38,
                           title: "add rate limiting to the checkout API"),
                       row("b", "AgentBabysitter", .waitingForInput,
                           entrypoint: "claude-desktop", dollars: 4.02),
                       row("c", "rollout-parser", .done,
                           agent: ("codex", "Codex"), dollars: 1.75),
                       row("d", "#a84b4e9f", .working,
                           agent: ("antigravity", "Antigravity"), entrypoint: "Antigravity")],
                summary: MenuBarSummary(worstState: .waitingForInput, activeCount: 4),
                usageLimits: ["claude-code": limit(43, plan: "pro", weekly: 23, live: true),
                              "codex": limit(12, plan: "plus", weekly: 4),
                              "antigravity": limit(5, plan: "Google AI Pro")],
                installedAgents: allInstalled,
                runningAgentIDs: ["claude-code", "codex", "antigravity"],
                todayCost: SessionCost(dollars: 18.15), costHistory: history)
        }

        // Token-display fixes: a heavy-cache priced row (its split lives in the
        // drill-in, the row shows dollars), an activity agent ("no token data",
        // not "—"/"0 tok"), and an unpriced model ("pricing unknown"); the
        // footer must stay compact with a single "≥" (no "~~", no token blob).
        menu("menu-tokens") { model in
            model.applyFixture(
                rows: [row("a", "checkout-service", .working, dollars: 128.40,
                           cost: SessionCost(dollars: 128.40, totalTokens: 2_100_000,
                                             inputTokens: 1_900_000, outputTokens: 200_000,
                                             cacheReadTokens: 4_800_000_000,
                                             cacheWriteTokens: 130_000_000)),
                       row("b", "design-notes", .done, agent: ("cursor", "Cursor")),
                       row("c", "prototype", .working, agent: ("codex", "Codex"),
                           cost: SessionCost(dollars: 0, totalTokens: 44_000,
                                             unknownModels: ["gpt-5.6-sol"],
                                             inputTokens: 30_000, outputTokens: 14_000))],
                summary: MenuBarSummary(worstState: .working, activeCount: 3),
                usageLimits: ["codex": limit(25, plan: "plus",
                                             resetsInMinutes: 4 * 24 * 60, windowMinutes: 10080)],
                installedAgents: allInstalled + [("cursor", "Cursor")],
                runningAgentIDs: ["claude-code", "cursor", "codex"],
                todayCost: SessionCost(dollars: 352.10, unknownModels: ["gpt-5.6-sol"]),
                costHistory: history)
        }

        // Currency conversion + limits ordering: Codex's window has rolled
        // over so it sinks below the live Claude/Antigravity readings and
        // dims; Gemini (link-only) sits at the very bottom; costs render in ₹.
        menu("menu-currency") { model in
            model.applyFixture(
                rows: [row("a", "checkout-service", .working, dollars: 12.38),
                       row("c", "rollout-parser", .done,
                           agent: ("codex", "Codex"), dollars: 1.75)],
                summary: MenuBarSummary(worstState: .working, activeCount: 2),
                usageLimits: ["claude-code": limit(43, plan: "pro", weekly: 23, live: true),
                              "codex": limit(0, plan: "plus", resetsInMinutes: -5),
                              // Cursor's window is the monthly billing cycle,
                              // Manus's the daily credit refresh — both pace.
                              "cursor": limit(42, plan: "Pro", resetsInMinutes: 12 * 24 * 60,
                                              live: true, windowMinutes: 30 * 24 * 60),
                              "manus": limit(62, plan: "Free · 1,276 credits",
                                             resetsInMinutes: 10 * 60,
                                             live: true, windowMinutes: 24 * 60),
                              "antigravity": limit(5, plan: "Google AI Pro")],
                installedAgents: allInstalled + [("cursor", "Cursor"), ("manus", "Manus"),
                                                 ("gemini", "Gemini")],
                runningAgentIDs: ["claude-code", "codex", "antigravity", "cursor", "manus", "gemini"],
                todayCost: SessionCost(dollars: 18.15), costHistory: history,
                currency: ("INR", 95.3))
        }

        menu("menu-crowded-danger", showAll: true) { model in
            model.applyFixture(
                rows: [row("a", "a-really-long-project-directory-name-that-should-truncate",
                           .working, dollars: 812.44, startedMinutesAgo: 260),
                       row("b", "checkout-service", .stalled, dollars: 55.1,
                           startedMinutesAgo: 45),
                       row("c", "unreadable-one", .working, unreadable: true),
                       row("d", "rollout-parser", .waitingForInput,
                           agent: ("codex", "Codex"), entrypoint: "Codex Desktop",
                           dollars: 9.99),
                       row("e", "#03460a7f", .done,
                           agent: ("antigravity-ide", "Antigravity IDE"),
                           entrypoint: "Antigravity IDE"),
                       row("f", "#09f95bd1", .ended,
                           agent: ("antigravity-cli", "Antigravity CLI"))],
                summary: MenuBarSummary(worstState: .stalled, activeCount: 5),
                usageLimits: ["claude-code": limit(94, plan: "pro", resetsInMinutes: 22,
                                                   weekly: 91, live: true),
                              "codex": limit(76, plan: "plus", weekly: 40,
                                             capturedMinutesAgo: 55),
                              "antigravity": limit(nil, plan: "Google AI Pro"),
                              // Pace-able reading on a CLOSED app: the pace
                              // line must stay hidden (running apps only).
                              "antigravity-ide": limit(65, plan: "Google AI Pro"),
                              "antigravity-cli": limit(5, plan: "Google AI Pro")],
                installedAgents: allInstalled,
                runningAgentIDs: ["claude-code", "codex"],
                todayCost: SessionCost(dollars: 877.53), costHistory: history,
                limitDanger: true, processDetectionDegraded: true)
        }

        menu("menu-quiet") { model in
            model.applyFixture(
                rows: [], summary: MenuBarSummary(worstState: nil, activeCount: 0),
                // Cursor offline = plan tier only; the row offers the
                // one-click "Show my real numbers" enable.
                usageLimits: ["codex": limit(1, plan: "plus"),
                              "cursor": limit(nil, plan: "Free")],
                installedAgents: allInstalled + [("cursor", "Cursor")],
                runningAgentIDs: ["cursor"],
                todayCost: SessionCost(), costHistory: [])
        }

        // The reported bug, exactly: Codex CLOSED, its newest rollout ~24.5h
        // old (so the session has aged out of the store's active window) and
        // the weekly quota read straight off disk. Without toggling "Show all"
        // the row must be present, dimmed, and answer "how much is left and
        // when does it reset". Hermes and OpenClaw are installed here and must
        // be ABSENT from this list — they record no quota anywhere.
        menu("menu-codex-weekly-closed") { model in
            model.applyFixture(
                rows: [row("a", "checkout-service", .working, dollars: 6.20)],
                summary: MenuBarSummary(worstState: .working, activeCount: 1),
                usageLimits: ["codex": limit(24, plan: "prolite",
                                             resetsInMinutes: 5 * 24 * 60 + 17 * 60,
                                             capturedMinutesAgo: 1474,
                                             windowMinutes: 10080)],
                installedAgents: allInstalled + [("hermes", "Hermes"),
                                                 ("openclaw", "OpenClaw")],
                runningAgentIDs: ["claude-code"],
                todayCost: SessionCost(dollars: 6.20), costHistory: history)
        }

        // Antigravity's three surfaces read ONE shared account quota, so the
        // store hands the identical snapshot to all three ids. With the IDE
        // closed, the collapsed list must show that fact ONCE — three
        // identical "Antigravity 12%" rows is what admitting each surface on
        // its own reading would produce.
        menu("menu-shared-quota-once") { model in
            let shared = limit(12, plan: "Google AI Pro", capturedMinutesAgo: 90)
            model.applyFixture(
                rows: [], summary: MenuBarSummary(worstState: nil, activeCount: 0),
                usageLimits: ["antigravity": shared, "antigravity-ide": shared,
                              "antigravity-cli": shared],
                installedAgents: allInstalled,
                runningAgentIDs: [],
                todayCost: SessionCost(), costHistory: [])
        }

        // The SAME shared quota with a RUNNING sibling — the one configuration
        // the fixture above cannot catch, and where the de-dup regressed: the
        // closed umbrella ("antigravity") sorts BEFORE the running IDE
        // ("antigravity-ide"), so a single forward pass let it claim the
        // reading, admitted it, and then appended the running row anyway —
        // "Antigravity 12%" and "Antigravity IDE 12%", the same fact twice.
        // This is the user's real setup: all three ~/.gemini/antigravity*
        // directories exist, and the IDE is routinely open with the desktop
        // app closed. Exactly ONE Antigravity row, and it must be the running
        // one (the row you can act on).
        menu("menu-shared-quota-running-sibling") { model in
            let shared = limit(12, plan: "Google AI Pro", capturedMinutesAgo: 90)
            model.applyFixture(
                rows: [row("a", "#a84b4e9f", .working,
                           agent: ("antigravity-ide", "Antigravity IDE"),
                           entrypoint: "Antigravity IDE")],
                summary: MenuBarSummary(worstState: .working, activeCount: 1),
                usageLimits: ["antigravity": shared, "antigravity-ide": shared,
                              "antigravity-cli": shared],
                installedAgents: allInstalled,
                runningAgentIDs: ["antigravity-ide"],
                todayCost: SessionCost(), costHistory: [])
        }

        // The SAME shared quota with the sort order REVERSED: the running
        // surface is the umbrella ("antigravity", order 4) and the closed
        // siblings sort AFTER it. De-dup must not depend on which direction
        // the running row happens to sit in — one row here too, and it is
        // "Antigravity".
        menu("menu-shared-quota-umbrella-running") { model in
            let shared = limit(12, plan: "Google AI Pro", capturedMinutesAgo: 90)
            model.applyFixture(
                rows: [row("a", "#a84b4e9f", .working,
                           agent: ("antigravity", "Antigravity"),
                           entrypoint: "Antigravity")],
                summary: MenuBarSummary(worstState: .working, activeCount: 1),
                usageLimits: ["antigravity": shared, "antigravity-ide": shared,
                              "antigravity-cli": shared],
                installedAgents: allInstalled,
                runningAgentIDs: ["antigravity"],
                todayCost: SessionCost(), costHistory: [])
        }

        // BOTH surfaces open at once — the configuration neither fixture above
        // covers, and the one the de-dup rule used to print twice: "Antigravity
        // 12%" directly above "Antigravity IDE 12%", one account's reading
        // drawn as two bars. Exactly ONE row, and it keeps full opacity
        // because the surviving surface is open.
        menu("menu-shared-quota-both-running") { model in
            let shared = limit(12, plan: "Google AI Pro", capturedMinutesAgo: 90)
            model.applyFixture(
                rows: [row("a", "#a84b4e9f", .working,
                           agent: ("antigravity", "Antigravity"),
                           entrypoint: "Antigravity"),
                       row("b", "#03460a7f", .working,
                           agent: ("antigravity-ide", "Antigravity IDE"),
                           entrypoint: "Antigravity IDE")],
                summary: MenuBarSummary(worstState: .working, activeCount: 2),
                usageLimits: ["antigravity": shared, "antigravity-ide": shared,
                              "antigravity-cli": shared],
                installedAgents: allInstalled,
                runningAgentIDs: ["antigravity", "antigravity-ide"],
                todayCost: SessionCost(), costHistory: [])
        }

        // A secondary weekly window that has ALREADY rolled over, on a row
        // whose primary (a 30-day billing cycle) has not. The row is entitled
        // to state its primary, but the weekly number behind it is dead — so
        // the caption must carry NO "weekly 23%" piece, and neither must the
        // tooltip. Before this, a row could read "billing cycle · 58% left ·
        // resets in 11d 23h · weekly 23%" with the weekly figure days stale.
        menu("menu-secondary-weekly-rolled-over") { model in
            model.applyFixture(
                rows: [], summary: MenuBarSummary(worstState: nil, activeCount: 0),
                usageLimits: ["cursor": limit(42, plan: "Pro",
                                              resetsInMinutes: 12 * 24 * 60,
                                              weekly: 23, weeklyResetsInDays: -1.5,
                                              live: true, windowMinutes: 30 * 24 * 60),
                              // The control, one row above: same secondary
                              // window, still live, still captioned.
                              "claude-code": limit(43, plan: "pro", weekly: 23, live: true)],
                installedAgents: allInstalled + [("cursor", "Cursor")],
                runningAgentIDs: ["claude-code"],
                todayCost: SessionCost(dollars: 18.15), costHistory: history)
        }

        // De-dup is a DEFAULT-LIST rule, not a filter: "Show all" over the
        // same shared quota must still list every surface separately, so the
        // user can see which surfaces exist and that they read one account.
        menu("menu-shared-quota-show-all", showAll: true) { model in
            let shared = limit(12, plan: "Google AI Pro", capturedMinutesAgo: 90)
            model.applyFixture(
                rows: [row("a", "#a84b4e9f", .working,
                           agent: ("antigravity-ide", "Antigravity IDE"),
                           entrypoint: "Antigravity IDE")],
                summary: MenuBarSummary(worstState: .working, activeCount: 1),
                usageLimits: ["antigravity": shared, "antigravity-ide": shared,
                              "antigravity-cli": shared],
                installedAgents: allInstalled,
                runningAgentIDs: ["antigravity-ide"],
                todayCost: SessionCost(), costHistory: [])
        }

        // A genuine 0% is a reading, not a gap: "0%" with "weekly · 100% left",
        // never "no recent reading" and never the "0% used 100% left 0%" mush.
        menu("menu-codex-zero-percent") { model in
            model.applyFixture(
                rows: [], summary: MenuBarSummary(worstState: nil, activeCount: 0),
                usageLimits: ["codex": limit(0, plan: "prolite",
                                             resetsInMinutes: 6 * 24 * 60,
                                             windowMinutes: 10080)],
                installedAgents: allInstalled,
                runningAgentIDs: [],
                todayCost: SessionCost(), costHistory: [])
        }

        // Rolled-over weekly window: the row shows neither a percentage nor a
        // "% left" — there is nothing left to report until it refills — only
        // which window reset. Hermes and OpenClaw are installed and this is
        // the FULLY EXPANDED list, so their absence here is the proof that
        // they're excluded rather than merely hidden: neither records a quota
        // anywhere.
        menu("menu-codex-reset", showAll: true) { model in
            model.applyFixture(
                rows: [], summary: MenuBarSummary(worstState: nil, activeCount: 0),
                usageLimits: ["codex": limit(88, plan: "prolite",
                                             resetsInMinutes: -90,
                                             capturedMinutesAgo: 200,
                                             windowMinutes: 10080)],
                installedAgents: allInstalled + [("hermes", "Hermes"),
                                                 ("openclaw", "OpenClaw"),
                                                 ("openclaw-sdk", "OpenClaw SDK")],
                runningAgentIDs: ["hermes"],
                todayCost: SessionCost(), costHistory: [])
        }

        // Rollover while Codex is still CLOSED — the moment the disk-quota fix
        // used to expire. The row must KEEP its place in the COLLAPSED list
        // (no "Show all") and say what happened: empty bar, "reset", and
        // "weekly · window reset · as of 5d ago". Vanishing here would have
        // stranded exactly the offline user the fix was for. The second
        // reading is the aged-out case in the same list: its window rolled
        // over 9 days ago, so a whole further weekly window has passed with no
        // evidence about the current one — that row is gone until Antigravity
        // runs again, or until "Show all".
        menu("menu-window-rolled-over-closed") { model in
            model.applyFixture(
                rows: [], summary: MenuBarSummary(worstState: nil, activeCount: 0),
                usageLimits: ["codex": limit(24, plan: "prolite",
                                             resetsInMinutes: -40,
                                             capturedMinutesAgo: 5 * 24 * 60,
                                             windowMinutes: 10080),
                              "antigravity": limit(65, plan: "Google AI Pro",
                                                   resetsInMinutes: -9 * 24 * 60,
                                                   capturedMinutesAgo: 16 * 24 * 60,
                                                   windowMinutes: 10080)],
                installedAgents: allInstalled,
                runningAgentIDs: [],
                todayCost: SessionCost(), costHistory: [])
        }

        menu("menu-onboarding") { model in
            model.applyFixture(rows: [], summary: MenuBarSummary(worstState: nil, activeCount: 0),
                               usageLimits: [:], installedAgents: [], runningAgentIDs: [],
                               todayCost: SessionCost(), costHistory: [],
                               noAgentsDetected: true)
        }

        menu("menu-welcome") { model in
            model.applyFixture(
                rows: [row("a", "checkout-service", .working, dollars: 2.10)],
                summary: MenuBarSummary(worstState: .working, activeCount: 1),
                usageLimits: ["claude-code": limit(8, plan: "pro")],
                installedAgents: [("claude-code", "Claude Code")],
                runningAgentIDs: ["claude-code"],
                todayCost: SessionCost(dollars: 2.10), costHistory: [],
                welcomeDismissed: false)
        }

        // MARK: F1 — coverage for the eight menu states the set didn't isolate
        // Each is a single-purpose fixture QA can eyeball on its own; several
        // states were previously only reachable inside a crowded composite.
        // Rendered when Xcode returns.

        // ERROR: process detection is degraded (macOS withheld process info)
        // AND a session's latest turn was an API error — the two "something is
        // wrong" surfaces at once. `apiError` and `processDetectionDegraded`
        // are existing fields; nothing here depends on an unlanded lane.
        menu("menu-error") { model in
            var failing = row("a", "checkout-service", .working, dollars: 3.10,
                              title: "run the migration and backfill orders")
            failing.apiError = "API error: overloaded_error (retrying)"
            model.applyFixture(
                rows: [failing,
                       row("b", "rollout-parser", .done,
                           agent: ("codex", "Codex"), dollars: 1.75)],
                summary: MenuBarSummary(worstState: .working, activeCount: 2),
                usageLimits: ["claude-code": limit(43, plan: "pro", weekly: 23, live: true)],
                installedAgents: allInstalled,
                runningAgentIDs: ["claude-code", "codex"],
                todayCost: SessionCost(dollars: 6.20), costHistory: history,
                processDetectionDegraded: true)
        }

        // EMPTY: agents installed and one open, but nothing is running and no
        // limit reading has arrived yet — the quiet just-launched list. Distinct
        // from menu-onboarding (noAgentsDetected: no agents installed at all)
        // and from menu-quiet (which carries limit readings): here both the
        // session list and the limits list are empty while agents are present.
        menu("menu-empty") { model in
            model.applyFixture(
                rows: [], summary: MenuBarSummary(worstState: nil, activeCount: 0),
                usageLimits: [:],
                installedAgents: allInstalled,
                runningAgentIDs: ["claude-code"],
                todayCost: SessionCost(), costHistory: [])
        }

        // MUTED: the bell is off — every lifecycle notification paused at once.
        // `notificationsMuted` is a public settable @Published var, so it pins
        // inside the fixture closure (unlike unreadableAgents below).
        menu("menu-muted") { model in
            model.notificationsMuted = true
            model.applyFixture(
                rows: [row("a", "checkout-service", .working, dollars: 12.38,
                           title: "add rate limiting to the checkout API"),
                       row("b", "AgentBabysitter", .waitingForInput,
                           entrypoint: "claude-desktop", dollars: 4.02)],
                summary: MenuBarSummary(worstState: .waitingForInput, activeCount: 2),
                usageLimits: ["claude-code": limit(43, plan: "pro", weekly: 23, live: true)],
                installedAgents: allInstalled,
                runningAgentIDs: ["claude-code"],
                todayCost: SessionCost(dollars: 18.15), costHistory: history)
        }

        // UNREADABLE: a session whose transcript the app can't parse renders as
        // the "can't read this one" row (isUnreadable).
        // KNOWN GAP (cross-file): the AGENT-level "Can't read <agent>" banner is
        // driven by AppModel.unreadableAgents, which is `private(set)` and NOT an
        // applyFixture parameter — it cannot be injected from UISnapshots, so
        // this fixture covers the unreadable ROW only. Covering the banner needs
        // an applyFixture(unreadableAgents:) parameter (or access relaxation) on
        // AppModel — owned by the app-hub / row-model lane, not this file.
        menu("menu-unreadable") { model in
            model.applyFixture(
                rows: [row("a", "some-project", .working, unreadable: true),
                       row("b", "checkout-service", .done, dollars: 2.40)],
                summary: MenuBarSummary(worstState: .working, activeCount: 2),
                usageLimits: ["claude-code": limit(43, plan: "pro")],
                installedAgents: allInstalled,
                runningAgentIDs: ["claude-code"],
                todayCost: SessionCost(dollars: 2.40), costHistory: history)
        }

        // ACTIVITY-ONLY (F4): agents that can only report that they're active —
        // no per-session cost, no lifecycle banners. MenuContent tags both the
        // session group header and the limits row "activity only"
        // (AgentCapabilityTier.activityOnly.rowLabel), driven by the real
        // adapters' `isActivityBased` and AppModel.activityOnlyAgentNames.
        // Gemini (link-only) and Cursor are the activity-only cases; a Claude
        // row sits beside them as the cost+notify control so the contrast shows.
        menu("menu-activity-only") { model in
            model.applyFixture(
                rows: [row("a", "checkout-service", .working, dollars: 12.38,
                           title: "add rate limiting to the checkout API"),
                       row("b", "#7f21ac0e", .working,
                           agent: ("gemini", "Gemini"), entrypoint: "Gemini"),
                       row("c", "#a84b4e9f", .working,
                           agent: ("cursor", "Cursor"), entrypoint: "Cursor")],
                summary: MenuBarSummary(worstState: .working, activeCount: 3),
                usageLimits: ["claude-code": limit(43, plan: "pro", weekly: 23, live: true),
                              "cursor": limit(42, plan: "Pro", resetsInMinutes: 12 * 24 * 60,
                                              live: true, windowMinutes: 30 * 24 * 60),
                              "gemini": limit(nil, plan: "Google AI Pro")],
                installedAgents: allInstalled + [("cursor", "Cursor"), ("gemini", "Gemini")],
                runningAgentIDs: ["claude-code", "gemini", "cursor"],
                todayCost: SessionCost(dollars: 18.15), costHistory: history)
        }

        // F10 + F11 feature surfaces. COMPILE AND RENDER both pend the row-model
        // lane: this fixture sets `SessionRow.git` (F10) and
        // `SessionRow.recentToolCalls` (F11), the two fields that lane adds to
        // SessionStore.swift (defaulted in init, build contract §1). MenuContent
        // already reads them — `git.summary` on a .done row and
        // `recentToolCalls.last.line` on a .working row — so the app target is
        // already blocked on those same fields regardless of this file; once
        // they land, everything (including this fixture) compiles and renders
        // together. The GitSnapshot / ToolCallSummary VALUES below are built
        // against the REAL Core types (already present and probe-verified); only
        // the two SessionRow properties are unlanded. See report: cross-file
        // dependency on SessionStore.swift (row-model lane).
        menu("menu-feature-surfaces") { model in
            // F11: the redacted last-tool-call feed. Summaries are already
            // redaction OUTPUT — no key/token/password shapes — exactly what
            // Core stores; MenuContent shows only `.last` on the working row.
            var working = row("a", "checkout-service", .working, dollars: 12.38,
                              title: "add rate limiting to the checkout API")
            working.recentToolCalls = [
                ToolCallSummary(tool: "Read", summary: "SessionStore.swift",
                                at: now.addingTimeInterval(-90)),
                ToolCallSummary(tool: "Edit", summary: "RateLimiter.swift",
                                at: now.addingTimeInterval(-60)),
                ToolCallSummary(tool: "Bash", summary: "swift test",
                                at: now.addingTimeInterval(-20)),
            ]
            // F10: what a finished turn changed on disk, from a read-only
            // git diff --shortstat + porcelain count.
            var finished = row("b", "checkout-service", .done, dollars: 6.20,
                               title: "wire the limiter into the request path")
            finished.cwd = "/Users/dev/work/checkout-service"
            finished.git = GitSnapshot(filesChanged: 6, added: 184,
                                       removed: 12, uncommitted: 2)
            // Clean-tree done row: git.summary == "", so MenuContent draws no
            // git line — the "nothing changed" control beside the one that did.
            var clean = row("c", "rollout-parser", .done,
                            agent: ("codex", "Codex"), dollars: 1.75)
            clean.git = GitSnapshot(filesChanged: 0, added: 0, removed: 0, uncommitted: 0)
            model.applyFixture(
                rows: [working, finished, clean],
                summary: MenuBarSummary(worstState: .working, activeCount: 3),
                usageLimits: ["claude-code": limit(43, plan: "pro", weekly: 23, live: true),
                              "codex": limit(12, plan: "plus", weekly: 4)],
                installedAgents: allInstalled,
                runningAgentIDs: ["claude-code", "codex"],
                todayCost: SessionCost(dollars: 8.60), costHistory: history)
        }

        // ~100 days of plausible history so every range has shape.
        let statsDays: [DayStat] = (0..<100).map { back in
            let day = Calendar.current.startOfDay(
                for: now.addingTimeInterval(Double(-back) * 86_400))
            let wave = Double((back * 37) % 100)
            return DayStat(day: day,
                           dollars: wave * 1.6,
                           byAgent: ["claude-code": wave * 1.1,
                                     "codex": wave * 0.4,
                                     "antigravity": wave * 0.1],
                           byProject: ["agent-babysitter": wave * 0.9,
                                       "checkout-service": wave * 0.5,
                                       "neon-county": wave * 0.2],
                           byModel: ["claude-opus-4-8": wave * 1.0,
                                     "claude-haiku-4-5-20251001": wave * 0.1,
                                     "claude-sonnet-5": wave * 0.5],
                           activeMinutes: wave * 3.2,
                           sessions: Int(wave / 12))
        }.reversed()

        func stats(_ name: String, _ range: StatsView.StatsRange) {
            let model = AppModel()
            model.applyFixture(
                rows: [], summary: MenuBarSummary(worstState: nil, activeCount: 0),
                usageLimits: [:], installedAgents: allInstalled, runningAgentIDs: [],
                todayCost: SessionCost(dollars: 22.9, totalTokens: 5_400_000,
                                       inputTokens: 800_000, outputTokens: 600_000,
                                       cacheReadTokens: 40_000_000,
                                       cacheWriteTokens: 4_000_000),
                costHistory: history, statsDays: Array(statsDays))
            results.append((name, AnyView(StatsView(model: model, initialRange: range).content)))
        }
        stats("stats-today", .today)
        stats("stats-week", .week)
        stats("stats-month", .month)
        stats("stats-3months", .threeMonths)
        stats("stats-alltime", .allTime)

        // The reported bug: one day of history must still draw a graph.
        let singleDayModel = AppModel()
        singleDayModel.applyFixture(
            rows: [], summary: MenuBarSummary(worstState: nil, activeCount: 0),
            usageLimits: [:], installedAgents: allInstalled, runningAgentIDs: [],
            todayCost: SessionCost(dollars: 22.9), costHistory: [],
            statsDays: [DayStat(day: Calendar.current.startOfDay(for: now),
                                dollars: 178.4,
                                byAgent: ["claude-code": 152.1, "codex": 26.3],
                                activeMinutes: 214, sessions: 9)])
        results.append(("stats-single-day",
                        AnyView(StatsView(model: singleDayModel, initialRange: .week).content)))
        results.append(("stats-single-day-alltime",
                        AnyView(StatsView(model: singleDayModel, initialRange: .allTime).content)))

        // Welcome tour as an updater would see it (floor 0.2.1 -> newer badged).
        setFixturePref("0.2.1", forKey: "lastSeenGuideVersion")
        let welcomeModel = AppModel()
        welcomeModel.applyFixture(
            rows: [], summary: MenuBarSummary(worstState: nil, activeCount: 0),
            usageLimits: [:], installedAgents: [], runningAgentIDs: [],
            todayCost: SessionCost(), costHistory: [])
        results.append(("welcome-tour", AnyView(WelcomeView(model: welcomeModel))))

        // Settings (Form/TabView) is AppKit-backed and invisible to
        // ImageRenderer — verified by eye in the running app instead.
        results.append(("menubar-labels", AnyView(
            HStack(spacing: 14) {
                MenuBarLabel(summary: .init(worstState: nil, activeCount: 0))
                MenuBarLabel(summary: .init(worstState: .working, activeCount: 3))
                MenuBarLabel(summary: .init(worstState: .waitingForInput, activeCount: 2),
                             limitDanger: true)
                MenuBarLabel(summary: .init(worstState: nil, activeCount: 0), limitDanger: true)
                MenuBarLabel(summary: .init(worstState: .working, activeCount: 2),
                             style: "cost", costToday: 317.65)
                // Zero today's cost must still render "$0" in the "cost" style,
                // not silently fall back to the moon icon (looked like the
                // preference hadn't applied).
                MenuBarLabel(summary: .init(worstState: nil, activeCount: 0),
                             style: "cost", costToday: 0)
                MenuBarLabel(summary: .init(worstState: .working, activeCount: 2),
                             style: "limit", costToday: 0, hottestLimit: 43)
                MenuBarLabel(summary: .init(worstState: .waitingForInput, activeCount: 1),
                             limitDanger: true, style: "limit", hottestLimit: 94)
                MenuBarLabel(summary: .init(worstState: .working, activeCount: 2),
                             style: "trend",
                             sparkline: Sparkline.image(
                                dailyDollars: [4.1, 12.6, 2.0, 18.2, 9.4, 22.9, 15.3]))
            }
            .padding(8))))

        // Session drill-in: the expanded row with everything it can show —
        // full prompt, the pending question (hook detail), timings, cwd,
        // and the inline actions.
        var drill = row("drill", "checkout-service", .waitingForInput,
                        entrypoint: "claude-desktop", startedMinutesAgo: 14,
                        title: "add rate limiting to the checkout API and cover it with tests",
                        cost: SessionCost(dollars: 12.38, totalTokens: 2_100_000,
                                          inputTokens: 1_900_000, outputTokens: 200_000,
                                          cacheReadTokens: 4_800_000_000,
                                          cacheWriteTokens: 130_000_000))
        drill.hookDetail = HookSignal(
            kind: .waitingForInput, timestamp: now,
            detail: "Should I run the database migration now, or wait for staging?")
        drill.cwd = "/Users/dev/work/checkout-service"
        results.append(("session-drilldown", AnyView(
            SessionRowView(row: drill, isExpanded: true)
                .frame(width: 330)
                .padding(8))))

        // Session History window, empty state — a brand-new install has no
        // finished sessions yet. HistoryView is SwiftUI-native so it renders
        // here (the Preferences tabs are AppKit Form/TabView and stay invisible
        // to ImageRenderer, verified by eye instead). A *populated* History
        // fixture needs applyFixture to accept a `sessionHistory:` array —
        // sessionHistory is private(set) on AppModel, so it can't be injected
        // from here yet (tracked as a cross-file follow-up).
        let historyEmptyModel = AppModel()
        historyEmptyModel.applyFixture(
            rows: [], summary: MenuBarSummary(worstState: nil, activeCount: 0),
            usageLimits: [:], installedAgents: allInstalled, runningAgentIDs: [],
            todayCost: SessionCost(), costHistory: [])
        results.append(("history-empty", AnyView(HistoryView(model: historyEmptyModel))))

        return results
    }
}
