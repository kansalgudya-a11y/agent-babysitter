import XCTest
@testable import AgentBabysitterCore

/// Claude Code's parallel sub-agents (the Task tool) write to
/// `<root>/<project>/<session>/subagents/agent-*.jsonl`. A one-level scan never
/// saw them, so every dollar those agents spent went uncounted.
final class SubAgentDiscoveryTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("babysitter-subagents-\(UUID().uuidString)")
        let subagents = root.appendingPathComponent("my-project/session-uuid/subagents")
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: root.appendingPathComponent("my-project/session-uuid.jsonl"))
        try Data("{}\n".utf8).write(to: subagents.appendingPathComponent("agent-abc123.jsonl"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testFindsNestedSubAgentTranscripts() {
        let found = SessionDirectoryScanner.recentTranscripts(under: root, maxAge: 3600)
        let ids = Set(found.map(\.sessionID))
        XCTAssertTrue(ids.contains("session-uuid"), "the main session")
        XCTAssertTrue(ids.contains("agent-abc123"),
                      "a parallel sub-agent's transcript must be discovered too")
    }

    func testSubAgentIsAttributedToItsProjectNotTheSubagentsFolder() {
        let found = SessionDirectoryScanner.recentTranscripts(under: root, maxAge: 3600)
        let sub = found.first { $0.sessionID == "agent-abc123" }
        XCTAssertEqual(sub?.projectDirName, "my-project",
                       "must not be attributed to the literal 'subagents' directory")
    }

    func testAdapterProjectDirNameWalksBackToTheProject() {
        let adapter = ClaudeCodeAdapter(transcriptRoot: root)
        let nested = root.appendingPathComponent("my-project/session-uuid/subagents/agent-abc123.jsonl")
        XCTAssertEqual(adapter.projectDirName(forTranscript: nested), "my-project")
        let plain = root.appendingPathComponent("my-project/session-uuid.jsonl")
        XCTAssertEqual(adapter.projectDirName(forTranscript: plain), "my-project")
    }

    func testStaleTranscriptsAreStillExcluded() throws {
        let old = root.appendingPathComponent("my-project/session-uuid/subagents/agent-old.jsonl")
        try Data("{}\n".utf8).write(to: old)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -7200)], ofItemAtPath: old.path)
        let found = SessionDirectoryScanner.recentTranscripts(under: root, maxAge: 3600)
        XCTAssertFalse(found.map(\.sessionID).contains("agent-old"))
    }
}
