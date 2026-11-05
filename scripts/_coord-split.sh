#!/usr/bin/env bash
#
# _coord-split.sh — helpers for COORD_MODE=split (issue #767, ADR 0006).
# Sourced by coordinator-watch.sh and coord-hook.sh; defines functions only.
#
# In split mode the coordinator window is a conversation session nobody types
# into but the operator, so changes reach the operator without waking it:
#   - the window flag 📥 on the coordinator window for urgent inbox kinds
#     (coord_split_flag_urgent, set by the watcher as it writes the item);
#   - a UserPromptSubmit hook line when .swarm/needs-you.md changed
#     (coord_needs_you_note, called by coord-hook.sh on the operator's next
#     message; it also clears the flag, since the operator is looking now).

# COORD_MODE has one source of truth: the project's .swarm/.env file. Every
# reader (llm-start.sh and so every wake, coordinator-claude.sh, coord-hook.sh,
# the watcher) calls these each time it needs the mode, so an edit to the file
# takes effect at the reader's next call. The caller's env and the tmux session
# env are never consulted for this setting.

# coord_mode_raw [project-dir]: the value .swarm/.env gives COORD_MODE, read the
# way the shell would (last assignment wins, "export" tolerated, a quoted value
# is taken whole, an unquoted one ends at whitespace so a trailing "# comment"
# is dropped); empty when unset or no file.
coord_mode_raw() {
    local f="${1:-$PWD}/.swarm/.env"
    [ -f "$f" ] || return 0
    sed -nE 's/^[[:space:]]*(export[[:space:]]+)?COORD_MODE=(.*)$/\2/p' "$f" | tail -1 |
        sed -E "s/^[[:space:]]+//; s/^\"([^\"]*)\".*/\1/; s/^'([^']*)'.*/\1/; s/[[:space:]#].*//" |
        tr -d "\"'[:space:]"
}

# coord_mode [project-dir]: "split" or "resident" (unset or anything else).
coord_mode() {
    [ "$(coord_mode_raw "${1:-$PWD}")" = "split" ] && echo split || echo resident
}

# coord_split_flag_urgent <inbox-file> <project-dir>
#
# Needs _window-flags.sh (set_window_flag) and _coord-inbox-batch.sh
# (coord_item_urgency) sourced and $SESSION_NAME set. No-op in resident mode.
# Operator notes are skipped: the operator wrote them a moment ago.
coord_split_flag_urgent() {
    [ "$(coord_mode "$2")" = "split" ] || return 0
    local f="$1" kind
    kind="$(coord_item_kind "$f")"
    [ "$kind" = "operator" ] && return 0
    [ "$(coord_item_urgency "$f")" = "urgent" ] || return 0
    set_window_flag coordinator "📥" "urgent_${kind:-unknown}"
}

# coord_needs_you_items <file>: the "- **A1** ..." item lines of a Needs-you
# list, one per line (the shape coordinator-work.md's digest block uses).
coord_needs_you_items() {
    grep -E '^[[:space:]]*-[[:space:]]+\*\*[A-Za-z][0-9]+\*\*' "$1" 2>/dev/null || true
}

# Item text without its A1/B2 label: renumbering a list is not a new item.
coord_needs_you_bodies() {
    coord_needs_you_items "$1" | sed -E 's/^[[:space:]]*-[[:space:]]+\*\*[A-Za-z][0-9]+\*\*[[:space:]]*//'
}

# coord_needs_you_note <swarm-dir>
#
# Prints one line when .swarm/needs-you.md differs from the copy this session
# last surfaced (.swarm/needs-you.seen), then records the new copy; prints
# nothing when unchanged, absent, or on the first prompt of a list with no
# items. New items = item texts (label ignored) not present in the previous copy.
coord_needs_you_note() {
    local cur="$1/needs-you.md" seen="$1/needs-you.seen" total new had_seen=0
    [ -f "$cur" ] || return 0
    [ -f "$seen" ] && had_seen=1
    if [ "$had_seen" = 1 ] && cmp -s "$cur" "$seen"; then
        return 0
    fi
    total="$(coord_needs_you_items "$cur" | grep -c . || true)"
    if [ "$had_seen" = 1 ]; then
        new="$(coord_needs_you_bodies "$cur" | grep -cvxFf <(coord_needs_you_bodies "$seen") || true)"
    else
        new="$total"
    fi
    cp -f "$cur" "$seen" 2>/dev/null || true
    [ "$had_seen" = 1 ] || [ "$total" -gt 0 ] || return 0
    printf 'Needs-you changed since your last message: %s new item(s), %s on the list now (see .swarm/needs-you.md).\n' "$new" "$total"
}
