import Foundation

/// Shares the rest of a Claude Code setup between profiles: memories, user
/// settings, and plugin configuration.
///
/// Same approach as `SettingsMerge` and for the same reason — Claude Code
/// refuses symlinks below a config root, so everything is copied.
public enum SharedAssets {
    // MARK: - Settings

    /// User settings safe to share between accounts.
    ///
    /// An allowlist, like the project keys. Two exclusions are deliberate:
    ///
    /// - `hooks` — these execute shell commands. Copying them between profiles
    ///   would silently arm code execution in an account that never opted in.
    /// - `env` — routinely holds machine-specific paths and secrets.
    ///
    /// `model` is also left out: entitlements differ per account, and pinning a
    /// model the other account cannot use fails at an unhelpful moment.
    public static let shareableSettingsKeys: Set<String> = [
        "permissions",
        "enabledPlugins",
        "extraKnownMarketplaces",
        "theme",
        "inputNeededNotifEnabled",
        "agentPushNotifEnabled",
        "statusLine",
        "outputStyle",
        "alwaysThinkingEnabled",
        "autoCompactEnabled",
    ]

    static var sharedSettingsFile: URL { Paths.sharedDir.appending(path: "settings.json") }
    static var sharedMemoryDir: URL { Paths.sharedDir.appending(path: "memory") }
    static var sharedPluginsDir: URL { Paths.sharedDir.appending(path: "plugins") }

    /// Plugin state worth carrying. The `cache/` and `marketplaces/` trees are
    /// re-fetchable and large, so only the manifests move.
    static let pluginManifests = ["installed_plugins.json", "known_marketplaces.json"]

    public struct AssetReport: Sendable, Equatable {
        public var memoryFiles = 0
        public var memoryProjects = 0
        public var settingsKeys = 0
        public var pluginManifests = 0
    }

    static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func writeJSON(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try AtomicWrite.write(data, to: url, backup: true)
    }

    @discardableResult
    public static func captureSettings(fromConfigDir dir: URL) throws -> Int {
        guard let settings = readJSON(dir.appending(path: "settings.json")) else { return 0 }
        var shared = readJSON(sharedSettingsFile) ?? [:]
        var learned = 0
        for (key, value) in settings where shareableSettingsKeys.contains(key) {
            shared[key] = value
            learned += 1
        }
        try writeJSON(shared, to: sharedSettingsFile)
        return learned
    }

    @discardableResult
    public static func materializeSettings(into profile: Profile) throws -> Int {
        guard let shared = readJSON(sharedSettingsFile), !shared.isEmpty else { return 0 }
        let target = profile.paths.config.appending(path: "settings.json")
        var settings = readJSON(target) ?? [:]
        var written = 0
        for (key, value) in shared where shareableSettingsKeys.contains(key) {
            settings[key] = value
            written += 1
        }
        try writeJSON(settings, to: target)
        return written
    }

    // MARK: - Memories

    /// Memories live at `projects/<slug>/memory/*.md` and describe repositories
    /// and working preferences, not accounts — so they are exactly the kind of
    /// thing a second account should not have to relearn.
    static func memoryDirectories(underProjects projects: URL) -> [(slug: String, dir: URL)] {
        let fm = FileManager.default
        guard let slugs = try? fm.contentsOfDirectory(atPath: projects.path) else { return [] }
        return slugs.compactMap { slug in
            let dir = projects.appending(path: slug).appending(path: "memory")
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
                return nil
            }
            return (slug, dir)
        }
    }

    /// Copies newer-or-missing files only, so a memory written under one profile
    /// is never clobbered by an older copy from another.
    @discardableResult
    static func copyNewer(from source: URL, to destination: URL) throws -> Int {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [
            .contentModificationDateKey
        ]) else { return 0 }

        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        var copied = 0
        for file in files where file.pathExtension == "md" {
            let target = destination.appending(path: file.lastPathComponent)
            let sourceDate =
                (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let targetDate =
                (try? target.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            guard sourceDate > targetDate else { continue }
            try? fm.removeItem(at: target)
            try fm.copyItem(at: file, to: target)
            copied += 1
        }
        return copied
    }

    @discardableResult
    public static func captureMemories(fromConfigDir dir: URL) throws -> (projects: Int, files: Int)
    {
        var projects = 0, files = 0
        for (slug, memoryDir) in memoryDirectories(underProjects: dir.appending(path: "projects")) {
            let copied = try copyNewer(from: memoryDir, to: sharedMemoryDir.appending(path: slug))
            if copied > 0 { projects += 1 }
            files += copied
        }
        return (projects, files)
    }

    @discardableResult
    public static func materializeMemories(into profile: Profile) throws -> (
        projects: Int, files: Int
    ) {
        let fm = FileManager.default
        guard let slugs = try? fm.contentsOfDirectory(atPath: sharedMemoryDir.path) else {
            return (0, 0)
        }
        var projects = 0, files = 0
        for slug in slugs {
            let destination = profile.paths.config
                .appending(path: "projects").appending(path: slug).appending(path: "memory")
            let copied = try copyNewer(
                from: sharedMemoryDir.appending(path: slug), to: destination)
            if copied > 0 { projects += 1 }
            files += copied
        }
        return (projects, files)
    }

    // MARK: - Plugins

    @discardableResult
    public static func capturePlugins(fromConfigDir dir: URL) throws -> Int {
        let fm = FileManager.default
        let source = dir.appending(path: "plugins")
        try fm.createDirectory(at: sharedPluginsDir, withIntermediateDirectories: true)
        var copied = 0
        for name in pluginManifests {
            let from = source.appending(path: name)
            guard fm.fileExists(atPath: from.path), let data = try? Data(contentsOf: from) else {
                continue
            }
            try AtomicWrite.write(data, to: sharedPluginsDir.appending(path: name), backup: true)
            copied += 1
        }
        return copied
    }

    @discardableResult
    public static func materializePlugins(into profile: Profile) throws -> Int {
        let fm = FileManager.default
        let destination = profile.paths.config.appending(path: "plugins")
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        var written = 0
        for name in pluginManifests {
            let from = sharedPluginsDir.appending(path: name)
            guard fm.fileExists(atPath: from.path), let data = try? Data(contentsOf: from) else {
                continue
            }
            try AtomicWrite.write(data, to: destination.appending(path: name), backup: true)
            written += 1
        }
        return written
    }
}
