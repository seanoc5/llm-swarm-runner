#!/usr/bin/env bash
#
# _coord-inbox-batch.sh — shared inbox wake classification + batching
# (issue #730). Sourced by coord-inbox-wait.sh, coord-hook.sh and
# coordinator-watch.sh; defines functions only, prints nothing when sourced.
#
# Why: a coordinator woken for every idle_capacity / ok-outcome / fyi item
# spent most of its tokens on replies that changed nothing for the operator.
# Urgent kinds still wake at once; everything else collects and wakes the
# coordinator at most once per COORD_INBOX_BATCH_SECS (default 900; 0 = off,
# every item wakes as before).
#
# Item files are named <UTC-ts>-<kind>-<pid>-<rand>.md (coord_inbox_write).
#
# URGENT (wake at once; also flushes whatever is queued):
#   deliver_stall stranded_brief worktree_vanished sidelined_worker
#   sidelined_wake_failed stall
#   outcome whose triggering path is not an *.ok.json (err.json, unknown)
#   outbox whose message says kind: decision-needed, or reports red CI
# BATCHED:
#   idle_capacity activity dispatch_pause_lifted stale_wait
#   outcome *.ok.json, outbox kind: fyi / brief-draft (no red-CI text)
# Anything else, and anything whose body can't be read, is URGENT: an
# unclassifiable item must never be delayed.

# COORD_QUIET_WAKES (default 1) is the master switch: 0 turns batching off
# and drops the "Woke for:" suffix, which is also the cue the coordinator
# prompt keys its quiet-reply rule on, so one setting reverts everything.

# coord_last_ring_at <swarm-dir>: epoch of the last ring, 0 when none. The
# newer of coord-hook-rang (waiter / Stop hook) and coord-typed-ring (the
# watcher's own typed doorbell, issue #743). The typed ring has its own file
# on purpose: the watcher's "the hook already rang this wake" skip reads
# coord-hook-rang, and a typed ring that failed to paste must not count there.
coord_last_ring_at() {
    local a b
    a="$(cut -d' ' -f1 "$1/coord-hook-rang" 2>/dev/null || echo 0)"
    b="$(cut -d' ' -f1 "$1/coord-typed-ring" 2>/dev/null || echo 0)"
    [[ "$a" =~ ^[0-9]+$ ]] || a=0
    [[ "$b" =~ ^[0-9]+$ ]] || b=0
    echo $(( a > b ? a : b ))
}

# coord_batch_secs: echoes the effective batch window in seconds (0 = off).
coord_batch_secs() {
    [ "${COORD_QUIET_WAKES:-1}" = "0" ] && { echo 0; return 0; }
    local v="${COORD_INBOX_BATCH_SECS:-900}"
    if [[ "$v" =~ ^[0-9]+$ ]]; then echo $((10#$v)); else echo 900; fi
}

# coord_item_kind <file>: echoes the kind encoded in the filename, or nothing.
coord_item_kind() {
    local b="${1##*/}"
    if [[ "$b" =~ ^[0-9]{8}T[0-9]{6}Z-([a-z_]+)-[0-9]+-[0-9]+\.md$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    fi
}

# coord_item_urgency <file>: echoes "urgent" or "batched".
coord_item_urgency() {
    local f="$1" kind body msg
    kind="$(coord_item_kind "$f")"
    case "$kind" in
        idle_capacity|activity|dispatch_pause_lifted|stale_wait)
            echo batched; return 0 ;;
        outcome)
            # Batched only when the body positively names an ok outcome file.
            if grep -Eq 'path=[^[:space:]]*\.ok\.json([[:space:]]|$)' "$f" 2>/dev/null; then
                echo batched
            else
                echo urgent
            fi
            return 0 ;;
        outbox)
            body="$(cat "$f" 2>/dev/null)" || { echo urgent; return 0; }
            msg="$(printf '%s\n' "$body" | sed -nE 's/^Triggering message: //p' | tail -n 1)"
            # The coordinator archives a handled message to processed/ mid-turn;
            # classify it from there rather than turning a fyi urgent.
            if [ -n "$msg" ] && [ ! -r "$msg" ] && [ -r "${msg%/*}/processed/${msg##*/}" ]; then
                msg="${msg%/*}/processed/${msg##*/}"
            fi
            if [ -n "$msg" ] && [ -r "$msg" ]; then
                if grep -Eiq '(^|[^a-z])(red[ -]ci|ci[ :]*(is )?(red|failing|failed)|checks? (are )?(red|failing|failed))' "$msg" 2>/dev/null; then
                    echo urgent; return 0
                fi
                if grep -Eq '^kind:[[:space:]]*(fyi|brief-draft)[[:space:]]*$' "$msg" 2>/dev/null; then
                    echo batched; return 0
                fi
            fi
            echo urgent; return 0 ;;
        *)
            echo urgent; return 0 ;;
    esac
}

