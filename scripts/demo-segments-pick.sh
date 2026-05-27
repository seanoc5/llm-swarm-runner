#!/usr/bin/env bash
#
# demo-segments-pick.sh — Interactive picker for edit-demo.sh SEGMENTS rows.
#
# Plays the raw demo in mpv with a custom key bound: each press of `c`
# captures the current timestamp. After you quit mpv, the script pairs
# successive captures as (start, end), prompts for SPEED and LABEL per
# pair on the terminal, and prints a ready-to-paste `SEGMENTS=(...)`
# block to stdout.
#
# Workflow:
#   1. Record a raw demo (see docs/demo-recording.md).
#   2. ./scripts/demo-segments-pick.sh [RAW_PATH]
#   3. In mpv:
#        c         capture the current timestamp (alternates START/END)
#        space     pause / resume
#        ← / →     seek ±5s        (Shift = ±1s)
#        , / .     step one frame
#        q         quit
#   4. Answer SPEED/LABEL prompts for each pair.
#   5. Copy the printed SEGMENTS=(...) block into scripts/edit-demo.sh.
#
# Tip: pipe the output to a file for safe-keeping:
#   ./scripts/demo-segments-pick.sh > /tmp/segments.txt
#
# Requirements: mpv (apt install mpv).
#
# Pairs with: scripts/edit-demo.sh (consumes the SEGMENTS array)
#             docs/demo-recording.md (the end-to-end recipe)

set -euo pipefail

RAW="${1:-${HOME}/Videos/demo-raw.mkv}"

log()  { printf '\033[1;36m[pick]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[pick]\033[0m %s\n' "$*" >&2; }

command -v mpv >/dev/null || { err "mpv not installed (apt install mpv)"; exit 1; }
[ -f "$RAW" ] || { err "raw file not found: $RAW"; exit 1; }

TMPDIR=$(mktemp -d /tmp/demo-pick-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT
PICKS="$TMPDIR/picks.txt"
LUA="$TMPDIR/pick.lua"
: > "$PICKS"

# Lua script injected into mpv. Binds `c` to append time-pos to $PICKS
# (one float-seconds per line) and flash an OSD confirmation. The
# START/END alternation is purely a UI hint — the bash side does the
# real pairing after mpv exits.
cat > "$LUA" <<'LUA'
local outfile = mp.get_opt("pickfile")
if not outfile then
    mp.msg.error("pickfile script-opt not set")
    return
end

local count = 0
mp.add_key_binding("c", "capture-time", function()
    local pos = mp.get_property_number("time-pos")
    if not pos then return end
    local f, err = io.open(outfile, "a")
    if not f then
        mp.osd_message("ERROR: cannot write " .. outfile .. ": " .. (err or "?"), 3)
        return
    end
    f:write(string.format("%.3f\n", pos))
    f:close()
    count = count + 1
    local kind = (count % 2 == 1) and "START" or "END  "
    mp.osd_message(string.format("#%d  %s  %.2fs", count, kind, pos), 2)
end)

mp.osd_message("press 'c' to mark a beat boundary  (q to quit)", 4)
LUA

log "raw:    $RAW"
log "marks → $PICKS"
log "launching mpv… press 'c' at each beat boundary, 'q' to quit."

# --no-config so user's ~/.config/mpv/input.conf doesn't shadow `c`.
mpv \
    --no-config \
    --script="$LUA" \
    --script-opts=pickfile="$PICKS" \
    --osd-level=1 \
    --osd-duration=2000 \
    --keep-open=yes \
    "$RAW"

# ---- After mpv exits: pair up and prompt -------------------------------

if [ ! -s "$PICKS" ]; then
    err "no marks captured — nothing to emit."
    exit 1
fi

mapfile -t MARKS < "$PICKS"
N=${#MARKS[@]}
if (( N % 2 != 0 )); then
    err "captured $N marks (odd number) — last mark will be dropped."
    unset 'MARKS[-1]'
    N=${#MARKS[@]}
fi
PAIRS=$((N / 2))
log "captured $N marks → $PAIRS segment pair(s); prompting for SPEED/LABEL…"

# seconds (float) → HH:MM:SS.SS
fmt_ts() {
    awk -v s="$1" 'BEGIN{
        h = int(s/3600);
        m = int((s - h*3600)/60);
        rem = s - h*3600 - m*60;
        printf "%02d:%02d:%05.2f", h, m, rem
    }'
}

# Read/prompt on /dev/tty so the user sees them and answers them even
# when stdout is being piped to a file. SEGMENTS block goes to stdout.
prompt_pair() {
    local idx="$1" start_ts="$2" end_ts="$3" dur="$4"
    printf '\n  pair %d: %s → %s  (%ss raw)\n' "$idx" "$start_ts" "$end_ts" "$dur" >/dev/tty
    printf '    SPEED [1.0]: ' >/dev/tty
    read -r SPEED </dev/tty
    SPEED="${SPEED:-1.0}"
    printf '    LABEL (empty for none): ' >/dev/tty
    read -r LABEL </dev/tty
}

echo "SEGMENTS=("
for ((i=0; i<PAIRS; i++)); do
    START_RAW="${MARKS[$((i*2))]}"
    END_RAW="${MARKS[$((i*2+1))]}"
    START_TS=$(fmt_ts "$START_RAW")
    END_TS=$(fmt_ts "$END_RAW")
    DUR=$(awk -v a="$START_RAW" -v b="$END_RAW" 'BEGIN{printf "%.1f", b-a}')

    prompt_pair "$((i+1))" "$START_TS" "$END_TS" "$DUR"
    echo "    \"$START_TS $END_TS $SPEED $LABEL\""
done
echo ")"
