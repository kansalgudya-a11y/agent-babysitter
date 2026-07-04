import Foundation

/// Watches the Precision-mode event log for lines appended by the installed
/// hooks and emits typed signals. Starts at end-of-file: events written while
/// the app wasn't running are stale and must not override fresh heuristics.
public final class HookEventWatcher: @unchecked Sendable {

    private let eventLogURL: URL
    private let onSignal: @Sendable (String, HookSignal) -> Void
    private let queue = DispatchQueue(label: "app.agentbabysitter.hook-events")
    private var fsWatcher: FSEventsWatcher?
    private var offset: UInt64 = 0
    private var lineBuffer = Data()

    public init(eventLogURL: URL = HooksInstaller.defaultEventLogURL,
                onSignal: @escaping @Sendable (String, HookSignal) -> Void) {
        self.eventLogURL = eventLogURL
        self.onSignal = onSignal
    }

    public func start() {
        let directory = eventLogURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Events written while the app wasn't running are stale by design —
        // truncate so the log can't grow without bound across sessions.
        if FileManager.default.fileExists(atPath: eventLogURL.path) {
            try? FileHandle(forWritingTo: eventLogURL).truncate(atOffset: 0)
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
            if let event = HookEventParser.parse(line: line) {
                onSignal(event.sessionID, HookSignal(kind: event.kind, timestamp: Date()))
            }
        }
    }
}
