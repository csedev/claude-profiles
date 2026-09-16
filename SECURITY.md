# Security

## What this tool touches

It manages local Claude Code state on your own machine. It makes no network
requests at all — usage figures are read from a file the desktop app maintains,
not fetched from an API — and it holds no credential of any kind.

### Credentials

**The tool never reads, writes, or moves Claude credential material.**

Isolation is achieved by pointing `CLAUDE_SECURESTORAGE_CONFIG_DIR` at a
per-profile directory. Claude Code derives its Keychain service name by hashing
that path, so each profile gets its own entry automatically and the secret is
only ever handled by Claude Code itself. `Keychain.serviceName` computes the
expected name for diagnostics; nothing reads the value.

An earlier version had an optional usage-token feature that stored a token you
minted with `claude setup-token` and queried `/api/oauth/usage` with it. It was
removed before the public release: the endpoint refuses long-lived tokens, and
it was the only code that touched a bearer token or the network.

### Removing a profile

`rm` deletes the profile's directories. It does **not** delete the login Claude
Code stored in your Keychain for that profile — this tool never touches those
entries — so the credential outlives the profile until you remove it yourself.
`rm` prints the service name and the `security delete-generic-password` command
that does it.

### Your data

Profiles live under `~/.claude-profiles`. Nothing is uploaded anywhere. The
journal at `~/.claude-profiles/journal/merge.log` records which projects were
merged and when — labels and counts, not file contents.

Everything the tool creates is readable by your user only: directories are
`0700`, files `0600`, and replacing a file that was more permissive leaves it
`0600`. Timestamped backups are taken before every rewrite and pruned to the
newest five per file. Each profile keeps the desktop app's stdout and stderr in
`launch.log`, rotated at 1 MB.

`CLAUDE_PROFILES_ROOT` relocates the store. A root at, inside, or above
`~/.claude`, `~/.claude.json`, or `~/Library/Application Support/Claude` is
refused, so the override cannot be used to talk the write guard into touching
Claude's own state. Path comparisons resolve symlinks on both sides.

### The environment a profile is launched with

Every `CLAUDE*` and `ANTHROPIC_*` variable is stripped before the app starts,
and only the two config-dir variables are set. Run from a terminal inside a
Claude Code session, the CLI would otherwise pass on that session's ID,
messaging socket, OAuth token, and `ANTHROPIC_BASE_URL` — and the profile
would quietly join the parent's session, proxy, or account. What remains is
what the app sees when launched from the Dock.

## What crosses between profiles, and what does not

`sync` uses allowlists. From `settings.json`, these are excluded on security
grounds:

- **`hooks`, `statusLine`, `apiKeyHelper`** — each names a shell command Claude
  Code executes. Copying them between profiles would arm code execution in an
  account that never opted in.
- **`env`** — routinely holds machine-specific paths and secrets.

Session telemetry stays with the account that produced it.

Two things that *are* shared deserve a clear statement, because they are the
reason a second account is useful and also the most sensitive data the tool
copies:

- **`mcpServers`** (per project, from `.claude.json`) carry the command Claude
  Code runs to start each server and the `env` it is started with — which is
  where MCP API keys usually live. They are copied into
  `shared/projects-settings.json`, its backups, and every profile's config.
- **`enabledMcpjsonServers`** and **`hasTrustDialogAccepted`** carry your
  approval decisions: a folder trusted, or a repository's `.mcp.json` servers
  enabled, under one account is trusted or enabled under all of them.

If that is not what you want for a particular account, do not run `sync`.

Note that `sync` rewrites a profile's `.claude.json` whole. If that profile's app
is running, whichever side writes last wins — nothing is corrupted, and a
backup is taken first, but one side's recent changes can be lost. `sync` warns
when this is the case.

## Scope of the isolation

Profiles are a **convenience and safety boundary, not a security boundary.**
Anything running as your user can read every profile's files, as it can read
`~/.claude` today. The guarantee is that *this tool* will not let one account's
state overwrite another's, and that the default profile is never written to.

## Reporting a vulnerability

Open a GitHub issue for anything non-sensitive. For something you would rather
not disclose publicly, use GitHub's private vulnerability reporting on this
repository.

Issues in Claude Code or the Claude desktop app themselves belong to Anthropic,
not here — this project only observes their local state.
