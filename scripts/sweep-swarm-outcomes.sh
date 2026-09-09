#!/usr/bin/env bash
#
# sweep-swarm-outcomes.sh — Iterate worker-finished outcome JSONs and invoke
# a user-configured posting hook (e.g., `gh issue comment`) for each one.
# Idempotent via `.posted` markers — re-runs only post new outcomes.
#
# Usage:
#   sweep-swarm-outcomes.sh [project-dir]
#
# Env:
#   OUTCOME_HOOK   Executable invoked per outcome.
#                  Receives 2 args: <worktree-path> <outcome-json-path>.
#                  Exit 0 = success → marker written.
#                  Non-zero = failure → no marker, retry on next sweep.
#                  Default: built-in dry-run that just prints intent.
#   SWEEP_FORCE=1  Re-post outcomes even when a .posted marker already exists.
#
# Scope:
#   Matches <project-dir>'s OWN worktrees, resolved via
#   swarm_own_worktree_dirs() (issue #357 — `git worktree list` against
#   this project's own repo, not a name-glob under a shared parent dir
#   that a sibling project's swarm can also populate under flat grouping):
#     <own-worktree>/.swarm/tasks/done/*.ok.json
#     <own-worktree>/.swarm/tasks/done/*.err.json
#   (This is the layout that `provision-worker.sh` creates.)
#
# Idempotency marker:
#   For each posted outcome we drop a `<outcome>.posted` file containing
#   the post timestamp. Sweeps skip outcomes whose marker exists.
#
# Exit codes:
#   0  all outcomes posted (or were already posted)
#   1  one or more hook invocations failed
set -euo pipefail

PROJECT_DIR="$(realpath "${1:-$PWD}")"
[ -d "$PROJECT_DIR" ] || { echo "ERROR: not a directory: $PROJECT_DIR" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Source the env loader to get swarm_own_worktree_dirs() (issue #357),
# scoped via `git worktree list` against $PROJECT_DIR's own repo.
# shellcheck source=_load-env.sh
. "$SCRIPT_DIR/_load-env.sh" "$PROJECT_DIR"
FORCE="${SWEEP_FORCE:-0}"

# Default hook: dry-run stub that prints what it would do. Cleaned up on exit.
DEFAULT_HOOK=0
if [ -z "${OUTCOME_HOOK:-}" ]; then
    OUTCOME_HOOK="$(mktemp -t sweep-default-hook-XXXXXX.sh)"
    cat > "$OUTCOME_HOOK" <<'EOF'
#!/usr/bin/env bash
echo "[dry-run] would post: wt=$1 outcome=$2"
EOF
    chmod +x "$OUTCOME_HOOK"
    DEFAULT_HOOK=1
    # shellcheck disable=SC2064
    trap "rm -f '$OUTCOME_HOOK'" EXIT
fi

[ -x "$OUTCOME_HOOK" ] || {
    echo "ERROR: OUTCOME_HOOK not executable: $OUTCOME_HOOK" >&2
    exit 1
}

echo "=== sweep-swarm-outcomes ==="
echo "project:        $PROJECT_DIR"
echo "scanning:       \$PROJECT_DIR's own wt-issue-*/.swarm/tasks/done/ (see issue #357)"
if [ "$DEFAULT_HOOK" = "1" ]; then
    echo "hook:           (dry-run default — set OUTCOME_HOOK to a real poster)"
else
    echo "hook:           $OUTCOME_HOOK"
fi
echo "force re-post:  $FORCE"
echo

POSTED=0
SKIPPED=0
FAILED=0

shopt -s nullglob
outcomes=()
while IFS= read -r wt; do
    [ -n "$wt" ] || continue
    outcomes+=( "$wt"/.swarm/tasks/done/*.ok.json "$wt"/.swarm/tasks/done/*.err.json )
done < <(swarm_own_worktree_dirs "$PROJECT_DIR")
shopt -u nullglob

if [ "${#outcomes[@]}" -eq 0 ]; then
    echo "(no outcome JSONs found)"
    echo
    echo "Posted: 0  Skipped: 0  Failed: 0"
    exit 0
fi

for outcome in "${outcomes[@]}"; do
    # worktree dir = strip /.swarm/tasks/done/<file>.json
    wt="${outcome%/.swarm/tasks/done/*}"
    marker="${outcome}.posted"

    if [ -e "$marker" ] && [ "$FORCE" != "1" ]; then
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    if "$OUTCOME_HOOK" "$wt" "$outcome"; then
        date -Iseconds > "$marker"
        POSTED=$((POSTED + 1))
    else
        echo "  WARN: hook failed for $outcome (will retry next sweep)" >&2
        FAILED=$((FAILED + 1))
    fi
done

echo
echo "Posted: $POSTED  Skipped (already posted): $SKIPPED  Failed: $FAILED"
[ "$FAILED" -eq 0 ] || exit 1
