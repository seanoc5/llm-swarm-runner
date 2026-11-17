#!/usr/bin/env bash
#
# cminder-events.sh — mirror a swarm's coord-inbox items and worker outcomes to
# its corpusminder forum (issue #862, stage B1 of the coordinator-in-corpusminder
# experiment; the receiving endpoint is corpusminder-spring #2220).
#
#   cminder-events.sh sweep [--project DIR]
#
# Opt-in: does nothing unless NEEDS_YOU_BACKEND=corpusminder AND CMINDER_EVENTS=1
# (default 0) AND CMINDER_URL / CMINDER_API_KEY / CMINDER_FORUM_ID are set.
# coordinator-watch.sh runs `sweep` on a timer (WATCH_CMINDER_EVENTS_SECS).
#
# Each sweep:
#   1. finds coord-inbox items (<project>/.swarm/coord-inbox/ and processed/) and
#      worker outcome JSON (<worktrees>/wt-issue-*/.swarm/tasks/done/*.{ok,err}.json)
#      modified within CMINDER_EVENTS_MAX_AGE_DAYS (default 2) that were not sent;
#   2. writes one request body per new item to <project>/.swarm/cminder-events-spool/;
#   3. POSTs spooled bodies to $CMINDER_URL/api/v1/forums/$CMINDER_FORUM_ID/swarm-events,
#      oldest first. A 2xx removes the spool file and leaves a marker in
#      .swarm/cminder-events-sent/. The first failure stops the flush, so a
#      corpusminder outage costs one short timeout per sweep, never more; the
#      spooled bodies are retried on the next sweep.
#
# event_key is the item's file name (outcomes: "outcome:<file name>"); the
# receiver is idempotent on it. Payload: swarm, kind, occurred_at, payload
# {issue, pr, text (first lines of the body)}. Lines that look like tokens or
# keys are dropped before anything is written to the spool.
#
# Knobs: CMINDER_EVENTS_TIMEOUT_SECS (5), CMINDER_EVENTS_MAX_AGE_DAYS (2),
# CMINDER_EVENTS_MAX_LINES (20), CMINDER_EVENTS_MAX_BATCH (40 posts per sweep).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
die() { echo "cminder-events: $*" >&2; exit 2; }

cmd="${1:-}"
[ -n "$cmd" ] || die "usage: cminder-events.sh sweep [--project DIR]"
shift
project="${CLAUDE_PROJECT_DIR:-$PWD}"
while [ $# -gt 0 ]; do
    case "$1" in
        --project) project="${2-}"; shift 2 ;;
        *) die "unknown argument $1" ;;
    esac
done
[ "$cmd" = sweep ] || die "unknown command $cmd (only: sweep)"
project="$(cd "$project" && pwd)" || die "no such project $project"

# shellcheck source=scripts/_load-env.sh
. "$SELF_DIR/_load-env.sh" "$project"

# Gate: the default path makes zero calls and touches nothing.
[ "${CMINDER_EVENTS:-0}" = 1 ] || exit 0
[ "${NEEDS_YOU_BACKEND:-file}" = corpusminder ] || exit 0
[ -n "${CMINDER_URL:-}" ] && [ -n "${CMINDER_API_KEY:-}" ] && [ -n "${CMINDER_FORUM_ID:-}" ] || {
    echo "cminder-events: CMINDER_URL, CMINDER_API_KEY and CMINDER_FORUM_ID are needed" >&2; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "cminder-events: jq is needed" >&2; exit 0; }

swarm_dir="$project/.swarm"
spool="$swarm_dir/cminder-events-spool"
sent="$swarm_dir/cminder-events-sent"
inbox="${COORD_INBOX_DIR:-$swarm_dir/coord-inbox}"
swarm_name="$(basename "$project")"
max_age="${CMINDER_EVENTS_MAX_AGE_DAYS:-2}"
max_lines="${CMINDER_EVENTS_MAX_LINES:-20}"
max_batch="${CMINDER_EVENTS_MAX_BATCH:-40}"
timeout_s="${CMINDER_EVENTS_TIMEOUT_SECS:-5}"
mkdir -p "$spool" "$sent" || exit 0

# One sweep at a time (the watcher may fire the next before a slow one ends).
lock="$swarm_dir/cminder-events.lock"
if ! mkdir "$lock" 2>/dev/null; then
    lp="$(cat "$lock/pid" 2>/dev/null || true)"
    if [ -n "$lp" ] && kill -0 "$lp" 2>/dev/null; then exit 0; fi
    rm -rf "$lock"; mkdir "$lock" 2>/dev/null || exit 0
fi
echo "$$" > "$lock/pid"
trap 'rm -rf "$lock"' EXIT

# Lines that look like credentials. Dropped whole; never sent, never spooled.
SECRET_RE='(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{16,}|AKIA[0-9A-Z]{12,}|xox[abprs]-[A-Za-z0-9-]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY|[Bb]earer +[A-Za-z0-9._~+/=-]{12,}|([Tt]oken|[Ss]ecret|[Pp]assword|[Pp]asswd|[Aa]pi[_-]?[Kk]ey|[Aa]uthorization|[Cc]redential)[A-Za-z_]*[ \t]*[:=])'
scrub() {
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" =~ $SECRET_RE ]] && continue
        [ "${#CMINDER_API_KEY}" -ge 8 ] && [[ "$line" == *"$CMINDER_API_KEY"* ]] && continue
        printf '%s\n' "$line"
    done
}

