#!/usr/bin/env bash
#
# test-shape-pr-status.sh — Non-LLM shape test for issue #536's
# pr_status_sweep_pass: posts a `swarm/worker` commit status per worker PR.
# Extracts the pass (and own_wt_dir_for_issue/is_own_worktree_dir) verbatim
# from coordinator-watch.sh, stubs `gh`, and stubs the pane helpers.
set -euo pipefail

green() { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()   { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COORD_WATCH="$SCRIPT_DIR/../scripts/coordinator-watch.sh"
T=$(mktemp -d -t shape-pr-status-XXXXXX)
trap 'rm -rf "$T"' EXIT

extract_fn() { sed -n "/^${1}() {/,/^}/p" "$COORD_WATCH"; }
for fn in is_own_worktree_dir own_wt_dir_for_issue pr_status_desc idle_park_marker_live pr_status_sweep_pass; do
    body="$(extract_fn "$fn")"
    [ -n "$body" ] || red "could not extract $fn"
    eval "$body"
done
declare -gA PR_STATUS_LAST=()
PR_STATUS_BACKOFF_UNTIL=0

# Fixture: own worktrees on branches fix/issue-N (PROJECT_DIR is not a git
# repo, so is_own_worktree_dir fails open).
WORKSPACE="$T/ws"; PROJECT_DIR="$T/proj"; mkdir -p "$WORKSPACE" "$PROJECT_DIR"
for n in 1 2 3 4 5 6; do
    git init -q -b "fix/issue-$n" "$WORKSPACE/wt-issue-$n"
done
EVENTS_LOG="$T/events.log"; : > "$EVENTS_LOG"
log_event() { printf '%s %s\n' "$1" "$2" >> "$EVENTS_LOG"; }
DRY_RUN=0; SWARM_PR_STATUS=1; WATCH_PR_STATUS_SWEEP_SECS=60
SESSION_NAME=s

# Stub pane helpers: windows listed in $T/windows; "busy" ones in $T/busy.
worker_pane_state() {
    if grep -qx "$1" "$T/shells"; then echo shell
    elif grep -qx "$1" "$T/windows"; then echo cli
    else echo absent; fi
}
worker_pane_busy() { grep -qx "$1" "$T/busy"; }

# The real comment-hold filter (issue #757), extracted verbatim.
eval "$(sed -n "/^PR_COMMENT_HOLD_JQ='/,/(\.\[-1\] \/\/ \"\")'\$/p" "$COORD_WATCH")"
[ -n "${PR_COMMENT_HOLD_JQ:-}" ] || red "could not extract PR_COMMENT_HOLD_JQ"

# gh stub: `pr list` prints $T/prs (already tsv), or, when $T/prs.json
# exists, runs the REAL --jq filter the sweep passes over that fixture;
# `api` logs args.
GH_API_RC=0
gh() {
    case "$1" in
        pr) if [ -f "$T/prs.json" ]; then
                local a prev="" expr=""
                for a in "$@"; do [ "$prev" = "--jq" ] && expr="$a"; prev="$a"; done
                jq -r "$expr" "$T/prs.json"
            else cat "$T/prs"; fi ;;
        api) shift; echo "$*" >> "$T/api.log"; [ -z "${GH_API_ERR:-}" ] || echo "$GH_API_ERR" >&2; return "$GH_API_RC" ;;
    esac
}

tab() { local IFS=$'\t'; printf '%s\n' "$*"; }
{ tab 1 fix/issue-1 sha1 true -
  tab 2 fix/issue-2 sha2 true -
  tab 3 fix/issue-3 sha3 true hold
  tab 4 fix/issue-4 sha4 true -
  tab 5 fix/issue-5 sha5 false -
  tab 6 fix/issue-6 sha6 true -
  tab 9 operator/own-branch sha9 true -
  tab 8 fix/issue-8 sha8 true -; } > "$T/prs"   # 8: no own worktree
printf 'iss-1\niss-2\niss-3\n' > "$T/windows"   # 4 has no window
printf 'iss-6\niss-7\n' > "$T/shells"   # 6: window exists, CLI gone (bare shell); 7: same but run_idle_shell's park
git init -q -b fix/issue-7 "$WORKSPACE/wt-issue-7"; mkdir -p "$WORKSPACE/wt-issue-7/.swarm/tasks"   # 7 is exercised in the fixture-driven phase below
printf 'iss-1\n' > "$T/busy"

