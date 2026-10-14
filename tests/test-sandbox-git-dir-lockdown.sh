#!/usr/bin/env bash
#
# test-sandbox-git-dir-lockdown.sh — Regression test for issue #615: a
# worker container must not be able to wipe the shared .git's hooks/,
# info/, refs/ or logs/ for every worktree, the way one worker's own
# build script did on 2026-10-11. `config`, `logs/HEAD` and
# `packed-refs` are deliberately NOT protected — see the "accepted gaps"
# section below and the matching comment in sandbox.sh — so this suite
# tests that they stay writable, not that they survive the attack.
#
# Root cause (corpusminder-spring, 2026-10-11): a worker's build.gradle.kts
# built `build/gitProperties/dotGit` as SYMLINKS into the shared common
# dir — objects, refs, logs, hooks, info, worktrees, config — and the next
# Gradle configuration pass ran `mergedGitDir.deleteRecursively()` (Kotlin,
# follows symlinks to directories) straight through them. Before this fix,
# every one of those targets was writable (sandbox.sh's #504 fix only
# narrowed `worktrees/`), so the delete succeeded: every loose ref, every
# reflog, hooks/, info/exclude and the worker's own worktree admin dir were
# all gone. Lost for good: refs/stash, two refs/notes/*, all reflogs, and
# any custom hooks (loose objects were recoverable — they're content-
# addressed and origin already had copies — which is why this fix leaves
# objects/ writable and does not try to protect it).
#
# Needs a real docker daemon and the built llm-swarm-runner:latest image —
# same requirement, and same reasoning, as test-sandbox-worktree-lockdown.sh
# (bind-mount enforcement is real kernel behavior, not something a stub can
# substitute for).
#
# Fixture placement and the nested-DooD $HOME/.gitconfig quirk: identical
# reasoning to test-sandbox-worktree-lockdown.sh — read that file's header
# and `is_nested_gitconfig_quirk` comment before changing either suite.
set -euo pipefail

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

PASS=0
FAIL=0
SKIP=0

