import Foundation
import ProfileKit

let usage = """
claude-profiles — run multiple Claude accounts side by side

  add <label> [--no-launch]  create a profile and open the app to sign in
  ls                       list profiles, bound accounts, and usage
  launch <label>           open the desktop app under a profile
  usage [<label>]          quota detail for one or all profiles
  rename <label> <new>     rename a profile (safe — directories are stable IDs)
  rm <label> --yes         delete a profile's local state
  sessions [<query>]       every session across all profiles, newest first
  token <label>            store a usage token (reads from stdin, never argv)
  token <label> --check    report a stored token's shape (never its value)
  token <label> --remove   forget a stored token
  sync                     share project settings across every profile
  doctor                   verify layout, boundaries, and version assumptions

Profiles live under \(Paths.root.path). The default Claude account is never modified.
"""

let signInGuidance = """

  ⚠  Sign in with EMAIL + verification code, not Google.

     Google leaves for your browser and returns through a claude:// link, which
     macOS delivers to whichever Claude instance is already running — usually the
     wrong one, so the login hangs. Email login stays inside this window.
"""

/// Bridges the async API into this synchronous CLI.
func runBlocking<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: Result<T, Error>!
    Task {
        do { result = .success(try await work()) } catch { result = .failure(error) }
        semaphore.signal()
    }
    semaphore.wait()
    return try result.get()
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func bar(_ percent: Double, width: Int = 16) -> String {
    let clamped = max(0, min(100, percent))
    let filled = Int((clamped / 100 * Double(width)).rounded())
    return String(repeating: "█", count: filled)
        + String(repeating: "·", count: width - filled)
}

func usageLine(_ history: UsageHistory?, indent: String) -> String {
    guard let history else { return "\(indent)usage     (no history yet)" }
    return UsageWindow.primary.compactMap { window -> String? in
        guard let value = history.current(window) else { return nil }
        return String(
            format: "%@%-9@ %@ %5.1f%%", indent, window.title as NSString,
            bar(value) as NSString, value)
    }.joined(separator: "\n")
}

func describe(_ profile: Profile) -> String {
    var lines = ["  \(profile.label)\(Launcher.isRunning(profile) ? "  [running]" : "")"]
    lines.append("    account   \(profile.identity?.email ?? "(no Code session yet)")")
    if let tier = profile.identity?.seatTier { lines.append("    plan      \(tier)") }
    if let fingerprint = profile.fingerprint {
        lines.append("    config    \(fingerprint.describedBriefly)")
    }
    lines.append(usageLine(UsageReader.read(for: profile), indent: "    "))
    return lines.joined(separator: "\n")
}

// MARK: - Commands

func cmdAdd(_ label: String, launch: Bool) throws {
    let profile = try ProfileStore.create(label: label)
    print("created profile '\(label)'  (id \(profile.id.uuidString.lowercased()))")
    print("  config   \(profile.paths.config.path)")
    print("  electron \(profile.paths.electron.path)")
    print("  keychain \(Keychain.serviceName(configDir: profile.paths.config, secureStorageDir: profile.paths.credentialScope))")
    guard launch else {
        print("\nrun `claude-profiles launch \(label)` and sign in to bind an account.")
        return
    }
    let result = try Launcher.launch(profile)
    print("\nlaunched app (pid \(result.pid)) — sign in to bind an account.")
    print(signInGuidance)
    print("then: claude-profiles ls")
}

func cmdList() {
    let (identity, fingerprint) = ProfileStore.defaultProfile()
    let defaultPIDs = Launcher.defaultRunningPIDs()
    let running =
        defaultPIDs.isEmpty
        ? "" : "  [running pid \(defaultPIDs.map(String.init).joined(separator: ","))]"
    print("DEFAULT (read-only — this tool never writes to it)\(running)")
    print("  \(identity?.email ?? "(unknown)")")
    if let fingerprint { print("    config    \(fingerprint.describedBriefly)") }
    print(usageLine(UsageReader.readDefault(), indent: "    "))

    let profiles = ProfileStore.all()
    print("\nMANAGED PROFILES (\(profiles.count))")
    if profiles.isEmpty {
        print("  none — create one with `claude-profiles add <label>`")
        return
    }
    for profile in profiles { print(describe(profile)) }
}

