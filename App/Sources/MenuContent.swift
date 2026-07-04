import SwiftUI
import AgentBabysitterCore

struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.noAgentsDetected {
                OnboardingView(model: model)
            } else if model.rows.isEmpty {
                Text("No agent sessions in the last 24 hours.")
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.rows) { row in
                            SessionRowView(row: row)
                                .onTapGesture { TerminalFocuser.focusSession(row) }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 360)
            }

            if model.processDetectionDegraded {
                Label("Process detection paused — Ended states may lag.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }

            Divider()
            HStack {
                Text("Today: \(model.todayCost.display)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.notificationsMuted.toggle()
                } label: {
                    Image(systemName: model.notificationsMuted ? "bell.slash" : "bell")
                }
                .buttonStyle(.borderless)
                .help(model.notificationsMuted ? "Notifications muted" : "Mute notifications")
                Button {
                    openSettings()
                    NSApp.activate()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Preferences")
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 320)
    }
}

struct SessionRowView: View {
    let row: SessionRow

    var body: some View {
        HStack(spacing: 8) {
            Text(row.state.dotEmoji)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.projectName)
                    .fontWeight(.medium)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(row.state.label)
                    if row.agentID != "claude-code" {
                        Text("· \(row.agentName)")
                    }
                    if row.isDesktopApp {
                        Text("· Desktop")
                    }
                    if let elapsed = elapsedText {
                        Text("· \(elapsed)")
                    }
                    if row.isUnreadable {
                        Text("· transcript unreadable")
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
    }

    private var elapsedText: String? {
        guard row.state != .ended, let start = row.turnStartedAt else { return nil }
        let seconds = Int(Date().timeIntervalSince(start))
        guard seconds >= 0 else { return nil }
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
                ? String(format: "$%.2f + %@ tok (pricing unknown)", dollars, tokens)
                : "\(tokens) tok · pricing unknown"
        }
        return String(format: "$%.2f", dollars)
    }
}

struct OnboardingView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "binoculars")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No coding agents detected")
                .fontWeight(.semibold)
            Text("Agent Babysitter watches Claude Code (~/.claude), Codex (~/.codex), and Antigravity (~/.gemini). None have session data yet — run any of them once, then retry. The app also picks new agents up automatically while running.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") { model.retryDetection() }
        }
        .padding()
    }
}
