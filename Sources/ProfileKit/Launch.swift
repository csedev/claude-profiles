import Foundation

public struct LaunchResult: Sendable {
    public let pid: Int32
    public let logFile: URL
}

public enum LaunchError: Error, CustomStringConvertible {
    case appMissing(URL)
    public var description: String {
        switch self {
        case .appMissing(let u):
            return "Claude desktop app not found at \(u.path)"
        }
    }
}

public enum Launcher {
    /// Prefixes of environment variables the child must not inherit.
    ///
    /// Everything Claude Code or the API client reads from the environment
    /// describes the *parent* session or account, not the profile being
    /// launched: `CLAUDE_CODE_SESSION_ID` would make the child join the
    /// parent's session instead of starting its own, `ANTHROPIC_API_KEY` or
    /// `CLAUDE_CODE_OAUTH_TOKEN` would bind it to an account other than the
    /// one it signed in with, and `ANTHROPIC_BASE_URL` would route it through
    /// the parent's proxy. All of these are present when this tool runs from a
    /// terminal inside a Claude Code session. Stripping by prefix leaves the
    /// child with what it sees when launched from the Dock — the same baseline
    /// the default profile gets via `open -a`.
    static let strippedPrefixes = ["CLAUDE_", "CLAUDECODE", "ANTHROPIC_"]

    /// Ours, and harmless to pass on: a relocated store stays relocated for
    /// anything the child runs.
    static let keptDespitePrefix: Set<String> = [Paths.rootEnvironmentKey]

    /// The environment a profile's app is launched with.
    public static func childEnvironment(
        from parent: [String: String] = ProcessInfo.processInfo.environment,
        for profile: Profile
    ) -> [String: String] {
        var env = parent.filter { key, _ in
            keptDespitePrefix.contains(key) || !strippedPrefixes.contains { key.hasPrefix($0) }
        }
        env["CLAUDE_CONFIG_DIR"] = profile.paths.config.path
        env["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = profile.paths.credentialScope.path
        return env
    }

    /// The app's stdout and stderr go here, appended across launches. Rotated
    /// once, at 1 MB, so a chatty app cannot grow it without bound.
    static let launchLogLimit = 1 << 20

    static func openLaunchLog(_ url: URL) throws -> FileHandle {
        let fm = FileManager.default
        try Paths.assertNotDefaultState(url)
        if let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int,
            size > launchLogLimit
        {
            let previous = url.appendingPathExtension("1")
            try? fm.removeItem(at: previous)
            try? fm.moveItem(at: url, to: previous)
        }
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        return handle
    }

    /// Starts the desktop app bound to one profile.
    ///
    /// The profile boundary is the PAIR: `--user-data-dir` isolates web identity
    /// (the `sessionKey` cookie, bridge sessions, usage history), while
    /// `CLAUDE_CONFIG_DIR` isolates CLI config, transcripts, and the Keychain
    /// entry. Neither alone is sufficient — the first leaves spawned Code
    /// sessions on the default account, the second leaves the app itself on it.
    ///
    /// The app forwards the config dir to the sessions it spawns
    /// (`env.CLAUDE_CONFIG_DIR = pT(process.env.CLAUDE_CONFIG_DIR)`), so setting
    /// it here reaches Claude Code itself.
    @discardableResult
    public static func launch(_ profile: Profile) throws -> LaunchResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Paths.appBinary.path) else {
            throw LaunchError.appMissing(Paths.appBinary)
        }
        try Paths.assertNotDefaultState(profile.paths.config)
        try Paths.assertNotDefaultState(profile.paths.electron)
        try Paths.assertNotDefaultState(profile.paths.credentialScope)
        try Paths.createPrivateDirectory(profile.paths.credentialScope)

        let handle = try openLaunchLog(profile.paths.launchLog)

        // Refresh shared project settings before the app starts, so the first
        // session already has this machine's trust decisions. Never fatal: a
        // merge problem must not stop you opening the app.
        do { try SettingsMerge.materialize(into: profile) } catch {
            try? Journal.append(
                event: "materialize-failed", profile: profile, detail: String(describing: error))
        }

        let process = Process()
        process.executableURL = Paths.appBinary
        process.arguments = ["--user-data-dir=\(profile.paths.electron.path)"]
        process.environment = childEnvironment(for: profile)
        process.standardOutput = handle
        process.standardError = handle
        try process.run()

        var meta = profile.meta
        meta.lastLaunchedAt = .now
        try? ProfileStore.write(meta: meta)

        return LaunchResult(pid: process.processIdentifier, logFile: profile.paths.launchLog)
    }

    /// PIDs of app instances currently bound to a profile's user-data-dir.
    public static func runningPIDs(_ profile: Profile) -> [Int32] {
        appProcesses()
            .filter { $0.command.contains("user-data-dir=\(profile.paths.electron.path)") }
            .map(\.pid)
    }

    public static func isRunning(_ profile: Profile) -> Bool {
        !runningPIDs(profile).isEmpty
    }

    // MARK: - The default (unmanaged) profile

    /// PIDs of app instances bound to no managed profile — i.e. running on
    /// Claude's own state.
    public static func defaultRunningPIDs() -> [Int32] {
        let managedRoot = Paths.profilesDir.path
        return appProcesses()
            .filter { !$0.command.contains("--user-data-dir=\(managedRoot)") }
            .map(\.pid)
    }

    public static var isDefaultRunning: Bool { !defaultRunningPIDs().isEmpty }

    /// Launches or focuses the default profile.
    ///
    /// `open -a` does both: it activates a running instance rather than
    /// starting a second one, and passes no environment overrides, so the app
    /// uses Claude's own config exactly as it would if opened from the Dock.
    public static func launchOrFocusDefault() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "/Applications/Claude.app"]
        try process.run()
        process.waitUntilExit()
    }

    static let appMainBinary = "Claude.app/Contents/MacOS/Claude"

    /// Every running desktop-app main process, with its command line.
    ///
    /// Uses `ps`, not `pgrep`, deliberately: **pgrep never matches its own
    /// ancestors**. When this code runs inside a Claude Code session the
    /// desktop app *is* an ancestor, so pgrep reports the app as not running —
    /// silently, and only in that context. `ps` has no such exclusion.
    static func appProcesses() -> [(pid: Int32, command: String)] {
        run("/bin/ps", ["-axww", "-o", "pid=,command="])
            .split(separator: "\n")
            .compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard let space = trimmed.firstIndex(of: " "),
                    let pid = Int32(trimmed[trimmed.startIndex..<space])
                else { return nil }
                let command = String(trimmed[space...]).trimmingCharacters(in: .whitespaces)
                // Main process only: helpers carry --type=renderer and friends.
                guard command.contains(appMainBinary), !command.contains("--type=") else {
                    return nil
                }
                return (pid, command)
            }
    }

    static func run(_ tool: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
