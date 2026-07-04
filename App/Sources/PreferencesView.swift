import SwiftUI
import AgentBabysitterCore

struct PreferencesView: View {
    @ObservedObject var model: AppModel
    @StateObject private var license = LicenseManager()
    @StateObject private var updates = UpdateChecker()
    @State private var licenseKeyInput = ""

    var body: some View {
        TabView {
            Form {
                generalTab
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                notificationsTab
            }
            .formStyle(.grouped)
            .tabItem { Label("Notifications", systemImage: "bell.badge") }

            Form {
                advancedTab
            }
            .formStyle(.grouped)
            .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }

            Form {
                licenseTab
            }
            .formStyle(.grouped)
            .tabItem { Label("License & Updates", systemImage: "checkmark.seal") }
        }
        .frame(width: 480, height: 420)
    }

    @ViewBuilder private var generalTab: some View {
            Section("General") {
                Toggle("Start Agent Babysitter when I log in", isOn: $model.launchAtLogin)
                Button("Show the welcome tips again") { model.resetWelcome() }
                    .disabled(!model.welcomeDismissed)
            }

    }

    @ViewBuilder private var notificationsTab: some View {
            Section {
                Toggle(isOn: $model.notifyWaiting) {
                    Text("🟡 An agent needs my input")
                    Text("A question or a permission prompt is waiting for you.")
                }
                Toggle(isOn: $model.notifyDone) {
                    Text("🔵 An agent finishes")
                    Text("Its reply is ready to read.")
                }
                Toggle(isOn: $model.notifyStalled) {
                    Text("🔴 An agent looks stuck")
                    Text("Mid-task but silent for too long (time set below).")
                }
                Toggle(isOn: $model.notifyLimit) {
                    Text("⚠️ An agent nears its 5-hour limit")
                    Text("One heads-up per window when usage crosses the level below, so a long task doesn't burn the whole window unnoticed.")
                }
                if model.notifyLimit {
                    HStack {
                        Slider(value: $model.limitAlertThreshold, in: 50...95, step: 5) {
                            Text("Warn at")
                        }
                        Text("\(Int(model.limitAlertThreshold))%")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            } header: {
                Text("Notify me when…")
            } footer: {
                Text("The bell button in the menu pauses all of these at once.")
            }

            Section("Stuck detection") {
                HStack {
                    Slider(value: $model.stallThresholdMinutes, in: 1...30, step: 1) {
                        Text("Consider an agent stuck after")
                    }
                    Text("\(Int(model.stallThresholdMinutes)) min")
                        .monospacedDigit()
                        .frame(width: 52, alignment: .trailing)
                }
                Text("How long an agent can stay silent mid-task before it shows as 🔴. Shorter catches problems faster; longer avoids false alarms on big tasks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

    }

    @ViewBuilder private var advancedTab: some View {
            Section {
                Toggle(isOn: $model.precisionModeEnabled) {
                    Text("Exact status from Claude Code")
                    Text("Uses Claude Code's own notifications so \"needs you\" and \"done\" are exact instead of inferred. Adds one small entry to Claude Code's settings; your other settings are never touched, and turning this off removes only our entry.")
                }
                Toggle(isOn: $model.claudeUsageMeterEnabled) {
                    Text("Claude usage meter (works offline)")
                    Text("Shows your real 5-hour usage % with no internet, by recording the numbers Claude Code computes for its terminal status line. It updates whenever a Claude session runs in a terminal — the % covers your whole account, so it reflects desktop app usage too. If you only ever use the desktop app, turn on Live usage below instead. Your own status line keeps working, and turning this off restores it exactly.")
                }
                Toggle(isOn: $model.liveUsageEnabled) {
                    Text("Live usage % (connects to the internet)")
                    Text("Off by default, everything else stays fully offline. When on, the app uses your existing Claude login (terminal or desktop app) to ask Anthropic for your real 5-hour and weekly usage — a tiny 1-token request, every 5 minutes while Claude is in use. It only ever contacts api.anthropic.com. Codex and Antigravity already show real usage with no network.")
                }
                if model.liveUsageEnabled, let status = model.liveUsageStatus {
                    Label(status, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let error = model.hooksError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Advanced")
            } footer: {
                Text("Everything runs on your Mac. Agent Babysitter makes no network connections and collects nothing.")
            }

    }

    @ViewBuilder private var licenseTab: some View {
            Section {
                switch license.state {
                case .activated(let maskedKey):
                    LabeledContent("License") {
                        Label("Activated (key \(maskedKey))", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    }
                    Button("Deactivate on this Mac") {
                        Task { await license.deactivate() }
                    }
                    .disabled(license.busy)
                case .unlicensed:
                    LabeledContent("License") {
                        Text(LicenseManager.isBeta ? "Free beta — everything unlocked"
                                                   : "Not activated")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        TextField("License key", text: $licenseKeyInput)
                            .textFieldStyle(.roundedBorder)
                        Button("Activate") {
                            Task { await license.activate(key: licenseKeyInput) }
                        }
                        .disabled(license.busy || licenseKeyInput.isEmpty)
                    }
                }
                if let error = license.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("License")
            } footer: {
                Text("Activation contacts api.lemonsqueezy.com once, only when you press the button. Nothing else about your usage is ever sent.")
            }

            Section("About") {
                LabeledContent("Version") {
                    Text(updates.currentVersion)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Check for updates") {
                        Task { await updates.check() }
                    }
                    .disabled(updates.status == .checking)
                    switch updates.status {
                    case .idle: EmptyView()
                    case .checking:
                        ProgressView().controlSize(.small)
                    case .upToDate(let version):
                        Text("You're on the latest version (\(version)).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .available(let version, let url):
                        Button("Get \(version)") { updates.openReleasePage(url) }
                            .buttonStyle(.link)
                    case .failed(let message):
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Button("Copy diagnostics") {
                    let defaults = UserDefaults.standard
                    let report = """
                    Agent Babysitter \(updates.currentVersion)
                    limits: \(defaults.string(forKey: "debugUsageLimits") ?? defaults.dictionary(forKey: "debugUsageLimits").map(String.init(describing:)) ?? "-")
                    agents: \(defaults.string(forKey: "debugAgents") ?? "-")
                    toggles: precision=\(model.precisionModeEnabled) meter=\(model.claudeUsageMeterEnabled) live=\(model.liveUsageEnabled) alerts=\(model.notifyLimit)@\(Int(model.limitAlertThreshold))%
                    """
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                }
                .help("Copies version, current readings, and toggle states — paste into a bug report. Contains no file contents or keys.")
            }
    }
}
