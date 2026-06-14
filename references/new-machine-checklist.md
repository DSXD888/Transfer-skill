# New-Machine Checklist

Per-project path rewrites are worthless if the target machine lacks the global toolchain, configs, MCP servers, and synchronized skills. This checklist is the superset distilled from `new-laptop-setup.md`, `new-laptop-setup-codex.md`, and the `maxer-skills-migration` kit. Assumes macOS / Apple Silicon. Adjust versions to current.

There are **three transfer surfaces**: (A) machine-global tooling, (B) global config + skill parity, (C) per-project gitignored state. A complete transfer touches all three.

## A. Machine-global tooling (install in order)

### Phase 0 — OS base
- [ ] Xcode CLT: `xcode-select --install`
- [ ] Homebrew + add shellenv to `~/.zprofile`
- [ ] `brew install bash gh ripgrep ast-grep jq gum sqlite typos-cli fd direnv` (+ optional `docker colima`). **`bash ≥ 4` is mandatory** — `ubs` hard-fails on macOS stock bash 3.2.
- [ ] PATH in `~/.zshrc`: `~/.local/bin`, `~/.cargo/bin`, `~/.bun/bin`, nvm node bin, `/opt/homebrew/bin`
- [ ] Git identity: `git config --global user.name`, `user.email` (a real address — not `name@Mac.fritz.box`); `gh auth login`

### Phase 1 — language runtimes
- [ ] Rust via rustup; nightly + `rustfmt` + `clippy` (`rustup toolchain install nightly --component rustfmt clippy`). Repo pins via `rust-toolchain.toml`.
- [ ] nvm + Node 20 (`nvm install 20 && nvm alias default 20`)
- [ ] npm globals: `@openai/codex agent-browser corepack` (+ optional `@googleworkspace/cli`)
- [ ] Bun: `curl -fsSL https://bun.sh/install | bash` (match `packageManager` pin in `package.json`)

### Phase 2 — apps + macOS permissions
- [ ] Claude Desktop (provides computer-use microVM), Codex app, Google Chrome (required for CDP), Warp/Cursor/etc. as used
- [ ] Grant **Screen Recording + Accessibility + Input Monitoring** to both Claude and Codex apps (before first computer-use call)
- [ ] Install `claude-in-chrome` extension

### Phase 3 — AI CLIs
- [ ] Claude Code: `curl -fsSL https://claude.ai/install.sh | bash`; `~/.claude/settings.json` → `{ "effortLevel": "xhigh", "skipDangerousModePermissionPrompt": true }`
- [ ] Codex: `npm install -g @openai/codex`; `codex login`; `~/.codex/config.toml` core overrides (`model`, `model_reasoning_effort = "xhigh"`, `model_context_window = 1000000`, `approval_policy = "never"`, `sandbox_mode = "danger-full-access"`). **Resolve the known discrepancy:** `tool_output_token_limit` is `25000` live vs `250000` in the workflow doc ("critical for big codebases") — pick one deliberately.

### Phase 4 — Dicklesworthstone toolchain (installs to `~/.local/bin`)
- [ ] `br` (beads), `bv` (beads viewer), `am` + `mcp-agent-mail`, `ubs` (bug scanner), `asupersync` (`cargo install --git`). Verify each with `--version`. Do not substitute `bd` for `br`.
- [ ] Agent Mail as always-on launchd service: `~/Library/LaunchAgents/com.agent-mail.plist` running `am serve-http --host 127.0.0.1 --port 8765 --no-tui`, `RunAtLoad=true`. **Regenerate the bearer token** (`openssl rand -hex 32`) — do not copy the source token.
- [ ] `export AGENT_MAIL_NAME="<agent-name>"` in `~/.zshrc` (or `AGENT_NAME`) — `install-bead-wrappers` fail-hards without it.

## B. Global config + skill parity

