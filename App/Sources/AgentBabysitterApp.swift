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
                         costLabel: model.moneyCompact(model.todayCost.dollars),
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

        Window("Session History", id: "history") {
            HistoryView(model: model)
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
    /// Pre-formatted compact cost in the user's currency ("$581", "₹55k").
    var costLabel = ""
    var hottestLimit: Double?

    var body: some View {
        // ⚠️ prefixes everything when any usage window is at 90%+ — the
        // babysitter's job is exactly this warning.
        Group {
        switch style {
        case "cost" where costToday > 0:
            composed(text: costLabel.isEmpty ? "$\(Int(costToday))" : costLabel)
        case "limit":
            if let hottestLimit {
                composed(text: "\(Int(hottestLimit))%")
            } else {
                statusLabel
            }
        default:
            statusLabel
        }
        }
        .accessibilityLabel(a11yDescription)
    }

    /// MenuBarExtra labels render reliably only as a single Text, and emoji
    /// glyphs at text size inflate the line height, sinking the item below
    /// its neighbors - so the label is one CONCATENATED Text with the emoji
    /// segments at a smaller size and a slight baseline lift.
    private func composed(text: String?, count: Int? = nil) -> some View {
        var label = Text("")
        if limitDanger {
            label = label + Text("⚠️ ").font(.system(size: 10)).baselineOffset(1)
        }
        if summary.activeCount > 0, let state = summary.worstState {
            label = label + Text("\(state.dotEmoji) ").font(.system(size: 9)).baselineOffset(1)
        }
        if let text {
            label = label + Text(text).font(.system(size: 13, weight: .medium))
        }
        if let count {
            label = label + Text("\(count)").font(.system(size: 13, weight: .medium))
        }
        return label
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
                Text("⚠️").font(.system(size: 10))
            } else {
                Image(systemName: "moon.zzz")
            }
        } else {
            composed(text: nil, count: summary.activeCount)
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
