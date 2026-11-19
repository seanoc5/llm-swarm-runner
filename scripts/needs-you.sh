#!/usr/bin/env bash
#
# needs-you.sh — the standing Needs-you list as structured items (issue #798).
#
#   needs-you.sh add --title T --background B --do D [--kind decision|todo]
#                    [--risk R] [--rec TEXT] [--default TEXT] [--url U] [--claim TEXT] (--check CMD | --check-source operator) [--project DIR]
#   needs-you.sh done <label> [--project DIR]
#   needs-you.sh verify <label> [--claim TEXT] [--project DIR]
#   needs-you.sh render [--json] [--write] [--project DIR]
#   needs-you.sh check [--project DIR]
#
# --check CMD (issue #1017): `add` runs CMD itself (bash, 30s cap: a shell test, `gh`,
# `curl`, `psql`) before filing and stores checkCmd, checkedAt, checkResult (exit code)
# and checkOutput (last line). Exit 0 means "the ask is still needed". A non-zero exit
# refuses the item: the ask is already done or false. An item with neither --check nor
# --check-source operator (a fact only the operator knows) is refused too, so
# "verified" always has a command behind it. `verify <label>` re-runs the stored
# checkCmd; a failing re-check keeps the item open, records the failure, exits 1, and
# `render` shows "CHECK FAILED".
#
# --background (issue #964) is the cold-reader paragraph: what the thing is, why
# it is open, what each option changes (>= 12 words). `add` refuses one that
# leans on undefined internal labels: "HOLD (yours, date)", option codes like
# B3 / A4-a, slash-joined acronyms like SI/SR. `render` leads each item with it
# as "What this is:". `check` exits 3 when .swarm/needs-you.md was not written
# from .swarm/needs-you.jsonl (a hand-written list); coord-hook.sh runs it.
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
# Carry-over (issue #680): an item rests on facts (file counts, PR state, numbers).
# --claim TEXT states them; `add` stamps "verified" now. Before an item rides into
# another digest, re-check the claim against the source and run `verify <label>`
# (optionally with the corrected --claim). `render` shows "verified MM-DD HH:MM", or
# "(unverified since MM-DD HH:MM)" once the stamp is older than NEEDS_YOU_STALE_HOURS
# (default 6), so a repeated item can never look settled without a check behind it.
#
# render ends with exactly one closing line: "Do now: <label>" (label alone, issue
# #1016: repeating the item's --do text or URL made the reply lint hit repeat-item)
# when items are open, "Nothing to do." when none are. Placeholder values ("none", "nothing",
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
usage() { sed -n '3,58p' "$0" | sed 's/^# \{0,1\}//'; }

cmd="${1:-}"
[ -n "$cmd" ] || { usage >&2; exit 2; }
case "$cmd" in -h|--help) usage; exit 0 ;; esac
shift

