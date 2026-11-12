#!/usr/bin/env bash
#
# needs-you.sh — the standing Needs-you list as structured items (issue #798).
#
#   needs-you.sh add --title T --do D [--kind decision|todo] [--risk R]
#                    [--rec TEXT] [--default TEXT] [--url U] [--project DIR]
#   needs-you.sh done <label> [--project DIR]
#   needs-you.sh render [--json] [--project DIR]
#
# Every item must carry --do: the exact thing the operator does, as a `command`
# (backticks or a fenced block) or an https URL (with the click path). `add`
# refuses an item without one, and refuses a --do that points elsewhere
# ("command above", "details in .swarm/needs-you.md"). Coordinators paste the
# `render` output into replies instead of hand-writing items, so a quiet wake
# reprints every action in full.
#
# Store: .swarm/needs-you.jsonl (one JSON object per item; done items stay,
# marked, so a label is never reused). Every change rewrites the human copy
# .swarm/needs-you.md (the file coord-hook.sh diffs). `render --json` prints the
# open items as JSON.
#
# render ends with exactly one closing line: "Do now: <label> ..." when items
# are open, "Nothing to do." when none are. Placeholder values ("none", "nothing",
# "n/a") for --risk/--rec/--default are dropped: an empty field is left out.
#
# Backend (issue #801): NEEDS_YOU_BACKEND=file (default) keeps everything local.
# NEEDS_YOU_BACKEND=corpusminder also files each item in corpusminder (REST
# POST /api/items: kind DECISION/TODO, fields in the jsonb "fields", targetUrl =
# --url) and completes it on `done`. The local files are written either way, so
# an outage never loses an item (a failed call warns on stderr and moves on).
# Needs CMINDER_URL + CMINDER_API_KEY; optional CMINDER_FORUM_ID. The answers
# come back through scripts/cminder-bridge.sh. render never calls corpusminder.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINT="$SELF_DIR/lint-coordinator-reply.sh"

die() { echo "needs-you.sh: $*" >&2; exit 2; }
usage() { sed -n '3,36p' "$0" | sed 's/^# \{0,1\}//'; }

cmd="${1:-}"
[ -n "$cmd" ] || { usage >&2; exit 2; }
case "$cmd" in -h|--help) usage; exit 0 ;; esac
shift

title=""; do_=""; kind="todo"; risk=""; rec=""; deflt=""; url=""; project="${CLAUDE_PROJECT_DIR:-$PWD}"
json=0; label=""
while [ $# -gt 0 ]; do
    case "$1" in
        --title)   title="${2-}"; shift 2 ;;
        --do)      do_="${2-}"; shift 2 ;;
        --kind)    kind="${2-}"; shift 2 ;;
        --risk)    risk="${2-}"; shift 2 ;;
        --rec)     rec="${2-}"; shift 2 ;;
        --default) deflt="${2-}"; shift 2 ;;
        --url)     url="${2-}"; shift 2 ;;
        --project) project="${2-}"; shift 2 ;;
        --json)    json=1; shift ;;
        -*)        die "unknown flag $1" ;;
        *)         [ -z "$label" ] || die "unexpected argument $1"; label="$1"; shift ;;
    esac
done

# shellcheck source=scripts/_load-env.sh
. "$SELF_DIR/_load-env.sh" "$project"
backend="${NEEDS_YOU_BACKEND:-file}"
case "$backend" in file|corpusminder) ;; *) die "NEEDS_YOU_BACKEND is file or corpusminder, not '$backend'" ;; esac

swarm="$project/.swarm"
store="$swarm/needs-you.jsonl"
md="$swarm/needs-you.md"

# open_items: the open items as a JSON array.
open_items() {
    [ -s "$store" ] || { echo '[]'; return; }
    jq -s '[.[] | select(.done != true)]' "$store"
}

