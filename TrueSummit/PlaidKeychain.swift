import Foundation
import Security

/// Minimal Keychain wrapper for Plaid item access tokens. One entry per Plaid
/// item, keyed by Plaid's `item_id`. Stored as generic passwords in the user's
/// default Keychain, accessible only when the device is unlocked.
enum PlaidKeychain {
    private static let service = "com.summit.plaid.accessToken"
    private static let cursorService = "com.summit.plaid.syncCursor"

    struct StoredItem: Codable, Hashable, Identifiable {
        var itemId: String
        var accessToken: String
        var institutionName: String?
        var linkedAt: Date

        var id: String { itemId }
    }

    // MARK: Access tokens

    static func saveItem(_ item: StoredItem) throws {
        let payload = try JSONEncoder().encode(item)
        try writeGenericPassword(service: service, account: item.itemId, data: payload)
    }

    static func allItems() -> [StoredItem] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { return [] }
        let decoder = JSONDecoder()
        return items.compactMap { entry in
            guard let data = entry[kSecValueData as String] as? Data else { return nil }
            return try? decoder.decode(StoredItem.self, from: data)
        }.sorted { $0.linkedAt < $1.linkedAt }
    }

    static func deleteItem(itemId: String) throws {
        try deleteGenericPassword(service: service, account: itemId)
        try? deleteGenericPassword(service: cursorService, account: itemId)
    }

    // MARK: Sync cursors

    static func cursor(for itemId: String) -> String? {
        guard let data = readGenericPassword(service: cursorService, account: itemId) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setCursor(_ cursor: String, for itemId: String) throws {
        guard let data = cursor.data(using: .utf8) else { return }
        try writeGenericPassword(service: cursorService, account: itemId, data: data)
    }

    // MARK: Private

    private static func writeGenericPassword(service: String, account: String, data: Data) throws {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw keychainError(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw keychainError(updateStatus)
        }
    }

    private static func readGenericPassword(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    private static func deleteGenericPassword(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw keychainError(status) }
    }

    private static func keychainError(_ status: OSStatus) -> NSError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error"
        return NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: message])
    }
}
