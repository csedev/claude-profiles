import Foundation
import Security

/// Stores per-profile API tokens in a Keychain entry this tool owns.
///
/// Deliberately a *separate* item from Claude Code's own credentials. We create
/// it, so reading it back never prompts — and it holds a token the user minted
/// explicitly with `claude setup-token`, which they can revoke without touching
/// their login.
///
/// The token is used for exactly one thing: `GET /api/oauth/usage`. It is never
/// logged, never passed as a command-line argument, and never written to disk
/// outside the Keychain.
public enum TokenStore {
    static let service = "io.github.csedev.claude-profiles.usage-token"

    public enum TokenError: Error, CustomStringConvertible {
        case keychain(OSStatus)

        public var description: String {
            switch self {
            case .keychain(let status):
                let message =
                    SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
                return "keychain error: \(message)"
            }
        }
    }

    static func account(for id: UUID) -> String { id.uuidString.lowercased() }

    public static func save(token: String, for id: UUID) throws {
        let account = account(for: id)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)

        var attributes = base
        attributes[kSecValueData as String] = Data(token.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw TokenError.keychain(status) }
    }

    public static func load(for id: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: id),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func has(_ id: UUID) -> Bool { load(for: id) != nil }

    @discardableResult
    public static func delete(for id: UUID) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: id),
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }
}