func cmdUsage(_ needle: String?) throws {
    /// Live meters include per-model weekly windows and reset times, neither of
    /// which the local history file records.
    func live(_ id: UUID) -> LiveUsage? {
        guard let token = TokenStore.load(for: id) else { return nil }
        do {
            return try runBlocking { try await UsageAPI.fetch(token: token) }
        } catch {
            // Surfacing this matters: a silently-swallowed failure looks
            // identical to having no token at all.
            print("  live usage unavailable — \(error)")
            return nil
        }
    }

    func reportLive(_ name: String, _ usage: LiveUsage) {
        print("\(name)  (live)")
        for meter in usage.meters {
            let reset =
                meter.resetsAt.map { " · resets \($0.formatted(date: .abbreviated, time: .shortened))" }
                ?? ""
            print(
                String(
                    format: "  %-22@ %@ %5.1f%%%@", meter.title as NSString,
                    bar(meter.utilization) as NSString, meter.utilization, reset as NSString))
        }
    }

    func report(_ name: String, _ history: UsageHistory?) {
        print("\(name)")
        guard let history else {
            print("  (no usage history)")
            return
        }
        for window in UsageWindow.allCases {
            guard let value = history.current(window) else { continue }
            let peak = history.peak(window).map { String(format: " · peak %.1f%%", $0) } ?? ""
            print(
                String(
                    format: "  %-15@ %@ %5.1f%%%@", window.title as NSString,
                    bar(value) as NSString, value, peak as NSString))
        }
        print(String(format: "  %d samples over %.1f days", history.samples.count,
                     history.span / 86_400))
    }

    func emit(_ profile: Profile) {
        if let usage = live(profile.id) {
            reportLive(profile.label, usage)
        } else {
            report(profile.label, UsageReader.read(for: profile))
            if !TokenStore.has(profile.id) {
                print("  (local history only — `claude-profiles token \(profile.label)` adds per-model windows)")
            }
        }
    }

    func emitDefault() {
        if let usage = live(ProfileStore.defaultPseudoID) {
            reportLive("DEFAULT", usage)
        } else {
            report("DEFAULT", UsageReader.readDefault())
            if !TokenStore.has(ProfileStore.defaultPseudoID) {
                print("  (local history only — `claude-profiles token default` adds per-model windows)")
            }
        }
    }

    if let needle {
        if needle.caseInsensitiveCompare("default") == .orderedSame {
            emitDefault()
        } else {
            emit(try ProfileStore.resolve(needle))
        }
    } else {
        emitDefault()
        for profile in ProfileStore.all() {
            print("")
            emit(profile)
        }
    }
}

func cmdLaunch(_ needle: String) throws {
    let profile = try ProfileStore.resolve(needle)
    let running = Launcher.runningPIDs(profile)
    guard running.isEmpty else {
        print("'\(profile.label)' is already running (pid \(running.map(String.init).joined(separator: ",")))")
        return
    }
    let result = try Launcher.launch(profile)
    print("launched '\(profile.label)' (pid \(result.pid))")
    print("  CLAUDE_CONFIG_DIR=\(profile.paths.config.path)")
    print("  --user-data-dir=\(profile.paths.electron.path)")
}

func cmdRename(_ needle: String, _ newLabel: String) throws {
    let profile = try ProfileStore.resolve(needle)
    try ProfileStore.rename(id: profile.id, to: newLabel)
    print("renamed '\(profile.label)' → '\(newLabel)'")
    print("  (login preserved — the config dir path, and so the keychain entry, is unchanged)")
}

func cmdRemove(_ needle: String, confirmed: Bool) throws {
    let profile = try ProfileStore.resolve(needle)
    guard Launcher.runningPIDs(profile).isEmpty else {
        fail("'\(profile.label)' is running — quit it first")
    }
    guard confirmed else {
        print("would delete \(profile.paths.root.path)")
        print("  this removes that profile's login, transcripts, and settings.")
        print("  re-run with --yes to confirm.")
        return
    }
    let service = Keychain.serviceName(configDir: profile.paths.config, secureStorageDir: profile.paths.credentialScope)
    try ProfileStore.delete(id: profile.id)
    print("deleted profile '\(profile.label)'")
    print("note: its keychain entry (\(service)) is left in place;")
    print("      remove it from Keychain Access if you want it gone.")
}