pr_status_sweep_pass
api() { grep -c "$1" "$T/api.log" || true; }
has() { grep -q -- "$1" "$T/api.log" || red "missing: $1"; }
has 'statuses/sha1 -f state=pending .*description=working: iss-1, busy as of [0-9][0-9]:[0-9][0-9]'; green "busy -> pending working"
has 'statuses/sha2 -f state=pending .*description=idle: waiting on review/input'; green "idle -> pending idle"
has 'statuses/sha3 -f state=pending .*description=held by coordinator'; green "hold banner -> pending held"
has 'statuses/sha4 -f state=failure .*description=no worker attached'; green "no window -> failure"
has 'statuses/sha6 -f state=failure .*description=worker exited: no CLI in window'; green "bare shell (CLI exited) -> failure"
has 'statuses/sha5 -f state=success .*description=ready'; green "ready PR -> success"
has 'context=swarm/worker' ; green "context swarm/worker"
[ "$(wc -l < "$T/api.log")" = 6 ] || red "expected 6 posts (operator PR and foreign-issue PR skipped), got $(wc -l < "$T/api.log")"
green "operator's own and foreign PRs untouched"

pr_status_sweep_pass
[ "$(wc -l < "$T/api.log")" = 6 ] || red "unchanged second cycle made an API call"
grep -q 'reason=unchanged' "$EVENTS_LOG" || red "no unchanged skip event"
green "unchanged second cycle: no API call"

tab 1 fix/issue-1 sha1b true - > "$T/prs"
pr_status_sweep_pass
[ "$(wc -l < "$T/api.log")" = 7 ] || red "new SHA should repost"
green "new push (new SHA) reposts"

# Fail open: API error logs, backs off, does not abort.
GH_API_RC=1; GH_API_ERR="gh: API rate limit exceeded (HTTP 403)"; PR_STATUS_LAST=()
tab 2 fix/issue-2 sha2 true - > "$T/prs"
pr_status_sweep_pass || red "api error must not fail the pass"
grep -q 'reason=api_error' "$EVENTS_LOG" || red "no api_error event"
[ "$PR_STATUS_BACKOFF_UNTIL" -gt "$(date +%s)" ] || red "no backoff set"
green "auth/rate-limit api error fails open with backoff"

# A per-PR error (head moved: 422) skips only that PR; the sweep goes on.
GH_API_ERR="gh: Validation Failed (HTTP 422)"; PR_STATUS_LAST=(); PR_STATUS_BACKOFF_UNTIL=0; : > "$T/api.log"
{ tab 2 fix/issue-2 sha2 true -; tab 1 fix/issue-1 sha1 true -; } > "$T/prs"
pr_status_sweep_pass || red "per-PR error must not fail the pass"
[ "$PR_STATUS_BACKOFF_UNTIL" -le "$(date +%s)" ] || red "a per-PR 422 backed off the whole sweep"
[ "$(wc -l < "$T/api.log")" = 2 ] || red "PR after the failing one was not attempted"
GH_API_ERR=""
green "per-PR api error skips that PR only, no sweep backoff"

# Gate off.
GH_API_RC=0; PR_STATUS_BACKOFF_UNTIL=0; SWARM_PR_STATUS=0; n=$(wc -l < "$T/api.log")
pr_status_sweep_pass
[ "$(wc -l < "$T/api.log")" = "$n" ] || red "SWARM_PR_STATUS=0 still posted"
green "SWARM_PR_STATUS=0 disables"

# Description cap.
long="$(pr_status_desc "$(printf "x%.0s" $(seq 200))")"; [ "${#long}" -le 140 ] || red "desc over 140"
green "description clamped to 140 chars"

