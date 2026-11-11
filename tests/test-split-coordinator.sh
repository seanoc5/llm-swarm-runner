#!/usr/bin/env bash
# test-split-coordinator.sh — issue #767 (ADR 0006 sections 1, 4, 6):
# COORD_MODE=split. Covers the operator-note helper, the prompt split, the
# 📥 window flag, the UserPromptSubmit needs-you hook, the llm-start.sh /
# coordinator-claude.sh wiring, and that resident mode is unchanged.
#
# No real tmux server and no claude: tmux is a PATH stub with a real
# @swarm_flag store (set / show / unset round-trip), claude a stub that
# records argv. The interactive-REPL check of the hook is a separate manual
# step (docs/split-coordinator.md); this suite drives the hook with the JSON
# Claude Code sends.
set -euo pipefail

green() { printf '\033[32m✓ %s\033[0m\n' "$*"; }
red()   { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
check() { [ "$2" = "$3" ] && green "$1" || red "$1 (expected [$2] got [$3])"; }
heading() { printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NOTE="$ROOT/scripts/operator-note.sh"
RENDER="$ROOT/scripts/render-coordinator-prompt.sh"
HOOK="$ROOT/scripts/coord-hook.sh"
WATCH="$ROOT/scripts/coordinator-watch.sh"
export LLM_SWARM_DIR="$ROOT"      # the host may point this at another install
unset COORD_MODE COORD_HOOK_STATE COORD_INBOX_WAITER CLAUDE_CODE_DISABLE_BACKGROUND_TASKS

T="$(mktemp -d -t split-coord-XXXXXX)"
trap 'rm -rf "$T"' EXIT
P="$T/proj"; mkdir -p "$P/.swarm/coord-inbox" "$T/bin" "$T/flags"

# tmux stub: only the @swarm_flag calls scripts/_window-flags.sh makes, backed
# by files in $T/flags; every call is also logged.
cat > "$T/bin/tmux" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$T/tmux.log"
args=("\$@"); target=""; mode=show; val=""
for ((i = 0; i < \${#args[@]}; i++)); do
    case "\${args[i]}" in
        -t) target="\${args[i+1]}" ;;
        -u) mode=unset ;;
        @swarm_flag) [ "\${args[i-1]}" = "-v" ] || val="\${args[i+1]:-}" ;;
    esac
done
f="$T/flags/\${target//:/_}"
case "\${args[0]}" in
    show-window-options) [ -f "\$f" ] && cat "\$f"; exit 0 ;;
    set-window-option) if [ "\$mode" = unset ]; then rm -f "\$f"; else printf '%s' "\$val" > "\$f"; fi; exit 0 ;;
esac
exit 0
EOF
chmod +x "$T/bin/tmux"
export PATH="$T/bin:$PATH"
flag() { cat "$T/flags/llm-proj_coordinator" 2>/dev/null || true; }
# COORD_MODE lives only in <project>/.swarm/.env (#767): tests flip it there.
setmode() {   # <dir> <split|resident|banana|unset>
    mkdir -p "$1/.swarm"
    case "$2" in unset) rm -f "$1/.swarm/.env" ;; *) printf 'FOO=1\nCOORD_MODE=%s\n' "$2" > "$1/.swarm/.env" ;; esac
}

# ── operator-note.sh ─────────────────────────────────────────────────────────
heading "operator-note.sh"
out="$("$NOTE" --project "$P" "dispatch #123 now")"
base="${out##*/}"
[[ "$base" =~ ^[0-9]{8}T[0-9]{6}Z-operator-[0-9]+-[0-9]+\.md$ ]] && got=named || got="[$base]"
check "inbox file is <ts>-operator-<pid>-<rand>.md" "named" "$got"
check "inbox file lives in .swarm/coord-inbox/" "$P/.swarm/coord-inbox" "${out%/*}"
grep -q 'dispatch #123 now' "$out" && got=yes || got=no
check "the note text is in the file" "yes" "$got"
check "a one-off note does not touch operator-notes.md" "no" "$([ -e "$P/.swarm/operator-notes.md" ] && echo yes || echo no)"
ls "$P/.swarm/coord-inbox"/.tmp.* >/dev/null 2>&1 && got=left || got=clean
check "no temp file left in the inbox" "clean" "$got"

# The existing classifier treats the kind as urgent without any change.
# shellcheck source=scripts/_coord-inbox-batch.sh
. "$ROOT/scripts/_coord-inbox-batch.sh"
check "kind parses as operator" "operator" "$(coord_item_kind "$out")"
check "an operator note is urgent (unknown kinds always are)" "urgent" "$(coord_item_urgency "$out")"

out2="$("$NOTE" --project "$P" "second")"; out3="$("$NOTE" --project "$P" "third")"
check "three quick notes give three distinct files" "3" "$(printf '%s\n' "$out" "$out2" "$out3" | sort -u | wc -l | tr -d ' ')"

s="$("$NOTE" --project "$P" --standing "hold #123, no migration work tonight")"
[ -f "$P/.swarm/operator-notes.md" ] && got=yes || got=no
check "--standing creates .swarm/operator-notes.md" "yes" "$got"
grep -qE '^- [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z hold #123, no migration work tonight$' "$P/.swarm/operator-notes.md" && got=yes || got=no
check "--standing appends '- <UTC ts> <text>'" "yes" "$got"
grep -q 'also in .swarm/operator-notes.md' "$s" && got=yes || got=no
check "--standing also drops the inbox note, so a run starts now" "yes" "$got"
printf 'line one\nline two\n' | "$NOTE" --project "$P" --standing - >/dev/null
check "a two-line note is folded to one notes entry" "1" "$(grep -c 'line one line two' "$P/.swarm/operator-notes.md")"
check "operator-notes.md has the header once and 2 entries" "2" "$(grep -c '^- ' "$P/.swarm/operator-notes.md")"

