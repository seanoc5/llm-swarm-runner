#!/usr/bin/env bash
#
# replay-work-run.sh — dry replay of ONE fresh coordinator work run against a
# copy of a real past inbox, with every outside effect stubbed (issue #768,
# ADR 0006 section 9 step A5).
#
# Question it answers: given only files (no chat memory), does a fresh run pick
# the same actions the resident coordinator picked on that wake?
#
# Usage:
#   replay-work-run.sh --out DIR --fixtures DIR (--inbox-src DIR --files a.md,b.md
#                       | --transcript T.jsonl --from ISO --to ISO)
#                      [--project-kind self|synthetic] [--asof ISO] [--windows "coordinator util iss-1"]
#                      [--repo OWNER/NAME] [--env KEY=VAL]... [--prompt TEXT]
#                      [--model ID] [--budget USD] [--timeout SECS] [--cmd SHELLCMD]
#
#   --inbox-src/--files   copy these archived inbox files (this repo's processed/)
#   --transcript/--from/--to
#                         rebuild the inbox from `cat .swarm/coord-inbox/*.md`
#                         output the resident saw in that transcript window (for
#                         swarms whose inbox archive is not on this host), and
#                         recover worker outcome JSONs the same way
#   --fixtures DIR        output of scripts/replay-gh-fixtures.sh
#   --asof ISO            with --project-kind self: cut the project's git history at
#                         this time, so the run cannot see commits from after the wake
#   --cmd SHELLCMD        test hook: run this instead of `claude -p` (no model cost)
#
# What is real and what is stubbed:
#   real     the work prompt, shared rules, and scripts (a COPY under DIR/swarm),
#            `claude -p` on the coordinator model, jq/git/sed/etc.
#   stubbed  gh (reads served from the fixtures, writes recorded and not sent),
#            tmux (list-windows from --windows, everything else recorded),
#            docker (reads show an empty host; stop/kill/rm/run recorded),
#            swarm-merge, requeue, provision-worker, llm-start, pr-ready,
#            self-review-pr, ci-wait, kill-finished-workers, stale-pr-nudges,
#            operator-note, capture-worker (recorded, not run)
#   safety   the run gets no GH_TOKEN/GITHUB_TOKEN, no MCP servers (mail, drive,
#            calendar: a claude shim adds --strict-mcp-config) and no tmux socket path; the
#            project clone has no git remote. HOME is a scratch directory (DIR/home) holding
#            only the claude.ai login (claudeAiOauth, no MCP tokens) and a bare gitconfig, so
#            the real gh, git and ssh find no credentials by default and the real
#            ~/.config/gh/hosts.yml is not under HOME. THIS IS NOT A SANDBOX: the run uses
#            --dangerously-skip-permissions and the same unix user, so a model that goes out
#            of its way can still read the real home by absolute path or reach /usr/bin/gh
#            with a token it finds. Runs made before this HOME change (R1, R2c, A1 in
#            docs/replay-768-report.md) used the real HOME.
#
# Output in DIR: actions.tsv (every stubbed write, in order), work-run/ (log,
# runs.log with tokens and cost), project/.swarm (digest, needs-you, inbox
# state after the run), summary.txt.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="" FIX="" SRC="" FILES="" TRANSCRIPT="" FROM="" TO="" KIND=self WINDOWS="coordinator util"
ASOF="" REPO="OWNER/REPO" PROMPT="Run once." MODEL="${COORD_MODEL:-claude-opus-5-5}" BUDGET=5 TIMEOUT=1200 CMD=""
EXTRA_ENV=()
while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT="${2:?}"; shift 2 ;;
        --fixtures) FIX="${2:?}"; shift 2 ;;
        --inbox-src) SRC="${2:?}"; shift 2 ;;
        --files) FILES="${2:?}"; shift 2 ;;
        --transcript) TRANSCRIPT="${2:?}"; shift 2 ;;
        --from) FROM="${2:?}"; shift 2 ;;
        --to) TO="${2:?}"; shift 2 ;;
        --project-kind) KIND="${2:?}"; shift 2 ;;
        --windows) WINDOWS="${2:?}"; shift 2 ;;
        --repo) REPO="${2:?}"; shift 2 ;;
        --asof) ASOF="${2:?}"; shift 2 ;;
        --env) EXTRA_ENV+=("${2:?}"); shift 2 ;;
        --prompt) PROMPT="${2:?}"; shift 2 ;;
        --model) MODEL="${2:?}"; shift 2 ;;
        --budget) BUDGET="${2:?}"; shift 2 ;;
        --timeout) TIMEOUT="${2:?}"; shift 2 ;;
        --cmd) CMD="${2:?}"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done
