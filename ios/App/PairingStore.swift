import Foundation
import Security

enum PairingStore {
    private static let service = "com.san.androidviewer.pairing"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: "android-sender",
         kSecAttrSynchronizable as String: false]
    }
    static func load() -> PairingPayload? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? PairingPayload.parse(data)
    }
    static func save(_ pairing: PairingPayload) throws {
        let data = try JSONEncoder().encode(pairing)
        let values: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let updated = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if updated == errSecItemNotFound {
            var added = query
            values.forEach { added[$0.key] = $0.value }
            guard SecItemAdd(added as CFDictionary, nil) == errSecSuccess else { throw PairingError.invalidCode }
        } else if updated != errSecSuccess { throw PairingError.invalidCode }
    }
    static func forget() { SecItemDelete(query as CFDictionary) }
}
