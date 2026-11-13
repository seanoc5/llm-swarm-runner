#!/usr/bin/env bash
# _pane-composer.sh — sourced helpers that read what a tmux pane's composer
# (input box) holds. Shared by coordinator-watch.sh (its doorbell/compact/
# deliver gates) and swarm-nudge.sh (the human-only send-keys escape hatch,
# issue #585) so both judge "composer clear" with the same code.
# Needs: tmux on PATH. Callers under `set -e -o pipefail` are fine.

# Default busy-pane pattern (spinner hint, exit-confirm, token ticker, queued-
# input hint, compaction). coordinator-watch.sh's AUTO_COMPACT_BUSY_PATTERN and
# WORKER_COMPACT_BUSY_PATTERN default to it; pass it to coord_pane_busy_visible.
PANE_BUSY_PATTERN_DEFAULT='\(esc to interrupt\)|Press Ctrl-C again to .xit|· ↓ [0-9.,]+k? tokens|Press up to edit queued messages|Compacting conversation'

# Chrome patterns (moved verbatim from coordinator-watch.sh; the header
# comments there still describe the incidents behind them).
COMPACT_COMPOSER_CHROME_PATTERN="${COMPACT_COMPOSER_CHROME_PATTERN:-^※ recap:|^[[:space:]]*(✻|✶)[[:space:]]*(Considering…|Sautéed for|Cooked for|Baked for|Simmered for|Brewed for|Crunched for)?|/clear to save [0-9.]+k tokens}"
COMPACT_FOOTER_PATTERN="${COMPACT_FOOTER_PATTERN:-^[[:space:]]*(⏵⏵|⏸)[[:space:]]|^[[:space:]]*([0-9]+ shells?|[0-9]+ background tasks?|← ([0-9]+|for) agents?)([[:space:]]*·[[:space:]]*([0-9]+ shells?|[0-9]+ background tasks?|← ([0-9]+|for) agents?))*[[:space:]]*\$}"

