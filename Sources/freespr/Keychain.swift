import Foundation
import Security

/// OpenAI API key storage. Generic password, service "freespr", account "openai-api-key".
/// kSecAttrAccessibleAfterFirstUnlock so the RunAtLoad daemon can read it at login without an
/// interactive unlock prompt. Same stably-signed binary writes (init) and reads (run), so the
/// item ACL grants silent self-access — zero prompts in steady state.
enum Keychain {
    static let service = "freespr"
    static let account = "openai-api-key"

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Upsert: update in place if present, else add. Never creates duplicate items.
    static func store(_ key: String) throws {
        let data = Data(key.utf8)
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(baseQuery() as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery()
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw FreesprError.keychain(addStatus) }
        } else if status != errSecSuccess {
            throw FreesprError.keychain(status)
        }
    }

    static func load() throws -> String {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else { throw FreesprError.missingAPIKey }
        guard status == errSecSuccess, let data = item as? Data,
              let s = String(data: data, encoding: .utf8) else {
            throw FreesprError.keychain(status)
        }
        return s
    }

    /// Presence check that does NOT return/decrypt the secret (cheaper, no prompt).
    static func exists() -> Bool {
        var query = baseQuery()
        query[kSecReturnData as String] = false
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
    }

    static func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw FreesprError.keychain(status)
        }
    }
}
