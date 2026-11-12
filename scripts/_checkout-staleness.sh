#!/usr/bin/env bash
# _checkout-staleness.sh — sourced helpers (issue #641): notice, and optionally
# fix, a checkout that has fallen behind its origin's default branch.
#
# A running swarm executes scripts/ straight from a checkout. When fixes merge
# but nothing fast-forwards that checkout, workers and watchers silently keep
# running pre-fix logic (2026-11-12: 36 commits behind, so the "no SSH key in
# workers" change was merged but not live).
#
# Everything here is local-only (no fetch) and degrades to "no answer" — never
# an error exit — when there is no origin, no default branch ref, or HEAD is not
# on the default branch (detached, custom branch).
#
#   checkout_default_branch <dir>   print origin's default branch name, or nothing
#   checkout_behind_count <dir>     print N (commits origin/<default> has that
#                                   HEAD lacks) when <dir> is on the default
#                                   branch; print nothing otherwise
#   checkout_ff_to_origin <dir>     fetch + fast-forward when clean and on the
#                                   default branch. Prints one status line;
#                                   returns 0 updated/already current, 1 skipped
#                                   (with the reason in the line), never fatal.

checkout_default_branch() {
    local dir="$1" b candidate
    b="$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
    b="${b#origin/}"
    if [ -z "$b" ]; then
        for candidate in main master; do
            if git -C "$dir" show-ref --verify --quiet "refs/remotes/origin/$candidate" 2>/dev/null; then
                b="$candidate"; break
            fi
        done
    fi
    [ -n "$b" ] && printf '%s\n' "$b"
    return 0
}

checkout_behind_count() {
    local dir="$1" def cur n
    git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || return 0
    def="$(checkout_default_branch "$dir")"
    [ -n "$def" ] || return 0
    cur="$(git -C "$dir" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    [ "$cur" = "$def" ] || return 0
    n="$(git -C "$dir" rev-list --count "HEAD..origin/$def" 2>/dev/null || true)"
    [[ "$n" =~ ^[0-9]+$ ]] && printf '%s\n' "$n"
    return 0
}

checkout_ff_to_origin() {
    local dir="$1" def cur before n
    git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || { echo "checkout $dir: not a git repo — not fast-forwarded"; return 1; }
    def="$(checkout_default_branch "$dir")"
    [ -n "$def" ] || { echo "checkout $dir: no origin default branch — not fast-forwarded"; return 1; }
    cur="$(git -C "$dir" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    if [ "$cur" != "$def" ]; then
        echo "checkout $dir is on ${cur:-a detached HEAD}, not $def — not fast-forwarded; the running swarm may be on old code"
        return 1
    fi
    if [ -n "$(git -C "$dir" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
        echo "checkout $dir has uncommitted changes — not fast-forwarded; run: git -C $dir pull --ff-only"
        return 1
    fi
    git -C "$dir" fetch --quiet origin "$def" >/dev/null 2>&1 || { echo "checkout $dir: git fetch origin $def failed — not fast-forwarded"; return 1; }
    n="$(checkout_behind_count "$dir")"
    [ "$n" != "0" ] || { echo "checkout $dir already at origin/$def"; return 0; }
    before="$(git -C "$dir" rev-parse --short HEAD 2>/dev/null)"
    if git -C "$dir" merge --ff-only --quiet "origin/$def" >/dev/null 2>&1; then
        echo "checkout $dir fast-forwarded $n commit(s) ($before -> $(git -C "$dir" rev-parse --short HEAD)); restart watchers to pick up script changes"
        return 0
    fi
    echo "checkout $dir cannot fast-forward to origin/$def (diverged local commits?) — not updated"
    return 1
}
