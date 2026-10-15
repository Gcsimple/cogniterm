import Foundation
import Security

/// DEEPSEEK_API_KEY 的 Keychain 存取；只在拉起 sidecar 时注入子进程环境，不入库、不上报。
struct KeychainService {
    let service: String
    let account: String

    init(service: String = "com.cogniterm.app",
         account: String = "deepseek-api-key") {
        self.service = service
        self.account = account
    }

    enum KeyError: Error {
        case unhandled(OSStatus)
    }

    @discardableResult
    func save(_ secret: String) throws -> OSStatus {
        SecItemDelete(baseQuery as CFDictionary)
        guard let data = secret.data(using: .utf8) else {
            throw KeyError.unhandled(errSecParam)
        }
        var query = baseQuery
        query[kSecValueData as String] = data
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeyError.unhandled(status) }
        return status
    }

    func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func clear() -> OSStatus {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
