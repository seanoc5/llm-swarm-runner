#!/usr/bin/env bash
# coord-hook.sh — Claude Code hook for the coordinator session (issue #666).
#
# Installed by coordinator-claude.sh via `claude --settings` when
# COORD_HOOK_STATE=1, so it runs for the coordinator process only — never
# for workers or for an operator's ad-hoc `claude` in the same project.
#
# Two jobs, both replacing a screen read in coordinator-watch.sh:
#
#   1. State file. Writes "<state> <epoch>" to .swarm/coordinator-state:
#        UserPromptSubmit -> busy     (a turn started)
#        Stop             -> idle     (the turn ended)
#        Notification     -> waiting  (permission / idle prompt)
#      The watcher reads it instead of matching spinner text on the pane.
#
#   2. Doorbell at turn end. On Stop, if coord-inbox/ holds items newer than
#      the last ring, the hook returns {"decision":"block","reason":<nudge>}
#      and Claude Code continues the turn with the nudge as input — nothing
#      is typed into the composer, so a half-typed operator draft is never
#      at risk. The ring is recorded in .swarm/coord-hook-rang so the
#      watcher treats that wake as delivered instead of pasting it again.
#      stop_hook_active=true (we already rang once this turn end) never
#      rings again, so this cannot loop.
#
#   2b. Dead-watcher WARN (issue #756). On Stop, if watcher-check.sh says this
#      project's coordinator-watch.sh is gone (and not stopped on purpose),
#      the WARN with the restart command rides the doorbell or is sent on its
#      own, at most once per WATCHER_DEAD_WARN_SECS (default 1800), so the
#      coordinator's next turn shows it and tells the operator.
#
#   3. Inbox waiter (COORD_INBOX_WAITER=1). An idle coordinator fires no
#      hooks, so coord-inbox-wait.sh runs as its background shell and wakes
#      it when an item lands. When no waiter is running, Stop asks the
#      coordinator to arm one (appended to the doorbell, or on its own).
#      An ask the coordinator hasn't answered (the waiter deletes
#      coord-waiter-asked when it arms) isn't repeated for
#      COORD_INBOX_WAITER_ASK_SECS, so a coordinator that can't arm it
#      never loops.
#
#   4. Split mode (COORD_MODE=split in .swarm/.env, issue #767). The session is a conversation
#      nobody wakes, so Stop never rings and never asks for a waiter. On
#      UserPromptSubmit the hook adds one line of context when
#      .swarm/needs-you.md changed since it last told the operator's session,
#      and clears the 📥 window flag (see _coord-split.sh). The same hook
#      prepends the dead-watcher WARN (2b) on every operator message while the
#      watcher is dead (issue #779); Stop never reaches it. Active even with
#      COORD_HOOK_STATE=0; state-file writes still need COORD_HOOK_STATE=1.
#
#   5. Reply lint (issue #798, ADR 0007). On Stop, the coordinator's last reply
#      goes through lint-coordinator-reply.sh: an action item that points at
#      text off the screen ("command above", "details in .swarm/needs-you.md"),
#      a run/start/click item with no command or URL, or two closing lines
#      blocks the stop once with the findings, so the coordinator reprints
#      the actions in full (needs-you.sh render). Every hit is counted in
#      events.log: coord.reply_lint.hit (blocked) / coord.reply_lint.unfixed
#      (still failing after the nudge; stop_hook_active, so no second block).
#      COORD_REPLY_LINT=0 turns it off. Runs in split mode too.
#
# Fails open: any error leaves the hook silent (exit 0, no output), which
# Claude Code treats as "no opinion" — the watcher then falls back to its
# screen-based checks because the state file goes stale.

set -uo pipefail

event="${1:-}"
input="$(cat 2>/dev/null || true)"
# shellcheck source=scripts/_coord-split.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_coord-split.sh"
project="${CLAUDE_PROJECT_DIR:-$PWD}"
hook_state=0; [ "${COORD_HOOK_STATE:-0}" = "1" ] && hook_state=1
split=0; [ "$(coord_mode "$project")" = "split" ] && split=1
lint_on=1; [ "${COORD_REPLY_LINT:-1}" = "0" ] && lint_on=0
[ "$hook_state" = "1" ] || [ "$split" = "1" ] || [ "$lint_on" = "1" ] || exit 0

swarm="$project/.swarm"
[ -d "$swarm" ] || exit 0

state_file="$swarm/coordinator-state"
rang_file="$swarm/coord-hook-rang"
inbox="$swarm/coord-inbox"
events="$swarm/events.log"
# Must match coordinator-watch.sh's COORD_INBOX_NUDGE_TEMPLATE default
# (tests/test-coord-hook.sh asserts it): the watcher recognises its own
# doorbell by this text.
template="${COORD_INBOX_NUDGE_TEMPLATE:-Inbox: %N item(s) in .swarm/coord-inbox/ — read and triage them (see prompts/coordinator.md \"Inbox\").}"

