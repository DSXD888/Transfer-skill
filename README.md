# project-transfer skill

Move a coding project from one machine to another cleanly — without leaving behind broken absolute paths, stale machine identity, copied-forward secrets, or multi-gigabyte runtime state.

This is the portable, generalized form of the hand-written `new-laptop-setup.md` / `new-laptop-setup-codex.md` runbooks and the `maxer-skills-migration` kit: it does on *any* project what those did for one.

## The core idea

`/Users/<oldname>` is only **one** class of machine-specific reference, and a blind find-and-replace is wrong. The skill classifies every reference into five buckets and acts per bucket:

| Bucket | Action |
|---|---|
| **MUST-REWRITE** | Rewrite source→target path (skills, helper scripts, source fallbacks, `.beads/issues.jsonl`, git `core.hookspath`, carried docs) |
| **COUPLED** | Rewrite together or neither (a test asserting a file's literal path) |
| **REGENERATE** | Never copy — fresh on target (bearer tokens, API keys, daemon state, SQLite snapshots) |
| **HISTORICAL** | Leave untouched (session logs, handoffs, evidence) — rewriting them falsifies the record |
| **SAFE** | No action (`/Applications/*`, loopback ports, self-contained test fixtures) |

## Layout

```
SKILL.md                          # the skill: when to use + 7-step workflow
references/
  classification-rules.md         # the bucketing ruleset + worked examples
  new-machine-checklist.md        # exhaustive target-machine prereqs + verify gate
  gotchas.md                      # 10 traps a naive s/old/new/ falls into
scripts/
  scan-machine-refs.sh            # read-only scanner/classifier (run first)
  rewrite-paths.sh                # parameterized old→new rewrite, manifest-driven, --dry-run
  regenerate-tokens.sh            # fresh tokens + propagate; flags git-tracked leaks
```

## Quick start

```bash
# 1. Scan + classify (read-only). Writes manifests to <project>/.transfer-scan/
bash scripts/scan-machine-refs.sh /path/to/project

# 2. Review .transfer-scan/must-rewrite.txt WITH the user. Prune borderline files.

# 3. Preview the functional rewrite, then apply (creates .bak files)
bash scripts/rewrite-paths.sh --dry-run \
  --old /Users/old/Desktop/Proj --new /Users/new/Desktop/Proj \
  --manifest /path/to/project/.transfer-scan/must-rewrite.txt
bash scripts/rewrite-paths.sh --apply  ...same args...

# 4. Regenerate secrets (never copy). Dry-run first.
bash scripts/regenerate-tokens.sh /path/to/project          # preview
bash scripts/regenerate-tokens.sh /path/to/project --apply  # rotate + propagate
```

Then follow `references/new-machine-checklist.md` for the global toolchain, MCP servers, Claude↔Codex skill parity, and the verification gate.

## Validated against

The scanner/rewriter were developed and smoke-tested against a real multi-agent Rust+Bun+Tauri project (`Testproject1`). On that project the scan correctly separated **122** functional rewrite candidates and **5** coupled-test refs from **2440** historical references, and flagged a reused agent-mail bearer token committed to **2 git-tracked docs** (a real leak) that a keyword-only scan missed.

## Safety properties

- The scanner is **strictly read-only**.
- The rewriter is **manifest-driven** and additionally refuses the historical glob set, so logs can't be rewritten by accident; it writes `.bak` backups and is idempotent.
- The token script **never copies** a secret and **refuses to auto-edit git-tracked files** — a committed token is already on the remote and must be rotated upstream + scrubbed from history.
