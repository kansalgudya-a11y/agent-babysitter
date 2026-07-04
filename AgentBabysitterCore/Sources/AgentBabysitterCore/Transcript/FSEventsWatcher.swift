import Foundation
import CoreServices

/// Thin FSEvents wrapper: recursive watch on a directory, delivering changed
/// paths. If the kernel signals a dropped/overflowed stream it asks the owner
/// to rescan instead of silently missing files.
public final class FSEventsWatcher: @unchecked Sendable {

    private let path: String
    private let latency: TimeInterval
    private let onChange: @Sendable ([String]) -> Void
    private let onNeedsRescan: @Sendable () -> Void
    private let queue = DispatchQueue(label: "app.agentbabysitter.fsevents")
    private var stream: FSEventStreamRef?

    public init(url: URL,
                latency: TimeInterval = 0.3,
                onChange: @escaping @Sendable ([String]) -> Void,
                onNeedsRescan: @escaping @Sendable () -> Void = {}) {
        self.path = url.path
        self.latency = latency
        self.onChange = onChange
        self.onNeedsRescan = onNeedsRescan
    }

    deinit { stop() }

    public func start() {
        guard stream == nil else { return }

        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()

        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
            guard let paths = Unmanaged<CFArray>.fromOpaque(eventPaths)
                .takeUnretainedValue() as? [String] else { return }

            var changed: [String] = []
            var needsRescan = false
            for i in 0..<count {
                let flags = eventFlags[i]
                if flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0 {
                    needsRescan = true  // stream dropped events; rescan once
                } else {
                    changed.append(paths[i])
                }
            }
            if !changed.isEmpty { watcher.onChange(changed) }
            if needsRescan {
                BabysitterLog.watcher.warning("FSEvents dropped events; rescanning")
                watcher.onNeedsRescan()
            }
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes |
                                     kFSEventStreamCreateFlagFileEvents |
                                     kFSEventStreamCreateFlagNoDefer)) else {
            onNeedsRescan()  // can't watch; owner should fall back to polling
            return
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
