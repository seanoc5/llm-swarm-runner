#!/usr/bin/env bash
#
# test-shape-load-env.sh — Non-LLM shape tests for _load-env.sh (issue #194):
# asserts the documented precedence order (highest wins):
#   1. shell env (caller-supplied, e.g. a CLI flag exported before sourcing)
#   2. <project>/.swarm/.env
#   3. <sandbox>/.env.example
#
# Uses fixture .env.example / .swarm/.env files rather than this repo's
# real ones, so the test doesn't drift if the shipped defaults change.
set -euo pipefail

green()  { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()    { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
heading(){ printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOAD_ENV="$SCRIPT_DIR/../scripts/_load-env.sh"
[ -f "$LOAD_ENV" ] || red "not found: $LOAD_ENV"

TEST_DIR=$(mktemp -d -t shape-load-env-XXXXXX)
cleanup() {
    if [ "${KEEP:-0}" = "1" ]; then
        yellow "KEEP=1: leaving $TEST_DIR for inspection"
    else
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

SANDBOX="$TEST_DIR/sandbox"
PROJECT="$TEST_DIR/project"
mkdir -p "$SANDBOX" "$PROJECT/.swarm"

cat > "$SANDBOX/.env.example" <<'EOF'
WORKER_VERBOSITY=verbose
SWARM_WORKTREE_GROUPING=flat
MAX_WORKERS=5
EOF

VARS=(WORKER_VERBOSITY SWARM_WORKTREE_GROUPING MAX_WORKERS)

# ============================================================================
heading "Test 1: no project override → sandbox .env.example defaults apply"
# ============================================================================
rm -f "$PROJECT/.swarm/.env"
(
    unset "${VARS[@]}" 2>/dev/null || true
    export LLM_SWARM_DIR="$SANDBOX"
    . "$LOAD_ENV" "$PROJECT"
    [ "$WORKER_VERBOSITY" = "verbose" ]      || { echo "WORKER_VERBOSITY=$WORKER_VERBOSITY, want verbose" >&2; exit 1; }
    [ "$SWARM_WORKTREE_GROUPING" = "flat" ]  || { echo "SWARM_WORKTREE_GROUPING=$SWARM_WORKTREE_GROUPING, want flat" >&2; exit 1; }
    [ "$MAX_WORKERS" = "5" ]                 || { echo "MAX_WORKERS=$MAX_WORKERS, want 5" >&2; exit 1; }
) || red "defaults-only layer failed"
green "no project .env, no shell env → .env.example defaults win"

# ============================================================================
heading "Test 2: project .swarm/.env overrides .env.example defaults"
# ============================================================================
cat > "$PROJECT/.swarm/.env" <<'EOF'
WORKER_VERBOSITY=concise
MAX_WORKERS=8
EOF
(
    unset "${VARS[@]}" 2>/dev/null || true
    export LLM_SWARM_DIR="$SANDBOX"
    . "$LOAD_ENV" "$PROJECT"
    [ "$WORKER_VERBOSITY" = "concise" ]      || { echo "WORKER_VERBOSITY=$WORKER_VERBOSITY, want concise" >&2; exit 1; }
    [ "$MAX_WORKERS" = "8" ]                 || { echo "MAX_WORKERS=$MAX_WORKERS, want 8" >&2; exit 1; }
    # Not overridden by the project file — still falls back to the default.
    [ "$SWARM_WORKTREE_GROUPING" = "flat" ]  || { echo "SWARM_WORKTREE_GROUPING=$SWARM_WORKTREE_GROUPING, want flat" >&2; exit 1; }
) || red "project .env override layer failed"
green "project .swarm/.env overrides the vars it sets; others still fall back to defaults"

# ============================================================================
heading "Test 3: caller-supplied shell env (flag) beats project .swarm/.env"
# ============================================================================
(
    unset SWARM_WORKTREE_GROUPING MAX_WORKERS 2>/dev/null || true
    export WORKER_VERBOSITY=spartan   # simulates a pre-set flag/env var
    export LLM_SWARM_DIR="$SANDBOX"
    . "$LOAD_ENV" "$PROJECT"
    [ "$WORKER_VERBOSITY" = "spartan" ] || { echo "WORKER_VERBOSITY=$WORKER_VERBOSITY, want spartan (shell env should win)" >&2; exit 1; }
    # Project file still wins over the sandbox default for the var it sets
    # and the caller didn't touch.
    [ "$MAX_WORKERS" = "8" ]            || { echo "MAX_WORKERS=$MAX_WORKERS, want 8 (project .env)" >&2; exit 1; }
) || red "shell-env-wins layer failed"
green "pre-set shell env beats project .swarm/.env, which still beats sandbox defaults for other vars"

# ============================================================================
heading "All _load-env.sh precedence shape tests passed"
# ============================================================================
green "flag(shell env) > project .swarm/.env > sandbox .env.example, for WORKER_VERBOSITY/SWARM_WORKTREE_GROUPING/MAX_WORKERS"
echo ""
yellow "Run with KEEP=1 to leave $TEST_DIR for inspection."
