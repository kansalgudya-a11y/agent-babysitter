import Foundation
import AgentBabysitterCore

// Dogfooding tool: run the exact pipeline the menu bar renders from and
// print what it shows. `swift run babysitter-debug`

// OpenClawAdapter.allSurfaces() MUST precede ClaudeCodeAdapter() so the SDK
// surface claims OpenClaw's temp-workspace transcripts first (mirrors AppModel).
let adapters: [any AgentAdapter] =
    OpenClawAdapter.allSurfaces()
    + [ClaudeCodeAdapter(excludeProjectDir: OpenClawAdapter.isSDKWorkspaceProjectDir),
       CodexAdapter(), HermesAdapter()]
    + AntigravityAdapter.allSurfaces()
    + GeminiAdapter.allSurfaces() + [CursorAdapter(), ManusAdapter()]
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

let limits = await store.usageLimits()
// Not all windows are five hours — Codex's primary is weekly, Cursor's a
// monthly billing cycle — so each line states its own length.
if limits.isEmpty {
    print("\nusage limits: none recorded locally")
} else {
    print("\nusage limits:")
    for (agentID, limit) in limits.sorted(by: { $0.key < $1.key }) {
        let resets = limit.resetsAt.map {
            $0 < Date() ? "window reset" : "resets in \(Int($0.timeIntervalSinceNow / 60))m"
        } ?? "no reset time"
        let pct = limit.usedPercent.map { "\(Int($0))%" } ?? "—%"
        print("  [\(agentID)] \(pct) of \(limit.windowMinutes / 60)h window"
            + "  plan=\(limit.plan ?? "?")  live=\(limit.isLive)  \(resets)")
    }
}

// Only the PLAN-WIDE bucket (limit_name absent/null) becomes the Codex
// reading; model-scoped ones ("GPT-5.3-Codex-Spark") are separate allowances
// that would mask it. If OpenAI ever labels the plan-wide bucket too, the row
// honestly degrades to "no recent reading" — a silent failure from the outside.
// Listing the buckets actually seen is what tells a support report
// "no readings on disk" apart from "only model-scoped readings on disk".
// The CONFIGURED adapter, not a fresh default one: a support report is
// usually being taken because the root is unusual, and a diagnostic that
// silently reports on a different directory than the store read is worse
// than no diagnostic.
let codexBuckets = (adapters.compactMap { $0 as? CodexAdapter }.first ?? CodexAdapter())
    .recentUsageBuckets()
if !codexBuckets.isEmpty {
    print("\ncodex quota buckets seen on disk (newest rollouts):")
    for bucket in codexBuckets {
        let pct = bucket.usedPercent.map { "\(Int($0))%" } ?? "—%"
        let window = bucket.windowMinutes.map { "\($0 / 60)h" } ?? "?"
        print("  limit_id=\(bucket.limitID ?? "?")  limit_name=\(bucket.limitName ?? "null")"
            + "  \(pct) of \(window)"
            + "  \(bucket.limitName == nil ? "← plan-wide, this is the reading" : "(ignored)")")
    }
}
