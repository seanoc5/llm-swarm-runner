#!/usr/bin/env bash
# Issue #927: behavioral test for coordinator-watch.sh stale_checkout_pass
# (issue #641 / PR #924). Rule under test: warn at the first gap, stay quiet
# until the gap reaches 2x the last warned gap, warn again at 2x, and re-arm
# once the checkout has caught up. Drives the real function (extracted from the
# watcher by sed) against a temp git repo with a bare on-disk "origin".
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0; ok() { echo "PASS: $1"; }; bad() { echo "FAIL: $1"; fail=1; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

T="$(mktemp -d -t stale-pass-XXXXXX)"; trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
# shellcheck source=../scripts/_checkout-staleness.sh
. "$ROOT/scripts/_checkout-staleness.sh"

# Real function body, stubbed collaborators. Each inbox write appends a line.
NOTES="$T/notes"; : > "$NOTES"
log_event() { :; }
coord_inbox_write() { echo "$1" >> "$NOTES"; }
DRY_RUN=0
body="$(sed -n '/^stale_checkout_pass() {/,/^}/p' "$ROOT/scripts/coordinator-watch.sh")"
[ -n "$body" ] || { echo "FAIL: stale_checkout_pass not found in coordinator-watch.sh"; exit 1; }
eval "$body"
STALE_CHECKOUT_LAST_NOTED=0

git init -q --bare -b master "$T/origin.git"
git clone -q "$T/origin.git" "$T/seed" 2>/dev/null
git -C "$T/seed" checkout -q -b master 2>/dev/null || true
echo 1 > "$T/seed/f"; git -C "$T/seed" add f; git -C "$T/seed" commit -qm one
git -C "$T/seed" push -q origin master
git clone -q "$T/origin.git" "$T/run" 2>/dev/null
LLM_SWARM_DIR="$T/run"

push_commits() { for i in $(seq 1 "$1"); do echo "$RANDOM" >> "$T/seed/f"; git -C "$T/seed" commit -qam "c$i"; done; git -C "$T/seed" push -q origin master; git -C "$T/run" fetch -q origin; }
notes() { wc -l < "$NOTES" | tr -d ' '; }
pass() { stale_checkout_pass >/dev/null; }

pass; eq "current checkout: no warning" "$(notes)" "0"

push_commits 2; pass
eq "first gap (2 behind): warns once" "$(notes)" "1"
eq "records the warned gap" "$STALE_CHECKOUT_LAST_NOTED" "2"

pass; eq "same gap again: quiet" "$(notes)" "1"
push_commits 1; pass
eq "gap 3 (<2x of 2): quiet" "$(notes)" "1"
eq "quiet pass keeps last-noted gap" "$STALE_CHECKOUT_LAST_NOTED" "2"

push_commits 1; pass
eq "gap 4 (=2x of 2): warns again" "$(notes)" "2"
eq "last-noted advances to 4" "$STALE_CHECKOUT_LAST_NOTED" "4"

push_commits 3; pass
eq "gap 7 (<2x of 4): quiet" "$(notes)" "2"
push_commits 1; pass
eq "gap 8 (=2x of 4): warns again" "$(notes)" "3"

# Reset: fast-forward, then a fresh gap warns at its first size (not 2x of 8).
git -C "$T/run" merge -q --ff-only origin/master
pass
eq "caught up: no new warning" "$(notes)" "3"
eq "caught up: re-armed to 0" "$STALE_CHECKOUT_LAST_NOTED" "0"
push_commits 1; pass
eq "new gap of 1 after reset: warns" "$(notes)" "4"

# A failed inbox write must not record the gap (so the next pass retries).
STALE_CHECKOUT_LAST_NOTED=0
git -C "$T/run" merge -q --ff-only origin/master
push_commits 2
coord_inbox_write() { return 1; }
stale_checkout_pass >/dev/null 2>&1
eq "failed write: gap not recorded" "$STALE_CHECKOUT_LAST_NOTED" "0"

exit "$fail"
