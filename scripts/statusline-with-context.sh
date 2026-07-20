#!/usr/bin/env bash
#
# statusline-with-context.sh — Claude Code statusLine command that shows
# context-window usage alongside model and cwd. Motivated by the
# long-lived-coordinator pattern (see docs/advanced-usage.md): a Claude
# session running for days drifts into the "stupid zone" above ~120k
# tokens; this surface makes the drift visible at a glance without
# having to invoke /context.
#
# Install (per-user, in ~/.claude/settings.json):
#
#     {
#       "statusLine": {
#         "type": "command",
#         "command": "/opt/work/llm-swarm-runner/scripts/statusline-with-context.sh"
#       }
#     }
#
# (/opt/work/llm-swarm-runner is this repo's path in the reference swarm
# deployment — adjust to wherever you cloned it.)
#
# The path must be absolute. If you want this under ~/.claude/ instead of
# the repo, symlink it: `ln -s /opt/work/llm-swarm-runner/scripts/statusline-with-context.sh ~/.claude/statusline.sh`
# and reference ~/.claude/statusline.sh in settings.json.
#
# Output format:  <model> · <cwd-basename> · ctx: <used>/<total> (<%>)
# Example:        opus · spring-search-tempo · ctx: 195k/1M (19%)
#
# This script also writes the raw stdin payload to $STATUSLINE_PROBE on
# every render (default ${XDG_RUNTIME_DIR:-/tmp}/claude-statusline-$UID.json).
# That dump exists so the *exact* JSON field names for the context window can
# be confirmed against a real Claude Code render — the first version of
# this script tries several plausible paths and the dump tells us which
# one Claude Code actually uses. Once we've confirmed, the fallback
# probes can be removed.

# Only -u, not -euo pipefail: this runs as a statusLine command hook, so any
# non-zero exit or unbound var here would blank the statusline every render
# instead of just degrading one field to "?" — the never-fail contract wins
# over strictness.
set -u

PROBE="${STATUSLINE_PROBE:-${XDG_RUNTIME_DIR:-/tmp}/claude-statusline-$UID.json}"

input="$(cat)"
# Write via mktemp+mv rather than a direct `>`: on the shared-/tmp fallback
# (when XDG_RUNTIME_DIR is unset) an attacker with a different UID can
# pre-plant a symlink at $PROBE that we cannot unlink (sticky-bit /tmp only
# lets the symlink's owner remove it), so a plain redirect would silently
# follow it into an arbitrary file. `mv` replaces whatever sits at the
# destination via an atomic rename(2) — it never follows a symlink-to-file
# there — so this is safe regardless of who owns it. Skipping when the
# destination resolves to a directory avoids the one case where mv
# behaves the "wrong" way (moving into it instead of replacing it) —
# checked ahead of the mv rather than fixed with GNU's `-T` (which
# macOS/BSD mv lacks); a symlink-to-directory planted in the resulting
# check-then-mv window would still divert the temp file into that
# directory, but never overwrites anything the attacker doesn't already
# control, so this is a best-effort narrowing, not a hard guarantee.
# No unsafe fallback on mktemp failure (e.g. an attacker exhausting /tmp
# inodes to force it) — skip the probe for this render rather than fall
# back to the direct-redirect hazard mktemp+mv exists to avoid. Also clean
# up the temp file if the write, the directory check, or the mv itself
# fails, since this runs on every render and a leaked temp file per
# failed render adds up fast.
probe_dir="$(dirname "$PROBE")"
if probe_tmp="$(mktemp "$probe_dir/.claude-statusline.XXXXXX" 2>/dev/null)"; then
    if [ -d "$PROBE" ] || ! printf '%s' "$input" > "$probe_tmp" || ! mv -f "$probe_tmp" "$PROBE"; then
        rm -f "$probe_tmp" 2>/dev/null
    fi
fi

# --- Model ---------------------------------------------------------------
model=$(printf '%s' "$input" | jq -r '
    .model.display_name? //
    .model.id? //
    (.model | select(type == "string")) //
    .model_name? //
    .session.model? //
    empty
' 2>/dev/null)
[ -z "$model" ] && model="?"

# Short model label: strip "claude-" prefix, take first dashed segment.
# claude-opus-4-7[1m] → opus
# claude-sonnet-4-6   → sonnet
short_model="${model#claude-}"
short_model="${short_model%%-*}"
[ -z "$short_model" ] && short_model="$model"

# --- CWD basename --------------------------------------------------------
cwd=$(printf '%s' "$input" | jq -r '
    .workspace.current_dir //
    .workspace.cwd //
    .cwd //
    .session.cwd //
    empty
' 2>/dev/null)
cwd_label="${cwd##*/}"
[ -z "$cwd_label" ] && cwd_label="?"

# --- Context window ------------------------------------------------------
# Try multiple plausible field paths; first non-empty wins.
ctx_pct=$(printf '%s' "$input" | jq -r '
    .context_window.used_percentage //
    .context.used_percentage //
    .context.percent //
    .usage.context_used_percent //
    empty
' 2>/dev/null)
ctx_used=$(printf '%s' "$input" | jq -r '
    .context_window.total_input_tokens //
    .context_window.used_tokens //
    .context.input_tokens //
    .context.used //
    .usage.input_tokens //
    empty
' 2>/dev/null)
ctx_total=$(printf '%s' "$input" | jq -r '
    .context_window.context_window_size //
    .context_window.total //
    .context.window_size //
    .context.total //
    .model_context_window //
    empty
' 2>/dev/null)

fmt_tokens() {
    local n="$1"
    if [ "$n" -ge 1000000 ]; then
        printf '%dM' "$((n / 1000000))"
    elif [ "$n" -ge 1000 ]; then
        printf '%dk' "$((n / 1000))"
    else
        printf '%d' "$n"
    fi
}

# Both fields must be plain non-negative integers, and total must be
# nonzero, before any arithmetic touches them — a non-numeric or zero
# total (e.g. "1M", or a not-yet-populated 0) must degrade to "?"
# rather than take down the statusline via a division/unbound-var death.
is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }
# Percentages may be reported as floats (e.g. "19.4"); same guard, decimal allowed.
is_pct() { [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]]; }
is_pct "$ctx_pct" || ctx_pct=""

if is_uint "$ctx_used" && is_uint "$ctx_total" && [ "$ctx_total" -gt 0 ]; then
    used_fmt=$(fmt_tokens "$ctx_used")
    total_fmt=$(fmt_tokens "$ctx_total")
    if [ -n "$ctx_pct" ]; then
        pct_int="${ctx_pct%.*}"
        ctx_label="${used_fmt}/${total_fmt} (${pct_int}%)"
    else
        # Compute percentage ourselves if not provided.
        pct_int=$((ctx_used * 100 / ctx_total))
        ctx_label="${used_fmt}/${total_fmt} (${pct_int}%)"
    fi
elif [ -n "$ctx_pct" ]; then
    pct_int="${ctx_pct%.*}"
    ctx_label="${pct_int}%"
else
    ctx_label="?"
fi

# --- Compose -------------------------------------------------------------
printf '%s · %s · ctx: %s' "$short_model" "$cwd_label" "$ctx_label"
