#!/usr/bin/env bash
#
# test-shape-load-env.sh — Non-LLM shape tests for _load-env.sh (issue #194):
# asserts the documented precedence order (highest wins):
#   1. shell env (caller-supplied, e.g. a CLI flag exported before sourcing)
#   2. <project>/.swarm/.env
#   3. <sandbox>/.env            — this machine's defaults (gitignored)
#   4. <sandbox>/.env.example    — shipped defaults (tracked)
#
# Uses fixture .env.example / .env / .swarm/.env files rather than this repo's
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
WORKER_MODEL=opus
SWARM_WORKTREE_GROUPING=flat
MAX_WORKERS=5
HOST_MAX_WORKERS=8
EOF

VARS=(WORKER_MODEL SWARM_WORKTREE_GROUPING MAX_WORKERS HOST_MAX_WORKERS)

# ============================================================================
heading "Test 1: no project override → sandbox .env.example defaults apply"
# ============================================================================
rm -f "$PROJECT/.swarm/.env" "$SANDBOX/.env"
(
    unset "${VARS[@]}" 2>/dev/null || true
    export LLM_SWARM_DIR="$SANDBOX"
    . "$LOAD_ENV" "$PROJECT"
    [ "$WORKER_MODEL" = "opus" ]             || { echo "WORKER_MODEL=$WORKER_MODEL, want opus" >&2; exit 1; }
    [ "$SWARM_WORKTREE_GROUPING" = "flat" ]  || { echo "SWARM_WORKTREE_GROUPING=$SWARM_WORKTREE_GROUPING, want flat" >&2; exit 1; }
    [ "$MAX_WORKERS" = "5" ]                 || { echo "MAX_WORKERS=$MAX_WORKERS, want 5" >&2; exit 1; }
    [ "$HOST_MAX_WORKERS" = "8" ]            || { echo "HOST_MAX_WORKERS=$HOST_MAX_WORKERS, want 8" >&2; exit 1; }
) || red "defaults-only layer failed"
green "no host .env, no project .env, no shell env → .env.example defaults win"

# ============================================================================
heading "Test 2: project .swarm/.env overrides .env.example defaults"
# ============================================================================
cat > "$PROJECT/.swarm/.env" <<'EOF'
WORKER_MODEL=sonnet
MAX_WORKERS=8
EOF
(
    unset "${VARS[@]}" 2>/dev/null || true
    export LLM_SWARM_DIR="$SANDBOX"
    . "$LOAD_ENV" "$PROJECT"
    [ "$WORKER_MODEL" = "sonnet" ]           || { echo "WORKER_MODEL=$WORKER_MODEL, want sonnet" >&2; exit 1; }
    [ "$MAX_WORKERS" = "8" ]                 || { echo "MAX_WORKERS=$MAX_WORKERS, want 8" >&2; exit 1; }
    # Not overridden by the project file — still falls back to the default.
    [ "$SWARM_WORKTREE_GROUPING" = "flat" ]  || { echo "SWARM_WORKTREE_GROUPING=$SWARM_WORKTREE_GROUPING, want flat" >&2; exit 1; }
) || red "project .env override layer failed"
green "project .swarm/.env overrides the vars it sets; others still fall back to defaults"

# ============================================================================
heading "Test 3: sandbox .env (host-level) beats .env.example, loses to project"
# ============================================================================
# The host-level file carries facts about the box, not the project — a bigger
# machine raising HOST_MAX_WORKERS is the motivating case. It must outrank the
# shipped default, and still yield to a project's own .swarm/.env.
cat > "$SANDBOX/.env" <<'EOF'
HOST_MAX_WORKERS=12
MAX_WORKERS=3
SWARM_WORKTREE_GROUPING=project
EOF
(
    unset "${VARS[@]}" 2>/dev/null || true
    export LLM_SWARM_DIR="$SANDBOX"
    . "$LOAD_ENV" "$PROJECT"
    # Set only in the host file → host file wins over .env.example.
    [ "$HOST_MAX_WORKERS" = "12" ]           || { echo "HOST_MAX_WORKERS=$HOST_MAX_WORKERS, want 12 (host .env)" >&2; exit 1; }
    [ "$SWARM_WORKTREE_GROUPING" = "project" ] || { echo "SWARM_WORKTREE_GROUPING=$SWARM_WORKTREE_GROUPING, want project (host .env)" >&2; exit 1; }
    # Set in BOTH → the project file outranks the host file.
    [ "$MAX_WORKERS" = "8" ]                 || { echo "MAX_WORKERS=$MAX_WORKERS, want 8 (project .env outranks host .env)" >&2; exit 1; }
) || red "host-level sandbox .env layer failed"
green "sandbox .env beats .env.example; project .swarm/.env still beats sandbox .env"

# ============================================================================
heading "Test 4: caller-supplied shell env (flag) beats every file"
# ============================================================================
(
    unset SWARM_WORKTREE_GROUPING MAX_WORKERS 2>/dev/null || true
    export WORKER_MODEL=haiku       # simulates a pre-set flag/env var
    export HOST_MAX_WORKERS=20      # caller override of the host-level file
    export LLM_SWARM_DIR="$SANDBOX"
    . "$LOAD_ENV" "$PROJECT"
    [ "$WORKER_MODEL" = "haiku" ]       || { echo "WORKER_MODEL=$WORKER_MODEL, want haiku (shell env should win)" >&2; exit 1; }
    [ "$HOST_MAX_WORKERS" = "20" ]      || { echo "HOST_MAX_WORKERS=$HOST_MAX_WORKERS, want 20 (shell env beats host .env)" >&2; exit 1; }
    # Project file still wins over the host/sandbox defaults for the var it
    # sets and the caller didn't touch.
    [ "$MAX_WORKERS" = "8" ]            || { echo "MAX_WORKERS=$MAX_WORKERS, want 8 (project .env)" >&2; exit 1; }
) || red "shell-env-wins layer failed"
green "pre-set shell env beats every file; project .swarm/.env still beats sandbox defaults for other vars"

# ============================================================================
heading "All _load-env.sh precedence shape tests passed"
# ============================================================================
green "flag(shell env) > project .swarm/.env > sandbox .env > sandbox .env.example"
echo ""
yellow "Run with KEEP=1 to leave $TEST_DIR for inspection."
