#!/usr/bin/env bash
#
# lint-coordinator-reply.sh — deterministic check on a coordinator's reply
# (issue #798, ADR 0007). Reads the reply on stdin (or a file argument).
#
# Rules (a rule name per hit; a hit prints "<rule>: <offending line>"):
#   backref      an action item points the operator at text that is not on the
#                screen: "command above", "from my last message", "as before",
#                "see earlier", "in my previous", "details in .swarm/needs-you.md".
#   no-command   a Needs-you item (a "- **A1**" bullet and its continuation
#                lines) says run/start/copy/click/type/paste/execute/open/edit/apply but
#                carries no fenced block, `code span`, https URL, file path with an
#                extension, file:line or quoted phrase. A "Pending your approval:" line
#                and its continuation lines count as an item too (issue #680); a "yes/no"
#                ask or Pending line needs no command for run/start/open, but copy/click/type/paste/execute/edit/apply
#                must still show the change.
#   pointer      the #680 incident phrase only: an item tells the operator to act "yourself" /
#                "on your end" (also "on your side", "yourselves") and carries no `code span`
#                and no file path. The fix is the change itself: file, line, before and after.
#                Deliberately narrow; other pointer phrasings are Known limits (PR #933).
#   two-endings  the reply has two closing lines: "Nothing to do" /
#                "Nothing needed ..." together with "Do now:", or two of "Do now:" /
#                "Pending your approval:" / nothing-lines (#801 fixture).
#
#   bare-list    a line outside a code fence starts with a bare number ("1." or "1)"):
#                the terminal renumbers every such list from 1, so two lists both read
#                "1, 2, 3" and "your 2" is ambiguous (issue #800). Say A1, B1... instead.
#                The same regex backs the user-level Stop hook scripts/hooks/no-bare-numbered-lists.sh.
#
#   stale-window an item sends the operator to type something "in its worker
#                window" / "in its iss-N pane" for a PR or issue whose worker is
#                on hold (sidelined: no window exists; issue #841). Needs
#                --project DIR; without one this rule
#                is skipped. A worker counts as on hold when its worktree has
#                .swarm/sidelined; a PR maps to its worker through the "pr" in
#                the worktree's .swarm/tasks/status/*.json. Right wording: type
#                the phrase in the coordinator.
#
#   issue-merged "#N merges/merged" where #N is an issue, not a PR (issue #716:
#                "hold deploys until #1910 merges" when #1910 was an issue and its fix
#                PR did not exist yet). Resolves each #N within two words of
#                merge/merges/merged/merging via gh api repos/{owner}/{repo}/issues/N
#                (in --project, else the cwd); flags only a confirmed issue, so an
#                offline or failing gh stays silent. Say "the fix PR for #N merges"
#                or "#N closes".
#
#   carryover    a bare backward reference with no gloss on the same line (issue #646;
#                research #645 found 12 dated misses of "I carried an item instead of
#                restating it"). Outside code fences, code spans and URLs, a line is
#                flagged when it has (a) a section pointer ("§4") or a carry-over
#                phrase ("from earlier", "carried over", "as noted", "mentioned
#                earlier", "in the previous digest") and fewer than
#                --gloss N (default 12) other words on the line to
#                explain it, or (b) a short label the reply never defines: a letter+digit
#                such as "your A2", "see B1", "per A3" or a bare "B3" opening a line (not a mid-sentence H2, p95, G1), a range such as "A-D", "option B", "your d)". A label is
#                defined when a line starts with it ("- **A1**", "B)", "A.") or it is
#                followed on its own line by ":", "(" or a dash. Naive on purpose: it cannot
#                see a coined phrase ("the keyboard overlay") or a bare "On #1378:" opener.
#                Fix: restate the item (what it is, options, recommendation) on this screen.
#
#   lede-identifier  the first sentence leads with identifiers, not plain words (issue #979;
#                failure 1 of epic #488: SAMlytics 2026-09-26 opened with migration numbers,
#                script names and PR numbers). "First sentence" = the first non-empty line
#                outside a code fence (a leading "Woke for: ..." line is skipped), cut at the
#                first ". " or a final ".". Hit when an identifier sits in its first 6 words
#                and fewer than 2 plain words come before it. Identifier: #NNN, a `code span`,
#                a path with "/" or a file extension, an ALL_CAPS_ENV token (needs "_"), a
#                7-40 char hex sha (needs a digit). Not plain: label nouns (PR, issue,
#                migration, script, commit...), stopwords (and, the, of...) and any word with
#                a digit (V42). "PR #974 merged" and "Migration V42 and `scripts/x.sh`: ..."
#                hit; "Both merged: #972 and #974" does not. coord-hook.sh runs it warn-only
#                by default (COORD_REPLY_LINT_LEDE=warn|block|off).
#                Fix: open with the outcome in plain words; identifiers come after it.
#
# Usage: lint-coordinator-reply.sh [--project DIR] [--only RULE[,RULE]] [--gloss N] [--why] [file]
# --gloss N sets the carryover threshold; --why prints the matched reference for each carryover hit to stderr.
# --only keeps just the named rules (and skips the slow gh/worktree passes when
# their rule is not named); the Stop hook uses --only bare-list.
# Exit 0 clean, 3 hits (printed to stdout), 2 usage error. Naive on purpose:
# a regex that catches the real incident beats a perfect check nobody runs.
# Fixtures: tests/fixtures/reply-lint/.
set -uo pipefail