[ -n "$OUT" ] && [ -n "$FIX" ] || { echo "usage: replay-work-run.sh --out DIR --fixtures DIR (--inbox-src DIR --files LIST | --transcript T --from ISO --to ISO) [...]" >&2; exit 2; }
if [ -z "$TRANSCRIPT" ] && { [ -z "$SRC" ] || [ -z "$FILES" ]; }; then
    echo "need --inbox-src and --files, or --transcript" >&2; exit 2
fi
command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }
[ ! -e "$OUT/project" ] || { echo "refusing to reuse $OUT (project/ exists); pick a fresh --out" >&2; exit 1; }
mkdir -p "$OUT" && OUT="$(cd "$OUT" && pwd)" || exit 1
FIX="$(cd "$FIX" && pwd)" || exit 1
mkdir -p "$OUT/swarm" "$OUT/bin" "$OUT/worktrees" "$OUT/fixtures"
cp -a "$FIX"/. "$OUT/fixtures/"
ACTIONS="$OUT/actions.tsv"; : > "$ACTIONS"

# ── 1. a copy of the llm-swarm-runner scripts/prompts the run will call ──────
cp -a "$ROOT/prompts" "$ROOT/scripts" "$ROOT/docs" "$OUT/swarm/"
[ -f "$ROOT/.env.example" ] && cp "$ROOT/.env.example" "$OUT/swarm/"

# ── 2. stubs ────────────────────────────────────────────────────────────────
# Recorder: logs "<epoch>\t<name>\t<args>" and prints a plausible success line.
RECORDER='#!/usr/bin/env bash
n="$(basename "$0")"
a="$*"; a="${a//$'"'"'\n'"'"'/ \\n }"
printf "%s\t%s\t%s\n" "$(date +%s)" "$n" "${a:0:600}" >> "$REPLAY_ACTIONS"
# A recorded reply for this call (fixtures/stub-out/<script>-<first arg>.txt),
# e.g. the review verdict the resident coordinator actually got.
so="${REPLAY_FIXTURES:-/nonexistent}/stub-out/$n-${1:-}.txt"
if [ -f "$so" ]; then cat "$so"; exit 0; fi
case "$n" in
    capture-worker.sh) echo "(replay: no live pane to capture)" ;;
    ci-wait.sh) echo "(replay: ci-wait not run; treat CI as the fixture shows)"; exit 0 ;;
    self-review-pr.sh) echo "(replay: independent review not run)" ;;
    *) echo "(replay: $n recorded, not run)" ;;
esac
exit 0'
for s in swarm-merge.sh worker-merge.sh requeue.sh provision-worker.sh llm-start.sh pr-ready.sh \
         self-review-pr.sh ci-wait.sh kill-finished-workers.sh stale-pr-nudges.sh \
         operator-note.sh capture-worker.sh file-followups.sh sideline-worker.sh; do
    printf '%s\n' "$RECORDER" > "$OUT/swarm/scripts/$s"; chmod +x "$OUT/swarm/scripts/$s"
done

