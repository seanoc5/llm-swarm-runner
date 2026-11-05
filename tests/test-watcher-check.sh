#!/usr/bin/env bash
#
# test-watcher-check.sh — issue #756: a dead coordinator-watch.sh must be
# noticed. Covers scripts/watcher-check.sh (alive / dead / pid reuse /
# deliberate stop / expiry / siblings), the Stop-hook WARN, the watcher's own
# sibling sweep pass and its stop/start markers. No tmux, no claude.
set -euo pipefail
green() { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()   { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
check() { [ "$2" = "$3" ] && green "$1" || red "$1 (expected [$2] got [$3])"; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHK="$ROOT/scripts/watcher-check.sh"
HOOK="$ROOT/scripts/coord-hook.sh"
WATCH="$ROOT/scripts/coordinator-watch.sh"
export LLM_SWARM_DIR="$ROOT"
T="$(mktemp -d -t watcher-check-XXXXXX)"
LIVE=""; WPID=""
trap '[ -z "$LIVE" ] || kill "$LIVE" 2>/dev/null || true; [ -z "$WPID" ] || kill -9 "$WPID" 2>/dev/null || true; rm -rf "$T"' EXIT

mkproj() {   # <name> <pid> [state-file-age]
    mkdir -p "$T/$1/.swarm"
    printf 'pid=%s\nstarted_at=x\n' "$2" > "$T/$1/.swarm/coordinator-watch.state"
    touch -d "${3:-2 hours ago}" "$T/$1/.swarm/coordinator-watch.state"
}
worker_event() {   # <name> <how long ago>
    echo "$(date -u -d "$2" +%Y-%m-%dT%H:%M:%SZ)  worker.start issue=1" >> "$T/$1/.swarm/events.log"
}

# ── the check ───────────────────────────────────────────────────────────────
mkdir -p "$T/never/.swarm"
out="$("$CHK" "$T/never")"; rc=$?
check "no state file (WATCH=0 swarm): silent, rc 0" "0|" "$rc|$out"

# A live process whose argv mentions coordinator-watch counts as the watcher.
bash -c 'exec -a coordinator-watch.sh sleep 300' & LIVE=$!
sleep 0.2
mkproj alive "$LIVE"
out="$("$CHK" "$T/alive")"; rc=$?
check "live watcher: silent, rc 0" "0|" "$rc|$out"
check "--status says running" "running (pid $LIVE)" "$("$CHK" --status "$T/alive")"

sleep 300 & OTHER=$!
mkproj reuse "$OTHER"
set +e; out="$("$CHK" "$T/reuse")"; rc=$?; set -e
kill "$OTHER" 2>/dev/null || true
check "recycled pid (live, but not a watcher) warns, rc 3" "3" "$rc"

mkproj dead 999999
set +e; out="$("$CHK" "$T/dead")"; rc=$?; set -e
check "dead watcher: rc 3" "3" "$rc"
case "$out" in *"WARN: coordinator-watch.sh is NOT running for $T/dead"*) got=yes ;; *) got=no ;; esac
check "WARN names the project" "yes" "$got"
case "$out" in *"restart it: cd $T/dead && NON_INTERACTIVE=1 $ROOT/llm-start.sh"*) got=yes ;; *) got=no ;; esac
check "WARN names the restart command" "yes" "$got"
case "$out" in *"--pause $T/dead"*) got=yes ;; *) got=no ;; esac
check "WARN says how to silence a planned stop" "yes" "$got"

set +e; out="$("$CHK" --pause "$T/no-such-dir" 2>&1)"; rc=$?; set -e
check "a bad project path is a usage error (rc 2), --pause writes nothing" "2|no" \
    "$rc|$([ -e /.swarm/watcher-paused ] && echo yes || echo no)"

# ── deliberate stop vs crash ────────────────────────────────────────────────
"$CHK" --pause "$T/dead" "deploying" >/dev/null
out="$("$CHK" "$T/dead")"; rc=$?
check "--pause silences the dead-watcher WARN" "0|" "$rc|$out"
check "--status says stopped-deliberately" "stopped-deliberately (watcher-paused)" "$("$CHK" --status "$T/dead")"
"$CHK" --resume "$T/dead" >/dev/null
set +e; "$CHK" "$T/dead" >/dev/null; rc=$?; set -e
check "--resume brings the WARN back" "3" "$rc"