# coord_inbox_scan <inbox-dir> <last_rang> [skip_activity]
#
# Sets globals: CIB_URGENT / CIB_BATCHED = counts of wake-eligible items newer
# than <last_rang> (the last ring, by the waiter or the Stop hook), i.e. not
# yet announced; CIB_TOTAL = every *.md file in the inbox.
# No "newer than the waiter's arming" guard: an item that landed during a turn
# whose Stop hook was skipped (stop_hook_active) is unannounced, and must ring
# when the waiter re-arms rather than wait out the typed fallback.
# skip_activity=1: activity-poll items are inbox-only and never trigger.
coord_inbox_scan() {
    local dir="$1" last="$2" skip_act="${3:-0}" f m
    CIB_URGENT=0 CIB_BATCHED=0 CIB_TOTAL=0
    for f in "$dir"/*.md; do
        [ -f "$f" ] || continue
        CIB_TOTAL=$((CIB_TOTAL + 1))
        [ "$skip_act" = 1 ] && [ "$(coord_item_kind "$f")" = activity ] && continue
        m="$(stat -c %Y "$f" 2>/dev/null || echo 0)"
        [ "$m" -gt "$last" ] || continue
        if [ "$(coord_item_urgency "$f")" = urgent ]; then
            CIB_URGENT=$((CIB_URGENT + 1))
        else
            CIB_BATCHED=$((CIB_BATCHED + 1))
        fi
    done
    return 0
}

# coord_batch_due <last_rang> <now>: true when the batch window has elapsed
# since the last ring (or batching is off).
coord_batch_due() {
    local secs
    secs="$(coord_batch_secs)"
    [ "$secs" -eq 0 ] || [ $(($2 - $1)) -ge "$secs" ]
}

# coord_should_ring: after coord_inbox_scan, true when a wake is due now:
# any urgent item, or batched items once the window has elapsed.
# Args: <last_rang> <now>
coord_should_ring() {
    [ "${CIB_URGENT:-0}" -gt 0 ] && return 0
    [ "${CIB_BATCHED:-0}" -gt 0 ] && coord_batch_due "$1" "$2"
}

# coord_woke_for <inbox-dir> <last_rang>: one-line summary of what is queued
# since the last ring, e.g. "2 outcome, 1 idle capacity".
coord_woke_for() {
    local dir="$1" last="$2" f m k out="" kinds=()
    declare -A n=()
    [ "${COORD_QUIET_WAKES:-1}" = "0" ] && return 0
    for f in "$dir"/*.md; do
        [ -f "$f" ] || continue
        m="$(stat -c %Y "$f" 2>/dev/null || echo 0)"
        [ "$m" -gt "$last" ] || continue
        k="$(coord_item_kind "$f")"; k="${k:-other}"
        [ -n "${n[$k]:-}" ] || kinds+=("$k")
        n[$k]=$(( ${n[$k]:-0} + 1 ))
    done
    for k in "${kinds[@]}"; do
        out+="${out:+, }${n[$k]} ${k//_/ }"
    done
    printf '%s\n' "$out"
}