PROJECT=""; FILE=""; ONLY=""; GLOSS=12; WHY=""
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) sed -n '3,73p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        --project) [ $# -ge 2 ] || { echo "--project needs a value" >&2; exit 2; }; PROJECT="$2"; shift 2 ;;
        --only) [ $# -ge 2 ] || { echo "--only needs a value" >&2; exit 2; }; ONLY=",$2,"; shift 2 ;;
        --only=*) ONLY=",${1#*=},"; shift ;;
        --gloss) [ $# -ge 2 ] && [[ "$2" =~ ^[0-9]+$ ]] || { echo "--gloss needs a number" >&2; exit 2; }; GLOSS="$2"; shift 2 ;;
        --why) WHY=1; shift ;;
        --project=*) PROJECT="${1#*=}"; shift ;;
        -*) echo "unknown option $1" >&2; exit 2 ;;
        *) [ -z "$FILE" ] || exit 2; FILE="$1"; shift ;;
    esac
done
if [ -n "$FILE" ]; then
    [ -r "$FILE" ] || { echo "cannot read $FILE" >&2; exit 2; }
    text="$(cat "$FILE")"
else
    text="$(cat)"
fi

FENCE_RE='^[[:space:]]*(```|~~~)'   # one fence definition for the main pass and issue_merged_hits
hits="$(printf '%s\n' "$text" | awk -v fence="$FENCE_RE" '
function flush_item(   hit, li) {
    li = tolower(item)
    if (item != "") {
        if (li ~ pointer && item !~ cmd_ptr) hits[++n] = "pointer: " first
        else if (item !~ cmd && (li ~ verbs_hard || (!ispend && li !~ /yes\/no/ && li ~ verbs))) hits[++n] = "no-command: " first
    }
    item = ""; first = ""
}
BEGIN {
    back = "(command|commands|step|steps|link|url|snippet|block)s? above|from my (last|previous|earlier) (message|reply)|as (before|above)|see (earlier|above|my (last|previous))|in my (previous|last|earlier)|details in [`]?\\.swarm/needs-you\\.md"
    verbs = "(^|[^a-z])(run|start|copy|click|type|paste|execute|open|edit|apply)([^a-z]|$)"
    verbs_hard = "(^|[^a-z])(copy|click|type|paste|execute|edit|apply)([^a-z]|$)"   # no yes/no or Pending exemption: only run/start/open are exempt (the change itself must be on screen)
    # An action item names its change: a command, a fence, a URL, a path with an
    # extension (".github/workflows/ci.yml"), file:line, or a quoted phrase to type.
    cmd = "```|`[^`]+`|https://|[A-Za-z0-9_./-]+\\.(ya?ml|kts?|sh|md|json|sql|java|py|html|toml|properties|xml|gradle|env|txt)([^A-Za-z]|$)|[A-Za-z0-9_-]*[./][A-Za-z0-9_./-]*:[0-9]+|\"[^\"]{5,}\""
    # Pointer payload (issue #680): a code span / fence or a file path. A URL or a quoted phrase is not one.
    cmd_ptr = "```|`[^`]+`|[A-Za-z0-9_./-]+\\.(ya?ml|kts?|sh|md|json|sql|java|py|html|toml|properties|xml|gradle|env|txt)([^A-Za-z]|$)|[A-Za-z0-9_-]*[./][A-Za-z0-9_./-]*:[0-9]+"
    # The one incident phrase: the operator is told to do it "yourself" / "on your end".
    pointer = "(^|[^a-z])(yourself|yourselves|(on|at) your (end|side))([^a-z]|$)"
    nothing = "^[[:space:]]*(nothing to do|nothing needed|nothing is needed|nothing needed from you)"
    dono = "^[[:space:]]*(\\*\\*)?do now(\\*\\*)?:"
    pend = "^[[:space:]]*(\\*\\*)?pending your approval(\\*\\*)?:"
    bl = 0; ispend = 0
    infence = 0; item = ""; first = ""; n = 0; nn = 0; nd = 0; np = 0
}
{
    line = $0; l = tolower(line)
    if (line ~ fence) {
        infence = !infence
        if (item != "") item = item "\n" line
        next
    }
    if (infence) { if (item != "") item = item "\n" line; next }
    if (l ~ back) hits[++n] = "backref: " line
    if (line ~ /^[[:space:]]*[0-9]+[.)][[:space:]]/ && !bl++) hits[++n] = "bare-list: " line
    if (line ~ /^[[:space:]]*-[[:space:]]+\*\*[A-Za-z][0-9]+\*\*/ || l ~ pend) {
        flush_item(); item = line; first = line; ispend = (l ~ pend)
    } else if (item != "") {
        if (line ~ /^[[:space:]]*$/ || line ~ /^(#|\*\*)/ ) flush_item()
        else item = item "\n" line
    }
    if (l ~ nothing) nn++
    if (l ~ dono) nd++
    if (l ~ pend) np++
}
END {
    flush_item()
    if (nn + nd + np >= 2) hits[++n] = "two-endings: " nn " nothing-line(s), " nd " Do now, " np " Pending your approval"
    for (i = 1; i <= n; i++) print hits[i]
}')"

# stale-window (issue #841): needs the project's worktrees, so it is a bash pass.
stale_window_hits() {
    [ -n "$PROJECT" ] && [ -d "$PROJECT" ] || return 0
    local self_dir lister wt issue f p
    local -A hold_issue=() hold_pr=()
    self_dir="$(cd "$(dirname "$0")" && pwd)"
    lister="$self_dir/list-own-worktrees.sh"
    while IFS= read -r wt; do
        [ -n "$wt" ] && [ -e "$wt/.swarm/sidelined" ] || continue
        issue="$(basename "$wt")"; issue="${issue#wt-issue-}"
        hold_issue[$issue]=1
        for f in "$wt"/.swarm/tasks/status/*.json "$wt"/.swarm/tasks/done/*.json; do
            [ -e "$f" ] || continue
            p="$(jq -r '.pr // empty' "$f" 2>/dev/null)"
            [[ "$p" =~ ^[0-9]+$ ]] && hold_pr[$p]=1
        done
    done < <("$lister" "$PROJECT" 2>/dev/null)
    [ "${#hold_issue[@]}" -gt 0 ] || return 0
    local block n
    while IFS= read -r block; do
        printf '%s' "$block" | tr 'A-Z' 'a-z' \
            | grep -E "(in|into) (its|the|that|their) ((iss-[0-9]+|worker|worker.s) )*(window|pane)" >/dev/null || continue
        while IFS= read -r n; do
            [ -n "$n" ] || continue
            if [ -n "${hold_pr[$n]:-}" ] || [ -n "${hold_issue[$n]:-}" ]; then
                echo "stale-window: ${block:0:200}"; break
            fi
        done < <(printf '%s' "$block" | grep -oiE '(PR[ #/]*|pull/|iss-|#)[0-9]+' | grep -oE '[0-9]+')
    done < <(printf '%s\n' "$text" | awk '
        function out() { if (b != "") print b; b = "" }
        /^[[:space:]]*-[[:space:]]+\*\*[A-Za-z][0-9]+\*\*/ { out(); b = $0; next }
        /^[[:space:]]*$/ || /^(#|\*\*)/ { out(); next }
        { if (b != "" && $0 ~ /^[[:space:]]/) b = b " " $0; else { out(); b = $0 } }
        END { out() }')
}
# issue-merged (issue #716): "#N merges" where #N is an issue. Candidates are a
# "#N" within two words of merge/merges/merged/merging on one line (either order,
# "merge conflict" excluded, fenced lines skipped); each distinct N is resolved
# with `gh api repos/{owner}/{repo}/issues/N` (run in --project, else the cwd) and
# flagged only when GitHub says it is not a pull request. A lookup that fails
# (offline, 404, no gh) never flags: the rule only fires on a confirmed issue.
issue_merged_hits() {
    command -v gh >/dev/null 2>&1 || return 0
    local w='[A-Za-z0-9_'"'"'-]+' mw='merg(e|es|ed|ing)' line n verdict looked=0
    local -A is_issue=(); local t0=$SECONDS
    local pf="(PR|pull[[:space:]]+request)[[:space:]]+for"
    local fwd="(${pf}[[:space:]]+)?#[0-9]+([[:space:]]+$w){0,2}[[:space:]]+$mw([^A-Za-z]|\$)"
    local rev="(^|[^A-Za-z])$mw([[:space:]]+$w){0,2}[[:space:]]+#[0-9]+"
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        local cands body; body="$(printf '%s\n' "$line" | sed -E "s/${mw}[[:space:]]+conflicts?//Ig")"
        # Dropped: "merge conflict" (stripped first), "the fix PR for #N merges" (the suggested wording), and
        # a rev match whose gap crosses a conjunction ("PR #1913 merges and #1910 closes").
        cands="$( { printf "%s\n" "$body" | grep -oiE "$fwd" | grep -viE "^$pf" | grep -oE '#[0-9]+'
                    printf "%s\n" "$body" | grep -oiE "$rev" | grep -viE "[[:space:]](and|or|but|then|while|which|that)[[:space:]]|${pf}[[:space:]]+#" | grep -oE '#[0-9]+$'; } | tr -d "#" | sort -un)"
        local hit=0
        while IFS= read -r n; do
            [ -n "$n" ] || continue
            if [ -z "${is_issue[$n]+x}" ]; then
                [ "$looked" -lt 10 ] && [ $((SECONDS - t0)) -lt 15 ] || continue    # cap: 10 calls and 15s in total per reply (the Stop hook gets 60s)
                looked=$((looked + 1))
                verdict="$( cd "${PROJECT:-.}" 2>/dev/null && timeout 5 gh api "repos/{owner}/{repo}/issues/$n" --jq '.pull_request != null' 2>/dev/null )" || verdict=""
                case "$verdict" in false) is_issue[$n]=1 ;; *) is_issue[$n]=0 ;; esac
            fi
            [ "${is_issue[$n]}" = 1 ] && hit=1
        done <<<"$cands"
        [ "$hit" = 1 ] && echo "issue-merged: $line"
    done < <(printf '%s\n' "$text" | awk -v fence="$FENCE_RE" '$0 ~ fence { f = !f; next } !f')
}

