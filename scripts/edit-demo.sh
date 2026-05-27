#!/usr/bin/env bash
#
# edit-demo.sh — Cut, speed-segment, and compress a raw demo recording into
# a Reddit-ready ~75-second MP4.
#
# Workflow:
#   1. Record raw demo with SimpleScreenRecorder (~15 min source is fine)
#   2. Scrub through the raw file, jot timestamps for each beat
#   3. Edit the SEGMENTS array below with your actual timestamps
#   4. ./scripts/edit-demo.sh [RAW_PATH] [OUT_PATH]
#
# Output:
#   ~/Videos/demo-final.mp4 (default; override via 2nd positional arg)
#
# Iteration:
#   Edit a timestamp, re-run. Each segment encodes independently, then
#   concatenates. Cheap to iterate.
#
# Requirements: ffmpeg, ffprobe

set -euo pipefail

# =========================================================================
# CONFIGURATION — edit these after recording
# =========================================================================

RAW="${1:-${HOME}/Videos/demo-raw.mp4}"
OUT="${2:-${HOME}/Videos/demo-final.mp4}"

# Optional spatial crop applied to every segment BEFORE the scale/fps pass.
# Format: "W:H:x:y" — width, height, top-left corner in source pixels.
# Empty = no crop (default).
# Special value "auto" runs ffmpeg's cropdetect against a sample frame
# (see Auto-detect below) and reuses the result for every segment.
#
# Use case: the recording captured more than you wanted (e.g., full desktop
# instead of just the terminal). Drop the unwanted pixels in one place
# instead of re-recording. Pair with `scripts/demo-record-setup.sh` to
# avoid the problem on future takes.
#
# Examples:
#   CROP="1920:1080:0:0"      ./scripts/edit-demo.sh      # top-left 1080p of a 1440p capture
#   CROP="1600:900:160:90"    ./scripts/edit-demo.sh      # 16:9 region centered-ish
#   CROP=auto                 ./scripts/edit-demo.sh      # sniff terminal rect from raw
#
# Auto-detect: cropdetect normally trims DARK borders, but in our case the
# terminal is the dark area and the desktop is brighter, so the script
# inverts the sample frame first (negate filter) and runs cropdetect on
# that. Works when the terminal background is consistently dark and the
# desktop background isn't (light wallpaper, panel, etc.). If the desktop
# itself is mostly black, prefer the explicit W:H:x:y form.
#
# Sanity: W and H should keep a 16:9 aspect for clean downscale to $RES;
# non-16:9 crops still work but will get letterbox/pillarbox from the
# subsequent scale to 1280:720.
CROP="${CROP:-}"

# Each row: "START_TIME END_TIME SPEED LABEL"
#   START_TIME, END_TIME — HH:MM:SS or seconds, relative to the RAW file
#   SPEED                 — playback speed (1.0 = real time; >1 = fast-forward)
#   LABEL                 — overlay text (empty string = no overlay)
#
# LABEL grammar — the text may be followed by trailing modifiers, parsed
# from the right. Each modifier is space-separated and starts with a
# sigil. Order doesn't matter; any combination is fine.
#
#   @<position>   one of: top-left, top-right, bottom-left,
#                 bottom-right, top, bottom, center
#                 (default: top-right for sped-up segments,
#                  bottom-left for real-time segments)
#   +<animation>  one of: static (default), fade-in, slide-in
#                 fade-in:  alpha ramps 0→1 over the first 0.5s
#                 slide-in: text slides in from the nearest edge
#                           over the first 0.5s
#   %<duration>   seconds the overlay stays visible (output-timeline,
#                 i.e. after speed-up). Default: full segment.
#
# Examples:
#   "00:05:30 00:05:42 1.0 PR opened — 🟢 low risk @top-right +slide-in %2.5"
#   "00:00:30 00:00:55 1.0 Coordinator dispatches @bottom +fade-in"
#   "00:01:05 00:05:30 8.0 ⏩ 8x"                  # default top-right chip
#
# AFTER RECORDING: replace these placeholder timestamps with your actual
# beat positions in the raw file. Use ffprobe/mpv/etc to scrub
# (or `./scripts/demo-segments-pick.sh` for an interactive picker).
SEGMENTS=(
    # title — show the backlog
    "00:00:00 00:00:03 1.0 "

    # invocation — typing ./scripts/demo-driver.sh
    "00:00:10 00:00:18 1.0 "

    # coordinator wakes, dispatches workers (the money beat — real time)
    "00:00:30 00:00:55 1.0 "

    # window list reveal — iss-* windows now visible
    "00:00:55 00:01:00 1.0 "

    # worker doing its thing — SPED UP
    "00:01:05 00:05:30 8.0 ⏩ 8x"

    # worker finishes, outcome JSON written, PR opens
    "00:05:30 00:05:42 1.0 "

    # human reviews — gh pr diff N | head -40
    "00:05:50 00:06:05 1.0 "

    # human merges — gh pr merge N --squash --delete-branch
    "00:06:05 00:06:12 1.0 "

    # watcher fires, coordinator wakes, wave 2 dispatches — SPED UP
    "00:06:15 00:07:00 4.0 ⏩ 4x"

    # second-wave workers visible + event log shot
    "00:07:00 00:07:12 1.0 "

    # final gh pr list shot
    "00:07:20 00:07:28 1.0 "
)

