import XCTest
@testable import AgentBabysitterCore

/// A failed API call is written as a synthetic assistant turn flagged by the
/// TOP-LEVEL `isApiErrorMessage`. The app must surface it as a current
/// problem — but only while it's the LATEST turn, and never off the benign
/// `<synthetic>` model marker alone.
final class APIErrorSurfacingTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("apierror-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Line builders (shapes lifted from the real transcript)

    private func apiErrorLine(_ text: String = "Not logged in · Please run /login",
                              id: String = "err1",
                              cwd: String = "/Users/dev/appA") -> String {
        "{\"type\":\"assistant\",\"isApiErrorMessage\":true,\"isSidechain\":false,\"cwd\":\"\(cwd)\",\"entrypoint\":\"sdk-cli\",\"timestamp\":\"2026-07-10T05:46:48.000Z\",\"uuid\":\"u-\(id)\",\"message\":{\"id\":\"\(id)\",\"role\":\"assistant\",\"model\":\"<synthetic>\",\"type\":\"message\",\"stop_reason\":\"stop_sequence\",\"content\":[{\"type\":\"text\",\"text\":\"\(text)\"}],\"usage\":{\"input_tokens\":0,\"output_tokens\":0,\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}}}"
    }

    private func healthyLine(_ text: String = "done", id: String = "ok1",
                             cwd: String = "/Users/dev/appA") -> String {
        "{\"type\":\"assistant\",\"cwd\":\"\(cwd)\",\"timestamp\":\"2026-07-10T05:47:00.000Z\",\"message\":{\"model\":\"claude-opus-4-8\",\"id\":\"\(id)\",\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"\(text)\"}],\"stop_reason\":\"end_turn\",\"usage\":{\"input_tokens\":5,\"output_tokens\":7,\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}}}"
    }

    /// `<synthetic>` model WITHOUT the error flag — a benign interrupt.
    private func syntheticInterruptLine() -> String {
        "{\"type\":\"assistant\",\"timestamp\":\"2026-07-10T05:47:00.000Z\",\"message\":{\"model\":\"<synthetic>\",\"id\":\"s1\",\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"[Request interrupted by user]\"}],\"stop_reason\":\"stop_sequence\",\"usage\":{\"input_tokens\":0,\"output_tokens\":0,\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}}}"
    }

    private func tailer(_ lines: [String]) throws -> TranscriptFileTailer {
        let url = tempDir.appendingPathComponent("\(UUID().uuidString).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: false, encoding: .utf8)
        let tailer = TranscriptFileTailer(url: url)
        _ = try tailer.catchUp()
        return tailer
    }

    // MARK: - Tailer verdict

    // (a)
    func testAPIErrorLineSetsLastAPIErrorToTheText() throws {
        let tailer = try tailer([apiErrorLine()])
        XCTAssertEqual(tailer.lastAPIError, "Not logged in · Please run /login")
    }

    // (b)
    func testLaterHealthyAssistantTurnClearsTheError() throws {
        let tailer = try tailer([apiErrorLine(), healthyLine()])
        XCTAssertNil(tailer.lastAPIError, "newer healthy output means it recovered")
    }

    // (c)
    func testAPIErrorAfterAHealthyTurnSetsIt() throws {
        let tailer = try tailer([healthyLine(), apiErrorLine("Overloaded", id: "err2")])
        XCTAssertEqual(tailer.lastAPIError, "Overloaded")
    }

    // (d)
    func testSyntheticModelWithoutErrorFlagDoesNotFlag() throws {
        let tailer = try tailer([syntheticInterruptLine()])
        XCTAssertNil(tailer.lastAPIError, "<synthetic> alone is not a failure signal")
    }

    func testParserReadsTheTopLevelFlagNotTheModel() throws {
        guard case .entry(let errored) = TranscriptLineParser.parse(apiErrorLine()),
              case .assistant(let erroredPayload) = errored.kind else {
            return XCTFail("expected an assistant entry")
        }
        XCTAssertTrue(erroredPayload.isAPIError)
        XCTAssertEqual(erroredPayload.firstText, "Not logged in · Please run /login")

        guard case .entry(let benign) = TranscriptLineParser.parse(syntheticInterruptLine()),
              case .assistant(let benignPayload) = benign.kind else {
            return XCTFail("expected an assistant entry")
        }
        XCTAssertEqual(benignPayload.model, "<synthetic>")
        XCTAssertFalse(benignPayload.isAPIError)
    }

    // (e)
    func testAPIErrorMessageCostsZeroAndZeroTokens() throws {
        let tailer = try tailer([apiErrorLine()])
        XCTAssertEqual(tailer.cost.dollars, 0)
        XCTAssertEqual(tailer.cost.totalTokens, 0)
    }

    // (f)
    func testSessionStoreRowExposesAPIError() async throws {
        let root = tempDir.appendingPathComponent("projects")
        let projectDir = root.appendingPathComponent("-Users-dev-appA")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let url = projectDir.appendingPathComponent("aaa.jsonl")
        let userLine = "{\"type\":\"user\",\"cwd\":\"/Users/dev/appA\",\"timestamp\":\"2026-07-10T05:46:00.000Z\",\"message\":{\"role\":\"user\",\"content\":\"hi\"}}"
        try ([userLine, apiErrorLine()].joined(separator: "\n") + "\n")
            .write(to: url, atomically: false, encoding: .utf8)

        let store = SessionStore(configuration: .init(projectsRoot: root))
        await store.bootstrap()
        await store.processesUpdated(.init(processes: [RunningProcess(pid: 1, cwd: "/Users/dev/appA")],
                                           degraded: false))
        let rows = await store.rows()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].apiError, "Not logged in · Please run /login")
    }

    // MARK: - Real transcript fixture

    func testRealAPIErrorFixtureFlagsLatestTurn() throws {
        let parser = TranscriptTailParser()
        var entries = parser.consume(try fixtureData("api_error"))
        if let last = parser.finalize() { entries.append(last) }
        XCTAssertEqual(parser.malformedLineCount, 0, "the real error line must parse cleanly")

        guard case .assistant(let payload) = entries.last?.kind else {
            return XCTFail("fixture should end on the api-error assistant turn")
        }
        XCTAssertTrue(payload.isAPIError)
        XCTAssertEqual(payload.firstText, "Not logged in · Please run /login")
        XCTAssertEqual(payload.usage, TokenUsage(inputTokens: 0, outputTokens: 0,
                                                 cacheCreationInputTokens: 0,
                                                 cacheReadInputTokens: 0,
                                                 cacheCreation5mTokens: 0,
                                                 cacheCreation1hTokens: 0))
    }

    // MARK: - Edge cases

    /// An error line with an empty text block must still caption "API error",
    /// not render a blank warning triangle.
    func testEmptyErrorTextFallsBackToAPIError() throws {
        let tailer = try tailer([apiErrorLine("")])
        XCTAssertEqual(tailer.lastAPIError, "API error")
    }

    /// A compaction that rewrites the file shorter, to content with no assistant
    /// line, must clear a stale error rather than leave the banner up forever.
    func testFileShrinkToAssistantlessContentClearsStaleError() throws {
        let url = tempDir.appendingPathComponent("\(UUID().uuidString).jsonl")
        try (apiErrorLine() + "\n").write(to: url, atomically: false, encoding: .utf8)
        let tailer = TranscriptFileTailer(url: url)
        _ = try tailer.catchUp()
        XCTAssertEqual(tailer.lastAPIError, "Not logged in · Please run /login")

        let userOnly = "{\"type\":\"user\",\"timestamp\":\"2026-07-10T06:00:00.000Z\"," +
            "\"message\":{\"role\":\"user\",\"content\":\"hi\"}}"
        try (userOnly + "\n").write(to: url, atomically: false, encoding: .utf8)
        _ = try tailer.catchUp()
        XCTAssertNil(tailer.lastAPIError, "the rebuilt file has no assistant error — clear it")
    }
}
