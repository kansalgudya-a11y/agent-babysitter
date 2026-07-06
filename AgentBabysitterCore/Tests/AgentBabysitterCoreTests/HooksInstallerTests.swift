import XCTest
@testable import AgentBabysitterCore

final class HooksInstallerTests: XCTestCase {

    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func hookEntries(_ root: [String: Any], _ event: String) -> [[String: Any]] {
        (root["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []
    }

    private func commands(in entries: [[String: Any]]) -> [String] {
        entries.flatMap { entry in
            (entry["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        }
    }

    // MARK: - Install

    func testInstallIntoMissingSettingsCreatesHooks() throws {
        let result = try HooksInstaller.settingsWithHooksInstalled(nil)
        let root = try json(result)
        for event in ["Notification", "Stop", "PreToolUse"] {
            let cmds = commands(in: hookEntries(root, event))
            XCTAssertEqual(cmds.count, 1, "\(event) should have exactly our hook")
            XCTAssertTrue(cmds[0].contains(HooksInstaller.marker))
            XCTAssertTrue(cmds[0].contains("events.jsonl"))
        }
    }

    func testInstallPreservesExistingUserHooksAndSettings() throws {
        let existing = """
        {
          "model": "opus",
          "hooks": {
            "Notification": [
              {"hooks": [{"type": "command", "command": "say 'user hook'"}]}
            ],
            "PreToolUse": [
              {"matcher": "Bash", "hooks": [{"type": "command", "command": "/usr/local/bin/lint"}]}
            ]
          }
        }
        """
        let result = try HooksInstaller.settingsWithHooksInstalled(Data(existing.utf8))
        let root = try json(result)

        // Untouched user config
        XCTAssertEqual(root["model"] as? String, "opus")

        // User hooks kept first (matcher and all), ours appended after
        for (event, userCommand) in [("Notification", "say 'user hook'"),
                                     ("PreToolUse", "/usr/local/bin/lint")] {
            let cmds = commands(in: hookEntries(root, event))
            XCTAssertEqual(cmds.count, 2, event)
            XCTAssertEqual(cmds[0], userCommand, event)
            XCTAssertTrue(cmds[1].contains(HooksInstaller.marker), event)
        }
        XCTAssertEqual(hookEntries(root, "PreToolUse").first?["matcher"] as? String, "Bash")

        // Stop added fresh
        XCTAssertEqual(commands(in: hookEntries(root, "Stop")).count, 1)
    }

    func testInstallIsIdempotent() throws {
        let once = try HooksInstaller.settingsWithHooksInstalled(nil)
        let twice = try HooksInstaller.settingsWithHooksInstalled(once)
        let root = try json(twice)
        XCTAssertEqual(commands(in: hookEntries(root, "Notification")).count, 1)
        XCTAssertEqual(commands(in: hookEntries(root, "Stop")).count, 1)
        XCTAssertEqual(commands(in: hookEntries(root, "PreToolUse")).count, 1)
    }

    func testInstallThrowsOnMalformedSettingsWithoutWriting() {
        let malformed = Data("{ this is not json".utf8)
        XCTAssertThrowsError(try HooksInstaller.settingsWithHooksInstalled(malformed)) { error in
            XCTAssertTrue(error is HooksInstaller.SettingsError)
        }
        // Non-object JSON is also unparseable-as-settings
        XCTAssertThrowsError(try HooksInstaller.settingsWithHooksInstalled(Data("[1,2]".utf8)))
    }

    // MARK: - Remove

    func testRemoveDeletesOnlyOurHooks() throws {
        let existing = """
        {
          "hooks": {
            "Notification": [
              {"hooks": [{"type": "command", "command": "say 'user hook'"}]}
            ]
          }
        }
        """
        let installed = try HooksInstaller.settingsWithHooksInstalled(Data(existing.utf8))
        let removed = try HooksInstaller.settingsWithHooksRemoved(installed)
        let root = try json(removed)

        XCTAssertEqual(commands(in: hookEntries(root, "Notification")), ["say 'user hook'"])
        XCTAssertTrue(hookEntries(root, "Stop").isEmpty)
        XCTAssertTrue(hookEntries(root, "PreToolUse").isEmpty)
    }

    func testRemoveOnCleanSettingsIsNoOp() throws {
        let clean = Data("{\"model\": \"opus\"}".utf8)
        let result = try HooksInstaller.settingsWithHooksRemoved(clean)
        XCTAssertEqual(try json(result)["model"] as? String, "opus")
    }

    func testRemoveThrowsOnMalformedSettings() {
        XCTAssertThrowsError(try HooksInstaller.settingsWithHooksRemoved(Data("not json".utf8)))
    }

    func testInstallDetection() throws {
        XCTAssertFalse(HooksInstaller.isInstalled(in: nil))
        XCTAssertFalse(HooksInstaller.isInstalled(in: Data("{}".utf8)))
        let installed = try HooksInstaller.settingsWithHooksInstalled(nil)
        XCTAssertTrue(HooksInstaller.isInstalled(in: installed))
    }
}

final class HookEventParserTests: XCTestCase {

    func testParsesNotificationEvent() {
        let line = """
        {"session_id":"abc-123","transcript_path":"/x/y.jsonl","hook_event_name":"Notification",\
        "message":"Claude needs your permission to use Bash"}
        """
        let event = HookEventParser.parse(line: Data(line.utf8))
        XCTAssertEqual(event?.signal?.sessionID, "abc-123")
        XCTAssertEqual(event?.signal?.kind, .waitingForInput)
        XCTAssertNil(event?.usage)
    }

    func testParsesStopEvent() {
        let line = "{\"session_id\":\"abc-123\",\"hook_event_name\":\"Stop\",\"stop_hook_active\":false}"
        let event = HookEventParser.parse(line: Data(line.utf8))
        XCTAssertEqual(event?.signal?.sessionID, "abc-123")
        XCTAssertEqual(event?.signal?.kind, .turnCompleted)
    }

    /// PreToolUse fires when a tool starts EXECUTING — the exact signal that
    /// an approved (or auto-approved) tool is running, not waiting.
    func testParsesPreToolUseEvent() {
        let line = """
        {"session_id":"abc-123","hook_event_name":"PreToolUse",\
        "tool_name":"Bash","tool_input":{"command":"xcodebuild"}}
        """
        let event = HookEventParser.parse(line: Data(line.utf8))
        XCTAssertEqual(event?.signal?.sessionID, "abc-123")
        XCTAssertEqual(event?.signal?.kind, .toolStarted)
        XCTAssertEqual(event?.signal?.detail, "Bash")
    }

    func testIgnoresUnknownEventsAndGarbage() {
        XCTAssertNil(HookEventParser.parse(line: Data("{\"hook_event_name\":\"SubagentStop\",\"session_id\":\"x\"}".utf8)))
        XCTAssertNil(HookEventParser.parse(line: Data("garbage".utf8)))
        XCTAssertNil(HookEventParser.parse(line: Data()))
    }

    /// A status-line update: no hook_event_name, but rate_limits present.
    func testParsesUsageFromStatusLineUpdate() {
        let line = """
        {"session_id":"abc-123","model":{"id":"claude-opus-4-8"},"cost":{"total_cost_usd":1.2},\
        "rate_limits":{"five_hour":{"used_percentage":34.5,"resets_at":"2026-07-05T18:00:00Z"},\
        "seven_day":{"used_percentage":12,"resets_at":1783573200}}}
        """
        let event = HookEventParser.parse(line: Data(line.utf8))
        XCTAssertNil(event?.signal)
        XCTAssertEqual(event?.usage?.usedPercent, 34.5)
        XCTAssertEqual(event?.usage?.windowMinutes, 300)
        XCTAssertEqual(event?.usage?.resetsAt,
                       ISO8601DateFormatter().date(from: "2026-07-05T18:00:00Z"))
        XCTAssertEqual(event?.usage?.isLive, false)
        XCTAssertEqual(event?.usage?.weeklyUsedPercent, 12)
        XCTAssertEqual(event?.usage?.weeklyResetsAt, Date(timeIntervalSince1970: 1_783_573_200))
    }

    func testNotificationCarriesTheQuestion() {
        let line = """
        {"session_id":"abc","hook_event_name":"Notification",\
        "message":"Claude needs your permission to use Bash"}
        """
        let event = HookEventParser.parse(line: Data(line.utf8))
        XCTAssertEqual(event?.signal?.detail, "Claude needs your permission to use Bash")
    }

    func testStopCarriesFirstLineOfReplyTrimmedAndCapped() {
        let long = String(repeating: "x", count: 200)
        let line = """
        {"session_id":"abc","hook_event_name":"Stop",\
        "last_assistant_message":"  All 191 tests pass.\\nDetails follow…"}
        """
        let event = HookEventParser.parse(line: Data(line.utf8))
        XCTAssertEqual(event?.signal?.detail, "All 191 tests pass.")

        let capped = HookEventParser.parse(line: Data(
            "{\"session_id\":\"x\",\"hook_event_name\":\"Stop\",\"last_assistant_message\":\"\(long)\"}".utf8))
        XCTAssertEqual(capped?.signal?.detail?.count, 118)  // 117 + ellipsis
    }

    func testMissingSevenDayLeavesWeeklyNil() {
        let line = #"{"rate_limits":{"five_hour":{"used_percentage":10}}}"#
        let event = HookEventParser.parse(line: Data(line.utf8))
        XCTAssertEqual(event?.usage?.usedPercent, 10)
        XCTAssertNil(event?.usage?.weeklyUsedPercent)
    }

    /// A Stop hook that also carries rate_limits yields both.
    func testStopEventWithRateLimitsYieldsSignalAndUsage() {
        let line = """
        {"session_id":"abc-123","hook_event_name":"Stop",\
        "rate_limits":{"five_hour":{"used_percentage":80,"resets_at":1751731200}}}
        """
        let event = HookEventParser.parse(line: Data(line.utf8))
        XCTAssertEqual(event?.signal?.kind, .turnCompleted)
        XCTAssertEqual(event?.usage?.usedPercent, 80)
        XCTAssertEqual(event?.usage?.resetsAt, Date(timeIntervalSince1970: 1_751_731_200))
    }

    func testUsagePercentIsClampedAndMalformedIgnored() {
        let over = HookEventParser.usageSnapshot(from:
            ["rate_limits": ["five_hour": ["used_percentage": 250.0]]])
        XCTAssertEqual(over?.usedPercent, 100)
        XCTAssertNil(HookEventParser.usageSnapshot(from:
            ["rate_limits": ["five_hour": ["used_percentage": "lots"]]]))
        XCTAssertNil(HookEventParser.usageSnapshot(from: ["rate_limits": ["five_hour": [:]]]))
    }
}

final class StatusLineInstallerTests: XCTestCase {

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testInstallIntoFreshSettingsCapturesWithoutPassThrough() throws {
        let result = try StatusLineInstaller.settingsWithStatusLineInstalled(
            nil, eventLogPath: "/tmp/events.jsonl", originalCommandPath: "/tmp/orig.sh")
        let statusLine = try XCTUnwrap(object(result.settings)["statusLine"] as? [String: Any])
        let command = try XCTUnwrap(statusLine["command"] as? String)
        XCTAssertEqual(statusLine["type"] as? String, "command")
        XCTAssertTrue(command.contains("/tmp/events.jsonl"))
        XCTAssertFalse(command.contains("/tmp/orig.sh"), "nothing to pass through to")
        XCTAssertTrue(command.contains(StatusLineInstaller.marker))
        XCTAssertNil(result.backup)
        XCTAssertNil(result.originalCommand)
    }

    func testInstallWrapsExistingStatusLineAndBacksItUp() throws {
        let existing = Data("""
        {"statusLine":{"type":"command","command":"~/my-statusline.sh","padding":0},"model":"opus"}
        """.utf8)
        let result = try StatusLineInstaller.settingsWithStatusLineInstalled(
            existing, eventLogPath: "/tmp/events.jsonl", originalCommandPath: "/tmp/orig.sh")

        let root = try object(result.settings)
        XCTAssertEqual(root["model"] as? String, "opus", "unrelated settings untouched")
        let statusLine = try XCTUnwrap(root["statusLine"] as? [String: Any])
        let command = try XCTUnwrap(statusLine["command"] as? String)
        XCTAssertTrue(command.contains("/tmp/orig.sh"), "must pass through to the original")
        XCTAssertEqual(statusLine["padding"] as? Int, 0, "extra keys preserved")
        XCTAssertEqual(result.originalCommand, "~/my-statusline.sh")
        let backup = try object(try XCTUnwrap(result.backup))
        XCTAssertEqual(backup["command"] as? String, "~/my-statusline.sh")
    }

    func testInstallIsIdempotent() throws {
        let first = try StatusLineInstaller.settingsWithStatusLineInstalled(nil)
        let second = try StatusLineInstaller.settingsWithStatusLineInstalled(first.settings)
        XCTAssertEqual(first.settings, second.settings)
        XCTAssertNil(second.backup)
    }

    func testRemovalRestoresBackedUpOriginal() throws {
        let existing = Data("""
        {"statusLine":{"type":"command","command":"~/my-statusline.sh","padding":0}}
        """.utf8)
        let installed = try StatusLineInstaller.settingsWithStatusLineInstalled(existing)
        let restored = try StatusLineInstaller.settingsWithStatusLineRemoved(
            installed.settings, backup: installed.backup)
        let statusLine = try XCTUnwrap(object(restored)["statusLine"] as? [String: Any])
        XCTAssertEqual(statusLine["command"] as? String, "~/my-statusline.sh")
        XCTAssertEqual(statusLine["padding"] as? Int, 0)
    }

    func testRemovalWithoutBackupDeletesKey() throws {
        let installed = try StatusLineInstaller.settingsWithStatusLineInstalled(nil)
        let removed = try StatusLineInstaller.settingsWithStatusLineRemoved(
            installed.settings, backup: nil)
        XCTAssertNil(try object(removed)["statusLine"])
    }

    func testRemovalNeverTouchesForeignStatusLine() throws {
        let foreign = Data("{\"statusLine\":{\"type\":\"command\",\"command\":\"mine.sh\"}}".utf8)
        let removed = try StatusLineInstaller.settingsWithStatusLineRemoved(foreign, backup: nil)
        let statusLine = try XCTUnwrap(object(removed)["statusLine"] as? [String: Any])
        XCTAssertEqual(statusLine["command"] as? String, "mine.sh")
    }

    func testMalformedSettingsThrowBeforeAnyWrite() {
        XCTAssertThrowsError(
            try StatusLineInstaller.settingsWithStatusLineInstalled(Data("not json".utf8)))
        XCTAssertThrowsError(
            try StatusLineInstaller.settingsWithStatusLineRemoved(Data("not json".utf8), backup: nil))
    }
}
