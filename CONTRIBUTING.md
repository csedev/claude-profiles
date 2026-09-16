# Contributing

## Build and test

```bash
swift build
swift test
./Scripts/build-app.sh      # assembles build/ClaudeProfiles.app
./Scripts/install.sh        # builds and installs to /Applications
```

No third-party dependencies. Swift 6 / Xcode 26.

Some tests skip themselves when their environment is missing — the Keychain
round-trip needs an unlocked login Keychain, and process detection needs the
Claude desktop app actually running. They are meaningful locally and quiet in CI.

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
Claude Code release cannot silently leak new per-account state. `hooks` and `env`
are excluded deliberately — the first would arm code execution in an account that
never opted in, the second routinely holds secrets.

**The tool never handles credential material.** Isolation comes from pointing
`CLAUDE_SECURESTORAGE_CONFIG_DIR` at a per-profile path; macOS does the rest.
`Keychain.serviceName` only *computes* a name for diagnostics.

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
