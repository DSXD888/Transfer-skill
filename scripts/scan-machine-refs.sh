#!/usr/bin/env bash
# scan-machine-refs.sh — read-only scanner that classifies machine-specific
# references in a project into the five transfer buckets.
#
# Usage: scan-machine-refs.sh <project-root> [source-home]
#   <project-root>  path to the project to scan
#   [source-home]   the OLD machine's home dir (default: derived from project
#                   path if it looks like /Users/<name>/..., else $HOME)
#
# Output: a human-readable classified report to stdout, and machine-readable
# candidate manifests under <project-root>/.transfer-scan/ :
#   must-rewrite.txt  (file:line per functional hit)
#   coupled.txt       (test-file literal that also appears in a non-test file)
#   secrets.txt       (file:line per secret hit, GIT-TRACKED ones marked)
#   regenerate.txt    (machine-local state paths + sizes)
#
# This script NEVER modifies the project. Read-only.
set -uo pipefail

PROJECT="${1:?usage: scan-machine-refs.sh <project-root> [source-home]}"
PROJECT="${PROJECT%/}"
[ -d "$PROJECT" ] || { echo "ERROR: not a directory: $PROJECT" >&2; exit 1; }

# Derive source home from the project path when possible (handles "moved on the
# same machine" — $HOME may already be the new one).
SRC_HOME="${2:-}"
if [ -z "$SRC_HOME" ]; then
  if [[ "$PROJECT" =~ ^(/Users/[^/]+) ]] || [[ "$PROJECT" =~ ^(/home/[^/]+) ]]; then
    SRC_HOME="${BASH_REMATCH[1]}"
  else
    SRC_HOME="$HOME"
  fi
fi
SRC_USER="$(basename "$SRC_HOME")"
DASH_HOME="$(printf '%s' "$SRC_HOME" | tr '/' '-')"   # -Users-name

OUT="$PROJECT/.transfer-scan"
mkdir -p "$OUT"
: > "$OUT/must-rewrite.txt"; : > "$OUT/coupled.txt"
: > "$OUT/secrets.txt"; : > "$OUT/regenerate.txt"; : > "$OUT/historical.txt"

# Prefer ripgrep; fall back to grep -r. (Each call site picks rg vs grep inline.)
EXCLUDES=(--glob '!.git' --glob '!node_modules' --glob '!target' --glob '!.transfer-scan')
# grep fallback excludes
GEXCL=(--exclude-dir=.git --exclude-dir=node_modules --exclude-dir=target --exclude-dir=.transfer-scan)

# Is a given repo-relative path a historical record?
is_historical() {
  case "$1" in
    docs/session-log-*|docs/handoff-*|docs/pipeline/*|docs/testing/*|\
    docs/planmaxer/*|docs/research/*|docs/strategy/*|prompts/*|thoughts/*|*.txt) return 0 ;;
    *) return 1 ;;
  esac
}
is_test() { case "$1" in */tests/*|tests/*|*_test.*|*/test_*|test_*|*.test.*|*.spec.*) return 0 ;; *) return 1 ;; esac }

cd "$PROJECT" || exit 1

echo "==================================================================="
echo " PROJECT TRANSFER SCAN"
echo "   project   : $PROJECT"
echo "   src home  : $SRC_HOME   (user: $SRC_USER)"
echo "   dash-enc  : $DASH_HOME"
echo "==================================================================="

# ---- 1. Literal home-path references, bucketed by file role ----------------
echo
echo "## 1. Home-path references (\`$SRC_HOME\`)"
total=0; mr=0; hist=0; tst=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  f="${line%%:*}"; f="${f#./}"
  total=$((total+1))
  if is_historical "$f"; then
    echo "$line" >> "$OUT/historical.txt"; hist=$((hist+1))
  elif is_test "$f"; then
    echo "$line" >> "$OUT/coupled.txt"; tst=$((tst+1))   # test refs — triage in §4
  else
    echo "$line" >> "$OUT/must-rewrite.txt"; mr=$((mr+1))
  fi
done < <(if command -v rg >/dev/null 2>&1; then rg -nI --no-heading --with-filename "${EXCLUDES[@]}" -F "$SRC_HOME" .; else grep -rnHI "${GEXCL[@]}" -F "$SRC_HOME" .; fi)
echo "   total hits: $total  ->  MUST-REWRITE: $mr   test refs (triage): $tst   HISTORICAL: $hist"
echo "   (functional candidates written to .transfer-scan/must-rewrite.txt)"

