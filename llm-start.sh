#!/usr/bin/env bash
#
# llm-start.sh - Bootstrap the multi-agent tmux session
#
# This script creates a dedicated tmux session for the current project,
# spawns the coordinator agent (claude by default; gemini or codex if
# COORDINATOR_CMD selects one) in the first window, and issues its initial
# startup command.
#
# Optional flags (env vars):
#   COORDINATOR_CMD={claude,gemini,codex}   Default: claude
#   COORDINATOR_MODEL=<id>            Per-coordinator default; see below
#   COORDINATOR_VERBOSE=1             Stay interactive in coordinator pane
#   WATCH=1                           Spawn coordinator-watch.sh in a 2nd
#                                     tmux window (carries POST_OUTCOMES,
#                                     OUTCOME_HOOK, DEBOUNCE_SECS, etc.
#                                     from caller env)
#   STATUS=1                          Spawn gh-status-bar.sh in a 'status'
#                                     tmux window — updates the session's
#                                     status-right with live open-issue/
#                                     open-PR/closed-today counts. Carries
#                                     STATUS_INTERVAL, STATUS_LENGTH,
#                                     STATUS_FORMAT, GH_TIMEOUT.
#   NON_INTERACTIVE=1                 Don't auto-attach to the session
set -euo pipefail

# Configuration
# Self-locate so the sandbox tree works from any clone path (not tied to
# /opt/work/sysadmin/...). LLM_SWARM_DIR overrides if you want to point at
# a different install while running this script from elsewhere.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLM_SWARM_DIR="${LLM_SWARM_DIR:-$SCRIPT_DIR}"

SESSION_NAME="llm-$(basename "$PWD")"
SYSTEM_PROMPT_FILE="$LLM_SWARM_DIR/prompts/coordinator.md"

# Per-repo tmux socket isolates swarm sessions from the user's default tmux
# server. Different `-L name` = different tmux server = independent
# resurrect/continuum state. Without this, swarm sessions land on the default
# socket alongside `main`, and tmux-continuum on the default socket
# auto-restores all of them on next server start — clobbering `main` as the
# expected attach target.
#
# Resurrect state for the swarm lives inside the repo (.swarm/tmux-resurrect/),
# so save/restore is genuinely per-project. tmux-continuum is left disabled on
# the swarm server; rely on manual prefix+Ctrl-s / prefix+Ctrl-r when desired.
SWARM_SOCKET="swarm-$(basename "$PWD")"
SWARM_RESURRECT_DIR="$PWD/.swarm/tmux-resurrect"

# Shadow `tmux` for the lifetime of this script so every tmux call below
# routes to the swarm socket. Commands sent into panes (via send-keys) run in
# child shells that don't see this function — but those shells already have
# $TMUX set by the swarm server, so their bare `tmux` invocations hit the
# right server automatically.
tmux() { command tmux -L "$SWARM_SOCKET" "$@"; }

# --- Help / usage ----------------------------------------------------------