# compact_last_pane_line <tmux-target>
#
# (issue #290) Echoes the last non-blank rendered line of <target>'s pane,
# ANSI-stripped (same sed chain used throughout this file) and trimmed of
# common composer chrome (prompt markers ❯/>/|, box-drawing borders) so
# callers can judge composer content/emptiness. This is a guess at how the
# CLI frames its composer, not a verified spec — re-check against a live
# pane if this misclassifies.
#
# A self-review on this function's first version flagged that "the
# composer is the pane's last rendered line" can be wrong on its own: a
# persistent statusline/hint line below the composer would make this
# permanently pick THAT line instead, misreading a genuinely-empty composer
# as non-empty forever. For the worker path this is a KNOWN, not merely
# hypothetical, risk — worker_pane_ctx_used/worker_pane_ctx_window (above)
# already parse a persistent "ctx: <used>/<total> (<pct>%)" statusline out
# of the exact same capture-pane output — so that specific line is excluded
# before picking the tail. No equivalently well-established coordinator-side
# persistent-chrome text exists elsewhere in this file to filter the same
# way; that half of the risk remains a live-pane-unverified guess like the
# rest of this feature's TUI-chrome parsing.
compact_last_pane_line() {
    local target="$1" content clean
    content="$(tmux capture-pane -e -t "$target" -p 2>/dev/null)" || { echo ""; return 1; }
    clean="$(printf '%s\n' "$content" | LC_ALL=C sed -E 's/\x1b\[((0|1|3|4|5|7|9|22|23|24|27|29|3[0-79]|4[0-79]|9[0-7]|10[0-7]);)*2(;[0-9;]*)?m([^\x1b]|\x1b\[[349][0-9;]*m)*//g' | LC_ALL=C sed 's/\x1b\[[0-9;?]*[A-Za-z]//g; s/\x1b\][^\x07]*\x07//g; s/\x1b[()][AB012]//g; s/\r/\n/g; s/\xc2\xa0/ /g')"
    # `|| true` on the whole pipeline: under this file's `set -o pipefail`,
    # a captured pane whose EVERY line happens to match the ctx: exclusion
    # below (grep -v then produces zero lines and exits 1) would otherwise
    # make this function return non-zero for a reason that has nothing to
    # do with a real failure — and since callers assign the result via a
    # bare (non-`local`) `last="$(compact_last_pane_line ...)"`, that
    # non-zero would trip `set -e` and abort the watcher. Only the explicit
    # capture-pane failure above is a real failure this function reports.
    # (issue #440) Three things the pre-#440 version misread as composer
    # content, each of which made an EMPTY idle composer look "dirty":
    #   1. Claude Code 2.1.x's persistent mode footer ("⏵⏵ bypass permissions
    #      on (shift+tab to cycle) · ← for agents", plus accept-edits / plan /
    #      auto variants) renders BELOW the composer, so it was the pane's
    #      last non-blank line whenever the composer was empty — every idle
    #      coordinator deferred (364/367 wakes on corpusminder-spring,
    #      2026-09-16 → 09-19). Dropped by the "(shift+tab to cycle)" hint,
    #      which every mode variant carries.
    #   2. The full-width ─ rule the TUI draws under the composer. Dropped as
    #      a box-drawing-only line — necessary once (1) is gone, or the rule
    #      becomes the last line and a REAL draft above it reads as clear.
    #   3. Framework-generated dim text in the composer itself: the empty-
    #      composer placeholder (Try "edit <filepath> to...") and the
    #      suggested-next-prompt autofill (the "known false positive" in
    #      reprompt_composer_dirty's comment). Verified on live panes: both
    #      render as ESC[2m dim runs (closed per word, per run, or not
    #      at all before end-of-line); text a human actually typed carries no
    #      SGR at all. So capture with -e and strip dim segments BEFORE the
    #      general ANSI strip — what survives is what a person typed.
    # (issue #436) A fourth chrome shape, distinct from the three above: the
    # "※ recap:" line, the spinner's past/present-tense verb residue, and
    # the "/clear to save Nk tokens" hint can each independently land as the
    # pane's own LAST line — not just below a composer whose ctx: line is
    # intact, but also when line-wrap (a longer token count, a narrower
    # terminal) splits the hint off the "ctx: N/M (P%)" line this function
    # already drops whole, so the ctx: exclusion above never sees it as part
    # of the same line. See COMPACT_COMPOSER_CHROME_PATTERN's header comment
    # for the full incident (a 1,812-skip/~14h stall against a genuinely
    # empty composer) and why this is its own pattern rather than folded
    # into the ctx:/shift-tab exclusion above.
    # The NBSP the TUI emits after ❯ is folded to a space so an empty prompt
    # trims to a genuinely empty string.
    # (2026-10-27) The footer drops "(shift+tab to cycle)" while background
    # shells or agents run — see COMPACT_FOOTER_PATTERN's header comment.
    printf '%s\n' "$clean" \
        | LC_ALL=C grep -vE "ctx: [0-9]+[kM]?/[0-9]+[kM]?[[:space:]]*\([0-9]+%\)|\(shift\+tab to cycle\)|^[[:space:]]*[─╭╮╰╯│]+[[:space:]]*\$|$COMPACT_COMPOSER_CHROME_PATTERN|$COMPACT_FOOTER_PATTERN" \
        | sed -e '/^[[:space:]]*$/d' -e 's/^[[:space:]]*[❯>│|╭╮╰╯─]*[[:space:]]*//' -e 's/[[:space:]]*[│|╭╮╰╯─]*[[:space:]]*$//' | tail -1 || true
}

# compact_composer_clear <tmux-target>
#
# (issue #290) True (rc 0) if compact_last_pane_line's trimmed result is
# empty — i.e. the composer genuinely holds nothing, not just "the queued-
# input marker is gone" (COMPACT_QUEUED_MARKER_PATTERN alone can never
# catch a PARTIAL retraction: a leftover "/compa" ghost matches neither
# that marker nor any prior check, which is exactly how issue #290's
# ghost-text symptom slipped past #265/#272's retraction success check).
compact_composer_clear() {
    local target="$1" last
    last="$(compact_last_pane_line "$target")" || true
    [ -z "$last" ]
}
