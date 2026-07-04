import Foundation
import AppKit

/// User-initiated update check against GitHub Releases — fires only when the
/// button in Settings is pressed, consistent with the app's "no network
/// unless you ask" contract. (Sparkle auto-updates arrive with code signing.)
@MainActor
final class UpdateChecker: ObservableObject {

    static let repo = "jaylmaao/agent-babysitter"

    enum Status: Equatable {
        case idle
        case checking
        case upToDate(String)
        case available(version: String, url: URL)
        case failed(String)
    }

    @Published private(set) var status: Status = .idle

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    func check() async {
        status = .checking
        var request = URLRequest(
            url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "accept")
        request.timeoutInterval = 12

        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            status = .failed("Couldn't reach github.com — check your connection.")
            return
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tag = root["tag_name"] as? String,
              let page = (root["html_url"] as? String).flatMap(URL.init(string:)) else {
            // 404 also lands here — private repo without auth, or no releases.
            status = .failed("No release information available yet.")
            return
        }
        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        if latest.compare(currentVersion, options: .numeric) == .orderedDescending {
            status = .available(version: latest, url: page)
        } else {
            status = .upToDate(currentVersion)
        }
    }

    func openReleasePage(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