usage() {
    cat <<EOF
llm-start.sh — Bootstrap a multi-agent tmux coordinator session

USAGE
    llm-start.sh [FLAGS] [PROMPT]

ARGUMENTS
    PROMPT          Initial prompt for the coordinator
                    (default: "Execute the Initial Startup Checklist.")

FLAGS
    -h, --help                       Show this help and exit
    -w, --watch                      Spawn coordinator-watch.sh   (= WATCH=1)
    -y, --yolo                       Opinionated automation bundle (see below)
        --status                     Spawn gh-status-bar window   (= STATUS=1)
        --max-workers N              Concurrent worker tmux windows
        --max-windows N              Total session window cap (HARD)
        --target-available N         AVAILABLE backlog target
        --include-others             Claim others' tickets        (= INCLUDE_ASSIGNED_TO_OTHERS=1)
        --owner-labels L1,L2         Comma-sep labels meaning "human-owned"

YOLO BUNDLE
    --yolo sets, only when not already set: WATCH=1 STATUS=1 MAX_WORKERS=5
    INCLUDE_ASSIGNED_TO_OTHERS=1 DEBOUNCE_SECS=15.
    Explicit flags and shell env still win, so 'MAX_WORKERS=8 ./llm-start.sh
    --yolo' gives 8 workers. MAX_TMUX_WINDOWS stays at 10 — the runaway
    brake is never disabled by yolo.

ENV VARS  (precedence: flag > shell env > <project>/.swarm/.env > <sandbox>/.env.example)

  Coordinator
    COORDINATOR_CMD              claude    claude | gemini | codex
    COORDINATOR_MODEL            (varies)  per-coordinator default
    COORDINATOR_VERBOSE          0         gemini -i instead of -p
    COORDINATOR_HEADLESS         0         1 = claude -p (exits after each prompt)
    COORDINATOR_USE_API_KEY      0         keep ANTHROPIC_API_KEY (bills API)

  Caps & filters  [also loadable from <project>/.swarm/.env]
    MAX_WORKERS                  5         concurrent worker tmux windows
    MAX_TMUX_WINDOWS             10        total session window cap (HARD)
    TARGET_AVAILABLE             10        AVAILABLE backlog target
    OWNER_LABELS                 (empty)   comma-sep labels = "human-owned"
    INCLUDE_ASSIGNED_TO_OTHERS   0         1 = claim others' tickets

  Watcher (when WATCH=1)
    WATCH                        0         spawn coordinator-watch.sh
    DEBOUNCE_SECS                30        wake coalescing window
    POLL_SECS                    2         poll-mode latency
    POST_OUTCOMES                0         run sweep on each outcome
    OUTCOME_HOOK                 (none)    path to per-outcome poster script

  Misc
    STATUS                       0         spawn gh-status-bar window
    NON_INTERACTIVE              0         don't auto-attach (for tests)

EXAMPLES
    ./llm-start.sh                              # one-shot triage, defaults
    ./llm-start.sh -w                           # one-shot + auto top-up
    ./llm-start.sh --yolo                       # unattended sprint mode
    ./llm-start.sh --max-workers 8 -w           # 8 workers, watcher on
    MAX_WORKERS=8 ./llm-start.sh --yolo         # 8 (env wins over yolo's 5)
    ./llm-start.sh "claim Radesh's tickets"     # free-text override

DOCS
    README:    $LLM_SWARM_DIR/README.md
    Overview:  $LLM_SWARM_DIR/docs/llm-swarm-runner-overview.md
EOF
}

# --- Flag parsing ----------------------------------------------------------
# Flags export immediately, beating shell env (so --max-workers 10 wins over
# MAX_WORKERS=8). The env loader (sourced after this loop) only sets unset
# vars, giving the standard precedence: flag > shell env > project .env >
# sandbox .env.example.

require_value() {
    if [ -z "${2:-}" ] || [[ "${2:-}" == -* ]]; then
        echo "ERROR: $1 requires a value" >&2
        exit 1
    fi
}

YOLO=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)              usage; exit 0 ;;
        -w|--watch)             export WATCH=1; shift ;;
        -y|--yolo)              YOLO=1; shift ;;
        --status)               export STATUS=1; shift ;;
        --include-others)       export INCLUDE_ASSIGNED_TO_OTHERS=1; shift ;;
        --max-workers)          require_value "$1" "${2:-}"; export MAX_WORKERS="$2"; shift 2 ;;
        --max-workers=*)        export MAX_WORKERS="${1#*=}"; shift ;;
        --max-windows)          require_value "$1" "${2:-}"; export MAX_TMUX_WINDOWS="$2"; shift 2 ;;
        --max-windows=*)        export MAX_TMUX_WINDOWS="${1#*=}"; shift ;;
        --target-available)     require_value "$1" "${2:-}"; export TARGET_AVAILABLE="$2"; shift 2 ;;
        --target-available=*)   export TARGET_AVAILABLE="${1#*=}"; shift ;;
        --owner-labels)         require_value "$1" "${2:-}"; export OWNER_LABELS="$2"; shift 2 ;;
        --owner-labels=*)       export OWNER_LABELS="${1#*=}"; shift ;;
        --)                     shift; break ;;
        -*)                     echo "ERROR: unknown flag: $1 (try --help)" >&2; exit 1 ;;
        *)                      break ;;   # positional PROMPT starts here
    esac
