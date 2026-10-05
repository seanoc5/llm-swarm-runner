#!/usr/bin/env bash
# nightly-full-tests.sh — run each project's slow test lanes overnight, one
# repo after another, against a throwaway clone of origin's default branch.
#
# Why: workers run only the fast tier (prompts/worker.md "Verify once") and
# CI runs what each repo's workflow runs per PR. Everything else (integration
# where CI skips it, slow, functional, e2e, data-tree) ran nowhere or by hand.
# Generalized from corpusminder-spring's scripts/ci/run-deep-tests-local.sh
# (issue #282 there): disposable clone, skip-if-no-prerequisite, and a
# tracking-issue comment on failure.
#
# While it runs, new worker spawns are refused host-wide through
# $HOST_STATE_DIR/dispatch-paused (provision-worker.sh's admission check).
# Workers already running keep running; the pause carries an expiry so a
# crashed run can't hold dispatch.
#
# Usage:
#   nightly-full-tests.sh [--only <repo-basename>] [--no-pause] [--no-issue]
#
# Config: $NIGHTLY_CONF (default $LLM_SWARM_DIR/nightly-repos.conf, gitignored;
# see examples/nightly-repos.conf.example). One line per lane, repos in file order:
#   <repo_dir> <lane> <command...>     run <command> in the clone; exit 0 = pass
#   <repo_dir> @copy <path...>         copy untracked files (e.g. .env) from
#                                      <repo_dir> into the clone before lanes
#   <repo_dir> @issue-title <title...> tracking-issue title for that repo
#   <repo_dir> @needs-docker           skip (not fail) that repo's lanes when
#                                      Docker is unreachable (Testcontainers)
#
# Env: NIGHTLY_HOME (clones, default ~/.cache/swarm-nightly), NIGHTLY_LOG_DIR
# (default ~/.local/state/swarm-nightly), NIGHTLY_LOG_KEEP (14 runs),
# NIGHTLY_LANE_TIMEOUT (5400 s), NIGHTLY_PAUSE_SECS (21600 s).
#
# Exit: 0 every lane that ran passed; 1 a lane failed; 2 config/infra error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLM_SWARM_DIR="${LLM_SWARM_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
NIGHTLY_CONF="${NIGHTLY_CONF:-$LLM_SWARM_DIR/nightly-repos.conf}"
NIGHTLY_HOME="${NIGHTLY_HOME:-$HOME/.cache/swarm-nightly}"
LOG_ROOT="${NIGHTLY_LOG_DIR:-$HOME/.local/state/swarm-nightly}"
LOG_KEEP="${NIGHTLY_LOG_KEEP:-14}"
LANE_TIMEOUT="${NIGHTLY_LANE_TIMEOUT:-5400}"
PAUSE_SECS="${NIGHTLY_PAUSE_SECS:-21600}"
HOST_STATE_DIR="${HOST_STATE_DIR:-${TMPDIR:-/tmp}/llm-swarm-host-$(id -u)}"
DEFAULT_TITLE="nightly full-test failure tracking"

ONLY="" PAUSE=1 ISSUE=1
while [ $# -gt 0 ]; do
    case "$1" in
        --only) ONLY="${2:?--only needs a repo basename}"; shift ;;
        --no-pause) PAUSE=0 ;;
        --no-issue) ISSUE=0 ;;
        *) echo "usage: $0 [--only <repo>] [--no-pause] [--no-issue]" >&2; exit 2 ;;
    esac
    shift
done

[ -r "$NIGHTLY_CONF" ] || { echo "nightly: no config at $NIGHTLY_CONF (see examples/nightly-repos.conf.example)" >&2; exit 2; }

RUN_TS="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="$LOG_ROOT/$RUN_TS"
mkdir -p "$RUN_DIR" "$NIGHTLY_HOME"
log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$RUN_DIR/run.log"; }

# --- dispatch pause --------------------------------------------------------
PAUSE_FILE="$HOST_STATE_DIR/dispatch-paused"
if [ "$PAUSE" = 1 ]; then
    mkdir -p "$HOST_STATE_DIR"
    echo "$(( $(date +%s) + PAUSE_SECS )) nightly full-test run $RUN_TS (pid $$)" > "$PAUSE_FILE"
    trap 'rm -f -- "$PAUSE_FILE"' EXIT
    log "dispatch paused host-wide (expires in ${PAUSE_SECS}s at the latest)"
fi

# --- parse config ----------------------------------------------------------
declare -a REPOS=()
declare -A LANES COPIES TITLES DOCKER
while read -r dir lane rest; do
    case "$dir" in ''|'#'*) continue ;; esac
    [ -n "$ONLY" ] && [ "$(basename "$dir")" != "$ONLY" ] && continue
    [[ " ${REPOS[*]} " == *" $dir "* ]] || REPOS+=("$dir")
    case "$lane" in
        @copy)        COPIES[$dir]="${COPIES[$dir]:-} $rest" ;;
        @issue-title) TITLES[$dir]="$rest" ;;
        @needs-docker) DOCKER[$dir]=1 ;;
        *)            LANES[$dir]="${LANES[$dir]:-}$lane"$'\t'"$rest"$'\n' ;;
    esac
