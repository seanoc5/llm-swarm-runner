#!/usr/bin/env bash
#
# test-shape-stale-wait-note.sh — Non-LLM shape test for issue #635's
# stale-wait handling in coordinator-watch.sh's ready_sweep_pass.
#
# ready-sweep.sh prints "#P stale-wait: waiting on #N, which merged at <ts>"
# for a draft whose **Next:** line still waits on an already-merged PR
# (fand-etl #1477 sat 16h that way). ready_sweep_pass must turn each P:N
# pair into exactly ONE coord-inbox note, stay silent when no stale-wait line
# is reported (an open trigger), and note again only after the pair has
# cleared and come back. The functions are extracted verbatim (sed) from
# coordinator-watch.sh; ready-sweep.sh is replaced by a fake via READY_SWEEP.
# shellcheck disable=SC2034  # globals are read by the extracted watcher functions
set -euo pipefail

green()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()     { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
heading() { printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCH="$SCRIPT_DIR/../scripts/coordinator-watch.sh"
[ -r "$WATCH" ] || red "coordinator-watch.sh not readable: $WATCH"

TEST_DIR=$(mktemp -d -t shape-stale-wait-XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT

extract_fn() { sed -n "/^${1}() {/,/^}/p" "$WATCH"; }

PROJECT_DIR="$TEST_DIR/proj"
mkdir -p "$PROJECT_DIR"
COORD_INBOX_DIR="$PROJECT_DIR/.swarm/coord-inbox"
COORD_INBOX_PROCESSED_DIR="$COORD_INBOX_DIR/processed"
COORD_INBOX_SELF_DIR="$COORD_INBOX_DIR/.self"
DRY_RUN=0
WATCH_STALE_WAIT_CHECK=1
SWEEP_OUT="$TEST_DIR/sweep-out.txt"
READY_SWEEP="$TEST_DIR/fake-ready-sweep.sh"
printf '#!/usr/bin/env bash\ncat "%s"\n' "$SWEEP_OUT" > "$READY_SWEEP"
chmod +x "$READY_SWEEP"
log_event() { :; }
RINGS="$TEST_DIR/rings.log"
: > "$RINGS"
coord_ring_doorbell() { printf '%s %s\n' "$1" "${2:-}" >> "$RINGS"; }
declare -A STALE_WAIT_NOTED=()
declare -A CI_FAILING_NOTED=()
declare -A CI_CANCELLED_NOTED=()
declare -A PARKED_GREEN_HANDLED=()
declare -A RETRY_FAILED_NOTED=()
BUSY_ISSUES=""; CLI_ISSUES=""
CLI_ISSUES=""   # issues whose window has a CLI in the foreground (else the window is absent)
CTX_ISSUES=""   # CLI windows that render the interactive ctx statusline (a headless -p run does not)
WORKSPACE="$TEST_DIR/ws"
mkdir -p "$WORKSPACE"
in_list() { [[ " $1 " == *" ${2#iss-} "* ]]; }
worker_pane_busy() { in_list "$BUSY_ISSUES" "$1"; }
worker_pane_state() { if in_list "$CLI_ISSUES" "$1"; then echo cli; else echo absent; fi; }
worker_pane_ctx_used() { in_list "$CTX_ISSUES" "$1" && echo 1000; }
own_wt_dir_for_issue() { [ -d "$WORKSPACE/wt-issue-$1" ] && echo "$WORKSPACE/wt-issue-$1"; }
# gh stub: only "pr view <N> --json comments --jq <filter>", answered from COMMENTS_<N> via the real jq filter
gh() { local v="COMMENTS_$3"; jq -r "$7" <<<"${!v:-{\"comments\":[]}}"; }
LLM_SWARM_DIR="$TEST_DIR/swarm"
mkdir -p "$LLM_SWARM_DIR/scripts"
printf '#!/usr/bin/env bash\necho "$1" >> "%s/ready.log"\nexit 0\n' "$TEST_DIR" > "$LLM_SWARM_DIR/scripts/pr-ready.sh"
chmod +x "$LLM_SWARM_DIR/scripts/pr-ready.sh"
CI_FAILING_RING_DIR="$PROJECT_DIR/.swarm/ci-failing-ring-pending"

# shellcheck source=/dev/null
. <(extract_fn coord_inbox_write; extract_fn ready_sweep_pass; extract_fn worker_brief_pending; extract_fn pr_comment_hold; sed -n "/^PR_COMMENT_HOLD_JQ=/,/(\.\[-1\] \/\/ \"\")'$/p" "$WATCH")
declare -F ready_sweep_pass >/dev/null || red "ready_sweep_pass not extracted"

notes() { find "$COORD_INBOX_DIR" -maxdepth 1 -name '*-stale_wait-*.md' 2>/dev/null | wc -l | tr -d ' '; }
MERGED='#21 stale-wait: waiting on #1461, which merged at 2026-10-15T06:52:00Z'

heading "Test 1: a merged-trigger line writes one coord-inbox note"
printf '#11 ci-pending: readied\n%s\n' "$MERGED" > "$SWEEP_OUT"
ready_sweep_pass >/dev/null
[ "$(notes)" = "1" ] || red "expected 1 note, got $(notes)"
grep -q "PR #21's \*\*Next:\*\* line is still waiting on #1461 to merge, but #1461 merged at 2026-10-15T06:52:00Z" "$COORD_INBOX_DIR"/*-stale_wait-*.md \
    || red "unexpected note text: $(cat "$COORD_INBOX_DIR"/*-stale_wait-*.md)"
green "note names the PR, the trigger and when it merged"

heading "Test 2: the same stale wait on the next sweep is deduped"
ready_sweep_pass >/dev/null
[ "$(notes)" = "1" ] || red "expected still 1 note, got $(notes)"
green "one note per PR:trigger pair"

heading "Test 3: no stale-wait line (trigger still open) writes nothing and clears the dedup"
printf '#22 ci-pending: still draft (exit 4)\n' > "$SWEEP_OUT"
ready_sweep_pass >/dev/null
[ "$(notes)" = "1" ] || red "expected no new note, got $(notes)"
[ "${#STALE_WAIT_NOTED[@]}" = "0" ] || red "expected dedup cleared, got: ${!STALE_WAIT_NOTED[*]}"
green "silent while the trigger is open"

heading "Test 4: a stale wait that comes back after clearing notes again"
printf '%s\n' "$MERGED" > "$SWEEP_OUT"
ready_sweep_pass >/dev/null
[ "$(notes)" = "2" ] || red "expected a second note, got $(notes)"
green "re-occurrence isn't permanently suppressed"

heading "Test 5 (issue #729): a parked draft going red writes one ci_failing note per head sha"
cf() { find "$COORD_INBOX_DIR" -maxdepth 1 -name '*-ci_failing-*.md' 2>/dev/null | wc -l | tr -d ' '; }
RED='#31 ci-failing: needs a fix push (sha=deadbeef)'
printf '%s\n' "$RED" > "$SWEEP_OUT"
ready_sweep_pass >/dev/null
[ "$(cf)" = "1" ] || red "expected 1 ci_failing note, got $(cf)"
grep -q "PR #31 has red CI on deadbee" "$COORD_INBOX_DIR"/*-ci_failing-*.md || red "unexpected note: $(cat "$COORD_INBOX_DIR"/*-ci_failing-*.md)"
ready_sweep_pass >/dev/null
[ "$(cf)" = "1" ] || red "same sha must dedupe, got $(cf)"
printf '#31 ci-failing: needs a fix push (sha=cafe1234)\n' > "$SWEEP_OUT"
ready_sweep_pass >/dev/null
[ "$(cf)" = "2" ] || red "new head sha must note again, got $(cf)"
green "one note per PR+sha"

heading "Test 6 (issue #729): ready_sweep_pass never rings itself; it queues one ring per new note"
[ ! -s "$RINGS" ] || red "ready_sweep_pass must not call coord_ring_doorbell (timer-loop process): $(cat "$RINGS")"
[ "$(ls "$CI_FAILING_RING_DIR" | wc -l | tr -d ' ')" = "2" ] || red "expected 2 queued rings, got: $(ls "$CI_FAILING_RING_DIR")"
[ -e "$CI_FAILING_RING_DIR/31-deadbeef" ] && [ -e "$CI_FAILING_RING_DIR/31-cafe1234" ] || red "queue lacks pr-sha files: $(ls "$CI_FAILING_RING_DIR")"
green "no direct ring; ring queued once per new note (deduped repeat adds nothing)"

heading "Test 7 (issue #757): parked-green drafts only ever get one note per PR+sha; pr-ready.sh is never run"
pg() { find "$COORD_INBOX_DIR" -maxdepth 1 -name '*-parked_green-*.md' 2>/dev/null | wc -l | tr -d ' '; }
: > "$TEST_DIR/ready.log"
cat > "$SWEEP_OUT" <<'OUT'
#71 parked-green: banner-less draft, green CI (risk=low, issue=71, sha=aaaa1111)
#72 parked-green: banner-less draft, green CI (risk=high, issue=72, sha=bbbb2222)
#73 parked-green: banner-less draft, green CI (risk=medium, issue=none, sha=cccc3333)
OUT
ready_sweep_pass >/dev/null
[ ! -s "$TEST_DIR/ready.log" ] || red "pr-ready.sh must never run for a parked-green draft: $(cat "$TEST_DIR/ready.log")"
[ "$(pg)" = "3" ] || red "expected 3 parked_green notes, got $(pg)"
grep -q "Draft PR #72 is green with no banner; its worker may have parked (risk high, head bbbb222)" "$COORD_INBOX_DIR"/*-parked_green-*.md || red "unexpected note: $(cat "$COORD_INBOX_DIR"/*-parked_green-*.md)"
ready_sweep_pass >/dev/null
[ "$(pg)" = "3" ] || red "same sha must dedupe, notes: $(pg)"
sed -i 's/sha=aaaa1111/sha=aaaa9999/' "$SWEEP_OUT"
ready_sweep_pass >/dev/null
[ "$(pg)" = "4" ] || red "new head sha should note again, notes: $(pg)"
green "one note per PR+sha, any risk, any issue; pr-ready.sh never called"

heading "Test 8 (issue #757): a comment-held parked-green draft gets no note until the hold lifts"
printf '#81 parked-green: banner-less draft, green CI (risk=low, issue=81, sha=aaaa0081)\n' > "$SWEEP_OUT"
before="$(pg)"
COMMENTS_81='{"comments":[{"body":"x\n<!-- SWARM_COORDINATOR_HOLD -->"}]}'
ready_sweep_pass >/dev/null
[ "$(pg)" = "$before" ] || red "comment-held draft must get no note"
COMMENTS_81='{"comments":[{"body":"<!-- SWARM_COORDINATOR_HOLD -->"},{"body":"<!-- SWARM_COORDINATOR_HOLD_LIFTED -->"}]}'
ready_sweep_pass >/dev/null
[ "$(pg)" = "$((before + 1))" ] || red "lifted hold should note on the next sweep"
COMMENTS_81='{"comments":[{"body":"quoting `<!-- SWARM_COORDINATOR_HOLD -->` in prose"}]}'
printf '#82 parked-green: banner-less draft, green CI (risk=low, issue=82, sha=aaaa0082)\n' > "$SWEEP_OUT"
COMMENTS_82="$COMMENTS_81"
ready_sweep_pass >/dev/null
[ "$(pg)" = "$((before + 2))" ] || red "prose quoting the marker is not a hold"
unset COMMENTS_81 COMMENTS_82
green "comment hold defers the note; lift or prose-only quote does not"

heading "Test 8b (issue #757): banner retry failing with exit 1 or 124 drops one note; other outcomes stay silent"
rf() { find "$COORD_INBOX_DIR" -maxdepth 1 -name '*-ready_retry_failed-*.md' 2>/dev/null | wc -l | tr -d ' '; }
cat > "$SWEEP_OUT" <<'OUT'
#91 ci-pending: still draft (exit 124)
#92 ci-unknown: still draft (exit 1)
#93 ci-pending: still draft (exit 4)
#94 ci-pending: readied
OUT
ready_sweep_pass >/dev/null
[ "$(rf)" = "2" ] || red "expected 2 ready_retry_failed notes (91 timeout, 92 exit 1), got $(rf)"
grep -q "timed out" "$COORD_INBOX_DIR"/*-ready_retry_failed-*.md || red "timeout note should say so"
ready_sweep_pass >/dev/null
[ "$(rf)" = "2" ] || red "same PR+exit must dedupe, got $(rf)"
green "exit 1 and 124 note once; exit 4 and readied stay silent"

heading "Test 10 (issue #817): a ci-cancelled line writes one ci_cancelled note per PR+sha"
cc() { find "$COORD_INBOX_DIR" -maxdepth 1 -name '*-ci_cancelled-*.md' 2>/dev/null | wc -l | tr -d ' '; }
CANC='#41 ci-cancelled: CI was cancelled, re-run it (`gh run rerun <run-id>`), not a fix push (sha=abcd1234)'
printf '%s\n' "$CANC" > "$SWEEP_OUT"
ready_sweep_pass >/dev/null
[ "$(cc)" = "1" ] || red "expected 1 ci_cancelled note, got $(cc)"
grep -q "PR #41 had its CI cancelled on abcd123" "$COORD_INBOX_DIR"/*-ci_cancelled-*.md || red "unexpected note: $(cat "$COORD_INBOX_DIR"/*-ci_cancelled-*.md)"
grep -q "gh run rerun" "$COORD_INBOX_DIR"/*-ci_cancelled-*.md || red "note lacks the re-run hint"
ready_sweep_pass >/dev/null
[ "$(cc)" = "1" ] || red "same sha must dedupe, got $(cc)"
printf '#41 ci-cancelled: CI was cancelled, re-run it (`gh run rerun <run-id>`), not a fix push (sha=ef015678)\n' > "$SWEEP_OUT"
ready_sweep_pass >/dev/null
[ "$(cc)" = "2" ] || red "new head sha must note again, got $(cc)"
green "one note per PR+sha"

heading "Test 9 (issue #757): the comment-hold jq matches pr-ready.sh's"
norm() { sed -n "/^$1=/,/(\.\[-1\] \/\/ \"\")'\$/p" "$2" | sed -E "s/^$1=//" | tr -s ' \n' ' '; }
[ -n "$(norm HOLD_COMMENT_JQ "$SCRIPT_DIR/../scripts/pr-ready.sh")" ] || red "could not read pr-ready.sh HOLD_COMMENT_JQ"
[ "$(norm HOLD_COMMENT_JQ "$SCRIPT_DIR/../scripts/pr-ready.sh")" = "$(norm PR_COMMENT_HOLD_JQ "$WATCH")" ] || red "PR_COMMENT_HOLD_JQ drifted from pr-ready.sh HOLD_COMMENT_JQ"
green "hold-comment filters identical"

green "ALL TESTS PASSED"
