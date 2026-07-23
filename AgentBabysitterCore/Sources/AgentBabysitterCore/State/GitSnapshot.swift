import Foundation

/// A read-only summary of a working directory's git state at a turn boundary:
/// the unstaged diff size plus a count of uncommitted working-tree entries.
/// Shown on a `.done` session row so the user sees "what did this run change"
/// without opening the terminal. All figures come from READ-ONLY git commands
/// (`diff --shortstat`, `status --porcelain`); nothing here ever mutates a repo.
public struct GitSnapshot: Equatable, Sendable, Codable {
    /// Files touched by the unstaged diff (`git diff --shortstat`).
    public let filesChanged: Int
    /// Insertions in the unstaged diff.
    public let added: Int
    /// Deletions in the unstaged diff.
    public let removed: Int
    /// Working-tree entries reported by `git status --porcelain` — staged,
    /// unstaged, and untracked. Deliberately a separate signal from the diff:
    /// it counts NEW files the diff can't (untracked), so both are shown.
    public let uncommitted: Int

    public init(filesChanged: Int, added: Int, removed: Int, uncommitted: Int) {
        self.filesChanged = filesChanged
        self.added = added
        self.removed = removed
        self.uncommitted = uncommitted
    }

    /// e.g. "+184 −12 across 6 files · 2 uncommitted". Zero clauses are omitted
    /// (an all-deletions diff drops the "+0"; no untracked drops the uncommitted
    /// clause). Returns "" when the tree is completely clean, so the caller can
    /// choose to show nothing rather than a "0 changes" line.
    public var summary: String {
        var clauses: [String] = []
        if filesChanged > 0 {
            var deltas: [String] = []
            if added > 0 { deltas.append("+\(added)") }
            // U+2212 MINUS SIGN — matches the app's other numeric captions.
            if removed > 0 { deltas.append("−\(removed)") }
            let fileWord = filesChanged == 1 ? "file" : "files"
            let prefix = deltas.isEmpty ? "" : deltas.joined(separator: " ") + " "
            clauses.append("\(prefix)across \(filesChanged) \(fileWord)")
        }
        if uncommitted > 0 {
            clauses.append("\(uncommitted) uncommitted")
        }
        return clauses.joined(separator: " · ")
    }
}

/// Reads a working directory's git state. `parse` is pure (probe it with
/// captured `git diff --shortstat` text); `read` shells out read-only and is
/// meant to run OFF the 2s store tick — the app hub spawns it in a detached
/// task at turn boundaries and injects the result into the row.
public enum GitSnapshotReader {

    /// Pure. Turns a `git diff --shortstat` line plus a porcelain line count
    /// into a `GitSnapshot`. Tolerates every shortstat shape:
    ///   " 3 files changed, 120 insertions(+), 8 deletions(-)"
    ///   " 1 file changed, 5 insertions(+)"
    ///   " 1 file changed, 8 deletions(-)"
    ///   "" (clean — all zeros)
    /// It reads the first integer of each comma-separated clause and classifies
    /// it by keyword (file/insertion/deletion), so word order or missing clauses
    /// never break it. A negative porcelain count is clamped to 0.
    public static func parse(shortstat: String, porcelainLineCount: Int) -> GitSnapshot {
        var filesChanged = 0, added = 0, removed = 0
        for clause in shortstat.split(separator: ",") {
            guard let value = firstInt(in: clause) else { continue }
            if clause.contains("file") {
                filesChanged = value
            } else if clause.contains("insertion") {
                added = value
            } else if clause.contains("deletion") {
                removed = value
            }
        }
        return GitSnapshot(filesChanged: filesChanged,
                           added: added,
                           removed: removed,
                           uncommitted: max(0, porcelainLineCount))
    }

    /// Read-only, async, OFF the 2s tick. Returns nil for a non-git dir, an
    /// empty cwd, or any command failure — never a mutating verb, never a write.
    /// Runs, in order:
    ///   git -C <cwd> rev-parse --is-inside-work-tree   (guard; non-"true" → nil)
    ///   git -C <cwd> diff --shortstat
    ///   git -C <cwd> status --porcelain                (count lines)
    /// The process runtime is confirmed with Xcode; `parse` above is the probed
    /// half. Uses a detached Process draining stdout before waitUntilExit, the
    /// same deadlock-safe shape as ShellProcessScanner.
    public static func read(cwd: String) async -> GitSnapshot? {
        let dir = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dir.isEmpty else { return nil }

        // Guard: a non-git dir exits 128; inside a bare .git prints "false".
        // Only a real work tree ("true", exit 0) proceeds.
        guard let guardRun = await runGit(["-C", dir, "rev-parse", "--is-inside-work-tree"]),
              guardRun.status == 0,
              guardRun.output.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        else { return nil }

        guard let diff = await runGit(["-C", dir, "diff", "--shortstat"]),
              let status = await runGit(["-C", dir, "status", "--porcelain"])
        else { return nil }

        let porcelainCount = status.output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .count
        return parse(shortstat: diff.output, porcelainLineCount: porcelainCount)
    }

    // MARK: - Internals

    /// First contiguous run of digits in a substring, or nil if none.
    private static func firstInt(in text: Substring) -> Int? {
        var digits = ""
        for ch in text {
            if ch.isNumber {
                digits.append(ch)
            } else if !digits.isEmpty {
                break
            }
        }
        return Int(digits)
    }

    /// Runs `/usr/bin/git` (the macOS git shim, always present) with a fixed,
    /// read-only argument vector. Returns nil only if the process can't launch.
    /// stderr is discarded; stdout is drained before waiting for exit.
    private static func runGit(_ arguments: [String]) async -> (status: Int32, output: String)? {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return nil
            }
            let data = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
    }
}
