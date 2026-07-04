import SwiftUI
import Charts
import AgentBabysitterCore

struct WeekStats: Equatable {
    struct Day: Equatable, Identifiable {
        let day: Date
        let dollars: Double
        let activeMinutes: Double
        var id: Date { day }
    }
    var costByAgent: [String: Double] = [:]
    var sessionCount = 0
    var activeMinutes: Double = 0
    var days: [Day] = []

    init(costByAgent: [String: Double] = [:], sessionCount: Int = 0,
         activeMinutes: Double = 0,
         days: [(day: Date, dollars: Double, activeMinutes: Double)] = []) {
        self.costByAgent = costByAgent
        self.sessionCount = sessionCount
        self.activeMinutes = activeMinutes
        self.days = days.map { Day(day: $0.day, dollars: $0.dollars,
                                   activeMinutes: $0.activeMinutes) }
    }
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

            HStack(alignment: .top, spacing: 16) {
                stat(value: hoursWorked, label: "agents worked while\nyou did other things")
                stat(value: "\(model.weekStats.sessionCount)", label: "sessions\nwatched")
                stat(value: totalCost, label: "estimated usage\nvalue (API prices)")
            }

            if model.weekStats.days.count > 1 {
                Divider()
                // Dollars and hours live on very different scales — one
                // shared axis buries the smaller series, so: two charts.
                weekChart(title: "Estimated cost per day ($)",
                          color: .accentColor) { $0.dollars }
                weekChart(title: "Agent hours per day",
                          color: .orange.opacity(0.85)) { $0.activeMinutes / 60 }
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
            Text("Everything above is computed on this Mac from your agents' own files. Nothing is sent anywhere.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(width: 440, alignment: .topLeading)
    }

    private func weekChart(title: String, color: Color,
                           value: @escaping (WeekStats.Day) -> Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
            Chart(model.weekStats.days) { day in
                BarMark(x: .value("Day", day.day, unit: .day),
                        y: .value(title, value(day)))
                    .foregroundStyle(color)
                    .cornerRadius(2)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) {
                    AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
                }
            }
            .frame(height: 76)
        }
    }

    private func stat(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title.monospacedDigit()).fontWeight(.semibold)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hoursWorked: String {
        let minutes = Int(model.weekStats.activeMinutes)
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    private var totalCost: String {
        String(format: "~$%.0f", model.weekStats.costByAgent.values.reduce(0, +))
    }
}
