#!/usr/bin/env bash
#
# capture-worker.sh — read a worker/coordinator pane without mistaking UI
# chrome for conversation.
#
# `tmux capture-pane -p` strips color/attribute info, so Claude Code's
# dimmed composer text (a suggested next prompt the operator never typed),
# `※ recap:` lines, spinner status (`✻ Brewed for Ns`), and session-resume
# dialogs (`❯ 1. Resume from summary…`) all read as plain text indistinguishable
# from something the human actually typed and submitted. See
# docs/tmux-as-channel.md §1c for the incident this guards against (issue
# #219) and the full argument.
#
# This script does two things plain `capture-pane` doesn't:
#   1. Tags known UI-chrome lines inline as [UI-CHROME] in the dump, so a
#      reader (human or coordinator LLM) doesn't have to memorize the marker
#      catalog.
#   2. `--verify TEXT` answers the actual question that matters — "was this
#      SUBMITTED BY THE USER?" — by scanning the worker's own session
#      transcript JSONL for TEXT inside user-role turns only (ground truth
#      for what was actually typed, independent of what the pane currently
#      renders). Assistant turns are excluded — a worker's own report text
#      (e.g. inviting the operator to say a confirmation phrase) does NOT
#      count as that phrase having been submitted. So are tool_result blocks
#      nested inside user-role messages — a tool result (e.g. captured pane
#      output) can contain arbitrary text that was never typed by anyone.
#      See issue #360 (the false-positive this replaced) and #219 (the
#      original guard).
#
# Usage:
#   capture-worker.sh [project-dir] <window> [-S lines]
#   capture-worker.sh [project-dir] <window> --verify "<text>"
#
# ARGUMENTS
#   project-dir   Path to project root (default: $PWD). Used to derive the
#                 socket (swarm-<basename>), session (llm-<basename>), and
#                 (for --verify) the worktree whose transcript to grep.
#   window        Window name, e.g. iss-219 or coordinator.
#
# OPTIONS
#   -S lines      Trailing scrollback lines to capture (default: 200;
#                 pass "-" for full history, same as capture-pane -S -).
#   --verify TEXT Skip the raw dump. Derive the window's worktree
#                 (swarm_worktree_dir for iss-N; project-dir for anything
#                 else), then scan every session transcript under
#                 ~/.claude/projects/<worktree-slug>/*.jsonl for TEXT inside
#                 a user-role turn's own text — not an assistant turn, and
#                 not a tool_result block nested in a user-role message.
#                 Prints FOUND (with the matching file) or NOT FOUND. A
#                 miss means the text was never actually submitted by the
#                 user — it may still appear in the transcript, but only as
#                 an assistant turn or tool output, or it may exist only as
#                 unsubmitted pane content (composer suggestion, recap,
#                 chrome).
#
# ENV VARS
#   CAPTURE_LINES   Default trailing lines when -S is not given (default: 200).
#
# EXIT
#   0   dump mode: always (unless usage/setup error). verify mode: TEXT found.
#   1   verify mode: TEXT NOT found in any transcript for this window.
#   2   usage / setup error (no swarm session, bad window, etc.)
#
# EXAMPLES
#   capture-worker.sh iss-219                          # tagged dump, last 200 lines
#   capture-worker.sh iss-219 -S -                      # tagged dump, full scrollback
#   capture-worker.sh iss-219 --verify "Loop in Radesh"  # was this really typed?
set -euo pipefail

case "${1:-}" in
    -h|--help)
        sed -n '2,67p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
esac

# --- Args ---
PROJECT_DIR="$PWD"
WINDOW=""
LINES="${CAPTURE_LINES:-200}"
VERIFY_TEXT=""

POSITIONAL=()
while [ $# -gt 0 ]; do
    case "$1" in
        -S)
            LINES="${2:?usage: capture-worker.sh ... -S <lines>}"
            shift 2
            ;;
        --verify)
            VERIFY_TEXT="${2:?usage: capture-worker.sh ... --verify <text>}"
            shift 2
            ;;
        *)
            POSITIONAL+=("$1")
            shift
            ;;
    esac
done
set -- "${POSITIONAL[@]+"${POSITIONAL[@]}"}"

