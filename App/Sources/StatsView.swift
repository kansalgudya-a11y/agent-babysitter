import SwiftUI
import AgentBabysitterCore

struct WeekStats: Equatable {
    var costByAgent: [String: Double] = [:]
    var sessionCount = 0
    var activeMinutes: Double = 0
}

/// "This week" at a glance — the product's thesis made visible: how much
/// your agents worked while you did something else.
struct StatsView: View {
    @ObservedObject var model: AppModel

    private static let agentNames = ["claude-code": "Claude Code", "codex": "Codex",
                                     "antigravity": "Antigravity",
                                     "antigravity-ide": "Antigravity IDE",
                                     "antigravity-cli": "Antigravity CLI"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("This week")
                .font(.title2).fontWeight(.semibold)

            HStack(spacing: 24) {
                stat(value: hoursWorked, label: "agents worked\nwhile you did other things")
                stat(value: "\(model.weekStats.sessionCount)", label: "sessions\nwatched")
                stat(value: totalCost, label: "estimated usage\nvalue (API prices)")
            }

            if model.costHistory.count > 1 {
                Divider()
                Text("Daily cost")
                    .font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                CostTrendView(history: model.costHistory)
            }

            if !model.weekStats.costByAgent.isEmpty {
                Divider()
                Text("By agent")
                    .font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                ForEach(model.weekStats.costByAgent.sorted { $0.value > $1.value },
                        id: \.key) { agent, dollars in
                    HStack {
                        Text(Self.agentNames[agent] ?? agent)
                            .font(.callout)
                        Spacer()
                        Text(String(format: "~$%.2f", dollars))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
            Text("Everything above is computed on this Mac from your agents' own files. Nothing is sent anywhere.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(width: 420, height: 420, alignment: .topLeading)
    }

    private func stat(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title.monospacedDigit()).fontWeight(.semibold)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var hoursWorked: String {
        let minutes = Int(model.weekStats.activeMinutes)
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    private var totalCost: String {
        String(format: "~$%.0f", model.weekStats.costByAgent.values.reduce(0, +))
    }
}