# gh stub: reads from $REPLAY_FIXTURES, writes recorded.
# Known gaps (also in docs/replay-768-report.md): `pr list` and `issue list` honour only
# --state open|all (so --state closed returns an empty list) and ignore --search,
# --head, --base, --label, --author and --assignee; `pr diff` has no fixture.
cat > "$OUT/bin/gh" <<'GH'
#!/usr/bin/env bash
# replay stub for gh — see scripts/replay-work-run.sh
F="${REPLAY_FIXTURES:?}"
args=("$@"); rec() { local a="$*"; a="${a//$'\n'/ \\n }"; printf '%s\t%s\t%s\n' "$(date +%s)" "gh" "${a:0:600}" >> "$REPLAY_ACTIONS"; }
# strip -R/--repo
clean=(); i=0
while [ $i -lt ${#args[@]} ]; do
    case "${args[i]}" in -R|--repo) i=$((i+2)); continue ;; esac
    clean+=("${args[i]}"); i=$((i+1))
done
set -- "${clean[@]}"
group="${1:-}"; verb="${2:-}"
sel() {  # sel <file> ; honors --json f1,f2 and --jq/-q expr from the remaining args
    local file="$1"; shift
    local fields="" expr="" has_json=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --json) fields="$2"; has_json=1; shift 2 ;;
            --jq|-q) expr="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    local data
    if [ $has_json = 1 ]; then
        data="$(jq -c --arg f "$fields" '
            def pick($o): ($f|split(",")) | map({key:., value:$o[.]}) | from_entries;
            if type == "array" then map(. as $o | pick($o)) else . as $o | pick($o) end' "$file")"
    else
        data="$(jq -c . "$file")"
    fi
    if [ -n "$expr" ]; then printf '%s' "$data" | jq -r "$expr"; else printf '%s\n' "$data" | jq .; fi
}
nofix() { echo "gh: replay has no fixture for: gh $*" >&2; exit 1; }
case "$group $verb" in
    "pr view"|"issue view")
        n="$3"; [[ "$n" =~ ^[0-9]+$ ]] || nofix "$@"
        f="$F/${group}-$n.json"; [ -f "$f" ] || nofix "$@"
        if jq -e 'has("error")' "$f" >/dev/null 2>&1; then echo "GraphQL: Could not resolve to a $group with the number of $n." >&2; exit 1; fi
        sel "$f" "${@:4}" ;;
    "pr list"|"issue list")
        f="$F/${group}-list.json"; [ -f "$f" ] || nofix "$@"
        st=open; as=""; args2=("${@:3}"); j=0
        while [ $j -lt ${#args2[@]} ]; do
            case "${args2[j]}" in --state|-s) st="${args2[j+1]}" ;; --assignee) as="${args2[j+1]}" ;; esac; j=$((j+1))
        done
        tmp="$(mktemp)"; jq --arg st "$st" 'map(select($st=="all" or $st=="open"))' "$f" > "$tmp"
        sel "$tmp" "${@:3}"; rm -f "$tmp" ;;
    "pr checks")
        n="$3"; f="$F/pr-$n.json"; [ -f "$f" ] || nofix "$@"
        want_json=0; for a in "$@"; do [ "$a" = "--json" ] && want_json=1; done
        if [ "$want_json" = 1 ]; then
            # real gh: a JSON array of {name,bucket,link}; rc 1 on a fail, 8 on pending
            arr="$(jq -c '[.statusCheckRollup[]? | (.conclusion // .state // "") as $c | {name: (.name // .context), bucket: (if $c == "SUCCESS" or $c == "NEUTRAL" or $c == "SKIPPED" then "pass" elif $c == "FAILURE" or $c == "ERROR" then "fail" elif (.status // "") == "COMPLETED" then "pass" else "pending" end), link: (.detailsUrl // .targetUrl // "")}]' "$f")"
            printf '%s\n' "$arr"
            if jq -e 'any(.[]; .bucket == "fail")' <<<"$arr" >/dev/null; then exit 1
            elif jq -e 'any(.[]; .bucket == "pending")' <<<"$arr" >/dev/null; then exit 8; fi
            exit 0
        fi
        jq -r '.statusCheckRollup[]? | [(.name // .context), (if (.conclusion // .state) == "SUCCESS" then "pass" elif (.conclusion // .state) == "FAILURE" then "fail" elif (.status // "") == "COMPLETED" then "pass" else "pending" end), "0", (.detailsUrl // .targetUrl // "")] | @tsv' "$f"
        jq -e '[.statusCheckRollup[]? | (.conclusion // .state // "")] | all(. == "SUCCESS" or . == "NEUTRAL" or . == "SKIPPED")' "$f" >/dev/null && exit 0 || exit 1 ;;
    "pr diff") echo "gh: replay has no diff fixture (PR diffs are not captured)" >&2; exit 1 ;;
    "api user") echo "replay-operator" ;;
    "api "*|"api")
        # reads only: GET with no field flags; anything else is a write
        if printf '%s ' "$@" | grep -E -- '(-X|--method|-f|-F|--field|--raw-field|--input)' >/dev/null; then rec "$@"; echo '{}'; exit 0; fi
        nofix "$@" ;;
    "label list") echo "[]" ;;
    "repo view") echo '{"nameWithOwner":"'"${REPLAY_REPO:-OWNER/REPO}"'","defaultBranchRef":{"name":"master"}}' | jq -r "${3:-.}" 2>/dev/null || echo "${REPLAY_REPO:-OWNER/REPO}" ;;
    "auth status") echo "replay: not logged in (no token in replay)"; exit 0 ;;
    *)
        rec "$@"
        case "$group $verb" in
            "issue create"|"pr create") echo "https://github.com/${REPLAY_REPO:-OWNER/REPO}/${group}s/9999" ;;
            "pr merge") echo "(replay: merge recorded, not sent)" ;;
            *) : ;;
        esac
        exit 0 ;;