done

# --yolo bundle: apply opinionated defaults AFTER explicit flags. The
# `:= ` form only sets when unset, so any flag/env value the user already
# supplied wins. MAX_TMUX_WINDOWS deliberately not bumped — runaway brake
# is never relaxed by yolo.
if [ "$YOLO" = "1" ]; then
    : "${WATCH:=1}";                      export WATCH
    : "${STATUS:=1}";                     export STATUS
    : "${MAX_WORKERS:=5}";                export MAX_WORKERS
    : "${INCLUDE_ASSIGNED_TO_OTHERS:=1}"; export INCLUDE_ASSIGNED_TO_OTHERS
    : "${DEBOUNCE_SECS:=15}";             export DEBOUNCE_SECS
fi

INITIAL_PROMPT="${1:-Execute the Initial Startup Checklist.}"

# Load <project>/.swarm/.env then <sandbox>/.env.example. Vars set above by
# flags or yolo (or by the caller's shell env) survive — the loader only
# fills in still-unset vars. Final precedence:
#   flag > shell env > <project>/.swarm/.env > <sandbox>/.env.example
# shellcheck source=scripts/_load-env.sh
. "$LLM_SWARM_DIR/scripts/_load-env.sh" "$PWD"

# Allow overriding the coordinator command and model
COORD_CMD="${COORDINATOR_CMD:-claude}"
# Default model depends on which coordinator is running:
#   claude → claude-fable-5 (Fable 5 — 1M context is the default on this
#     model, so no '[1m]' suffix is needed. Older '[1m]'-suffixed ids like
#     'claude-opus-4-7[1m]' still work as overrides; single-quote them at
#     the shell to suppress glob expansion of the brackets).
#   gemini → gemini-2.5-flash (stable). gemini-3-flash-preview returns
#     INVALID_ARGUMENT on multi-step tool sequences (which is the
#     coordinator's whole job), so it's not a viable default.
#   codex → CLI-configured default. Set COORDINATOR_MODEL to pin one.
# Override either via COORDINATOR_MODEL=<id>.
case "$COORD_CMD" in
    claude) COORD_MODEL_DEFAULT='claude-fable-5' ;;
    gemini) COORD_MODEL_DEFAULT='gemini-2.5-flash' ;;
    codex)  COORD_MODEL_DEFAULT='' ;;
    *)      COORD_MODEL_DEFAULT='' ;;
esac
COORD_MODEL="${COORDINATOR_MODEL:-$COORD_MODEL_DEFAULT}"

# Auto-discover GEMINI_API_KEY when running gemini coordinator. Gemini CLI only
# auto-loads .env from CWD/walks up to $HOME and ~/.gemini/.env — it never
# finds keys stored outside those paths. So we walk a configurable list and
# source the first match. tmux new-session -e then propagates it into the
# coordinator pane.
#
# Default search list works on the original minti9 layout. Append to it via
# LLM_ENV_FILES (colon-separated, like $PATH) for additional locations
# without losing the defaults.
GEMINI_ENV_SOURCED=""
if [ "$COORD_CMD" = "gemini" ] && [ -z "${GEMINI_API_KEY:-}" ]; then
    _env_candidates=(
        "$PWD/.env"
        "$HOME/.gemini/.env"
        "$LLM_SWARM_DIR/.env"
        "/opt/work/sysadmin/.env"
    )
    if [ -n "${LLM_ENV_FILES:-}" ]; then
        IFS=':' read -ra _extra_envs <<< "$LLM_ENV_FILES"
        _env_candidates+=("${_extra_envs[@]}")
    fi
    for _candidate in "${_env_candidates[@]}"; do
        if [ -f "$_candidate" ] && grep -q '^GEMINI_API_KEY=' "$_candidate" 2>/dev/null; then
            set -a
            # shellcheck source=/dev/null
            . "$_candidate"
            set +a
            if [ -n "${GEMINI_API_KEY:-}" ]; then
                GEMINI_ENV_SOURCED="$_candidate"
                break
            fi
        fi
    done
    if [ -z "${GEMINI_API_KEY:-}" ]; then
        echo "WARN: GEMINI_API_KEY not in env and not found in any of:" >&2
        printf '      %s\n' "${_env_candidates[@]}" >&2
        echo "      (extend the search list via LLM_ENV_FILES=path1:path2:...)" >&2
        echo "      gemini will fail with 'specify the GEMINI_API_KEY' on launch." >&2
    fi
