import CryptoKit
import Foundation

/// A summary of a `.claude.json` that pins the state we actually protect.
public struct Fingerprint: Sendable, Equatable, Codable {
    public let projects: Int
    /// Hash of the projects map ALONE.
    public let projectsSHA: String
    public let bytes: Int

    public var describedBriefly: String {
        "\(projects) projects · projects-sha:\(projectsSHA)"
    }
}

public enum Fingerprinter {
    /// Stable stringify: object keys sorted recursively, so key order never
    /// affects the hash. Mirrors the TypeScript reference implementation.
    static func canonical(_ value: Any) -> String {
        switch value {
        case is NSNull:
            return "null"
        case let dict as [String: Any]:
            let body = dict.keys.sorted()
                .map { "\(quote($0)):\(canonical(dict[$0]!))" }
                .joined(separator: ",")
            return "{\(body)}"
        case let array as [Any]:
            return "[\(array.map(canonical).joined(separator: ","))]"
        case let number as NSNumber:
            return canonicalNumber(number)
        case let string as String:
            return quote(string)
        default:
            return "null"
        }
    }

    private static func canonicalNumber(_ n: NSNumber) -> String {
        // Distinguish booleans, which bridge to NSNumber on Darwin.
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
        let d = n.doubleValue
        if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
        return String(d)
    }

    /// Hand-rolled to match `JSON.stringify` exactly.
    ///
    /// `JSONSerialization` escapes forward slashes (`\/`) and JavaScript does
    /// not. Project keys are absolute file paths, so that one difference changed
    /// every hash — which is how the mismatch against the TypeScript reference
    /// was found. Matching byte-for-byte keeps that reference usable as an
    /// independent oracle for the code that guards against data loss.
    private static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// Summarizes a config file without copying it.
    ///
    /// Hashes the `projects` map alone, not the whole file. The rest of
    /// `.claude.json` carries volatile per-session telemetry (`lastCost`,
    /// `lastSessionId`, token counts) that a live Claude Code session rewrites
    /// continuously — hashing the whole file yields a value that changes every
    /// few seconds and asserts nothing.
    public static func fingerprint(configFile: URL) -> Fingerprint? {
        guard let data = try? Data(contentsOf: configFile),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let projects = obj["projects"] as? [String: Any] ?? [:]
        let sha = SHA256.hash(data: Data(canonical(projects).utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(12)
        return Fingerprint(projects: projects.count, projectsSHA: String(sha), bytes: data.count)
    }
}
