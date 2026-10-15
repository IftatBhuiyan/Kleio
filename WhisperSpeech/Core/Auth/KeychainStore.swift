import Foundation
import Security
import os

struct KeychainStore {
    enum Key: String {
        case stableDeviceID = "auth.identity.device-id"
        case backendAuthTokenOverride = "dictation.auth-token-override"
    }

    private static let logger = Logger(subsystem: "com.eclipsestudio.kleio", category: "keychain")

    private let service: String

    init(service: String = Bundle.main.bundleIdentifier ?? "com.eclipsestudio.kleio") {
        self.service = service
    }

    func string(for key: Key) -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                Self.logger.error("keychain read failed key=\(key.rawValue, privacy: .public) status=\(status)")
            }
            return nil
        }
        guard let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func set(_ value: String, for key: Key) {
        let data = Data(value.utf8)
        // SecItemUpdate rejects search-only keys (kSecReturnData/kSecMatchLimit) with
        // errSecParam, so the update query must stay bare or every overwrite silently
        // falls through to a failing SecItemAdd.
        let query = baseQuery(for: key)
        let attributes: [CFString: Any] = [
            kSecValueData: data
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus != errSecItemNotFound {
            Self.logger.error("keychain update failed key=\(key.rawValue, privacy: .public) status=\(updateStatus)")
        }

        var insertQuery = query
        insertQuery[kSecValueData as String] = data
        insertQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(insertQuery as CFDictionary, nil)
        if addStatus != errSecSuccess {
            Self.logger.error("keychain add failed key=\(key.rawValue, privacy: .public) status=\(addStatus)")
        }
    }

    func remove(_ key: Key) {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            Self.logger.error("keychain delete failed key=\(key.rawValue, privacy: .public) status=\(status)")
        }
    }

    private func baseQuery(for key: Key) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
    }
}