# Output knobs
RES="1280:720"
CRF=26               # 23 = high quality / bigger; 28 = scrappy / smaller
FPS=30
END_CARD_SECS=3

TITLE_CARD_TEXT="llm-swarm-runner — Claude Code coordinator + worker swarm"
END_CARD_TEXT="github.com/seanoc5/llm-swarm-runner   ·   MIT"

# Font (DejaVu Sans is preinstalled on Ubuntu/Mint)
FONT="/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"

# =========================================================================
# Implementation — usually no need to edit below this line
# =========================================================================

log()  { printf '\033[1;36m[edit-demo]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[edit-demo]\033[0m %s\n' "$*" >&2; }

# Strip trailing @position / +animation / %duration modifiers from a
# LABEL string. Sets LABEL_TEXT, LABEL_POS, LABEL_ANIM, LABEL_DUR
# globals. Unrecognised tokens stay as part of LABEL_TEXT.
parse_label() {
    local s="$1"
    LABEL_POS=""
    LABEL_ANIM=""
    LABEL_DUR=""
    local re_pos='^(.*)[[:space:]]@(top-left|top-right|bottom-left|bottom-right|top|bottom|center)$'
    local re_anim='^(.*)[[:space:]]\+(static|fade-in|slide-in)$'
    local re_dur='^(.*)[[:space:]]%([0-9]+(\.[0-9]+)?)$'
    local changed=1
    while [ $changed -eq 1 ]; do
        changed=0
        if [[ "$s" =~ $re_pos ]] && [ -z "$LABEL_POS" ]; then
            LABEL_POS="${BASH_REMATCH[2]}"
            s="${BASH_REMATCH[1]}"
            changed=1
        elif [[ "$s" =~ $re_anim ]] && [ -z "$LABEL_ANIM" ]; then
            LABEL_ANIM="${BASH_REMATCH[2]}"
            s="${BASH_REMATCH[1]}"
            changed=1
        elif [[ "$s" =~ $re_dur ]] && [ -z "$LABEL_DUR" ]; then
            LABEL_DUR="${BASH_REMATCH[2]}"
            s="${BASH_REMATCH[1]}"
            changed=1
        fi
    done
    # Trim trailing whitespace
    [[ "$s" =~ ^(.*[^[:space:]])[[:space:]]*$ ]] && s="${BASH_REMATCH[1]}"
    [[ "$s" =~ ^[[:space:]]*$ ]] && s=""
    LABEL_TEXT="$s"
}

