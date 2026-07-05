import XCTest
@testable import AgentBabysitterCore

final class AgentInstallationTests: XCTestCase {

    private var allAdapters: [any AgentAdapter] {
        [ClaudeCodeAdapter(), CodexAdapter()]
            + AntigravityAdapter.allSurfaces()
            + GeminiAdapter.allSurfaces()
            + [CursorAdapter(), ManusAdapter()]
    }

    func testDesktopOnlyMachineHidesCLIsurfaces() {
        // Bundles present, no CLIs on PATH — the CLI-only surfaces vanish.
        let installedBundles: Set<String> = [
            "com.anthropic.claudefordesktop", "com.openai.codex",
            "com.google.antigravity", "com.google.antigravity-ide",
            "com.google.GeminiMacOS", "com.todesktop.230313mzl4w4u92",
            "im.manus.desktop",
        ]
        let installed = AgentInstallation.installedIDs(
            among: allAdapters,
            bundlePresent: { installedBundles.contains($0) },
            executablePresent: { _ in false })

        XCTAssertTrue(installed.isSuperset(of: [
            "claude-code", "codex", "antigravity", "antigravity-ide",
            "gemini", "cursor", "manus"]))
        // agy / gemini CLIs absent → these surfaces are not installed.
        XCTAssertFalse(installed.contains("antigravity-cli"))
        XCTAssertFalse(installed.contains("gemini-cli"))
    }

    func testCLIonlyMachineShowsOnlyWhatsOnPath() {
        // No app bundles at all, only the claude + agy CLIs present.
        let installed = AgentInstallation.installedIDs(
            among: allAdapters,
            bundlePresent: { _ in false },
            executablePresent: { ["claude", "agy"].contains($0) })

        XCTAssertEqual(installed, ["claude-code", "antigravity-cli"])
    }

    func testNothingInstalledYieldsEmpty() {
        let installed = AgentInstallation.installedIDs(
            among: allAdapters,
            bundlePresent: { _ in false },
            executablePresent: { _ in false })
        XCTAssertTrue(installed.isEmpty)
    }

    func testOneAppInstalledShowsOnlyThatApp() {
        // The user's example: only Claude installed → only claude-code shows.
        let installed = AgentInstallation.installedIDs(
            among: allAdapters,
            bundlePresent: { $0 == "com.anthropic.claudefordesktop" },
            executablePresent: { _ in false })
        XCTAssertEqual(installed, ["claude-code"])
    }

    func testAdapterInstallSignals() {
        XCTAssertEqual(ClaudeCodeAdapter().cliExecutableNames, ["claude"])
        XCTAssertEqual(CodexAdapter().cliExecutableNames, ["codex"])
        XCTAssertEqual(GeminiAdapter(surface: .cli).cliExecutableNames, ["gemini"])
        XCTAssertEqual(GeminiAdapter(surface: .desktop).cliExecutableNames, [])
        XCTAssertEqual(AntigravityAdapter(surface: .cli).cliExecutableNames, ["agy"])
        XCTAssertEqual(AntigravityAdapter(surface: .desktop).cliExecutableNames, [])
        // Desktop-only agents expose a bundle and no CLI.
        XCTAssertEqual(CursorAdapter().cliExecutableNames, [])
        XCTAssertEqual(ManusAdapter().cliExecutableNames, [])
        XCTAssertEqual(CursorAdapter().focusBundleIdentifiers, ["com.todesktop.230313mzl4w4u92"])
        XCTAssertEqual(ManusAdapter().focusBundleIdentifiers, ["im.manus.desktop"])
    }
}