esac
GH
chmod +x "$OUT/bin/gh"

# claude shim: pin the claude binary this shell resolves (a clean PATH can find an
# older one that rejects current models) and drop every MCP server, so the run
# cannot reach mail, drive, calendar or any other connector the account has.
REAL_CLAUDE="$(command -v claude 2>/dev/null || true)"
if [ -n "$REAL_CLAUDE" ]; then
    printf '#!/usr/bin/env bash\nexec %q --strict-mcp-config --mcp-config %s "$@"\n' "$REAL_CLAUDE" "'{\"mcpServers\":{}}'" > "$OUT/bin/claude"
    chmod +x "$OUT/bin/claude"
fi

# tmux stub: list-windows from $REPLAY_WINDOWS, everything else recorded.
cat > "$OUT/bin/tmux" <<'TM'
#!/usr/bin/env bash
case "$*" in
    *list-windows*)
        for w in $REPLAY_WINDOWS; do
            case "$*" in *"#W"*|*"#{window_name}"*) echo "$w" ;; *) echo "0: $w (1 panes)" ;; esac
        done ;;
    *has-session*|*display-message*|*show-options*|*show-environment*|*list-panes*|*capture-pane*) exit 0 ;;
    *) a="$*"; printf '%s\t%s\t%s\n' "$(date +%s)" tmux "${a:0:600}" >> "$REPLAY_ACTIONS" ;;
esac
exit 0
TM
chmod +x "$OUT/bin/tmux"

# docker stub: the replay sees an empty host (no containers); stop/kill/rm/run/
# compose are recorded, never sent to the real daemon (the real one would show
# today's containers and `docker stop` would hit live workers).
cat > "$OUT/bin/docker" <<'DK'
#!/usr/bin/env bash
case "$1" in
    ps|images|info|version|inspect|logs|stats|port|top) exit 0 ;;
    container|image|network|volume|system)
        # `docker container stop/rm/kill` is the same write as `docker stop`: only the
        # read subcommands are silent, everything else is recorded.
        case "${2:-}" in ls|list|ps|inspect|logs|stats|port|top|history|df|info) exit 0 ;; esac
        a="$*"; printf '%s\t%s\t%s\n' "$(date +%s)" docker "${a:0:600}" >> "$REPLAY_ACTIONS" ;;
    *) a="$*"; printf '%s\t%s\t%s\n' "$(date +%s)" docker "${a:0:600}" >> "$REPLAY_ACTIONS" ;;
esac
exit 0
DK
chmod +x "$OUT/bin/docker"

# ── 3. the project the run works in ─────────────────────────────────────────
P="$OUT/project"
if [ "$KIND" = self ]; then
    git clone -q --no-hardlinks "$ROOT" "$P" || exit 1
    git -C "$P" remote remove origin 2>/dev/null
    if [ -n "$ASOF" ]; then
        # Cut history at the wake time: a run that sees later commits (the PRs
        # it is deciding about, already squash-merged) is not replaying that day.
        base="$(git -C "$ROOT" rev-list -1 --before="$ASOF" HEAD 2>/dev/null)"
        [ -n "$base" ] || { echo "no commit before $ASOF" >&2; exit 1; }
        git -C "$P" checkout -q -B master "$base" || exit 1
        git -C "$P" for-each-ref --format='%(refname)' | grep -v '^refs/heads/master$' | xargs -r -n1 git -C "$P" update-ref -d
        git -C "$P" reflog expire --expire=now --all && git -C "$P" gc -q --prune=now
    else
        git -C "$P" checkout -q -B master 2>/dev/null
    fi
