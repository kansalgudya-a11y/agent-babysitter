import SwiftUI
import AppKit
import AgentBabysitterCore

/// "What did I run?" — the durable log of finished sessions the live menu
/// tidies away. Grouped by local day, newest first; each row can reopen its
/// transcript. Read-only history built from the agents' own files.
struct HistoryView: View {
    @ObservedObject var model: AppModel

    private var groups: [(day: Date, entries: [SessionHistoryEntry])] {
        let cal = Calendar.current
        let byDay = Dictionary(grouping: model.sessionHistory) {
            cal.startOfDay(for: $0.endedAt)
        }
        return byDay.sorted { $0.key > $1.key }.map { (day: $0.key, entries: $0.value) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Session history").font(.title2).fontWeight(.semibold)
                Spacer()
                Text("\(model.sessionHistory.count) sessions")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.sessionHistory.isEmpty {
                Text("No finished sessions yet. Once an agent session ends, it's logged here — even after it disappears from the menu.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: 460, alignment: .leading)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(groups, id: \.day) { group in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(Self.dayLabel(group.day))
                                    .font(.caption).fontWeight(.semibold)
                                    .foregroundStyle(.secondary)
                                ForEach(group.entries) { entry in
                                    row(entry)
                                    Divider()
                                }
                            }
                        }
                    }
                }
                .frame(minWidth: 520, minHeight: 300, maxHeight: 520)
            }
            Text("Built on this Mac from your agents' own transcript files. Nothing is uploaded.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(minWidth: 560)
    }

    @ViewBuilder private func row(_ entry: SessionHistoryEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.project).fontWeight(.medium).lineLimit(1)
                Text("\(entry.agentName) · \(Self.timeLabel(entry.endedAt))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(entry.dollars > 0 ? model.money(entry.dollars)
                     : "\(SessionCost.abbreviatedCount(entry.totalTokens)) tok")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if let path = entry.transcriptPath, !path.isEmpty {
                    Button("Open transcript") {
                        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                    }
                    .buttonStyle(.link).font(.caption2)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private static func dayLabel(_ day: Date) -> String {
        let f = DateFormatter()
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        f.dateStyle = .medium
        return f.string(from: day)
    }

    private static func timeLabel(_ date: Date) -> String {
        let f = DateFormatter(); f.timeStyle = .short
        return f.string(from: date)
    }
}
