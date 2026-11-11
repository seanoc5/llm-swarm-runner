#!/usr/bin/env bash
# test-checks.sh — #811: the deterministic checks component. Every fixture dir
# test-fixtures/checks/<id>/ (kind, fail.txt, pass.txt) must flag <id> on
# fail.txt and not flag it on pass.txt, through scripts/checks/run.sh, and
# every output line must be valid JSON in the documented shape.
set -euo pipefail
green() { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()   { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
check() { [ "$2" = "$3" ] && green "$1" || red "$1 (expected [$2] got [$3])"; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$ROOT/scripts/checks/run.sh"
FX="$ROOT/test-fixtures/checks"
SHAPE='type=="object" and (.check|type=="string") and (.severity=="warn" or .severity=="error") and (.line|type=="number") and (.match|type=="string") and (.message|type=="string")'

for d in "$FX"/*/; do
    id="$(basename "$d")"; kind="$(cat "$d/kind")"
    set +e; out="$("$RUN" "$kind" "$d/fail.txt")"; ec=$?; set -e
    check "$id: fail fixture exits 1" 1 "$ec"
    check "$id: fail fixture flags the check" yes "$(jq -r --arg id "$id" 'select(.check==$id)|"yes"' <<<"$out" | sort -u | head -1)"
    check "$id: every line has the documented shape" "" "$(jq -c "select($SHAPE|not)" <<<"$out")"
    set +e; out="$("$RUN" "$kind" "$d/pass.txt")"; ec=$?; set -e
    check "$id: pass fixture does not flag the check" "" "$(jq -r --arg id "$id" 'select(.check==$id)|.check' <<<"$out")"
done

# Acceptance (#811): the #801 contradictory-ending reply is flagged, the corrected one is clean.
set +e; "$RUN" reply "$FX/two-endings/fail.txt" >/dev/null; a=$?; "$RUN" reply "$FX/two-endings/pass.txt" >/dev/null; b=$?; set -e
check "reply: #801 fixture exit 1, corrected version exit 0" "1 0" "$a $b"
check "stdin works (-)" "1" "$("$RUN" reply - < "$FX/two-endings/fail.txt" >/dev/null; echo $?)"
check "line number points at the offending line" "2" "$("$RUN" reply "$FX/backref/fail.txt" | jq -r 'select(.check=="backref")|.line')"
set +e; "$RUN" nokind "$FX/backref/fail.txt" 2>/dev/null; a=$?; "$RUN" reply /nonexistent 2>/dev/null; b=$?; set -e
check "unknown kind and unreadable file exit 2" "2 2" "$a $b"
NY="$ROOT/test-fixtures/checks-needs-you"
set +e; "$RUN" needs-you "$NY/fail.txt" >/dev/null; a=$?; "$RUN" needs-you "$NY/pass.txt" >/dev/null; b=$?; set -e
check "needs-you kind applies the reply rules (two-endings fails, one ending passes)" "1 0" "$a $b"
echo "all checks tests passed"
