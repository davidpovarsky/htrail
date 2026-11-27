import Foundation
import Security

enum PurelineWGKeychain {
    enum StorageError: LocalizedError {
        case failed(OSStatus)
        case invalidData
        var errorDescription: String? {
            switch self {
            case .failed(let status): return "Secure profile storage failed (\(status))."
            case .invalidData: return "The saved WireGuard profile is unavailable."
            }
        }
    }

    /// Use the already-entitled App Group, matching the official WireGuard iOS
    /// keychain pattern. Only the persistent reference enters VPN preferences.
    static func save(_ source: String) throws -> Data {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "com.davidpovarsky.pureline.wireguard",
            kSecAttrAccount: UUID().uuidString,
            kSecAttrLabel: "Pureline WireGuard profile",
            kSecAttrAccessGroup: PurelineWGContract.appGroup,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable: false,
            kSecValueData: Data(source.utf8),
            kSecReturnPersistentRef: true
        ]
        var result: CFTypeRef?
        let status = SecItemAdd(query as CFDictionary, &result)
        guard status == errSecSuccess else { throw StorageError.failed(status) }
        guard let reference = result as? Data else { throw StorageError.invalidData }
        return reference
    }

    static func load(_ reference: Data) throws -> String {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecValuePersistentRef: reference,
            kSecReturnData: true
        ] as CFDictionary, &result)
        guard status == errSecSuccess else { throw StorageError.failed(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw StorageError.invalidData
        }
        return value
    }

    static func delete(_ reference: Data) {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecValuePersistentRef: reference] as CFDictionary)
    }
}
