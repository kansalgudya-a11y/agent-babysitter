import XCTest
@testable import AgentBabysitterCore

private struct FakeScanner: ProcessScanning {
    let results: [String: [RunningProcess]]
    let fails: Bool

    func scanProcesses(for adapters: [any AgentAdapter]) async throws -> [String: [RunningProcess]] {
        if fails { throw CocoaError(.fileReadUnknown) }
        return results
    }
}

final class ProcessWatcherTests: XCTestCase {

    func testPollPublishesScannedProcesses() async {
        let expected = ["claude-code": [RunningProcess(pid: 42, cwd: "/Users/dev/appA")]]
        let watcher = ProcessWatcher(scanner: FakeScanner(results: expected, fails: false))
        await watcher.pollOnce()
        let update = await watcher.latest
        XCTAssertEqual(update.processesByAdapter, expected)
        XCTAssertFalse(update.degraded)
    }

    func testFailureAfterSuccessPreservesStaleProcessList() async {
        // Drive one watcher through success then failure using a stateful scanner
        final class FlakyScanner: ProcessScanning, @unchecked Sendable {
            var callCount = 0
            func scanProcesses(for adapters: [any AgentAdapter]) async throws -> [String: [RunningProcess]] {
                callCount += 1
                if callCount > 1 { throw CocoaError(.fileReadUnknown) }
                return ["claude-code": [RunningProcess(pid: 7, cwd: "/x")]]
            }
        }
        let watcher = ProcessWatcher(scanner: FlakyScanner())
        await watcher.pollOnce()
        await watcher.pollOnce()
        let update = await watcher.latest
        XCTAssertTrue(update.degraded)
        XCTAssertEqual(update.processesByAdapter,
                       ["claude-code": [RunningProcess(pid: 7, cwd: "/x")]],
                       "degraded mode keeps the last good scan instead of marking everything Ended")
    }

    func testSingleAdapterConvenienceInitKeepsClaudeShape() {
        let update = ProcessWatcher.Update(processes: [RunningProcess(pid: 1, cwd: "/a")],
                                           degraded: false)
        XCTAssertEqual(update.processesByAdapter, ["claude-code": [RunningProcess(pid: 1, cwd: "/a")]])
    }

    func testRealScannerRunsWithoutThrowing() async throws {
        // Smoke test against the actual ps/lsof binaries on this machine.
        let scanner = ShellProcessScanner()
        let result = try await scanner.scanProcesses(for: [ClaudeCodeAdapter(), CodexAdapter()])
        XCTAssertNotNil(result["claude-code"])
        XCTAssertNotNil(result["codex"])
    }
}
