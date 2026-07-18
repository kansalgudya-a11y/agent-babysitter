import XCTest
@testable import AgentBabysitterCore

final class OpenClawAdapterTests: XCTestCase {

    // The real example on this machine (paths only — never the contents).
    private let sdkSlug =
        "-private-var-folders-hq-yhm5d7kj07gfh6d5b7bb2b840000gn-T-openclaw-crestodian-planner-q5Oo50"
    private let sdkCWD =
        "/private/var/folders/hq/yhm5d7kj07gfh6d5b7bb2b840000gn/T/openclaw-crestodian-planner-q5Oo50"
    private let sdkUUID = "d364b6a3-d52e-4678-b2eb-11ab673483bf"

    private func makeDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclaw-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    // MARK: - Borrowed-process presence (the .sdk false-drift bug)

    /// The .sdk surface reuses every `claude` pid, so it must disown any whose
    /// cwd is NOT an SDK temp workspace — otherwise a plain Claude Code user with
    /// zero OpenClaw sessions reads openclaw-sdk as running and gets a false
    /// "can't read your data" drift warning + a phantom limits row.
    func testSDKClaimsOnlyProcessesRunningInAWorkspace() {
        let sdk = OpenClawAdapter(surface: .sdk)
        XCTAssertTrue(sdk.claimsProcess(cwd: sdkCWD))
        XCTAssertFalse(sdk.claimsProcess(cwd: "/Users/jayagrawal"),
                       "a plain claude process must not read as openclaw-sdk")
        XCTAssertFalse(sdk.claimsProcess(cwd: "/Users/jayagrawal/dev/openclaw"),
                       "a Claude Code checkout of the OpenClaw source is not a workspace")
        XCTAssertTrue(OpenClawAdapter(surface: .gateway).claimsProcess(cwd: "/anything"),
                      "gateway pids are already openclaw-specific")
    }

    /// One gateway daemon multiplexes every native session; unpaired sessions
    /// must still read as alive. Safe because gateway is activity-based and can
    /// never produce a `.stalled` state.
    func testGatewayMatchSharesTheDaemonPidWithEverySession() {
        let gateway = OpenClawAdapter(surface: .gateway)
        let now = Date()
        let candidates = (0..<3).map {
            SessionMatchCandidate(sessionID: "s\($0)", projectDirName: "main",
                                  lastKnownCWD: nil, lastModified: now.addingTimeInterval(Double(-$0)))
        }
        let match = gateway.match(processes: [RunningProcess(pid: 7, cwd: "/")],
                                  candidates: candidates)
        XCTAssertEqual(Set(match.keys), ["s0", "s1", "s2"], "all sessions paired to the daemon")
        XCTAssertEqual(Set(match.values), [7])
    }

    // MARK: - SDK workspace classification

    func testIsSDKWorkspaceProjectDirAcceptsBothTempForms() {
        // macOS per-user temp (…/T/openclaw-…) and POSIX /tmp/openclaw-….
        XCTAssertTrue(OpenClawAdapter.isSDKWorkspaceProjectDir(sdkSlug))
        XCTAssertTrue(OpenClawAdapter.isSDKWorkspaceProjectDir(
            "-tmp-openclaw-crestodian-planner-q5Oo50"))
        XCTAssertTrue(OpenClawAdapter.isSDKWorkspaceProjectDir(
            "-private-tmp-openclaw-crestodian-planner-q5Oo50"))
    }

    func testIsSDKWorkspaceProjectDirRejectsSourceCheckouts() {
        // A user running ordinary Claude Code inside the OpenClaw source repo,
        // or any project that merely contains the word — never a temp workspace.
        XCTAssertFalse(OpenClawAdapter.isSDKWorkspaceProjectDir("-Users-jayagrawal-dev-openclaw"))
        XCTAssertFalse(OpenClawAdapter.isSDKWorkspaceProjectDir("-Users-x-openclaw"))
        XCTAssertFalse(OpenClawAdapter.isSDKWorkspaceProjectDir("-Users-x-projects-openclaw-clone"))
    }

    /// The temp marker alone is not enough — mkdtemp always appends six random
    /// alphanumerics, and a real project may legitimately be named `T-openclaw-…`.
    func testIsSDKWorkspaceProjectDirRejectsLookalikesWithoutMkdtempSuffix() {
        XCTAssertFalse(OpenClawAdapter.isSDKWorkspaceProjectDir(
            "-Users-jayagrawal-dev-T-openclaw-notes"), "a real project dir, not a temp root")
        XCTAssertFalse(OpenClawAdapter.isSDKWorkspaceProjectDir("-tmp-openclaw-scratch"),
                       "hand-made /tmp/openclaw-scratch has no mkdtemp suffix")
        XCTAssertTrue(OpenClawAdapter.isSDKWorkspaceProjectDir("-tmp-openclaw-foo-a1B2c3"))
    }

