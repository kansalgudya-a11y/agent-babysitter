import Foundation

/// Tracks one transcript file: reads only bytes appended since the last call,
/// feeds them through the parser into a reducer, and remembers growth times
/// from file mtime (so a launch scan of an old transcript doesn't read as
/// fresh activity).
public final class TranscriptFileTailer {

    public let url: URL
    /// Session UUID, taken from the transcript filename.
    public let sessionID: String

    public private(set) var reducer = TranscriptReducer()
    public private(set) var costAccumulator = CostAccumulator()
    public private(set) var lastGrowthAt: Date?
    /// cwd from the most recent entry that carried one.
    public private(set) var lastKnownCWD: String?
    /// entrypoint from the most recent entry that carried one
    /// ("claude-desktop", "sdk-cli", …).
    public private(set) var lastKnownEntrypoint: String?

    private var offset: UInt64 = 0
    private var parser = TranscriptTailParser()

    /// A transcript with this many undecodable lines is presumed corrupt;
    /// keep watching others but stop trusting this one.
    public static let unreadableThreshold = 50

    public var isUnreadable: Bool {
        parser.malformedLineCount > Self.unreadableThreshold
    }

    public init(url: URL) {
        self.url = url
        self.sessionID = url.deletingPathExtension().lastPathComponent
    }

    /// Read appended bytes (if any) and fold them into the reducer.
    /// Returns the newly parsed entries.
    public func catchUp() throws -> [TranscriptEntry] {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? UInt64) ?? 0

        if size < offset {
            // File shrank — rebuild from scratch rather than reading garbage.
            offset = 0
            parser = TranscriptTailParser()
            reducer = TranscriptReducer()
            costAccumulator = CostAccumulator()
        }
        guard size > offset else { return [] }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: Int(size - offset)) ?? Data()
        offset += UInt64(data.count)

        let entries = parser.consume(data)
        for entry in entries {
            reducer.consume(entry)
            costAccumulator.consume(entry)
            if let cwd = entry.cwd { lastKnownCWD = cwd }
            if let entrypoint = entry.entrypoint { lastKnownEntrypoint = entrypoint }
        }
        lastGrowthAt = attributes[.modificationDate] as? Date ?? Date()
        return entries
    }
}

/// Launch-time enumeration of `~/.claude/projects/`: every `<project-dir>/
/// <session-uuid>.jsonl` modified within `maxAge`.
public enum SessionDirectoryScanner {

    public static func recentTranscripts(under root: URL,
                                         maxAge: TimeInterval,
                                         now: Date = Date()) -> [SessionFileInfo] {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(at: root,
                                                            includingPropertiesForKeys: nil,
                                                            options: [.skipsHiddenFiles]) else {
            return []
        }
        var found: [SessionFileInfo] = []
        for dir in projectDirs {
            let files = (try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles])) ?? []
            for file in files where file.pathExtension == "jsonl" {
                guard let values = try? file.resourceValues(
                        forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                      values.isRegularFile == true,
                      let modified = values.contentModificationDate,
                      now.timeIntervalSince(modified) <= maxAge else { continue }
                found.append(SessionFileInfo(
                    sessionID: file.deletingPathExtension().lastPathComponent,
                    projectDirName: dir.lastPathComponent,
                    lastModified: modified))
            }
        }
        return found
    }
}
