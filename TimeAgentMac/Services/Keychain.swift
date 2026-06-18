import Foundation
import Security

/// TP API token stored in the macOS Keychain — same service/account the Electron
/// app used (net.omnevo.timeagent / tp-token), so an existing token is reused.
enum Keychain {
    static let service = "net.omnevo.timeagent"
    static let account = "tp-token"

    static func readToken() -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let s = String(data: data, encoding: .utf8) else { return nil }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    static func writeToken(_ token: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        if token.isEmpty { return true }
        var add = base
        add[kSecValueData as String] = Data(token.utf8)
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
