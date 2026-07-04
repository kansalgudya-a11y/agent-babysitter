import SwiftUI
import AppKit
import AgentBabysitterCore

/// Renders every notable UI state to PNGs for visual QA:
/// `AgentBabysitter --ui-snapshots <dir>`. Exits when done — never runs in
/// a normal launch.
@MainActor
enum UISnapshots {

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
            let model = AppModel()
            configure(model)
            results.append((name, AnyView(MenuContent(model: model,
                                                      forceShowAllLimits: showAll))))
        }

        let now = Date()
        func row(_ id: String, _ project: String, _ state: SessionState,
                 agent: (String, String) = ("claude-code", "Claude Code"),
                 entrypoint: String? = nil, dollars: Double = 0,
                 startedMinutesAgo: Double = 6, unreadable: Bool = false) -> SessionRow {
            SessionRow(id: id, projectName: project, state: state,
                       turnStartedAt: now.addingTimeInterval(-startedMinutesAgo * 60),
                       lastGrowthAt: now.addingTimeInterval(-30), isUnreadable: unreadable,
                       pid: 123, cwd: nil,
                       cost: SessionCost(dollars: dollars),
                       entrypoint: entrypoint, agentID: agent.0, agentName: agent.1)
        }

        func limit(_ used: Double?, plan: String?, resetsInMinutes: Double = 135,
                   weekly: Double? = nil, live: Bool = false,
                   capturedMinutesAgo: Double = 2) -> UsageLimitSnapshot {
            UsageLimitSnapshot(usedPercent: used, windowMinutes: 300,
                               resetsAt: now.addingTimeInterval(resetsInMinutes * 60),
                               capturedAt: now.addingTimeInterval(-capturedMinutesAgo * 60),
                               plan: plan,
                               isLive: live, weeklyUsedPercent: weekly,
                               weeklyResetsAt: now.addingTimeInterval(3.4 * 86_400))
        }

        let allInstalled = [("claude-code", "Claude Code"), ("codex", "Codex"),
                            ("antigravity", "Antigravity"),
                            ("antigravity-ide", "Antigravity IDE"),
                            ("antigravity-cli", "Antigravity CLI")]
        let history = (0..<7).map { (day: now.addingTimeInterval(Double($0 - 6) * 86_400),
                                     dollars: [12.0, 48.2, 3.1, 96.4, 0, 157.5, 22.9][$0]) }

        menu("menu-normal") { model in
            model.applyFixture(
                rows: [row("a", "checkout-service", .working, dollars: 12.38),
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
                              "antigravity-ide": limit(5, plan: "Google AI Pro"),
                              "antigravity-cli": limit(5, plan: "Google AI Pro")],
                installedAgents: allInstalled,
                runningAgentIDs: ["claude-code", "codex"],
                todayCost: SessionCost(dollars: 877.53), costHistory: history,
                limitDanger: true, processDetectionDegraded: true)
        }

        menu("menu-quiet") { model in
            model.applyFixture(
                rows: [], summary: MenuBarSummary(worstState: nil, activeCount: 0),
                usageLimits: ["codex": limit(1, plan: "plus")],
                installedAgents: allInstalled, runningAgentIDs: [],
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
                           activeMinutes: wave * 3.2,
                           sessions: Int(wave / 12))
        }.reversed()

        func stats(_ name: String, _ range: StatsView.StatsRange) {
            let model = AppModel()
            model.applyFixture(
                rows: [], summary: MenuBarSummary(worstState: nil, activeCount: 0),
                usageLimits: [:], installedAgents: allInstalled, runningAgentIDs: [],
                todayCost: SessionCost(dollars: 22.9), costHistory: history,
                statsDays: Array(statsDays))
            results.append((name, AnyView(StatsView(model: model, initialRange: range))))
        }
        stats("stats-today", .today)
        stats("stats-week", .week)
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
                        AnyView(StatsView(model: singleDayModel, initialRange: .week))))

        // Settings (Form/TabView) is AppKit-backed and invisible to
        // ImageRenderer — verified by eye in the running app instead.
        results.append(("menubar-labels", AnyView(
            HStack(spacing: 14) {
                MenuBarLabel(summary: .init(worstState: nil, activeCount: 0))
                MenuBarLabel(summary: .init(worstState: .working, activeCount: 3))
                MenuBarLabel(summary: .init(worstState: .waitingForInput, activeCount: 2),
                             limitDanger: true)
                MenuBarLabel(summary: .init(worstState: nil, activeCount: 0), limitDanger: true)
            }
            .padding(8))))

        return results
    }
}
