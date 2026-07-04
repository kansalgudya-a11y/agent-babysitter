import SwiftUI
import AgentBabysitterCore

@main
struct AgentBabysitterApp: App {

    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            MenuBarLabel(summary: model.summary, limitDanger: model.limitDanger)
        }
        .menuBarExtraStyle(.window)

        Settings {
            PreferencesView(model: model)
        }
    }
}

/// Colored dot of the worst active state + active session count; a quiet
/// monochrome glyph when nothing needs attention.
struct MenuBarLabel: View {
    let summary: MenuBarSummary
    var limitDanger = false

    var body: some View {
        // ⚠️ prefixes everything when any usage window is at 90%+ — the
        // babysitter's job is exactly this warning.
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
