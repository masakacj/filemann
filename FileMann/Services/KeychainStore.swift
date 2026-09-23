import Foundation
import Security

enum KeychainStore {
    private static let service = "com.masakacj.filemann"
    private static let smbPasswordAccount = "smb-password"
    private static let webDAVPasswordAccount = "webdav-password"

    static func savePassword(_ password: String) throws {
        try save(password, account: smbPasswordAccount)
    }

    static func loadPassword() -> String {
        load(account: smbPasswordAccount)
    }

    static func saveWebDAVPassword(_ password: String) throws {
        try save(password, account: webDAVPasswordAccount)
    }

    static func loadWebDAVPassword() -> String {
        load(account: webDAVPasswordAccount)
    }

    private static func save(_ password: String, account: String) throws {
        let data = Data(password.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        SecItemDelete(base as CFDictionary)

        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    private static func load(account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return ""
        }
        return value
    }
}
