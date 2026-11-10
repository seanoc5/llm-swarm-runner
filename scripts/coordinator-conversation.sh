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
#                    hide (use \A/\z for whole-message matches), appended to
#                    the built-in doorbell list.
#      CLAUDE_PROJECTS_DIR  override ~/.claude/projects (tests).
#
# Session choice: newest top-level *.jsonl in that dir whose entrypoint is
# `cli` (interactive). Headless `claude -p` runs (self-review etc.) record
# `sdk-cli` and are skipped. A restart, /clear or compaction that starts a
# new file is followed automatically.
#
# Shown:  user records and queued_command attachments (messages typed while
#         the coordinator was mid-turn) with origin.kind "human" whose text is not a typed
#         doorbell (see HIDE_RE), and the text blocks of assistant records.
# Hidden: tool calls/results, thinking, doorbell nudges (whole-message match
#         on "Inbox:" and wake prompts; the stop hook's reason is the same
#         nudge), task notifications, peer messages,
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
# Like human_typed_since (scripts/coordinator-watch.sh, issue #497) this
# matches the WHOLE message against the doorbell's exact wording, never a
# prefix or a last line: an operator message that starts with a doorbell
# phrase ("Stop hook is broken, fix it"), shares a turn with a doorbell, or
# finishes on the doorbell's own line ("Continue your task from where you
# left off. Also merge PR 12") must stay visible. No wildcard tails: the only
# variable parts allowed are the ones the senders really append -- the inbox
# nudge's " Woke for: 2 outbox, 1 ci." (coord_woke_for) and the Stop hook's
# waiter-arm sentence (coord-hook.sh waiter_arm_request). Oniguruma's ^/$ are
# per-line anchors, so use \A and \z.
# Each wording is the default of the template that sends it:
# COORD_INBOX_NUDGE_TEMPLATE, WAKE_PROMPT, STALL_WAKE_PROMPT, llm-start.sh's
# INITIAL_PROMPT, WORKER_COMPACT_NUDGE_PROMPT, and the activity-poll body. A
# swarm that overrides one of these env knobs gets that doorbell shown, not
# hidden; add its wording via CONV_HIDE_RE.
# The tag/summary prefixes are Claude Code's own wrappers, never typed.
WOKE_RE=' Woke for: [0-9]+ [^,.\n]+(, [0-9]+ [^,.\n]+)*\.'
ARM_RE=' Arm the inbox waiter: run (\\.|[^\s\\])+ (\\.|[^\s\\])+ with run_in_background \(Bash\), then end your turn\. It wakes you when an inbox item lands; nothing more to do with it until then\.'
HIDE_RE='\A\s*(Inbox: [0-9]+ item\(s\) in \.swarm/coord-inbox/ — read and triage them \(see prompts/coordinator\.md "Inbox"\)\.'"($WOKE_RE)?($ARM_RE)?"
HIDE_RE+='|Worker\(s\) just finished\. Triage their outcome JSONs in worktrees/\.swarm/tasks/done/, then top up workers per the Initial Startup Checklist \(compute AVAILABLE, count alive workers, fill open slots up to MAX_WORKERS subject to MAX_TMUX_WINDOWS\)\. Use the @me-or-unassigned filter unless INCLUDE_ASSIGNED_TO_OTHERS=1\.'
HIDE_RE+='|Quiet-period check-in: no coordinator wake has been delivered for at least [0-9]+s\. That only proves no doorbell landed in that window — it does NOT mean workers are idle; a swarm with live workers still on long tasks can look exactly like this\. Verify actual worker/PR state before concluding the swarm is idle\. Produce a short wake digest \(swarm state: live workers, open PRs/issues, anything blocked\) and suggest next steps — or say plainly that there is nothing to do right now\.'
HIDE_RE+='|Execute the Initial Startup Checklist\.'
HIDE_RE+='|Continue your task from where you left off\.'
HIDE_RE+='|A periodic gh-search poll \(issue #392\) found GitHub activity[\s\S]*pending on these\.'
HIDE_RE+=')\s*\z'
HIDE_RE+='|\A\s*(<task-notification>|<local-command|<command-name>|<system-reminder>)'
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
    jq -R -r --arg re "$HIDE_RE" --arg cy "$C_YOU" --arg cb "$C_BOT" --arg cd "$C_DIM" --arg cr "$C_RST" '
        def hhmm: (.timestamp // "" | sub("\\.[0-9]+Z$"; "Z")
                   | try (fromdateiso8601 | localtime | strftime("%H:%M")) catch "");
        def texts: if (.message.content | type) == "string" then .message.content
                   else [.message.content[]? | select(.type == "text") | .text] | join("\n") end;
        def show: select((.isSidechain // false) | not)
        | if .type == "attachment" then
            # A message typed while the coordinator is mid-turn is recorded
            # only as a queued_command attachment (no user record follows).
            select(.attachment.type == "queued_command" and .attachment.origin.kind == "human"
                   and (.attachment.prompt | type) == "string")
            | (.attachment.prompt | sub("\\A\\s+"; "") | sub("\\s+\\z"; "")) as $t
            | select($t != "" and ($t | test($re) | not))
            | "\($cy)── you · \(hhmm) ──\($cr)\n\($t)\n\u001e"
          elif .type == "user" then
            select(.origin.kind == "human" and ((.isMeta // false) | not)
                   and ((.isCompactSummary // false) | not))
            | (texts | sub("\\A\\s+"; "") | sub("\\s+\\z"; "")) as $t
            | select($t != "" and ($t | test($re) | not))
            | "\($cy)── you · \(hhmm) ──\($cr)\n\($t)\n\u001e"
          elif .type == "assistant" then
            select(.message.model != "<synthetic>")
            | (texts | sub("\\A\\s+"; "") | sub("\\s+\\z"; "")) as $t
            | select($t != "")
            | "\($cb)── coordinator · \(hhmm) ──\($cr)\n\($t)\n\u001e"
          else empty end;
        # One corrupt or non-object line is skipped with a visible warning; it
        # must not end the batch (a bare `jq` parse error drops every later line).
        select(test("\\S"))
        | . as $raw
        | (try ($raw | fromjson) catch null) as $r
        | if ($r | type) == "object" then ($r | show)
          else "\($cd)── skipped an unparseable transcript line ──\($cr)\n\u001e" end
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
        if [ "$(jq -r 'select(.entrypoint != null) | .entrypoint' "$f" 2>/dev/null | sed -n 1p)" = "cli" ]; then
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
declare -A seen=()

# Render whatever whole lines were appended since $offset; keep only the last
# $1 messages when given. A trailing partial line waits for its newline.
consume() {
    local size len part
    size="$(stat -c %s "$cur" 2>/dev/null || echo 0)"
    [ "$size" -gt "$offset" ] || return 0
    len=$((size - offset))
    if [ -n "$(tail -c1 "$cur")" ]; then
        # head -c reads the file directly (no pipe reader quits early), so a file
        # that grew since `stat` cannot SIGPIPE the producer.
        part="$(head -c "$size" "$cur" | tail -c "$len" | tail -n1 | LC_ALL=C wc -c || true)"
        len=$((len - part))
    fi
    [ "$len" -gt 0 ] || return 0
    { head -c "$size" "$cur" | tail -c "$len" | render | emit "${1:-}"; } || true
    offset=$((offset + len))
}

[ -z "$cur" ] || consume "$TAIL"
[ "$ONCE" = 1 ] && exit 0

while :; do
    sleep "$INTERVAL"
    next="$(pick || true)"
    [ -n "$next" ] || continue
    if [ "$next" != "$cur" ]; then
        # Flush the old transcript first: a reply written just before a restart
        # or /clear would otherwise be dropped (issue #764).
        [ -z "$cur" ] || { consume ""; seen["$cur"]=$offset; }
        if [ -n "${seen[$next]+x}" ]; then
            # Two live sessions take turns as "newest"; resume the one we
            # already showed where we left off instead of replaying it.
            cur="$next" offset="${seen[$next]}"
            consume ""
            continue
        fi
        [ -z "$cur" ] || printf '%s── new session ──%s\n\n' "$C_DIM" "$C_RST"
        cur="$next" offset=0
        # A session new to the reader shows its last --tail messages (20 when
        # --tail 0), so a resumed old session is not replayed.
        consume "$(( TAIL > 0 ? TAIL : 20 ))"
        continue
    fi
    consume ""
done
