import Foundation

/// OpenClaw (`openclaw` v2026.6.1) writes to two different stores, and this
/// adapter exposes one surface per store:
///
///   - `.gateway` — the native gateway store under `~/.openclaw` (JSONL session
///     trees). Activity-based only: it reports Working/Done/Ended from file
///     growth and NO tokens and NO cost. (See the block above `parseLine`.)
///   - `.sdk` — the transcripts OpenClaw produces when it drives an agent
///     through the Claude Agent SDK. Those land in `~/.claude/projects/<slug>/
///     <uuid>.jsonl` in *standard Claude Code format*, so this surface delegates
///     to the Claude Code line parser and gets real tokens, cost, and turn
///     state for free. It claims ONLY the transcripts whose project dir is an
///     ephemeral OpenClaw temp workspace (`isSDKWorkspaceProjectDir`); those
///     were previously misattributed to Claude Code (the spend is OpenClaw's).
///
/// The npm package ships no macOS `.app`, so both surfaces have empty
/// `focusBundleIdentifiers`; the gateway daemon runs as a Node process whose
/// `comm` is `node`, so it is matched on argv.
public struct OpenClawAdapter: AgentAdapter {

    public enum Surface: String, CaseIterable, Sendable {
        case gateway = "openclaw"
        case sdk = "openclaw-sdk"

        var displayName: String {
            switch self {
            case .gateway: "OpenClaw"
            case .sdk: "OpenClaw (Claude SDK)"
            }
        }
    }

    public let surface: Surface
    public let transcriptRoot: URL

    public var id: String { surface.rawValue }
    public var displayName: String { surface.displayName }
    // No macOS app bundle ships with the npm package.
    public let focusBundleIdentifiers: [String] = []
    // Both surfaces share OpenClaw's single binary (`openclaw`) as their install
    // signal. The SDK surface ships no binary of its own — it is a derived view
    // of the Claude-format transcripts OpenClaw writes when it drives an agent
    // through the Claude Agent SDK, and those only exist when `openclaw` is
    // installed. Reporting [] for it (the old behavior) left openclaw-sdk with
    // no bundle AND no executable name, so AgentInstallation could never mark it
    // installed: the surface was registered, tested, and structurally invisible.
    public var cliExecutableNames: [String] { ["openclaw"] }
    // The gateway store is opaque to parsing (see parseLine); the SDK store is
    // real Claude Code JSONL and IS parsed.
    public var isActivityBased: Bool { surface == .gateway }
    /// Neither surface records a quota: the gateway store is opaque to parsing
    /// (its reader's `usageLimit` is a stored nil), and the SDK surface's
    /// Claude-format lines carry no `rate_limits` — `TranscriptLineParser`
    /// never produces one. Unconditional, so both surfaces stay out of the
    /// usage list while keeping their real tokens and cost.
    public var publishesUsageLimit: Bool { false }

    /// Resolves the native store root and the SDK root from the environment.
    public init(surface: Surface,
                home: URL = PlatformPaths.home,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                fileManager: FileManager = .default) {
        self.surface = surface
        switch surface {
        case .gateway:
            self.transcriptRoot = Self.resolveNativeStoreRoot(
                environment: environment, home: home, fileManager: fileManager)
        case .sdk:
            self.transcriptRoot = home.appendingPathComponent(".claude/projects")
        }
    }

    /// Explicit-root init (tests, and any wiring that scopes a surface at a
    /// specific directory).
    public init(surface: Surface, transcriptRoot: URL) {
        self.surface = surface
        self.transcriptRoot = transcriptRoot
    }

