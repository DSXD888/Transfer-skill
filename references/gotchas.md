# Gotchas — what a naive `s/oldname/newname/` misses

A blind global find-and-replace of the old username is the obvious approach and it is wrong on every axis. These are the traps, drawn from a real transfer audit of `Testproject1`.

## 1. The username isn't always there
Several real breakages contain **no username at all**:
- `core.hookspath` in `.git/config` is an absolute path to the old project location — breaks hooks, never matched by a username replace if you only scan tracked files (`.git/config` is not tracked).
- Dash-encoded session paths `-Users-old-Desktop-Proj` (Claude/Codex encode the project path this way for memory/session dirs). A `/Users/old`-anchored regex misses these entirely.
- `runtime/daemon.info.json` embeds an absolute `~/Library/Application Support/<bundle-id>/state` stateRoot and a live PID — machine-local, must be regenerated, not rewritten.

## 2. Rewriting history is a bug, not a feature
~130 of ~180 files that mention the old path are session logs, handoffs, and test evidence. They are a *true record* of what ran on the old machine. Rewriting an "observed launch command" or a dated "Repo:" header makes the record lie. Leave them. A privacy scrub (if wanted) is a separate, opt-in pass.

## 3. Secrets must be regenerated, and one token hides in ~10 places
- A single agent-mail bearer token was reused across `*.mcp.json` (×6), `.codex/config.toml`, `.vscode/mcp.json`, `.claude/settings.local.json`, and `opencode.json`. Rotating it means updating **all** of them consistently — miss one and that client silently 401s.
- The **same token was committed to two git-tracked docs** (`docs/upstream-bug-*.md`, `*.txt`) and pushed to GitHub. That token is compromised: it cannot be "fixed" by replacement — it must be rotated at the source and scrubbed from history. The scanner flags git-tracked secrets specifically.
- Watch for *internally inconsistent* configs: `.vscode/mcp.json` had an `env.HTTP_BEARER_TOKEN` that didn't match its own `Authorization` header.

## 4. Fixing callers without fixing the callee
25 SKILL.md files call `bin/ensure-cdp-9222` by absolute path — but the **profile dir lives inside that script** (`--user-data-dir=~/.chrome-automation`). Rewrite all 25 callers and Chrome still launches against a nonexistent profile until the script itself is fixed. Always trace the path to where it's actually consumed.

## 5. Coupled tests
`crates/daemon/tests/skill_lint.rs` asserts a SKILL.md *contains a literal path*. The path and its assertion are a pair: rewrite one without the other and the test breaks. These look independent (one's a test, one's a doc) but are joined at the hip.

## 6. Don't haul gigabytes of regenerable state
`state/` held **3.6 GB** of SQLite snapshots + timestamped backups, all gitignored and all rebuildable. `.beads/*.db*` rebuilds from the tracked `issues.jsonl`. Copying these wastes time/space and risks importing a corrupt/locked DB. Transfer the *source of truth* (`issues.jsonl`, migrations), regenerate the DB.

## 7. Self-contained fixtures are not breakages
`/Users/old/private/tender-response.pdf` looks like a machine path but is a fake input defined and asserted *within the same redaction test* — it never touches the filesystem and is identical on every machine. Rewriting it is needless churn. Distinguish "path the code uses" from "string the test inspects."

## 8. OS-standard ≠ machine-specific
`/Applications/Google Chrome.app/...`, `/opt/homebrew`, loopback `127.0.0.1:<port>` are the same on every Mac. Leave them. Only flag absolute paths that encode *this user's home or this project's location*.

## 9. Global ≠ project
The hardest-to-see breakages live *outside the repo*: the launchd plist, `~/.config/mcp-agent-mail/config.env`, the `~/.claude` ↔ `~/.codex` ↔ `~/.agents/skills` parity, the project memory dir under `~/.claude/projects/<encoded>/`. `git clone` brings none of this. A project that "transfers" but whose global environment is absent will fail at runtime in ways that look like project bugs.

## 10. gitignored secrets won't travel — and that's intentional
`.env`, `*.mcp.json`, `.codex/`, `.claude/settings.local.json` are gitignored, so `git clone` gives you a repo with no working config. The transfer must consciously move these (with fresh secrets), or the new clone is inert. Conversely, anything secret that is *not* gitignored is a leak to flag.
