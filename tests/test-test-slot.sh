#!/usr/bin/env bash
#
# test-test-slot.sh — scripts/test-slot.sh counting semaphore (issue #1026):
# exit status passes through, N holders block the N+1th until --wait expires
# (exit 75, command not run), a freed slot is reusable, usage errors exit 2.
set -uo pipefail

green()   { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()     { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SLOT="$SCRIPT_DIR/../scripts/test-slot.sh"
[ -x "$SLOT" ] || red "test-slot.sh not executable"
command -v flock >/dev/null || { echo "skip: flock missing"; exit 0; }

T=$(mktemp -d -t test-slot-XXXXXX)
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$T"' EXIT
export TEST_SLOT_DIR="$T/slots"
cd "$T"   # not a git worktree: no outbox note expected

"$SLOT" --slots 2 -- true 2>/dev/null || red "true should pass"
"$SLOT" --slots 2 -- sh -c 'exit 7' 2>/dev/null; [ $? -eq 7 ] || red "exit status not passed through"
green "exit status passes through"

# Occupy both slots.
"$SLOT" --slots 2 -- sleep 20 2>/dev/null & h1=$!
"$SLOT" --slots 2 -- sleep 20 2>/dev/null & h2=$!
for _ in $(seq 1 50); do
    [ -e "$TEST_SLOT_DIR/slot-1" ] && [ -e "$TEST_SLOT_DIR/slot-2" ] && break; sleep 0.1
done
sleep 0.5
"$SLOT" --slots 2 --wait 3 -- touch "$T/ran" 2>/dev/null; rc=$?
[ "$rc" -eq 75 ] || red "full slots: expected exit 75, got $rc"
[ ! -e "$T/ran" ] || red "command ran despite no slot"
green "third caller times out with 75 and does not run"

# Kill each holder's child (it inherited the lock fd) and then the holder.
pkill -P "$h1" 2>/dev/null; pkill -P "$h2" 2>/dev/null
kill "$h1" "$h2" 2>/dev/null; wait 2>/dev/null
sleep 0.5
"$SLOT" --slots 2 --wait 5 -- touch "$T/ran" 2>/dev/null || red "slot not reusable after release"
[ -e "$T/ran" ] || red "command did not run after release"
green "released slot is reusable"

"$SLOT" --slots 0 -- true 2>/dev/null; [ $? -eq 2 ] || red "slots=0 should be usage error"
"$SLOT" 2>/dev/null; [ $? -eq 2 ] || red "no command should be usage error"
TEST_SLOT_DISABLE=1 "$SLOT" -- true || red "disable escape hatch failed"
green "usage errors and disable switch"

# #1030: a background child left running must not hold the slot.
"$SLOT" --slots 1 -- sh -c 'sleep 30 >/dev/null 2>&1 & echo $! > "'"$T"'/bgpid"' 2>/dev/null
"$SLOT" --slots 1 --wait 3 -- true 2>/dev/null || red "leaked background child held the slot"
kill "$(cat "$T/bgpid")" 2>/dev/null
green "background child does not hold the slot"

# #1030: project-tier TEST_SLOT_DIR/COUNT are ignored with a warning.
mkdir -p "$T/proj/.swarm"
printf 'TEST_SLOT_DIR=%s\nTEST_SLOT_COUNT=99\n' "$T/escape" > "$T/proj/.swarm/.env"
out=$(cd "$T/proj" && env -u TEST_SLOT_DIR -u TEST_SLOT_COUNT bash -c ". '$SCRIPT_DIR/../scripts/_load-env.sh' '$T/proj'; echo \"dir=\${TEST_SLOT_DIR:-unset} count=\${TEST_SLOT_COUNT:-unset}\"" 2>&1)
case "$out" in *"$T/escape"*) red "project TEST_SLOT_DIR leaked: $out" ;; esac
case "$out" in *"count=99"*) red "project TEST_SLOT_COUNT leaked: $out" ;; esac
case "$out" in *"host-only keys are ignored"*) ;; *) red "no warning: $out" ;; esac
green "project .swarm/.env cannot move the shared cap"