# ---- 2. Dash-encoded home (session/memory paths) ---------------------------
echo
echo "## 2. Dash-encoded home paths (\`$DASH_HOME\`) — usually HISTORICAL"
de=$(if command -v rg >/dev/null 2>&1; then rg -nI --no-heading --with-filename "${EXCLUDES[@]}" -F "$DASH_HOME" . ; else grep -rnHI "${GEXCL[@]}" -F "$DASH_HOME" . ; fi | tee -a "$OUT/historical.txt" | wc -l | tr -d ' ')
echo "   $de hit(s). These encode the old user AND project location."
echo "   Live config hits (if any) are MUST-REWRITE; log hits are HISTORICAL — review:"
if command -v rg >/dev/null 2>&1; then rg -lI "${EXCLUDES[@]}" -F "$DASH_HOME" . 2>/dev/null | sed 's/^/     /'; else grep -rlI "${GEXCL[@]}" -F "$DASH_HOME" . 2>/dev/null | sed 's/^/     /'; fi

# ---- 3. Secrets, with git-tracked leak detection ---------------------------
echo
echo "## 3. Secrets / tokens (REGENERATE — never copy)"
# Keyword/format matches (note: bare TOKEN/KEY/SECRET, not just *_TOKEN).
SECRET_RE='(Bearer [A-Za-z0-9._-]{16,}|eyJ[A-Za-z0-9._-]{10,}|sk-[A-Za-z0-9]{16,}|[A-Z_]*(TOKEN|KEY|SECRET|PASSWORD)[[:space:]]*[=:])'
HAS_GIT=0; git -C "$PROJECT" rev-parse >/dev/null 2>&1 && HAS_GIT=1
git_tracked() { [ "$HAS_GIT" -eq 1 ] && git -C "$PROJECT" ls-files --error-unmatch "$1" >/dev/null 2>&1; }
# Keyword hits are a REVIEW list (env-var names in docs/tests are NOT secrets);
# the authoritative leak signal is the value cross-reference below.
while IFS= read -r line; do [ -z "$line" ] && continue; echo "review: $line" >> "$OUT/secrets.txt"; done < <(
  if command -v rg >/dev/null 2>&1; then rg -nI --no-heading --with-filename "${EXCLUDES[@]}" -e "$SECRET_RE" .;
  else grep -rnHEI "${GEXCL[@]}" "$SECRET_RE" .; fi)
nreview=$(grep -c '^review: ' "$OUT/secrets.txt" 2>/dev/null | head -1)

# Value cross-reference: pull concrete token VALUES out of standard config files,
# then hunt those literal values everywhere (catches URL-encoded / bare forms a
# keyword regex misses). Any git-tracked occurrence is a real leak.
declare -A VALSEEN
extract_vals() {
  local file="$1"
  [ -f "$file" ] || return 0
  # values after 'Bearer ', and 32+ hex/base64-ish run after TOKEN=/TOKEN":"
  grep -oE 'Bearer [A-Za-z0-9._-]{20,}' "$file" 2>/dev/null | awk '{print $2}'
  grep -oE '[A-Za-z0-9]{32,}' "$file" 2>/dev/null
}
for cf in .env .codex/config.toml .claude/settings.local.json .vscode/mcp.json opencode.json \
          codex.mcp.json cursor.mcp.json cline.mcp.json gemini.mcp.json factory.mcp.json windsurf.mcp.json; do
  while IFS= read -r v; do
    [ -z "$v" ] && continue
    case "$v" in *example*|*REPLACE*|*YOUR_*|*xxxx*|'<<'*) continue;; esac
    VALSEEN["$v"]=1
  done < <(extract_vals "$PROJECT/$cf")
