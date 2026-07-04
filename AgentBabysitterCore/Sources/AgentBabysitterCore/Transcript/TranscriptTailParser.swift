import Foundation

/// Stateful per-file tail parser. Feed it raw appended bytes in any chunking
/// (FSEvents callbacks don't align to line boundaries); it buffers the
/// trailing partial line until its newline arrives and never re-reads old
/// bytes.
public final class TranscriptTailParser {

    /// Undecodable lines seen so far. The session layer marks a transcript
    /// unreadable past a threshold; the parser just counts.
    public private(set) var malformedLineCount = 0

    private var buffer = Data()
    private let parseLine: @Sendable (Data) -> LineParseResult

    /// `parseLine` defaults to the Claude Code schema; adapters inject their own.
    public init(parseLine: @escaping @Sendable (Data) -> LineParseResult
                    = { TranscriptLineParser.parse($0) }) {
        self.parseLine = parseLine
    }

    /// Consume newly appended bytes, returning every entry whose line was
    /// completed by this chunk.
    public func consume(_ data: Data) -> [TranscriptEntry] {
        buffer.append(data)
        var entries: [TranscriptEntry] = []
        // Split on \n only: safe for UTF-8 (no multibyte sequence contains 0x0A).
        // Track a cursor and compact the buffer once at the end — removing the
        // consumed prefix per line would be quadratic over large appends.
        var start = buffer.startIndex
        while let newline = buffer[start...].firstIndex(of: 0x0A) {
            append(line: buffer.subdata(in: start..<newline), to: &entries)
            start = buffer.index(after: newline)
        }
        if start == buffer.endIndex {
            buffer = Data()
        } else if start != buffer.startIndex {
            buffer = Data(buffer[start...])
        }
        return entries
    }

    /// Parse whatever remains in the buffer as a final, unterminated line.
    /// Use when a transcript is known to be complete (e.g. launch scan of an
    /// ended session) — never while live-tailing, where more bytes may follow.
    public func finalize() -> TranscriptEntry? {
        guard !buffer.isEmpty else { return nil }
        let line = buffer
        buffer = Data()
        var entries: [TranscriptEntry] = []
        append(line: line, to: &entries)
        return entries.first
    }

    private func append(line: Data, to entries: inout [TranscriptEntry]) {
        switch parseLine(line) {
        case .entry(let entry): entries.append(entry)
        case .empty: break
        case .malformed: malformedLineCount += 1
        }
    }
}
