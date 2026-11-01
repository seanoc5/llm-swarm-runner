#!/usr/bin/env bash
#
# daily-changelog.sh — once-a-day "what merged" digest per app swarm, posted
# to a per-app changelog thread on corpusminder.
#
# For each app in the config it lists the PRs merged on one local calendar
# day, renders a plain-language digest, writes it to
#   <repo_dir>/.swarm/changelog/YYYY-MM-DD.md    (the post itself)
#   <repo_dir>/.swarm/changelog/YYYY-MM-DD.json  (same data, for an in-app
#                                                 "What's new" page later)
# and posts the markdown as one comment in that app's changelog thread.
# A day with nothing merged writes nothing and posts nothing.
#
# Per PR line: risk colour from the first `<!-- BLIND_MERGE_RISK: x -->`
# marker in the body (🟢 low, 🟡 medium, 🔴 high, ⚪ not rated), the title
# with its `[agent] type(scope):` prefix and trailing `(#N)` stripped, and
# the https PR URL. A PR whose latest `SWARM_SELF_REVIEW: <v> actor=coordinator`
# verdict is APPROVE_WITH_CAVEATS is flagged, with any follow-up issue
# labelled `from-pr-N` linked. Whether a merge was unattended or operator-
# approved comes from swarm-merge.sh's `merge.done ... mode=` events in the
# app's .swarm/events.log; unattended merges are tagged "(auto-merged)".
#
# corpusminder side: the external-thread API (`/api/threads`, corpusminder
# issue #1203). A thread is keyed by (cm_app, "changelog", <name>) and lives
# in that cm_app's "Using <app>" guide forum; find-or-create is idempotent on
# the server, so the thread is never duplicated. Auth is an API-client key
# (`cmapi_...`, sent as `X-Api-Key`) whose client has app=<cm_app> and an
# owner user who is a member of that guide forum. One key per cm_app, read
# from $CHANGELOG_KEY_DIR/<cm_app>.key (bare key or `KEY=value` line).
#
# Idempotent: a posted day leaves YYYY-MM-DD.posted next to the markdown,
# and before posting the thread is read back and skipped if any comment
# already carries this day's footer ("Daily changelog · <name> · <date>").
#
# Catch-up: without --date, each app reports every day after its newest
# .posted marker up to yesterday (at most $CHANGELOG_MAX_BACKFILL, default 7,
# newest kept; older days are logged as skipped). An app with no marker yet
# reports just yesterday.
#
# Usage: daily-changelog.sh [--date YYYY-MM-DD] [--app NAME] [--dry-run]
#   --date     one local day to report (default: catch up through yesterday in $CHANGELOG_TZ)
#   --app      only this app (name column of the config); repeatable
#   --dry-run  print each digest to stdout; write nothing, call no API
#
# Config ($CHANGELOG_CONF, default ~/.config/swarm-changelog/apps.conf;
# template examples/changelog-apps.conf.example), one app per line:
#   <name> <repo_dir> <owner/repo> <cm_app>
#
# Env: CHANGELOG_TZ (America/New_York), CM_BASE_URL (http://192.168.1.185:8081,
#   the LAN address: the public hostname sits behind Cloudflare rate limits),
#   CM_PUBLIC_URL (https://corpusminder.oconeco.com, used for printed links),
#   CHANGELOG_KEY_DIR (~/.config/swarm-changelog/keys), CHANGELOG_MAX_BACKFILL (7).
#
# Exit: 0 all done (including nothing-to-post and a missing key, which only
#   warns: the digest is still written and posts once the key exists);
#   1 a fetch or post failed; 2 usage/config error.

set -euo pipefail

TZ_NAME="${CHANGELOG_TZ:-America/New_York}"
CONF="${CHANGELOG_CONF:-$HOME/.config/swarm-changelog/apps.conf}"
KEY_DIR="${CHANGELOG_KEY_DIR:-$HOME/.config/swarm-changelog/keys}"
CM_BASE_URL="${CM_BASE_URL:-http://192.168.1.185:8081}"
CM_PUBLIC_URL="${CM_PUBLIC_URL:-https://corpusminder.oconeco.com}"
ENTITY_TYPE="changelog"

usage() { sed -n '2,62p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "daily-changelog: ERROR: $*" >&2; exit 2; }

DATE=""
DRY_RUN=0
ONLY_APPS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --date) DATE="${2:?--date needs YYYY-MM-DD}"; shift 2 ;;
        --app) ONLY_APPS+=("${2:?--app needs a name}"); shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