now="$(date +%s)"
# shellcheck source=scripts/_coord-inbox-batch.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_coord-inbox-batch.sh"
# shellcheck source=scripts/_window-flags.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_window-flags.sh"
SESSION_NAME="${SESSION_NAME:-llm-$(basename "$project")}"

write_state() {
    local tmp
    tmp="$(mktemp "$swarm/.tmp.coordinator-state.XXXXXX" 2>/dev/null)" || return 0
    printf '%s %s\n' "$1" "$now" > "$tmp" && mv -f "$tmp" "$state_file" || rm -f "$tmp"
}

log_event() {
    printf '%s  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$events" 2>/dev/null || true
}

# waiter_arm_request: prints the "arm the waiter" sentence when
# COORD_INBOX_WAITER=1, no live waiter heartbeat exists, and no unanswered ask
# is younger than COORD_INBOX_WAITER_ASK_SECS; records the ask. Prints
# nothing otherwise.
waiter_arm_request() {
    [ "${COORD_INBOX_WAITER:-0}" = "1" ] || return 0
    # Issue #743: the waiter runs via run_in_background, which does not exist
    # when background tasks are disabled (the default since #715). Asking for
    # it would only waste a turn; the watcher batches by typing instead.
    [ "${CLAUDE_CODE_DISABLE_BACKGROUND_TASKS:-0}" = "1" ] && return 0
    local pid_file="$swarm/coord-inbox-waiter" asked_file="$swarm/coord-waiter-asked"
    local pid m asked
    if read -r pid _ 2>/dev/null < "$pid_file" && [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
        m="$(stat -c %Y "$pid_file" 2>/dev/null || echo 0)"
        [ $((now - m)) -le "${COORD_INBOX_WAITER_STALE_SECS:-30}" ] && return 0
    fi
    asked="$(cat "$asked_file" 2>/dev/null || echo 0)"
    [[ "$asked" =~ ^[0-9]+$ ]] || asked=0
    [ $((now - asked)) -ge "${COORD_INBOX_WAITER_ASK_SECS:-300}" ] || return 0
    printf '%s\n' "$now" > "$asked_file" 2>/dev/null || true
    log_event "coord.waiter.ask"
    printf 'Arm the inbox waiter: run %s %s with run_in_background (Bash), then end your turn. It wakes you when an inbox item lands; nothing more to do with it until then.' \
        "$(printf '%q' "$(cd "$(dirname "$0")" && pwd)/coord-inbox-wait.sh")" "$(printf '%q' "$project")"
}

# watcher_dead_warning [min-secs]: prints the one-line WARN (restart command
# included) when the watcher is dead and none was sent in the last min-secs
# (default WATCHER_DEAD_WARN_SECS, 1800); records the send. Prints nothing
# otherwise. Split mode passes 0: every operator message carries the WARN.
watcher_dead_warning() {
    local warned_file="$swarm/watcher-dead-warned" warned out min_secs="${1:-${WATCHER_DEAD_WARN_SECS:-1800}}"
    out="$("$(cd "$(dirname "$0")" && pwd)/watcher-check.sh" "$project" 2>/dev/null)" || true
    [ -n "$out" ] || { rm -f "$warned_file" 2>/dev/null; return 0; }
    warned="$(cat "$warned_file" 2>/dev/null || echo 0)"
    [[ "$warned" =~ ^[0-9]+$ ]] || warned=0
    [ $((now - warned)) -ge "$min_secs" ] || return 0
    printf '%s\n' "$now" > "$warned_file" 2>/dev/null || true
    log_event "coord.watcher_dead.warn"
    printf '%s' "$out" | tr '\n' ' '
}

# reply_lint_message: prints the block reason when the last reply fails
# lint-coordinator-reply.sh (and logs the hit); nothing otherwise. The reply is
# the hook input's last_assistant_message, else the last assistant text block
# of its transcript.
reply_lint_message() {
    [ "${COORD_REPLY_LINT:-1}" = "0" ] && return 0
    local text tp hits rules
    [ "$active" = "true" ] || rm -f "$swarm/coord-lint-blocked" 2>/dev/null || true   # new reply chain
    text="$(printf '%s' "$input" | jq -r '.last_assistant_message // empty' 2>/dev/null || true)"
    if [ -z "$text" ]; then
        tp="$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
        [ -n "$tp" ] && [ -r "$tp" ] && text="$(jq -rs '[.[] | select(.type == "assistant") | [.message.content[]? | select(.type == "text") | .text] | select(length > 0) | join("\n")] | last // empty' "$tp" 2>/dev/null || true)"
    fi
    [ -n "$text" ] || return 0
    hits="$(printf '%s\n' "$text" | "$(cd "$(dirname "$0")" && pwd)/lint-coordinator-reply.sh" --project "$project" 2>/dev/null)" && return 0
    [ -n "$hits" ] || return 0
    rules="$(printf '%s\n' "$hits" | cut -d: -f1 | sort -u | paste -sd, -)"
    # Block at most once per reply chain: a continuation (stop_hook_active) is
    # still linted unless this chain's earlier block was itself a lint block.
    # A doorbell/arm block does not count, so the wake digest that follows it
    # gets linted (issue #798 review).
    local blocked_file="$swarm/coord-lint-blocked"
    if [ "$active" = "true" ] && [ -e "$blocked_file" ]; then
        log_event "coord.reply_lint.unfixed rules=$rules"
        return 0
    fi
    : > "$blocked_file" 2>/dev/null || true
    log_event "coord.reply_lint.hit rules=$rules"
    printf 'Reply lint failed (%s). Fix before ending your turn: every operator action must carry its full command (fenced) or https URL plus click path in this reply; never point at an earlier message, "above" or .swarm/needs-you.md; end with exactly one closing line. Reprint with: scripts/needs-you.sh render. Offending lines: %s' \
        "$rules" "$(printf '%s' "$hits" | sed -n 1,3p | tr '\n' '|')"
}

case "$event" in
    UserPromptSubmit)
        [ "$hook_state" = "1" ] && write_state busy
        if [ "$split" = "1" ]; then
            # COORD_MODE=split (issue #767): this session is never woken, so the
            # operator's next message is where a changed Needs-you list reaches it.
            clear_window_flag coordinator "📥" "operator_prompt"
            note="$(coord_needs_you_note "$swarm")"
            dead="$(watcher_dead_warning 0)"   # issue #779: a dead watcher must not stay silent in split mode
            [ -z "$dead" ] || note="$dead${note:+ $note}"
            [ -z "$note" ] || jq -n --arg c "$note" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $c}}'
        fi
        ;;
    Notification)     [ "$hook_state" = "1" ] && write_state waiting ;;
    Stop)
        active="$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null || echo false)"
        lint="$(reply_lint_message)"
        # Split mode never rings: nothing is typed into or blocked on this session
        # (only the reply lint can block it). The same holds for a resident
        # coordinator with COORD_HOOK_STATE=0: lint only, no state, no doorbell.
        if [ "$split" = "1" ] || [ "$hook_state" = "0" ]; then
            if [ -n "$lint" ]; then
                [ "$hook_state" = "1" ] && write_state busy
                jq -n --arg r "$lint" '{decision: "block", reason: $r}'
            else
                [ "$hook_state" = "1" ] && write_state idle
            fi
            exit 0
        fi
        last_rang="$(coord_last_ring_at "$swarm")"
        # Same urgent-vs-batched gate as coord-inbox-wait.sh (issue #730).
        coord_inbox_scan "$inbox" "$last_rang"
        count="$CIB_TOTAL"
        dead=""
        [ "$active" != "true" ] && dead="$(watcher_dead_warning)"
        woke="$(coord_woke_for "$inbox" "$last_rang")"
        if [ "$active" != "true" ] && [ "$count" -gt 0 ] && [ $((CIB_URGENT + CIB_BATCHED)) -gt 0 ] \
                && coord_should_ring "$last_rang" "$now"; then
            printf '%s %s\n' "$now" "$count" > "$rang_file" 2>/dev/null || true
            # Same debounce clock the watcher stamps when it rings.
            printf '%s\n' "$now" > "$swarm/coord-wake-last" 2>/dev/null || true
            write_state busy
            log_event "coord.wake.hook_rang items=$count urgent=$CIB_URGENT batched=$CIB_BATCHED"
            arm="$(waiter_arm_request)"
            jq -n --arg r "${template//%N/$count}${woke:+ Woke for: $woke.}${arm:+ $arm}${dead:+ $dead}${lint:+ $lint}" '{decision: "block", reason: $r}'
        elif [ -n "$lint" ]; then
            write_state busy
            arm="$(waiter_arm_request)"
            jq -n --arg r "$lint${arm:+ $arm}${dead:+ $dead}" '{decision: "block", reason: $r}'
        elif arm="$(waiter_arm_request)" && [ -n "$arm" ]; then
            write_state busy
            jq -n --arg r "$arm${dead:+ $dead}" '{decision: "block", reason: $r}'
        elif [ -n "$dead" ]; then
            write_state busy
            jq -n --arg r "$dead Tell the operator; do not restart it yourself unless asked." '{decision: "block", reason: $r}'
        else
            write_state idle
        fi
        ;;
esac
exit 0
