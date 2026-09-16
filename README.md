# Claude Profiles

Run multiple Claude accounts side by side on macOS — switch freely, lose nothing,
and see usage for every account from the menu bar.

> Not affiliated with, endorsed by, or sponsored by Anthropic. "Claude" is a
> trademark of Anthropic, PBC. This is an independent community tool that reads
> and writes local Claude Code state on your own machine.

## The problem

Claude Code stores "who you are" in one fixed place: `~/.claude`, `~/.claude.json`,
and a single Keychain entry. If you have two accounts — personal and work, say —
they fight over that one slot. Signing into the second means signing out of the
first, every time. And because `~/.claude.json` fuses your account identity with
*every project's* trust decisions, tool permissions and MCP config, the second
account starts from nothing: re-approving every folder, re-enabling every server.

## What this does

Gives each account its own profile, so nothing is shared that shouldn't be and
everything that should be, is.

- **Both accounts run at once**, in separate windows, with no re-login ever.
- **Project settings follow you** — trust decisions, `allowedTools`, MCP servers,
  memories, and user settings are shared between profiles.
- **Neither account can overwrite the other.** They never touch the same storage.
- **Usage for every account in one place**, from local data — no API calls, no
  tokens, no credentials handled by this tool at all.

### What it deliberately does not do

- **It does not pool quota.** Switching between accounts you hold is ordinary
  account management; pooling quota across accounts to extend rate limits is a
  different thing, and this tool has no rotation feature.
- **It cannot show one account's sessions inside another.** The desktop app
  partitions its session list by account UUID and session groups live
  server-side. No local tool can merge those views — which is why the
  cross-account view lives in this app's own UI instead.

## Requirements

- macOS (Apple silicon or Intel), Claude desktop app installed at
  `/Applications/Claude.app`
- Swift 6 / Xcode 26 to build
- No third-party dependencies

## Install

```bash
git clone https://github.com/csedev/claude-profiles.git
cd claude-profiles
./Scripts/install.sh          # builds and installs to /Applications
```

That installs the menu bar app. For the CLI:

```bash
swift build
.build/debug/claude-profiles help
```

## Quick start

```bash
# 1. Create a profile and open the app to sign in
.build/debug/claude-profiles add work

# 2. Sign in with EMAIL + verification code, not Google  (see Known constraints)

# 3. Share your existing project settings into it
.build/debug/claude-profiles sync

# 4. Check both accounts
.build/debug/claude-profiles ls
```

Your existing Claude setup becomes the "default" profile. It is **read-only** —
this tool reads it to share settings outward, but never writes to it.

## Status

| Phase | State |
|---|---|
| Profile model + CLI | done |
| Usage engine | done |
| Menu bar app | done |
| Settings + memory sharing | done |
| Session index | done |
| Polish (quota alerts, login item) | done |

Verified against two live accounts on Claude desktop `2.110.0` / claude-code
`2.1.271`. 55 tests passing.

## CLI

| Command | Does |
|---|---|
| `add <label> [--no-launch]` | Create a profile and open the app to sign in |
| `ls` | Profiles, bound accounts, live usage |
| `launch <label>` | Open the desktop app under a profile |
| `usage [<label>]` | Quota detail, all windows, with peaks |
| `sync` | Share project settings across every profile |
| `rename <label> <new>` | Rename — safe, directories are stable IDs |
| `rm <label> --yes` | Delete a profile's local state |
| `sessions [<query>]` | Every session across all profiles, newest first |
| `token <label>` | Store a usage token (stdin; see SECURITY.md — currently vestigial) |
| `doctor` | Verify layout, boundaries, version assumptions |

## How a profile is isolated

A profile is a **triple** of directories. No single one is sufficient.

| Layer | Env var | Isolates |
|---|---|---|
| `electron/` | `--user-data-dir` | Web identity — `sessionKey` cookie, bridge sessions, usage history |
| `config/` | `CLAUDE_CONFIG_DIR` | CLI config, transcripts, session registry |
| `credentials/` | `CLAUDE_SECURESTORAGE_CONFIG_DIR` | The Keychain entry |

**The tool never reads, writes, or moves credential material.** Claude Code
derives its Keychain service name by hashing the secure-storage directory, so
pointing that at a per-profile path gives each profile its own entry
automatically. `doctor` computes the expected name for diagnostics; the secret
itself is never touched.

Secure storage is deliberately a *separate* directory from `config/`. By default
Claude Code derives the Keychain name from `CLAUDE_CONFIG_DIR`, which silently
couples a profile's login to its config dir *path* — reorganize the directory and
the login is orphaned. Splitting them decouples the two.

## Settings sharing

`.claude.json` fuses account identity with the per-project settings map, so it can
be neither symlinked nor copied wholesale. `sync` keeps the projects map
canonically in `shared/projects-settings.json`, materializes it into each profile,
and merges changes back.

Only **account-independent** keys are shared — `hasTrustDialogAccepted`,
`allowedTools`, `enabledMcpjsonServers`, `disabledMcpjsonServers`, `mcpServers`,
and the CLAUDE.md include flags. Session telemetry (`lastCost`, `lastSessionId`,
token counts, `activeWorktreeSession`) stays local to whichever account produced
it.

