import Foundation
import Security

/// Passwords / keys, shared between the app and the extension through a keychain access group.
enum Keychain {
    private static let service = "CKClient.profile"

    private static func query(_ account: String) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let group = Constants.keychainGroup
        if !group.isEmpty { q[kSecAttrAccessGroup as String] = group }
        return q
    }

    static func save(_ s: Secrets, for account: String) {
        guard let data = try? JSONEncoder().encode(s) else { return }
        SecItemDelete(query(account) as CFDictionary)
        var q = query(account)
        q[kSecValueData as String] = data
        // readable after the first unlock: the extension may start (on demand) while the phone is locked
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }

    static func load(_ account: String) -> Secrets? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(Secrets.self, from: data)
    }

    static func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
