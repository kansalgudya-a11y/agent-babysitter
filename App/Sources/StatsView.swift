import SwiftUI
import Charts
import AgentBabysitterCore

/// One local day of observed agent activity.
struct DayStat: Equatable, Identifiable {
    let day: Date
    let dollars: Double
    let byAgent: [String: Double]
    let activeMinutes: Double
    let sessions: Int
    var id: Date { day }
}

/// Stats at a glance — the product's thesis made visible: how much your
/// agents worked while you did something else. Week, three months, or all
/// time; history accumulates from the day the app was first installed.
struct StatsView: View {
    @ObservedObject var model: AppModel
    @State private var range: StatsRange

    init(model: AppModel, initialRange: StatsRange = .week) {
        self.model = model
        _range = State(initialValue: initialRange)
    }

    enum StatsRange: String, CaseIterable, Identifiable {
        case today = "Today"
        case week = "Week"
        case threeMonths = "3 months"
        case allTime = "All time"
        var id: String { rawValue }

        var days: Int? {
            switch self {
            case .today: 1
            case .week: 7
            case .threeMonths: 91
            case .allTime: nil
            }
        }

        /// Chart bucket that keeps the bar count readable.
        var unit: Calendar.Component {
            switch self {
            case .today, .week: .day
            case .threeMonths: .weekOfYear
            case .allTime: .month
            }
        }
    }

    private static let agentNames = ["claude-code": "Claude Code", "codex": "Codex",
                                     "antigravity": "Antigravity",
                                     "antigravity-ide": "Antigravity IDE",
                                     "antigravity-cli": "Antigravity CLI"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title)
                    .font(.title2).fontWeight(.semibold)
                Spacer()
                Picker("", selection: $range) {
                    ForEach(StatsRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 300)
            }

            HStack(alignment: .top, spacing: 16) {
                stat(value: hoursWorked, label: "agents worked while\nyou did other things")
                stat(value: "\(selectedDays.reduce(0) { $0 + $1.sessions })",
                     label: "sessions\nwatched")
                stat(value: totalCost, label: "estimated usage\nvalue (API prices)")
            }

            // Even one bucket draws (a single bar beats a missing graph);
            // Today skips the time charts — one day has no time axis.
            if range != .today, !buckets.isEmpty {
                Divider()
                // Dollars and hours live on very different scales — one
                // shared axis buries the smaller series, so: two charts.
                bucketChart(title: "Estimated cost per \(unitName) ($)",
                            color: .accentColor) { $0.dollars }
                bucketChart(title: "Agent hours per \(unitName)",
                            color: .orange.opacity(0.85)) { $0.activeMinutes / 60 }
            }

            if !costByAgent.isEmpty {
                Divider()
                Text("By agent")
                    .font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                ForEach(costByAgent.sorted { $0.value > $1.value }, id: \.key) { agent, dollars in
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
            Text("Everything above is computed on this Mac from your agents' own files, since the day Agent Babysitter was installed. Nothing is sent anywhere.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(width: 460, alignment: .topLeading)
    }

    // MARK: - Range slicing and bucketing

    private var selectedDays: [DayStat] {
        guard let dayCount = range.days else { return model.statsDays }
        let cutoff = Calendar.current.startOfDay(
            for: Date().addingTimeInterval(-Double(dayCount - 1) * 86_400))
        return model.statsDays.filter { $0.day >= cutoff }
    }

    private struct Bucket: Identifiable {
        let start: Date
        var dollars: Double = 0
        var activeMinutes: Double = 0
        var id: Date { start }
    }

    /// Days grouped into the range's calendar unit so the bar count stays
    /// readable: 7 daily bars, ~13 weekly bars, or monthly bars.
    private var buckets: [Bucket] {
        var grouped: [Date: Bucket] = [:]
        let calendar = Calendar.current
        for day in selectedDays {
            let start = calendar.dateInterval(of: range.unit, for: day.day)?.start ?? day.day
            var bucket = grouped[start] ?? Bucket(start: start)
            bucket.dollars += day.dollars
            bucket.activeMinutes += day.activeMinutes
            grouped[start] = bucket
        }
        return grouped.values.sorted { $0.start < $1.start }
    }

    private var title: String {
        switch range {
        case .today: "Today"
        case .week: "This week"
        case .threeMonths: "Past 3 months"
        case .allTime: "All time"
        }
    }

    private var unitName: String {
        switch range.unit {
        case .day: "day"
        case .weekOfYear: "week"
        default: "month"
        }
    }

    private var costByAgent: [String: Double] {
        selectedDays.reduce(into: [:]) { totals, day in
            for (agent, dollars) in day.byAgent { totals[agent, default: 0] += dollars }
        }
    }

    // MARK: - Pieces

    private func bucketChart(title: String, color: Color,
                             value: @escaping (Bucket) -> Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
            Chart(buckets) { bucket in
                BarMark(x: .value("When", bucket.start, unit: range.unit),
                        y: .value(title, value(bucket)))
                    .foregroundStyle(color)
                    .cornerRadius(2)
            }
            .chartXAxis {
                switch range {
                case .today, .week:
                    AxisMarks(values: .stride(by: .day)) {
                        AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
                    }
                case .threeMonths:
                    AxisMarks(values: .stride(by: .month)) {
                        AxisValueLabel(format: .dateTime.month(.abbreviated))
                        AxisGridLine()
                    }
                case .allTime:
                    AxisMarks(values: .automatic) {
                        AxisValueLabel(format: .dateTime.month(.abbreviated).year(.twoDigits))
                        AxisGridLine()
                    }
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
        let minutes = Int(selectedDays.reduce(0) { $0 + $1.activeMinutes })
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    private var totalCost: String {
        String(format: "~$%.0f", selectedDays.reduce(0) { $0 + $1.dollars })
    }
}