YESTERDAY="${CHANGELOG_YESTERDAY:-$(TZ="$TZ_NAME" date -d yesterday +%F)}"  # env override: test hook
MAX_BACKFILL="${CHANGELOG_MAX_BACKFILL:-7}"
[[ "$MAX_BACKFILL" =~ ^[1-9][0-9]*$ ]] || die "CHANGELOG_MAX_BACKFILL must be a positive integer"
if [ -n "$DATE" ]; then
    [[ "$DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "--date must be YYYY-MM-DD, got '$DATE'"
    TZ="$TZ_NAME" date -d "$DATE 00:00" >/dev/null 2>&1 || die "bad --date '$DATE'"
fi

# Sets the per-day globals (window, label, search) for one local day.
set_day() {
    DATE="$1"
    DAY_START="$(TZ="$TZ_NAME" date -d "$DATE 00:00" +%s)"
    NEXT_DAY="$(date -d "$DATE 12:00 next day" +%F)"
    DAY_END="$(TZ="$TZ_NAME" date -d "$NEXT_DAY 00:00" +%s)"
    DAY_LABEL="$(TZ="$TZ_NAME" date -d "$DATE 12:00" '+%A, %-d %B %Y')"
    # GitHub's merged: qualifier is UTC-dated; search one day wider each side,
    # then keep exactly the local day with jq below.
    SEARCH="merged:$(date -u -d "@$((DAY_START - 86400))" +%F)..$(date -u -d "@$((DAY_END + 86400))" +%F)"
}

# Days to report for one app, oldest first: the explicit --date, else every
# day after the newest .posted marker through yesterday (capped), else just
# yesterday. Prints a skipped-days note to stderr when the cap bites.
days_for() {
    local name="$1" outdir="$2" last d days=() skipped=0
    if [ -n "$DATE" ]; then echo "$DATE"; return; fi
    last="$(ls "$outdir" 2>/dev/null | sed -n 's/^\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\)\.posted$/\1/p' | sort | tail -1)"
    if [ -z "$last" ]; then echo "$YESTERDAY"; return; fi
    d="$last"
    while [[ "$d" < "$YESTERDAY" ]]; do
        d="$(date -d "$d 12:00 next day" +%F)"
        days+=("$d")
    done
    if [ "${#days[@]}" -gt "$MAX_BACKFILL" ]; then
        skipped=$(( ${#days[@]} - MAX_BACKFILL ))
        days=("${days[@]:skipped}")
        echo "$name: gap since $last is longer than $MAX_BACKFILL days; skipping the $skipped oldest" >&2
    fi
    [ "${#days[@]}" -gt 0 ] && printf '%s\n' "${days[@]}"
    return 0
}

[ -r "$CONF" ] || die "no config at $CONF (copy examples/changelog-apps.conf.example there)"

# Every config line as "name|repo_dir|gh_repo|cm_app".
APPS=()
while read -r name dir repo cm_app _; do
    case "$name" in ''|'#'*) continue ;; esac
    [ -n "$cm_app" ] || die "config line for '$name' needs 4 columns: name repo_dir owner/repo cm_app"
    APPS+=("$name|$dir|$repo|$cm_app")
done < "$CONF"

if [ "${#ONLY_APPS[@]}" -gt 0 ]; then
    for want in "${ONLY_APPS[@]}"; do
        printf '%s\n' "${APPS[@]}" | grep -q "^$want|" || die "--app '$want' is not in $CONF"
    done
fi

wanted() {
    [ "${#ONLY_APPS[@]}" -eq 0 ] && return 0
    local a
    for a in "${ONLY_APPS[@]}"; do [ "$a" = "$1" ] && return 0; done
    return 1
}

# The day's merged PRs for one repo as a JSON array, oldest merge first.
fetch_prs() {
    local repo="$1" raw
    raw="$(gh pr list -R "$repo" --state merged --search "$SEARCH" --limit 300 \
        --json number,title,url,mergedAt,body,comments)" || return 1
    jq --argjson s "$DAY_START" --argjson e "$DAY_END" '
        def kinds: {feat:"New", fix:"Fix", perf:"Faster", docs:"Docs", test:"Tests",
                    refactor:"Cleanup", style:"Cleanup", chore:"Upkeep", build:"Build",
                    ci:"Build", revert:"Undo"};
        def summary:
            sub("^\\[[^\\]]*\\]\\s*"; "") as $t
            | ($t | capture("^(?<k>[A-Za-z]+)(\\([^)]*\\))?!?:\\s*(?<r>.+)$") // {k: "", r: $t}) as $m
            | ($m.r | sub("\\s*\\(#[0-9]+\\)\\s*$"; "")) as $r
            | "\(kinds[$m.k | ascii_downcase] // "Change"): \($r[0:1] | ascii_upcase)\($r[1:])";
        [ .[]
          | select((.mergedAt | fromdateiso8601) as $m | $m >= $s and $m < $e)
          | { number, url, mergedAt,
              title,
              summary: (.title | summary),
              risk: ((.body // "") | [scan("<!-- BLIND_MERGE_RISK: ([a-z]+) -->")] | first | .[0]? // "unrated"),
              caveats: ([.comments[]?.body // "" | scan("SWARM_SELF_REVIEW: ([A-Z_]+) actor=coordinator") | .[0]]
                        | last == "APPROVE_WITH_CAVEATS"),
              followups: [] } ]
        | sort_by(.mergedAt)' <<<"$raw"
}

# Adds .mode from swarm-merge.sh's merge.done events (unattended-low,
# unattended-medium, operator). PRs merged another way (gh, the web UI, before
# the event existed) keep mode null and render with no tag.
add_modes() {
    local events="$1/.swarm/events.log" prs="$2" modes
    [ -f "$events" ] || { printf '%s\n' "$prs"; return; }
    modes="$(sed -n 's/.*merge\.done .*pr=\([0-9]*\) .*mode=\([a-z-]*\).*/\1 \2/p' "$events" \
        | jq -Rn '[inputs | split(" ") | {key: .[0], value: .[1]}] | from_entries')"
    jq --argjson m "$modes" 'map(.mode = ($m[.number | tostring] // null))' <<<"$prs"
}

# Adds follow-up issue URLs (label from-pr-N) to every caveat PR.
add_followups() {
    local repo="$1" prs="$2" n urls
    for n in $(jq -r '.[] | select(.caveats) | .number' <<<"$prs"); do
        urls="$(gh issue list -R "$repo" --state all --label "from-pr-$n" --limit 20 \
            --json url --jq '[.[].url]' 2>/dev/null || echo '[]')"
        [ -n "$urls" ] || urls='[]'
        prs="$(jq --argjson n "$n" --argjson u "$urls" \
            'map(if .number == $n then .followups = $u else . end)' <<<"$prs")"
    done
    printf '%s\n' "$prs"
}

footer() { printf 'Daily changelog · %s · %s' "$1" "$DATE"; }

render_md() {
    local name="$1" json="$2"
    jq -r --arg name "$name" --arg day "$DAY_LABEL" --arg footer "$(footer "$name")" '
        def dot: {low: "🟢", medium: "🟡", high: "🔴"}[.] // "⚪";
        (.prs | length) as $n
        | "## \($name): \($n) \(if $n == 1 then "change" else "changes" end) merged on \($day)\n",
          (.prs[] | "- \(.risk | dot) \(.summary)\(if (.mode // "") | startswith("unattended") then " (auto-merged)" else "" end) — \(.url)",
                    (select(.caveats)
                     | "  - ⚠️ Merged with reviewer caveats."
                       + (if (.followups | length) > 0
                          then " Follow-up: " + (.followups | join(", "))
                          else " No follow-up issue filed." end))),
          "",
          "Risk before merging: 🟢 low · 🟡 medium · 🔴 high · ⚪ not rated",
          "",
          "_\($footer)_"' <<<"$json"
}

# corpusminder call: cm_call <method> <path> <key_file> [json_body]; prints
# the body, returns 1 on a non-2xx. The key goes in via a 0600 header file,
# never argv.
cm_call() {
    local method="$1" path="$2" key_file="$3" body="${4:-}" hdr out code key
    hdr="$(mktemp)"
    chmod 600 "$hdr"
    key="$(sed -n '/[^[:space:]]/{s/^[A-Za-z_]*=//;s/^["'\'']//;s/["'\'']$//;p;q}' "$key_file")"
    printf 'X-Api-Key: %s\n' "$key" > "$hdr"
    local args=(-sS -m 30 -X "$method" -H "@$hdr" -H 'Accept: application/json' -w '\n%{http_code}')
    [ -n "$body" ] && args+=(-H 'Content-Type: application/json' --data-binary "$body")
    out="$(curl "${args[@]}" "$CM_BASE_URL$path")" || { rm -f "$hdr"; echo "curl failed: $method $path" >&2; return 1; }
    rm -f "$hdr"
    code="${out##*$'\n'}"
    out="${out%$'\n'*}"
    if [[ "$code" != 2* ]]; then
        echo "corpusminder $method $path -> HTTP $code: ${out:0:300}" >&2
        return 1
    fi
    printf '%s\n' "$out"
}

post_digest() {
    local name="$1" cm_app="$2" outdir="$3" md_file="$4" key_file thread resp qid
    local posted="$outdir/$DATE.posted"
    local q="?externalId=$name"
    key_file="$KEY_DIR/$cm_app.key"
    if [ ! -r "$key_file" ]; then
        echo "$name: WARNING: digest for $DATE written, NOT posted: no key at $key_file (needs a corpusminder API client with app=$cm_app)" >&2
        return 3
    fi
    thread="$(cm_call POST /api/threads "$key_file" \
        "$(jq -nc --arg a "$cm_app" --arg t "$ENTITY_TYPE" --arg x "$name" \
            '{app: $a, entityType: $t, externalId: $x, title: "\($x) changelog"}')")" || return 1
    qid="$(jq -r '.questionId // empty' <<<"$thread" 2>/dev/null || true)"
    if ! [[ "$qid" =~ ^[0-9]+$ ]]; then
        echo "$name: ERROR: POST /api/threads returned no usable questionId (${thread:0:200}); thread.json not written" >&2
        return 1
    fi
    jq -n --argjson q "$qid" --arg app "$cm_app" --arg x "$name" --arg u "$CM_PUBLIC_URL/questions/$qid" \
        '{questionId: $q, app: $app, entityType: "changelog", externalId: $x, url: $u}' > "$outdir/thread.json"

    # Remote dedupe: a lost .posted file must not cause a second post.
    resp="$(cm_call GET "/api/threads/$cm_app/$ENTITY_TYPE$q" "$key_file")" || return 1
    if jq -e --arg f "$(footer "$name")" \
        '[.comments[]? | recurse(.replies[]?) | .text // ""] | any(contains($f))' <<<"$resp" >/dev/null; then
        echo "already-in-thread" > "$posted"
        echo "$name: already posted for $DATE (found in thread) — $CM_PUBLIC_URL/questions/$qid"
        return 0
    fi

    resp="$(cm_call POST "/api/threads/$cm_app/$ENTITY_TYPE/comments$q" "$key_file" \
        "$(jq -Rsc '{text: .}' < "$md_file")")" || return 1
    jq -r '.id' <<<"$resp" > "$posted"
    echo "$name: posted $DATE — $CM_PUBLIC_URL/questions/$qid"
}

# One app, one day (DATE and friends already set by set_day). Returns 0 done
# or skipped, 1 on a fetch/post failure (the caller stops that app's catch-up
# so a later day's marker can never hide an earlier unposted day).
do_day() {
    local name="$1" dir="$2" repo="$3" cm_app="$4" outdir="$5" prs json prc=0
    if [ "$DRY_RUN" = 0 ] && [ -e "$outdir/$DATE.posted" ]; then
        echo "$name: already posted for $DATE"
        return 0
    fi
    if ! prs="$(fetch_prs "$repo")"; then
        echo "$name: ERROR: could not list merged PRs for $repo" >&2
        return 1
    fi
    if [ "$(jq length <<<"$prs")" -eq 0 ]; then
        echo "$name: nothing merged on $DATE"
        return 0
    fi
    prs="$(add_followups "$repo" "$prs")"
    prs="$(add_modes "$dir" "$prs")"
    json="$(jq -n --arg app "$name" --arg repo "$repo" --arg date "$DATE" --argjson prs "$prs" \
        '{app: $app, repo: $repo, date: $date, count: ($prs | length), prs: $prs}')"

    if [ "$DRY_RUN" = 1 ]; then
        echo "===== $name ($DATE) — dry run, would write $outdir/$DATE.md and post to $cm_app/$ENTITY_TYPE/$name ====="
        render_md "$name" "$json"
        echo
        return 0
    fi

    mkdir -p "$outdir"
    printf '%s\n' "$json" > "$outdir/$DATE.json"
    render_md "$name" "$json" > "$outdir/$DATE.md"
    post_digest "$name" "$cm_app" "$outdir" "$outdir/$DATE.md" || prc=$?
    case "$prc" in
        0|3) return 0 ;;  # 3: no key, already warned; the digest is kept
        *) echo "$name: ERROR: post failed; digest kept at $outdir/$DATE.md" >&2; return 1 ;;
    esac
}

RC=0
for entry in "${APPS[@]}"; do
    IFS='|' read -r name dir repo cm_app <<<"$entry"
    wanted "$name" || continue
    outdir="$dir/.swarm/changelog"
    mapfile -t days < <(days_for "$name" "$outdir")
    if [ "${#days[@]}" -eq 0 ]; then
        echo "$name: already posted through $YESTERDAY"
        continue
    fi
    for day in "${days[@]}"; do
        set_day "$day"
        do_day "$name" "$dir" "$repo" "$cm_app" "$outdir" || { RC=1; break; }
    done
done
exit "$RC"
