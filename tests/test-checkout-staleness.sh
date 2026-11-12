#!/usr/bin/env bash
# Issue #641: _checkout-staleness.sh reports how far a checkout is behind
# origin/<default> and fast-forwards a clean default-branch checkout. Synthetic
# local repos only (a bare "origin" on disk), no network.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0; ok() { echo "PASS: $1"; }; bad() { echo "FAIL: $1"; fail=1; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

T="$(mktemp -d -t stale-checkout-XXXXXX)"; trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
# shellcheck source=../scripts/_checkout-staleness.sh
. "$ROOT/scripts/_checkout-staleness.sh"

git init -q --bare -b master "$T/origin.git"
git clone -q "$T/origin.git" "$T/seed" 2>/dev/null
git -C "$T/seed" checkout -q -b master 2>/dev/null || true
echo 1 > "$T/seed/f"; git -C "$T/seed" add f; git -C "$T/seed" commit -qm one
git -C "$T/seed" push -q origin master
git clone -q "$T/origin.git" "$T/run" 2>/dev/null
push_commits() { for i in $(seq 1 "$1"); do echo "$RANDOM" >> "$T/seed/f"; git -C "$T/seed" commit -qam "c$i"; done; git -C "$T/seed" push -q origin master; }

eq "current checkout reports 0 behind" "$(checkout_behind_count "$T/run")" "0"
push_commits 3
eq "before fetch the local ref is unchanged (no network)" "$(checkout_behind_count "$T/run")" "0"
git -C "$T/run" fetch -q origin
eq "after fetch reports 3 behind" "$(checkout_behind_count "$T/run")" "3"

# Degradation: silent, exit 0, no output.
git init -q "$T/noremote"
eq "no origin: no output" "$(checkout_behind_count "$T/noremote")" ""
eq "not a repo: no output" "$(checkout_behind_count "$T")" ""
git -C "$T/run" checkout -q -b topic
eq "custom branch: no output" "$(checkout_behind_count "$T/run")" ""
git -C "$T/run" checkout -q --detach
eq "detached HEAD: no output" "$(checkout_behind_count "$T/run")" ""
git -C "$T/run" checkout -q master

# ff refusals report a reason and return 1.
echo dirty >> "$T/run/f"
rc=0; msg="$(checkout_ff_to_origin "$T/run")" || rc=$?
eq "dirty checkout: ff refused" "$rc" "1"
case "$msg" in *"uncommitted changes"*) ok "dirty message names cause";; *) bad "dirty message: $msg";; esac
eq "dirty checkout left behind" "$(checkout_behind_count "$T/run")" "3"
git -C "$T/run" checkout -q -- f
git -C "$T/run" checkout -q topic
rc=0; msg="$(checkout_ff_to_origin "$T/run")" || rc=$?
eq "non-default branch: ff refused" "$rc" "1"
case "$msg" in *"not master"*) ok "branch message names default";; *) bad "branch message: $msg";; esac
git -C "$T/run" checkout -q master
rc=0; msg="$(checkout_ff_to_origin "$T/noremote")" || rc=$?
eq "no origin: ff refused, no crash" "$rc" "1"

# Success: clean + default branch -> fetched and fast-forwarded.
push_commits 2
rc=0; msg="$(checkout_ff_to_origin "$T/run")" || rc=$?
eq "clean default branch: ff ok" "$rc" "0"
case "$msg" in *"fast-forwarded 5 commit"*) ok "ff message counts commits";; *) bad "ff message: $msg";; esac
eq "caught up after ff" "$(checkout_behind_count "$T/run")" "0"
rc=0; msg="$(checkout_ff_to_origin "$T/run")" || rc=$?
eq "already current: rc 0" "$rc" "0"

# Diverged local commit: ff impossible, reported, not fatal.
echo local >> "$T/run/f"; git -C "$T/run" commit -qam local
push_commits 1
rc=0; msg="$(checkout_ff_to_origin "$T/run")" || rc=$?
eq "diverged: ff refused" "$rc" "1"

# Wiring shape: watcher and swarm-merge use the helper.
grep -q 'stale_checkout_pass || true' "$ROOT/scripts/coordinator-watch.sh" && ok "watcher timer loop runs the pass" || bad "watcher does not run the pass"
grep -q 'checkout_ff_to_origin "\$MAIN_WT"' "$ROOT/scripts/swarm-merge.sh" && ok "swarm-merge fast-forwards after merge" || bad "swarm-merge missing ff step"

exit "$fail"
