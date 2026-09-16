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

        public var description: String {
            switch self {
            case .touchesDefaultState(let url):
                return """
                    refusing to touch default Claude state: \(url.path)
                      (this tool only ever writes under \(Paths.root.path))
                    """
            }
        }
    }

    /// Hard guard on every write path. The tool exists to not destroy the
    /// default profile's state, so proximity to it is an error, not a warning.
    public static func assertNotDefaultState(_ url: URL) throws {
        let target = url.standardizedFileURL.resolvingSymlinksInPath().path
        let ourRoot = root.standardizedFileURL.path

        // Anything under our own root is fine, even though it lives in $HOME.
        if target == ourRoot || target.hasPrefix(ourRoot + "/") { return }

        let forbidden = [
            defaultConfigDir, defaultConfigJSON, defaultElectronDir, home,
        ].map { $0.standardizedFileURL.path }

        for f in forbidden where target == f || target.hasPrefix(f + "/") {
            throw GuardError.touchesDefaultState(url)
        }
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
