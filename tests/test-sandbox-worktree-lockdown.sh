#!/usr/bin/env bash
#
# test-sandbox-worktree-lockdown.sh — Regression test for issue #504: a
# worker container running `git worktree prune`/`remove` must not be able to
# destroy a SIBLING worktree's admin metadata.
#
# Root cause: sandbox.sh bind-mounts the shared git common dir rw (so git
# works at all from a linked worktree), but only THIS worktree's own working
# directory is bind-mounted into the container — every sibling worktree's
# directory lives at a host path the container can't see. git can't tell
# "doesn't exist because I can't see it" apart from "doesn't exist because it
# was deleted", so it reports every sibling as prunable, and before the fix
# the rw common-dir mount gave `git worktree prune` permission to act on that
# wrong belief. Incident: one worker's `worktree prune -v` destroyed four
# siblings' + the coordinator's admin dirs (seanoc5/llm-swarm-runner#504).
#
# Needs a real docker daemon and the built llm-swarm-runner:latest image
# (same requirement as test-sandbox.sh, hence the same CI exclude-list entry
# in .github/workflows/*.yml) — the whole point is exercising real kernel
# bind-mount enforcement, which no PATH-stub can substitute for.
#
# Fixture placement: under REPO_ROOT (not /tmp). sandbox.sh launches nested
# `docker run` calls against the HOST daemon; if this suite is itself running
# inside a swarm worker container (DooD), a /tmp path resolves against the
# wrong filesystem on the host side. REPO_ROOT is bind-mounted at the same
# absolute path on both sides by convention (see test-sandbox.sh's identical
# fixture-placement comments).
set -euo pipefail

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

PASS=0
FAIL=0
SKIP=0

