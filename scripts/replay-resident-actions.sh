#!/usr/bin/env bash
#
# replay-resident-actions.sh — list what a RESIDENT coordinator did on each
# wake, read from its Claude Code transcript (issue #768, ADR 0006 section 9
# step A5). This is the baseline side of the replay comparison; the other side
# is scripts/replay-work-run.sh.
#
# Usage:
#   replay-resident-actions.sh <transcript.jsonl> [--from <iso-ts>] [--to <iso-ts>]
#
# Output (TSV, one row per fact, in transcript order):
#   <ts>\twake\t<doorbell text, 100 chars>
#   <ts>\tread\t<inbox file name the coordinator opened>
#   <ts>\tact\t<state-changing command, one line, 200 chars>
#   <ts>\tsay\t<first line of a text reply>
#
# "act" rows are the commands that change something outside the coordinator's
# own files: merges, dispatches, GitHub writes, window kills, pushes. The
# patterns are the same ones replay-work-run.sh's stubs record, so the two
# sides can be compared by verb and target.
#
# Read-only: opens the transcript, writes nothing.

set -uo pipefail

TRANSCRIPT="${1:?usage: replay-resident-actions.sh <transcript.jsonl> [--from ts] [--to ts]}"
shift
FROM="" TO=""
while [ $# -gt 0 ]; do
    case "$1" in
        --from) FROM="${2:?}"; shift 2 ;;
        --to) TO="${2:?}"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done
[ -r "$TRANSCRIPT" ] || { echo "cannot read $TRANSCRIPT" >&2; exit 1; }

# Verbs that change state. Keep in step with the stub list in replay-work-run.sh
# (the `for s in swarm-merge.sh ...` loop) and its gh/tmux/docker stubs.
ACTION_RE='swarm-merge\.sh|worker-merge\.sh|pr-ready\.sh|self-review-pr\.sh|requeue\.sh|provision-worker\.sh|llm-start\.sh|gh (pr|issue) (merge|comment|edit|close|reopen|create|ready|review)|gh api .*(-X|--method) *(POST|PUT|PATCH|DELETE)|tmux (kill|send-keys|new-window)|docker (stop|kill|rm|run|compose)|sideline-worker\.sh|git (push|worktree (add|remove))|file-followups|operator-note\.sh'

jq -r --arg from "$FROM" --arg to "$TO" --arg re "$ACTION_RE" '
  select((.isSidechain // false) | not)
  | select(($from == "" or .timestamp >= $from) and ($to == "" or .timestamp <= $to))
  | if .type == "user" then
      ((.message.content | if type == "string" then . else (map(select(.type == "text").text) | join(" ")) end) // "") as $t
      | select($t | startswith("Inbox:") or startswith("Execute the Initial"))
      | [.timestamp, "wake", ($t | gsub("\n"; " ") | .[0:100])] | @tsv
    elif .type == "assistant" then
      .timestamp as $ts
      | (.message.content // [])
      | if type == "array" then . else [] end
      | .[]
      | if .type == "tool_use" and .name == "Bash" then
          (.input.command // "") as $c
          | ( [$c | scan("coord-inbox/[^ \"|)*]*[.]md")] | unique | .[] | [$ts, "read", (sub("^coord-inbox/"; ""))] | @tsv ),
            ( select($c | test($re)) | [$ts, "act", ($c | gsub("\n"; " \\n ") | .[0:200])] | @tsv )
        elif .type == "tool_use" and .name == "Read" then
          (.input.file_path // "") | select(test("coord-inbox/")) | [$ts, "read", (split("coord-inbox/")[1])] | @tsv
        elif .type == "text" then
          select((.text | length) > 0) | [$ts, "say", (.text | split("\n")[0] | .[0:160])] | @tsv
        else empty end
    else empty end
' "$TRANSCRIPT"
