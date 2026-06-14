---
name: project-transfer
description: Move a coding project from one machine to another cleanly. Finds and classifies machine-specific references (absolute home paths, dash-encoded session paths, secrets/tokens, machine-local state, git identity), rewrites only the functional ones to the new machine, regenerates secrets instead of copying them, lists what to regenerate vs transfer, and verifies the global toolchain/skill parity on the new machine. Idempotent and confirmation-gated. Triggers include `transfer this project`, `move project to new machine`, `migrate project to another laptop`, `fix machine-specific paths`, `port this repo to a new Mac`.
---

# Project Transfer

This skill moves a project from a **source machine** to a **target machine** without leaving behind broken absolute paths, stale machine identity, copied-forward secrets, or multi-gigabyte runtime state. It is the portable, generalized counterpart of the hand-written `new-laptop-setup.md` / `new-laptop-setup-codex.md` runbooks — it does on any project what those docs did for one.

The core insight: **`/Users/<oldname>` is only one of several classes of machine-specific reference, and a blind find-and-replace is wrong.** It would (a) falsify historical logs, (b) miss several real breakages that don't contain the username at all, and (c) copy compromised secrets forward. This skill classifies every reference into a bucket and acts per bucket.

## When to Use

- You are **moving an existing project to a new machine** (new laptop, new user account, cloned to a different path).
- You **cloned a repo** that was developed on someone else's machine and hit broken absolute paths.
- You want to **audit** a project for machine-specific assumptions before handing it off.
- A teammate's project "works on their machine" but not yours and you suspect baked-in paths/identity.

Do **NOT** use this to mass-rewrite documentation or git history. Historical logs are evidence of what happened on the source machine and must stay truthful (see the HISTORICAL bucket below).

## Prerequisites

- Read access to the source project tree (and, ideally, the source `$HOME` so global config/skills can be inventoried).
- On the target machine: the global toolchain set up per `references/new-machine-checklist.md` *before* per-project rewrites are verified.
- `git`, `rg` (ripgrep) or `grep`, and `bash` available. `openssl` for token regeneration.

## The Five Buckets

Every machine-specific reference is classified into exactly one bucket. The skill's whole job is correct bucketing, then bucket-appropriate action. Full ruleset and worked examples: `references/classification-rules.md`.

| Bucket | Action | Examples |
|---|---|---|
| **MUST-REWRITE** | Rewrite source→target path | Absolute paths in `**/SKILL.md`, helper scripts (`--user-data-dir`), hardcoded fallbacks in source, `.beads/issues.jsonl`, git `core.hookspath`, carried docs (`AGENTS.md`), local permission allowlists (`.claude/settings.local.json`) |
| **COUPLED** | Rewrite together or not at all | A test that asserts a SKILL.md contains a literal path (e.g. `skill_lint.rs` ↔ the SKILL.md it checks) |
| **REGENERATE** | Never copy — create fresh on target | Bearer tokens, API keys, JWTs, machine runtime state, daemon PID/socket files, SQLite snapshots |
| **HISTORICAL** | Leave untouched (optional separate scrub) | `session-log-*`, `handoff-*`, pipeline/testing/planmaxer docs, prompts, transcripts — including dash-encoded `-Users-old-...` session paths |
| **SAFE** | No action | Self-contained test fixtures, `/Applications/*` Mac-standard paths, loopback `127.0.0.1:<port>`, tool-version pins |

## Workflow

Run the steps in order. Each produces output the user should see before the next destructive step. **Never skip the scan, and never rewrite before the user confirms the candidate list.**

### Step 1 — Scan and classify (read-only)

Run the scanner against the project. It detects literal home paths, dash-encoded session paths, secrets (with duplicate + git-tracked-leak detection), regenerate-not-copy state, git identity/hookspath, and gitignored secret files that won't survive `git clone`.

```bash
bash "$SKILL_DIR/scripts/scan-machine-refs.sh" <project-root> [source-home]
```

It writes a classified report to stdout and a machine-readable candidate manifest to `<project-root>/.transfer-scan/`. Review the report **with the user**. Resolve anything ambiguous before touching files.

### Step 2 — Regenerate secrets (never copy)

For every REGENERATE secret the scan found, generate a fresh value on the target and propagate it consistently to **all** locations that held the old one (the scan reports duplicates). Use:

```bash
bash "$SKILL_DIR/scripts/regenerate-tokens.sh" <project-root>
```

**Flag — do not auto-fix — any secret the scan found in a git-tracked file.** A token committed to git is already on the remote and must be treated as compromised: tell the user to rotate it at the source and scrub it from history separately. (Per the chosen policy, this skill regenerates + flags; it does not rewrite git-tracked docs automatically.)

