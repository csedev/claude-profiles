# Security

## What this tool touches

It manages local Claude Code state on your own machine. It makes no network
requests in normal operation — usage figures are read from a file the desktop app
maintains, not fetched from an API.

### Credentials

**The tool never reads, writes, or moves Claude credential material.**

Isolation is achieved by pointing `CLAUDE_SECURESTORAGE_CONFIG_DIR` at a
per-profile directory. Claude Code derives its Keychain service name by hashing
that path, so each profile gets its own entry automatically and the secret is
only ever handled by Claude Code itself. `Keychain.serviceName` computes the
expected name for diagnostics; nothing reads the value.

There is an optional usage-token feature (`claude-profiles token`). It stores a
token you mint yourself with `claude setup-token`, in a Keychain entry this tool
creates, and reads it from stdin so it never reaches your shell history or the
process list. It is currently vestigial: `/api/oauth/usage` requires the
`user:profile` scope, and long-lived tokens are capped at inference-only scope by
Anthropic, so the request returns 403. The code is kept in case a read-only usage
scope appears. If you are not using it, `claude-profiles token <label> --remove`
leaves nothing stored.

### Your data

Profiles live under `~/.claude-profiles`. Nothing is uploaded anywhere. The
journal at `~/.claude-profiles/journal/merge.log` records which projects were
merged and when — labels and counts, not file contents.

## What is deliberately not shared between profiles

`sync` uses allowlists. Two settings are excluded on security grounds:

- **`hooks`** — they execute shell commands. Copying them between profiles would
  arm code execution in an account that never opted in.
- **`env`** — routinely holds machine-specific paths and secrets.

Session telemetry stays with the account that produced it.

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