# file_key <key> -> a filesystem-safe name.
safe() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

# enqueue <event_key> <kind> <occurred_at> <issue> <pr> <text>
enqueue() {
    local key="$1" kind="$2" at="$3" issue="$4" pr="$5" text="$6" f
    f="$(safe "$key")"
    [ -e "$sent/$f" ] || [ -e "$spool/$f.json" ] && return 0
    jq -n --arg k "$key" --arg s "$swarm_name" --arg kind "$kind" --arg at "$at" \
        --arg issue "$issue" --arg pr "$pr" --arg text "$text" '
        {event_key:$k, swarm:$s, kind:$kind, occurred_at:$at,
         payload:({text:$text}
                  + (if $issue != "" then {issue:($issue|tonumber)} else {} end)
                  + (if $pr != "" then {pr:($pr|tonumber)} else {} end))}' \
        > "$spool/.tmp.$f" 2>/dev/null && mv -f "$spool/.tmp.$f" "$spool/$f.json" || rm -f "$spool/.tmp.$f"
}

iso_mtime() { date -u -d "@$(stat -c %Y "$1")" +%Y-%m-%dT%H:%M:%SZ; }

# ── 1. discover ──────────────────────────────────────────────────────────────
while IFS= read -r f; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    # <UTC-timestamp>-<kind>-<pid>-<rand>.md
    kind="$(sed -E 's/^[0-9]{8}T[0-9]{6}Z-(.*)-[0-9]+-[0-9]+\.md$/\1/' <<<"$base")"
    [ "$kind" != "$base" ] || kind=inbox
    text="$(head -n "$max_lines" "$f" | scrub | head -c 4000)"
    issue="$(grep -oiE '(issue #|iss-)[0-9]+' <<<"$text" | head -1 | grep -oE '[0-9]+$' || true)"
    pr="$(grep -oiE '(PR #|pull/)[0-9]+' <<<"$text" | head -1 | grep -oE '[0-9]+$' || true)"
    enqueue "$base" "$kind" "$(iso_mtime "$f")" "$issue" "$pr" "$text"
done < <(find "$inbox" "$inbox/processed" -maxdepth 1 -name '*.md' -type f -mtime "-$max_age" 2>/dev/null | sort)

wt_parent="${WORKSPACE:-$(dirname "$project")}"
while IFS= read -r f; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    case "$base" in *.ok.json) kind=outcome_ok ;; *) kind=outcome_err ;; esac
    # Redact secret-looking string values, cap each string at 500 chars.
    text="$(jq -c --arg re "$SECRET_RE" '
        walk(if type == "object" then with_entries(if (.key | test("token|secret|passw|api.?key|authorization|credential"; "i")) then .value = "[redacted]" else . end)
             elif type == "string" then (if test($re) then "[redacted]" else .[0:500] end) else . end)' "$f" 2>/dev/null \
        | scrub | head -c 4000)"
    [ -n "$text" ] || continue
    issue="$(jq -r '.issue // empty' "$f" 2>/dev/null | grep -E '^[0-9]+$' || true)"
    [ -n "$issue" ] || issue="$(grep -oE 'wt-issue-[0-9]+' <<<"$f" | head -1 | grep -oE '[0-9]+$' || true)"
    pr="$(jq -r '.pr // empty' "$f" 2>/dev/null | grep -E '^[0-9]+$' || true)"
    enqueue "outcome:$base" "$kind" "$(iso_mtime "$f")" "$issue" "$pr" "$text"
done < <(find "$wt_parent" -maxdepth 6 -path '*/wt-issue-*/.swarm/tasks/done/*' \( -name '*.ok.json' -o -name '*.err.json' \) -type f -mtime "-$max_age" 2>/dev/null | sort)

# ── 2. flush the spool, oldest first; stop at the first failure ──────────────
url="${CMINDER_URL%/}/api/v1/forums/$CMINDER_FORUM_ID/swarm-events"
n=0
while IFS= read -r body; do
    [ -f "$body" ] || continue
    [ "$n" -lt "$max_batch" ] || break
    n=$((n + 1))
    if curl -sS --fail --max-time "$timeout_s" -o /dev/null -X POST \
            -H "Authorization: Bearer $CMINDER_API_KEY" -H "Content-Type: application/json" \
            --data-binary "@$body" "$url" 2>/dev/null; then
        : > "$sent/$(basename "$body" .json)"
        rm -f "$body"
    else
        echo "cminder-events: post failed; $(find "$spool" -name '*.json' | wc -l | tr -d ' ') event(s) stay spooled for the next sweep" >&2
        break
    fi
done < <(ls -tr "$spool"/*.json 2>/dev/null)

# Sent markers only need to outlive the discovery window.
find "$sent" -type f -mtime +14 -delete 2>/dev/null || true
exit 0
