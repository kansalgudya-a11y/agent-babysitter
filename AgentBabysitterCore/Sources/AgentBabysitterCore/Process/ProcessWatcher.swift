import Foundation

/// Source of live agent processes. The real implementation shells out to
/// ps/lsof; tests inject a fake.
public protocol ProcessScanning: Sendable {
    /// Live processes per adapter id.
    func scanProcesses(for adapters: [any AgentAdapter]) async throws -> [String: [RunningProcess]]
}

/// Real scanner: one `ps` pass (comm= and args=), each adapter extracts its
/// pids, then one `lsof` call resolves every cwd.
public struct ShellProcessScanner: ProcessScanning {

    public init() {}

    public func scanProcesses(
        for adapters: [any AgentAdapter]
    ) async throws -> [String: [RunningProcess]] {
        let commOutput = try await run("/bin/ps", ["-axo", "pid=,comm="])
        let argsOutput = try await run("/bin/ps", ["-axo", "pid=,args="])

        var pidsByAdapter: [String: [Int32]] = [:]
        for adapter in adapters {
            pidsByAdapter[adapter.id] = adapter.agentPIDs(psComm: commOutput,
                                                          psArgs: argsOutput)
        }
        let allPIDs = Set(pidsByAdapter.values.flatMap { $0 })
        guard !allPIDs.isEmpty else {
            return pidsByAdapter.mapValues { _ in [] }
        }

        let pidList = allPIDs.sorted().map(String.init).joined(separator: ",")
        // lsof exits non-zero if any pid vanished between ps and lsof; that's
        // fine — parse whatever it printed.
        let lsofOutput = (try? await run("/usr/sbin/lsof",
                                         ["-a", "-d", "cwd", "-Fn", "-p", pidList])) ?? ""
        let cwds = ProcessOutputParser.cwdsByPID(fromLSOF: lsofOutput)
        return pidsByAdapter.mapValues { pids in
            pids.compactMap { pid in cwds[pid].map { RunningProcess(pid: pid, cwd: $0) } }
        }
    }

    private func run(_ launchPath: String, _ arguments: [String]) async throws -> String {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: launchPath)
            process.arguments = arguments
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            try process.run()
            // Drain stdout BEFORE waiting for exit: ps output easily exceeds
            // the 64KB pipe buffer, and an undrained pipe deadlocks the child.
            let data = try stdout.fileHandleForReading.readToEnd() ?? Data()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }.value
    }
}

/// Polls for claude CLI processes on an interval. On scanner failure it
/// reports degraded mode (transcript-only; Ended detection paused) instead of
/// wiping the session list with an empty result.
public actor ProcessWatcher {

    public struct Update: Equatable, Sendable {
        public let processesByAdapter: [String: [RunningProcess]]
        /// True when the last scan failed and the process map is stale.
        public let degraded: Bool

        public init(processesByAdapter: [String: [RunningProcess]], degraded: Bool) {
            self.processesByAdapter = processesByAdapter
            self.degraded = degraded
        }

        /// Convenience for the single-adapter (Claude Code) shape.
        public init(processes: [RunningProcess], degraded: Bool) {
            self.init(processesByAdapter: ["claude-code": processes], degraded: degraded)
        }
    }

    private let scanner: any ProcessScanning
    private let adapters: [any AgentAdapter]
    private let interval: Duration
    private var pollTask: Task<Void, Never>?
    private var handler: (@Sendable (Update) -> Void)?

    public private(set) var latest = Update(processesByAdapter: [:], degraded: false)

    public init(scanner: any ProcessScanning = ShellProcessScanner(),
                adapters: [any AgentAdapter] = [ClaudeCodeAdapter()],
                interval: Duration = .seconds(5)) {
        self.scanner = scanner
        self.adapters = adapters
        self.interval = interval
    }

    public func start(onUpdate: @escaping @Sendable (Update) -> Void) {
        handler = onUpdate
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                await pollOnce()
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        handler = nil
    }

    /// One scan cycle; exposed for tests to drive without the timer.
    public func pollOnce() async {
        do {
            let processes = try await scanner.scanProcesses(for: adapters)
            latest = Update(processesByAdapter: processes, degraded: false)
        } catch {
            BabysitterLog.process.error("process scan failed: \(error.localizedDescription, privacy: .public)")
            latest = Update(processesByAdapter: latest.processesByAdapter, degraded: true)
        }
        handler?(latest)
    }
}
