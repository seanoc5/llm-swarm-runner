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
# open items for corpusminder's file_item (DECISION or TODO, fields in jsonb);
# an MCP tool cannot be called from here, so the coordinator relays them.
#
# render ends with exactly one closing line: "Do now: <label> ..." when items
# are open, "Nothing to do." when none are.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINT="$SELF_DIR/lint-coordinator-reply.sh"

die() { echo "needs-you.sh: $*" >&2; exit 2; }
usage() { sed -n '3,25p' "$0" | sed 's/^# \{0,1\}//'; }

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
        grep -qE '`[^`]+`|```|https://' <<<"$do_" \
            || die "--do has no command or https URL. Put the command in backticks, or give the URL and the click path. Refusing: $do_"
        if hits="$("$LINT" <<<"$title $do_ $rec" || true)" && [ -n "$hits" ]; then
            die "item points elsewhere instead of carrying its action (${hits%%:*}); put the full command in --do. Refusing."
        fi
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
