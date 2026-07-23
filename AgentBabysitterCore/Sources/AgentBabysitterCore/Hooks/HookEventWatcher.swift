import Foundation

/// Watches the Precision-mode event log for lines appended by the installed
/// hooks and emits typed signals. Starts at end-of-file: events written while
/// the app wasn't running are stale and must not override fresh heuristics.
public final class HookEventWatcher: @unchecked Sendable {

    private let eventLogURL: URL
    private let onSignal: @Sendable (String, HookSignal) -> Void
    private let onUsage: (@Sendable (UsageLimitSnapshot) -> Void)?
    private let onToolCall: (@Sendable (String, ToolCallSummary) -> Void)?
    private let queue = DispatchQueue(label: "app.agentbabysitter.hook-events")
    private var fsWatcher: FSEventsWatcher?
    private var offset: UInt64 = 0
    private var lineBuffer = Data()

    public init(eventLogURL: URL = HooksInstaller.defaultEventLogURL,
                onSignal: @escaping @Sendable (String, HookSignal) -> Void,
                onUsage: (@Sendable (UsageLimitSnapshot) -> Void)? = nil,
                onToolCall: (@Sendable (String, ToolCallSummary) -> Void)? = nil) {
        self.eventLogURL = eventLogURL
        self.onSignal = onSignal
        self.onUsage = onUsage
        self.onToolCall = onToolCall
    }

    public func start() {
        let directory = eventLogURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Events written while the app wasn't running are stale by design —
        // truncate so the log can't grow without bound across sessions, and
        // keep it private (it carries session ids and usage data; the shell
        // writers can't guarantee the mode of a pre-existing file).
        if FileManager.default.fileExists(atPath: eventLogURL.path) {
            try? FileHandle(forWritingTo: eventLogURL).truncate(atOffset: 0)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: eventLogURL.path)
            BabysitterLog.hooks.info("truncated stale event log")
        }
        offset = (try? FileManager.default.attributesOfItem(atPath: eventLogURL.path))
            .flatMap { $0[.size] as? UInt64 } ?? 0

        let watcher = FSEventsWatcher(url: directory, latency: 0.1, onChange: { [weak self] paths in
            guard let self, paths.contains(where: { $0.hasSuffix("events.jsonl") }) else { return }
            self.queue.async { self.drain() }
        })
        watcher.start()
        fsWatcher = watcher
    }

    public func stop() {
        fsWatcher?.stop()
        fsWatcher = nil
    }

    /// Status-line updates arrive every few hundred ms during streaming; cap
    /// the log so a long-running app can't grow it without bound. Truncating
    /// after a drain loses at most one in-flight line, which self-heals.
    static let maxLogBytes: UInt64 = 5 * 1024 * 1024

    private func drain() {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: eventLogURL.path),
              let size = attributes[.size] as? UInt64 else { return }
        if size < offset {  // log rotated/cleared
            offset = 0
            lineBuffer = Data()
        }
        guard size > offset, let handle = try? FileHandle(forReadingFrom: eventLogURL) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.read(upToCount: Int(size - offset)) else { return }
        offset += UInt64(data.count)

        lineBuffer.append(data)
        while let newline = lineBuffer.firstIndex(of: 0x0A) {
            let line = lineBuffer.subdata(in: lineBuffer.startIndex..<newline)
            lineBuffer = Data(lineBuffer[lineBuffer.index(after: newline)...])
            guard let event = HookEventParser.parse(line: line) else { continue }
            if let signal = event.signal {
                onSignal(signal.sessionID,
                         HookSignal(kind: signal.kind, timestamp: Date(),
                                    detail: signal.detail))
            }
            if let usage = event.usage {
                onUsage?(usage)
            }
            if let toolCall = event.toolCall {
                // Already redacted in HookEventParser.parse — the raw tool_input
                // never reaches this callback.
                onToolCall?(toolCall.sessionID, toolCall.summary)
            }
        }

        if offset > Self.maxLogBytes {
            try? FileHandle(forWritingTo: eventLogURL).truncate(atOffset: 0)
            offset = 0
            lineBuffer = Data()
            BabysitterLog.hooks.info("event log hit size cap; truncated")
        }
    }
}
