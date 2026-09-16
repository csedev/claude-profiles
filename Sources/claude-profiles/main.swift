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

/// Strings read from Claude's own files are printed through this, so nothing
/// that came out of a transcript or config can carry a terminal escape.
func safe(_ text: String?) -> String? { text.map(TerminalText.sanitize) }

func describe(_ profile: Profile) -> String {
    var lines = ["  \(profile.label)\(Launcher.isRunning(profile) ? "  [running]" : "")"]
    lines.append("    account   \(safe(profile.identity?.email) ?? "(no Code session yet)")")
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
    print("  \(safe(identity?.email) ?? "(unknown)")")
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

    if let needle {
        if needle.caseInsensitiveCompare("default") == .orderedSame {
            report("DEFAULT", UsageReader.readDefault())
        } else {
            let profile = try ProfileStore.resolve(needle)
            report(profile.label, UsageReader.read(for: profile))
        }
    } else {
        report("DEFAULT", UsageReader.readDefault())
        for profile in ProfileStore.all() {
            print("")
            report(profile.label, UsageReader.read(for: profile))
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
    // Exact label or UUID only: `rm w --yes` must not quietly expand to "work".
    let profile = try ProfileStore.resolve(needle, exact: true)
    guard Launcher.runningPIDs(profile).isEmpty else {
        fail("'\(profile.label)' is running — quit it first")
    }
    guard confirmed else {
        print("would delete profile '\(profile.label)' at \(profile.paths.root.path)")
        print("  this removes that profile's login, transcripts, and settings.")
        print("  re-run with --yes to confirm.")
        return
    }
    let service = Keychain.serviceName(configDir: profile.paths.config, secureStorageDir: profile.paths.credentialScope)
    try ProfileStore.delete(id: profile.id)
    print("deleted profile '\(profile.label)'")
    print("note: the login Claude Code stored for it is still in your Keychain, under")
    print("      service \"\(service)\". This tool never touches that entry; to remove it:")
    print("      security delete-generic-password -s '\(service)'")
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
                TerminalText.sanitize(record.displayTitle) as NSString))
        if let cwd = safe(record.cwd) {
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
        if Launcher.isRunning(profile) {
            // Both sides rewrite .claude.json whole, so whichever writes last
            // wins. Nothing is corrupted (writes are atomic, and a backup is
            // taken first), but one side's changes can be lost.
            print(
                "  warning: '\(profile.label)' is running — it may overwrite what sync writes, or lose its own recent changes; quit it and re-run sync for a clean merge"
            )
        }
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
