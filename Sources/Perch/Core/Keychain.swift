import Foundation
import Security

public final class KeychainKeyStore: KeyStoreProtocol {
    private let service: String

    public init(service: String = "com.perch.desktop") {
        self.service = service
    }

    private func account(_ kind: AIProviderKind) -> String { "apikey.\(kind.rawValue)" }

    public func apiKey(for kind: AIProviderKind) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(kind),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        query[kSecReturnData as String] = true
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setAPIKey(_ key: String?, for kind: AIProviderKind) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(kind)
        ]
        SecItemDelete(base as CFDictionary)
        guard let key = key, !key.isEmpty, let data = key.data(using: .utf8) else { return }
        var attributes = base
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    public func hasKey(for kind: AIProviderKind) -> Bool {
        guard let value = apiKey(for: kind) else { return false }
        return !value.isEmpty
    }
}