fi

# Check if already inside tmux
IN_TMUX=false
if [ -n "${TMUX:-}" ]; then
    IN_TMUX=true
fi

# --- Session + coordinator-pane state detection -----------------------------
# Two boolean flags drive the launch decision below:
#   session_existed      — was a prior llm-X session already running?
#   coordinator_idle     — is the coordinator window's pane sitting at a shell
#                          prompt (i.e., previous agent exited / errored / Ctrl-C'd)?
# Logic:
#   • no session              → create new session + window, send prompt
#   • session, idle pane      → reuse existing window, send new prompt
#   • session, busy pane      → don't disturb; just attach so user can watch
session_existed=false
coordinator_idle=true
window_exists=true   # vacuously true when no session — gated by session_existed
PANE_CMD=""
PANE_DEAD=0
if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    session_existed=true
    if tmux list-windows -t "$SESSION_NAME" -F '#W' 2>/dev/null | grep -qx 'coordinator'; then
        # eval-safe: format string is fixed, values are constrained by tmux
        # (pane_current_command is an executable name; pane_dead is 0 or 1).
        eval "$(tmux list-panes -t "$SESSION_NAME:coordinator" \
                 -F 'PANE_CMD=#{pane_current_command} PANE_DEAD=#{pane_dead}' \
                 2>/dev/null | head -1)"
        if [ "${PANE_DEAD:-0}" = "1" ]; then
            # remain-on-exit=failed left a dead pane after a non-zero exit.
            # Kill it; the window auto-closes when its last pane is gone,
            # collapsing this into the window_exists=false case below.
            tmux kill-pane -t "$SESSION_NAME:coordinator" 2>/dev/null || true
            window_exists=false
            coordinator_idle=true
            echo "Detected dead coordinator pane (previous crash); cleared. Will relaunch."
        else
            case "$PANE_CMD" in
                bash|zsh|sh|fish|"") coordinator_idle=true ;;
                *)                   coordinator_idle=false ;;
            esac
        fi
    else
        # Session survives but coordinator window is gone — clean exit
        # closed it under remain-on-exit=failed. Recreate the window.
        window_exists=false
        coordinator_idle=true
    fi
fi