set +e
"$NOTE" --project "$P" "   " >/dev/null 2>&1; rc_empty=$?
"$NOTE" --project "$T/nowhere" "x" >/dev/null 2>&1; rc_dir=$?
"$NOTE" --bogus "x" >/dev/null 2>&1; rc_opt=$?
set -e
check "empty note -> exit 2" "2" "$rc_empty"
check "dir without .swarm -> exit 2" "2" "$rc_dir"
check "unknown option -> exit 2" "2" "$rc_opt"
got="$(cd "$P" && "$NOTE" "from cwd" | xargs -I{} dirname {})"
check "project defaults to \$PWD" "$P/.swarm/coord-inbox" "$got"
rm -f "$P/.swarm/coord-inbox"/*.md "$P/.swarm/operator-notes.md"

# ── prompt split ─────────────────────────────────────────────────────────────
heading "prompt split"
for m in work chat resident; do
    "$RENDER" "$m" > "$T/render-$m.md"
    grep -q '{{LLM_SWARM_DIR}}' "$T/render-$m.md" && got=left || got=none
    check "$m: {{LLM_SWARM_DIR}} fully substituted" "none" "$got"
done
set +e; "$RENDER" bogus >/dev/null 2>&1; rc=$?; set -e
check "unknown mode -> exit 2" "2" "$rc"
sed "s|{{LLM_SWARM_DIR}}|$ROOT|g" "$ROOT/prompts/coordinator.md" | cmp -s - "$T/render-resident.md" && got=same || got=differs
check "resident render is coordinator.md, byte for byte" "same" "$got"
for m in work chat; do
    grep -qF 'Talking to workers' "$T/render-$m.md" && grep -qF 'Report grammar (BLUF)' "$T/render-$m.md" && got=yes || got=no
    check "$m prompt carries the shared rules" "yes" "$got"
done
check "shared rules exist in exactly one file" "1" "$(grep -lF '## Talking to workers' "$ROOT"/prompts/coordinator-*.md | wc -l | tr -d ' ')"

# Every coordinator.md section is still homed in a split file (or renamed).
# A heading added to coordinator.md without a home would be silently
# missing from split mode, so this fails until it is placed.
declare -A RENAMED=(
    ["Every wake: sweep"]="Every run: sweep"
    ["Ongoing Monitoring"]="Status requests"
    ["Wake digest"]="Run output"
    ["When the user hits a merge conflict"]="Follow-ups and conflicts"
)
missing=""
while IFS= read -r h; do
    want="${RENAMED[$h]:-$h}"
    cat "$ROOT"/prompts/coordinator-{shared,work,chat}.md | grep -qxF -e "## $want" -e "### $want" || missing+="[$h] "
done < <(awk '/^```/ {f = !f} !f && /^#{2,3} / {sub(/^#+ /, ""); print}' "$ROOT/prompts/coordinator.md")
check "every coordinator.md section has a home in the split prompts" "" "$missing"

W="$ROOT/prompts/coordinator-work.md"
# Headings alone are not enough (issue #779): the sweep section of coordinator.md
# also carries bold-led rules and a script block, and the work prompt dropped
# the watcher-check.sh line and the Dead watcher rule without any heading
# changing. Every sweep script and every bold rule lead must survive in the
# work prompt.
sweep_of() {   # <file> <heading>: the body of one "## heading" section
    awk -v h="## $2" '$0 == h {f = 1; next} /^## / {f = 0} f' "$1"
}
RES_SWEEP="$(sweep_of "$ROOT/prompts/coordinator.md" "Every wake: sweep")"
WORK_SWEEP="$(sweep_of "$ROOT/prompts/coordinator-work.md" "Every run: sweep")"
check "sweep section found in both prompts" "yes" "$([ -n "$RES_SWEEP" ] && [ -n "$WORK_SWEEP" ] && echo yes || echo no)"
lost=""
while IFS= read -r s; do
    grep -qF "scripts/$s" <<<"$WORK_SWEEP" || lost+="[script $s] "
done < <(grep -oE 'scripts/[A-Za-z0-9_.-]+\.sh' <<<"$RES_SWEEP" | sed 's|scripts/||' | sort -u)
while IFS= read -r lead; do
    grep -qF "**$lead" <<<"$WORK_SWEEP" || lost+="[rule $lead] "
done < <(grep -oE '^\*\*[^*]+\*\*' <<<"$RES_SWEEP" | sed -E 's/^\*\*//; s/\*\*$//; s/ \(.*//; s/:.*//' | sort -u)
check "work prompt sweep keeps every sweep script and bold rule of coordinator.md" "" "$lost"
grep -q 'NOT running' "$W" && grep -q 'NOT running' "$ROOT/prompts/coordinator-chat.md" && got=yes || got=no
check "work and chat prompts both say what to do with the dead-watcher WARN" "yes" "$got"
grep -q 'scripts/watcher-check.sh "\$PWD"' "$ROOT/prompts/coordinator-chat.md" && grep -q 'watcher-check.sh "\$PWD"' "$ROOT/docs/split-coordinator.md" && got=yes || got=no
check "issue #781: chat prompt has hook-less sessions run watcher-check.sh, and the docs say so" "yes" "$got"

