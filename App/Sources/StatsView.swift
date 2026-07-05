import SwiftUI
import Charts
import AgentBabysitterCore

/// One local day of observed agent activity.
struct DayStat: Equatable, Identifiable {
    let day: Date
    let dollars: Double
    let byAgent: [String: Double]
    var byProject: [String: Double] = [:]
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
                                     "antigravity-cli": "Antigravity CLI",
                                     "gemini": "Gemini", "gemini-cli": "Gemini CLI",
                                     "cursor": "Cursor", "manus": "Manus"]

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
                bucketChart(title: "Estimated cost per \(unitName) (\(model.displayCurrency.symbol))",
                            color: .accentColor) { $0.dollars * model.effectiveRate }
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
                        Text(model.money(dollars))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if !costByProject.isEmpty {
                Divider()
                Text("By project")
                    .font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                ForEach(costByProject.sorted { $0.value > $1.value }.prefix(8), id: \.key) { project, dollars in
                    HStack {
                        Text(project).font(.callout).lineLimit(1)
                        Spacer()
                        Text(model.money(dollars))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            let tokens = model.todayCost
            if tokens.inputTokens + tokens.outputTokens + tokens.cacheReadTokens
                + tokens.cacheWriteTokens > 0 {
                Divider()
                Text("Today's tokens")
                    .font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                Text("input \(SessionCost.abbreviatedCount(tokens.inputTokens)) · output \(SessionCost.abbreviatedCount(tokens.outputTokens)) · cache-write \(SessionCost.abbreviatedCount(tokens.cacheWriteTokens)) · cache-read \(SessionCost.abbreviatedCount(tokens.cacheReadTokens))")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Cache reads are cheap; output and cache writes are where spend goes.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            HStack(alignment: .bottom) {
                Text("Everything above is computed on this Mac from your agents' own files, since the day Agent Babysitter was installed. Nothing is sent anywhere.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Export CSV…") { exportCSV() }
                    .controlSize(.small)
                    .help("Saves every recorded day: date, cost, active minutes, sessions, and per-agent dollars.")
            }
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

    /// At most ~6 axis labels regardless of how much history exists.
    private var thinnedBucketStarts: [Date] {
        let starts = buckets.map(\.start)
        let step = max(1, Int((Double(starts.count) / 6).rounded(.up)))
        return starts.enumerated().compactMap { $0.offset % step == 0 ? $0.element : nil }
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

    var costByProject: [String: Double] {
        selectedDays.reduce(into: [:]) { totals, day in
            for (project, dollars) in day.byProject { totals[project, default: 0] += dollars }
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
                // Explicit labels at (thinned) bucket starts: automatic tick
                // generation over a short domain repeats one label four times
                // ("Jul 26 · Jul 26 · Jul 26 · Jul 26").
                switch range {
                case .today, .week:
                    AxisMarks(values: .stride(by: .day)) {
                        AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
                    }
                case .threeMonths:
                    AxisMarks(values: thinnedBucketStarts) {
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                        AxisGridLine()
                    }
                case .allTime:
                    AxisMarks(values: thinnedBucketStarts) {
                        AxisValueLabel(format: .dateTime.month(.abbreviated).year())
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

    private func exportCSV() {
        let agents = Array(Set(model.statsDays.flatMap { $0.byAgent.keys })).sorted()
        var csv = "date,total_dollars,active_minutes,sessions"
            + agents.map { ",\($0)_dollars" }.joined() + "\n"
        for day in model.statsDays {
            csv += "\(DailyCostHistory.key(for: day.day)),"
                + "\(String(format: "%.2f", day.dollars)),"
                + "\(String(format: "%.1f", day.activeMinutes)),\(day.sessions)"
                + agents.map { ",\(String(format: "%.2f", day.byAgent[$0] ?? 0))" }.joined()
                + "\n"
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "agent-babysitter-stats.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        if panel.runModal() == .OK, let url = panel.url {
            try? csv.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private var totalCost: String {
        model.money(selectedDays.reduce(0) { $0 + $1.dollars })
    }
}
