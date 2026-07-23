import SwiftUI
import AppKit
import AgentBabysitterCore

/// "What did I run?" — the durable log of finished sessions the live menu
/// tidies away. Grouped by local day, newest first; each row can reveal its
/// transcript in Finder. Read-only history built from the agents' own files.
struct HistoryView: View {
    @ObservedObject var model: AppModel
    /// Transcript files found to be gone the moment the user clicked "Reveal in
    /// Finder" — so we show an honest "no longer on disk" note in place of a
    /// button that would otherwise silently do nothing on a pruned transcript.
    @State private var missingTranscripts: Set<String> = []

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
                if let title = entry.title, title != entry.project {
                    Text("“\(title)”")
                        .font(.caption).italic()
                        .foregroundStyle(.secondary).lineLimit(1)
                }
                Text("\(entry.agentName) · \(Self.timeLabel(entry.endedAt))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                // No false "0 tok" and no wall of em-dashes: show a real figure
                // when we have one, an honest "no token data" for activity-based
                // agents that record none, and nothing at all when the cost is
                // genuinely unknown. A blank reads as "unknown"; a column of
                // identical "—" read as a broken table (verified finding: on real
                // data 79% of rows had no cost, so the dash was the dominant mark).
                if let amount = historyAmount(entry) {
                    Text(amount)
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if entry.dollars > 0, entry.cost.hasTokens {
                    Text(entry.cost.tokenBreakdown)
                        .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.tail)
                }
                if let path = entry.transcriptPath, !path.isEmpty {
                    if missingTranscripts.contains(entry.id) {
                        // The button only ever revealed the file in Finder; once the
                        // agent has pruned the transcript there is nothing to reveal,
                        // so say so rather than let the click do nothing.
                        Text("Transcript no longer on disk")
                            .font(.caption2).foregroundStyle(.tertiary)
                    } else {
                        Button("Reveal in Finder") {
                            if FileManager.default.fileExists(atPath: path) {
                                NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                            } else {
                                missingTranscripts.insert(entry.id)
                            }
                        }
                        .buttonStyle(.link).font(.caption2)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// The trailing amount, or nil when there is no honest figure to show:
    /// dollars when priced, the token split when it was persisted, the legacy
    /// single figure for old entries, an explicit "no token data" for
    /// activity-based agents that record none, and nil (render nothing) when the
    /// cost is simply unknown — so the column never becomes a wall of em-dashes.
    private func historyAmount(_ entry: SessionHistoryEntry) -> String? {
        if entry.dollars > 0 { return model.money(entry.dollars) }
        if entry.cost.hasTokens { return entry.cost.tokenBreakdown }
        if entry.totalTokens > 0 { return "\(SessionCost.abbreviatedCount(entry.totalTokens)) tok" }
        // Match the live row: an activity-based agent records no tokens on disk,
        // which is different from a session we simply couldn't read.
        if entry.isActivityBased == true { return "no token data" }
        return nil
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
