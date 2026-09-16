import CryptoKit
import Foundation

/// Derives the macOS Keychain service name Claude Code uses for a given config dir.
///
/// **Diagnostic only.** This tool never reads, writes, or moves credential
/// material. Credentials isolate themselves: because the service name is a
/// function of the config dir, every `CLAUDE_CONFIG_DIR` automatically gets its
/// own Keychain entry. We compute the name so `doctor` can show the mapping.
///
/// Observed in Claude Code 2.1.271 (PHASE0-FINDINGS.md, Discovery A):
///
///     service = "Claude Code-credentials" + (isDefault ? "" : "-" + sha256(dir)[0..<8])
///
/// where `dir` is the NFC-normalized `CLAUDE_SECURESTORAGE_CONFIG_DIR` when set,
/// and the config dir otherwise.
public enum Keychain {
    static let base = "Claude Code"
    static let oauthFileSuffix = "-credentials"

    /// Version this derivation was verified against; `doctor` warns on drift.
    public static let verifiedAgainst = "2.1.271"

    /// `secureStorageDir` mirrors `CLAUDE_SECURESTORAGE_CONFIG_DIR`, which takes
    /// precedence over the config dir when set.
    public static func serviceName(configDir: URL?, secureStorageDir: URL? = nil) -> String {
        let source = secureStorageDir ?? configDir
        guard let source else { return base + oauthFileSuffix }
        let normalized = source.path.precomposedStringWithCanonicalMapping
        let digest = SHA256.hash(data: Data(normalized.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(8)
        return "\(base)\(oauthFileSuffix)-\(digest)"
    }

    /// The service name the unmanaged default profile uses.
    public static var defaultServiceName: String { serviceName(configDir: nil) }
}