if ! $session_existed; then
    if [ "$COORD_CMD" = "gemini" ]; then
        echo "Creating new multi-agent session: $SESSION_NAME (Coordinator: gemini, Model: $COORD_MODEL)"
    else
        echo "Creating new multi-agent session: $SESSION_NAME (Coordinator: $COORD_CMD)"
    fi

    # Create a detached session, name the first window "coordinator".
    # Propagate GEMINI_API_KEY into the session env when present, so the
    # gemini coordinator (which auto-loads .env from CWD/walks up only)
    # finds it without us having to copy a .env into every project dir.
    TMUX_ENV_OPTS=()
    if [ -n "${GEMINI_API_KEY:-}" ]; then
        TMUX_ENV_OPTS+=(-e "GEMINI_API_KEY=$GEMINI_API_KEY")
    fi
    # Propagate WORKER_HEADLESS into the session so any worker windows the
    # coordinator spawns inherit it (used by automation/tests where no human
    # is attached to answer claude's trust dialog or interactive REPL).
    if [ -n "${WORKER_HEADLESS:-}" ]; then
        TMUX_ENV_OPTS+=(-e "WORKER_HEADLESS=$WORKER_HEADLESS")
    fi
    # Propagate COORDINATOR_HEADLESS so child invocations of llm-start.sh
    # inside the session (e.g. provision-worker, watch-driven re-wakes) see
    # the same value. Default (unset) = interactive REPL coordinator.
    if [ -n "${COORDINATOR_HEADLESS:-}" ]; then
        TMUX_ENV_OPTS+=(-e "COORDINATOR_HEADLESS=$COORDINATOR_HEADLESS")
    fi
    # Propagate sandbox config into the session so the coordinator LLM and
    # any provision-worker.sh invocations within the session see the same
    # caps and filters loaded from .env.example / .swarm/.env above.
    # LLM_SWARM_DOCS = $LLM_SWARM_DIR/docs by convention; matches the
    # env var sandbox.sh sets inside worker containers, so coordinator and
    # workers reference the same path notation.
    : "${LLM_SWARM_DOCS:=$LLM_SWARM_DIR/docs}"
    export LLM_SWARM_DOCS
    for _v in MAX_WORKERS MAX_TMUX_WINDOWS TARGET_AVAILABLE OWNER_LABELS \
              INCLUDE_ASSIGNED_TO_OTHERS DEBOUNCE_SECS POLL_SECS \
              WORKER_CMD WORKER_MODEL WORKER_HEADLESS WORKER_VERBOSITY WORKER_SELF_REVIEW \
              LLM_SWARM_DIR LLM_SWARM_DOCS; do
        _val="${!_v:-}"
        [ -n "$_val" ] && TMUX_ENV_OPTS+=(-e "$_v=$_val")
    done
    unset _v _val
    if [ -n "$GEMINI_ENV_SOURCED" ]; then
        echo "Loaded GEMINI_API_KEY from $GEMINI_ENV_SOURCED"
    fi
    tmux new-session -d -s "$SESSION_NAME" "${TMUX_ENV_OPTS[@]}" -n "coordinator"

    # Pin resurrect state to this repo, disable continuum autosave/restore on
    # the swarm server. The swarm is recreated via llm-start.sh, so we don't
    # want continuum's timer competing with the repo-local save dir.
    mkdir -p "$SWARM_RESURRECT_DIR"
    tmux set-option -g @resurrect-dir "$SWARM_RESURRECT_DIR" >/dev/null
    tmux set-option -g @continuum-restore 'off' >/dev/null
    tmux set-option -g @continuum-save-interval '0' >/dev/null
elif ! $window_exists; then
    echo "Session $SESSION_NAME exists but coordinator window is gone. Recreating window."
    tmux new-window -d -t "$SESSION_NAME" -n coordinator
elif $coordinator_idle; then
    echo "Session $SESSION_NAME exists; coordinator pane is idle (previous agent exited). Sending new prompt to existing window."
elif [ "$COORD_CMD" = "claude" ] && [ "${COORDINATOR_HEADLESS:-0}" != "1" ]; then
    # Interactive claude REPL is the new default. When the pane is busy
    # running something (PANE_CMD != shell), assume it's the live coordinator
    # REPL and paste the new prompt into it as a follow-up message instead
    # of relaunching claude. This is what kills the "coordinator amnesia"
    # symptom — prior turns stay in-context across `llm "..."` invocations.
    echo "Session $SESSION_NAME exists; coordinator REPL is live (pane: '$PANE_CMD'). Sending prompt into the running session."
else
    echo "Session $SESSION_NAME exists; coordinator is busy (running '$PANE_CMD'). Not interrupting — attaching."
fi

