import Foundation

public struct Check: Sendable {
    public enum Severity: String, Sendable { case ok, warn, fail }
    public let severity: Severity
    public let label: String
    public let detail: String
}

public enum Doctor {
    /// Claude Code refuses a symlink at any non-leaf component below the config
    /// root (PHASE0-FINDINGS.md, Discovery B) and emits a refusal event. A
    /// symlinked directory is non-leaf for everything under it, so those are the
    /// ones that matter; symlinked files are always leaves.
    public static func symlinkedDirectories(under root: URL, depth: Int = 0) -> [URL] {
        guard depth <= 6,
            let entries = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
                options: [])
        else { return [] }

        var found: [URL] = []
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [
                .isSymbolicLinkKey, .isDirectoryKey,
            ])
            if values?.isSymbolicLink == true {
                found.append(entry)
            } else if values?.isDirectory == true {
                found += symlinkedDirectories(under: entry, depth: depth + 1)
            }
        }
        return found
    }

    static func bundledClaudeCodeVersions() -> [String] {
        let dir = Paths.defaultElectronDir.appending(path: "claude-code")
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return entries.filter { $0.wholeMatch(of: /\d+\.\d+\.\d+/) != nil }.sorted()
    }

    public static func run() -> [Check] {
        var checks: [Check] = []
        let fm = FileManager.default

        let appExists = fm.fileExists(atPath: Paths.appBinary.path)
        checks.append(
            Check(
                severity: appExists ? .ok : .fail, label: "desktop app",
                detail: appExists ? Paths.appBinary.path : "not found"))

        let versions = bundledClaudeCodeVersions()
        let drift = !versions.isEmpty && !versions.contains(Keychain.verifiedAgainst)
        checks.append(
            Check(
                severity: drift ? .warn : .ok, label: "claude-code version",
                detail: drift
                    ? "app ships \(versions.joined(separator: ", ")); observed behavior was verified against \(Keychain.verifiedAgainst) — re-verify the keychain and usage-file derivations"
                    : "\(versions.joined(separator: ", ")) (verified against \(Keychain.verifiedAgainst))"
            ))

        let (identity, fingerprint) = ProfileStore.defaultProfile()
        checks.append(
            Check(
                severity: fingerprint == nil ? .warn : .ok, label: "default profile",
                detail: fingerprint.map {
                    "\(identity?.email ?? "unknown") · \($0.describedBriefly) — must be unchanged by any operation"
                } ?? "could not read \(Paths.defaultConfigJSON.path)"))

        for profile in ProfileStore.all() {
            let hasDirs =
                fm.fileExists(atPath: profile.paths.config.path)
                && fm.fileExists(atPath: profile.paths.electron.path)
            checks.append(
                Check(
                    severity: hasDirs ? .ok : .fail, label: "profile \(profile.label)",
                    detail: hasDirs
                        ? "\(profile.identity?.email ?? "(no Code session yet)") · keychain: \(Keychain.serviceName(configDir: profile.paths.config, secureStorageDir: profile.paths.credentialScope))"
                        : "missing config/ or electron/"))

            let bad = symlinkedDirectories(under: profile.paths.config)
            checks.append(
                Check(
                    severity: bad.isEmpty ? .ok : .fail,
                    label: "profile \(profile.label): symlink boundary",
                    detail: bad.isEmpty
                        ? "no symlinked directories under config root"
                        : "Claude Code will REFUSE: \(bad.map(\.path).joined(separator: ", "))"))
        }

        if ProfileStore.all().isEmpty {
            checks.append(
                Check(
                    severity: .ok, label: "profiles",
                    detail: "none yet — create one with `claude-profiles add <label>`"))
        }
        return checks
    }
}