func cmdToken(_ needle: String, remove: Bool, check: Bool) throws {
    // The default profile owns no directory but still needs a token slot: it is
    // usually the busiest account.
    let isDefault = needle.caseInsensitiveCompare("default") == .orderedSame
    let id = isDefault ? ProfileStore.defaultPseudoID : try ProfileStore.resolve(needle).id
    let label = isDefault ? "default" : try ProfileStore.resolve(needle).label

    if check {
        guard let token = TokenStore.load(for: id) else {
            print("no token stored for '\(label)'")
            return
        }
        // Shape only — never the value.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let bad = token.unicodeScalars.filter { !allowed.contains($0) }
        print("token for '\(label)':")
        print("  length      \(token.count)")
        print("  prefix      \(token.prefix(13))…")
        print("  segments    \(token.split(separator: "-").count)")
        print("  whitespace  \(token.contains(where: \.isWhitespace) ? "YES — likely a broken copy" : "none")")
        print("  unexpected  \(bad.isEmpty ? "none" : String(bad.map(Character.init)))")
        if let result = try? runBlocking({ try await UsageAPI.validate(token: token) }) {
            print("  validate    HTTP \(result.status) \(result.body.prefix(120))")
        }
        return
    }

    if remove {
        let existed = TokenStore.delete(for: id)
        print(existed ? "removed token for '\(label)'" : "no token stored for '\(label)'")
        return
    }

    // The default profile needs no env prefix: `claude setup-token` already
    // runs against it.
    var envPrefix = ""
    if !isDefault {
        let paths = ProfilePaths(id: id)
        envPrefix =
            "CLAUDE_CONFIG_DIR=\(paths.config.path) \\\n"
            + "  CLAUDE_SECURESTORAGE_CONFIG_DIR=\(paths.credentialScope.path) \\\n  "
    }

    print("""
        Mint a long-lived token for '\(label)', then paste it below.

          \(envPrefix)claude setup-token

        Input is not echoed. The token never reaches your shell history, the
        process list, or the terminal scrollback — it goes straight into this
        tool's own Keychain entry, used only for GET /api/oauth/usage.
        """)
    print("token: ", terminator: "")

    guard let token = SecureInput.readSecret()?.trimmingCharacters(in: .whitespaces),
        !token.isEmpty
    else {
        fail("no token provided")
    }
    // Piping from the clipboard is the easy path, and the easy path should
    // fail loudly when the clipboard holds something else.
    guard token.hasPrefix("sk-ant-"), token.count >= 40 else {
        fail("""
            that does not look like a Claude token
              expected: starts with "sk-ant-", at least 40 characters
              got:      \(token.count) character(s) starting "\(token.prefix(7))"
              (copy the token printed by `claude setup-token` and try again)
            """)
    }

    try TokenStore.save(token: token, for: id)
    print("stored token for '\(label)' (\(token.count) characters)")
    print("run `claude-profiles usage \(label)` to verify it works.")
}

func cmdSessions(_ query: String?) {
    let records = query.map { SessionIndex.search($0) } ?? Array(SessionIndex.all().prefix(40))
    guard !records.isEmpty else {
        print(query.map { "no sessions matching '\($0)'" } ?? "no sessions found")
        return
    }

    let formatter = DateFormatter()
    formatter.dateFormat = "MMM d HH:mm"

    for record in records {
        // Bridge sessions are owned server-side by the account that made them.
        let marker = record.kind == .bridge ? "☁" : "·"
        let size = Double(record.sizeBytes) / 1_048_576
        print(
            String(
                format: "%@ %-12@ %-11@ %6.1fMB  %@", marker as NSString,
                record.profileLabel as NSString,
                formatter.string(from: record.modified) as NSString, size,
                record.displayTitle as NSString))
        if let cwd = record.cwd {
            print("               \(cwd)")
        }
    }

    let bridge = records.filter { $0.kind == .bridge }.count
    print("\n\(records.count) session(s) · ☁ \(bridge) cloud-owned · · \(records.count - bridge) local")
    print("cloud sessions open only in the account that created them.")
}

