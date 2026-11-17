#!/usr/bin/env bash
# test-cminder-events.sh — issue #862: scripts/cminder-events.sh mirrors coord-inbox
# items and worker outcomes to corpusminder's swarm-events endpoint. curl is a stub
# on PATH that logs each call (no network). Covers:
#   - CMINDER_EVENTS=0 (default) or backend=file: zero calls, nothing written
#   - an inbox item posts once (a second sweep makes no call), event_key = file name
#   - a worker outcome JSON posts once, with its issue and PR
#   - a 500 spools the body, the next sweep retries it, then it never posts again
#   - secret-looking lines never reach the body or the spool
set -euo pipefail
green() { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()   { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
check() { [ "$2" = "$3" ] && green "$1" || red "$1 (expected [$2] got [$3])"; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EV="$ROOT/scripts/cminder-events.sh"
T="$(mktemp -d -t cminder-events-XXXXXX)"
trap 'rm -rf "$T"' EXIT
[ -n "${KEEP:-}" ] && trap - EXIT

mkdir -p "$T/sandbox" "$T/bin" "$T/home"
: > "$T/sandbox/.env.example"
export LLM_SWARM_DIR="$T/sandbox" HOME="$T/home"
unset NEEDS_YOU_BACKEND CMINDER_URL CMINDER_API_KEY CMINDER_FORUM_ID CMINDER_EVENTS WORKSPACE COORD_INBOX_DIR

# curl stub: logs "<args>" then the body file's JSON on the next line; STATUS_FILE
# holds "ok" or "fail" so a test can flip the endpoint between sweeps.
cat > "$T/bin/curl" <<'STUB'
#!/usr/bin/env bash
body=""; prev=""
for a in "$@"; do [ "$prev" = "--data-binary" ] && body="${a#@}"; prev="$a"; done
printf '%s\n' "$*" >> "$CALLS"
[ -n "$body" ] && cat "$body" >> "$BODIES" && echo >> "$BODIES"
case "$(cat "$STATUS_FILE")" in
    fail) printf 500 ;;
    reject) printf 422 ;;
    *) printf 200 ;;
esac
exit 0
STUB
chmod +x "$T/bin/curl"
export PATH="$T/bin:$PATH" CALLS="$T/calls.log" BODIES="$T/bodies.log" STATUS_FILE="$T/status"
echo ok > "$STATUS_FILE"
calls() { [ -f "$CALLS" ] && wc -l < "$CALLS" | tr -d ' ' || echo 0; }

# A real repo with one registered worker worktree, plus a sibling swarm's worktree
# in the same parent folder that is NOT ours and must never be mirrored.
P="$T/ws/proj"; mkdir -p "$P"
git -C "$P" init -q -b main && git -C "$P" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$P" worktree add -q "$T/ws/wt-issue-7" -b iss-7
mkdir -p "$P/.swarm/coord-inbox" "$T/ws/wt-issue-7/.swarm/tasks/done"
mkdir -p "$T/ws/other/.swarm" "$T/ws/wt-issue-8/.swarm/tasks/done"
git -C "$T/ws/other" init -q -b main && git -C "$T/ws/other" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$T/ws/other" worktree add -q "$T/ws/wt-issue-8" -b iss-8 2>/dev/null || true
printf '{"task_id":"foreign-8","pr":999,"issue":8}\n' > "$T/ws/wt-issue-8/.swarm/tasks/done/foreign-8.ok.json"
printf 'Idle capacity: 2 slots open for project proj.\nIssue #123 waits on PR #456.\napi_key = hunter2hunter2\nnotes: ghp_abcdefghijklmnopqrstuvwxyz0123456789\nlast line\n' \
    > "$P/.swarm/coord-inbox/20261117T010000Z-idle_capacity-111-222.md"
printf '{"task_id":"20261117-000000-7","state":"ready-for-review","pr":555,"issue":7,"note":"opened PR","token":"abc123"}\n' \
    > "$T/ws/wt-issue-7/.swarm/tasks/done/20261117-000000-7.ok.json"

