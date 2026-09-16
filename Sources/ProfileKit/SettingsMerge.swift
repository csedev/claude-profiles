import Foundation

/// Shares per-project settings between profiles.
///
/// `.claude.json` fuses account identity with the per-project settings map, so
/// it can be neither symlinked nor copied wholesale. Instead the projects map is
/// kept canonically in `shared/projects-settings.json`, materialized into each
/// profile before launch, and merged back afterwards.
public enum SettingsMerge {
    /// Per-project keys that are genuinely account-independent, and so safe to
    /// share. Everything else in a project entry — `lastCost`, `lastSessionId`,
    /// token counts, `activeWorktreeSession` — is session telemetry that belongs
    /// to whichever account produced it.
    ///
    /// This is an allowlist, not a denylist, on purpose: an unrecognized key
    /// stays local, so a future Claude Code release cannot silently start
    /// leaking new per-account state between profiles.
    public static let sharedProjectKeys: Set<String> = [
        "allowedTools",
        "mcpContextUris",
        "enabledMcpjsonServers",
        "disabledMcpjsonServers",
        "hasTrustDialogAccepted",
        "hasClaudeMdExternalIncludesApproved",
        "hasClaudeMdExternalIncludesWarningShown",
        "mcpServers",
    ]

    public struct MergeReport: Sendable, Equatable {
        public var projectsWritten: Int = 0
        public var projectsLearned: Int = 0
        public var before: Fingerprint?
        public var after: Fingerprint?
    }

    // MARK: - Shared store

    public static func loadShared() -> [String: [String: Any]] {
        guard let data = try? Data(contentsOf: Paths.sharedProjectSettings),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let projects = obj["projects"] as? [String: Any]
        else { return [:] }
        return projects.compactMapValues { $0 as? [String: Any] }
    }

    public static func saveShared(_ projects: [String: [String: Any]]) throws {
        let payload: [String: Any] = [
            "version": 1,
            "updatedAt": ISO8601DateFormatter().string(from: .now),
            "projects": projects,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try AtomicWrite.write(data, to: Paths.sharedProjectSettings, backup: true)
    }

    /// Keeps only the shareable keys from a project entry.
    static func shareable(_ entry: [String: Any]) -> [String: Any] {
        entry.filter { sharedProjectKeys.contains($0.key) }
    }

    // MARK: - Capture

    /// Learns shareable settings from a profile's config into the shared store.
    @discardableResult
    public static func captureBack(from profile: Profile) throws -> MergeReport {
        var report = MergeReport()
        guard let data = try? Data(contentsOf: profile.paths.configFile),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let projects = obj["projects"] as? [String: Any]
        else { return report }

        var shared = loadShared()
        for (path, value) in projects {
            guard let entry = value as? [String: Any] else { continue }
            let incoming = shareable(entry)
            guard !incoming.isEmpty else { continue }
            var merged = shared[path] ?? [:]
            // Last writer wins per key, which is what a human switching between
            // two windows actually expects.
            for (key, v) in incoming { merged[key] = v }
            if !NSDictionary(dictionary: merged).isEqual(to: shared[path] ?? [:]) {
                report.projectsLearned += 1
            }
            shared[path] = merged
        }
        try saveShared(shared)
        try Journal.append(
            event: "capture", profile: profile,
            detail: "learned \(report.projectsLearned) project(s)")
        return report
    }

    /// Seeds the shared store from the unmanaged default profile. This is how a
    /// new profile inherits years of accumulated trust decisions.
    @discardableResult
    public static func captureFromDefault() throws -> MergeReport {
        var report = MergeReport()
        guard let data = try? Data(contentsOf: Paths.defaultConfigJSON),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let projects = obj["projects"] as? [String: Any]
        else { return report }

        var shared = loadShared()
        for (path, value) in projects {
            guard let entry = value as? [String: Any] else { continue }
            let incoming = shareable(entry)
            guard !incoming.isEmpty else { continue }
            var merged = shared[path] ?? [:]
            for (key, v) in incoming { merged[key] = v }
            shared[path] = merged
            report.projectsLearned += 1
        }
        try saveShared(shared)
        try Journal.append(
            event: "capture-default", profile: nil,
            detail: "learned \(report.projectsLearned) project(s)")
        return report
    }

    // MARK: - Materialize

    /// Writes the shared settings into a profile's config, preserving that
    /// profile's identity and its own session telemetry.
    @discardableResult
    public static func materialize(into profile: Profile) throws -> MergeReport {
        var report = MergeReport()
        report.before = Fingerprinter.fingerprint(configFile: profile.paths.configFile)

        let shared = loadShared()
        guard !shared.isEmpty else { return report }

        var root: [String: Any] =
            (try? Data(contentsOf: profile.paths.configFile))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        var projects = root["projects"] as? [String: Any] ?? [:]

        for (path, sharedEntry) in shared {
            var entry = projects[path] as? [String: Any] ?? [:]
            // Only shareable keys are overwritten; anything this profile knows
            // that the shared store does not is left untouched.
            for (key, value) in sharedEntry where sharedProjectKeys.contains(key) {
                entry[key] = value
            }
            projects[path] = entry
            report.projectsWritten += 1
        }

        root["projects"] = projects
        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try AtomicWrite.write(data, to: profile.paths.configFile, backup: true)

        report.after = Fingerprinter.fingerprint(configFile: profile.paths.configFile)
        try Journal.append(
            event: "materialize", profile: profile,
            detail: "wrote \(report.projectsWritten) project(s)")
        return report
    }
}

/// Append-only record of every mutation, so a merge interrupted by a crash can
/// be understood after the fact.
public enum Journal {
    public static func append(event: String, profile: Profile?, detail: String) throws {
        let line =
            [
                ISO8601DateFormatter().string(from: .now), event,
                profile?.label ?? "-", detail,
            ].joined(separator: "\t") + "\n"

        try FileManager.default.createDirectory(
            at: Paths.journalDir, withIntermediateDirectories: true)
        let file = Paths.journalDir.appending(path: "merge.log")
        try Paths.assertNotDefaultState(file)

        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } else {
            try Data(line.utf8).write(to: file)
        }
    }
}