# Ensure the 'util' window exists immediately after coordinator (slot 2).
# Bare bash in $PWD — no sandbox, no container — for ad-hoc inspection
# commands while the coordinator and workers run. When WATCH=1 (below),
# coordinator-watch.sh is added as a second pane in this window instead
# of taking its own window slot, which saves a window and puts the
# watcher next to a live shell you can use to react to its output.
if ! tmux list-windows -t "$SESSION_NAME" -F '#W' 2>/dev/null | grep -qx 'util'; then
    # -a -t coordinator inserts after the coordinator window. tmux shifts
    # any existing windows at that index up to make room, so util ends up
    # at slot 2 (right after coordinator at slot 1).
    tmux new-window -d -a -t "$SESSION_NAME:coordinator" -n util -c "$PWD"
    echo "Created util window (bare bash in $PWD)."
fi

# Only build + send a launch command when we have an idle/empty pane to
# send into. (Skipped when an agent is already running in the existing
# session — that case is handled by the live-REPL reprompt elif below.)
if ! $session_existed || ! $window_exists || $coordinator_idle; then
    # We pass the prompt via a temporary file to handle multiline strings safely
    TMP_PROMPT=$(mktemp)
    echo "$INITIAL_PROMPT" > "$TMP_PROMPT"

    # Render the system prompt with {{LLM_SWARM_DIR}} substituted, so the
    # coordinator's instructions reference the actual install path rather
    # than a hardcoded one. The rendered file is consumed below by
    # GEMINI_SYSTEM_MD / --append-system-prompt; we let it leak into /tmp
    # since it's tiny, deterministic, and the rendered prompt is harmless.
    RENDERED_PROMPT_FILE=$(mktemp -t coordinator-prompt-XXXXXX.md)
    sed "s|{{LLM_SWARM_DIR}}|$LLM_SWARM_DIR|g" "$SYSTEM_PROMPT_FILE" > "$RENDERED_PROMPT_FILE"

    # Per-backend launch. Each branch builds the tmux send-keys line tailored
    # to its CLI. The claude branch delegates to scripts/coordinator-claude.sh
    # so the visible pane line stays short and the long flag soup lives in
    # one maintainable place. The gemini path remains inline (already short).
    if [ "$COORD_CMD" = "claude" ]; then
        # Host-side announce. The wrapper does the actual stripping/toggling,
        # but flagging the ANTHROPIC_API_KEY case here keeps the warning
        # visible to the user launching llm-start.sh (it would otherwise
        # only surface inside the tmux pane).
        if [ -n "${ANTHROPIC_API_KEY:-}" ] && [ "${COORDINATOR_USE_API_KEY:-0}" != "1" ]; then
            echo "WARN: ANTHROPIC_API_KEY is set; coordinator-claude.sh will strip it so Claude Max OAuth is used."
            echo "      (Set COORDINATOR_USE_API_KEY=1 to keep it and bill the API account instead.)"
        fi
        if [ "${COORDINATOR_HEADLESS:-0}" != "1" ]; then
            echo "Coordinator: claude interactive REPL (set COORDINATOR_HEADLESS=1 for -p / exit-after-prompt)."
            echo "  • First run per project triggers claude's 'Trust this folder?' dialog — answer Y."
            echo "  • Conversation grows per turn; restart the pane or /compact when it bloats."
        fi

        # Env-prefix for vars the wrapper reads. printf %q quotes safely so
        # shell glob chars in the model id (e.g. 'claude-opus-4-7[1m]') and
        # any spaces in tmp paths survive the tmux→bash re-parse.
        ENV_VARS=""
        [ -n "${COORD_MODEL:-}" ]                && ENV_VARS+="COORD_MODEL=$(printf '%q' "$COORD_MODEL") "
        [ "${COORDINATOR_HEADLESS:-0}" = "1" ]   && ENV_VARS+="COORDINATOR_HEADLESS=1 "
        [ "${COORDINATOR_USE_API_KEY:-0}" = "1" ] && ENV_VARS+="COORDINATOR_USE_API_KEY=1 "

        WRAPPER="$LLM_SWARM_DIR/scripts/coordinator-claude.sh"
        tmux send-keys -t "$SESSION_NAME:coordinator" \
            "${ENV_VARS}exec $(printf '%q' "$WRAPPER") $(printf '%q' "$RENDERED_PROMPT_FILE") $(printf '%q' "$TMP_PROMPT")" C-m
    elif [ "$COORD_CMD" = "codex" ]; then
        # Codex has no append-system-prompt flag, so the wrapper prepends the
        # rendered coordinator prompt to the user's request and runs a
        # one-shot `codex exec`. This preserves the coordinator's disk-state
        # re-derivation model without depending on TUI keystroke semantics.
        ENV_VARS=""
        [ -n "${COORD_MODEL:-}" ] && ENV_VARS+="COORD_MODEL=$(printf '%q' "$COORD_MODEL") "
        WRAPPER="$LLM_SWARM_DIR/scripts/coordinator-codex.sh"
        tmux send-keys -t "$SESSION_NAME:coordinator" \
            "${ENV_VARS}exec $(printf '%q' "$WRAPPER") $(printf '%q' "$RENDERED_PROMPT_FILE") $(printf '%q' "$TMP_PROMPT")" C-m
    else
        # gemini (or any other backend): inline construction.
        if [ "$COORD_CMD" = "gemini" ]; then
            BASE_CMD="GEMINI_SYSTEM_MD='$RENDERED_PROMPT_FILE' gemini -m '$COORD_MODEL' --yolo --skip-trust"
        else
            BASE_CMD="$COORD_CMD"
        fi

        # COORDINATOR_VERBOSE=1 swaps gemini's -p for -i (--prompt-interactive)
        # so tool calls stream live in the pane. Trade-off: gemini stays alive
        # after the prompt; exit with /quit or Ctrl-D.
        if [ "$COORD_CMD" = "gemini" ] && [ "${COORDINATOR_VERBOSE:-1}" = "1" ]; then
            PROMPT_FLAG="-i"
            echo "COORDINATOR_VERBOSE=1: gemini will stay interactive after the prompt; exit with /quit."
        else
            PROMPT_FLAG="-p"
        fi

        # gemini-cli truncates server-side errors (e.g. INVALID_ARGUMENT on
        # gemini-3-flash-preview) to "Operation cancelled" in the pane while
        # writing the full payload to /tmp/gemini-*-error-*.json. The tail
        # script surfaces the actual message so users don't have to dig.
        if [ "$COORD_CMD" = "gemini" ]; then
            ERR_TAIL="; $LLM_SWARM_DIR/scripts/coordinator-error-tail.sh"
        else
            ERR_TAIL=''
        fi

        tmux send-keys -t "$SESSION_NAME:coordinator" "$BASE_CMD $PROMPT_FLAG \"\$(cat '$TMP_PROMPT')\"; rm '$TMP_PROMPT'$ERR_TAIL" C-m
    fi