W="$ROOT/prompts/coordinator-work.md"; C="$ROOT/prompts/coordinator-chat.md"
grep -q 'only the opt-in automerges' "$W" && got=yes || got=no
check "work prompt: opt-in automerges only" "yes" "$got"
grep -q 'never run `swarm-merge.sh` without `--auto-low` or `--auto-medium`' "$W" && got=yes || got=no
check "work prompt: no explicit merges" "yes" "$got"
grep -q 'merge PR N red' "$W" && grep -q 'merge PR N red' "$C" && got=yes || got=no
check "red merges are named in both prompts (listed by the run, executed by chat)" "yes" "$got"
grep -qE 'merge PR N red`, typed by the operator here' "$C" && got=yes || got=no
check "chat prompt: a relayed red-merge phrase never counts" "yes" "$got"
grep -q 'scripts/operator-note.sh' "$C" && grep -q -- '--standing' "$C" && got=yes || got=no
check "chat prompt tells the session to use operator-note.sh (one-off and --standing)" "yes" "$got"
grep -qiE 'doorbell' "$W" && grep -q 'No doorbell reaches you' "$W" && got=yes || got=no
check "work prompt: no doorbell, the files are the truth" "yes" "$got"
check "work prompt does not claim a chat with the operator" "0" "$(grep -cE 'reply to the operator|operator.s last interaction' "$W")"

# ── state between runs (ADR section 1) ───────────────────────────────────────
heading "state between runs"
ADR="$ROOT/docs/adr/0006-split-coordinator-work-runs-and-conversation.md"
DOC="$ROOT/docs/split-coordinator.md"
for f in .swarm/work-run/last-digest.md .swarm/operator-notes.md .swarm/work-run/runs.log; do
    grep -qF "$f" "$ADR" && grep -qF "$f" "$DOC" && got=yes || got=no
    check "$f is named by the ADR and by docs/split-coordinator.md" "yes" "$got"
done
for f in .swarm/operator-notes.md .swarm/needs-you.md .swarm/work-run/last-digest.md .swarm/coord-inbox/; do
    grep -qF "$f" "$W" && got=yes || got=no
    check "work prompt reads/writes $f" "yes" "$got"
