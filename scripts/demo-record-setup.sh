#!/usr/bin/env bash
#
# demo-record-setup.sh — Patch ~/.ssr/settings.conf with demo-tuned values.
#
# SimpleScreenRecorder persists its settings between runs in a section-
# scoped INI file. This script edits THAT file in place, touching only
# the keys the demo workflow cares about — capture rect, frame rate,
# codec, output path — and leaving everything else (hotkeys, screen
# preferences, audio settings the user chose) alone.
#
# Idempotent: re-run is a no-op if the file already matches the target.
# A backup at .ssr/settings.conf.bak.<utc> is written only when changes
# would actually be made.
#
# Usage:
#   ./scripts/demo-record-setup.sh             # patch in place
#   ./scripts/demo-record-setup.sh --dry-run   # print diff, don't write
#   ./scripts/demo-record-setup.sh --help
#
# Pairs with: docs/demo-recording.md (the end-to-end recipe)
#             scripts/demo-driver.sh (the swarm side of the demo)
#             scripts/edit-demo.sh   (post-processing into ~60-second MP4)

set -euo pipefail

CFG="${SSR_CONFIG:-$HOME/.ssr/settings.conf}"
DRY_RUN=0

usage() {
    cat <<'EOF'
demo-record-setup.sh — patch ~/.ssr/settings.conf for the llm-swarm-runner demo

Sets these keys in-place (other keys preserved):

  [input]
    video_area          = fixed
    video_x             = 0
    video_y             = 0
    video_w             = 1920
    video_h             = 1080
    video_frame_rate    = 30
    video_scale         = false
    video_record_cursor = true
    audio_enabled       = false

  [output]
    container           = mkv
    video_codec         = h264
    video_h264_crf      = 18
    video_h264_preset   = 4
    add_timestamp       = false
    file                = $HOME/Videos/demo-raw.mkv

Why these values: 1920×1080 fixed rect downscales cleanly (1.5×) to the
1280×720 final output produced by edit-demo.sh. CRF 18 is high-quality
source for post-processing. add_timestamp=false + fixed filename means
each take overwrites the same path, which edit-demo.sh consumes by
default.

If the SSR config file doesn't exist yet (clean install), this script
creates it with the demo values and SSR's standard section structure.

Options:
  --dry-run   Show what would change, but don't write.
  -h, --help  This message.

Env:
  SSR_CONFIG  Override the target file (default: ~/.ssr/settings.conf).
EOF
}

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown arg: $arg" >&2; usage >&2; exit 2 ;;
    esac
done

if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 is required (used for section-aware INI editing)." >&2
    exit 1
fi

mkdir -p "$(dirname "$CFG")"
[ -f "$CFG" ] || : > "$CFG"   # create empty if absent

OUT_FILE="$HOME/Videos/demo-raw.mkv"

# Section-aware INI patcher. configparser preserves insertion order
# (Python 3.7+) and we explicitly set optionxform=str to keep keys
# case-as-written (SSR's keys are lowercase, but we don't want
# silent normalisation either way).
python3 - "$CFG" "$OUT_FILE" "$DRY_RUN" <<'PY'
import configparser, hashlib, io, sys, time
from pathlib import Path

cfg_path = Path(sys.argv[1])
out_file = sys.argv[2]
dry_run  = sys.argv[3] == "1"

# (section, key, value) tuples. Order doesn't matter — configparser
# will create the section if missing, otherwise insert at section end.
TARGETS = [
    ("input",  "video_area",          "fixed"),
    ("input",  "video_x",             "0"),
    ("input",  "video_y",             "0"),
    ("input",  "video_w",             "1920"),
    ("input",  "video_h",             "1080"),
    ("input",  "video_frame_rate",    "30"),
    ("input",  "video_scale",         "false"),
    ("input",  "video_record_cursor", "true"),
    ("input",  "audio_enabled",       "false"),
    ("output", "container",           "mkv"),
    ("output", "video_codec",         "h264"),
    ("output", "video_h264_crf",      "18"),
    ("output", "video_h264_preset",   "4"),
    ("output", "add_timestamp",       "false"),
    ("output", "file",                out_file),
]

cp = configparser.ConfigParser()
cp.optionxform = str  # preserve case (SSR uses lowercase keys; don't normalise)
# SSR writes plain "key=value" — configparser handles that with default settings.
cp.read(cfg_path)

before = io.StringIO()
cp.write(before, space_around_delimiters=False)
before_text = before.getvalue()

changes = []   # list of (section, key, old, new)
for section, key, want in TARGETS:
    if not cp.has_section(section):
        cp.add_section(section)
        changes.append((section, key, "(section absent)", want))
        cp.set(section, key, want)
        continue
    have = cp.get(section, key, fallback=None)
    if have == want:
        continue
    changes.append((section, key, repr(have) if have is not None else "(unset)", want))
    cp.set(section, key, want)

after = io.StringIO()
cp.write(after, space_around_delimiters=False)
after_text = after.getvalue()

# Report.
if not changes:
    print(f"OK — {cfg_path} already has the demo-tuned values. No changes needed.")
    sys.exit(0)

print(f"Patching {cfg_path}:")
print(f"  ({len(changes)} change{'s' if len(changes) != 1 else ''})")
for section, key, old, new in changes:
    print(f"    [{section}] {key}: {old} -> {new}")
print()

if dry_run:
    print("--dry-run: not writing.")
    sys.exit(0)

# Back up the original (only if the file had real content).
if before_text.strip():
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    bak = cfg_path.with_suffix(cfg_path.suffix + f".bak.{stamp}")
    bak.write_text(before_text)
    print(f"Backup written: {bak}")

cfg_path.write_text(after_text)
print(f"Wrote: {cfg_path}")

# Sanity: hash of resulting file, so re-runs can confirm idempotence visually.
h = hashlib.sha256(after_text.encode()).hexdigest()[:12]
print(f"sha256[:12]: {h}")
PY

# Recording output directory must exist before SSR will write to it.
mkdir -p "$HOME/Videos"

if [ "$DRY_RUN" -eq 0 ]; then
    cat <<EOF

Done. Recipe:
  1. Open SimpleScreenRecorder (it will load $CFG automatically).
  2. Position your terminal at (0,0) sized 1920x1080 (a single un-tmuxed
     window the demo will tmux inside).
  3. In another terminal: cd /opt/work/llm-swarm-runner
  4. Start recording in SSR.
  5. ./scripts/demo-driver.sh
  6. Stop recording in SSR.
  7. ./scripts/edit-demo.sh    # consumes ~/Videos/demo-raw.mkv by default

Full recipe + troubleshooting: docs/demo-recording.md
EOF
fi
