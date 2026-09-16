# Contributing

## Build and test

```bash
swift build
swift test
./Scripts/build-app.sh      # assembles build/ClaudeProfiles.app
./Scripts/install.sh        # builds and installs to /Applications
```

No third-party dependencies. Swift 6; Xcode 16 or newer. CI builds on macOS 15
and macOS 26.

One test skips itself when its environment is missing — process detection needs
the Claude desktop app actually running. It is meaningful locally and quiet in
CI.

## Layout

| Target | Role |
|---|---|
| `ProfileKit` | Library: profiles, usage, settings merge, session index, launching |
| `claude-profiles` | CLI |
| `ClaudeProfilesApp` | SwiftUI `MenuBarExtra` |

## Invariants worth not breaking

These are the assumptions the tool rests on. Each was established by testing
against a live install, and each has a test or a `doctor` check behind it.

**The default profile is read-only.** Every write path calls
`Paths.assertNotDefaultState()`. If you add one, call it. A bug here costs
someone their accumulated project settings.

**Sharing is allowlist-only.** `SettingsMerge.sharedProjectKeys` and
`SharedAssets.shareableSettingsKeys` enumerate what crosses between profiles.
Never invert these into denylists: an unknown key must stay local, so a future
Claude Code release cannot silently leak new per-account state. `hooks`,
`statusLine`, `apiKeyHelper` and `env` are excluded deliberately — the first
three each name a shell command Claude Code executes, so copying one would arm
code execution in an account that never opted in; the last routinely holds
secrets. Before adding a settings key, check whether its value is, or contains,
a command.

**Everything written is private to the user.** Directories go through
`Paths.createPrivateDirectory` (`0700`) and files through `AtomicWrite`
(`0600`, and `usingNewMetadataOnly` so a replaced file does not keep a looser
mode). The shared store holds MCP server environments; the default `umask`
would leave it listable by every local user.

**Path comparisons use `Paths.resolved`, not `resolvingSymlinksInPath()`.**
Foundation's resolver leaves a path untouched when it does not exist yet and
strips `/private` when it does, so two spellings of one location come back in
different forms. `Paths.resolved` runs the longest existing prefix through
`realpath(3)` and appends the rest. `Paths.safeRoot` also refuses a
`CLAUDE_PROFILES_ROOT` that overlaps Claude's own state, because the "under our
root" exemption would otherwise become a bypass.

**Destructive commands resolve exactly.** `ProfileStore.resolve(_:exact:)`
accepts a label prefix for convenience; `rm` passes `exact: true` so `rm w --yes`
cannot expand to "work".

**The launched app inherits nothing Claude Code reads.** `Launcher.childEnvironment`
strips every `CLAUDE*` and `ANTHROPIC_*` variable, then sets the two config-dir
variables. The list is prefix-based on purpose: Claude Code adds variables
faster than an explicit list would keep up, and each one describes the parent
session, not the child.

**The tool never handles credential material, and makes no network requests.**
Isolation comes from pointing `CLAUDE_SECURESTORAGE_CONFIG_DIR` at a per-profile
path; macOS does the rest. `Keychain.serviceName` only *computes* a name for
diagnostics. Keep it that way: a feature that needs a token or an API call
should be a separate tool.

**No symlinks below a config root.** Claude Code refuses a symlink at any
non-leaf component and emits a refusal event, so shared state is copied, never
linked. `Doctor` asserts this per profile.

**Use `ps`, not `pgrep`, to find app processes.** `pgrep` never matches its own
ancestors, so when this code runs inside a Claude Code session it cannot see the
desktop app hosting it — silently, and only in that context.

**The projects fingerprint hashes the projects map alone.** The rest of
`.claude.json` carries session telemetry that a live session rewrites every few
seconds; hashing the whole file produces a value that changes on its own and
asserts nothing. Note the canonical serializer matches `JSON.stringify`, not
Foundation: forward slashes must NOT be escaped, and project keys are file paths,
so getting this wrong changes every hash.

## Version-sensitive assumptions

Behavior observed against Claude desktop `2.110.0` / claude-code `2.1.271`, not
documented API:

- Keychain service naming (`Keychain.verifiedAgainst`)
- `plan-usage-history.json` schema and its key abbreviations
- Session transcript first-line shapes used to tell cloud from local
- The desktop app forwarding `CLAUDE_CONFIG_DIR` to spawned sessions

`doctor` warns when the installed claude-code version differs from the one these
were verified against. If you re-verify against a newer version, update
`Keychain.verifiedAgainst`.
