#!/usr/bin/env bash
# coordinator-conversation.sh — read-only, clean view of a coordinator
# conversation: only the operator's messages and the coordinator's reply text,
# read from the Claude Code session transcript (issue #744). The coordinator
# pane stays the debugging record; you still type there.
#
# Usage:
#   coordinator-conversation.sh [PROJECT_DIR] [--tail N] [--once] [--interval S]
#   coordinator-conversation.sh --file TRANSCRIPT.jsonl [--once]
#
#   PROJECT_DIR   swarm project (default: current dir; a worktree resolves to
#                 its main checkout). The coordinator runs in PROJECT_DIR, so
#                 its transcripts live in ~/.claude/projects/<encoded-dir>/.
#                 Worker transcripts live under their own worktree dirs and
#                 are never read.
#   --tail N      show the last N messages first (default 20; 0 = only new)
#   --once        print and exit instead of following
#   --interval S  poll period while following (default 2)
#   --file F      read this transcript instead of auto-detecting (no
#                 session switching)
#
# Env: CONV_HIDE_RE  extra ERE (jq/Oniguruma) of operator-message starts to
#                    hide, appended to the built-in doorbell list.
#      CLAUDE_PROJECTS_DIR  override ~/.claude/projects (tests).
#
# Session choice: newest top-level *.jsonl in that dir whose entrypoint is
# `cli` (interactive). Headless `claude -p` runs (self-review etc.) record
# `sdk-cli` and are skipped. A restart, /clear or compaction that starts a
# new file is followed automatically.
#
# Shown:  user records with origin.kind "human" whose text is not a typed
#         doorbell (see HIDE_RE), and the text blocks of assistant records.
# Hidden: tool calls/results, thinking, doorbell nudges ("Inbox:", wake
#         prompts), stop-hook text, task notifications, peer messages,
#         slash-command output, compaction summaries, subagent turns.
#
# Never writes to the transcript, the pane or the inbox.

set -euo pipefail

command -v jq >/dev/null || { echo "coordinator-conversation.sh: jq is required" >&2; exit 2; }

TAIL=20 ONCE=0 INTERVAL=2 FILE="" PROJECT=""
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
        --tail)     TAIL="${2:?--tail needs a number}"; shift 2 ;;
        --once)     ONCE=1; shift ;;
        --interval) INTERVAL="${2:?--interval needs seconds}"; shift 2 ;;
        --file)     FILE="${2:?--file needs a path}"; shift 2 ;;
        -*)         echo "coordinator-conversation.sh: unknown option $1" >&2; exit 2 ;;
        *)          PROJECT="$1"; shift ;;
    esac
done
case "$TAIL" in ''|*[!0-9]*) echo "coordinator-conversation.sh: --tail must be a number" >&2; exit 2 ;; esac

# Typed doorbells are recorded as ordinary human messages, so match on text.
HIDE_RE='^\s*(Inbox: [0-9]+ item|Worker\(s\) just finished|Quiet-period check-in|Execute the Initial Startup Checklist|A periodic gh-search poll|Continue your task from where you left off|Stop hook|<task-notification>|<local-command|<command-name>|<system-reminder>|This session is being continued)|Woke for: [^\n]*$'
[ -n "${CONV_HIDE_RE:-}" ] && HIDE_RE="$HIDE_RE|$CONV_HIDE_RE"

# A bad CONV_HIDE_RE would make jq fail and blank every message; refuse it.
jq -n --arg re "$HIDE_RE" '"" | test($re)' >/dev/null 2>&1 \
    || { echo "coordinator-conversation.sh: CONV_HIDE_RE is not a valid regex" >&2; exit 2; }

if [ -t 1 ]; then
    C_YOU=$'\033[1;36m' C_BOT=$'\033[1;33m' C_DIM=$'\033[2m' C_RST=$'\033[0m'
else
    C_YOU="" C_BOT="" C_DIM="" C_RST=""
fi

