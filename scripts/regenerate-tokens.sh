#!/usr/bin/env bash
# regenerate-tokens.sh — generate a fresh agent-mail bearer token and propagate
# it consistently to every project config file that carries one. Secrets are
# REGENERATED, never copied from the source machine.
#
# Usage:
#   regenerate-tokens.sh <project-root> [--apply]
#     (default is dry-run: shows which files/keys would change)
#
# It updates, in place (with .bak), the bearer token in the standard MCP config
# files and .env. It does NOT touch git-tracked files — if a token lives in a
# tracked file that's a LEAK; the script reports it and refuses to "fix" it,
# because the old value is already on the remote and must be rotated upstream.
set -uo pipefail

PROJECT="${1:?usage: regenerate-tokens.sh <project-root> [--apply]}"
PROJECT="${PROJECT%/}"
APPLY=0; [ "${2:-}" = "--apply" ] && APPLY=1
[ -d "$PROJECT" ] || { echo "ERROR: not a directory: $PROJECT" >&2; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "ERROR: openssl required" >&2; exit 1; }

NEW_TOKEN="$(openssl rand -hex 32)"

# Files that conventionally carry the agent-mail bearer token / HTTP token.
CONFIGS=(.env .codex/config.toml .claude/settings.local.json .vscode/mcp.json \
         opencode.json codex.mcp.json cursor.mcp.json cline.mcp.json \
         gemini.mcp.json factory.mcp.json windsurf.mcp.json)

is_tracked() { [ "$HAS_GIT" -eq 1 ] && git -C "$PROJECT" ls-files --error-unmatch "$1" >/dev/null 2>&1; }
HAS_GIT=0; git -C "$PROJECT" rev-parse >/dev/null 2>&1 && HAS_GIT=1
TOKEN_RE='(Bearer [A-Za-z0-9._-]{16,}|HTTP_BEARER_TOKEN[[:space:]]*[=:]|AGENT_MAIL_BEARER_TOKEN[[:space:]]*[=:])'

echo "New bearer token generated (kept in memory; shown once below if --apply)."
echo "All agent-mail tokens found will be unified to this single fresh value"
echo "(server token must equal client token; this also repairs any drift)."
[ "$APPLY" -eq 1 ] && echo "  NEW_TOKEN=$NEW_TOKEN"
echo "Scanning ${#CONFIGS[@]} candidate config files in: $PROJECT"
echo

declare -A OLDVALS         # old token values, to hunt for lingering leaks afterwards
skip_tracked=0; touched=0
for rel in "${CONFIGS[@]}"; do
  f="$PROJECT/$rel"
  [ -f "$f" ] || continue
  grep -qE "$TOKEN_RE" "$f" || continue
  # Capture the existing token value(s) before any edit (for leak-hunting below).
  while IFS= read -r v; do [ -n "$v" ] && OLDVALS["$v"]=1; done < <(
    { grep -oE 'Bearer [A-Za-z0-9._-]{20,}' "$f" 2>/dev/null | awk '{print $2}';
      grep -oE '[A-Za-z0-9]{32,}' "$f" 2>/dev/null; } )
  # We never auto-edit a git-tracked file: its old value is already on the remote.
  if is_tracked "$rel"; then
    echo "SKIP (git-tracked — won't auto-edit): $rel — rotate at source + scrub history"
    skip_tracked=$((skip_tracked+1)); continue
  fi
  if [ "$APPLY" -eq 1 ]; then
    cp "$f" "$f.bak"
    # NEW_TOKEN is pure hex (openssl rand -hex) so it is sed-replacement-safe.
    sed -i.tmp -E \
      -e "s#(Bearer )[A-Za-z0-9._-]{16,}#\1${NEW_TOKEN}#g" \
      -e "s#((HTTP_BEARER_TOKEN|AGENT_MAIL_BEARER_TOKEN)[[:space:]]*[=:][[:space:]]*\"?)[A-Za-z0-9._-]{16,}#\1${NEW_TOKEN}#g" \
      "$f" && rm -f "$f.tmp"
    echo "ROTATED: $rel  (backup: $rel.bak)"
  else
    echo "WOULD ROTATE: $rel"
    grep -nE "$TOKEN_RE" "$f" | sed 's/^/    /'
  fi
  touched=$((touched+1))
done

echo
echo "config files with tokens: $((touched+skip_tracked))   would-rotate: $touched   git-tracked (skipped): $skip_tracked"

# Authoritative leak check: does any OLD token value still live in a git-tracked
# file (e.g. a doc)? Those are the real leaks — rotation alone does not fix them.
if [ "$HAS_GIT" -eq 1 ] && [ ${#OLDVALS[@]} -gt 0 ]; then
  echo
  echo "Leaked-value check (old token still committed to git?):"
  found_leak=0
  for v in "${!OLDVALS[@]}"; do
    case "$v" in *example*|*REPLACE*|*YOUR_*|'<<'*) continue;; esac
    while IFS= read -r hit; do
      [ -z "$hit" ] && continue; hit="${hit#./}"
      if is_tracked "$hit"; then echo "  LEAK: ${v:0:10}… committed in $hit — scrub history + rotate upstream"; found_leak=1; fi
    done < <(if command -v rg >/dev/null 2>&1; then rg -lI --no-ignore --hidden --glob '!.git' --glob '!node_modules' -F "$v" "$PROJECT" 2>/dev/null; else grep -rlI --exclude-dir=.git --exclude-dir=node_modules -F "$v" "$PROJECT" 2>/dev/null; fi)
  done
  [ "$found_leak" -eq 0 ] && echo "  none — no old token value found in any git-tracked file"
fi
echo
echo "IMPORTANT — this only covers the PROJECT. Also rotate the SAME token in the"
echo "global agent-mail service config and propagate the new value there:"
echo "  - ~/Library/LaunchAgents/com.agent-mail.plist  (HTTP_BEARER_TOKEN env)"
echo "  - ~/.config/mcp-agent-mail/config.env          (AGENT_MAIL_BEARER_TOKEN)"
echo "  - ~/.codex/config.toml / ~/.claude.json mcp server headers (if global)"
echo "Then 'launchctl unload/load' the plist so the server uses the new token."
[ "$APPLY" -eq 0 ] && echo && echo "Dry-run only. Re-run with --apply to write changes."
