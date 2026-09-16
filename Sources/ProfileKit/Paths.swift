import Foundation

/// Filesystem layout for the tool, and the guards that keep it away from
/// Claude's own unmanaged state.
public enum Paths {
    public static var home: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    /// Overrides the managed root. Set for tests, or to relocate the store.
    public static let rootEnvironmentKey = "CLAUDE_PROFILES_ROOT"

    /// Root of everything this tool owns.
    public static var root: URL {
        if let override = ProcessInfo.processInfo.environment[rootEnvironmentKey],
            !override.isEmpty
        {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return home.appending(path: ".claude-profiles")
    }
    public static var profilesDir: URL { root.appending(path: "profiles") }
    public static var sharedDir: URL { root.appending(path: "shared") }
    public static var journalDir: URL { root.appending(path: "journal") }
    public static var sharedProjectSettings: URL {
        sharedDir.appending(path: "projects-settings.json")
    }

    // MARK: - Default (unmanaged) Claude state. Never written to.

    public static var defaultConfigDir: URL { home.appending(path: ".claude") }
    public static var defaultConfigJSON: URL { home.appending(path: ".claude.json") }
    public static var defaultElectronDir: URL {
        home.appending(path: "Library/Application Support/Claude")
    }

    public static let appBinary = URL(
        fileURLWithPath: "/Applications/Claude.app/Contents/MacOS/Claude")

    public enum GuardError: Error, CustomStringConvertible {
        case touchesDefaultState(URL)
        case rootOverlapsDefaultState(URL)

        public var description: String {
            switch self {
            case .touchesDefaultState(let url):
                return """
                    refusing to touch default Claude state: \(url.path)
                      (this tool only ever writes under \(Paths.root.path))
                    """
            case .rootOverlapsDefaultState(let url):
                return """
                    refusing to use \(url.path) as the profile store
                      (\(rootEnvironmentKey) must not point at, above, or inside \
                    ~/.claude, ~/.claude.json, or ~/Library/Application Support/Claude)
                    """
            }
        }
    }

    /// Canonical form of a path that may not exist yet: the longest existing
    /// prefix goes through `realpath(3)`, and the rest is appended unchanged.
    /// Applied to both sides of every comparison below, so a store relocated
    /// behind a symlink still passes, and a symlink planted inside the store
    /// that points back at Claude's own state still fails — even for a file
    /// that is about to be created.
    ///
    /// Foundation's `resolvingSymlinksInPath()` is not usable for this: it
    /// resolves nothing when the full path does not exist, and strips the
    /// `/private` prefix when it does, so two spellings of one location come
    /// back in different forms.
    static func resolved(_ url: URL) -> String {
        var path = url.standardizedFileURL.path
        var trailing: [String] = []
        while true {
            if let real = realpath(path, nil) {
                defer { free(real) }
                var result = String(cString: real)
                for component in trailing.reversed() {
                    result += result.hasSuffix("/") ? component : "/" + component
                }
                return result
            }
            let parent = (path as NSString).deletingLastPathComponent
            guard !parent.isEmpty, parent != path else { return path }
            trailing.append((path as NSString).lastPathComponent)
            path = parent
        }
    }

    static func isInside(_ path: String, _ ancestor: String) -> Bool {
        path == ancestor || path.hasPrefix(ancestor == "/" ? "/" : ancestor + "/")
    }

    /// The managed root, after checking that it does not overlap Claude's own
    /// state. `CLAUDE_PROFILES_ROOT` may relocate the store anywhere else, but
    /// a root at, above, or inside `~/.claude` would turn the "under our root"
    /// exemption in `assertNotDefaultState` into a bypass of it.
    static func safeRoot() throws -> String {
        let ourRoot = resolved(root)
        let protected = [defaultConfigDir, defaultConfigJSON, defaultElectronDir].map(resolved)
        for path in protected where isInside(path, ourRoot) || isInside(ourRoot, path) {
            throw GuardError.rootOverlapsDefaultState(root)
        }
        return ourRoot
    }

    /// Hard guard on every write path. The tool exists to not destroy the
    /// default profile's state, so proximity to it is an error, not a warning.
    public static func assertNotDefaultState(_ url: URL) throws {
        let target = resolved(url)
        let ourRoot = try safeRoot()

        // Anything under our own root is fine, even though it lives in $HOME.
        if isInside(target, ourRoot) { return }

        let forbidden = [defaultConfigDir, defaultConfigJSON, defaultElectronDir, home]
            .map(resolved)
        for path in forbidden where isInside(target, path) {
            throw GuardError.touchesDefaultState(url)
        }
    }

    /// Creates a directory, and any missing parents, readable by this user
    /// only — the same mode the profile directories get. The files inside
    /// carry account identity, memories, and MCP server environments, and the
    /// default `umask` would leave the directories listable by every local
    /// user. Existing directories are left as they are.
    public static func createPrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }
}

/// A profile's directory layout. The directory name is a stable UUID — never the
/// human label — because the Keychain service name is derived from the config
/// dir path, so renaming a directory would orphan its login.
public struct ProfilePaths: Sendable, Equatable {
    public let id: UUID
    public let root: URL

    public init(id: UUID) {
        self.id = id
        self.root = Paths.profilesDir.appending(path: id.uuidString.lowercased())
    }

    /// `CLAUDE_CONFIG_DIR` — CLI config, transcripts, and (implicitly) the keychain entry.
    public var config: URL { root.appending(path: "config") }
    /// Electron `--user-data-dir` — web identity, and `plan-usage-history.json`.
    public var electron: URL { root.appending(path: "electron") }
    public var meta: URL { root.appending(path: "meta.json") }

    /// `CLAUDE_SECURESTORAGE_CONFIG_DIR` — the hash input for the Keychain
    /// service name.
    ///
    /// By default Claude Code derives that name from `CLAUDE_CONFIG_DIR`, which
    /// silently couples a profile's credentials to its config dir *path*:
    /// reorganize the directory and the login is orphaned. Pointing secure
    /// storage at a separate, stable directory decouples the two, so config
    /// layout can change without anyone having to sign in again.
    public var credentialScope: URL { root.appending(path: "credentials") }
    public var launchLog: URL { root.appending(path: "launch.log") }

    /// Where Claude Code keeps its config file inside a custom config dir.
    public var configFile: URL {
        let alt = config.appending(path: ".config.json")
        return FileManager.default.fileExists(atPath: alt.path)
            ? alt : config.appending(path: ".claude.json")
    }

    public var usageHistoryFile: URL {
        electron.appending(path: "plan-usage-history.json")
    }

    /// The app partitions its Code session list by account UUID.
    public var codeSessionsDir: URL {
        electron.appending(path: "claude-code-sessions")
    }
}