: > "$T/dead/.swarm/watcher-stopped"
out="$("$CHK" "$T/dead")"; rc=$?
check "watcher-stopped marker (Ctrl-C / kill) silences it" "0|" "$rc|$out"

touch -d "5 days ago" "$T/dead/.swarm/watcher-stopped"
touch -d "6 days ago" "$T/dead/.swarm/coordinator-watch.state"
set +e; out="$("$CHK" "$T/dead")"; rc=$?; set -e
check "a stop older than WATCHER_PAUSE_MAX_SECS warns again" "3" "$rc"
case "$out" in *"stopped on purpose 5d"*) got=yes ;; *) got=no ;; esac
check "expired-stop WARN says how long it was stopped" "yes" "$got"

touch -d "3 hours ago" "$T/dead/.swarm/watcher-stopped"
touch -d "1 hour ago" "$T/dead/.swarm/coordinator-watch.state"
set +e; "$CHK" "$T/dead" >/dev/null; rc=$?; set -e
check "marker older than the current watcher's start does not silence a later crash" "3" "$rc"
rm -f "$T/dead/.swarm/watcher-stopped"

# ── siblings ────────────────────────────────────────────────────────────────
mkproj sib-recent 999999;  worker_event sib-recent "1 day ago"
mkproj sib-old 999999;     worker_event sib-old "10 days ago"
mkproj sib-noworker 999999
mkproj sib-paused 999999;  worker_event sib-paused "1 hour ago"; "$CHK" --pause "$T/sib-paused" >/dev/null
mkproj sib-stopped 999999; worker_event sib-stopped "1 hour ago"; : > "$T/sib-stopped/.swarm/watcher-stopped"
mkproj sib-alive "$LIVE";  worker_event sib-alive "1 hour ago"
mkdir -p "$T/sib-recent-worktrees/wt-issue-9"; cp -r "$T/sib-recent/.swarm" "$T/sib-recent-worktrees/wt-issue-9/"
out="$("$CHK" --siblings "$T/alive")"
dirs="$(cut -f1 <<<"$out" | sed "s|$T/||" | sort | tr '\n' ' ')"
check "--siblings lists only dead, unsilenced siblings with recent workers" "sib-recent " "$dirs"
check "--siblings carries the last worker.start ISO time" "yes" \
    "$(cut -f3 <<<"$out" | grep -q '^20[0-9][0-9]-.*Z$' && echo yes || echo no)"
out="$("$CHK" --siblings "$T/sib-recent")"
case "$out" in *"$T/sib-recent"$'\t'*) got=self ;; *) got=ok ;; esac
check "--siblings never reports the project it was asked from" "ok" "$got"

# ── the Stop hook ───────────────────────────────────────────────────────────
P="$T/dead"; : > "$P/.swarm/events.log"
hook() { printf '{"stop_hook_active":%s}' "${1:-false}" | CLAUDE_PROJECT_DIR="$P" COORD_HOOK_STATE=1 "$HOOK" Stop; }
out="$(hook)"
check "Stop with a dead watcher blocks" "block" "$(jq -r .decision <<<"$out")"
case "$(jq -r .reason <<<"$out")" in *"restart it: cd $P && NON_INTERACTIVE=1 "*) got=yes ;; *) got=no ;; esac
check "Stop reason carries the restart command" "yes" "$got"
out="$(hook)"
check "second Stop inside WATCHER_DEAD_WARN_SECS is quiet" "" "$out"
out="$(hook true)"
check "stop_hook_active=true never warns" "" "$out"
rm -f "$P/.swarm/watcher-dead-warned"; "$CHK" --pause "$P" >/dev/null
out="$(hook)"
check "Stop with a deliberately stopped watcher is quiet" "" "$out"

