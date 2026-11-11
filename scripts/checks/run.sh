#!/usr/bin/env bash
#
# checks/run.sh — run every deterministic check registered for a kind (#811,
# ADR 0007). Format and kinds: docs/checks.md.
#
# Usage: run.sh <kind> <file|->    kind: brief | pr-screen | reply | needs-you
#
# A check is an executable scripts/checks/<kind>/<name>.sh taking one file
# argument and printing JSON lines
#   {"check":"<id>","severity":"warn|error","line":N,"match":"…","message":"…"}
# (nothing printed = clean). Findings from all checks go to stdout.
# Exit 0 clean, 1 findings, 2 usage/IO error or a check that crashed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${1:-}" in -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; esac
KIND="${1:-}"; FILE="${2:-}"
[ -n "$KIND" ] && [ -n "$FILE" ] || { echo "Usage: $0 <kind> <file|->" >&2; exit 2; }
[ -d "$HERE/$KIND" ] || { echo "checks: unknown kind '$KIND' (have: $(cd "$HERE" && ls -d */ | tr -d / | paste -sd, -))" >&2; exit 2; }
command -v jq >/dev/null || { echo "checks: jq required" >&2; exit 2; }
if [ "$FILE" = "-" ]; then
    TMP="$(mktemp -t checks-stdin-XXXXXX)"; trap 'rm -f "$TMP"' EXIT
    cat > "$TMP"; FILE="$TMP"
fi
[ -r "$FILE" ] || { echo "checks: cannot read '$FILE'" >&2; exit 2; }

found=0; crashed=0
for c in "$HERE/$KIND"/*.sh; do
    [ -x "$c" ] || continue
    out="$("$c" "$FILE")"; ec=$?
    if [ "$ec" -ne 0 ]; then echo "checks: $(basename "$c") crashed (exit $ec)" >&2; crashed=1; fi
    [ -n "$out" ] && { printf '%s\n' "$out"; found=1; }
done
[ "$crashed" = 1 ] && exit 2
[ "$found" = 1 ] && exit 1
exit 0