pass() { PASS=$((PASS + 1)); green "  ✓ $1"; shift; [ $# -gt 0 ] && printf '    %s\n' "$@" || true; }
fail() { FAIL=$((FAIL + 1)); red "  ✗ $1"; shift; [ $# -gt 0 ] && printf '    %s\n' "$@" || true; }
skip() { SKIP=$((SKIP + 1)); yellow "  - $1 (skipped: $2)"; }

# Same known, environment-specific false failure as
# test-sandbox-worktree-lockdown.sh (see that file for the full
# explanation): sandbox.sh's unconditional `$HOME/.gitconfig:...:ro` mount
# can resolve to something that isn't a regular file when this suite itself
# runs inside an already-sandboxed container. Any check that needs a `git`
# command to fully resolve config (not a bare filesystem op) skips, rather
# than fails, on this exact signature.
is_nested_gitconfig_quirk() {
    [[ "$1" == *"unable to access"*".gitconfig"*"Is a directory"* ]] \
        && [[ "$1" == *"fatal: unknown error occurred while reading the configuration files"* ]]
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="llm-swarm-runner:latest"
SANDBOX_SH="$REPO_ROOT/sandbox.sh"

echo ""
echo "=== Shared .git lockdown: hooks/info/refs/logs (#615) ==="
echo ""

if ! command -v docker &>/dev/null; then
    red "Docker not found — cannot run this test"
    exit 1
fi
if ! docker image inspect "$IMAGE" &>/dev/null; then
    red "Image '$IMAGE' not found — run: docker build -t $IMAGE ."
    exit 1
fi

FIXTURE="$REPO_ROOT/.tmp-test-sandbox-git-dir-lockdown"
cleanup() {
    [ "${KEEP:-0}" = "1" ] && { yellow "KEEP=1: leaving $FIXTURE for inspection"; return; }
    rm -rf "$FIXTURE"
}
trap cleanup EXIT

rm -rf "$FIXTURE"
mkdir -p "$FIXTURE"
MAIN="$FIXTURE/main"
# Slash-named branches, matching this project's own worker convention
# (fix/issue-N) — deliberately DIFFERENT prefixes for wt-a/wt-b so a pass
# here demonstrates real cross-worker protection, not just "my own branch's
# directory is writable."
WTA="$FIXTURE/wt-a"
WTB="$FIXTURE/wt-b"
BRANCH_A="fix/issue-900"
BRANCH_B="feat/other-500"

git init -q "$MAIN"
git -C "$MAIN" config user.email test@example.com
git -C "$MAIN" config user.name Test
echo hi > "$MAIN/f.txt"
git -C "$MAIN" add f.txt
git -C "$MAIN" commit -qm init
# refs/notes and refs/stash, the two ref namespaces #615 actually destroyed —
# created on MAIN before either worktree exists, so they're shared history
# every worktree's container can see.
git -C "$MAIN" notes add -m "a note worth keeping" >/dev/null 2>&1
echo "stash me" >> "$MAIN/f.txt"
git -C "$MAIN" stash push -q -m "a stash worth keeping"
git -C "$MAIN" branch "$BRANCH_A"
git -C "$MAIN" branch "$BRANCH_B"
git -C "$MAIN" worktree add -q "$WTA" "$BRANCH_A"
git -C "$MAIN" worktree add -q "$WTB" "$BRANCH_B"
GITCOMMON="$MAIN/.git"

# A custom hook and a custom info/exclude/config line — the plain things a
# worker never needs to write but #615 proved were writable anyway.
mkdir -p "$GITCOMMON/hooks"
printf '#!/bin/sh\necho custom-hook-marker\n' > "$GITCOMMON/hooks/pre-commit"
chmod +x "$GITCOMMON/hooks/pre-commit"
printf '# pre-existing local exclude\nmy-local-marker.tmp\n' >> "$GITCOMMON/info/exclude"
git -C "$MAIN" config custom.marker "keep-me"

run_in_wta() {
    # Single-argument command, same caveat as test-sandbox-worktree-lockdown.sh.
    "$SANDBOX_SH" "$WTA" "$1" 2>&1
}

snapshot_protected() {
    # md5sum of everything this fix is supposed to keep safe, taken before
    # the attack so a later mismatch has a concrete "what changed" answer
    # instead of just pass/fail. `config` and `packed-refs` are
    # deliberately excluded — they're two of the three accepted gaps, not
    # something this fix protects (see the header comment and sandbox.sh's
    # #615 comment) — `find` exits 1 for a nonexistent start point even
    # with output suppressed, which trips `pipefail`, so only existing
    # paths are passed to it.
    local paths=() p
    for p in hooks info refs/notes refs/stash refs/heads/feat; do
        [ -e "$GITCOMMON/$p" ] && paths+=("$p")
    done
    ( cd "$GITCOMMON" && find "${paths[@]}" -type f 2>/dev/null | sort | xargs -r md5sum )
}

BEFORE="$(snapshot_protected)"

# ── 1. Direct writes to the clearly-never-needed paths fail outright ───────
echo "[ 1. Direct writes to hooks/, info/exclude fail (read-only) ]"
for rel in hooks/pre-commit info/exclude; do
    out=$(run_in_wta "echo x >> '$GITCOMMON/$rel' 2>&1; echo RC=\$?" || true)
    if echo "$out" | grep -qi "read-only file system" && ! echo "$out" | grep -q "RC=0"; then
        pass "direct write to $rel fails"
    else
        fail "direct write to $rel fails" "$out"
    fi
done

# config is an accepted gap (`git push -u` writes branch.<name>.* into it
# as part of the documented worker flow — see sandbox.sh's #615 comment),
# so assert the opposite: it stays writable, not that it's locked down.
# Appends a comment line (`# x`), not a bare `x`, so the shared config
# file this leaves behind is still valid for every later `git -C "$MAIN"`
# call in this script.
out=$(run_in_wta "echo '# x' >> '$GITCOMMON/config' 2>&1; echo RC=\$?" || true)
if echo "$out" | grep -q "RC=0"; then
    pass "config stays writable (accepted gap: git push -u needs it)"
else
    fail "config stays writable (accepted gap: git push -u needs it)" "$out"
fi

# packed-refs is the third accepted gap (a single-file bind mount would
# pin the container to a stale inode across a host-side `git gc`/
# `pack-refs` — see sandbox.sh's #615 comment) — assert it stays
# writable too. Doesn't exist yet in this fixture (no gc/pack-refs has
# run), so a successful append also proves it's creatable, not just
# modifiable; removed afterward so it doesn't shadow loose refs for the
# rest of this script.
packed_refs_preexisted=0
[ -e "$GITCOMMON/packed-refs" ] && packed_refs_preexisted=1
out=$(run_in_wta "echo '# x' >> '$GITCOMMON/packed-refs' 2>&1; echo RC=\$?" || true)
if echo "$out" | grep -q "RC=0"; then
    pass "packed-refs stays writable (accepted gap: single-file mount would go stale)"
else
    fail "packed-refs stays writable (accepted gap: single-file mount would go stale)" "$out"
fi
[ "$packed_refs_preexisted" = "0" ] && rm -f "$GITCOMMON/packed-refs"

# ── 2. Direct writes to a SIBLING's branch ref / its reflog fail ───────────
echo ""
echo "[ 2. Direct writes to the sibling's (different-prefix) branch ref fail ]"
sib_ref="$GITCOMMON/refs/heads/$BRANCH_B"
out=$(run_in_wta "echo x >> '$sib_ref' 2>&1; echo RC=\$?" || true)
if echo "$out" | grep -qi "read-only file system" && ! echo "$out" | grep -q "RC=0"; then
    pass "direct write to sibling's branch ref ($BRANCH_B) fails"
else
    fail "direct write to sibling's branch ref ($BRANCH_B) fails" "$out"
fi

# ── 3. The #615 attack itself: symlink into the shared dir, then recursive
#       delete through it — reproducing Kotlin's deleteRecursively ─────────
echo ""
echo "[ 3. The #615 attack: symlinks into refs/logs/hooks/info, then rm -rf ]"
attack_out=$(run_in_wta "
    set -e
    mkdir -p '$WTA/evil'
    for d in refs logs hooks info config objects worktrees; do
        ln -s \"$GITCOMMON/\$d\" \"$WTA/evil/\$d\"
    done
    rm -rf '$WTA/evil' 2>&1
    echo DONE
" || true)
if ! echo "$attack_out" | grep -q "DONE"; then
    if is_nested_gitconfig_quirk "$attack_out"; then
        skip "the symlink+rm -rf attack leaves the protected paths intact" \
            "nested-DooD \$HOME/.gitconfig quirk, unrelated to #615"
    else
        fail "the symlink+rm -rf attack leaves the protected paths intact" \
            "attack sequence itself never completed: $attack_out"
    fi
else
    AFTER="$(snapshot_protected)"
    if [ "$BEFORE" = "$AFTER" ]; then
        pass "the symlink+rm -rf attack (refs/logs/hooks/info/objects/worktrees) leaves every protected path byte-for-byte unchanged"
    else
        fail "the symlink+rm -rf attack leaves the protected paths intact" \
            "before: $BEFORE" "after:  $AFTER"
    fi
    # Spell out the specific #615 losses individually too, so a partial
    # regression names exactly which protection broke instead of just
    # "the snapshot differs." `config` is NOT checked here — it's one of
    # the two accepted gaps (see header comment); this same attack can and
    # does wipe it, by design trade-off, not by omission.
    [ -x "$GITCOMMON/hooks/pre-commit" ] \
        && pass "custom hook survives" \
        || fail "custom hook survives" "hooks/pre-commit missing or no longer executable"
    grep -qxF 'my-local-marker.tmp' "$GITCOMMON/info/exclude" \
        && pass "info/exclude survives" \
        || fail "info/exclude survives" "$(cat "$GITCOMMON/info/exclude" 2>&1)"
    git -C "$MAIN" stash list 2>&1 | grep -q "a stash worth keeping" \
        && pass "refs/stash survives" \
        || fail "refs/stash survives" "$(git -C "$MAIN" stash list 2>&1)"
    git -C "$MAIN" notes show 2>&1 | grep -q "a note worth keeping" \
        && pass "refs/notes survives" \
        || fail "refs/notes survives" "$(git -C "$MAIN" notes show 2>&1)"
    git -C "$MAIN" show-ref --verify --quiet "refs/heads/$BRANCH_B" \
        && pass "sibling's branch ref ($BRANCH_B) survives" \
        || fail "sibling's branch ref ($BRANCH_B) survives" "refs/heads/$BRANCH_B is gone"
fi

# ── 4. Regression: the own-branch rw carve-out itself, and a real commit ──
echo ""
echo "[ 4. Regression: the own-branch write carve-out works, and a real commit still succeeds ]"
# A raw filesystem check first — no `git` invocation, so it can't trip the
# nested-DooD gitconfig quirk the full-commit check below can. Proves the
# carve-out mount itself is live, independent of whether this environment
# can exercise a full `git commit`. The ref's original content is saved and
# restored byte-for-byte so this probe can't itself corrupt the branch the
# next check (a real commit) relies on.
own_ref="$GITCOMMON/refs/heads/$BRANCH_A"
own_ref_before="$(cat "$own_ref")"
raw_out=$(run_in_wta "echo x >> '$own_ref' 2>&1; echo RC=\$?" || true)
if echo "$raw_out" | grep -q "RC=0"; then
    pass "own branch ref ($BRANCH_A) is directly writable (the rw carve-out)"
else
    fail "own branch ref ($BRANCH_A) is directly writable (the rw carve-out)" "$raw_out"
fi
printf '%s\n' "$own_ref_before" > "$own_ref"

before_sha="$(git -C "$MAIN" rev-parse "$BRANCH_A")"
own_out=$(run_in_wta "echo change >> f.txt && git add f.txt && git -c user.email=test@example.com -c user.name=Test commit -qm 'worker commit' && echo OWN_COMMIT_OK" || true)
if echo "$own_out" | grep -q "OWN_COMMIT_OK"; then
    after_sha="$(git -C "$MAIN" rev-parse "$BRANCH_A")"
    if [ "$after_sha" != "$before_sha" ]; then
        pass "own commit succeeds and updates $BRANCH_A's ref" "before=$before_sha after=$after_sha"
    else
        fail "own commit succeeds and updates $BRANCH_A's ref" "ref unchanged: $before_sha"
    fi
elif is_nested_gitconfig_quirk "$own_out"; then
    skip "own commit succeeds and updates $BRANCH_A's ref" \
        "nested-DooD \$HOME/.gitconfig quirk, unrelated to #615"
else
    fail "own commit succeeds and updates $BRANCH_A's ref" "$own_out"
fi

# ── 5. Known, accepted limitation: a SAME-prefix sibling's branch ref is
#       NOT isolated — document it as tested, not a silent gap ────────────
echo ""
echo "[ 5. Known tradeoff: a same-TOP-PREFIX sibling branch is not isolated (see sandbox.sh #615 comment) ]"
git -C "$MAIN" branch "fix/issue-901" "$BRANCH_A"
same_prefix_ref="$GITCOMMON/refs/heads/fix/issue-901"
out=$(run_in_wta "echo x >> '$same_prefix_ref' 2>&1; echo RC=\$?" || true)
if echo "$out" | grep -q "RC=0"; then
    pass "a same-prefix sibling branch ref (fix/issue-901) IS writable from fix/issue-900's container — accepted, documented narrowing (not full per-worker isolation; see #615's option (b) for that)"
elif is_nested_gitconfig_quirk "$out"; then
    skip "a same-prefix sibling branch ref is writable (documented tradeoff)" \
        "nested-DooD \$HOME/.gitconfig quirk, unrelated to #615"
else
    fail "a same-prefix sibling branch ref (fix/issue-901) is writable from fix/issue-900's container (documenting the known tradeoff — if this now fails, the narrowing got stricter than the #615 PR claims; update the sandbox.sh comment and this test together)" "$out"
fi

# ── 6. Regression: refs/tags carve-out (fetch auto-follows tags) ──────────
echo ""
echo "[ 6. Regression: refs/tags stays writable (git fetch auto-follows tags onto new commits) ]"
out=$(run_in_wta "echo x >> '$GITCOMMON/refs/tags/does-not-exist-yet' 2>&1; echo RC=\$?" || true)
if echo "$out" | grep -q "RC=0"; then
    pass "refs/tags is directly writable (the rw carve-out)"
elif is_nested_gitconfig_quirk "$out"; then
    skip "refs/tags is directly writable (the rw carve-out)" \
        "nested-DooD \$HOME/.gitconfig quirk, unrelated to #615"
else
    fail "refs/tags is directly writable (the rw carve-out)" "$out"
fi
rm -f "$GITCOMMON/refs/tags/does-not-exist-yet"

# ── 7. Regression found by self-review on the first version of this fix:
#       the MAIN checkout's own HEAD reflog (logs/HEAD, outside logs/refs/)
#       must stay writable, or every commit in the main checkout breaks ──
echo ""
echo "[ 7. Regression: a commit in the MAIN checkout itself still succeeds (logs/HEAD stays writable) ]"
# Raw filesystem check first, same reasoning as section 4's own-ref probe:
# no `git` invocation, so it can't trip the nested-DooD gitconfig quirk the
# full-commit check below can, and it isolates exactly the write the
# self-review flagged (logs/HEAD, not logs/refs/heads/<branch>).
main_logs_head="$GITCOMMON/logs/HEAD"
main_logs_head_before="$(cat "$main_logs_head")"
raw_main_out=$("$SANDBOX_SH" "$MAIN" "echo x >> '$main_logs_head' 2>&1; echo RC=\$?" 2>&1 || true)
if echo "$raw_main_out" | grep -q "RC=0"; then
    pass "MAIN checkout's logs/HEAD is directly writable"
else
    fail "MAIN checkout's logs/HEAD is directly writable" "$raw_main_out"
fi
printf '%s\n' "$main_logs_head_before" > "$main_logs_head"

main_before_sha="$(git -C "$MAIN" rev-parse HEAD)"
main_out=$("$SANDBOX_SH" "$MAIN" "echo change2 >> f.txt && git add f.txt && git -c user.email=test@example.com -c user.name=Test commit -qm 'main-checkout commit' && echo MAIN_COMMIT_OK" 2>&1 || true)
if echo "$main_out" | grep -q "MAIN_COMMIT_OK"; then
    main_after_sha="$(git -C "$MAIN" rev-parse HEAD)"
    if [ "$main_after_sha" != "$main_before_sha" ]; then
        pass "a commit in the MAIN checkout succeeds (logs/HEAD write didn't fail)" "before=$main_before_sha after=$main_after_sha"
    else
        fail "a commit in the MAIN checkout succeeds (logs/HEAD write didn't fail)" "ref unchanged: $main_before_sha"
    fi
elif is_nested_gitconfig_quirk "$main_out"; then
    skip "a commit in the MAIN checkout succeeds (logs/HEAD write didn't fail)" \
        "nested-DooD \$HOME/.gitconfig quirk, unrelated to #615"
else
    fail "a commit in the MAIN checkout succeeds (logs/HEAD write didn't fail)" "$main_out"
fi

echo ""
echo "=== Results ==="
TOTAL=$((PASS + FAIL + SKIP))
green "  Passed: $PASS / $TOTAL"
[ "$SKIP" -gt 0 ] && yellow "  Skipped: $SKIP" || true
[ "$FAIL" -gt 0 ] && red "  Failed: $FAIL" || true
echo ""

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