done
echo "   Token VALUES found in config, cross-referenced across the whole tree:"
for v in "${!VALSEEN[@]}"; do
  short="${v:0:10}…"
  # where does this exact value appear? (--no-ignore --hidden so gitignored
  # config files are counted too, not just tracked ones)
  mapfile -t hits < <(if command -v rg >/dev/null 2>&1; then rg -lI --no-ignore --hidden "${EXCLUDES[@]}" -F "$v" . 2>/dev/null; else grep -rlI "${GEXCL[@]}" -F "$v" . 2>/dev/null; fi)
  n=${#hits[@]}
  leaks=()
  for h in "${hits[@]}"; do h="${h#./}"; git_tracked "$h" && leaks+=("$h"); done
  if [ ${#leaks[@]} -gt 0 ]; then
    echo "     $short  in $n file(s); ${#leaks[@]} GIT-TRACKED LEAK(S): ${leaks[*]}"
    for h in "${leaks[@]}"; do echo "LEAK $short  $h" >> "$OUT/secrets.txt"; done
  else
    echo "     $short  in $n file(s) (all gitignored — rotate, do not copy)"
  fi
done
nleak=$(grep -c '^LEAK ' "$OUT/secrets.txt" 2>/dev/null | head -1)
echo "   keyword review hits: ${nreview:-0} (env-var names etc. — triage manually)"
echo "   confirmed GIT-TRACKED LEAK lines: ${nleak:-0}  (real token values committed to git)"
echo "   -> full list in .transfer-scan/secrets.txt ; rotate every token, copy none"

# ---- 4. Test refs — triage (COUPLED vs self-contained fixture) -------------
echo
echo "## 4. Test-file refs — triage each (see .transfer-scan/coupled.txt)"
echo "   COUPLED  = test asserts another file's literal path (e.g. a SKILL.md). It is"
echo "              EXCLUDED from must-rewrite.txt, so you MUST rewrite it in the same"
echo "              pass as that file or the test breaks. Default-safe: rewrite coupled.txt"
echo "              alongside must-rewrite.txt (fixture churn is harmless)."
echo "   FIXTURE  = path defined AND asserted within the same test (e.g. a redaction"
echo "              fixture). Rewriting is harmless churn; leaving it is also fine."
if [ -s "$OUT/coupled.txt" ]; then
  awk -F: '{print $1}' "$OUT/coupled.txt" | sort -u | while read -r tf; do
    echo "     test: $tf"
  done
else
  echo "     none detected"
fi

# ---- 5. Machine-local state to regenerate (with sizes) ---------------------
echo
echo "## 5. Machine-local state (REGENERATE — do not transfer)"
for p in state runtime artifacts/downloads .beads; do
  if [ -e "$PROJECT/$p" ]; then
    sz=$(du -sh "$PROJECT/$p" 2>/dev/null | awk '{print $1}')
    echo "     $p  ($sz)" | tee -a "$OUT/regenerate.txt"
  fi
done
find "$PROJECT" -maxdepth 3 \( -name '*.db' -o -name '*.sqlite*' -o -name 'daemon.info.json' -o -name '*.sock' -o -name '*.lock' \) \
  -not -path '*/.git/*' -not -path '*/node_modules/*' 2>/dev/null | sed "s#^$PROJECT/##" | sed 's/^/     state-file: /' >> "$OUT/regenerate.txt"
echo "     (full list incl. db/sock/lock files in .transfer-scan/regenerate.txt)"

# ---- 6. Git identity + hookspath ------------------------------------------
echo
echo "## 6. Git identity / hookspath"
if git -C "$PROJECT" rev-parse >/dev/null 2>&1; then
  echo "     remote : $(git -C "$PROJECT" remote get-url origin 2>/dev/null || echo '(none)')"
  echo "     user   : $(git -C "$PROJECT" config user.name 2>/dev/null) <$(git -C "$PROJECT" config user.email 2>/dev/null)>"
  hp="$(git -C "$PROJECT" config --local core.hookspath 2>/dev/null || true)"
  if [ -n "$hp" ]; then
    case "$hp" in /*) echo "     hookspath: $hp   <<< ABSOLUTE — MUST-REWRITE (or make relative)";; *) echo "     hookspath: $hp (relative — ok)";; esac
  fi
  case "$(git -C "$PROJECT" config user.email 2>/dev/null)" in
    *@*.fritz.box|*@*.local|*@*.lan) echo "     <<< git email embeds a machine hostname — reset on target";;
  esac
else
  echo "     (not a git repo)"
fi

# ---- 7. Gitignored secret/config files that won't travel -------------------
echo
echo "## 7. Gitignored config that won't survive 'git clone' (transfer manually, fresh secrets)"
if git -C "$PROJECT" rev-parse >/dev/null 2>&1; then
  for cand in .env .envrc .codex/config.toml .claude/settings.local.json .vscode/mcp.json opencode.json \
              codex.mcp.json cursor.mcp.json cline.mcp.json gemini.mcp.json factory.mcp.json windsurf.mcp.json; do
    if [ -e "$PROJECT/$cand" ] && git -C "$PROJECT" check-ignore -q "$cand" 2>/dev/null; then
      echo "     gitignored: $cand"
    fi
  done
fi

# ---- 8. Symlinks with absolute targets ------------------------------------
echo
echo "## 8. Symlinks (absolute targets break on transfer)"
sl=$(find "$PROJECT" -maxdepth 4 -type l -not -path '*/.git/*' -not -path '*/node_modules/*' 2>/dev/null)
if [ -n "$sl" ]; then echo "$sl" | while read -r l; do echo "     $l -> $(readlink "$l")"; done; else echo "     none"; fi

echo
echo "==================================================================="
echo " Manifests written to: $OUT/"
echo "   Review must-rewrite.txt with the user, then run rewrite-paths.sh."
echo "   NEVER copy anything in secrets.txt — regenerate it."
echo "==================================================================="
