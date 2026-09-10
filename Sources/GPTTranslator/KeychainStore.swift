import Foundation
import LocalAuthentication
import Security

struct KeychainStore: Sendable {
    private let service = "com.gpttranslator.app"
    private static let interactionLock = NSLock()

    func readAPIKey(for provider: ModelProvider, allowInteraction: Bool = false) -> String? {
        readCredential(account: provider.rawValue, allowInteraction: allowInteraction)
    }

    func readAPIKey(account: String, allowInteraction: Bool = false) -> String? {
        readCredential(account: account, allowInteraction: allowInteraction)
    }

    private func readCredential(account: String, allowInteraction: Bool) -> String? {
        Self.interactionLock.lock()
        defer { Self.interactionLock.unlock() }

        var previousInteraction = DarwinBoolean(true)
        _ = SecKeychainGetUserInteractionAllowed(&previousInteraction)
        _ = SecKeychainSetUserInteractionAllowed(allowInteraction)
        defer { _ = SecKeychainSetUserInteractionAllowed(previousInteraction.boolValue) }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        let authenticationContext = LAContext()
        authenticationContext.interactionNotAllowed = !allowInteraction
        query[kSecUseAuthenticationContext as String] = authenticationContext
        if !allowInteraction {
            // Keep background reads silent even for legacy Keychain ACL entries.
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func saveAPIKey(_ key: String, for provider: ModelProvider) -> Bool {
        saveCredential(key, account: provider.rawValue)
    }

    @discardableResult
    func saveAPIKey(_ key: String, account: String) -> Bool {
        saveCredential(key, account: account)
    }

    private func saveCredential(_ key: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if key.isEmpty { return deleteCredential(account: account) }
        let data = Data(key.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        var insert = query
        insert[kSecValueData as String] = data
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    func deleteAPIKey(for provider: ModelProvider) -> Bool {
        deleteCredential(account: provider.rawValue)
    }

    @discardableResult
    func deleteAPIKey(account: String) -> Bool {
        deleteCredential(account: account)
    }

    private func deleteCredential(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