# Build a drawtext= filter expression honoring LABEL modifiers.
# Args: text pos anim dur speed. Echoes the filter or nothing.
build_drawtext() {
    local text="$1" pos="$2" anim="$3" dur="$4" speed="$5"
    [ -z "$text" ] && return 0

    # Defaults derived from speed, matching the original chip styles.
    local default_pos fontsize boxborderw
    if awk "BEGIN{exit !($speed > 1.0)}"; then
        default_pos="top-right"; fontsize=36; boxborderw=10
    else
        default_pos="bottom-left"; fontsize=24; boxborderw=8
    fi
    pos="${pos:-$default_pos}"
    anim="${anim:-static}"

    local final_x final_y
    case "$pos" in
        top-left)     final_x="30"        ; final_y="30" ;;
        top-right)    final_x="w-tw-30"   ; final_y="30" ;;
        bottom-left)  final_x="30"        ; final_y="h-th-30" ;;
        bottom-right) final_x="w-tw-30"   ; final_y="h-th-30" ;;
        top)          final_x="(w-tw)/2"  ; final_y="30" ;;
        bottom)       final_x="(w-tw)/2"  ; final_y="h-th-30" ;;
        center)       final_x="(w-tw)/2"  ; final_y="(h-th)/2" ;;
        *)
            err "unknown @position '$pos' — falling back to $default_pos"
            pos="$default_pos"
            build_drawtext "$text" "$pos" "$anim" "$dur" "$speed"
            return
            ;;
    esac

    local x_expr="$final_x"
    local y_expr="$final_y"
    local alpha_extra=""

    case "$anim" in
        static) ;;
        fade-in)
            alpha_extra=":alpha='if(lt(t,0.5),t/0.5,1)'"
            ;;
        slide-in)
            # Slide in over 0.5s from the edge nearest to the final
            # position. Right-anchored positions slide in from the
            # right; left-anchored from the left; top from above; the
            # rest (bottom, center) from below.
            case "$pos" in
                top-right|bottom-right)
                    x_expr="if(lt(t,0.5),w-(w-($final_x))*t/0.5,$final_x)"
                    ;;
                top-left|bottom-left)
                    x_expr="if(lt(t,0.5),-tw+($final_x+tw)*t/0.5,$final_x)"
                    ;;
                top)
                    y_expr="if(lt(t,0.5),-th+($final_y+th)*t/0.5,$final_y)"
                    ;;
                bottom|center)
                    y_expr="if(lt(t,0.5),h+(($final_y)-h)*t/0.5,$final_y)"
                    ;;
            esac
            ;;
        *)
            err "unknown +animation '$anim' — using static"
            ;;
    esac

    local enable_extra=""
    if [ -n "$dur" ]; then
        enable_extra=":enable='between(t,0,$dur)'"
    fi

    printf "drawtext=fontfile='%s':text='%s':fontcolor=white:fontsize=%d:box=1:boxcolor=black@0.6:boxborderw=%d:x='%s':y='%s'%s%s" \
        "$FONT" "$text" "$fontsize" "$boxborderw" "$x_expr" "$y_expr" "$alpha_extra" "$enable_extra"
}

# Tool checks
command -v ffmpeg  >/dev/null || { err "ffmpeg not installed (apt install ffmpeg)"; exit 1; }
command -v ffprobe >/dev/null || { err "ffprobe not installed (comes with ffmpeg)"; exit 1; }
[ -f "$RAW" ] || { err "raw file not found: $RAW"; exit 1; }
[ -f "$FONT" ] || { err "font not found: $FONT — install fonts-dejavu or edit FONT="; exit 1; }

mkdir -p "$(dirname "$OUT")"

# ---- Resolve CROP=auto via cropdetect on a negated sample -------------
#
# cropdetect's default heuristic is "crop out dark borders", which is the
# opposite of what we want here (the terminal IS the dark area we want to
# keep). Inverting the frame first flips the polarity so the bright
# desktop background becomes the "border" that cropdetect trims.
#
# Sample ~25% into the raw — past the title dwell, into actual content
# with high-contrast text. We run cropdetect over a 3-second window so
# it has enough frames to converge.
if [ "$CROP" = "auto" ]; then
    DURATION=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$RAW" 2>/dev/null || echo 0)
    SAMPLE_AT=$(awk -v d="$DURATION" 'BEGIN{ s = d * 0.25; if (s < 5) s = 5; printf "%.2f", s }')
    log "[crop=auto] probing $RAW at t=${SAMPLE_AT}s (duration ${DURATION}s)"
    DETECTED=$(ffmpeg -hide_banner -nostats -loglevel info \
        -ss "$SAMPLE_AT" -i "$RAW" -t 3 \
        -vf "negate,cropdetect=limit=24:round=2:reset=0" \
        -an -f null - 2>&1 \
        | grep -oE 'crop=[0-9]+:[0-9]+:[0-9]+:[0-9]+' \
        | tail -1 \
        | sed 's/^crop=//')
    if [ -z "$DETECTED" ]; then
        err "CROP=auto: cropdetect found nothing — desktop bg may be too dark."
        err "Fall back to an explicit CROP=W:H:x:y, or omit CROP."
        exit 1
    fi
    log "[crop=auto] detected: $DETECTED"
    CROP="$DETECTED"
fi

