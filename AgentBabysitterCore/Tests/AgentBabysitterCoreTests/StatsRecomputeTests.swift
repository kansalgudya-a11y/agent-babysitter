import XCTest
@testable import AgentBabysitterCore

/// Rebuilding history from transcripts must reproduce reality: a resumed
/// session's copied conversation counted once, and parallel sub-agents counted
/// at all.
final class StatsRecomputeTests: XCTestCase {

    private var root: URL!

    /// 1M output tokens on Opus 4.8 = $25 exactly, which makes the arithmetic
    /// legible in the assertions below.
    private func assistantLine(_ id: String) -> String {
        """
        {"type":"assistant","timestamp":"2026-07-04T10:00:30.000Z","message":{"model":"claude-opus-4-8",\
        "id":"\(id)","role":"assistant","content":[{"type":"text","text":"x"}],"stop_reason":"end_turn",\
        "usage":{"input_tokens":0,"output_tokens":1000000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}

        """
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("recompute-\(UUID().uuidString)")
        let project = root.appendingPathComponent("my-project")
        let subagents = project.appendingPathComponent("session-b/subagents")
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)

        // Original session: one message.
        try Data(assistantLine("msg_shared").utf8)
            .write(to: project.appendingPathComponent("session-a.jsonl"))
        // Resumed session: copies msg_shared verbatim, then adds its own.
        try Data((assistantLine("msg_shared") + assistantLine("msg_new")).utf8)
            .write(to: project.appendingPathComponent("session-b.jsonl"))
        // A parallel sub-agent, nested where Claude Code actually puts them.
        try Data(assistantLine("msg_subagent").utf8)
            .write(to: subagents.appendingPathComponent("agent-xyz.jsonl"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testCountsEachMessageOnceAndIncludesSubAgents() {
        let totals = StatsRecompute.run(adapters: [ClaudeCodeAdapter(transcriptRoot: root)])
        let day = "2026-07-04"
        // 3 distinct messages × $25 = $75. Per-file dedupe would have said $100
        // (msg_shared billed twice); missing sub-agents would have said $50.
        XCTAssertEqual(totals.dayTotals[day] ?? 0, 75, accuracy: 0.01)
        XCTAssertEqual(totals.costByAgent[day]?["claude-code"] ?? 0, 75, accuracy: 0.01)
        XCTAssertEqual(totals.costByModel[day]?["claude-opus-4-8"] ?? 0, 75, accuracy: 0.01)
    }

    func testSubAgentSpendIsAttributedToItsProjectNotSubagents() {
        let totals = StatsRecompute.run(adapters: [ClaudeCodeAdapter(transcriptRoot: root)])
        let byProject = totals.costByProject["2026-07-04"] ?? [:]
        XCTAssertEqual(byProject["my-project"] ?? 0, 75, accuracy: 0.01)
        XCTAssertNil(byProject["subagents"], "never a project literally named 'subagents'")
    }

    func testDaysWithoutTranscriptsAreNotReported() {
        let totals = StatsRecompute.run(adapters: [ClaudeCodeAdapter(transcriptRoot: root)])
        XCTAssertEqual(totals.days, ["2026-07-04"],
                       "caller must keep stored values for days it can't rebuild")
    }
}
