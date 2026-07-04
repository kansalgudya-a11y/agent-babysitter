import SwiftUI
import AgentBabysitterCore

struct PreferencesView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("General") {
                Toggle("Start Agent Babysitter when I log in", isOn: $model.launchAtLogin)
                Button("Show the welcome tips again") { model.resetWelcome() }
                    .disabled(!model.welcomeDismissed)
            }

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

            Section {
                Toggle(isOn: $model.precisionModeEnabled) {
                    Text("Exact status from Claude Code")
                    Text("Uses Claude Code's own notifications so \"needs you\" and \"done\" are exact instead of inferred. Adds one small entry to Claude Code's settings; your other settings are never touched, and turning this off removes only our entry.")
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
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