TMPDIR=$(mktemp -d /tmp/demo-edit-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT
log "raw:    $RAW"
log "output: $OUT"
log "tmp:    $TMPDIR"
log "segments: ${#SEGMENTS[@]}"
[ -n "$CROP" ] && log "crop:   $CROP"

CONCAT_LIST="$TMPDIR/concat.txt"
: > "$CONCAT_LIST"

# ---- Generate title card ------------------------------------------------

TITLE_CLIP="$TMPDIR/00-title.mp4"
log "[card] title"
ffmpeg -y -loglevel error \
    -f lavfi -i "color=c=black:s=1280x720:d=3:r=$FPS" \
    -vf "drawtext=fontfile='$FONT':text='$TITLE_CARD_TEXT':fontcolor=white:fontsize=32:x=(w-tw)/2:y=(h-th)/2" \
    -c:v libx264 -preset fast -crf "$CRF" -pix_fmt yuv420p \
    "$TITLE_CLIP"
echo "file '$TITLE_CLIP'" >> "$CONCAT_LIST"

# ---- Process each segment ----------------------------------------------

i=0
for seg in "${SEGMENTS[@]}"; do
    read -r START END SPEED LABEL <<< "$seg"
    i=$((i + 1))
    out_clip="$TMPDIR/$(printf '%02d' $((i+10)))-seg.mp4"

    # Build filter: PTS scaling + optional drawtext overlay (parsed
    # from LABEL's trailing @position/+animation/%duration modifiers).
    parse_label "$LABEL"
    DRAWTEXT=$(build_drawtext "$LABEL_TEXT" "$LABEL_POS" "$LABEL_ANIM" "$LABEL_DUR" "$SPEED")

    if awk "BEGIN{exit !($SPEED > 1.0)}"; then
        FILTER="setpts=PTS/${SPEED}"
    else
        FILTER="setpts=PTS"
    fi
    [ -n "$DRAWTEXT" ] && FILTER="$FILTER,$DRAWTEXT"

    # Optional crop prepended to the filter chain; runs in source pixel
    # space before setpts/drawtext/scale so coordinates are unambiguous.
    CROP_PREFIX=""
    if [ -n "$CROP" ]; then
        CROP_PREFIX="crop=${CROP},"
    fi

    # Build a short modifier summary for the log line.
    MOD_SUMMARY=""
    [ -n "$LABEL_POS" ]  && MOD_SUMMARY="${MOD_SUMMARY}@${LABEL_POS} "
    [ -n "$LABEL_ANIM" ] && MOD_SUMMARY="${MOD_SUMMARY}+${LABEL_ANIM} "
    [ -n "$LABEL_DUR" ]  && MOD_SUMMARY="${MOD_SUMMARY}%${LABEL_DUR}s "

    log "[seg $i] $START → $END  speed=${SPEED}x  ${LABEL_TEXT:+overlay='$LABEL_TEXT'  }${MOD_SUMMARY:+($MOD_SUMMARY) }${CROP:+crop=$CROP}"
    ffmpeg -y -loglevel error \
        -ss "$START" -to "$END" \
        -i "$RAW" \
        -vf "${CROP_PREFIX}${FILTER},scale=$RES,fps=$FPS" \
        -an \
        -c:v libx264 -preset fast -crf "$CRF" -pix_fmt yuv420p \
        "$out_clip"

    echo "file '$out_clip'" >> "$CONCAT_LIST"
done

# ---- Generate end card --------------------------------------------------

END_CLIP="$TMPDIR/99-end.mp4"
log "[card] end"
ffmpeg -y -loglevel error \
    -f lavfi -i "color=c=black:s=1280x720:d=${END_CARD_SECS}:r=$FPS" \
    -vf "drawtext=fontfile='$FONT':text='$END_CARD_TEXT':fontcolor=white:fontsize=32:x=(w-tw)/2:y=(h-th)/2" \
    -c:v libx264 -preset fast -crf "$CRF" -pix_fmt yuv420p \
    "$END_CLIP"
echo "file '$END_CLIP'" >> "$CONCAT_LIST"

# ---- Concatenate -------------------------------------------------------

log "[concat] joining $((${#SEGMENTS[@]} + 2)) clips..."
ffmpeg -y -loglevel error \
    -f concat -safe 0 -i "$CONCAT_LIST" \
    -c copy \
    "$OUT"

# ---- Report ------------------------------------------------------------

log "=== Done ==="
log "Output: $OUT"
SIZE=$(du -h "$OUT" | cut -f1)
DURATION=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT" 2>/dev/null | awk '{printf "%.1fs", $1}')
log "Size: $SIZE   Duration: $DURATION"

if awk "BEGIN{exit !($(du -b "$OUT" | cut -f1) > 10485760)}"; then
    log "Note: output > 10MB; consider raising CRF (currently $CRF) or shortening segments."
fi
