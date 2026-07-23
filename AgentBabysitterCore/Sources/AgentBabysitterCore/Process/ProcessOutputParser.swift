import Foundation

/// A live agent CLI process and the directory it was launched from.
public struct RunningProcess: Equatable, Hashable, Sendable {
    public let pid: Int32
    public let cwd: String
    /// Controlling terminal as `ps` reports it (e.g. `ttys001`), or nil when the
    /// process has none (`ps` prints `??` — e.g. a CLI launched by an IDE or
    /// launchd). Used by the App layer (F9) to select the exact terminal tab.
    /// Format is the bare device name without the `/dev/` prefix, so a consumer
    /// comparing against Terminal.app's `/dev/ttys001` must match on the suffix.
    public let tty: String?

    // tty defaulted so the ~30 existing `RunningProcess(pid:cwd:)` call sites
    // (adapters, tests, fixtures) keep compiling unchanged.
    public init(pid: Int32, cwd: String, tty: String? = nil) {
        self.pid = pid
        self.cwd = cwd
        self.tty = tty
    }
}

/// Pure parsers for `ps` / `lsof` output, separated from the shelling-out so
/// they can be tested against captured fixtures.
public enum ProcessOutputParser {

    /// Extract pids of `claude` CLI processes from `ps -axo pid=,args=` output.
    /// Matches the native binary (`…/claude`) and runtime-hosted installs
    /// (`node …/claude`, `bun …/claude`). The Claude desktop app ("Claude",
    /// capitalized) and its helpers are deliberately not CLI sessions.
    public static func claudePIDs(fromPS output: String) -> [Int32] {
        var pids: [Int32] = []
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let firstSpace = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else { continue }
            guard let pid = Int32(line[..<firstSpace]) else { continue }
            let args = line[line.index(after: firstSpace)...]
                .trimmingCharacters(in: .whitespaces)
            let tokens = args.split(separator: " ", omittingEmptySubsequences: true)
            guard let command = tokens.first else { continue }

            if basename(command) == "claude" {
                pids.append(pid)
            } else if ["node", "bun", "deno"].contains(basename(command)),
                      tokens.count > 1, basename(tokens[1]) == "claude" {
                pids.append(pid)
            }
        }
        return pids
    }

    /// Extract pids whose executable is named `claude` from
    /// `ps -axo pid=,comm=` output. `comm` is the full executable path with
    /// no argument tokens after it, so paths containing spaces (the desktop
    /// app's embedded runtime lives under "Application Support") parse
    /// correctly — unlike args-based tokenization.
    public static func claudePIDs(fromPSComm output: String) -> [Int32] {
        var pids: [Int32] = []
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let firstSpace = line.firstIndex(where: { $0 == " " || $0 == "\t" }),
                  let pid = Int32(line[..<firstSpace]) else { continue }
            let command = line[line.index(after: firstSpace)...]
                .trimmingCharacters(in: .whitespaces)
            if command.split(separator: "/").last == "claude" {
                pids.append(pid)
            }
        }
        return pids
    }

    /// Parse `ps -axo pid=,tty=` output into pid → controlling terminal.
    /// The `tty=` column prints the bare device (e.g. `ttys001`) with no
    /// argument tokens after it, so a simple pid / rest split is unambiguous.
    /// Processes with no controlling terminal print `??`; those are skipped so
    /// the map only holds pids the App can actually focus a tab for.
    public static func ttysByPID(fromPS output: String) -> [Int32: String] {
        var result: [Int32: String] = [:]
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let firstSpace = line.firstIndex(where: { $0 == " " || $0 == "\t" }),
                  let pid = Int32(line[..<firstSpace]) else { continue }
            let tty = line[line.index(after: firstSpace)...]
                .trimmingCharacters(in: .whitespaces)
            // `??` = no controlling terminal; empty guards a malformed row.
            guard !tty.isEmpty, tty != "??" else { continue }
            result[pid] = tty
        }
        return result
    }

    /// Parse `lsof -a -d cwd -Fn -p <pids>` field output into pid → cwd.
    /// Field format: `p<pid>` starts a process section, `n<path>` is the
    /// cwd path within it.
    public static func cwdsByPID(fromLSOF output: String) -> [Int32: String] {
        var result: [Int32: String] = [:]
        var currentPID: Int32?
        for line in output.split(separator: "\n") {
            if line.hasPrefix("p") {
                currentPID = Int32(line.dropFirst())
            } else if line.hasPrefix("n"), let pid = currentPID {
                result[pid] = String(line.dropFirst())
            }
        }
        return result
    }

    private static func basename(_ path: Substring) -> String {
        path.split(separator: "/").last.map(String.init) ?? String(path)
    }
}