    func testFriendlyWorkspaceNameStripsTempRootAndRandomSuffix() {
        XCTAssertEqual(OpenClawAdapter.friendlyWorkspaceName(fromProjectDir: sdkSlug),
                       "openclaw-crestodian-planner")
    }

    // MARK: - Claude Code exclusion

    func testClaudeCodeDeclinesSDKWorkspaceButKeepsNormalAndSubagentPaths() {
        // Pure string/path classification — a stable non-symlinked fake root.
        let root = URL(fileURLWithPath: "/Users/test/.claude/projects")
        let adapter = ClaudeCodeAdapter(
            transcriptRoot: root, excludeProjectDir: OpenClawAdapter.isSDKWorkspaceProjectDir)

        let sdk = root.appendingPathComponent(sdkSlug)
            .appendingPathComponent("\(sdkUUID).jsonl")
        let normal = root.appendingPathComponent("-Users-dev-appA")
            .appendingPathComponent("aaa.jsonl")
        let subagent = root.appendingPathComponent("-Users-dev-appA")
            .appendingPathComponent("aaa/subagents/agent-x.jsonl")

        XCTAssertFalse(adapter.isTranscript(path: sdk.path),
                       "SDK workspace transcript belongs to the .sdk surface, not Claude Code")
        XCTAssertTrue(adapter.isTranscript(path: normal.path))
        XCTAssertTrue(adapter.isTranscript(path: subagent.path),
                      "a parallel sub-agent path is still Claude Code's")
    }