    public static func allSurfaces(
        home: URL = PlatformPaths.home,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> [OpenClawAdapter] {
        Surface.allCases.map {
            OpenClawAdapter(surface: $0, home: home,
                            environment: environment, fileManager: fileManager)
        }
    }

    /// The gateway's own root resolution: `$OPENCLAW_STATE_DIR` →
    /// `$OPENCLAW_HOME`/`$HOME`/home + `/.openclaw` if it exists → legacy
    /// `~/.clawdbot` if it exists → else `<base>/.openclaw`.
    static func resolveNativeStoreRoot(environment: [String: String],
                                       home: URL,
                                       fileManager: FileManager) -> URL {
        func nonEmpty(_ key: String) -> String? {
            environment[key].flatMap { $0.isEmpty ? nil : $0 }
        }
        if let stateDir = nonEmpty("OPENCLAW_STATE_DIR") {
            return URL(fileURLWithPath: (stateDir as NSString).expandingTildeInPath)
        }
        let baseHome = nonEmpty("OPENCLAW_HOME") ?? nonEmpty("HOME") ?? home.path
        let primary = URL(fileURLWithPath: (baseHome as NSString).expandingTildeInPath)
            .appendingPathComponent(".openclaw")
        if fileManager.fileExists(atPath: primary.path) { return primary }
        let legacy = home.appendingPathComponent(".clawdbot")
        if fileManager.fileExists(atPath: legacy.path) { return legacy }
        return primary
    }

    // MARK: - Honest install signal

    /// Both surfaces advertise the `openclaw` binary as their install signal
    /// (see `cliExecutableNames`), but the two surfaces are NOT equally honest
    /// when the binary is merely on PATH:
    ///
    ///   - `.sdk` is a parseable Claude Code view — when OpenClaw drives the
    ///     Agent SDK it writes real, priced transcripts, so listing it on a
    ///     bare install is honest (it produces data the moment it's used, and
    ///     `claimsProcess` keeps it from faking a live process meanwhile).
    ///   - `.gateway` is activity-only over an OPAQUE store we deliberately do
    ///     not parse (no verifiable sample exists on any machine here — see the
    ///     block above `parseLine`). A bare `openclaw` on PATH with an EMPTY or
    ///     absent store would otherwise read as an active monitored agent that
    ///     can never show a token, a cost, or a real turn — pure phantom.
    ///
    /// So the gateway only counts once its store actually holds a session file.
    /// Install-detection ANDs this with the CLI/bundle presence check.
    ///
    /// NOTE (honesty): this gates VISIBILITY, not a parser. Whenever a real
    /// native-gateway sample is captured, the gateway parser can be built and
    /// verified; until then we show nothing rather than an invented number.
    public func hasMonitoredDataOnDisk() -> Bool {
        switch surface {
        case .sdk: return true
        case .gateway: return Self.gatewayStoreHasSessions(root: transcriptRoot)
        }
    }

    /// Whether the native gateway store under `root` holds at least one real
    /// session file (`<root>/agents/<agentId>/sessions/<id>.jsonl`, filtering
    /// the index/checkpoint/trajectory siblings). Deliberately shallow — two
    /// non-recursive directory reads — and returns false on the fast path when
    /// `agents/` is absent (the empty/absent-store case), because it is called
    /// from install-detection on the refresh cadence.
    static func gatewayStoreHasSessions(root: URL) -> Bool {
        let fm = FileManager.default
        let agentsDir = root.appendingPathComponent("agents")
        guard let agentDirs = try? fm.contentsOfDirectory(
            at: agentsDir, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return false }
        for agentDir in agentDirs {
            let sessions = agentDir.appendingPathComponent("sessions")
            guard let files = try? fm.contentsOfDirectory(
                at: sessions, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]) else { continue }
            if files.contains(where: { isNativeSessionFile($0.lastPathComponent) }) {
                return true
            }
        }
        return false
    }

    // MARK: - SDK workspace classification

    /// Whether a slugified `~/.claude/projects` dir name is an ephemeral
    /// OpenClaw SDK workspace. OpenClaw makes each workspace with
    /// `fs.mkdtemp(path.join(os.tmpdir(), "openclaw-<codename>-"))`, so the
    /// realpath'd cwd is the OS temp root immediately followed by an
    /// `openclaw-` segment, which Claude then slugifies with
    /// `replace(/[^a-zA-Z0-9]/g,"-")`.
    ///
    /// We anchor on the temp-root marker that precedes the `openclaw-` segment
    /// — never a bare `contains("openclaw")` — because classification only ever
    /// sees the path: an ordinary Claude Code checkout of the OpenClaw *source*
    /// (`-Users-x-dev-openclaw`, `-Users-x-projects-openclaw-clone`) must NOT be
    /// stolen from Claude Code. The markers:
    ///   - macOS per-user temp `…/T/openclaw-…`, i.e. a `var-folders` segment
    ///     followed by the uppercase "T" segment:
    ///     `-private-var-folders-hq-<hash>-T-openclaw-…`.
    ///   - POSIX `/tmp/openclaw-…` (and its `/private/tmp` realpath) →
    ///     `-tmp-openclaw-…` / `-private-tmp-openclaw-…`.
    ///
    /// The temp marker alone is not enough: a project genuinely named
    /// `T-openclaw-notes` slugifies to `…-dev-T-openclaw-notes`, and a hand-made
    /// `/tmp/openclaw-scratch` is not an SDK workspace. `mkdtemp` always appends
    /// exactly six random alphanumerics, so we require that suffix too.
    public static func isSDKWorkspaceProjectDir(_ name: String) -> Bool {
        let underTempRoot = (name.contains("-var-folders-") && name.contains("-T-openclaw-"))
            || name.hasPrefix("-tmp-openclaw-")
            || name.hasPrefix("-private-tmp-openclaw-")
        guard underTempRoot else { return false }
        return name.range(of: "-[A-Za-z0-9]{6}$", options: .regularExpression) != nil
    }