title=""; background=""; do_=""; kind="todo"; risk=""; rec=""; deflt=""; url=""; claim=""; check=""; check_source=""; project="${CLAUDE_PROJECT_DIR:-$PWD}"
json=0; write=0; label=""
while [ $# -gt 0 ]; do
    case "$1" in
        --title)   title="${2-}"; shift 2 ;;
        --background) background="${2-}"; shift 2 ;;
        --do)      do_="${2-}"; shift 2 ;;
        --kind)    kind="${2-}"; shift 2 ;;
        --risk)    risk="${2-}"; shift 2 ;;
        --rec)     rec="${2-}"; shift 2 ;;
        --default) deflt="${2-}"; shift 2 ;;
        --url)     url="${2-}"; shift 2 ;;
        --claim)   claim="${2-}"; shift 2 ;;
        --check)   check="${2-}"; shift 2 ;;
        --check-source) check_source="${2-}"; shift 2 ;;
        --project) project="${2-}"; shift 2 ;;
        --json)    json=1; shift ;;
        --write)   write=1; shift ;;
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
    local stale_h="${NEEDS_YOU_STALE_HOURS:-6}"
    case "$stale_h" in ''|*[!0-9]*) stale_h=6 ;; esac
    jq -r --argjson sh "$stale_h" '.[] |
        "- **\(.label)** \(.title)"
        + (if .risk != "" then " (risk: \(.risk))" else "" end)
        + (if .rec != "" then " — \(.rec)" else "" end)
        + (if (.background // "") != "" then "\n  What this is: \(.background)" else "" end)
        + (if (.do | contains("\n")) then "\n  Do:\n\(.do)" else "\n  Do: \(.do)" end)
        + (if .url != "" then "\n  \(.url)" else "" end)
        + ((.verified // .added) as $v
           | ($v | fromdateiso8601) as $t
           | (if (now - $t) > ($sh * 3600) then "(unverified since \($t | localtime | strftime("%m-%d %H:%M")))" else "verified \($t | localtime | strftime("%m-%d %H:%M"))" end) as $vs
           | "\n  " + (if (.claim // "") != "" then "Claim: \(.claim) — " else "" end) + $vs)
        + (if (.checkCmd // "") != "" then
             (if (.checkResult // 0) != 0 then "\n  CHECK FAILED (exit \(.checkResult)) at \(.checkedAt | fromdateiso8601 | localtime | strftime("%m-%d %H:%M")): \(.checkCmd) → \(.checkOutput // "")"
              else "\n  Check: \(.checkCmd) → exit 0 at \(.checkedAt | fromdateiso8601 | localtime | strftime("%m-%d %H:%M"))" end)
           elif (.checkSource // "") == "operator" then "\n  Source: operator-stated, not machine-checked"
           else "" end)
        + (if .default != "" then "\n  Default if silent: \(.default)" else "" end)' <<<"$items"
    if [ "$n" -gt 0 ]; then
        printf '\nDo now: %s\n' "$(jq -r '.[0].label' <<<"$items")"
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

# jargon_hit <text>: prints the first undefined-internal-label match and returns
# 0; returns 1 when clean (issue #964). Deterministic: no option codes (B3, A4-a),
# no "HOLD (yours, date)" stubs, no slash-joined acronyms (SI/SR). PR/issue numbers
# (#2387) and single tech names (H2, p95) pass.
jargon_hit() {
    local m text
    # Well-known pairs are plain words, not internal labels.
    text="$(printf '%s' "$1" | sed -E 's#\b(CI/CD|UI/UX|TCP/IP|I/O|HTTP/HTTPS|SQL/NoSQL|TLS/SSL|CPU/GPU|PR/MR)\b##g')"
    for re in '\bHOLD[[:space:]]*\((yours|mine|ours)[^)]*\)' '\b[A-Z][0-9]{1,2}-[a-z0-9]\b' '\b[A-Z]{2,}(/[A-Z]{2,})+\b' '\b([Oo]ption|[Oo]ptions|[Cc]hoice)[[:space:]]+[A-Z][0-9]{0,2}\b' '\b[A-Z][0-9]{1,2}[[:space:]]*(/|vs\.?|or)[[:space:]]*[A-Z][0-9]{1,2}\b'; do
        m="$(grep -oE -- "$re" <<<"$text" | sed -n 1p || true)"
        [ -z "$m" ] || { printf '%s' "$m"; return 0; }
    done
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
         description: (if (.background // "") != "" then .background else .rec end),
         targetUrl: (if .url != "" then .url else null end),
         fields: ({swarm: $swarm, repo: $repo, issue: $issue, item: $lbl, problem: .title, background: (.background // ""), recommendation: .rec,
                   blast_radius: .risk, do: .do, default_if_silent: .default}
                  | with_entries(select(.value != "")))}
        + (if $forum != "" then {forumId: ($forum | tonumber)} else {} end)
        | if .description == "" then del(.description) else . end' <<<"$item")"
    resp="$(cm_api POST /api/items "$body")" && jq -r '.id // empty' <<<"$resp"
}

# run_check <cmd>: sets check_ec and check_out (last output line). Never aborts the script.
run_check() {
    local out
    set +e
    out="$(cd "$project" && timeout 30 bash -c "$1" 2>&1)"
    check_ec=$?
    set -e
    check_out="$(printf '%s' "$out" | tail -n 1 | cut -c1-200)"
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
        [ -n "$background" ] || die "add needs --background: a plain-language paragraph for a cold reader (what this is, why it is open, what each option changes). A title alone is a stub; refusing."
        [ -n "$do_" ] || die "add needs --do: the exact command (in backticks or a fenced block) or an https URL plus click path. An item without one is a stub; refusing."
        case "$kind" in decision|todo) ;; *) die "--kind is decision or todo" ;; esac
        printf '%s' "$do_" | grep -E '`[^`]+`|```|https://' >/dev/null \
            || die "--do has no command or https URL. Put the command in backticks, or give the URL and the click path. Refusing: $do_"
        [ "$(printf '%s' "$background" | wc -w)" -ge 12 ] \
            || die "--background is under 12 words. Say what the thing is, why it is open and what each option changes, in plain words. Refusing: $background"
        if hit="$(jargon_hit "$title $background")"; then
            die "title/background lean on an undefined internal label ($hit). Say what it is in plain words (what the check or hold is, which PR raised it, what each option changes) instead of a code. Refusing."
        fi
        # --skip (a deny-list), not an --only allowlist: a rule added later applies here by default.
        # lede-identifier is excluded on purpose: a needs-you item is a title plus background, not a reply lede.
        # repeat-item is excluded too: it is warn-only and one item cannot repeat itself across a reply.
        # offer-to-act is excluded too: it is warn-only and judges a Do now block, which an item has none of.
        if hits="$("$LINT" --project "$project" --skip lede-identifier,repeat-item,offer-to-act,ask-not-listed < <(printf "%s\n%s\n" "$title $do_ $rec" "$background") || true)" && [ -n "$hits" ]; then
            die "item points elsewhere instead of carrying its action (${hits%%:*}); restate the item in plain words (what it is, the options, your recommendation) instead of pointing at its label. Refusing."
        fi
        check_json='{}'
        if [ -n "$check" ]; then
            run_check "$check"
            [ "$check_ec" -eq 0 ] || die "--check failed (exit $check_ec: ${check_out:-no output}), so the ask is already done or no longer true. Not filing it. Command: $check"
            check_json="$(jq -cn --arg c "$check" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg o "$check_out" '{checkCmd: $c, checkedAt: $at, checkResult: 0, checkOutput: $o}')"
        elif [ "$check_source" = operator ]; then
            check_json='{"checkSource": "operator"}'
        else
            die "add needs --check '<command>' (a shell test, gh or curl that exits 0 while the ask is still needed) or --check-source operator (a fact only the operator knows). Re-check the ask against the source before listing it. Refusing."
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
        jq -cn --arg label "$new" --arg title "$title" --arg bg "$background" --arg act "$do_" --arg kind "$kind" \
            --arg risk "$risk" --arg rec "$rec" --arg default "$deflt" --arg url "$url" --arg claim "$claim" \
            --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '{label: $label, kind: $kind, title: $title, background: $bg, do: $act, risk: $risk, rec: $rec, default: $default, url: $url, claim: $claim, added: $at, verified: $at, done: false} + $chk' --argjson chk "$check_json" >> "$store"
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
    verify)
        [ -n "$label" ] || die "verify needs a label (e.g. A1)"
        [ -s "$store" ] && jq -se --arg l "$label" 'any(.[]; .label == $l and .done != true)' "$store" >/dev/null \
            || die "no open item $label"
        vcheck="$(jq -r --arg l "$label" 'select(.label == $l and .done != true) | .checkCmd // empty' "$store")"
        check_ec=0; check_out=""
        [ -z "$vcheck" ] || run_check "$vcheck"
        tmp="$(mktemp -p "$swarm" .tmp.needs-you-store.XXXXXX)"
        jq -c --arg l "$label" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg claim "$claim" \
            --argjson ec "$check_ec" --arg out "$check_out" --arg hascheck "$vcheck" \
            'if .label == $l then
                (if $hascheck != "" then .checkedAt = $at | .checkResult = $ec | .checkOutput = $out else . end)
                | (if $hascheck == "" or $ec == 0 then .verified = $at else . end)
                | (if $claim != "" then .claim = $claim else . end)
             else . end' "$store" > "$tmp" && mv -f "$tmp" "$store" \
            || { rm -f "$tmp"; die "could not update $store"; }
        write_md
        if [ "$check_ec" -ne 0 ]; then
            echo "needs-you.sh: $label check failed (exit $check_ec: ${check_out:-no output}); the ask may already be done. Item stays open, flagged CHECK FAILED. Close it with done $label if so." >&2
            exit 1
        fi
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
    check)
        # A hand-written list: a needs-you.md with no store, or one whose body
        # differs from what the store renders (the Updated: time is ignored).
        [ -f "$md" ] || exit 0
        # A missing store counts as an empty list, so `render --write` clears a stale file.
        if diff <(grep -v '^Updated:' "$md") <(render_md | grep -v '^Updated:') >/dev/null; then exit 0; fi
        # Older needs-you.sh layout: same header and same open labels as the store
        # means a render wrote it, not a hand (it is rewritten at the next add/done).
        IFS= read -r first_line < "$md" || true
        if [ -e "$store" ] && [[ $first_line =~ ^'## Needs you ('[0-9]+' open)'$ ]] \
            && [ "$(grep -oE '^- \*\*[A-Za-z][0-9]+\*\*' "$md" | tr -d '* -' | sort | paste -sd,)" = "$(open_items | jq -r '[.[].label] | sort | join(",")')" ]; then
            exit 0
        fi
        echo "needs-you.md does not match needs-you.jsonl (or no list exists): it was written by hand" >&2
        exit 3
        ;;
    render)
        # --write rewrites .swarm/needs-you.md from the store (an empty list when
        # nothing is open): the supported way to clear a stale hand-written file.
        if [ "$write" = 1 ]; then write_md; fi
        if [ "$json" = 1 ]; then
            open_items
        else
            render_md
        fi
        ;;
    *) usage >&2; exit 2 ;;
esac