    /// The exclusion is opt-in. A store that never registers OpenClaw must keep
    /// counting these transcripts — dropping them would silently delete real
    /// spend from the user's totals.
    func testClaudeCodeWithoutTheExclusionStillClaimsSDKWorkspaces() throws {
        let root = URL(fileURLWithPath: "/Users/test/.claude/projects")
        let sdk = root.appendingPathComponent(sdkSlug)
            .appendingPathComponent("\(sdkUUID).jsonl")
        XCTAssertTrue(ClaudeCodeAdapter(transcriptRoot: root).isTranscript(path: sdk.path))

        let scanRoot = try makeDir("cc-scan-default")
        let d = scanRoot.appendingPathComponent(sdkSlug)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: d.appendingPathComponent("\(sdkUUID).jsonl"))
        let found = ClaudeCodeAdapter(transcriptRoot: scanRoot)
            .recentTranscripts(maxAge: 3600, now: Date())
        XCTAssertEqual(found.map(\.sessionID), [sdkUUID],
                       "unregistered OpenClaw ⇒ Claude Code must not drop the session")
    }

    func testClaudeCodeRecentTranscriptsSkipsSDKWorkspaceOnDisk() throws {
        let root = try makeDir("cc-scan")
        // An SDK workspace transcript and an ordinary project transcript.
        for (dir, name) in [(sdkSlug, sdkUUID), ("-Users-dev-appA", "aaa")] {
            let d = root.appendingPathComponent(dir)
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            try Data("{}\n".utf8).write(to: d.appendingPathComponent("\(name).jsonl"))
        }
        let found = ClaudeCodeAdapter(
            transcriptRoot: root, excludeProjectDir: OpenClawAdapter.isSDKWorkspaceProjectDir)
            .recentTranscripts(maxAge: 3600, now: Date())
        XCTAssertEqual(found.map(\.sessionID), ["aaa"],
                       "Claude Code must not scan OpenClaw's SDK workspaces")
    }

    // MARK: - .sdk surface

    func testSDKSurfaceClaimsWorkspaceTranscriptsAndReadsIdentity() {
        let root = URL(fileURLWithPath: "/Users/test/.claude/projects")
        let adapter = OpenClawAdapter(surface: .sdk, transcriptRoot: root)
        let url = root.appendingPathComponent(sdkSlug)
            .appendingPathComponent("\(sdkUUID).jsonl")

        XCTAssertEqual(adapter.id, "openclaw-sdk")
        XCTAssertEqual(adapter.displayName, "OpenClaw (Claude SDK)")
        XCTAssertFalse(adapter.isActivityBased, "SDK transcripts are real Claude Code JSONL")
        XCTAssertTrue(adapter.isTranscript(path: url.path))
        XCTAssertFalse(adapter.isTranscript(path: root
            .appendingPathComponent("-Users-dev-openclaw")
            .appendingPathComponent("\(sdkUUID).jsonl").path),
            "a source checkout is not an SDK workspace")
        XCTAssertEqual(adapter.sessionID(forTranscript: url), sdkUUID)
        XCTAssertEqual(adapter.projectDirName(forTranscript: url), "openclaw-crestodian-planner")
    }

    func testSDKParseLineDelegatesToClaudeCodeParser() {
        let adapter = OpenClawAdapter(surface: .sdk, transcriptRoot:
            URL(fileURLWithPath: "/Users/test/.claude/projects"))
        let line = """
        {"type":"assistant","entrypoint":"sdk-cli","cwd":"\(sdkCWD)",\
        "timestamp":"2026-07-10T10:00:00.000Z","message":{"model":"claude-opus-4-8",\
        "id":"msg_abc","role":"assistant","content":[{"type":"text","text":"ok"}],\
        "stop_reason":"end_turn","usage":{"input_tokens":12345,"output_tokens":678,\
        "cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        """
        guard case .entry(let entry) = adapter.parseLine(Data(line.utf8)),
              case .assistant(let payload) = entry.kind else {
            return XCTFail("expected a parsed assistant entry")
        }
        XCTAssertEqual(payload.model, "claude-opus-4-8")
        XCTAssertEqual(payload.usage?.inputTokens, 12345)
        XCTAssertEqual(payload.usage?.outputTokens, 678)
        XCTAssertEqual(entry.entrypoint, "sdk-cli")
    }

    // MARK: - .gateway surface

    func testGatewaySurfaceIdentityAndActivityOnly() {
        let adapter = OpenClawAdapter(surface: .gateway,
                                      transcriptRoot: URL(fileURLWithPath: "/root/.openclaw"))
        XCTAssertEqual(adapter.id, "openclaw")
        XCTAssertEqual(adapter.displayName, "OpenClaw")
        XCTAssertTrue(adapter.isActivityBased)
        XCTAssertEqual(adapter.focusBundleIdentifiers, [])
        XCTAssertEqual(adapter.cliExecutableNames, ["openclaw"])
        // Activity-based: the line parser is a no-op.
        guard case .malformed = adapter.parseLine(Data(#"{"type":"message"}"#.utf8)) else {
            return XCTFail("gateway must not parse lines")
        }
    }

    func testGatewayIsTranscriptAcceptsSessionsAndRejectsSiblings() throws {
        let root = URL(fileURLWithPath: "/root/.openclaw")
        let adapter = OpenClawAdapter(surface: .gateway, transcriptRoot: root)
        let sessions = root.appendingPathComponent("agents/main/sessions")

        XCTAssertTrue(adapter.isTranscript(
            path: sessions.appendingPathComponent("\(sdkUUID).jsonl").path))

        for sibling in ["sessions.json", "abc.checkpoint.3.jsonl", "abc.trajectory.jsonl",
                        "abc.reset.9.jsonl", "abc.jsonl.bak.123"] {
            XCTAssertFalse(adapter.isTranscript(
                path: sessions.appendingPathComponent(sibling).path),
                "must skip \(sibling)")
        }
        // Not inside a sessions/ dir.
        XCTAssertFalse(adapter.isTranscript(
            path: root.appendingPathComponent("agents/main/other/x.jsonl").path))
    }

    func testGatewayRecentTranscriptsHonoursMaxAgeAndReadsZeroCost() throws {
        let root = try makeDir("gw-scan")
        let sessions = root.appendingPathComponent("agents/main/sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let file = sessions.appendingPathComponent("\(sdkUUID).jsonl")
        try Data(#"{"type":"session","version":3}"#.utf8).write(to: file)

        let adapter = OpenClawAdapter(surface: .gateway, transcriptRoot: root)
        var found = adapter.recentTranscripts(maxAge: 3600, now: Date())
        XCTAssertEqual(found.map(\.sessionID), [sdkUUID])
        XCTAssertEqual(found.first?.projectDirName, "main")

        // Backdate past the window: dropped.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -7200)], ofItemAtPath: file.path)
        found = adapter.recentTranscripts(maxAge: 3600, now: Date())
        XCTAssertTrue(found.isEmpty, "maxAge is honoured")

        // The reader invents no usage.
        let reader = adapter.makeReader(url: file)
        try reader.refresh()
        XCTAssertEqual(reader.cost, SessionCost(), "gateway reports no tokens and no cost")
    }

    // MARK: - Root resolution

    func testNativeRootResolutionPrefersStateDirThenLegacy() {
        let home = URL(fileURLWithPath: "/Users/test")
        let fm = FileManager.default

        XCTAssertEqual(
            OpenClawAdapter.resolveNativeStoreRoot(
                environment: ["OPENCLAW_STATE_DIR": "/custom/state"], home: home, fileManager: fm).path,
            "/custom/state")

        // No env, no ~/.openclaw, no ~/.clawdbot on this synthetic home →
        // default to <home>/.openclaw.
        XCTAssertEqual(
            OpenClawAdapter.resolveNativeStoreRoot(environment: [:], home: home, fileManager: fm).path,
            "/Users/test/.openclaw")
    }

    func testNativeRootUsesLegacyClawdbotWhenPresent() throws {
        let home = try makeDir("home")
        let legacy = home.appendingPathComponent(".clawdbot")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        // ~/.openclaw does NOT exist, ~/.clawdbot does → legacy wins.
        XCTAssertEqual(
            OpenClawAdapter.resolveNativeStoreRoot(
                environment: [:], home: home, fileManager: .default).path,
            legacy.path)
    }

    // MARK: - Processes

    func testGatewayAgentPIDsMatchLauncherArgvNotUnrelatedNode() {
        let adapter = OpenClawAdapter(surface: .gateway,
                                      transcriptRoot: URL(fileURLWithPath: "/root/.openclaw"))
        let psArgs = """
        501 /opt/homebrew/bin/node /opt/homebrew/lib/node_modules/openclaw/openclaw.mjs gateway
        777 /opt/homebrew/bin/node /Users/x/app/server.js
        """
        // comm is `node` for both — matching must be on argv.
        XCTAssertEqual(adapter.agentPIDs(psComm: "501 node\n777 node", psArgs: psArgs), [501])
    }

    // MARK: - Store integration

    func testStoreAttributesSDKWorkspaceToOpenClawNotClaudeCode() async throws {
        let root = try makeDir("sdk-store")
        let dir = root.appendingPathComponent(sdkSlug)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(sdkUUID).jsonl")
        let userLine = "{\"type\":\"user\",\"cwd\":\"\(sdkCWD)\",\"entrypoint\":\"sdk-cli\"," +
            "\"timestamp\":\"2026-07-10T10:00:00.000Z\"," +
            "\"message\":{\"role\":\"user\",\"content\":\"hi\"}}"
        let usageLine = "{\"type\":\"assistant\",\"cwd\":\"\(sdkCWD)\"," +
            "\"timestamp\":\"2026-07-10T10:00:05.000Z\"," +
            "\"message\":{\"model\":\"claude-opus-4-8\",\"id\":\"msg_x\",\"role\":\"assistant\"," +
            "\"content\":[{\"type\":\"text\",\"text\":\"ok\"}],\"stop_reason\":\"end_turn\"," +
            "\"usage\":{\"input_tokens\":200000,\"output_tokens\":40000," +
            "\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}}}"
        try (userLine + "\n" + usageLine + "\n").write(to: file, atomically: false, encoding: .utf8)

        // Both adapters point at the same ~/.claude/projects root; the exclusion
        // must keep the SDK workspace out of Claude Code entirely.
        let store = SessionStore(configuration: .init(
            projectsRoot: root,
            adapters: [ClaudeCodeAdapter(transcriptRoot: root,
                                         excludeProjectDir: OpenClawAdapter.isSDKWorkspaceProjectDir),
                       OpenClawAdapter(surface: .sdk, transcriptRoot: root)]))
        await store.bootstrap()
        await store.processesUpdated(.init(
            processesByAdapter: ["openclaw-sdk": [RunningProcess(pid: 9, cwd: sdkCWD)]],
            degraded: false))

        let rows = await store.rows()
        XCTAssertEqual(rows.count, 1, "tracked once, not once per adapter")
        XCTAssertEqual(rows[0].agentID, "openclaw-sdk")
        XCTAssertEqual(rows[0].agentName, "OpenClaw (Claude SDK)")
        XCTAssertEqual(rows[0].pid, 9)
        XCTAssertGreaterThan(rows[0].cost.dollars, 0, "real Claude Code usage is priced")
        XCTAssertTrue(rows.allSatisfy { $0.agentID != "claude-code" },
                      "the spend belongs to OpenClaw, not Claude Code")
    }
}