# Stream of rendered messages from JSONL on stdin. A message prints as a
# marker line, its text, then a blank line; the NUL-free "\u001e" record
# separator lets --tail count messages rather than lines.
render() {
    jq -r --arg re "$HIDE_RE" --arg cy "$C_YOU" --arg cb "$C_BOT" --arg cd "$C_DIM" --arg cr "$C_RST" '
        def hhmm: (.timestamp // "" | sub("\\.[0-9]+Z$"; "Z")
                   | try (fromdateiso8601 | localtime | strftime("%H:%M")) catch "");
        def texts: if (.message.content | type) == "string" then .message.content
                   else [.message.content[]? | select(.type == "text") | .text] | join("\n") end;
        select((.isSidechain // false) | not)
        | if .type == "user" then
            select(.origin.kind == "human" and ((.isMeta // false) | not)
                   and ((.isCompactSummary // false) | not))
            | (texts | sub("^\\s+"; "") | sub("\\s+$"; "")) as $t
            | select($t != "" and ($t | test($re) | not))
            | "\($cy)── you · \(hhmm) ──\($cr)\n\($t)\n\u001e"
          elif .type == "assistant" then
            select(.message.model != "<synthetic>")
            | (texts | sub("^\\s+"; "") | sub("\\s+$"; "")) as $t
            | select($t != "")
            | "\($cb)── coordinator · \(hhmm) ──\($cr)\n\($t)\n\u001e"
          else empty end
    ' 2>/dev/null || true
}

# Print the stream with record separators removed, keeping only the last
# $1 messages (all when $1 is empty).
emit() {
    local keep="${1:-}"
    awk -v keep="$keep" 'BEGIN { RS = "\x1e"; ORS = "" } $0 ~ /^[ \n]*$/ { next } { m[++n] = $0 } END {
        s = (keep == "" || keep + 0 >= n) ? 1 : n - keep + 1
        for (i = s; i <= n; i++) { sub(/^\n/, "", m[i]); print m[i] "\n" }
    }'
}

pick_session() {
    local dir="$1" f
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        if [ "$(jq -r 'select(.entrypoint != null) | .entrypoint' "$f" 2>/dev/null | head -n1)" = "cli" ]; then
            printf '%s\n' "$f"; return 0
        fi
    done < <(ls -t "$dir"/*.jsonl 2>/dev/null)
    return 1
}

if [ -n "$FILE" ]; then
    [ -r "$FILE" ] || { echo "coordinator-conversation.sh: cannot read $FILE" >&2; exit 2; }
    pick() { printf '%s\n' "$FILE"; }
else
    PROJECT="$(cd "${PROJECT:-.}" && pwd -P)"
    common="$(git -C "$PROJECT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    if [ -n "$common" ] && [ "$(basename "$common")" = ".git" ]; then PROJECT="$(dirname "$common")"; fi
    SLUG="$(printf '%s' "$PROJECT" | sed 's/[^A-Za-z0-9]/-/g')"
    TDIR="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}/$SLUG"
    pick() { pick_session "$TDIR"; }
    if [ ! -d "$TDIR" ]; then
        echo "coordinator-conversation.sh: no transcript dir $TDIR (has a Claude Code session run in $PROJECT?)" >&2
        exit 2
    fi
fi

cur="$(pick || true)"
if [ -z "$cur" ]; then
    [ "$ONCE" = 1 ] && { echo "coordinator-conversation.sh: no interactive session transcript found" >&2; exit 1; }
    echo "${C_DIM}waiting for a coordinator session transcript...${C_RST}" >&2
fi

offset=0

# Render whatever whole lines were appended since $offset; keep only the last
# $1 messages when given. A trailing partial line waits for its newline.
consume() {
    local size len part
    size="$(stat -c %s "$cur" 2>/dev/null || echo 0)"
    [ "$size" -gt "$offset" ] || return 0
    len=$((size - offset))
    if [ -n "$(tail -c1 "$cur")" ]; then
        # `head -c` closes the pipe before `tail` finishes when the file has
        # grown since `stat`; that SIGPIPE must not end follow mode.
        part="$(tail -c +"$((offset + 1))" "$cur" | head -c "$len" | tail -n1 | LC_ALL=C wc -c || true)"
        len=$((len - part))
    fi
    [ "$len" -gt 0 ] || return 0
    { tail -c +"$((offset + 1))" "$cur" | head -c "$len" | render | emit "${1:-}"; } || true
    offset=$((offset + len))
}

[ -z "$cur" ] || consume "$TAIL"
[ "$ONCE" = 1 ] && exit 0

while :; do
    sleep "$INTERVAL"
    next="$(pick || true)"
    [ -n "$next" ] || continue
    if [ "$next" != "$cur" ]; then
        [ -z "$cur" ] || printf '%s── new session ──%s\n\n' "$C_DIM" "$C_RST"
        cur="$next" offset=0
        # A switched-to session is new to the reader: show its last --tail
        # messages (20 when --tail 0), so a resumed old session is not replayed.
        consume "$(( TAIL > 0 ? TAIL : 20 ))"
        continue
    fi
    consume ""
done
