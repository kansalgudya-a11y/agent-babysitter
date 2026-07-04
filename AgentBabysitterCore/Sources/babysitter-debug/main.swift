import Foundation
import AgentBabysitterCore

// Dogfooding tool: run the exact pipeline the menu bar renders from and
// print what it shows. `swift run babysitter-debug`

let root = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude/projects")

let store = SessionStore(configuration: .init(projectsRoot: root))
await store.bootstrap()

let processes = (try? await ShellProcessScanner().scanClaudeProcesses()) ?? []
print("live claude processes:")
for process in processes {
    print("  pid \(process.pid)  cwd \(process.cwd)")
}

await store.processesUpdated(.init(processes: processes, degraded: false))

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
    let cost = row.cost.hasUnknownPricing
        ? "\(row.cost.totalTokens) tok (pricing unknown)"
        : String(format: "$%.2f", row.cost.dollars)
    let host = row.isDesktopApp ? "desktop" : (row.entrypoint ?? "?")
    print("  [\(row.state)] \(row.projectName)  session=\(row.id.prefix(8))  "
        + "pid=\(row.pid.map(String.init) ?? "-")  host=\(host)  \(cost)")
}

let today = await store.todayCost()
print(String(format: "\ntoday's total: $%.2f", today.dollars))