# render_md: the human list. Items keep the "- **A1**" shape coord-hook.sh counts.
render_md() {
    local items n
    items="$(open_items)"
    n="$(jq 'length' <<<"$items")"
    printf '## Needs you (%s open)\n' "$n"
    printf 'Updated: %s\n' "$(date +%H:%M)"
    jq -r '.[] |
        "- **\(.label)** \(.title)"
        + (if .risk != "" then " (risk: \(.risk))" else "" end)
        + (if .rec != "" then " — \(.rec)" else "" end)
        + (if (.do | contains("\n")) then "\n  Do:\n\(.do)" else "\n  Do: \(.do)" end)
        + (if .url != "" then "\n  \(.url)" else "" end)
        + (if .default != "" then "\n  Default if silent: \(.default)" else "" end)' <<<"$items"
    if [ "$n" -gt 0 ]; then
        printf '\nDo now: %s\n' "$(jq -r '.[0] | "\(.label) — \([.do | split("\n")[] | select((test("^[[:space:]]*```") or test("^[[:space:]]*$")) | not)] | first // .do)"' <<<"$items")"
    else
        printf '\nNothing to do.\n'
    fi
}

# --- corpusminder backend (issue #801) --------------------------------------
# cm_api <METHOD> <path> [json-body]: prints the response body, returns non-zero
# on any failure. Callers warn and carry on: the local files are the fallback.
cm_api() {
    local method="$1" path="$2" body="${3-}"
    [ -n "${CMINDER_URL:-}" ] && [ -n "${CMINDER_API_KEY:-}" ] \
        || { echo "CMINDER_URL and CMINDER_API_KEY are needed" >&2; return 1; }
    local args=(-sS --fail --max-time "${CMINDER_TIMEOUT_SECS:-15}" -X "$method"
        -H "Authorization: Bearer $CMINDER_API_KEY" -H "Accept: application/json")
    [ -z "$body" ] || args+=(-H "Content-Type: application/json" --data-binary "$body")
    curl "${args[@]}" "${CMINDER_URL%/}$path"
}

# is_placeholder <text>: "none", "nothing", "n/a" and friends are not content.
is_placeholder() {
    local t
    t="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/^[[:space:].]+//; s/[[:space:].]+$//')"
    case "$t" in none|nothing|"nothing needed"|n/a|na|-|--|"no default"|"not applicable") return 0 ;; esac
    return 1
}

# cm_file <label>: files the item; prints the corpusminder item id (or nothing).
cm_file() {
    local item repo_url repo issue body resp
    item="$(jq -c --arg l "$1" 'select(.label == $l)' "$store" | tail -n 1)"
    repo_url="$(git -C "$project" remote get-url origin 2>/dev/null || true)"
    repo="$(printf '%s' "$repo_url" | sed -E 's#^(git@[^:]+:|https?://[^/]+/)##; s#\.git$##')"
    issue="$(jq -r '.url | capture("/(issues|pull)/(?<n>[0-9]+)").n // empty' <<<"$item")"
    body="$(jq -c --arg swarm "$(basename "$project")" --arg repo "$repo" --arg issue "$issue" \
        --arg forum "${CMINDER_FORUM_ID:-}" --arg lbl "$1" '
        {kind: (if .kind == "decision" then "DECISION" else "TODO" end),
         label: .title,
         description: (.rec),
         targetUrl: (if .url != "" then .url else null end),
         fields: ({swarm: $swarm, repo: $repo, issue: $issue, item: $lbl, problem: .title, recommendation: .rec,
                   blast_radius: .risk, do: .do, default_if_silent: .default}
                  | with_entries(select(.value != "")))}
        + (if $forum != "" then {forumId: ($forum | tonumber)} else {} end)
        | if .description == "" then del(.description) else . end' <<<"$item")"
    resp="$(cm_api POST /api/items "$body")" && jq -r '.id // empty' <<<"$resp"
}

