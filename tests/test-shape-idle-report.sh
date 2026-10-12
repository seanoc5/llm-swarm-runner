#!/usr/bin/env bash
#
# test-shape-idle-report.sh — shape tests for scripts/swarm-idle-report.sh.
#
# Two fake swarms with hand-written events.log timelines (whole hours, so
# the expected bucket totals are exact), a frozen "now" and a stub running-
# container list. Checks the per-swarm working / waiting / held split, the
# machine-wide refusal snapshot, the coordinator 🔔 hours, --days clipping,
# and that a live container keeps an unreaped worker open until "now".
set -euo pipefail

green()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()     { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT="$SCRIPT_DIR/../scripts/swarm-idle-report.sh"
[ -x "$REPORT" ] || red "swarm-idle-report.sh not executable: $REPORT"

TEST_DIR=$(mktemp -d -t shape-idle-report-XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/alpha/.swarm" "$TEST_DIR/beta/.swarm"

# alpha, issue 1: works 01-03, waits on you 02-03 (✋ inside the task),
#   finished-held 03-06, reaped 06. Follow-up delivered 04-05 → working.
#   So: working 01-02 + 04-05 = 2h, waiting 02-03 = 1h, held 03-04 + 05-06 = 2h.
# alpha, issue 2: starts 05, finishes 07, container still running at
#   now=10 → held 07-10 = 3h, working 2h.
# alpha coordinator: 🔔 08-09 = 1h.
# beta, issue 7: starts 00, finishes 01, no reap and no container → ends
#   at its last event (01): working 1h, held 0h, one "no reap" note.
# Refusal at 05:30 (machine-wide): alpha#1 held (follow-up finished 05:00),
#   alpha#2 working, beta#7 already ended (spawn_stagger refusals ignored).
cat > "$TEST_DIR/alpha/.swarm/events.log" <<'EOF'
2026-10-01T00:00:00Z  watch.start     project=alpha
2026-10-01T01:00:00Z  worker.start    issue=1 task_id=t1 window=iss-1
2026-10-01T02:00:00Z  watch.flag      window=iss-1 flag=✋ reason=outbox_decision_needed
2026-10-01T03:00:00Z  watch.flag      window=iss-1 flag=none reason=outbox_drained_or_processed
2026-10-01T03:00:00Z  worker.finish   issue=1 outcome=ok path=x
2026-10-01T04:00:00Z  worker.deliver.ok issue=1 brief=b.md release=auto_deliver
2026-10-01T05:00:00Z  worker.finish   issue=1 outcome=ok path=y
2026-10-01T05:00:00Z  worker.start    issue=2 task_id=t2 window=iss-2
2026-10-01T05:30:00Z  cap.refused     issue=3 reason=host_max_workers total=12 max=12
2026-10-01T05:40:00Z  cap.refused     issue=3 reason=spawn_stagger since=5 min=60
2026-10-01T06:00:00Z  reap.window     issue=1 window=iss-1 branch=fix/issue-1 reasons=pr-gated,PR-merged
2026-10-01T07:00:00Z  worker.finish   issue=2 outcome=ok path=z
2026-10-01T08:00:00Z  watch.flag      window=coordinator flag=🔔 reason=pending_approval
2026-10-01T09:00:00Z  watch.flag      window=coordinator flag=none reason=approval_answered
EOF
cat > "$TEST_DIR/beta/.swarm/events.log" <<'EOF'
2026-10-01T00:00:00Z  watch.start     project=beta
2026-10-01T00:00:00Z  worker.start    issue=7 task_id=t7 window=iss-7
2026-10-01T01:00:00Z  worker.finish   issue=7 outcome=ok path=w
EOF

NOW=$(date -u -d 2026-10-01T10:00:00Z +%s)
run() { SWARM_IDLE_NOW="$NOW" SWARM_IDLE_RUNNING="swarm-llm-alpha-iss-2" "$REPORT" "$@"; }

out="$(run --days 0 "$TEST_DIR/alpha" "$TEST_DIR/beta")"
row() { grep -m1 -E "^  $1 " <<< "$out" | awk '{print $2, $3, $4, $5, $6}'; }

[ "$(row alpha)" = "4.0 1.0 5.0 10.0 60%" ] || red "alpha split: got '$(row alpha)'"$'\n'"$out"
green "alpha: working 4h, waiting-on-you 1h (✋ wins), held 5h incl. live container to now"
[ "$(row beta)" = "1.0 0.0 0.0 1.0 0%" ] || red "beta split: got '$(row beta)'"
green "beta: unreaped worker without a container ends at its last event"
grep -q "(1 worker(s) had no reap event" <<< "$out" || red "missing no-reap note"
green "no-reap note counts beta#7 only"

grep -q "Machine-wide cap refusals: 1$" <<< "$out" || red "refusal count (spawn_stagger must not count)"
grep -q "working 1.0, waiting-on-you 0.0, finished-held 1.0" <<< "$out" \
    || red "refusal snapshot wrong:"$'\n'"$out"
green "refusal snapshot: alpha#1 held, alpha#2 working, ended beta#7 not counted"

grep -qE "^  alpha +1.0 h$" <<< "$out" || red "coordinator 🔔 hours"
green "coordinator 🔔 hours"

# --days clipping: now = 2026-10-03T07:00, --days 2 → count from
# 2026-10-01T07:00. Only alpha#2's held stretch (still running) and the
# 08-09 🔔 fall inside: held 48h, nothing else.
NOW_LATE=$(date -u -d 2026-10-03T07:00:00Z +%s)
out="$(SWARM_IDLE_NOW="$NOW_LATE" SWARM_IDLE_RUNNING="swarm-llm-alpha-iss-2" "$REPORT" --days 2 "$TEST_DIR/alpha")"
[ "$(row alpha)" = "0.0 0.0 48.0 48.0 100%" ] || red "--days 2 clip: got '$(row alpha)'"$'\n'"$out"
green "--days clips each stretch to the window"

"$REPORT" --days x "$TEST_DIR/alpha" >/dev/null 2>&1 && red "--days x should fail"
green "--days rejects non-numbers"