    /// A readable label recovered from an SDK workspace slug:
    /// `…-T-openclaw-crestodian-planner-q5Oo50` → `openclaw-crestodian-planner`.
    /// The workspace basename is `openclaw-<codename>-<6 random>` (mkdtemp
    /// appends exactly 6 chars to the `openclaw-…-` prefix), so drop that
    /// trailing `-<6 chars>` group.
    static func friendlyWorkspaceName(fromProjectDir name: String) -> String {
        guard let range = name.range(of: "openclaw-", options: .backwards) else { return name }
        let workspace = String(name[range.lowerBound...])
        let parts = workspace.split(separator: "-")
        if parts.count >= 3, let suffix = parts.last,
           suffix.count == 6, suffix.allSatisfy({ $0.isLetter || $0.isNumber }) {
            return parts.dropLast().joined(separator: "-")
        }
        return workspace
    }

    // MARK: - Transcript discovery

    public func recentTranscripts(maxAge: TimeInterval, now: Date) -> [SessionFileInfo] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(
            at: transcriptRoot, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]) else { return [] }
        var found: [SessionFileInfo] = []
        for case let url as URL in walker {
            // The enumerator is already rooted at transcriptRoot, so match on
            // the file's structure — not a raw path prefix, which /var vs
            // /private/var symlink resolution can defeat.
            guard isCanonicalTranscript(url),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  now.timeIntervalSince(modified) <= maxAge else { continue }
            found.append(SessionFileInfo(sessionID: sessionID(forTranscript: url),
                                         projectDirName: projectDirName(forTranscript: url),
                                         lastModified: modified,
                                         url: url))
        }
        return found
    }

    public func isTranscript(path: String) -> Bool {
        guard path.hasPrefix(transcriptRoot.path) else { return false }
        return isCanonicalTranscript(URL(fileURLWithPath: path))
    }

    /// The structural test shared by `isTranscript` and `recentTranscripts`.
    private func isCanonicalTranscript(_ url: URL) -> Bool {
        guard url.pathExtension == "jsonl" else { return false }
        switch surface {
        case .gateway:
            // `<root>/agents/<agentId>/sessions/<sessionId>.jsonl`. Skip the
            // `sessions.json` index and checkpoint/trajectory/deleted/reset/bak
            // siblings that live in the same directory.
            return url.deletingLastPathComponent().lastPathComponent == "sessions"
                && Self.isNativeSessionFile(url.lastPathComponent)
        case .sdk:
            let project = SessionDirectoryScanner.projectDirName(for: url, under: transcriptRoot)
            return Self.isSDKWorkspaceProjectDir(project)
        }
    }

    /// A canonical native session file, filtering the siblings OpenClaw keeps
    /// alongside them.
    static func isNativeSessionFile(_ name: String) -> Bool {
        guard name.hasSuffix(".jsonl") else { return false }
        if name.contains(".checkpoint.") { return false }
        if name.contains(".trajectory") { return false }
        for marker in [".deleted.", ".reset.", ".bak."] where name.contains(marker) {
            return false
        }
        return true
    }

    public func sessionID(forTranscript url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    public func projectDirName(forTranscript url: URL) -> String {
        switch surface {
        case .gateway:
            // `<root>/agents/<agentId>/sessions/<file>` — label by agent id.
            return url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        case .sdk:
            let slug = SessionDirectoryScanner.projectDirName(for: url, under: transcriptRoot)
            return Self.friendlyWorkspaceName(fromProjectDir: slug)
        }
    }

    // MARK: - Parsing

    /// The gateway surface never parses lines. We deliberately show no tokens
    /// and no cost for it rather than an invented number: this machine has no
    /// native gateway sample to validate a parser against, the type validator
    /// does not require `usage` on every assistant line, and `sessions.json`'s
    /// token fields are last-run / current-context snapshots (the OpenClaw docs
    /// call that shape legacy/unstable), not lifetime sums. We would rather show
    /// nothing than a wrong number. The SDK surface parses real Claude Code
    /// JSONL via the shared parser below.
    public func parseLine(_ line: Data) -> LineParseResult {
        switch surface {
        case .gateway: .malformed
        case .sdk: TranscriptLineParser.parse(line)
        }
    }

    public func makeReader(url: URL) -> any SessionReading {
        switch surface {
        case .gateway:
            // Activity-only: Working while the session JSONL grows, Done once
            // quiet, Ended when the gateway process exits. No usage.
            return FileActivityReader(url: url,
                                      sessionID: sessionID(forTranscript: url),
                                      entrypoint: displayName)
        case .sdk:
            // Standard Claude Code format → the default line tailer gives real
            // tokens, cost, and turn state.
            return TranscriptFileTailer(url: url, adapter: self)
        }
    }

    // MARK: - Processes

    public func agentPIDs(psComm: String, psArgs: String) -> [Int32] {
        switch surface {
        case .gateway:
            // The daemon runs as `node …/openclaw/openclaw.mjs <subcommand>`
            // (comm is `node`), so match on argv: an argument whose basename is
            // the launcher script or the `openclaw` bin — never a bare
            // `contains("openclaw")`, which would match a checkout path.
            var pids: [Int32] = []
            for rawLine in psArgs.split(separator: "\n") {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard let space = line.firstIndex(where: { $0 == " " || $0 == "\t" }),
                      let pid = Int32(line[..<space]) else { continue }
                let args = line[line.index(after: space)...]
                let tokens = args.split(whereSeparator: { $0 == " " || $0 == "\t" })
                if tokens.contains(where: { token in
                    let base = token.split(separator: "/").last.map(String.init) ?? String(token)
                    return base == "openclaw.mjs" || base == "openclaw"
                }) {
                    pids.append(pid)
                }
            }
            return pids.sorted()
        case .sdk:
            // OpenClaw drives the Claude Agent SDK, which spawns the `claude`
            // CLI (entrypoint "sdk-cli") in the temp workspace. That subprocess
            // IS a real `claude` process, so reuse Claude Code's detection and
            // pair it to the workspace session by cwd (see `match`). A NORMAL
            // `claude` process has a normal cwd and pairs only with Claude Code
            // sessions, never with an SDK workspace, so there is no collision.
            return Array(Set(ProcessOutputParser.claudePIDs(fromPSComm: psComm))
                .union(ProcessOutputParser.claudePIDs(fromPS: psArgs))).sorted()
        }
    }

    public func claimsProcess(cwd: String) -> Bool {
        switch surface {
        case .gateway:
            // agentPIDs already matched only openclaw processes.
            return true
        case .sdk:
            // We borrowed every `claude` pid; keep only those actually running
            // in an SDK temp workspace. Slugify the cwd the way Claude names its
            // project dir (non-alphanumerics → "-") and reuse the one classifier,
            // so a plain `claude` in ~/dev never reads as openclaw-sdk running.
            let slug = String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
            return Self.isSDKWorkspaceProjectDir(slug)
        }
    }

    public func match(processes: [RunningProcess],
                      candidates: [SessionMatchCandidate]) -> [String: Int32] {
        switch surface {
        case .gateway:
            // The native store records no cwd we can match on, so pair the most
            // recently active sessions to the daemon's processes, newest first.
            let recent = candidates.sorted { $0.lastModified > $1.lastModified }
            var match: [String: Int32] = [:]
            for (candidate, process) in zip(recent, processes.sorted { $0.pid < $1.pid }) {
                match[candidate.sessionID] = process.pid
            }
            // One gateway daemon multiplexes every native session, so share its
            // pid with whatever's left unpaired. Safe here (unlike a per-session
            // CLI): the gateway is activity-based, whose reader never emits
            // `.midTurn`, so a shared pid can never fabricate a `.stalled` row.
            if let pid = processes.min(by: { $0.pid < $1.pid })?.pid {
                for candidate in candidates where match[candidate.sessionID] == nil {
                    match[candidate.sessionID] = pid
                }
            }
            return match
        case .sdk:
            // The SDK transcript carries the temp workspace as its cwd, and the
            // driving `claude` subprocess runs there — pair by exact cwd, newest
            // session first within a cwd.
            var byCWD = Dictionary(grouping: candidates.filter { $0.lastKnownCWD != nil },
                                   by: { $0.lastKnownCWD! })
            for key in byCWD.keys {
                byCWD[key]!.sort { $0.lastModified > $1.lastModified }
            }
            let processesByCWD = Dictionary(grouping: processes, by: \.cwd)
            var match: [String: Int32] = [:]
            for (cwd, cwdProcesses) in processesByCWD {
                guard let sessions = byCWD[cwd] else { continue }
                for (session, process) in zip(sessions, cwdProcesses.sorted { $0.pid < $1.pid }) {
                    match[session.sessionID] = process.pid
                }
            }
            return match
        }
    }
}