func cmdSync() throws {
    // Learn from the default profile first — it holds years of accumulated
    // trust decisions that a new account would otherwise have to re-approve.
    let seeded = try SettingsMerge.captureFromDefault()
    print("learned \(seeded.projectsLearned) project(s) from the default profile")

    for profile in ProfileStore.all() {
        let captured = try SettingsMerge.captureBack(from: profile)
        if captured.projectsLearned > 0 {
            print("learned \(captured.projectsLearned) project(s) from '\(profile.label)'")
        }
    }

    let shared = SettingsMerge.loadShared()
    print("shared store now holds \(shared.count) project(s)")

    // Everything else worth carrying between accounts.
    let settingsLearned = try SharedAssets.captureSettings(fromConfigDir: Paths.defaultConfigDir)
    let memories = try SharedAssets.captureMemories(fromConfigDir: Paths.defaultConfigDir)
    let plugins = try SharedAssets.capturePlugins(fromConfigDir: Paths.defaultConfigDir)
    for profile in ProfileStore.all() {
        _ = try? SharedAssets.captureSettings(fromConfigDir: profile.paths.config)
        _ = try? SharedAssets.captureMemories(fromConfigDir: profile.paths.config)
    }
    print(
        "shared assets: \(settingsLearned) setting(s), \(memories.files) memory file(s) across \(memories.projects) project(s), \(plugins) plugin manifest(s)"
    )

    for profile in ProfileStore.all() {
        let report = try SettingsMerge.materialize(into: profile)
        let delta =
            report.before?.projectsSHA == report.after?.projectsSHA ? "unchanged" : "updated"
        print("  → '\(profile.label)': wrote \(report.projectsWritten) project(s) (\(delta))")

        let settings = (try? SharedAssets.materializeSettings(into: profile)) ?? 0
        let mem = (try? SharedAssets.materializeMemories(into: profile)) ?? (projects: 0, files: 0)
        let plug = (try? SharedAssets.materializePlugins(into: profile)) ?? 0
        print(
            "      \(settings) setting(s), \(mem.files) memory file(s), \(plug) plugin manifest(s)"
        )
    }

    // The default profile is read-only. It is the state this tool exists to
    // protect, so it is never a merge target.
    print("\ndefault profile: read-only, not modified")
}

func cmdDoctor() {
    var failures = 0
    for check in Doctor.run() {
        let mark =
            switch check.severity {
            case .ok: " ok "
            case .warn: "WARN"
            case .fail: "FAIL"
            }
        if check.severity == .fail { failures += 1 }
        print("[\(mark)] \(check.label)\n       \(check.detail)")
    }
    print(failures == 0 ? "\nall checks passed" : "\n\(failures) check(s) failed")
    if failures > 0 { exit(1) }
}

// MARK: - Entry

let arguments = Array(CommandLine.arguments.dropFirst())
let flags = Set(arguments.filter { $0.hasPrefix("--") })
let positional = arguments.filter { !$0.hasPrefix("--") }

do {
    switch positional.first {
    case "add":
        guard positional.count > 1 else { fail("usage: claude-profiles add <label>") }
        try cmdAdd(positional[1], launch: !flags.contains("--no-launch"))
    case "ls", "list":
        cmdList()
    case "launch":
        guard positional.count > 1 else { fail("usage: claude-profiles launch <label>") }
        try cmdLaunch(positional[1])
    case "usage":
        try cmdUsage(positional.count > 1 ? positional[1] : nil)
    case "rename":
        guard positional.count > 2 else {
            fail("usage: claude-profiles rename <label> <new-label>")
        }
        try cmdRename(positional[1], positional[2])
    case "rm", "remove":
        guard positional.count > 1 else { fail("usage: claude-profiles rm <label> --yes") }
        try cmdRemove(positional[1], confirmed: flags.contains("--yes"))
    case "token":
        guard positional.count > 1 else { fail("usage: claude-profiles token <label>") }
        try cmdToken(
            positional[1], remove: flags.contains("--remove"),
            check: flags.contains("--check"))
    case "sessions":
        cmdSessions(positional.count > 1 ? positional[1] : nil)
    case "sync":
        try cmdSync()
    case "doctor":
        cmdDoctor()
    case "help", "--help", "-h", nil:
        print(usage)
    case .some(let unknown):
        fail("unknown command: \(unknown)\n\n\(usage)")
    }
} catch {
    fail(String(describing: error))
}
