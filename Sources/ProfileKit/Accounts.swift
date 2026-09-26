import Foundation

/// Which account a profile's desktop app is signed in to.
public enum SignedInAccount: Sendable, Equatable {
    /// Signed in, to an account this machine has a record of.
    case known(Identity)
    /// Signed in, to an organization no account record on this machine names
    /// yet. Claude Code records the account once a session runs in that window.
    case unrecognized
    /// Nothing records a sign-in: no usage history and no Code session.
    case notSignedIn

    public var identity: Identity? {
        if case .known(let identity) = self { identity } else { nil }
    }

    /// One line for a person to read.
    public var summary: String {
        switch self {
        case .known(let identity): identity.email ?? "signed in"
        case .unrecognized: "signed in — email shows after a Code session runs"
        case .notSignedIn: "not signed in"
        }
    }
}

/// The accounts this machine has seen, for telling who each profile's app is
/// signed in as.
///
/// A profile's `.claude.json` names an account (`oauthAccount`), but that is
/// Claude Code's record, rewritten only when one of its sessions runs; the
/// desktop app itself never writes it. Sign a window out and back in as someone
/// else and the record goes on naming the previous account — two profiles then
/// show the same email — until a Code session next runs in that window.
///
/// The app's usage file is the live signal. Every sample is tagged with the
/// organization it was fetched for, and the app writes one as soon as it signs
/// in, so the latest sample's organization is who the app is signed in as now.
/// This book turns that organization back into an account.
public struct AccountBook: Sendable {
    /// Every account record seen, one per account and organization.
    public private(set) var known: [Identity]

    /// Kept in the store because Claude Code overwrites its record of an
    /// account as soon as a session runs under another one. Without it, an
    /// account a window switched away from could not be named when it
    /// switches back.
    static var file: URL { Paths.root.appending(path: "accounts.json") }

    init(known: [Identity]) { self.known = known }

    /// The remembered accounts plus whatever the given configs name now.
    public static func load(adding current: [Identity?]) -> AccountBook {
        var book = AccountBook(known: stored())
        book.learn(current.compactMap { $0 }, replacing: true)
        return book
    }

    /// Who a profile's app is signed in as.
    ///
    /// - Parameters:
    ///   - config: the account the profile's `.claude.json` names.
    ///   - usage: the profile's usage history, whose latest sample names the
    ///     organization the app is signed in to.
    ///   - backups: accounts named by Claude Code's own copies of each config,
    ///     read only when nothing else names the organization.
    public mutating func signedIn(
        config: Identity?, usage: UsageHistory?,
        backups: () -> [Identity] = AccountBook.accountsInBackups
    ) -> SignedInAccount {
        // Without usage history there is nothing to check the config against.
        guard let org = usage?.org else {
            return config.map(SignedInAccount.known) ?? .notSignedIn
        }
        if let config, config.organizationUUID == nil || config.organizationUUID == org {
            return .known(config)
        }
        if let account = account(in: org) { return .known(account) }
        // Claude Code keeps its last few copies of each config. They are the
        // only record of an account the app switched away from before this
        // book first saw it — and they rotate within minutes, so what they
        // teach is saved.
        learn(backups(), replacing: false)
        return account(in: org).map(SignedInAccount.known) ?? .unrecognized
    }

    /// The account seen in an organization. Two accounts in one organization
    /// cannot be told apart by it, so that is no answer.
    func account(in org: String) -> Identity? {
        let members = known.filter { $0.organizationUUID == org }
        return Set(members.map(\.accountUUID)).count == 1 ? members.first : nil
    }

    /// Adds accounts not yet known. `replacing` also updates known ones — right
    /// for a config's current record, wrong for a backup's older one.
    mutating func learn(_ seen: [Identity], replacing: Bool) {
        var changed = false
        for identity in seen where identity.accountUUID != nil && identity.organizationUUID != nil {
            if let i = known.firstIndex(where: {
                $0.accountUUID == identity.accountUUID
                    && $0.organizationUUID == identity.organizationUUID
            }) {
                guard replacing, known[i] != identity else { continue }
                known[i] = identity
            } else {
                known.append(identity)
            }
            changed = true
        }
        // Never fatal: failing to remember an account means naming it later,
        // never naming the wrong one.
        if changed { try? save() }
    }

    static func stored() -> [Identity] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([Identity].self, from: data)) ?? []
    }

    func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicWrite.write(try encoder.encode(known), to: Self.file)
    }

    /// Accounts named in Claude Code's backups of every config on this machine.
    public static func accountsInBackups() -> [Identity] {
        let configs =
            [(dir: Paths.defaultConfigDir, file: Paths.defaultConfigJSON)]
            + ProfileStore.allIDs().map(ProfilePaths.init(id:)).map {
                (dir: $0.config, file: $0.configFile)
            }
        return configs.flatMap { backupFiles(configDir: $0.dir, configFile: $0.file) }
            .compactMap(ProfileStore.readIdentity(configFile:))
    }

    /// Where Claude Code keeps copies of a config, observed in 2.1.x: rotated
    /// ones as `<config dir>/backups/<name>.backup.<ms>`, and an older single
    /// `<name>.backup` beside the file.
    static func backupFiles(configDir: URL, configFile: URL) -> [URL] {
        let dir = configDir.appending(path: "backups")
        let prefix = configFile.lastPathComponent + ".backup."
        let rotated = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix(prefix) }
            .sorted()
            .map { dir.appending(path: $0) }
        return rotated + [configFile.appendingPathExtension("backup")]
    }
}