elif [ "$COORD_CMD" = "claude" ] && [ "${COORDINATOR_HEADLESS:-0}" != "1" ]; then
    # Live-REPL re-prompt path: claude is already running in the pane and
    # we want to send a follow-up message into the existing conversation.
    # tmux load-buffer + paste-buffer handles multi-line content correctly
    # (bracketed-paste support in modern terminals), then we press Enter
    # to submit it to claude's input prompt.
    TMP_PROMPT=$(mktemp)
    printf '%s\n' "$INITIAL_PROMPT" > "$TMP_PROMPT"
    tmux load-buffer -b llm-coord-reprompt "$TMP_PROMPT"
    tmux paste-buffer -b llm-coord-reprompt -t "$SESSION_NAME:coordinator" -d
    tmux send-keys -t "$SESSION_NAME:coordinator" Enter
    rm -f "$TMP_PROMPT"
fi

# Optionally spawn coordinator-watch.sh as a second pane inside the util
# window (alongside the bare bash from the ensure-block above). The
# unattended supervisor pattern stays one command instead of two terminals.
# WATCH=1 enables; POST_OUTCOMES + OUTCOME_HOOK propagate from caller env
# (so `WATCH=1 POST_OUTCOMES=1 OUTCOME_HOOK=/path ./llm-start.sh` gives
# you coordinator + watcher + audit posting from a single invocation).
# Idempotent: detects an existing watcher pane via its pane_start_command
# and skips the split when one is already running.
if [ "${WATCH:-1}" = "1" ]; then
    WATCH_SCRIPT="$LLM_SWARM_DIR/scripts/coordinator-watch.sh"
    if tmux list-panes -t "$SESSION_NAME:util" -F '#{pane_start_command}' 2>/dev/null \
            | grep -qF "$WATCH_SCRIPT"; then
        echo "coordinator-watch pane already running in '$SESSION_NAME:util' — skipping spawn"
    else
        # printf %q makes every value safe for re-parsing in the new shell,
        # which matters for OUTCOME_HOOK paths and prompts that may contain
        # spaces or quotes.
        WATCH_CMD=""
        for _v in POST_OUTCOMES OUTCOME_HOOK DEBOUNCE_SECS WAKE_PROMPT POLL_SECS WORKSPACE SWEEP; do
            _val="${!_v:-}"
            [ -n "$_val" ] && WATCH_CMD+="$_v=$(printf '%q' "$_val") "
        done
        WATCH_CMD+="$WATCH_SCRIPT $(printf '%q' "$PWD")"
        # -v -b splits above (watcher on top, bash on bottom). -c $PWD makes
        # both panes share a cwd. tmux uses the util window's first pane
        # as the split source automatically when -t targets a window.
        tmux split-window -d -v -b -t "$SESSION_NAME:util" -c "$PWD" "$WATCH_CMD"
        echo "Spawned coordinator-watch as a pane in '$SESSION_NAME:util'"
        if [ "${POST_OUTCOMES:-0}" = "1" ] && [ -z "${OUTCOME_HOOK:-}" ]; then
            echo "  WARN: POST_OUTCOMES=1 but no OUTCOME_HOOK set — sweep will use dry-run stub (no real posts)"
        fi
    fi