# ── default: off ─────────────────────────────────────────────────────────────
"$EV" sweep --project "$P"
check "CMINDER_EVENTS unset: zero calls" "0" "$(calls)"
check "CMINDER_EVENTS unset: no spool created" "no" "$([ -d "$P/.swarm/cminder-events-spool" ] && echo yes || echo no)"
export NEEDS_YOU_BACKEND=corpusminder CMINDER_URL=http://cm.test CMINDER_API_KEY=test-api-key-0001 CMINDER_FORUM_ID=9
CMINDER_EVENTS=0 "$EV" sweep --project "$P"
check "CMINDER_EVENTS=0: zero calls" "0" "$(calls)"
NEEDS_YOU_BACKEND=file CMINDER_EVENTS=1 "$EV" sweep --project "$P"
check "backend=file with CMINDER_EVENTS=1: zero calls" "0" "$(calls)"

# ── on: each item posts once ─────────────────────────────────────────────────
export CMINDER_EVENTS=1
"$EV" sweep --project "$P"
check "inbox item + outcome: two posts" "2" "$(calls)"
grep -q 'http://cm.test/api/v1/forums/9/swarm-events' "$CALLS" && green "posts to the forum's swarm-events URL" || red "wrong URL"
check "inbox event_key is the file name" "1" "$(jq -s '[.[]|select(.event_key=="20261117T010000Z-idle_capacity-111-222.md")]|length' "$BODIES")"
check "inbox kind and refs parsed" "idle_capacity 123 456" "$(jq -sr '.[]|select(.kind=="idle_capacity")|"\(.kind) \(.payload.issue) \(.payload.pr)"' "$BODIES")"
check "outcome event_key and refs" "outcome:20261117-000000-7.ok.json outcome_ok 7 555" \
    "$(jq -sr '.[]|select(.kind=="outcome_ok")|"\(.event_key) \(.kind) \(.payload.issue) \(.payload.pr)"' "$BODIES")"
check "secret lines are dropped from the body" "0" "$(grep -cE 'hunter2|ghp_' "$BODIES" || true)"
check "a secret-named outcome field is redacted" "[redacted]" "$(jq -sr '.[]|select(.kind=="outcome_ok")|.payload.text|fromjson|.token' "$BODIES")"
check "ordinary lines are kept" "1" "$(grep -c 'Idle capacity: 2 slots' "$BODIES")"
check "spool is empty after success" "0" "$(find "$P/.swarm/cminder-events-spool" -name '*.json' | wc -l | tr -d ' ')"
"$EV" sweep --project "$P"
check "a second sweep posts nothing" "2" "$(calls)"
check "a sibling swarm's outcome is never posted" "0" "$(grep -c 'foreign-8' "$BODIES" || true)"

# ── outage: spool, then retry ────────────────────────────────────────────────
printf 'Worker 9 failed.\n' > "$P/.swarm/coord-inbox/20261117T020000Z-fyi-333-444.md"
echo fail > "$STATUS_FILE"
"$EV" sweep --project "$P" 2>/dev/null
check "a 500 is attempted once" "3" "$(calls)"
check "the failed event stays spooled" "1" "$(find "$P/.swarm/cminder-events-spool" -name '*.json' | wc -l | tr -d ' ')"
"$EV" sweep --project "$P" 2>/dev/null
check "the next sweep retries it (still failing)" "4" "$(calls)"
echo ok > "$STATUS_FILE"
"$EV" sweep --project "$P"
check "once the endpoint is back the spooled event posts" "5" "$(calls)"
check "spool drained" "0" "$(find "$P/.swarm/cminder-events-spool" -name '*.json' | wc -l | tr -d ' ')"
"$EV" sweep --project "$P"
check "and never posts again" "5" "$(calls)"

# ── a permanent 4xx must not block the queue ─────────────────────────────────
printf 'Bad item.\n' > "$P/.swarm/coord-inbox/20261117T030000Z-fyi-555-666.md"
echo reject > "$STATUS_FILE"
"$EV" sweep --project "$P"
check "a 422 is attempted once" "6" "$(calls)"
check "a 422 moves the body to the rejected folder" "1" "$(find "$P/.swarm/cminder-events-rejected" -name '*.json' | wc -l | tr -d ' ')"
check "a 422 leaves nothing spooled" "0" "$(find "$P/.swarm/cminder-events-spool" -name '*.json' | wc -l | tr -d ' ')"
check "the failure is logged" "1" "$(grep -c 'rejected with 422' "$P/.swarm/cminder-events.log")"
echo ok > "$STATUS_FILE"
"$EV" sweep --project "$P"
check "a rejected item is not retried" "6" "$(calls)"