### Step 3 — Functional rewrite (MUST-REWRITE + COUPLED)

Rewrite the source path prefix to the target prefix, operating **only** on the candidate files the scan flagged as functional. The HISTORICAL bucket is excluded by default. Always dry-run first.

```bash
# preview
bash "$SKILL_DIR/scripts/rewrite-paths.sh" --dry-run \
  --old "/Users/oldname/Desktop/Proj" --new "/Users/newname/Desktop/Proj" \
  --manifest <project-root>/.transfer-scan/must-rewrite.txt
# apply (creates .bak files)
bash "$SKILL_DIR/scripts/rewrite-paths.sh" --apply ...same args...
```

**Honor COUPLED pairs — this is mandatory, not optional.** The scanner puts test-file
refs in `coupled.txt`, *separate* from `must-rewrite.txt`. If a test asserts that a
SKILL.md/source file contains a literal path, and you rewrite that file (it's in
`must-rewrite.txt`) without rewriting the test, **the test breaks.** So after reviewing
`coupled.txt` (§4 of the scan explains COUPLED vs self-contained fixture), rewrite it in
the **same pass**:

```bash
# combine both manifests, then one rewrite pass keeps coupled pairs in sync
cat <project-root>/.transfer-scan/must-rewrite.txt \
    <project-root>/.transfer-scan/coupled.txt > /tmp/rewrite-all.txt
bash "$SKILL_DIR/scripts/rewrite-paths.sh" --apply --old ... --new ... --manifest /tmp/rewrite-all.txt
```

Rewriting a self-contained fixture this way is harmless churn (the test defines and
checks the same string, so it stays internally consistent). The only unsafe move is
rewriting one half of a coupled pair — which combining the manifests prevents.

### Step 4 — State hygiene

Do **not** transfer machine-local state. Delete/ignore on the target (regenerated on first run): daemon `runtime/` (PID, `.sock`, `.lock`, `daemon.info.json`), large SQLite snapshots (`state/*.db*` and timestamped backups), `.beads/*.db*` (rebuilt from the tracked `issues.jsonl`), cached `artifacts/downloads/**`, and the agents' own `sessions/` / `history.jsonl` / `cache/`. The scan reports sizes so you can show the user how much *not* to copy.

### Step 5 — Reset machine identity

- Git identity: `git config user.email` / `user.name` — reset if it embeds a stale hostname (e.g. `name@Mac.fritz.box`).
- `git config --local core.hookspath` — if absolute, repoint to the new location (or make it relative).
- Re-sign-in to portal sites in the CDP Chrome profile; re-auth Supabase / GitHub.

### Step 6 — Global environment + skill parity

Per-project rewrites are useless if the target machine lacks the toolchain. Walk `references/new-machine-checklist.md`: Homebrew packages, language runtimes, the Dicklesworthstone toolchain, the AI CLIs, MCP servers, and the **Claude ↔ Codex skill sync** (bulk-tar `~/.claude/skills`+`commands` and `~/.codex/skills`; this is the only complete path — fresh-install silently loses skills). If a `maxer-skills-migration`-style kit exists, its `apply.sh` + `sync-claude-codex.sh` are the reference implementation.

### Step 7 — Verify

Run the verification gate from the checklist: a `command -v` sweep over every expected binary; service health curls (agent-mail `:8765/healthz`, CDP `:9222/json/version`); project gates (`cargo check`, `cargo clippy -- -D warnings`, `bun run lint`, `br ready`, `ubs --ci` where applicable); and `/mcp` `/skills` parity checks in **both** Claude and Codex. Report pass/fail honestly — do not declare success on a skipped gate.

## Step 0 — Discover skill asset directory

```bash
SKILL_DIR="${PROJECT_TRANSFER_SKILL_DIR:-}"
if [ -z "$SKILL_DIR" ]; then
  for c in "$HOME/.claude/skills/project-transfer" "$HOME/.codex/skills/project-transfer"; do
    [ -d "$c/scripts" ] && SKILL_DIR="$c" && break
  done
fi
[ -z "$SKILL_DIR" ] && { echo "project-transfer: skill assets not found" >&2; exit 1; }
echo "Using skill assets from: $SKILL_DIR"
```

## References

- `references/classification-rules.md` — the full bucketing ruleset with concrete patterns and worked examples.
- `references/new-machine-checklist.md` — exhaustive target-machine prerequisites (tooling, configs, MCP servers, skill sync, verification gate).
- `references/gotchas.md` — everything a naive `s/oldname/newname/` misses, and why.