It is an **allowlist, not a denylist**: an unrecognized key stays local, so a
future Claude Code release cannot silently start leaking new per-account state
between profiles.

## What else `sync` shares

Beyond project settings, three things are account-agnostic and worth carrying:

| Asset | Where | Why |
|---|---|---|
| **Memories** | `projects/<slug>/memory/*.md` | Notes about repos and working preferences — knowledge about your code, not your account |
| **User settings** | `settings.json` | Permission allowlists especially; without them the second account re-prompts for everything |
| **Plugin manifests** | `plugins/installed_plugins.json`, `known_marketplaces.json` | Which plugins and marketplaces are configured |

Memories copy **newer-or-missing only**, by modification time, so a memory
written under one profile is never clobbered by an older copy from another.
Plugin `cache/` and `marketplaces/` are skipped — large and re-fetchable.

Settings use an allowlist, and three exclusions are deliberate:

- **`hooks`** — these execute shell commands. Copying them would silently arm
  code execution in an account that never opted in.
- **`env`** — routinely holds machine-specific paths and secrets.
- **`model`** — entitlements differ per account, and pinning a model the other
  account cannot use fails at an unhelpful moment.

## Safety

The default account is never modified. Every write path calls
`assertNotDefaultState()`, which refuses any path at or under `~/.claude`,
`~/.claude.json`, or `~/Library/Application Support/Claude`.

`ls` and `doctor` print a **fingerprint of the projects map** — count plus a
sorted-key hash. It deliberately excludes the volatile session telemetry stored
alongside it, which a live session rewrites every few seconds; hashing the whole
file yields a value that changes on its own and asserts nothing.

Writes are atomic — temp file, `fsync`, `rename(2)` — with timestamped backups,
and every merge is recorded in `journal/merge.log`.

## Known constraints

**Authentication must be serialized.** `claude://` is registered once against the
app bundle, so an OAuth callback goes to whichever instance is already running.
**Sign in with email + verification code**, which never leaves the webview. Google
SSO will hang. A deep-link router that dispatches callbacks by OAuth `state` is
the real fix; it is backlog.

**Accounts cannot see each other's sessions.** The desktop app partitions its Code
session list by account UUID, and session groups are server-side. No local tool
can merge those views — which is why this tool puts the cross-account view in its
own UI instead.

**Never symlink below a config root.** Claude Code refuses a symlink at any
non-leaf component. `doctor` asserts this.

## Usage windows

Read from each profile's `plan-usage-history.json`. The complete set, decoded
from the app bundle's server contract:

| Key | Window | Shown |
|---|---|---|
| `fh` | 5-hour limit | always |
| `sd` | Weekly limit | always |
| `so` | Weekly (Opus) | when reported |
| `sn` | Weekly (Sonnet) | when reported |
| `oa` | Weekly (apps) | when reported |
| `cw` | Weekly (Cowork) | when reported |
| `om` / `op` | Omelette (internal codename, not a model) | when reported |
| `xu` | Extra usage | when reported |

Secondary windows render only once an account reports them; most accounts report
just `fh` and `sd`, and a column of permanent zeroes would be noise.

### Per-model windows — not available

Claude's own popup shows a **Weekly · Fable** row and reset times. This app
cannot reproduce them, and the reason is a deliberate boundary rather than a
missing feature.

Those values exist only in `GET /api/oauth/usage`, which requires the
`user:profile` scope. Claude Code's own error strings are explicit:

> Long-lived tokens (from `claude setup-token` or `CLAUDE_CODE_OAUTH_TOKEN`) are
> limited to inference-only for security reasons.

So a minted token authenticates but gets `403 … does not meet scope requirement
user:profile`. The only credential carrying that scope is the full login token in
Claude Code's own Keychain entry — reading it would mean this tool holding the
credential that *is* your account, in exchange for two extra numbers. Not worth
it, so the app shows 5-hour and weekly from local history instead.

The client is built and tested (`UsageAPI`, `TokenStore`, the `model_scoped`
parser) in case a read-only usage scope ever appears. `token <label>` still works
for storing one.
## Sessions

`sessions` indexes every transcript across every profile — 455 files, 1.7 GB, in
about 0.6s, because only the head of each file is read.

Sessions are **attributed, never merged**. A cloud session (marked ☁) is stamped
with the account that created it and can only be opened by that account; the
desktop app partitions its own list by account UUID. So the index tells you which
account owns what, and clicking one in the menu bar opens the window that can
actually resume it.

## Contributing / caveats

This tool depends on observed behavior of Claude Code and the Claude desktop
app — the config-dir environment variables are documented surfaces, but the
usage-file schema, Keychain naming, and session layout are not. Everything
version-sensitive is pinned in one place and asserted by `doctor`, which fails
loudly rather than writing garbage when the shape changes. Verified against
Claude desktop `2.110.0` / claude-code `2.1.271`.

## Documentation

- [CONTRIBUTING.md](CONTRIBUTING.md) — build, layout, and the invariants that matter
- [SECURITY.md](SECURITY.md) — what this tool touches, and what it never touches

## License

MIT — see [LICENSE](LICENSE).
