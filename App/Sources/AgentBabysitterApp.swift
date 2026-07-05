import SwiftUI
import AgentBabysitterCore

@main
struct AgentBabysitterApp: App {

    @StateObject private var model = AppModel()

    init() {
        UISnapshots.runIfRequested()  // exits after writing PNGs
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            MenuBarLabel(summary: model.summary, limitDanger: model.limitDanger,
                         style: model.menuBarStyle,
                         costToday: model.todayCost.dollars,
                         hottestLimit: model.hottestLimitPercent)
        }
        .menuBarExtraStyle(.window)

        Settings {
            PreferencesView(model: model)
        }

        Window("Welcome", id: "welcome") {
            WelcomeView(model: model)
        }
        .windowResizability(.contentSize)

        Window("Agent Stats", id: "stats") {
            StatsView(model: model)
        }
        .windowResizability(.contentSize)
    }
}

/// Colored dot of the worst active state + active session count; a quiet
/// monochrome glyph when nothing needs attention.
struct MenuBarLabel: View {
    let summary: MenuBarSummary
    var limitDanger = false
    var style = "status"
    var costToday = 0.0
    var hottestLimit: Double?

    var body: some View {
        // ⚠️ prefixes everything when any usage window is at 90%+ — the
        // babysitter's job is exactly this warning.
        let warning = limitDanger ? "⚠️ " : ""
        Group {
        switch style {
        case "cost" where costToday > 0:
            Text("\(warning)\(dot)$\(costToday, specifier: "%.0f")")
        case "limit":
            if let hottestLimit {
                Text("\(warning)\(dot)\(Int(hottestLimit))%")
            } else {
                statusLabel
            }
        default:
            statusLabel
        }
        }
        .accessibilityLabel(a11yDescription)
    }

    private var a11yDescription: String {
        var parts: [String] = []
        if summary.activeCount > 0, let state = summary.worstState {
            parts.append("\(summary.activeCount) agent sessions, worst state \(state.label)")
        } else {
            parts.append("no active agent sessions")
        }
        if limitDanger { parts.append("a usage limit is above 90 percent") }
        return "Agent Babysitter: " + parts.joined(separator: ", ")
    }

    /// The worst state's dot, kept in every style so "needs you" is never
    /// hidden by a display preference.
    private var dot: String {
        guard summary.activeCount > 0, let state = summary.worstState else { return "" }
        return "\(state.dotEmoji) "
    }

    @ViewBuilder private var statusLabel: some View {
        if summary.activeCount == 0 {
            if limitDanger {
                Text("⚠️")
            } else {
                Image(systemName: "moon.zzz")
            }
        } else if let state = summary.worstState {
            // Emoji render in color in the menu bar; SF Symbols would be
            // template-flattened to monochrome.
            Text("\(limitDanger ? "⚠️ " : "")\(state.dotEmoji) \(summary.activeCount)")
        } else {
            Image(systemName: "moon.zzz")
        }
    }
}

extension SessionState {
    var dotEmoji: String {
        switch self {
        case .working: "🟢"
        case .waitingForInput: "🟡"
        case .done: "🔵"
        case .stalled: "🔴"
        case .ended: "⚫"
        }
    }

    var label: String {
        switch self {
        case .working: "Working"
        case .waitingForInput: "Waiting for you"
        case .done: "Done"
        case .stalled: "Stalled"
        case .ended: "Ended"
        }
    }
}