write_md() {
    local tmp
    mkdir -p "$swarm"
    tmp="$(mktemp -p "$swarm" .tmp.needs-you.XXXXXX)"
    render_md > "$tmp" && mv -f "$tmp" "$md" || { rm -f "$tmp"; die "could not write $md"; }
}

case "$cmd" in
    add)
        [ -n "$title" ] || die "add needs --title"
        [ -n "$do_" ] || die "add needs --do: the exact command (in backticks or a fenced block) or an https URL plus click path. An item without one is a stub; refusing."
        case "$kind" in decision|todo) ;; *) die "--kind is decision or todo" ;; esac
        printf '%s' "$do_" | grep -E '`[^`]+`|```|https://' >/dev/null \
            || die "--do has no command or https URL. Put the command in backticks, or give the URL and the click path. Refusing: $do_"
        if hits="$("$LINT" --project "$project" <<<"$title $do_ $rec" || true)" && [ -n "$hits" ]; then
            die "item points elsewhere instead of carrying its action (${hits%%:*}); restate the item in plain words (what it is, the options, your recommendation) instead of pointing at its label. Refusing."
        fi
        # An empty field is left out, not stored as "none" (issue #801).
        ! is_placeholder "$risk" || risk=""
        ! is_placeholder "$rec" || rec=""
        ! is_placeholder "$deflt" || deflt=""
        mkdir -p "$swarm"
        max=0
        if [ -s "$store" ]; then
            max="$(jq -s '[.[].label | sub("^[A-Za-z]"; "") | tonumber] | max // 0' "$store")"
        fi
        new="A$((max + 1))"
        jq -cn --arg label "$new" --arg title "$title" --arg act "$do_" --arg kind "$kind" \
            --arg risk "$risk" --arg rec "$rec" --arg default "$deflt" --arg url "$url" \
            --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '{label: $label, kind: $kind, title: $title, do: $act, risk: $risk, rec: $rec, default: $default, url: $url, added: $at, done: false}' >> "$store"
        if [ "$backend" = corpusminder ]; then
            errf="$(mktemp -p "$swarm" .tmp.needs-you-cm.XXXXXX)"
            if cmid="$(cm_file "$new" 2>"$errf")" && [ -n "$cmid" ]; then
                tmp="$(mktemp -p "$swarm" .tmp.needs-you-store.XXXXXX)"
                jq -c --arg l "$new" --argjson id "$cmid" 'if .label == $l then .cm_id = $id else . end' "$store" > "$tmp" \
                    && mv -f "$tmp" "$store" || rm -f "$tmp"
            else
                echo "needs-you.sh: corpusminder filing failed for $new ($(tr '\n' ' ' <"$errf")); kept in the local list only" >&2
            fi
            rm -f "$errf"
        fi
        write_md
        echo "$new"
        ;;
    done)
        [ -n "$label" ] || die "done needs a label (e.g. A1)"
        [ -s "$store" ] && jq -se --arg l "$label" 'any(.[]; .label == $l and .done != true)' "$store" >/dev/null \
            || die "no open item $label"
        tmp="$(mktemp -p "$swarm" .tmp.needs-you-store.XXXXXX)"
        jq -c --arg l "$label" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            'if .label == $l then .done = true | .closed = $at else . end' "$store" > "$tmp" && mv -f "$tmp" "$store" \
            || { rm -f "$tmp"; die "could not update $store"; }
        write_md
        if [ "$backend" = corpusminder ]; then
            cmid="$(jq -r --arg l "$label" 'select(.label == $l) | .cm_id // empty' "$store")"
            if [ -n "$cmid" ]; then
                cm_api POST "/api/items/$cmid/complete" >/dev/null 2>&1 \
                    || echo "needs-you.sh: could not complete corpusminder item $cmid for $label; close it there by hand" >&2
            fi
        fi
        ;;
    render)
        if [ "$json" = 1 ]; then
            open_items
        else
            render_md
        fi
        ;;
    *) usage >&2; exit 2 ;;
esac
