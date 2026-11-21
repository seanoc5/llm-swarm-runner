#!/usr/bin/env bash
#
# test-pr-ci-green-note.sh — issue #1033: when a PR goes ✅ (CI green, worker done)
# after a merge was refused on swarm-hold:ci, the watcher writes ONE urgent
# pr_ci_green coord-inbox note per PR + head sha, rings once, and survives a
# restart without re-noting. Cache-driven; no tmux, no gh, no network.
set -euo pipefail
green() { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()   { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
check() { if [ "$2" = "$3" ]; then green "$1"; else red "$1 (expected [$2] got [$3])"; fi; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WATCH="$ROOT/scripts/coordinator-watch.sh"
T="$(mktemp -d -t pr-ci-green-XXXXXX)"; trap 'rm -rf "$T"' EXIT
P="$T/proj"; mkdir -p "$P/.swarm"

# shellcheck disable=SC1090
eval "$(sed -n '/^pr_ci_green_note() {/,/^}/p; /^pr_ci_green_ring_pass() {/,/^}/p; /^coord_inbox_write() {/,/^}/p; /^log_event() {/,/^}/p; /^pr_risk_glyph() {/,/^}/p' "$WATCH")"
declare -A PR_HOLD_CACHE=() PR_MERGE_CACHE=() PR_RISK_CACHE=()
PROJECT_DIR="$P"; DRY_RUN=0; WATCH_WINDOW_FLAG_RISK=1
COORD_INBOX_DIR="$P/.swarm/coord-inbox"; COORD_INBOX_PROCESSED_DIR="$COORD_INBOX_DIR/processed"
COORD_INBOX_SELF_DIR="$COORD_INBOX_DIR/.self"; EVENTS_LOG="$P/.swarm/events.log"
PR_CI_GREEN_RING_DIR="$P/.swarm/pr-ci-green-ring-pending"
PR_CI_GREEN_NOTED_DIR="$P/.swarm/pr-ci-green-noted"
RINGS="$T/rings.log"; : > "$RINGS"
coord_ring_doorbell() { echo "$*" >> "$RINGS"; }
coord_split_flag_urgent() { :; }
pr_open_details_load() { :; }
notes() { find "$COORD_INBOX_DIR" -maxdepth 1 -name '*-pr_ci_green-*.md' 2>/dev/null | wc -l | tr -d ' '; }

SHA1=aaaaaaa1111111111111111111111111111111aa
SHA2=bbbbbbb2222222222222222222222222222222bb
PR_MERGE_CACHE[2966]=$'MERGEABLE\t'"$SHA1"$'\tmaster'; PR_RISK_CACHE[2966]="🟢"; PR_HOLD_CACHE[2966]="-"

pr_ci_green_note 11 2966
check "first ✅ transition writes one note" 1 "$(notes)"
grep -q "swarm-merge.sh 2966 --auto-low" "$COORD_INBOX_DIR"/*-pr_ci_green-*.md || red "note lacks the re-run command"
green "note names the --auto-low re-run command"
pr_ci_green_note 11 2966; pr_ci_green_note 11 2966
check "later polls of the same head write no more notes" 1 "$(notes)"
pr_ci_green_ring_pass; pr_ci_green_ring_pass
check "doorbell rings exactly once" "pr_ci_green count=1 prs=2966-$SHA1" "$(cat "$RINGS")"

PR_MERGE_CACHE[2966]=$'MERGEABLE\t'"$SHA2"$'\tmaster'
pr_ci_green_note 11 2966
check "a new head sha notes again" 2 "$(notes)"

PR_MERGE_CACHE[2967]=$'MERGEABLE\t'"$SHA1"$'\tmaster'; PR_RISK_CACHE[2967]="🔴"
pr_ci_green_note 12 2967
grep -q "needs the operator" "$COORD_INBOX_DIR"/*-pr_ci_green-*.md || red "high-risk PR got no operator caveat"
green "a high-risk PR names no auto-merge command"

PR_MERGE_CACHE[2968]=$'MERGEABLE\t'"$SHA1"$'\tmaster'; PR_HOLD_CACHE[2968]="hold"
n=$(notes); pr_ci_green_note 13 2968
check "a coordinator-held PR writes no note" "$n" "$(notes)"
PR_MERGE_CACHE[2969]=$'CONFLICTING\t'"$SHA1"$'\tmaster'; PR_HOLD_CACHE[2969]="-"
pr_ci_green_note 14 2969
check "a conflicting PR writes no note" "$n" "$(notes)"

check "the first note is classified urgent" urgent "$(. "$ROOT/scripts/_coord-inbox-batch.sh"; coord_item_urgency "$(ls "$COORD_INBOX_DIR"/*-pr_ci_green-*.md | head -1)")"
echo "all pr_ci_green checks passed"