# --- Phase 2: real hold jq over fixture JSON, and park vs crash (issue #536) ---
SWARM_PR_STATUS=1; GH_API_RC=0; PR_STATUS_LAST=(); PR_STATUS_BACKOFF_UNTIL=0; : > "$T/api.log"
printf 'iss-1\niss-2\niss-3\niss-7\n' > "$T/windows"; printf 'iss-6\niss-7\n' > "$T/shells"; : > "$T/busy"
cat > "$T/prs.json" <<'JSON'
[
 {"number":1,"headRefName":"fix/issue-1","headRefOid":"sha1","isDraft":true,"body":"x","comments":[
   {"body":"held\n<!-- SWARM_COORDINATOR_HOLD -->"}]},
 {"number":2,"headRefName":"fix/issue-2","headRefOid":"sha2","isDraft":true,"body":"x","comments":[
   {"body":"held\n<!-- SWARM_COORDINATOR_HOLD -->"},{"body":"<!-- SWARM_COORDINATOR_HOLD_LIFTED -->"}]},
 {"number":3,"headRefName":"fix/issue-3","headRefOid":"sha3","isDraft":true,"body":"> ⛔ **COORDINATOR HOLD** banner","comments":[]},
 {"number":6,"headRefName":"fix/issue-6","headRefOid":"sha6","isDraft":true,"body":"x","comments":[
   {"body":"review quotes it <!-- SWARM_COORDINATOR_HOLD --> SWARM_SELF_REVIEW: x"}]},
 {"number":7,"headRefName":"fix/issue-7","headRefOid":"sha7","isDraft":true,"body":"x","comments":[]}
]
JSON
pr_status_sweep_pass
has 'statuses/sha1 -f state=pending .*description=held by coordinator'; green "SWARM_COORDINATOR_HOLD comment (no body banner) -> held"
has 'statuses/sha2 -f state=pending .*description=idle: waiting on review/input'; green "hold lifted by a later comment -> not held"
has 'statuses/sha3 -f state=pending .*description=held by coordinator'; green "body banner still holds"
has 'statuses/sha6 -f state=failure .*description=worker exited: no CLI in window'; green "bare shell, no idle-shell marker -> still a crash (failure)"
has 'statuses/sha7 -f state=failure .*description=worker exited: no CLI in window'; green "pane 7 before its marker exists -> failure"
M="$WORKSPACE/wt-issue-7/.swarm/tasks/.idle-parked"; PIDF="$WORKSPACE/wt-issue-7/.swarm/tasks/.idle-shell-pid"
# #925: the idle shell runs in the worker's container (own PID namespace), so the watcher must judge a park
# by the marker's heartbeat (mtime), never by a pid it cannot see. Pid files below are deliberately misleading.
date +%s > "$M"
PR_STATUS_LAST=(); : > "$T/api.log"
pr_status_sweep_pass
has 'statuses/sha7 -f state=pending .*description=parked: idle shell'; green "fresh heartbeat, no pid file -> parked"
printf '%s\n' "999999" > "$PIDF"   # a container pid: names nothing (or something unrelated) on the host
PR_STATUS_LAST=(); : > "$T/api.log"
pr_status_sweep_pass
has 'statuses/sha7 -f state=pending .*description=parked: idle shell, waiting for a brief'; green "fresh heartbeat + unresolvable pid -> parked (a pid check would call this a crash)"
touch -d '5 minutes ago' "$M"
printf '%s\n' "$$" > "$PIDF"       # a live HOST pid must not rescue a dead heartbeat
PR_STATUS_LAST=(); : > "$T/api.log"
pr_status_sweep_pass
has 'statuses/sha7 -f state=failure .*description=worker exited: no CLI in window'; green "stale heartbeat + live host pid -> failure (a pid check would call this parked)"
touch "$M"
PR_STATUS_LAST=()
pr_status_sweep_pass
has 'statuses/sha7 -f state=pending .*description=parked: idle shell'; green "heartbeat resumes -> parked again"

# The producer side: run_idle_shell writes the marker on entry and removes it when the shell exits.
LISTENER="$SCRIPT_DIR/../scripts/worker-listener.sh"
grep -q '^IDLE_PARKED_MARKER="\$QUEUE_ROOT/.idle-parked"' "$LISTENER" || red "listener lost IDLE_PARKED_MARKER (path must match the watcher's .swarm/tasks/.idle-parked)"
# (whole-file greps: a sed range over run_idle_shell stops at the heredoc's own column-0 braces)
grep -q 'date +%s > "\$IDLE_PARKED_MARKER"' "$LISTENER" || red "run_idle_shell does not write the park marker"
grep -q 'rm -f "\$rcfile" "\$IDLE_SHELL_PIDFILE" "\$IDLE_PARKED_MARKER"' "$LISTENER" || red "run_idle_shell does not remove the park marker on exit"
green "run_idle_shell writes the park marker on entry and removes it on exit"
grep -c 'touch -c "\$IDLE_PARKED_MARKER"' "$LISTENER" | grep -qx 2 || red "poll_for_brief lost its park-marker heartbeat (both loops must touch it, #925)"
green "poll_for_brief heartbeats the park marker in both loops"