pass() { PASS=$((PASS + 1)); green "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); red "  ✗ $1"; shift; [ $# -gt 0 ] && printf '    %s\n' "$@" || true; }
skip() { SKIP=$((SKIP + 1)); yellow "  - $1 (skipped: $2)"; }

# Detects a known, environment-specific false failure: when THIS suite is
# itself run from inside an already-sandboxed container whose $HOME doesn't
# correspond to the real host's $HOME (e.g. a swarm worker's own container
# testing sandbox.sh via a nested docker-outside-of-docker call), sandbox.sh's
# unconditional `-v "$HOME/.gitconfig:...:ro"` mount can resolve, on the real
# host side, to something that isn't a regular file — breaking every git
# command that needs full config resolution, with nothing this patch touches.
# Verified directly: reproduces identically against an unmodified sandbox.sh
# and a plain non-worktree PROJECT_DIR, so it predates and is unrelated to
# the #504 fix. Checks 4/5 below skip (not fail) on this exact signature.
is_nested_gitconfig_quirk() {
    [[ "$1" == *"unable to access"*".gitconfig"*"Is a directory"* ]] \
        && [[ "$1" == *"fatal: unknown error occurred while reading the configuration files"* ]]
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="llm-swarm-runner:latest"
SANDBOX_SH="$REPO_ROOT/sandbox.sh"

echo ""
echo "=== Sandbox worktree admin-dir lockdown (#504) ==="
echo ""

if ! command -v docker &>/dev/null; then
    red "Docker not found — cannot run this test"
    exit 1
fi
if ! docker image inspect "$IMAGE" &>/dev/null; then
    red "Image '$IMAGE' not found — run: docker build -t $IMAGE ."
    exit 1
fi

FIXTURE="$REPO_ROOT/.tmp-test-sandbox-worktree-lockdown"
cleanup() {
    [ "${KEEP:-0}" = "1" ] && { yellow "KEEP=1: leaving $FIXTURE for inspection"; return; }
    rm -rf "$FIXTURE"
}
trap cleanup EXIT

rm -rf "$FIXTURE"
mkdir -p "$FIXTURE"
MAIN="$FIXTURE/main"
WTA="$FIXTURE/wt-a"
WTB="$FIXTURE/wt-b"

git init -q "$MAIN"
git -C "$MAIN" config user.email test@example.com
git -C "$MAIN" config user.name Test
echo hi > "$MAIN/f.txt"
git -C "$MAIN" add f.txt
git -C "$MAIN" commit -qm init
git -C "$MAIN" branch wta
git -C "$MAIN" branch wtb
git -C "$MAIN" worktree add -q "$WTA" wta
git -C "$MAIN" worktree add -q "$WTB" wtb
GITCOMMON="$MAIN/.git"

run_in_wta() {
    # Launch the real sandbox.sh against WTA with a one-shot command. Pass
    # the command as a SINGLE argument, not as separate "bash" "-c" words —
    # sandbox.sh's AGENT detection only special-cases the literal tokens
    # claude/gemini/codex/listener, so an explicit leading "bash" is never
    # shifted off and gets folded back into the command via its own `"$*"`
    # wildcard case, producing a doubled `bash -c "bash -c ..."` invocation
    # (see the identical note in test-sandbox.sh).
    "$SANDBOX_SH" "$WTA" "$1" 2>&1
}

# ── 1. Reproduce the underlying visibility bug ──────────────────────────────
# With ONLY wt-a's own directory + the common dir mounted (no wt-b directory),
# git can't see wt-b and must mark it prunable. This is the belief that made
# the pre-fix rw mount dangerous — captured here as evidence independent of
# sandbox.sh's exact mount set.
echo "[ 1. Reproduce: sibling worktree looks prunable without its own mount ]"
repro_out=$(docker run --rm \
    --user "$(id -u):$(id -g)" \
    -v "$WTA:$WTA:rw" \
    -v "$GITCOMMON:$GITCOMMON:rw" \
    -w "$WTA" \
    "$IMAGE" git worktree list --porcelain 2>&1) || true
# Only wt-b is invisible to this container (wt-a is mounted, main's dir is
# the git-dir source itself), so a bare "prunable" anywhere in the porcelain
# output unambiguously means wt-b.
if echo "$repro_out" | grep -q "wt-b" && echo "$repro_out" | grep -q "prunable"; then
    pass "sibling (wt-b) is reported prunable when only wt-a is mounted"
else
    fail "sibling (wt-b) is reported prunable when only wt-a is mounted" "$repro_out"
fi

# ── 2. With the real sandbox.sh: prune removes nothing ──────────────────────
echo ""
echo "[ 2. Fix: git worktree prune -v inside the real sandbox.sh container removes nothing ]"
prune_out=$(run_in_wta "git worktree prune -v" || true)
# Require evidence prune actually ran and saw wt-b as prunable — otherwise
# this check would pass vacuously if sandbox.sh/git failed outright for an
# unrelated reason (e.g. the nested-DooD gitconfig quirk) before prune ever
# got a chance to attempt (and be blocked from) the delete.
if ! echo "$prune_out" | grep -qi "wt-b"; then
    if is_nested_gitconfig_quirk "$prune_out"; then
        skip "wt-b's admin dir survives \`git worktree prune -v\` from inside the container" \
            "nested-DooD \$HOME/.gitconfig quirk, unrelated to #504 (see is_nested_gitconfig_quirk)"
    else
        fail "wt-b's admin dir survives \`git worktree prune -v\` from inside the container" \
            "prune never even saw wt-b as prunable — can't tell this blocked the delete vs. never ran:" \
            "prune output: $prune_out"
    fi
elif [ -d "$GITCOMMON/worktrees/wt-b" ]; then
    pass "wt-b's admin dir survives \`git worktree prune -v\` from inside the container"
else
    fail "wt-b's admin dir survives \`git worktree prune -v\` from inside the container" \
        "prune output: $prune_out" "wt-b admin dir is gone: $GITCOMMON/worktrees/wt-b"
fi

# ── 3. Direct write/delete attempts against the sibling's admin dir fail ────
echo ""
echo "[ 3. Fix: direct writes to a sibling's admin dir are blocked, not just prune ]"
write_out=$(run_in_wta "echo x >> '$GITCOMMON/worktrees/wt-b/HEAD' 2>&1; echo RC=\$?" || true)
if echo "$write_out" | grep -qi "read-only file system" && ! echo "$write_out" | grep -q "RC=0"; then
    pass "direct write into sibling's admin file fails (read-only mount)"
else
    fail "direct write into sibling's admin file fails (read-only mount)" "$write_out"
fi

rm_out=$(run_in_wta "rm -rf '$GITCOMMON/worktrees/wt-b' 2>&1; echo RC=\$?" || true)
# Require evidence the container actually ran rm and it failed (not just that
# the dir survives, which would also be true — wrongly — if the container
# never launched at all).
if ! echo "$rm_out" | grep -q "RC="; then
    fail "rm -rf on sibling's admin dir fails and leaves it intact" \
        "container never reported a result — can't tell this blocked rm vs. never ran:" "$rm_out"
elif echo "$rm_out" | grep -q "RC=0"; then
    fail "rm -rf on sibling's admin dir fails and leaves it intact" "rm reported success: $rm_out"
elif [ -d "$GITCOMMON/worktrees/wt-b" ]; then
    pass "rm -rf on sibling's admin dir fails and leaves it intact"
else
    fail "rm -rf on sibling's admin dir fails and leaves it intact" "$rm_out"
fi

# ── 4. Own worktree's admin dir stays fully writable ────────────────────────
echo ""
echo "[ 4. Regression: this worktree's OWN git operations still work ]"
own_out=$(run_in_wta "git status --porcelain=v1 >/dev/null && echo 'change' >> f.txt && git add f.txt && git -c user.email=test@example.com -c user.name=Test commit -qm 'worker commit' && echo OWN_COMMIT_OK" || true)
if echo "$own_out" | grep -q "OWN_COMMIT_OK"; then
    pass "own worktree's status/add/commit (own admin-dir index write) still work"
elif is_nested_gitconfig_quirk "$own_out"; then
    skip "own worktree's status/add/commit (own admin-dir index write) still work" \
        "nested-DooD \$HOME/.gitconfig quirk, unrelated to #504 (see is_nested_gitconfig_quirk)"
else
    fail "own worktree's status/add/commit (own admin-dir index write) still work" "$own_out"
fi

# ── 5. Plain non-worktree project still launches (no regression) ───────────
echo ""
echo "[ 5. Regression: a plain (non-worktree) project is unaffected ]"
plain_out=$("$SANDBOX_SH" "$MAIN" "git status --porcelain=v1 >/dev/null && echo PLAIN_OK" 2>&1 || true)
if echo "$plain_out" | grep -q "PLAIN_OK"; then
    pass "a plain, non-worktree project directory still launches and works"
elif is_nested_gitconfig_quirk "$plain_out"; then
    skip "a plain, non-worktree project directory still launches and works" \
        "nested-DooD \$HOME/.gitconfig quirk, unrelated to #504 (see is_nested_gitconfig_quirk)"
else
    fail "a plain, non-worktree project directory still launches and works" "$plain_out"
fi

# ── 6. Lockdown also applies when the container IS the main checkout ───────
# The common-dir mount above is only added when it's OUTSIDE PROJECT_DIR
# (the worktree case). When PROJECT_DIR is the main checkout itself, the
# common dir lies INSIDE PROJECT_DIR and is already covered by PROJECT_DIR's
# own mount — this check confirms the sibling lockdown still gets applied
# (nested on top of that mount) rather than being skipped along with the
# now-redundant explicit common-dir mount.
echo ""
echo "[ 6. Fix: lockdown also applies when sandbox.sh is pointed at the main checkout ]"
main_prune_out=$("$SANDBOX_SH" "$MAIN" "git worktree prune -v" 2>&1 || true)
if echo "$main_prune_out" | grep -qi "wt-a\|wt-b"; then
    if [ -d "$GITCOMMON/worktrees/wt-a" ] && [ -d "$GITCOMMON/worktrees/wt-b" ]; then
        pass "both worktrees' admin dirs survive \`git worktree prune -v\` run against the main checkout"
    else
        fail "both worktrees' admin dirs survive \`git worktree prune -v\` run against the main checkout" \
            "prune output: $main_prune_out"
    fi
elif is_nested_gitconfig_quirk "$main_prune_out"; then
    skip "both worktrees' admin dirs survive \`git worktree prune -v\` run against the main checkout" \
        "nested-DooD \$HOME/.gitconfig quirk, unrelated to #504 (see is_nested_gitconfig_quirk)"
else
    fail "both worktrees' admin dirs survive \`git worktree prune -v\` run against the main checkout" \
        "prune never even saw wt-a/wt-b as prunable — can't tell this blocked the delete vs. never ran:" \
        "prune output: $main_prune_out"
fi

# ── 7. Known, accepted tradeoff: `git gc` fails inside a locked-down worker ─
# `git gc` expires reflogs for EVERY worktree, which needs to briefly lock
# each sibling's HEAD — something the read-only overlay now refuses just
# like it refuses prune/rm. This is intentional (allowing that one write
# back would mean allowing writes to sibling admin dirs in general, which is
# the whole thing being locked down) — asserted here so it's a documented,
# tracked behavior rather than a silent, untested side effect.
echo ""
echo "[ 7. Known tradeoff: \`git gc\` can't lock a sibling's HEAD to expire its reflog ]"
gc_out=$(run_in_wta "GIT_CONFIG_GLOBAL=/dev/null git gc 2>&1; echo RC=\$?" || true)
if echo "$gc_out" | grep -qi "cannot lock ref" && ! echo "$gc_out" | grep -q "RC=0"; then
    pass "git gc fails to lock a sibling's HEAD (expected — see docs/troubleshooting.md)"
elif is_nested_gitconfig_quirk "$gc_out"; then
    skip "git gc fails to lock a sibling's HEAD (expected — see docs/troubleshooting.md)" \
        "nested-DooD \$HOME/.gitconfig quirk, unrelated to #504 (see is_nested_gitconfig_quirk)"
else
    fail "git gc fails to lock a sibling's HEAD (expected — see docs/troubleshooting.md)" "$gc_out"
fi

echo ""
echo "=== Results ==="
TOTAL=$((PASS + FAIL + SKIP))
green "  Passed: $PASS / $TOTAL"
[ "$SKIP" -gt 0 ] && yellow "  Skipped: $SKIP" || true
[ "$FAIL" -gt 0 ] && red "  Failed: $FAIL" || true
echo ""

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
