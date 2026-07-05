import AppKit
import AgentBabysitterCore

/// Supplies the real "is it on this Mac?" checks for AgentInstallation:
/// LaunchServices for app bundles, the login shell's PATH for CLIs. The PATH
/// query spawns a shell, so it's cached — installation changes rarely and the
/// refresh tick runs every couple of seconds. Main-actor isolated: it's only
/// ever called from the model's refresh, and NSWorkspace wants the main thread.
@MainActor
enum AgentInstallDetector {

    static func installedIDs(among adapters: [any AgentAdapter]) -> Set<String> {
        let directories = loginShellPATHDirectories()
        return AgentInstallation.installedIDs(
            among: adapters,
            bundlePresent: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil },
            executablePresent: { name in
                directories.contains { dir in
                    FileManager.default.isExecutableFile(
                        atPath: (dir as NSString).appendingPathComponent(name))
                }
            })
    }

    // MARK: - Login shell PATH (cached)

    private static var cachedPATH: (capturedAt: Date, dirs: [String])?
    private static let pathTTL: TimeInterval = 300

    private static func loginShellPATHDirectories() -> [String] {
        if let cache = cachedPATH, Date().timeIntervalSince(cache.capturedAt) < pathTTL {
            return cache.dirs
        }
        var dirs = Set(defaultCLIDirectories())
        if let shellPATH = queryLoginShellPATH() {
            for dir in shellPATH.split(separator: ":") where !dir.isEmpty {
                dirs.insert(String(dir))
            }
        }
        let result = Array(dirs)
        cachedPATH = (Date(), result)
        return result
    }

    /// GUI apps inherit a minimal PATH, so seed the usual CLI install spots
    /// even before the login shell answers.
    private static func defaultCLIDirectories() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin",
                "\(home)/.local/bin", "\(home)/.bun/bin", "\(home)/.deno/bin",
                "\(home)/.npm-global/bin", "\(home)/.volta/bin", "\(home)/n/bin"]
    }

    private static func queryLoginShellPATH() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", "echo $PATH"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
