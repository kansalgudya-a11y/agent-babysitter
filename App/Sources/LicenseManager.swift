import Foundation
import AgentBabysitterCore

/// License activation via Lemon Squeezy's license-key API. Network happens
/// ONLY when the user presses Activate/Deactivate in Settings — never in the
/// background — keeping the app's "no network unless you ask" contract.
/// Once activated, the license is honored offline indefinitely.
///
/// During the free beta every feature works without a key; the section in
/// Settings just lets early buyers register. Before charging, set the real
/// store/product IDs below so foreign Lemon Squeezy keys can't activate.
@MainActor
final class LicenseManager: ObservableObject {

    /// Fill in once the Lemon Squeezy store exists; nil skips pinning (beta).
    static let expectation = LicenseParsing.Expectation(storeID: nil, productID: nil)
    static let isBeta = true

    enum State: Equatable {
        case unlicensed
        case activated(maskedKey: String)
    }

    @Published private(set) var state: State = .unlicensed
    @Published private(set) var lastError: String?
    @Published private(set) var busy = false

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config)
        migrateFromDefaultsIfNeeded()
        if let stored = Self.keychainRead(), !stored.key.isEmpty {
            state = .activated(maskedKey: Self.mask(stored.key))
        }
    }

    /// v0.1.x briefly kept the key in UserDefaults; move it to the keychain.
    private func migrateFromDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        if let key = defaults.string(forKey: "licenseKey"), !key.isEmpty {
            Self.keychainWrite(key: key,
                               instanceID: defaults.string(forKey: "licenseInstanceID") ?? "")
            defaults.removeObject(forKey: "licenseKey")
            defaults.removeObject(forKey: "licenseInstanceID")
        }
    }

    func activate(key rawKey: String) async {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        busy = true
        lastError = nil
        defer { busy = false }

        let instanceName = Host.current().localizedName ?? "Mac"
        guard let data = await post("activate", body: [
            "license_key": key, "instance_name": instanceName,
        ]) else {
            lastError = "Couldn't reach the license server — check your connection and try again."
            return
        }
        switch LicenseParsing.activation(from: data, expecting: Self.expectation) {
        case .success(let activation):
            Self.keychainWrite(key: activation.licenseKey, instanceID: activation.instanceID)
            state = .activated(maskedKey: Self.mask(activation.licenseKey))
        case .failure(.rejected(let message)):
            lastError = message
        case .failure(.wrongProduct):
            lastError = "That key belongs to a different product."
        case .failure(.malformed):
            lastError = "Unexpected response from the license server."
        }
    }

    func deactivate() async {
        guard let stored = Self.keychainRead() else {
            clearLocal()
            return
        }
        busy = true
        lastError = nil
        defer { busy = false }
        // Free the activation seat, then clear locally — but only once the
        // server has actually answered. A transport failure (offline, or a
        // Mac mid-wipe) means the seat is still held server-side; clearing
        // anyway silently burns it, so the key can never be re-used and the
        // customer hits the activation limit on their next Mac with nothing
        // to show for it. On any server response (success, or "already
        // deactivated"/"key not found") the seat is no longer ours, so we
        // clear. Keep the key on a transport failure and tell the user.
        let response = await post("deactivate", body: ["license_key": stored.key,
                                                       "instance_id": stored.instanceID])
        guard response != nil else {
            lastError = "Couldn't reach the license server, so this Mac's seat "
                + "wasn't freed. Check your connection and try again."
            return
        }
        clearLocal()
    }

    private func clearLocal() {
        Self.keychainDelete()
        state = .unlicensed
        lastError = nil
    }

    // MARK: - Keychain (a purchased credential doesn't belong in defaults)

    private static let keychainService = "app.agentbabysitter.license"
    /// A fixed account so the item is addressable (queried/updated/deleted by
    /// service+account) rather than an anonymous service-only generic password.
    private static let keychainAccount = "license"

    private static func keychainWrite(key: String, instanceID: String) {
        keychainDelete()
        guard let payload = try? JSONSerialization.data(withJSONObject:
            ["key": key, "instanceID": instanceID]) else { return }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            // Data-protection keychain (not the legacy file keychain): its ACL
            // is not bound to the signing identity, so a purchased key isn't
            // re-prompted or lost every time the app's cdhash changes across
            // builds/updates. AfterFirstUnlock keeps it readable for a
            // login-item launch after a reboot without the user present.
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: payload,
        ]
        SecItemAdd(attributes as CFDictionary, nil)
    }

    private static func keychainRead() -> (key: String, instanceID: String)? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: String],
              let key = root["key"] else { return nil }
        return (key, root["instanceID"] ?? "")
    }

    private static func keychainDelete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecUseDataProtectionKeychain as String: true,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func post(_ endpoint: String, body: [String: String]) async -> Data? {
        var request = URLRequest(
            url: URL(string: "https://api.lemonsqueezy.com/v1/licenses/\(endpoint)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return (try? await session.data(for: request))?.0
    }

    private static func mask(_ key: String) -> String {
        key.count > 4 ? "…\(key.suffix(4))" : key
    }
}
