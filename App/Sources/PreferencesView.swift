import SwiftUI
import AgentBabysitterCore

struct PreferencesView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Stall detection") {
                HStack {
                    Slider(value: $model.stallThresholdMinutes, in: 1...30, step: 1) {
                        Text("Stall threshold")
                    }
                    Text("\(Int(model.stallThresholdMinutes)) min")
                        .monospacedDigit()
                        .frame(width: 52, alignment: .trailing)
                }
                Text("A session mid-turn with no transcript growth for this long shows as 🔴 Stalled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Notifications") {
                Toggle("Needs your input (🟡)", isOn: $model.notifyWaiting)
                Toggle("Turn finished (🔵)", isOn: $model.notifyDone)
                Toggle("Session stalled (🔴)", isOn: $model.notifyStalled)
            }

            Section("Precision mode") {
                Toggle("Use Claude Code hooks for exact signals", isOn: $model.precisionModeEnabled)
                Text("Installs Notification and Stop hooks into ~/.claude/settings.json for exact waiting-for-input moments. Existing hooks are never touched; turning this off removes only ours.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = model.hooksError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Toggle("Launch at login", isOn: $model.launchAtLogin)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}
