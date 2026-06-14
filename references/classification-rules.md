# Classification Rules

Every machine-specific reference is sorted into exactly one of five buckets. Bucketing by **file role**, not by string content, is what makes this safe — the same literal `/Users/oldname/...` is MUST-REWRITE in a SKILL.md and HISTORICAL in a session log.

## Decision procedure

For each hit on a machine-specific token (source home path, dash-encoded home, secret, etc.), ask in order:

1. **Is the file a historical record?** (lives under `docs/session-log-*`, `docs/handoff-*`, `docs/pipeline/**`, `docs/testing/**`, `docs/planmaxer/**`, `docs/research/**`, `prompts/**`, `thoughts/**`, or is a dated transcript) → **HISTORICAL**. Stop.
2. **Is the value a secret or machine-local runtime state?** (bearer token, API key, JWT, `*.db`, `*.sqlite`, `daemon.info.json`, `*.sock`, `*.lock`, PID) → **REGENERATE**. Stop.
3. **Is the path standard on any machine of this OS?** (`/Applications/*.app`, `/opt/homebrew`, loopback `127.0.0.1:<port>`, tool-version pin like `bun@1.3.10`) → **SAFE**. Stop.
4. **Is the value only ever defined and checked within the same self-contained test?** (a redaction fixture that never touches the real filesystem) → **SAFE**. Stop.
5. **Does another file assert this file contains the literal path?** → **COUPLED** (with that other file). Rewrite both together.
6. Otherwise, it is a functional path that executes or is copy-pasted → **MUST-REWRITE**.

## MUST-REWRITE — functional, breaks or misleads on the new machine

| Pattern | Where seen (Testproject1 examples) | Note |
|---|---|---|
| Absolute path to a project helper script | `skills/**/SKILL.md` calling `/Users/old/Desktop/Proj/bin/ensure-cdp-9222` (25 files) | Comment in the skills themselves says it *must* be absolute (subprocess cwd ≠ project root). Genuinely load-bearing. |
| `--user-data-dir` / profile path inside a helper script | `bin/ensure-cdp-9222` → `~/.chrome-automation` | Fixing the SKILL.md callers is not enough; the script itself must be fixed or Chrome launches against a missing profile. |
| Hardcoded absolute fallback in source | `crates/daemon/src/main.rs` `PathBuf::from("/Users/old/.../bin/ensure-cdp-9222")` | Often guarded behind an env var / manifest-relative lookup, but the literal fallback is still wrong on a new home. |
| Absolute paths embedded in tracked data | `.beads/issues.jsonl` bead descriptions (git-tracked) | Travels with `git clone`; stale links inside canonical data. |
| `core.hookspath` in `.git/config` | absolute `/Users/old/Desktop/Proj/.git/hooks` | Breaks hooks if cloned to a different location. Prefer a relative value. |
| Copy-pasteable commands in carried docs | `AGENTS.md` (`repoPath:`, manual `--user-data-dir=` launch) | Not auto-executed, but agents/operators paste them. Carried doc, not a historical log. |
| Local permission/allowlist entries | `.claude/settings.local.json` Bash allowlist (`~/.local/bin/br`, `~/.claude/skills/...`) | Non-fatal (stale → extra prompts) but rewrite for hygiene. |

## COUPLED — rewrite together or neither

A test that asserts another file's *text* contains a literal path. Example: `crates/daemon/tests/skill_lint.rs` asserts `skills/bid-portal-procontract/SKILL.md` contains `/Users/old/.chrome-automation`. Rewrite the SKILL.md without the test → the test fails; rewrite the test without the SKILL.md → also fails.

The scanner does **not** auto-confirm the pairing — it routes every test-file hit to `coupled.txt` (separate from `must-rewrite.txt`) and leaves the COUPLED-vs-self-contained-fixture judgment to you (§4 of the scan output). The safe default is to rewrite `coupled.txt` in the **same pass** as `must-rewrite.txt`: genuine couples stay in sync, and self-contained fixtures only get harmless churn (they define and assert the same string). The one thing never to do is rewrite a file in `must-rewrite.txt` whose asserting test sits un-rewritten in `coupled.txt`.

## REGENERATE — never copy, create fresh

- **Secrets**: agent-mail bearer token(s), `MORPH_API_KEY`, `EXA_API_KEY`, Supabase keys/JWTs, anything matching `Bearer `, `eyJ`, `sk-`, `*_TOKEN`, `*_KEY`, `*_SECRET`. Generate with `openssl rand -hex 32` and propagate to **every** location that held the old value (often ~10 config files share one token). A secret found in a **git-tracked** file is compromised — flag for rotation + history scrub, do not just replace.
- **Machine-local state**: `state/*.db*` and timestamped backups (can be multi-GB), `runtime/daemon.info.json` (live PID + absolute stateRoot), `runtime/*.sock` / `*.lock`, `.beads/*.db*` (rebuilt from tracked `issues.jsonl`), `artifacts/downloads/**`, and the agents' `~/.claude/sessions`, `history.jsonl`, `cache/` (and Codex equivalents).

## HISTORICAL — leave untouched

Dated logs, handoffs, pipeline/testing evidence, prompts, transcripts. They contain real machine paths (including dash-encoded `-Users-old-Desktop-Proj` Claude-session paths) as a true record of what happened. Rewriting them falsifies evidence — e.g. an "observed launch command" that genuinely ran under the old path. **Default: do not touch.** Offer an *optional, separate, clearly-labeled* privacy scrub (replace the username) only if the user wants to strip personal identifiers; never fold it into the functional rewrite pass.

## Borderline — surface for human judgment, don't auto-decide

Some files are neither clearly functional nor clearly historical; the scanner puts them in the MUST-REWRITE candidate list so they get reviewed, but the agent should confirm with the user before rewriting:

- `featuremaxxer/active/**`, `docs/*maxxer/active/**` — pipeline kickoff/push **working prompts**. Often copy-pasted and re-run, so rewriting is usually right — but they may also be archived soon. Confirm.
- `docs/audit-*`, `docs/upstream-bug-*` — **evidence** docs. Treat like HISTORICAL (leave) unless the path is in a command meant to be re-run. Note: `docs/upstream-bug-*` is also where the leaked token lives — handle that via the secret-scrub path, independently of path rewriting.
- `progress.md` — carried status doc; the `Repo:` header is narrative, an embedded launch command is borderline. Usually fine to rewrite.

The rule of thumb: the scanner errs toward *surfacing* (candidate list), never toward *silently rewriting*. The reviewing agent prunes the manifest before `--apply`.

## SAFE — no action

- OS-standard absolute paths: `/Applications/Google Chrome.app/...`, `/Applications/LibreOffice.app/...`, `/opt/homebrew/bin`.
- Loopback endpoints: `http://127.0.0.1:8765/mcp/`, `:9222`, `:5173` — identical on every machine.
- Self-contained test fixtures (defined + asserted in the same test, never hit the filesystem), e.g. a fake `/Users/old/private/x.pdf` used to test redaction.
- Tool-version pins (`bun@1.3.10`, `rustc 1.96.0-nightly`) and stable project identifiers (`.agent-mail.yaml` `project_uid`).