if [ $# -eq 2 ]; then
    PROJECT_DIR="$1"
    WINDOW="$2"
elif [ $# -eq 1 ]; then
    WINDOW="$1"
else
    echo "usage: capture-worker.sh [project-dir] <window> [-S lines] [--verify <text>]" >&2
    exit 2
fi

PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
REPO="$(basename "$PROJECT_DIR")"
SOCKET="swarm-$REPO"
SESSION="llm-$REPO"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_load-env.sh
. "$SCRIPT_DIR/_load-env.sh" "$PROJECT_DIR"

# --verify reads the on-disk transcript only — it needs neither a live tmux
# session nor a live window (useful for a worker that's already been
# reaped), so the liveness checks below are skipped in that mode.
if [ -z "$VERIFY_TEXT" ]; then
    if ! tmux -L "$SOCKET" has-session -t "$SESSION" 2>/dev/null; then
        echo "ERROR: no tmux session '$SESSION' on socket '$SOCKET'" >&2
        echo "       (derived from project dir: $PROJECT_DIR)" >&2
        exit 2
    fi

    if ! tmux -L "$SOCKET" list-windows -t "$SESSION" -F '#{window_name}' | grep -qx "$WINDOW"; then
        echo "ERROR: no window '$WINDOW' in session '$SESSION'" >&2
        exit 2
    fi
fi

# --- ANSI-strip (mirrors check-stuck-workers.sh's strip_ansi) ---
strip_ansi() {
    sed 's/\x1b\[[0-9;?]*[A-Za-z]//g; s/\x1b\][^\x07]*\x07//g; s/\x1b[()][AB012]//g; s/\r/\n/g'
}

# --- Known UI-chrome markers (see docs/tmux-as-channel.md §1c) ---
# Precedence doesn't matter here — unlike check-stuck-workers.sh's
# detect_state, every matching pattern gets tagged, not just the first.
tag_chrome() {
    LC_ALL=C awk '
        /※ recap:/                                                          { print "[UI-CHROME] " $0; next }
        /Considering…|Sautéed for|Cooked for|Baked for|Simmered for|Brewed for|Crunched for|✻|✶/ { print "[UI-CHROME] " $0; next }
        /Press Ctrl-C again to .xit/                                        { print "[UI-CHROME] " $0; next }
        /Resume this session with|Resume from summary/                     { print "[UI-CHROME] " $0; next }
        /\/clear to save [0-9.]+k tokens/                                   { print "[UI-CHROME] " $0; next }
        { print }
    '
}

# --- Worktree dir for this window (used by --verify) ---
worktree_dir_for_window() {
    local win="$1"
    if [[ "$win" =~ ^iss-([0-9]+)$ ]]; then
        swarm_worktree_dir "$PROJECT_DIR" "${BASH_REMATCH[1]}"
    else
        printf '%s\n' "$PROJECT_DIR"
    fi
}

if [ -n "$VERIFY_TEXT" ]; then
    WT_DIR="$(worktree_dir_for_window "$WINDOW")"
    SLUG="$(printf '%s' "$WT_DIR" | tr '/' '-')"
    TRANSCRIPT_DIR="$HOME/.claude/projects/$SLUG"

    if [ ! -d "$TRANSCRIPT_DIR" ]; then
        echo "ERROR: no transcript dir for window '$WINDOW' (expected $TRANSCRIPT_DIR)" >&2
        echo "       Worktree does not exist, or this Claude Code session never ran there." >&2
        exit 2
    fi

    # Only a user-role turn's own text counts as "submitted by the user".
    # Excludes assistant turns (a worker report can quote a confirmation
    # phrase without anyone having sent it) and tool_result blocks nested
    # inside user-role messages (tool output, e.g. a captured pane dump, can
    # contain arbitrary text that was never typed by anyone). See #360.
    USER_TEXT_FILTER='
        select(.type == "user") |
        .message.content as $c |
        (
            if ($c | type) == "string" then $c
            elif ($c | type) == "array" then
                ([$c[] | select(.type == "text") | .text] | join("\n"))
            else empty
            end
        ) as $text |
        select($text != null and ($text | contains($needle)))
    '

    MATCHES=""
    for f in "$TRANSCRIPT_DIR"/*.jsonl; do
        [ -e "$f" ] || continue
        if jq -e --arg needle "$VERIFY_TEXT" "$USER_TEXT_FILTER" "$f" >/dev/null 2>&1; then
            MATCHES="${MATCHES}${MATCHES:+$'\n'}$f"
        fi
    done

    if [ -n "$MATCHES" ]; then
        echo "FOUND — text was submitted by the user in a transcript turn:"
        printf '%s\n' "$MATCHES"
        exit 0
    else
        echo "NOT FOUND — text was not submitted by the user in any session transcript under $TRANSCRIPT_DIR"
        echo "It may still appear in the transcript as an assistant turn or tool-result output, or it"
        echo "may exist only as unsubmitted pane content (composer suggestion, recap, or other UI chrome)."
        echo "Either way, treat it as NOT operator/agent input."
        exit 1
    fi
fi

echo "# --- capture-worker.sh: $SESSION:$WINDOW, last ${LINES#-} lines ---"
echo "# Lines tagged [UI-CHROME] are known UI markers, not conversation. Composer"
echo "# suggestions in particular can render as plain text below the last response —"
echo "# never attribute untagged text to the operator without --verify. See"
echo "# docs/tmux-as-channel.md §1c."
echo "# ---------------------------------------------------------------------------"
tmux -L "$SOCKET" capture-pane -t "$SESSION:$WINDOW" -p -S "-$LINES" | strip_ansi | tag_chrome
