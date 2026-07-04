import SwiftUI
import AgentBabysitterCore

struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @State private var showLegend = false
    @State private var showCostInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if showLegend { LegendView() }

            if model.noAgentsDetected {
                OnboardingView(model: model)
            } else {
                if !model.welcomeDismissed {
                    WelcomeCard(model: model)
                }
                if model.rows.isEmpty {
                    emptyState
                } else {
                    sessionList
                }
            }

            if model.processDetectionDegraded {
                Label("Having trouble checking which sessions are still running — statuses may lag for a moment.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }

            Divider()
            if !limitEntries.isEmpty {
                limitsSection
                Divider()
            }
            footer
        }
        .frame(width: 330)
    }

    // MARK: - Pieces

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Agent Babysitter")
                    .font(.headline)
                Text(statusPhrase)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                withAnimation(.easeOut(duration: 0.15)) { showLegend.toggle() }
            } label: {
                Image(systemName: showLegend ? "questionmark.circle.fill" : "questionmark.circle")
            }
            .buttonStyle(.borderless)
            .help("What do the colors mean?")
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    /// Plain-language one-liner for the top of the dropdown.
    private var statusPhrase: String {
        let rows = model.rows
        let waiting = rows.filter { $0.state == .waitingForInput }.count
        let stalled = rows.filter { $0.state == .stalled }.count
        let working = rows.filter { $0.state == .working }.count
        if waiting > 0 { return waiting == 1 ? "1 agent needs you" : "\(waiting) agents need you" }
        if stalled > 0 { return stalled == 1 ? "1 agent may be stuck" : "\(stalled) agents may be stuck" }
        if working > 0 { return working == 1 ? "1 agent working" : "\(working) agents working" }
        if rows.contains(where: { $0.state == .done }) { return "All caught up" }
        return "Watching for agent sessions"
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("All quiet right now.")
                .foregroundStyle(.secondary)
            Text("Start a Claude Code, Codex, or Antigravity session and it will appear here automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    /// Sessions grouped per agent app, in a fixed friendly order; rows keep
    /// their needs-attention-first ordering within each group.
    private var groupedRows: [(agentID: String, agentName: String, rows: [SessionRow])] {
        let order = ["claude-code": 0, "codex": 1,
                     "antigravity": 2, "antigravity-ide": 3, "antigravity-cli": 4]
        return Dictionary(grouping: model.rows, by: \.agentID)
            .sorted { (order[$0.key] ?? 99, $0.key) < (order[$1.key] ?? 99, $1.key) }
            .map { (agentID: $0.key,
                    agentName: $0.value.first?.agentName ?? $0.key,
                    rows: $0.value) }
    }

    private var sessionList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(groupedRows, id: \.agentID) { group in
                    HStack(spacing: 6) {
                        Text(group.agentName)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                        Text("\(group.rows.count)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        VStack { Divider() }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    ForEach(group.rows) { row in
                        SessionRowView(row: row, onDismiss: { model.dismiss($0) })
                            .onTapGesture { TerminalFocuser.focusSession(row) }
                    }
                }
            }
            .padding(.vertical, 6)
        }
        .frame(maxHeight: 380)
    }

    /// One entry per agent that has sessions listed: its 5h reading when the
    /// agent records one locally, an honest "no data" otherwise.
    private var limitEntries: [(id: String, name: String, limit: UsageLimitSnapshot?)] {
        groupedRows.map { group in
            // Antigravity surfaces share one Gemini quota; none expose it.
            (id: group.agentID, name: group.agentName, limit: model.usageLimits[group.agentID])
        }
    }

    private var limitsSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("5-hour limits")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            ForEach(limitEntries, id: \.id) { entry in
                HStack(spacing: 8) {
                    Text(entry.name)
                        .font(.caption)
                        .frame(width: 92, alignment: .leading)
                        .lineLimit(1)
                    if let limit = entry.limit {
                        if let resets = limit.resetsAt, resets < Date() {
                            ProgressView(value: 0)
                                .tint(.green)
                            Text("reset")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .trailing)
                                .help("The 5-hour window rolled over; fresh numbers arrive with the next agent activity.")
                        } else {
                            ProgressView(value: min(limit.usedPercent, 100) / 100)
                                .tint(limit.usedPercent >= 90 ? .red
                                      : limit.usedPercent >= 70 ? .orange : .green)
                            Text("\(Int(limit.usedPercent))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .trailing)
                                .help(limitHelp(limit))
                        }
                    } else {
                        Text("not shared by this app")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .help("This agent doesn't record its limit usage on your Mac, and Agent Babysitter never guesses or phones home.")
                        Spacer()
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func limitHelp(_ limit: UsageLimitSnapshot) -> String {
        var parts: [String] = []
        if let plan = limit.plan { parts.append("\(plan.capitalized) plan") }
        if let resets = limit.resetsAt, resets > Date() {
            let minutes = Int(resets.timeIntervalSinceNow / 60)
            parts.append(minutes >= 60 ? "resets in \(minutes / 60)h \(minutes % 60)m"
                                       : "resets in \(minutes)m")
        }
        let age = Int(Date().timeIntervalSince(limit.capturedAt) / 60)
        parts.append(age < 1 ? "just updated" : "as of \(age)m ago")
        return parts.joined(separator: " · ")
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("Today: \(model.todayCost.display)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                showCostInfo.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .popover(isPresented: $showCostInfo, arrowEdge: .bottom) {
                Text("Estimated from token usage at API list prices.\nOn a subscription plan (Pro/Max) this is not an extra charge — it shows the value of today's usage.")
                    .font(.caption)
                    .padding(10)
                    .frame(width: 240)
            }
            Spacer()
            Button {
                model.notificationsMuted.toggle()
            } label: {
                Image(systemName: model.notificationsMuted ? "bell.slash" : "bell")
            }
            .buttonStyle(.borderless)
            .help(model.notificationsMuted ? "Alerts are off — click to turn back on"
                                           : "Pause all alerts")
            Button {
                openSettings()
                NSApp.activate()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Explains the status colors in plain words.
struct LegendView: View {
    private let items: [(String, String, String)] = [
        ("🟢", "Working", "the agent is actively doing things"),
        ("🟡", "Needs you", "waiting for your answer or a permission"),
        ("🔵", "Done", "finished — ready for your next prompt"),
        ("🔴", "Maybe stuck", "mid-task but silent for a while"),
        ("⚫", "Ended", "the session has exited"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items, id: \.0) { dot, name, meaning in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(dot).font(.caption)
                    Text(name).font(.caption).fontWeight(.medium)
                    Text("— \(meaning)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Click a session to jump to it · right-click for more options")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05))
    }
}

/// One-time intro shown until dismissed.
struct WelcomeCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("👋 Welcome!")
                .font(.subheadline).fontWeight(.semibold)
            Text("Agent Babysitter keeps an eye on your AI coding agents so you don't have to keep switching windows. The dot in your menu bar shows the session that most needs you, and you'll get a notification when an agent wants input or finishes.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Got it") { model.dismissWelcome() }
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
    }
}

struct SessionRowView: View {
    let row: SessionRow
    var onDismiss: (SessionRow) -> Void = { _ in }
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(row.state.dotEmoji)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.projectName)
                    .fontWeight(.medium)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(row.state.label)
                    if row.isDesktopApp {
                        Text("· Desktop")
                    }
                    if let elapsed = elapsedText {
                        Text("· \(elapsed)")
                    }
                    if row.isUnreadable {
                        Text("· can't read this session's log")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text(row.cost.display)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .background(hovering ? Color.primary.opacity(0.07) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .onHover { hovering = $0 }
        .help("Click to jump to this session")
        .contextMenu {
            if let url = row.transcriptURL {
                Button("Reveal Session Log in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            Button("Copy Session ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.id, forType: .string)
            }
            Divider()
            Button("Hide Until Next Activity") { onDismiss(row) }
        }
    }

    private var elapsedText: String? {
        guard let start = row.turnStartedAt else { return nil }
        // Finished turns show their frozen duration; anything else counts up.
        let end: Date
        switch row.state {
        case .working, .waitingForInput, .stalled: end = Date()
        case .done: end = row.lastGrowthAt ?? Date()
        case .ended: return nil
        }
        let seconds = Int(end.timeIntervalSince(start))
        guard seconds > 0 else { return nil }
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }
}

extension SessionCost {
    /// "$1.22", or token counts when pricing is unknown — never guessed dollars.
    var display: String {
        if dollars == 0 && totalTokens == 0 && !hasUnknownPricing {
            return "—"  // no readable usage at all (e.g. Antigravity)
        }
        if hasUnknownPricing {
            let tokens = totalTokens >= 1000 ? "\(totalTokens / 1000)k" : "\(totalTokens)"
            return dollars > 0
                ? String(format: "~$%.2f + %@ tokens", dollars, tokens)
                : "\(tokens) tokens"
        }
        return String(format: "~$%.2f", dollars)
    }
}

struct OnboardingView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "binoculars")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No coding agents yet")
                .fontWeight(.semibold)
            Text("Agent Babysitter works with:")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Label("Claude Code — terminal or desktop app", systemImage: "checkmark.circle")
                Label("Codex — CLI or desktop app", systemImage: "checkmark.circle")
                Label("Antigravity — app, IDE, or agy CLI", systemImage: "checkmark.circle")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text("Run any of them once and this list fills in by itself — no setup needed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Check Again") { model.retryDetection() }
        }
        .padding()
    }
}
