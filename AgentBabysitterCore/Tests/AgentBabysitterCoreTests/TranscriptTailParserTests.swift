import XCTest
@testable import AgentBabysitterCore

final class TranscriptTailParserTests: XCTestCase {

    func testChunkedFeedMatchesWholeFileParse() throws {
        let data = try fixtureData("normal_turn")

        let whole = TranscriptTailParser()
        var wholeEntries = whole.consume(data)
        if let last = whole.finalize() { wholeEntries.append(last) }

        let chunked = TranscriptTailParser()
        var chunkedEntries: [TranscriptEntry] = []
        var offset = 0
        while offset < data.count {
            let end = min(offset + 7, data.count)  // deliberately awkward chunk size
            chunkedEntries += chunked.consume(data.subdata(in: offset..<end))
            offset = end
        }
        if let last = chunked.finalize() { chunkedEntries.append(last) }

        XCTAssertEqual(chunkedEntries.count, wholeEntries.count)
        XCTAssertEqual(chunkedEntries, wholeEntries)
        XCTAssertEqual(chunked.malformedLineCount, 0)
    }

    func testPartialLineIsBufferedUntilNewlineArrives() {
        let parser = TranscriptTailParser()
        let line = "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"hi\"}}\n"
        let bytes = Data(line.utf8)
        let split = bytes.count / 2

        XCTAssertTrue(parser.consume(bytes.prefix(split)).isEmpty)
        XCTAssertEqual(parser.malformedLineCount, 0)

        let entries = parser.consume(bytes.suffix(from: split))
        XCTAssertEqual(entries.count, 1)
        guard case .user(let payload) = entries[0].kind else { return XCTFail("expected user") }
        XCTAssertEqual(payload.text, "hi")
    }

    func testMultibyteUTF8SplitAcrossChunks() {
        let parser = TranscriptTailParser()
        let line = "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"héllo 🚀 wörld\"}}\n"
        let bytes = Data(line.utf8)
        // Split inside the rocket emoji (4-byte UTF-8 sequence)
        let emojiRange = bytes.range(of: Data("🚀".utf8))!
        let split = emojiRange.lowerBound + 2

        var entries = parser.consume(bytes.prefix(split))
        entries += parser.consume(bytes.suffix(from: split))
        XCTAssertEqual(entries.count, 1)
        guard case .user(let payload) = entries[0].kind else { return XCTFail("expected user") }
        XCTAssertEqual(payload.text, "héllo 🚀 wörld")
        XCTAssertEqual(parser.malformedLineCount, 0)
    }

    func testFinalizeParsesTrailingLineWithoutNewline() {
        let parser = TranscriptTailParser()
        let noNewline = Data("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"tail\"}}".utf8)
        XCTAssertTrue(parser.consume(noNewline).isEmpty)
        guard let entry = parser.finalize(), case .user(let payload) = entry.kind else {
            return XCTFail("expected trailing entry from finalize")
        }
        XCTAssertEqual(payload.text, "tail")
        // finalize drains the buffer — calling again yields nothing
        XCTAssertNil(parser.finalize())
    }

    func testMalformedFixtureCountsSkipsAndKeepsGoodLines() throws {
        let data = try fixtureData("malformed")
        let parser = TranscriptTailParser()
        var entries = parser.consume(data)
        if let last = parser.finalize() { entries.append(last) }

        // 6 good lines survive; 4 malformed (truncated JSON, plain text, fragment, missing type);
        // the empty line is skipped without counting.
        XCTAssertEqual(entries.count, 6)
        XCTAssertEqual(parser.malformedLineCount, 4)
    }

    func testHugeFileParsesCompletely() {
        let line = """
        {"type":"assistant","timestamp":"2026-07-04T09:45:57.119Z","sessionId":"s-big",\
        "message":{"model":"claude-opus-4-8","id":"msg_%d","role":"assistant",\
        "content":[{"type":"text","text":"chunk"}],"stop_reason":"end_turn",\
        "usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":10,\
        "cache_read_input_tokens":1000}}}
        """
        let count = 100_000
        var big = Data(capacity: count * (line.count + 8))
        for i in 0..<count {
            big.append(Data(line.replacingOccurrences(of: "%d", with: "\(i)").utf8))
            big.append(0x0A)
        }

        let parser = TranscriptTailParser()
        let entries = parser.consume(big)
        XCTAssertEqual(entries.count, count)
        XCTAssertEqual(parser.malformedLineCount, 0)
        guard case .assistant(let last) = entries[count - 1].kind else { return XCTFail("expected assistant") }
        XCTAssertEqual(last.messageID, "msg_\(count - 1)")
    }
}
