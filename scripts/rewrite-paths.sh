#!/usr/bin/env bash
# rewrite-paths.sh — rewrite the OLD machine path prefix to the NEW one, ONLY
# in files the scan flagged as functional (MUST-REWRITE / confirmed COUPLED).
#
# It never touches the HISTORICAL bucket and never rewrites secrets. It operates
# on an explicit manifest of files, so the historical bucket cannot leak in.
#
# Usage:
#   rewrite-paths.sh --dry-run|--apply \
#     --old  <old-prefix> \
#     --new  <new-prefix> \
#     --manifest <file-list>   # file:line lines (scan output) OR plain file paths
#
# Example:
#   rewrite-paths.sh --apply \
#     --old /Users/alinaaitova/Desktop/Testproject1 \
#     --new /Users/bob/Desktop/Testproject1 \
#     --manifest ./.transfer-scan/must-rewrite.txt
#
# --apply writes a .bak beside each changed file. Re-runnable (idempotent once
# the old prefix no longer appears).
set -uo pipefail

MODE=""; OLD=""; NEW=""; MANIFEST=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) MODE="dry";;
    --apply)   MODE="apply";;
    --old)  OLD="$2"; shift;;
    --new)  NEW="$2"; shift;;
    --manifest) MANIFEST="$2"; shift;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
  shift
done
[ -n "$MODE" ] && [ -n "$OLD" ] && [ -n "$NEW" ] && [ -n "$MANIFEST" ] || {
  echo "usage: rewrite-paths.sh --dry-run|--apply --old <p> --new <p> --manifest <f>" >&2; exit 2; }
[ -f "$MANIFEST" ] || { echo "ERROR: manifest not found: $MANIFEST" >&2; exit 1; }
[ "$OLD" = "$NEW" ] && { echo "ERROR: --old and --new are identical" >&2; exit 1; }
# Guard against sed-hostile characters in the prefixes (filesystem paths never
# contain these; refuse rather than silently corrupt with the '#' delimiter).
case "$OLD$NEW" in *'#'*|*'&'*|*'\'*) echo "ERROR: --old/--new must not contain # & or \\" >&2; exit 1;; esac

# Collect unique file paths from the manifest (strip :line:content if present).
mapfile -t FILES < <(sed 's/:.*$//' "$MANIFEST" | sed 's#^\./##' | sort -u)

# Refuse to touch anything in the historical bucket, as a belt-and-braces guard.
historical() {
  case "$1" in
    docs/session-log-*|docs/handoff-*|docs/pipeline/*|docs/testing/*|\
    docs/planmaxer/*|docs/research/*|docs/strategy/*|prompts/*|thoughts/*|*.txt) return 0;;
    *) return 1;;
  esac
}

changed=0; skipped=0
for f in "${FILES[@]}"; do
  [ -z "$f" ] && continue
  if historical "$f"; then echo "SKIP (historical): $f"; skipped=$((skipped+1)); continue; fi
  [ -f "$f" ] || { echo "SKIP (missing): $f"; skipped=$((skipped+1)); continue; }
  n=$(grep -cF -- "$OLD" "$f" 2>/dev/null); n=${n:-0}
  [ "$n" -eq 0 ] && continue
  if [ "$MODE" = "dry" ]; then
    echo "WOULD REWRITE $n occurrence(s): $f"
    grep -nF "$OLD" "$f" | sed 's/^/    /'
  else
    cp "$f" "$f.bak"
    # '#' delimiter is safe: OLD/NEW were validated above to contain no # & \.
    sed -i.tmp "s#${OLD}#${NEW}#g" "$f" && rm -f "$f.tmp"
    echo "REWROTE $n occurrence(s): $f  (backup: $f.bak)"
  fi
  changed=$((changed+1))
done

echo
echo "files affected: $changed   skipped: $skipped   mode: $MODE"
if [ "$MODE" = "dry" ]; then
  echo "Re-run with --apply to write changes (.bak backups created)."
else
  echo "Backups written as *.bak. Remove them once verified: find . -name '*.bak' -newer ... "
  echo "REMINDER: handle COUPLED test files in the same pass, and fix the path INSIDE"
  echo "helper scripts (e.g. bin/ensure-cdp-9222 --user-data-dir), not just the callers."
fi