done
grep -q 'belongs to the run wrapper, not you' "$W" && got=yes || got=no
check "work prompt: runs.log is the wrapper's, not the run's" "yes" "$got"
grep -qE 'no memory of any earlier run' "$W" && got=yes || got=no
check "work prompt states it starts with no memory" "yes" "$got"
grep -qE 'Before you exit, in this order' "$W" && grep -q 'always\*\* overwrite `.swarm/work-run/last-digest.md`' "$W" && got=yes || got=no
check "work prompt: last-digest.md is rewritten every run" "yes" "$got"
# The standing note the chat session writes is what the next run reads first.
"$NOTE" --project "$P" --standing "hold #9" >/dev/null
first_read="$(grep -n 'operator-notes.md' "$W" | head -1 | cut -d: -f1)"
digest_read="$(grep -n 'last-digest.md' "$W" | head -1 | cut -d: -f1)"
[ "$first_read" -lt "$digest_read" ] && got=first || got="notes@$first_read digest@$digest_read"
check "work prompt reads operator-notes.md before the previous digest" "first" "$got"
grep -q 'hold #9' "$P/.swarm/operator-notes.md" && got=yes || got=no
check "a standing note survives for the next run (file, not chat memory)" "yes" "$got"
rm -f "$P/.swarm/coord-inbox"/*.md "$P/.swarm/operator-notes.md"

# ── window flag ──────────────────────────────────────────────────────────────
heading "📥 window flag"
# shellcheck source=scripts/_window-flags.sh
. "$ROOT/scripts/_window-flags.sh"
# shellcheck source=scripts/_coord-split.sh
. "$ROOT/scripts/_coord-split.sh"
SESSION_NAME=llm-proj
mk() { printf 'x\n' > "$P/.swarm/coord-inbox/$1"; echo "$P/.swarm/coord-inbox/$1"; }
urgent="$(mk 20261105T120000Z-stall-1-1.md)"
batched="$(mk 20261105T120001Z-idle_capacity-1-2.md)"
opnote="$(mk 20261105T120002Z-operator-1-3.md)"

check "coord_mode defaults to resident (no file)" "resident" "$(coord_mode "$P")"
setmode "$P" banana
check "coord_mode: garbage -> resident" "resident" "$(coord_mode "$P")"
printf '# c\nexport COORD_MODE="split"\n' > "$P/.swarm/.env"
check "coord_mode: export + quotes tolerated" "split" "$(coord_mode "$P")"
printf 'COORD_MODE=split\nCOORD_MODE=resident\n' > "$P/.swarm/.env"
check "coord_mode: the last assignment wins" "resident" "$(coord_mode "$P")"
setmode "$P" split
check "coord_mode ignores a conflicting env value" "split" "$(COORD_MODE=resident coord_mode "$P")"
printf 'COORD_MODE=split # tried it\n' > "$P/.swarm/.env"
check "coord_mode: inline comment stripped (split)" "split" "$(coord_mode "$P")"
check "coord_mode_raw: inline comment stripped" "split" "$(coord_mode_raw "$P")"
printf 'COORD_MODE="split"   # x\n' > "$P/.swarm/.env"
check "coord_mode_raw: quoted value then comment" "split" "$(coord_mode_raw "$P")"
printf 'COORD_MODE=resident # was split\n' > "$P/.swarm/.env"
check "coord_mode_raw: comment naming split does not leak" "resident" "$(coord_mode_raw "$P")"
printf 'COORD_MODE= # nothing\n' > "$P/.swarm/.env"
check "coord_mode_raw: empty value with comment" "" "$(coord_mode_raw "$P")"
setmode "$P" split
setmode "$P" resident
COORD_MODE=split coord_split_flag_urgent "$urgent" "$P"
check "resident in the file: an urgent item sets no flag (stale env says split)" "" "$(flag)"
setmode "$P" split
coord_split_flag_urgent "$batched" "$P"
check "split: a batched item sets no flag" "" "$(flag)"
coord_split_flag_urgent "$opnote" "$P"
check "split: the operator's own note sets no flag" "" "$(flag)"
coord_split_flag_urgent "$urgent" "$P"
check "split: an urgent item flags the coordinator window" "📥" "$(flag)"
WATCH_WINDOW_FLAGS=0 coord_split_flag_urgent "$urgent" "$P"   # kill switch: no-op, no error
check "split: WATCH_WINDOW_FLAGS=0 leaves the flag untouched" "📥" "$(flag)"
clear_window_flag coordinator "📥" test
check "clear_window_flag removes 📥" "" "$(flag)"
set_window_flag coordinator "🔔" test
coord_split_flag_urgent "$urgent" "$P"
check "📥 (rank 2) replaces the unranked 🔔 (rank 1) on the coordinator window" "📥" "$(flag)"
clear_window_flag coordinator "📥" test

# The watcher's real writer calls it: extract coord_inbox_write verbatim.
log_event() { :; }
eval "$(sed -n '/^coord_inbox_write() {/,/^}/p' "$WATCH")"
# shellcheck disable=SC2034  # read by the eval-ed coord_inbox_write
PROJECT_DIR="$P" COORD_INBOX_DIR="$P/.swarm/ci" COORD_INBOX_PROCESSED_DIR="$P/.swarm/ci/processed" COORD_INBOX_SELF_DIR="$P/.swarm/ci/self"
coord_inbox_write idle_capacity "1 idle slot"
check "watcher writer: a batched kind sets no flag" "" "$(flag)"
coord_inbox_write stall "worker iss-5 stalled"
check "watcher writer: an urgent kind sets 📥 (end to end)" "📥" "$(flag)"
clear_window_flag coordinator "📥" test
setmode "$P" resident
COORD_MODE=split coord_inbox_write stall "again"
check "watcher writer: resident in the file sets nothing, stale split env or not" "" "$(flag)"
setmode "$P" split
coord_inbox_write stall "flipped"
check "watcher writer: the same writer follows the file back to split, no restart" "📥" "$(flag)"
clear_window_flag coordinator "📥" test

# ── needs-you hook ───────────────────────────────────────────────────────────
heading "UserPromptSubmit hook"
hook() {   # <event> [stdin-json]; mode from the file (HM, default split); the env says the opposite
    setmode "$P" "${HM:-split}"
    local stale=resident; [ "${HM:-split}" = resident ] && stale=split
    printf '%s' "${2:-{\}}" | CLAUDE_PROJECT_DIR="$P" COORD_MODE="$stale" COORD_HOOK_STATE="${HS:-0}" "$HOOK" "$1"
}
rm -f "$P/.swarm"/needs-you.* "$P/.swarm/coord-hook-rang" "$P/.swarm/coordinator-state"
out="$(hook UserPromptSubmit)"
check "no needs-you.md -> silent" "" "$out"
check "split + COORD_HOOK_STATE=0: no state file written" "none" "$([ -e "$P/.swarm/coordinator-state" ] && echo some || echo none)"
printf '# Needs you\nUpdated: 12:00\n- **A1** 🟡 PR #1 ready\n- **A2** 🟡 PR #2 ready\n' > "$P/.swarm/needs-you.md"
set_window_flag coordinator "📥" test
out="$(hook UserPromptSubmit)"
check "the output is hook JSON for UserPromptSubmit" "UserPromptSubmit" "$(jq -r .hookSpecificOutput.hookEventName <<<"$out")"
ctx="$(jq -r .hookSpecificOutput.additionalContext <<<"$out")"
check "first prompt: one line naming the item count" "Needs-you changed since your last message: 2 new item(s), 2 on the list now (see .swarm/needs-you.md)." "$ctx"
check "the prompt clears the 📥 flag" "" "$(flag)"
out="$(hook UserPromptSubmit)"
check "unchanged list -> silent on the next prompt" "" "$out"
printf -- '- **A3** 🔴 PR #3 needs you\n' >> "$P/.swarm/needs-you.md"
ctx="$(hook UserPromptSubmit | jq -r .hookSpecificOutput.additionalContext)"
check "one added item -> '1 new item(s), 3 on the list'" "Needs-you changed since your last message: 1 new item(s), 3 on the list now (see .swarm/needs-you.md)." "$ctx"
grep -v 'A1' "$P/.swarm/needs-you.md" > "$T/ny" && cp "$T/ny" "$P/.swarm/needs-you.md"
ctx="$(hook UserPromptSubmit | jq -r .hookSpecificOutput.additionalContext)"
check "an item resolved -> '0 new item(s), 2 on the list'" "Needs-you changed since your last message: 0 new item(s), 2 on the list now (see .swarm/needs-you.md)." "$ctx"
# Renumbering (A2 becomes A1 once the old A1 is resolved) is not a new item.
printf '# Needs you\n- **A1** 🟡 PR #2 ready\n- **A2** 🔴 PR #3 needs you\n' > "$P/.swarm/needs-you.md"
ctx="$(hook UserPromptSubmit | jq -r .hookSpecificOutput.additionalContext)"
check "relabelled items are not counted as new" "Needs-you changed since your last message: 0 new item(s), 2 on the list now (see .swarm/needs-you.md)." "$ctx"

echo "- **A9** 🟡 PR #9" >> "$P/.swarm/coord-inbox/a.md"
setmode "$P" split
printf '%s' '{"stop_hook_active":false}' | CLAUDE_PROJECT_DIR="$P" COORD_HOOK_STATE=1 "$HOOK" Stop > "$T/stop.out"
check "split Stop: never blocks or rings a doorbell" "" "$(cat "$T/stop.out")"
check "split Stop: coord-hook-rang is not written" "none" "$([ -e "$P/.swarm/coord-hook-rang" ] && echo some || echo none)"
check "split Stop with COORD_HOOK_STATE=1 records idle" "idle" "$(cut -d' ' -f1 "$P/.swarm/coordinator-state")"

# Dead watcher (issue #779): split mode must not stay silent. A recorded pid
# that is gone = dead; the WARN rides every operator message, even with
# COORD_HOOK_STATE=0, and Stop (which split never blocks) stays silent.
printf 'pid=999999\nstarted_at=x\n' > "$P/.swarm/coordinator-watch.state"
touch -d "2 hours ago" "$P/.swarm/coordinator-watch.state"
rm -f "$P/.swarm"/needs-you.* "$P/.swarm/watcher-dead-warned" "$P/.swarm/watcher-stopped" "$P/.swarm/watcher-paused"
ctx="$(hook UserPromptSubmit | jq -r .hookSpecificOutput.additionalContext)"
check "split + dead watcher: the prompt context carries the WARN" "yes" "$(grep -q 'WARN: coordinator-watch.sh is NOT running' <<<"$ctx" && echo yes || echo no)"
check "split + dead watcher: the restart command is in it" "yes" "$(grep -q 'restart it: cd .*llm-start.sh' <<<"$ctx" && echo yes || echo no)"
ctx2="$(hook UserPromptSubmit | jq -r .hookSpecificOutput.additionalContext)"
check "split + dead watcher: the next prompt warns again (no throttle)" "yes" "$(grep -q 'NOT running' <<<"$ctx2" && echo yes || echo no)"
printf '# Needs you\n- **A1** 🟡 PR #1 ready\n' > "$P/.swarm/needs-you.md"
ctx3="$(hook UserPromptSubmit | jq -r .hookSpecificOutput.additionalContext)"
check "WARN and the needs-you line share one context" "yes" "$(grep -q 'NOT running' <<<"$ctx3" && grep -q 'Needs-you changed' <<<"$ctx3" && echo yes || echo no)"
printf '%s' '{"stop_hook_active":false}' | CLAUDE_PROJECT_DIR="$P" COORD_HOOK_STATE=1 "$HOOK" Stop > "$T/stop.dead.out"
check "split Stop with a dead watcher still never blocks" "" "$(cat "$T/stop.dead.out")"
touch "$P/.swarm/watcher-stopped"
check "stopped on purpose -> no WARN" "" "$(hook UserPromptSubmit | jq -r '.hookSpecificOutput.additionalContext // empty' | grep 'NOT running' || true)"
rm -f "$P/.swarm/watcher-stopped"
rm -f "$P/.swarm"/coordinator-watch.state "$P/.swarm"/needs-you.* "$P/.swarm/watcher-dead-warned" "$P/.swarm/coordinator-state"
out="$(hook UserPromptSubmit)"
check "no watcher state file (WATCH=0 swarm) -> silent" "" "$out"

# Resident mode: unchanged. Hook is off without COORD_HOOK_STATE, and with it
# on a UserPromptSubmit still only writes the state file.
rm -f "$P/.swarm"/needs-you.seen "$P/.swarm/coordinator-state"
out="$(HM=resident HS=0 hook UserPromptSubmit)"
check "resident, hook state off: silent no-op" "|none|none" "$out|$([ -e "$P/.swarm/coordinator-state" ] && echo some || echo none)|$([ -e "$P/.swarm/needs-you.seen" ] && echo some || echo none)"
out="$(HM=resident HS=1 hook UserPromptSubmit)"
check "resident, hook state on: no needs-you line, state is busy" "|busy|none" "$out|$(cut -d' ' -f1 "$P/.swarm/coordinator-state")|$([ -e "$P/.swarm/needs-you.seen" ] && echo some || echo none)"
rm -f "$P/.swarm/coord-inbox"/*.md "$P/.swarm"/needs-you.* "$P/.swarm/coordinator-state"

# ── coordinator-claude.sh wiring ─────────────────────────────────────────────
heading "coordinator-claude.sh"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > %q\n' "$T/argv" > "$T/bin/claude"; chmod +x "$T/bin/claude"
echo sys > "$T/sys"
run_wrapper() {   # <mode in .swarm/.env> <COORD_HOOK_STATE>; the env carries the opposite mode
    echo hi > "$T/init"; setmode "$P" "$1"
    local stale=resident; [ "$1" = resident ] && stale=split
    (cd "$P" && env COORD_MODE="$stale" COORD_HOOK_STATE="$2" "$ROOT/scripts/coordinator-claude.sh" "$T/sys" "$T/init")
}
hooks() { grep -A1 -x -- '--settings' "$T/argv" | tail -1 | jq -r '[.hooks | keys[]] | sort | join(",")' 2>/dev/null || echo none; }
run_wrapper resident 0
check "resident, hook state 0: only the Stop reply lint (#798), no state or doorbell hooks" "Stop" "$(hooks)"
run_wrapper resident 1
check "resident, hook state 1: the three hooks (unchanged)" "Notification,Stop,UserPromptSubmit" "$(hooks)"
run_wrapper split 0
check "split, hook state 0: UserPromptSubmit + Stop (Stop runs the reply lint, #798; no state file)" "Stop,UserPromptSubmit" "$(hooks)"
run_wrapper split 1
check "split, hook state 1: all three" "Notification,Stop,UserPromptSubmit" "$(hooks)"
settings="$(grep -A1 -x -- '--settings' "$T/argv" | tail -1)"
cmd="$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' <<<"$settings")"
printf '%s\n' '- **A1** 🟡 PR #1' > "$P/.swarm/needs-you.md"
ctx="$(printf '{}' | env -u COORD_MODE CLAUDE_PROJECT_DIR="$P" bash -c "$cmd" | jq -r .hookSpecificOutput.additionalContext)"
check "the installed command runs the hook, which reads the mode from the file" "Needs-you changed since your last message: 1 new item(s), 1 on the list now (see .swarm/needs-you.md)." "$ctx"
rm -f "$P/.swarm"/needs-you.*
setmode "$P" unset

# ── coord-work-run.sh prompt selection ───────────────────────────────────────
# The real wrapper with a claude stub that keeps the system prompt it is
# handed. A rule that lives ONLY in coordinator-shared.md must be in it.
heading "coord-work-run.sh passes the work + shared prompt"
cat > "$T/bin/claude" <<STUB
#!/usr/bin/env bash
while [ \$# -gt 0 ]; do
    [ "\$1" = --append-system-prompt-file ] && { cp "\$2" "$T/work-sys.md"; break; }
    shift
done
STUB
chmod +x "$T/bin/claude"
W="$T/wproj"; mkdir -p "$W/.swarm"; rm -f "$T/work-sys.md"
(cd "$W" && env -u COORD_WORK_RUN_CMD -u COORD_WORK_PROMPT_FILE LLM_SWARM_DIR="$ROOT" "$ROOT/scripts/coord-work-run.sh" "$W" "Run once." >/dev/null 2>&1) || true
[ -s "$T/work-sys.md" ] && got=captured || got=missing
check "the wrapper handed claude a system prompt file" "captured" "$got"
RULE='Never `tmux send-keys` into another agent'
grep -qF "$RULE" "$ROOT/prompts/coordinator-shared.md" && ! grep -qF "$RULE" "$ROOT/prompts/coordinator-work.md" && got=shared-only || got=not-shared-only
check "fixture rule exists only in coordinator-shared.md" "shared-only" "$got"
grep -qF "$RULE" "$T/work-sys.md" && got=yes || got=no
check "work-run prompt carries the shared-only no-send-keys rule" "yes" "$got"
grep -qF 'Report grammar (BLUF)' "$T/work-sys.md" && got=yes || got=no
check "work-run prompt carries the shared report grammar" "yes" "$got"
"$RENDER" work | cmp -s - "$T/work-sys.md" && got=same || got=differs
check "work-run prompt is exactly the work render" "same" "$got"
grep -qF '{{LLM_SWARM_DIR}}' "$T/work-sys.md" && got=left || got=none
check "work-run prompt has {{LLM_SWARM_DIR}} substituted" "none" "$got"

# ── llm-start.sh ─────────────────────────────────────────────────────────────
heading "llm-start.sh"
S="$T/start"; mkdir -p "$S/proj/.swarm"; (cd "$S/proj" && git init -q . && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m i)
cat > "$T/bin/tmux" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$S/tmux.log"
case "\$*" in *"-V"*) echo "tmux 3.4";; esac
case "\$*" in *has-session*) exit 1;; esac
exit 0
EOF
start() {   # <mode written to .swarm/.env> [args...]; the caller env carries the OPPOSITE mode, which must lose
    local mode="$1"; shift
    local stale=resident; [ "$mode" = resident ] && stale=split
    setmode "$S/proj" "$mode"
    : > "$S/tmux.log"
    (cd "$S/proj" && env COORD_MODE="$stale" HOME="$S" NON_INTERACTIVE=1 WATCH=0 STATUS=0 "$ROOT/llm-start.sh" "$@") > "$S/out.txt" 2>&1
}
send_line() { grep -F 'send-keys' "$S/tmux.log" | head -1; }
files_of() { local l; l="$(send_line)"; printf '%s\n' "$(grep -oE '/tmp/coordinator-prompt-[A-Za-z0-9]+\.md' <<<"$l")" "$(sed -E 's/ C-m$//' <<<"$l" | awk '{print $NF}')"; }

set +e; start bogus; rc=$?; set -e
check "COORD_MODE=bogus -> exit 2" "2" "$rc"
grep -q 'COORD_MODE must be resident or split' "$S/out.txt" && got=yes || got=no
check "COORD_MODE=bogus prints why" "yes" "$got"

start resident
grep -q 'WARN: ignoring COORD_MODE=split from the environment' "$S/out.txt" && got=warned || got=silent
check "caller env disagrees with the file: warned, file followed" "warned" "$got"
check "the warning appears once" "1" "$(grep -c 'ignoring COORD_MODE' "$S/out.txt")"
grep -qE 'COORD_MODE([^L]|$)|set-environment' "$S/tmux.log" && got=found || got=none
check "resident: no COORD_MODE pin or session-env change anywhere in the tmux calls" "none" "$got"
# A resident swarm that never heard of COORD_MODE: no file entry, no env value.
setmode "$S/proj" unset; : > "$S/tmux.log"
(cd "$S/proj" && env -u COORD_MODE HOME="$S" NON_INTERACTIVE=1 WATCH=0 STATUS=0 "$ROOT/llm-start.sh") > "$S/out.txt" 2>&1
grep -qE 'COORD_MODE([^L]|$)|set-environment' "$S/tmux.log" && got=found || got=none
check "no COORD_MODE anywhere: the tmux calls carry no mode, as before #767" "none" "$got"
grep -q 'WARN' "$S/out.txt" && got=warned || got=silent
check "no COORD_MODE anywhere: no warning" "silent" "$got"
start resident
rp="$(files_of | sed -n 1p)"; ip="$(files_of | sed -n 2p)"
grep -q 'Initial Startup Checklist' "$rp" && got=yes || got=no
check "resident: system prompt is coordinator.md" "yes" "$got"
check "resident: initial prompt is the startup checklist" "Execute the Initial Startup Checklist." "$(cat "$ip")"

start split
grep -qE 'COORD_MODE([^L]|$)|set-environment' "$S/tmux.log" && got=found || got=none
check "split: no COORD_MODE pin or session-env change in the tmux calls either" "none" "$got"
rp="$(files_of | sed -n 1p)"; ip="$(files_of | sed -n 2p)"
grep -q "conversation session" "$rp" && ! grep -q 'Initial Startup Checklist' "$rp" && got=chat || got=other
check "split: system prompt is the chat prompt, not the startup checklist" "chat" "$got"
grep -qF 'Talking to workers' "$rp" && got=yes || got=no
check "split: the shared rules are appended" "yes" "$got"
grep -q 'needs-you.md' "$ip" && got=yes || got=no
check "split: initial prompt reads needs-you, not the startup checklist" "yes" "$got"
check "split: only the coordinator window is launched (1 send-keys)" "1" "$(grep -cF 'send-keys' "$S/tmux.log")"
start split "do the thing"
grep -q 'do the thing' "$(files_of | sed -n 2p)" && got=yes || got=no
check "split: an explicit prompt still wins on a fresh launch" "yes" "$got"

# A live session: split never types into it; resident does (existing path).
cat > "$T/bin/tmux" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$S/tmux.log"
case "\$*" in
    *"-V"*) echo "tmux 3.4" ;;
    *has-session*) exit 0 ;;
    *"list-windows -t llm-proj -F #W"*) printf 'coordinator\nutil\n' ;;
    *"coordinator"*"PANE_CMD"*) echo "PANE_CMD=claude PANE_DEAD=0" ;;
esac
exit 0
EOF
start split "wake up"
grep -qE 'paste-buffer|load-buffer' "$S/tmux.log" && got=typed || got=untouched
check "split + live session: a wake prompt is not pasted" "untouched" "$got"
check "split + live session: send-keys is never used" "0" "$(grep -cF 'send-keys' "$S/tmux.log")"
grep -q 'coord.wake.skip reason=split_mode' "$S/proj/.swarm/events.log" 2>/dev/null && got=logged || got=missing
check "split + live session: the skip is logged" "logged" "$got"
grep -q 'split-mode conversation session is live' "$S/out.txt" && got=yes || got=no
check "split + live session: says nothing was typed" "yes" "$got"

# A pane sitting at a shell: a wake still must not start or type into the chat.
sed -i "s/PANE_CMD=claude/PANE_CMD=bash/" "$T/bin/tmux"
start split "wake up"
grep -qE "send-keys|paste-buffer|load-buffer" "$S/tmux.log" && got=typed || got=untouched
check "split + idle shell pane: a wake types nothing and launches nothing" "untouched" "$got"
grep -q "coord.wake.skip reason=split_mode" "$S/proj/.swarm/events.log" && got=logged || got=missing
check "split + idle shell pane: the skip is logged" "logged" "$got"

# Session alive but the coordinator window is gone: a wake still must not launch the chat.
sed -i 's|coordinator\\nutil|util|' "$T/bin/tmux"
start split "wake up"
grep -qE "paste-buffer|load-buffer|claude" "$S/tmux.log" && got=launched || got=untouched
check "split + missing window: a wake launches nothing" "untouched" "$got"

# Pane crashed (remain-on-exit left it dead): llm-start.sh clears it and treats the
# window as gone, and a wake still must not launch or type into the chat.
cat > "$T/bin/tmux" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$S/tmux.log"
case "\$*" in
    *"-V"*) echo "tmux 3.4" ;;
    *has-session*) exit 0 ;;
    *"list-windows -t llm-proj -F #W"*) printf 'coordinator\nutil\n' ;;
    *"coordinator"*"PANE_CMD"*) echo "PANE_CMD=claude PANE_DEAD=1" ;;
esac
exit 0
EOF
start split "wake up"
grep -qF 'kill-pane' "$S/tmux.log" && got=cleared || got=left
check "split + dead pane: the corpse is cleared as before" "cleared" "$got"
grep -qE "send-keys|paste-buffer|load-buffer" "$S/tmux.log" && got=launched || got=untouched
check "split + dead pane: a wake launches nothing and types nothing" "untouched" "$got"

# Mode flips in the file; the NEXT run follows it, in both directions, with a
# stale value of the opposite mode in the caller env every time (#767).
heading "flip in .swarm/.env, next run follows"
cat > "$T/bin/tmux" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$S/tmux.log"
case "\$*" in
    *"-V"*) echo "tmux 3.4" ;;
    *has-session*) exit 0 ;;
    *"list-windows -t llm-proj -F #W"*) printf 'coordinator\nutil\n' ;;
    *"coordinator"*"PANE_CMD"*) echo "PANE_CMD=claude PANE_DEAD=0" ;;
esac
exit 0
EOF
rm -f "$S/proj/.swarm/events.log"
start resident "wake"
grep -qE 'paste-buffer|load-buffer|send-keys' "$S/tmux.log" && got=typed || got=untouched
check "resident wake into a live session: typed (unchanged)" "typed" "$got"
start split "wake"
grep -qE 'paste-buffer|load-buffer|send-keys' "$S/tmux.log" && got=typed || got=untouched
check "flip resident -> split: the very next wake types nothing" "untouched" "$got"
grep -q 'coord.wake.skip reason=split_mode' "$S/proj/.swarm/events.log" && got=logged || got=missing
check "flip resident -> split: the next wake logs the skip" "logged" "$got"
start resident "wake"
grep -qE 'paste-buffer|load-buffer|send-keys' "$S/tmux.log" && got=typed || got=untouched
check "flip split -> resident: the very next wake types again" "typed" "$got"
setmode "$S/proj" unset
: > "$S/tmux.log"
(cd "$S/proj" && env COORD_MODE=split HOME="$S" NON_INTERACTIVE=1 WATCH=0 STATUS=0 "$ROOT/llm-start.sh" "wake") > "$S/out.txt" 2>&1
grep -qE 'paste-buffer|load-buffer|send-keys' "$S/tmux.log" && got=typed || got=untouched
check "no COORD_MODE in the file, stale split env: resident behaviour" "typed" "$got"

# The launch line carries no mode; the wrapper reads the file when it starts.
heading "launched coordinator follows the file"
cat > "$T/bin/tmux" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$S/tmux.log"
case "\$*" in
    *"-V"*) echo "tmux 3.4" ;;
    *has-session*) exit 0 ;;
    *"list-windows -t llm-proj -F #W"*) printf 'coordinator\nutil\n' ;;
    *"coordinator"*"PANE_CMD"*) echo "PANE_CMD=bash PANE_DEAD=0" ;;
esac
exit 0
EOF
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > %q\n' "$T/argv" > "$T/bin/claude"
relaunch() {   # <mode> <COORD_HOOK_STATE>: llm-start writes the launch line; run it with the opposite mode in its env
    start "$1"
    local line; line="$(send_line | sed -E 's/^.*send-keys -t [^ ]+ //; s/ C-m$//')"
    [ -n "$line" ] || { echo "no launch line"; return 1; }
    rm -f "$T/argv"
    local stale=resident; [ "$1" = resident ] && stale=split
    (cd "$S/proj" && env COORD_MODE="$stale" COORD_HOOK_STATE="$2" bash -c "$line")
}
P_SAVE="$P"; P="$S/proj"
relaunch split 0
check "split launch: the needs-you hook + the reply-lint Stop hook (#798)" "Stop,UserPromptSubmit" "$(hooks)"
relaunch resident 1
check "rollback relaunch: resident hooks (Stop rings again)" "Notification,Stop,UserPromptSubmit" "$(hooks)"
printf '%s\n' '- **A1** 🟡 PR #1' > "$P/.swarm/needs-you.md"; rm -f "$P/.swarm/needs-you.seen"
cmd="$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' <<<"$(grep -A1 -x -- '--settings' "$T/argv" | tail -1)")"
out="$(printf '{}' | env COORD_MODE=split CLAUDE_PROJECT_DIR="$P" bash -c "$cmd")"
check "rollback relaunch: the installed hook is silent on needs-you even with a stale split env" "" "$out"
rm -f "$P/.swarm"/needs-you.*
relaunch resident 0
check "resident, hook state 0: only the Stop reply lint (#798), nothing else installed" "Stop" "$(hooks)"
P="$P_SAVE"

# A wake never kills or restarts a watcher, whatever the file says and whatever
# its start command carries: the watcher pane is never touched.
heading "a wake never touches the watcher"
cat > "$T/bin/tmux" <<EOF2
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$S/tmux.log"
case "\$*" in
    *"-V"*) echo "tmux 3.4" ;;
    *has-session*) exit 0 ;;
    *"list-windows -t llm-proj -F #W"*) printf 'coordinator\nutil\n' ;;
    *"coordinator"*"PANE_CMD"*) echo "PANE_CMD=bash PANE_DEAD=0" ;;
    *list-panes*llm-proj:util*pane_dead*) echo "0 1 $ROOT/scripts/coordinator-watch.sh /x" ;;
    *display-message*) echo "%9" ;;
esac
exit 0
EOF2
for m in resident split unset; do
    setmode "$S/proj" "$m"
    : > "$S/tmux.log"
    set +e
    (cd "$S/proj" && env COORD_MODE=split HOME="$S" NON_INTERACTIVE=1 TMUX_PANE=%9 WATCH=1 STATUS=0 "$ROOT/llm-start.sh" "wake") > "$S/out.txt" 2>&1
    rc=$?; set -e
    grep -qE 'kill-pane|split-window' "$S/tmux.log" && got=touched || got=untouched
    check "wake with '$m' in the file: the live watcher is neither killed nor duplicated" "untouched" "$got"
    check "wake with '$m' in the file: llm-start exits 0" "0" "$rc"
    grep -q 'skipping spawn' "$S/out.txt" && got=skipped || got=other
    check "wake with '$m' in the file: says it is skipping the spawn" "skipped" "$got"
done
grep -n 'COORD_MODE' "$ROOT/llm-start.sh" | grep -E 'set-environment|show-environment|new-session' > /dev/null && got=found || got=none
check "llm-start.sh does no COORD_MODE tmux-env sync" "none" "$got"

# Auto-compact never injects /compact into the conversation session.
heading "auto-compact"
log_event() { echo "$*" >> "$T/ev.log"; }
eval "$(sed -n "/^coord_split_active() {/,/^}/p" "$ROOT/scripts/coordinator-watch.sh")"
eval "$(sed -n "/^maybe_auto_compact() {/,/^    fi$/p" "$ROOT/scripts/coordinator-watch.sh")
    return 99
}"
# shellcheck disable=SC2034
AUTO_COMPACT=1; : > "$T/ev.log"
PROJECT_DIR="$P"
printf "COORD_MODE=split\n" > "$P/.swarm/.env"; maybe_auto_compact wake; rc=$?
check "split: maybe_auto_compact returns before touching the pane" "0" "$rc"
grep -q "reason=split_mode" "$T/ev.log" && got=logged || got=missing
check "split: maybe_auto_compact logs the skip" "logged" "$got"
printf "COORD_MODE=resident\n" > "$P/.swarm/.env"; set +e; maybe_auto_compact wake; rc=$?; set -e
check "resident: maybe_auto_compact proceeds past the split guard" "99" "$rc"

echo
green "all split-coordinator checks passed"
