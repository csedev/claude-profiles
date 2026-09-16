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
    /// Environment variables that describe the *parent* session. If these leak
    /// into the child, it tries to join the parent's session instead of starting
    /// its own.
    static let sessionScopedVars = [
        "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_HOST_SESSION_ID",
        "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN",
        "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_PID", "CLAUDE_CODE_ENTRYPOINT",
    ]

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
        try fm.createDirectory(
            at: profile.paths.credentialScope, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        if !fm.fileExists(atPath: profile.paths.launchLog.path) {
            fm.createFile(atPath: profile.paths.launchLog.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: profile.paths.launchLog)
        try handle.seekToEnd()

        // Refresh shared project settings before the app starts, so the first
        // session already has this machine's trust decisions. Never fatal: a
        // merge problem must not stop you opening the app.
        do { try SettingsMerge.materialize(into: profile) } catch {
            try? Journal.append(
                event: "materialize-failed", profile: profile, detail: String(describing: error))
        }

        var env = ProcessInfo.processInfo.environment
        for key in sessionScopedVars { env.removeValue(forKey: key) }
        env["CLAUDE_CONFIG_DIR"] = profile.paths.config.path
        env["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = profile.paths.credentialScope.path

        let process = Process()
        process.executableURL = Paths.appBinary
        process.arguments = ["--user-data-dir=\(profile.paths.electron.path)"]
        process.environment = env
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