# carryover (issue #646): see the rule text in the header. Fenced lines are skipped; code
# spans and URLs are blanked before matching so a command or link never reads as a label.
carryover_hits() {
    printf '%s\n' "$text" | awk -v fence="$FENCE_RE" -v gloss="$GLOSS" -v dbg="$WHY" '
    function nwords(s,   a) { return split(s, a, /[ \t]+/) - (s ~ /^[ \t]/) - (s ~ /[ \t]$/) }
    function skip_label(t) { return t ~ /^(q[1-4]|s3|v[0-9]+|x[0-9]+|p[0-3]|i18n|l10n)$/ }
    BEGIN {
        phrase = "§ ?[0-9]|from earlier|carried over|carry-over|carryover|as noted|noted (earlier|above|before)|as (discussed|mentioned)|(mentioned|discussed|described|listed) (earlier|before|previously)|(from|in) (an |the )?(earlier|previous|prior|last) (digest|report|reply|wake|session)"
        # A label is a letter+digits (A12, B3) and only counts with a reference cue: after "your" /
        # "see" / "per", or bare at the start of a line. Mid-sentence "H2 database", "p95", "G1 GC" are not labels.
        lab = "(^|[^A-Za-z0-9_#/.-])(your|see|per) [A-Za-z][0-9]{1,2}([^A-Za-z0-9_]|$)"
        lead = "^[A-Za-z][0-9]{1,2}($|[,;)]| (below|above|earlier|please|again|too|and|plus|is|was|still)([^A-Za-z]|$))"
    }
    $0 ~ fence { inf = !inf; next }
    inf { next }
    {
        raw = $0; c = $0
        gsub(/`[^`]*`/, " ", c); gsub(/https?:\/\/[^ )>\]]*/, " ", c)
        n++; R[n] = raw; C[n] = c
        # definitions: a line that starts with the label, or an inline "X:" / "X (" / "X —"
        s = c; sub(/^[ \t>|*#-]+/, "", s); gsub(/\*\*/, "", s)
        if (match(s, /^[A-Za-z][0-9]{0,2}([)\].:|]|[ ]*[—–=-]|$)/) || raw ~ /^[ \t>-]*\*\*[A-Za-z][0-9]{0,2}([ *:.)]|$)/) {
            d = s; sub(/[^A-Za-z0-9].*$/, "", d); def[tolower(d)] = 1
        }
        t = c
        while (match(t, /(^|[^A-Za-z0-9_])[A-Za-z][0-9]{0,2}[ ]?(:|\(|[—–=]|--| - )/)) {
            d = substr(t, RSTART, RLENGTH); gsub(/^[^A-Za-z]+|[^A-Za-z0-9].*$/, "", d); def[tolower(d)] = 1
            t = substr(t, RSTART + RLENGTH)
        }
    }
    END {
        for (i = 1; i <= n; i++) {
            c = C[i]; l = tolower(c); bad = 0; why = ""; others = 0
            # explanation available: the other words on this line, plus the block it introduces
            # when it ends in a colon ("Needs you (carried over):" then the restated items)
            ctx = 0
            if (c ~ /:(\*\*)?[ \t]*$/) {
                for (j = i + 1; j <= n && C[j] ~ /^[ \t]*$/; j++) ;
                for (; j <= n && C[j] !~ /^[ \t]*$/ && ctx < 200; j++) ctx += nwords(C[j])
            }
            if (match(l, phrase)) { bad = 1; why = "phrase: " substr(l, RSTART, RLENGTH); others = nwords(substr(l, 1, RSTART - 1) " " substr(l, RSTART + RLENGTH)) }
            else others = nwords(c) - 1
            t = l
            while (!bad && match(t, lab)) {
                d = substr(t, RSTART, RLENGTH); sub(/^.*(your|see|per) /, "", d); gsub(/[^A-Za-z0-9]/, "", d)
                if (!skip_label(tolower(d)) && !(tolower(d) in def)) { bad = 1; why = "label: " d }
                t = substr(t, RSTART + RLENGTH - 1)
            }
            # a same-letter range of list labels ("M1-M3") is a reference too
            if (!bad && match(l, /(^|[^a-z0-9_#\/.-])[a-z][0-9]{1,2}(–|-)[a-z][0-9]{1,2}([^a-z0-9_]|$)/)) {
                t = substr(l, RSTART, RLENGTH); gsub(/^[^a-z]+|[^a-z0-9]+$/, "", t); d = substr(t, 1, 1)
                if (d == substr(t, index(t, "-") + 1, 1) && !(d in def) && !(substr(t, 1, index(t, "-") - 1) in def)) { bad = 1; why = "label-range: " t }
            }
            s = c; sub(/^[ \t>|*#-]+/, "", s); gsub(/\*\*/, "", s)
            if (!bad && match(s, lead)) {
                d = s; sub(/[^A-Za-z0-9].*$/, "", d)
                if (!skip_label(tolower(d)) && !(tolower(d) in def)) { bad = 1; why = "label: " d }
            }
            t = c
            if (!bad && match(t, /(^|[^A-Za-z0-9])[A-H](–|-)[A-H]([^A-Za-z0-9]|$)/)) {
                d = substr(t, RSTART, RLENGTH); gsub(/^[^A-H]+/, "", d); d = tolower(substr(d, 1, 1))
                if (!(d in def)) { bad = 1; why = "range: " d }
            }
            if (!bad && (match(t, /(option|item|choice|pick|follow-ups?|your) [A-H]([^A-Za-z0-9]|$)/) || match(t, /[(,;:—-] ?[A-H] recommended/) || match(t, /your [a-z]\)/))) {
                d = substr(t, RSTART, RLENGTH); gsub(/ recommended/, "", d); gsub(/[^A-Za-z]*$/, "", d); gsub(/^.* /, "", d); d = tolower(d)
                if (!(d in def)) { bad = 1; why = "ref: " d }
            }
            if (bad && others + ctx < gloss) { print "carryover: " R[i]; if (dbg) print "  why " why " (" others "+" ctx " words)" > "/dev/stderr" }
        }
    }'
}

# lede-identifier (issue #979): see the rule text in the header.
lede_hits() {
    printf '%s\n' "$text" | awk -v fence="$FENCE_RE" '
    function isid(w,   b) {
        if (w ~ /^`/ || w ~ /^#[0-9]+/) return 1
        b = w; gsub(/^[("\[*]+|[)"\]*,;:!?.]+$/, "", b)
        if (b ~ /^`/ || b ~ /^#[0-9]+$/) return 1
        if (b ~ /\// || b ~ /[A-Za-z0-9_-]\.(sh|md|json|ya?ml|kts?|sql|java|py|html|toml|xml|gradle|env|txt|jsonl|log)$/) return 1
        if (b ~ /^[A-Z][A-Z0-9]*(_[A-Z0-9]+)+$/) return 1
        if (b ~ /^[0-9a-f]{7,40}$/ && b ~ /[0-9]/ && b ~ /[a-f]/) return 1
        return 0
    }
    function plain(w,   b) {
        b = tolower(w); gsub(/[^a-z0-9]/, "", b)
        if (b == "" || b ~ /[0-9]/) return 0
        return !(b in skip)
    }
    BEGIN {
        n = split("pr prs issue issues migration migrations script scripts commit commits branch worker workers file files sha pull request the a an and or of to for in on at is are was were with from by", s, " ")
        for (i = 1; i <= n; i++) skip[s[i]] = 1
    }
    $0 ~ fence { inf = !inf; next }
    inf || $0 ~ /^[[:space:]]*$/ { next }
    done { next }
    {
        line = $0
        if (!seen_woke && tolower(line) ~ /^[[:space:]*_>-]*woke for:/) { seen_woke = 1; next }
        done = 1
        sub(/^[[:space:]>#*_-]+/, "", line); sub(/^[A-Za-z][0-9]{1,2}[*:.)]+[[:space:]]+/, "", line)   # list bullet and its A1 label
        if (match(line, /\. /)) line = substr(line, 1, RSTART)
        else sub(/\.[[:space:]]*$/, "", line)
        nw = split(line, w, /[[:space:]]+/); pl = 0
        for (i = 1; i <= nw && i <= 6; i++) {
            if (isid(w[i])) { if (pl < 2) print "lede-identifier: " $0; break }
            if (plain(w[i])) pl++
        }
    }'
}

want() { [ -z "$ONLY" ] || [[ "$ONLY" == *",$1,"* ]]; }
stale=""; issue=""; carry=""; lede=""
want stale-window && stale="$(stale_window_hits)"
want issue-merged && issue="$(issue_merged_hits)"
want carryover && carry="$(carryover_hits)"
want lede-identifier && lede="$(lede_hits)"
all="$(printf '%s\n%s\n%s\n%s\n%s\n' "$hits" "$stale" "$issue" "$carry" "$lede" | sed '/^$/d')"
if [ -n "$ONLY" ]; then
    all="$(printf '%s\n' "$all" | awk -v only="$ONLY" '{ split($0, p, ":"); if (index(only, "," p[1] ",")) print }')"
fi
[ -z "$all" ] && exit 0
printf '%s\n' "$all"
exit 3
