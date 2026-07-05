import Foundation

/// Decides which agents are actually installed so the UI never lists an app
/// the user doesn't have. An agent counts as installed when any of its app
/// bundles is registered OR any of its CLI executables is on PATH. The two
/// presence checks are injected: the app layer supplies real LaunchServices
/// and filesystem lookups, tests supply fakes. Kept pure and in Core so the
/// rule itself is unit-tested.
public enum AgentInstallation {

    public static func installedIDs(
        among adapters: [any AgentAdapter],
        bundlePresent: (String) -> Bool,
        executablePresent: (String) -> Bool
    ) -> Set<String> {
        var installed: Set<String> = []
        for adapter in adapters {
            if adapter.focusBundleIdentifiers.contains(where: bundlePresent)
                || adapter.cliExecutableNames.contains(where: executablePresent) {
                installed.insert(adapter.id)
            }
        }
        return installed
    }
}