### MCP servers (in BOTH Claude and Codex)
- [ ] **exa** — Claude: `claude mcp add --transport http exa https://mcp.exa.ai/mcp` (no auth). Codex: key in URL `https://mcp.exa.ai/mcp?exaApiKey=<EXA_KEY>`.
- [ ] **morph-mcp** — `npx -y @morphllm/morphmcp --api-key <MORPH_KEY>`, `ENABLED_TOOLS=edit_file,warpgrep_codebase_search`.
- [ ] **agent-mail** — Claude: stdio `mcp-agent-mail`. Codex: HTTP `http://127.0.0.1:8765/mcp/` with `http_headers = { Authorization = "Bearer <NEW_TOKEN>" }`.
- [ ] Codex-only: `openaiDeveloperDocs`; `node_repl` (let the app recreate it). Claude-only `computer-use`/`claude-in-chrome` are app-injected (won't show in `claude mcp list`).

### Skill parity (Claude ↔ Codex ↔ shared store)
- [ ] **Bulk-tar is the only complete path.** `tar czf ~/claude-skills.tgz -C ~/.claude skills commands` and `tar czf ~/codex-skills.tgz -C ~/.codex skills` and `tar czf ~/agents-skills.tgz -C ~/.agents skills`, untar on target. Fresh-install loses ~100 skills silently.
- [ ] If using the `maxer-skills-migration` kit: install `~/.agents/skills` **first** (store-backed skills symlink into it), then `./apply.sh` (clones upstream maxer + idea-to-research, applies `maxer-local.patch`, installs into both CLIs, runs the sync), then `./sync-claude-codex.sh` whenever a skill/MCP changes.
- [ ] **Re-apply `maxer-local.patch` after any upstream skill refresh** — pulling upstream reintroduces the removed "Backend Validation Ladder."
- [ ] Copy custom global skills (`install-bead-wrappers`, `bd-to-br-migration`) into both CLIs; restore exec bits on their `assets/*`/`scripts/*`.

### Global config files / dirs to transfer
- [ ] Claude: `~/.claude/settings.json`, `~/.claude.json` (MCP env/secrets — regenerate tokens), `~/.claude/hooks/on-file-write.sh` (`chmod +x`; runs `ubs`), `~/.claude/commands/`, and the project memory dir `~/.claude/projects/<encoded-path>/memory/`.
- [ ] Codex: `~/.codex/config.toml`, `~/.codex/AGENTS.md`(+`.override.md`), `~/.codex/rules/`, `~/.codex/hooks.json`, `~/.codex/prompts/`, plugins. `~/.config/mcp-agent-mail/config.env` (exports `AGENT_MAIL_BEARER_TOKEN`, `AGENT_MAIL_PROJECT_KEY=<new-project-path>`, `AGENT_MAIL_NAME`).

## C. Per-project gitignored state (does NOT travel with `git clone`)

Transfer manually (with regenerated secrets) — these are gitignored:
- [ ] `.env`, all `*.mcp.json`, `opencode.json`, `.codex/config.toml`, `.claude/settings.local.json`, `.vscode/mcp.json` — all carry the agent-mail bearer token; **update to the new token in every one.**
- [ ] Supabase keys/JWTs; Chrome CDP profile `~/.chrome-automation` (or re-sign-in to portals); `.envrc` from `.envrc.example`.

Do **NOT** transfer (regenerate on target): `state/*.db*` + backups, `runtime/` (daemon PID/sock/lock/info), `.beads/*.db*`, `artifacts/downloads/**`, `target/`, `node_modules/`, build outputs, agent `sessions`/`history`/`cache`.

## Verification gate (run last)

- [ ] `for b in br bv am mcp-agent-mail ubs asupersync claude codex bun node npm cargo rustc gh rg ast-grep jq gum supabase; do command -v "$b" || echo "MISSING: $b"; done`
- [ ] `curl -s http://127.0.0.1:8765/healthz` → `"status":"alive"`; `am doctor check` clean
- [ ] CDP: `bin/ensure-cdp-9222` then `curl -s http://127.0.0.1:9222/json/version`
- [ ] Project gates: `cargo check --all-targets`, `cargo clippy --all-targets -- -D warnings`, `bun run lint`, `br ready`, `bv --robot-triage`, `ubs --ci`
- [ ] In both Claude and Codex: `/mcp`, `/skills` (and `/plugin` in Claude) show expected entries
- [ ] Agent Mail smoke test: register both agents, exchange a message, reserve/release a file