else
    mkdir -p "$P" && git -C "$P" init -q -b master && git -C "$P" -c user.name=replay -c user.email=replay@invalid commit -q --allow-empty -m "replay root"
fi
mkdir -p "$P/.swarm/coord-inbox/processed" "$P/.swarm/tasks/done" "$P/.swarm/work-run"
{
    echo "SWARM_AUTOMERGE_LOW=1"
    for kv in "${EXTRA_ENV[@]:-}"; do [ -n "$kv" ] && echo "$kv"; done
} > "$P/.swarm/.env"

rewrite() {  # rewrite host paths in an inbox file to the replay tree
    sed -E \
        -e "s#/mnt/wd1t/worktrees/[A-Za-z0-9._-]+-worktrees#$OUT/worktrees#g" \
        -e "s#/opt/work/[A-Za-z0-9._/-]+-worktrees#$OUT/worktrees#g" \
        -e "s#/opt/work/llm-swarm-runner#$OUT/swarm#g" \
        -e "s#/opt/work/oconeco/[A-Za-z0-9._-]+#$P#g"
}

# ── 4. inbox + worker outcomes ──────────────────────────────────────────────
if [ -n "$TRANSCRIPT" ]; then
    # Rebuild inbox files from "== .swarm/coord-inbox/<name>" blocks that `cat`
    # printed in the window. A block ends at the next header or at the tmux
    # window list the resident printed right after (a line starting "coordinator ").
    jq -r --arg from "$FROM" --arg to "$TO" '
        select((.isSidechain // false) | not) | select(.type == "user" and .timestamp >= $from and .timestamp <= $to)
        | (.message.content | if type == "array" then .[] else empty end)
        | select(.type == "tool_result")
        | (.content | if type == "array" then (map(.text // "") | join("")) else (. // "") end)
        | select(test("== \\.swarm/coord-inbox/"))' "$TRANSCRIPT" \
    | awk -v dir="$P/.swarm/coord-inbox" '
        /^== \.swarm\/coord-inbox\// { n=$2; sub(".*/","",n); out=dir "/" n
            if (system("test -e \"" out "\"") == 0) out=""; next }
        /^coordinator / { out=""; next }
        out { print > out }'
else
    IFS=',' read -r -a FARR <<< "$FILES"
    for f in "${FARR[@]}"; do
        [ -f "$SRC/$f" ] || { echo "missing inbox file $SRC/$f" >&2; exit 1; }
        rewrite < "$SRC/$f" > "$P/.swarm/coord-inbox/$f"
    done
fi
# path rewrite for transcript-built files too
for f in "$P"/.swarm/coord-inbox/*.md; do [ -f "$f" ] && { rewrite < "$f" > "$f.tmp" && mv "$f.tmp" "$f"; }; done

# Worker outcome JSONs the inbox items point at. The worker worktrees were
# reaped long ago, so the file is rebuilt: from the transcript when it printed
# one, otherwise a stand-in carrying only what the inbox item itself says.
for f in "$P"/.swarm/coord-inbox/*.md; do
    [ -f "$f" ] || continue
    line="$(grep -E '^Triggering outcome: ' "$f" | sed -n 1p)" || true
    [ -n "$line" ] || continue
    iss="$(sed -E 's/.*issue=([0-9]+).*/\1/' <<<"$line")"
    oc="$(sed -E 's/.*outcome=([A-Za-z-]+).*/\1/' <<<"$line")"
    path="$(sed -E 's/.*path=([^ ]+).*/\1/' <<<"$line")"
    # Only write inside the replay tree. A path that `rewrite` missed (or one with ..) would
    # point at a real host file; refuse it rather than overwrite (issue #788).
    case "$path" in
        */../*|*/..) path="" ;;
        "$OUT"/worktrees/*|"$P"/*) ;;
        *) path="" ;;
    esac
    if [ -z "$path" ]; then
        echo "refused: outcome path in $(basename "$f") is outside the replay tree; no stand-in written" >&2
        printf 'refused_outcome\t%s\n' "$(basename "$f")" >> "$OUT/refused.txt"
        continue
    fi
    mkdir -p "$(dirname "$path")"
    tid="$(basename "$path" | sed -E 's/\.(ok|err|blocked|done-no-pr)(\.attempt[0-9]+)?\.json$//')"
    rec=""
    if [ -n "$TRANSCRIPT" ]; then
        rec="$(jq -r --arg from "$FROM" --arg to "$TO" --arg tid "$tid" '
            select((.isSidechain // false) | not) | select(.type == "user" and .timestamp >= $from and .timestamp <= $to)
            | (.message.content | if type == "array" then .[] else empty end) | select(.type == "tool_result")
            | (.content | if type == "array" then (map(.text // "") | join("")) else (. // "") end)
            | select(contains($tid)) | [match("\\{[^{}]*\"task_id\": *\"" + $tid + "\"[^{}]*\\}"; "g").string] | .[]' "$TRANSCRIPT" 2>/dev/null | sed -n 1p)"
    fi
    if [ -n "$rec" ] && printf '%s' "$rec" | jq -e . >/dev/null 2>&1; then
        printf '%s\n' "$rec" > "$path"
    else
        jq -n --arg t "$tid" --arg o "$oc" --argjson i "$iss" \
            '{task_id:$t, issue:$i, outcome:$o, exit_code:0, reconstructed:"stand-in: original outcome record was reaped; only the inbox item survives"}' > "$path"
    fi
done

# ── 5. run it ───────────────────────────────────────────────────────────────
if [ -z "$CMD" ] && [ "$(ls "$P/.swarm/coord-inbox"/*.md 2>/dev/null | wc -l)" -eq 0 ]; then
    echo "no inbox files were built; nothing to replay" >&2; exit 1
fi
printf 'items\t%s\n' "$(ls "$P/.swarm/coord-inbox"/*.md 2>/dev/null | wc -l)" > "$OUT/summary.txt"

# Scratch HOME: only what claude needs to log in. The credentials file also holds MCP
# OAuth tokens for other services, so copy just the claudeAiOauth key. REPLAY_AUTH_HOME
# is a test hook (where to take the login from).
AUTH_HOME="${REPLAY_AUTH_HOME:-$HOME}"
RH="$OUT/home"
mkdir -p "$RH/.claude" && chmod 700 "$RH"
if [ -f "$AUTH_HOME/.claude/.credentials.json" ]; then
    ( umask 077; jq -c '{claudeAiOauth: .claudeAiOauth} | with_entries(select(.value != null))' \
        "$AUTH_HOME/.claude/.credentials.json" > "$RH/.claude/.credentials.json" ) 2>/dev/null \
        || rm -f "$RH/.claude/.credentials.json"
fi
echo '{"hasCompletedOnboarding":true}' > "$RH/.claude.json"
printf '[user]\n\tname = replay\n\temail = replay@invalid\n' > "$RH/.gitconfig"

env -i HOME="$RH" PATH="$OUT/bin:/usr/local/bin:/usr/bin:/bin" \
    TERM="${TERM:-xterm}" LANG="${LANG:-C.UTF-8}" \
    LLM_SWARM_DIR="$OUT/swarm" REPLAY_ACTIONS="$ACTIONS" REPLAY_FIXTURES="$OUT/fixtures" \
    REPLAY_WINDOWS="$WINDOWS" REPLAY_REPO="$REPO" \
    COORD_MODEL="$MODEL" COORD_WORK_RUN_BUDGET_USD="$BUDGET" COORD_WORK_RUN_TIMEOUT_SECS="$TIMEOUT" \
    ${CMD:+COORD_WORK_RUN_CMD="$CMD"} \
    "$OUT/swarm/scripts/coord-work-run.sh" "$P" "$PROMPT"
rc=$?
rm -f "$RH/.claude/.credentials.json"   # do not leave a login token in the output dir
{
    echo "exit	$rc"
    echo "actions	$(wc -l < "$ACTIONS")"
    echo "runs_log	$(tail -n 1 "$P/.swarm/work-run/runs.log" 2>/dev/null)"
    echo "inbox_left	$(ls "$P/.swarm/coord-inbox"/*.md 2>/dev/null | wc -l)"
} >> "$OUT/summary.txt"
cat "$OUT/summary.txt"
exit "$rc"
