#!/usr/bin/env bash
# test-coordinator-conversation.sh — scripts/coordinator-conversation.sh (issue #744):
# the clean conversation view shows operator messages and coordinator reply
# text only, hides every other transcript kind, picks the coordinator's own
# interactive session (never a worker's or a headless run), and follows a new
# session. No tmux, no claude; works on a fixture transcript.
set -euo pipefail
green() { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()   { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VIEW="$ROOT/scripts/coordinator-conversation.sh"
FIX="$ROOT/tests/fixtures/coordinator-conversation/session.jsonl"
T="$(mktemp -d -t coord-conv-XXXXXX)"
trap 'rm -rf "$T"' EXIT

# ── 1. fixture: exactly the SHOW lines, nothing HIDE ──
out="$("$VIEW" --file "$FIX" --once --tail 100)"
for want in SHOW-reply-one SHOW-operator-one SHOW-reply-two "SHOW-operator-two with a screenshot"; do
    grep -qF "$want" <<<"$out" || red "missing visible message: $want"
done
green "operator and coordinator messages shown"
if grep -n 'HIDE' <<<"$out"; then red "hidden kind leaked (lines above)"; fi
green "tool calls/results, thinking, doorbells, stop-hook text, task notifications, compaction, subagent and synthetic turns all hidden"
[ "$(grep -c '── you' <<<"$out")" = 2 ] && [ "$(grep -c '── coordinator' <<<"$out")" = 2 ] \
    || red "expected 2 operator + 2 coordinator messages"
green "message count and order"
first="$(grep -m1 -o 'SHOW-[a-z-]*' <<<"$out")"; [ "$first" = "SHOW-reply-one" ] || red "order wrong: $first"

# ── 2. --tail keeps only the last N messages ──
last="$("$VIEW" --file "$FIX" --once --tail 1)"
grep -qF "SHOW-operator-two" <<<"$last" && ! grep -qF "SHOW-reply-one" <<<"$last" || red "--tail 1 should keep only the last message"
green "--tail N"

# ── 3. session discovery ──
PROJ="$T/proj"; mkdir -p "$PROJ"
SLUG="$(printf '%s' "$(cd "$PROJ" && pwd -P)" | sed 's/[^A-Za-z0-9]/-/g')"
export CLAUDE_PROJECTS_DIR="$T/projects"
D="$CLAUDE_PROJECTS_DIR/$SLUG"; mkdir -p "$D" "$CLAUDE_PROJECTS_DIR/${SLUG}-worktrees-wt-issue-9"
rec() { printf '{"type":"assistant","entrypoint":"%s","timestamp":"2026-11-05T03:00:00.000Z","message":{"model":"m","role":"assistant","content":[{"type":"text","text":"%s"}]}}\n' "$1" "$2"; }
rec cli  "SHOW-coordinator-session" > "$D/aaa.jsonl"; touch -d '2026-11-05 03:00:00' "$D/aaa.jsonl"
rec sdk-cli "HIDE-headless-run"      > "$D/bbb.jsonl"; touch -d '2026-11-05 04:00:00' "$D/bbb.jsonl"
rec cli  "HIDE-worker-session"       > "$CLAUDE_PROJECTS_DIR/${SLUG}-worktrees-wt-issue-9/ccc.jsonl"
mkdir -p "$D/aaa"; rec cli "HIDE-subagent-dir" > "$D/aaa/sub.jsonl"
out="$("$VIEW" "$PROJ" --once)"
grep -qF SHOW-coordinator-session <<<"$out" && ! grep -q HIDE <<<"$out" || red "session discovery picked the wrong transcript: $out"
green "picks the interactive project session; ignores headless runs, worker dirs and subagent files"

# ── 4. read-only: nothing under the project or transcripts changed ──
before="$(find "$T" -type f -printf '%p %s %T@\n' | sort | md5sum)"
"$VIEW" "$PROJ" --once >/dev/null
[ "$before" = "$(find "$T" -type f -printf '%p %s %T@\n' | sort | md5sum)" ] || red "files changed"
green "read-only"

# ── 5. follow mode: new lines appear; a newer session is followed ──
log="$T/follow.out"
timeout 8 "$VIEW" "$PROJ" --interval 1 --tail 0 >"$log" 2>&1 &
vp=$!
sleep 2
rec cli "SHOW-appended-line" >> "$D/aaa.jsonl"
sleep 2.5
rec cli "SHOW-new-session" > "$D/ddd.jsonl"; touch -d 'now + 1 hour' "$D/ddd.jsonl"
sleep 2.5
wait "$vp" 2>/dev/null || true
grep -qF SHOW-appended-line "$log" || red "appended line not followed: $(cat "$log")"
grep -qF SHOW-new-session "$log" || red "new session not followed: $(cat "$log")"
! grep -q HIDE "$log" || red "follow leaked hidden text"
green "follows appended lines and a newer session"
echo "all coordinator-conversation checks passed"