fi

# Optionally spawn gh-status-bar.sh in a 'status' window. Updates the tmux
# session's status-right with live open-issue / open-PR / closed-today
# counts so they're visible from every window. Independent of WATCH — the
# status bar polls gh on its own cadence (default 60s) regardless of
# whether worker outcomes are landing.
if [ "${STATUS:-0}" = "1" ]; then
    if tmux list-windows -t "$SESSION_NAME" -F '#W' 2>/dev/null | grep -qx 'status'; then
        echo "tmux window '$SESSION_NAME:status' already exists — skipping status spawn"
    else
        STATUS_SCRIPT="$LLM_SWARM_DIR/scripts/gh-status-bar.sh"
        STATUS_CMD=""
        for _v in STATUS_INTERVAL STATUS_LENGTH STATUS_FORMAT GH_TIMEOUT; do
            _val="${!_v:-}"
            [ -n "$_val" ] && STATUS_CMD+="$_v=$(printf '%q' "$_val") "
        done
        STATUS_CMD+="$STATUS_SCRIPT $(printf '%q' "$SESSION_NAME") $(printf '%q' "$PWD")"
        tmux new-window -d -t "$SESSION_NAME" -n status "$STATUS_CMD"
        echo "Spawned gh-status-bar in tmux window '$SESSION_NAME:status'"
    fi
fi

# Attach or switch to the session
if [ "${NON_INTERACTIVE:-0}" != "1" ]; then
    echo "Connecting to Coordinator (socket: $SWARM_SOCKET)..."
    echo "  Reattach later from this repo: $LLM_SWARM_DIR/llm-start.sh"
    echo "  Or directly: tmux -L $SWARM_SOCKET attach -t $SESSION_NAME"
    if $IN_TMUX; then
        # If we are already in tmux, switch the client to the new session
        tmux switch-client -t "$SESSION_NAME"
    else
        # Otherwise, attach normally
        tmux attach -t "$SESSION_NAME"
    fi
else
    echo "NON_INTERACTIVE is set. Session $SESSION_NAME created but not attaching."
    echo "Attach with: tmux -L $SWARM_SOCKET attach -t $SESSION_NAME"
fi
