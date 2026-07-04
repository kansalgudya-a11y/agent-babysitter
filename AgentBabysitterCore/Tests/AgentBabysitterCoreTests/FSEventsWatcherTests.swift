import XCTest
@testable import AgentBabysitterCore

final class FSEventsWatcherTests: XCTestCase {

    func testDeliversChangeForNewFileInSubdirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fsevents-tests-\(UUID().uuidString)")
        let sub = root.appendingPathComponent("-Users-dev-appA")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let expectation = expectation(description: "change delivered")
        expectation.assertForOverFulfill = false
        let seen = Locked<[String]>([])

        let watcher = FSEventsWatcher(url: root, latency: 0.1, onChange: { paths in
            seen.withLock { $0.append(contentsOf: paths) }
            if paths.contains(where: { $0.hasSuffix("abc.jsonl") }) {
                expectation.fulfill()
            }
        })
        watcher.start()
        defer { watcher.stop() }

        // Give the stream a beat to arm before writing
        Thread.sleep(forTimeInterval: 0.3)
        let file = sub.appendingPathComponent("abc.jsonl")
        try "{\"type\":\"user\"}\n".write(to: file, atomically: false, encoding: .utf8)

        wait(for: [expectation], timeout: 10)
        XCTAssertTrue(seen.withLock { $0 }.contains { $0.hasSuffix("abc.jsonl") })
    }
}

/// Tiny test helper: a lock-guarded box (XCTest closures run on FSEvents' queue).
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