# ── the watcher: sibling sweep pass + markers ──────────────────────────────
eval "$(sed -n '/^watcher_sibling_sweep_pass() {/,/^}/p; /^coord_inbox_write() {/,/^}/p; /^log_event() {/,/^}/p' "$WATCH")"
declare -A SIBLING_DEAD_LOGGED=()
PROJECT_DIR="$T/alive"; DRY_RUN=0; WATCHER_CHECK="$CHK"; LLM_SWARM_DIR="$ROOT"
COORD_INBOX_DIR="$T/alive/.swarm/coord-inbox"; COORD_INBOX_PROCESSED_DIR="$COORD_INBOX_DIR/processed"
COORD_INBOX_SELF_DIR="$COORD_INBOX_DIR/.self"; EVENTS_LOG="$T/alive/.swarm/events.log"
WATCHER_DEAD_RING_DIR="$T/alive/.swarm/watcher-dead-ring-pending"
eval "$(sed -n '/^watcher_dead_ring_pass() {/,/^}/p' "$WATCH")"
RINGS="$T/rings.log"; : > "$RINGS"
coord_ring_doorbell() { echo "$*" >> "$RINGS"; }
watcher_sibling_sweep_pass
n="$(find "$COORD_INBOX_DIR" -maxdepth 1 -name '*-watcher_dead-*.md' | wc -l)"
check "sweep writes one watcher_dead inbox note for the dead sibling" "1" "$n"
case "$(cat "$COORD_INBOX_DIR"/*-watcher_dead-*.md)" in *"$T/sib-recent"*"--pause $T/sib-recent"*) got=yes ;; *) got=no ;; esac
check "note names the sibling and how to silence it" "yes" "$got"
watcher_sibling_sweep_pass
n="$(find "$COORD_INBOX_DIR" -maxdepth 1 -name '*-watcher_dead-*.md' | wc -l)"
check "a second sweep does not write a duplicate" "1" "$n"
"$CHK" --pause "$T/sib-recent" >/dev/null
watcher_dead_ring_pass; watcher_dead_ring_pass
check "the note's doorbell rings exactly once, naming the project" "watcher_dead count=1 projects=sib-recent" "$(cat "$RINGS")"
watcher_sibling_sweep_pass
check "dedup entry clears once the sibling is silenced" "0" "${#SIBLING_DEAD_LOGGED[@]}"
"$CHK" --resume "$T/sib-recent" >/dev/null
watcher_sibling_sweep_pass
n="$(find "$COORD_INBOX_DIR" -maxdepth 1 -name '*-watcher_dead-*.md' | wc -l)"
check "a sibling that goes dead again is noted again" "2" "$n"

# Real watcher process: startup clears markers; SIGTERM leaves watcher-stopped.
R="$T/real"; mkdir -p "$R/.swarm"; : > "$R/.swarm/watcher-paused"; : > "$R/.swarm/watcher-stopped"
( cd "$R" && DRY_RUN=1 WATCH_SIBLING_SWEEP_SECS=0 POLL_SECS=1 "$WATCH" "$R" >/dev/null 2>&1 ) & WPID=$!
for _ in $(seq 1 50); do [ -s "$R/.swarm/coordinator-watch.state" ] && break; sleep 0.2; done
check "a starting watcher removes both stop markers" "none" \
    "$([ -e "$R/.swarm/watcher-paused" ] || [ -e "$R/.swarm/watcher-stopped" ] && echo some || echo none)"
check "check sees the real watcher as running" "0" "$("$CHK" "$R" >/dev/null; echo $?)"
wpid="$(sed -n 's/^pid=//p' "$R/.swarm/coordinator-watch.state")"
kill -TERM "$wpid"
for _ in $(seq 1 50); do kill -0 "$wpid" 2>/dev/null || break; sleep 0.2; done
check "SIGTERM leaves the watcher-stopped marker" "yes" "$([ -e "$R/.swarm/watcher-stopped" ] && echo yes || echo no)"
check "...so check reports a deliberate stop, silently" "0|" "$("$CHK" "$R" >/dev/null; echo "$?")|$("$CHK" "$R")"
rm -f "$R/.swarm/watcher-stopped"
echo "all watcher-check tests passed"