done < "$NIGHTLY_CONF"
[ "${#REPOS[@]}" -gt 0 ] || { log "no repos selected"; exit 2; }

docker_up() { docker info >/dev/null 2>&1; }

ANY_FAIL=0 INFRA=0
SUMMARY="| repo | lane | result | minutes |"$'\n'"|------|------|--------|---------|"$'\n'

for dir in "${REPOS[@]}"; do
    name="$(basename "$dir")"
    clone="$NIGHTLY_HOME/nightly-$name"   # distinct basename: fand-etl derives its test DB from it
    repo_log="$RUN_DIR/$name"; mkdir -p "$repo_log"
    repo_fail=0 repo_rows=""

    # sync the clone to origin's default branch
    url="$(git -C "$dir" remote get-url origin 2>/dev/null)" || { log "$name: no origin remote"; INFRA=1; continue; }
    [ -d "$clone/.git" ] || git clone -q "$url" "$clone" || { log "$name: clone failed"; INFRA=1; continue; }
    branch="$(git -C "$clone" remote show origin 2>/dev/null | sed -n 's/.*HEAD branch: //p')"
    branch="${branch:-master}"
    if ! { git -C "$clone" fetch -q origin "$branch" && git -C "$clone" checkout -q -B "$branch" "origin/$branch" \
           && git -C "$clone" clean -q -fdx; }; then
        log "$name: could not sync clone to origin/$branch"; INFRA=1; continue
    fi
    sha="$(git -C "$clone" rev-parse --short HEAD)"
    log "$name: clone at origin/$branch @ $sha"
    for f in ${COPIES[$dir]:-}; do
        [ -e "$dir/$f" ] && cp -a "$dir/$f" "$clone/$f" || log "$name: @copy $f missing in $dir"
    done

    while IFS=$'\t' read -r lane cmd; do
        [ -n "$lane" ] || continue
        if [ -n "${DOCKER[$dir]:-}" ] && ! docker_up; then
            result="skipped (Docker unreachable)"; mins="-"
        else
            log "$name/$lane: $cmd"
            t0=$(date +%s)
            (cd "$clone" && timeout --kill-after=60 "$LANE_TIMEOUT" bash -c "$cmd") > "$repo_log/$lane.log" 2>&1
            rc=$?
            mins=$(( ($(date +%s) - t0 + 59) / 60 ))
            case "$rc" in
                0)   result="pass" ;;
                124) result="FAIL (timeout ${LANE_TIMEOUT}s)"; repo_fail=1 ;;
                *)   result="FAIL (exit $rc)"; repo_fail=1 ;;
            esac
        fi
        log "$name/$lane: $result"
        repo_rows+="| $name | $lane | $result | $mins |"$'\n'
    done <<< "${LANES[$dir]:-}"
    SUMMARY+="$repo_rows"

    [ "$repo_fail" = 1 ] || continue
    ANY_FAIL=1
    [ "$ISSUE" = 1 ] && command -v gh >/dev/null || { log "$name: failure not filed (--no-issue or no gh)"; continue; }
    gh_repo="$(cd "$dir" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" || { log "$name: gh repo view failed"; continue; }
    title="${TITLES[$dir]:-$DEFAULT_TITLE}"
    body="Nightly run $RUN_TS failed at origin/$branch @ $sha. Logs on minti9: \`$repo_log\`"$'\n\n'
    body+="| lane | result | minutes |"$'\n'"|------|--------|---------|"$'\n'
    body+="$(sed 's/^| [^|]* |/|/' <<< "$repo_rows")"$'\n'
    for lf in "$repo_log"/*.log; do
        grep -q . "$lf" 2>/dev/null || continue
        lane="$(basename "$lf" .log)"
        grep -q "| $lane | FAIL" <<< "$repo_rows" || continue
        body+=$'\n'"<details><summary>$lane (last 60 lines)</summary>"$'\n\n```\n'"$(tail -n 60 "$lf")"$'\n```\n</details>\n'
    done
    body+=$'\n'"Posted by llm-swarm-runner \`scripts/nightly-full-tests.sh\`."$'\n\n'"— drafted by claude"
    num="$(gh issue list -R "$gh_repo" --state open --search "in:title \"$title\"" --json number -q '.[0].number' 2>/dev/null)"
    if [ -n "$num" ]; then
        gh issue comment "$num" -R "$gh_repo" --body "$body" >/dev/null && log "$name: commented on #$num" || log "$name: gh comment failed"
    else
        gh issue create -R "$gh_repo" --title "$title" --body "$body" >/dev/null && log "$name: opened tracking issue" || log "$name: gh issue create failed"
    fi
done

printf '# Nightly full tests %s\n\n%s' "$RUN_TS" "$SUMMARY" > "$RUN_DIR/summary.md"
cat "$RUN_DIR/summary.md"

# keep the newest $LOG_KEEP runs
ls -1dt "$LOG_ROOT"/*/ 2>/dev/null | tail -n +"$((LOG_KEEP + 1))" | xargs -r rm -rf

[ "$ANY_FAIL" = 1 ] && exit 1
[ "$INFRA" = 1 ] && exit 2
exit 0
