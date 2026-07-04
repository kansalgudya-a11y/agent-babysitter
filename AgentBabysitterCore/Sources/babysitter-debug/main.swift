import Foundation
import AgentBabysitterCore

// Dogfooding tool: run the exact pipeline the menu bar renders from and
// print what it shows. `swift run babysitter-debug`

let adapters: [any AgentAdapter] =
    [ClaudeCodeAdapter(), CodexAdapter()] + AntigravityAdapter.allSurfaces()
let store = SessionStore(configuration: .init(
    projectsRoot: ClaudeCodeAdapter().transcriptRoot,
    adapters: adapters))
await store.bootstrap()

let processes = (try? await ShellProcessScanner().scanProcesses(for: adapters)) ?? [:]
print("live agent processes:")
for (agentID, agentProcesses) in processes.sorted(by: { $0.key < $1.key }) {
    for process in agentProcesses {
        print("  [\(agentID)] pid \(process.pid)  cwd \(process.cwd)")
    }
}

await store.processesUpdated(.init(processesByAdapter: processes, degraded: false))

let summary = await store.menuBarSummary()
let dot: String
switch summary.worstState {
case .working: dot = "🟢"
case .waitingForInput: dot = "🟡"
case .done: dot = "🔵"
case .stalled: dot = "🔴"
case .ended: dot = "⚫"
case nil: dot = "(quiet)"
}
print("\nmenu bar label:  \(dot) \(summary.activeCount)")

print("\nsession rows:")
for row in await store.rows() {
    let cost: String
    if row.cost.hasUnknownPricing {
        cost = "\(row.cost.totalTokens) tok (pricing unknown)"
    } else if row.cost.dollars == 0 && row.cost.totalTokens == 0 {
        cost = "—"
    } else {
        cost = String(format: "$%.2f", row.cost.dollars)
    }
    let host = row.isDesktopApp ? "desktop" : (row.entrypoint ?? "?")
    print("  [\(row.state)] \(row.agentName): \(row.projectName)  session=\(row.id.prefix(8))  "
        + "pid=\(row.pid.map(String.init) ?? "-")  host=\(host)  \(cost)")
}

let today = await store.todayCost()
print(String(format: "\ntoday's total: $%.2f", today.dollars))
