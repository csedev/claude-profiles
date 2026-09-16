import Foundation

/// Persisted per-profile metadata. The human label lives here rather than in the
/// directory name, so renaming never changes the config-dir path — and therefore
/// never orphans the Keychain entry derived from it.
public struct ProfileMeta: Codable, Sendable, Equatable {
    public var id: UUID
    public var label: String
    public var createdAt: Date
    public var lastLaunchedAt: Date?
    /// Cached from the profile's config once a Code session has bound an account.
    public var accountUUID: String?
    public var accountEmail: String?

    public init(id: UUID, label: String, createdAt: Date = .now) {
        self.id = id
        self.label = label
        self.createdAt = createdAt
    }
}

/// The account bound to a profile, read from its `.claude.json`.
public struct Identity: Sendable, Equatable {
    public var email: String?
    public var displayName: String?
    public var organizationName: String?
    public var accountUUID: String?
    public var organizationUUID: String?
    public var seatTier: String?
}

public struct Profile: Sendable, Equatable {
    public let paths: ProfilePaths
    public var meta: ProfileMeta
    public var identity: Identity?
    public var fingerprint: Fingerprint?

    public var id: UUID { meta.id }
    public var label: String { meta.label }
}

public enum ProfileError: Error, CustomStringConvertible {
    case labelInUse(String)
    case notFound(String)
    case ambiguous(String, [String])
    case invalidLabel(String)

    public var description: String {
        switch self {
        case .labelInUse(let l): return "a profile named '\(l)' already exists"
        case .notFound(let l): return "no such profile: \(l)"
        case .ambiguous(let l, let m):
            return "'\(l)' matches several profiles: \(m.joined(separator: ", "))"
        case .invalidLabel(let l):
            return "invalid label '\(l)' — use letters, digits, and . _ @ -"
        }
    }
}

public enum ProfileStore {
    /// Stable pseudo-identifier for the unmanaged default profile. It owns no
    /// directory, but it still needs an identity for things keyed per account —
    /// its row in the menu bar, for one. Usually it is the account you use most.
    public static let defaultPseudoID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    /// Labels are user-facing only — directories are UUIDs — but they still go
    /// into shell output and comparisons, so keep them boring.
    static let allowedLabelCharacters = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "._@-"))

    public static func validate(label: String) throws {
        // Directories are UUIDs, so a label is never a path component and "."
        // cannot traverse anywhere — but they are still confusing as names.
        guard !label.isEmpty, label != ".", label != "..",
            label.unicodeScalars.allSatisfy(allowedLabelCharacters.contains)
        else { throw ProfileError.invalidLabel(label) }
    }

    // MARK: - Reading

    public static func allIDs() -> [UUID] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: Paths.profilesDir.path)
        else { return [] }
        return entries.compactMap(UUID.init(uuidString:))
    }

    public static func load(id: UUID) -> Profile? {
        let paths = ProfilePaths(id: id)
        guard let data = try? Data(contentsOf: paths.meta) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var meta = try? decoder.decode(ProfileMeta.self, from: data) else { return nil }

        let identity = readIdentity(configFile: paths.configFile)
        // Keep the cached account on meta fresh once a session has bound one.
        if let identity, identity.accountUUID != meta.accountUUID {
            meta.accountUUID = identity.accountUUID
            meta.accountEmail = identity.email
            try? write(meta: meta)
        }
        return Profile(
            paths: paths, meta: meta, identity: identity,
            fingerprint: Fingerprinter.fingerprint(configFile: paths.configFile))
    }

    public static func all() -> [Profile] {
        allIDs().compactMap(load(id:)).sorted { $0.label.lowercased() < $1.label.lowercased() }
    }

    /// Resolves a label, a UUID string, or — unless `exact` — a unique label
    /// prefix. Destructive commands pass `exact: true`: `rm w --yes` must not
    /// quietly expand to "work".
    public static func resolve(_ needle: String, exact: Bool = false) throws -> Profile {
        let profiles = all()
        if let uuid = UUID(uuidString: needle), let hit = profiles.first(where: { $0.id == uuid }) {
            return hit
        }
        let exactMatches = profiles.filter {
            $0.label.caseInsensitiveCompare(needle) == .orderedSame
        }
        if let only = exactMatches.first, exactMatches.count == 1 { return only }
        guard !exact else { throw ProfileError.notFound(needle) }
        let prefix = profiles.filter { $0.label.lowercased().hasPrefix(needle.lowercased()) }
        if prefix.count == 1, let only = prefix.first { return only }
        if prefix.count > 1 { throw ProfileError.ambiguous(needle, prefix.map(\.label)) }
        throw ProfileError.notFound(needle)
    }

    public static func readIdentity(configFile: URL) -> Identity? {
        guard let data = try? Data(contentsOf: configFile),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let a = obj["oauthAccount"] as? [String: Any]
        else { return nil }
        return Identity(
            email: a["emailAddress"] as? String,
            displayName: a["displayName"] as? String,
            organizationName: a["organizationName"] as? String,
            accountUUID: a["accountUuid"] as? String,
            organizationUUID: a["organizationUuid"] as? String,
            seatTier: a["seatTier"] as? String)
    }

    /// The unmanaged default profile, read-only, for comparison.
    public static func defaultProfile() -> (identity: Identity?, fingerprint: Fingerprint?) {
        (
            readIdentity(configFile: Paths.defaultConfigJSON),
            Fingerprinter.fingerprint(configFile: Paths.defaultConfigJSON)
        )
    }

    // MARK: - Writing

    public static func create(label: String) throws -> Profile {
        try validate(label: label)
        if all().contains(where: { $0.label.caseInsensitiveCompare(label) == .orderedSame }) {
            throw ProfileError.labelInUse(label)
        }
        let meta = ProfileMeta(id: UUID(), label: label)
        let paths = ProfilePaths(id: meta.id)
        try Paths.assertNotDefaultState(paths.root)

        for dir in [paths.config, paths.electron, paths.credentialScope] {
            try Paths.createPrivateDirectory(dir)
        }
        try write(meta: meta)
        return Profile(paths: paths, meta: meta, identity: nil, fingerprint: nil)
    }

    public static func rename(id: UUID, to label: String) throws {
        try validate(label: label)
        if all().contains(where: {
            $0.id != id && $0.label.caseInsensitiveCompare(label) == .orderedSame
        }) { throw ProfileError.labelInUse(label) }
        guard var profile = load(id: id) else { throw ProfileError.notFound(id.uuidString) }
        profile.meta.label = label
        try write(meta: profile.meta)
    }

    public static func write(meta: ProfileMeta) throws {
        let paths = ProfilePaths(id: meta.id)
        try Paths.assertNotDefaultState(paths.meta)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicWrite.write(try encoder.encode(meta), to: paths.meta)
    }

    public static func delete(id: UUID) throws {
        let paths = ProfilePaths(id: id)
        try Paths.assertNotDefaultState(paths.root)
        try FileManager.default.removeItem(at: paths.root)
    }
}
