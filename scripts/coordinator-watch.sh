#!/usr/bin/env bash
#
# coordinator-watch.sh — wake the coordinator on worker-finished events.
#
# Long-running daemon. Watches every worker's `.swarm/tasks/done/` dir
# under the given project. When a new outcome JSON appears there (i.e. a
# worker finished a task), wakes the coordinator via `llm-start.sh` so
# it can triage / re-dispatch / merge / etc.
#
# Pairs with the queued protocol from worker-listener.sh — proves the
# "event-driven coordinator" upgrade path described in the README.
#
# Usage:
#   coordinator-watch.sh [project-dir]
#
# Env vars:
#   DEBOUNCE_SECS=30        Window during which repeated events coalesce
#                           into a single coordinator wake. Prevents runaway
#                           when many workers finish near-simultaneously.
#   DRY_RUN=0               Set to 1 to log what would happen without
#                           actually invoking llm-start.sh.
#   ONCE=0                  Set to 1 to exit after first successful wake.
#                           Useful for smoke-testing.
#   LLM_START=<path>        Override path to llm-start.sh.
#   WAKE_PROMPT=<text>      Prompt sent to the coordinator on wake.
#   POLL_SECS=2             Polling interval (used only in polling-mode
#                           fallback when inotifywait is unavailable).
#   POST_OUTCOMES=0         Set to 1 to also run sweep-swarm-outcomes.sh
#                           on each detected outcome. Posting is naturally
#                           idempotent via .posted markers, so this fires
#                           outside the wake-debounce window — every
#                           outcome gets audit coverage even when wakes
#                           are coalesced. Honors $OUTCOME_HOOK; falls
#                           back to dry-run stub if unset.
#   SWEEP=<path>            Override path to sweep-swarm-outcomes.sh.
#   WATCHER_AUTOCLOSE=1     Set to 0 to disable automatic cleanup of
#                           finalized workers before each coord.wake. When
#                           enabled (default), invokes kill-finished-workers.sh
#                           with --with-worktree --yes plus a PR-state flag
#                           chosen by WATCHER_AUTOCLOSE_MODE (below) so
#                           eligible workers fully reap (window + worktree +
#                           local branch) and free their slot. OPEN PRs and
#                           "no PR yet" cases are always left untouched,
#                           regardless of mode.
#   WATCHER_AUTOCLOSE_MODE=merged
#                           (issue #237) Which terminal PR states count as
#                           "eligible to reap" for WATCHER_AUTOCLOSE, applied
#                           consistently at both autoclose call sites (the
#                           outcome-triggered cleanup_eligible_workers call
#                           and the WATCH_PR_POLL_SECS pr_poll_pass backstop
#                           below):
#                             merged     (default) STRICT — only a MERGED PR
#                                        is reap-eligible
#                                        (kill-finished-workers.sh --merged-only).
#                                        A CLOSED-without-merge PR is left
#                                        alone entirely: window, worktree, and
#                                        branch all stay put, and pr_poll_pass
#                                        doesn't even log terminal_pr_detected
#                                        for it — a closed-without-merge PR is
#                                        a rejection/oddity the operator likely
#                                        wants to inspect, not a clean success
#                                        like a merge.
#                             finalized  MERGED *or* CLOSED is reap-eligible
#                                        (kill-finished-workers.sh
#                                        --pr-finalized) — this is the
#                                        behavior WATCHER_AUTOCLOSE had before
#                                        this knob existed. CLOSED PRs are
#                                        treated as terminal — the user said
#                                        no — but origin/fix/issue-N is
#                                        preserved by kill-worktree.sh, so
#                                        accidental closures are recoverable
#                                        via `gh pr reopen N`.
#                           The WATCH_ORPHAN_SWEEP_SECS orphan sweep below is
#                           NOT gated by this knob — it always runs
#                           reap-orphan-worktrees.sh --pr-finalized. That
#                           sweep only ever reaches worktrees whose tmux
#                           window is already gone (see its own header
#                           comment), so there's no live window/scrollback
#                           left to preserve for operator inspection either
#                           way — the "leave it for review" motivation behind
#                           this knob doesn't apply there.
#
#   WATCH_PR_POLL_SECS=60   (issue #119) The outcome-driven trigger above
#                           only fires when a NEW outcome.json appears —
#                           but outcome.json is written once, usually
#                           right after the PR is opened. A PR that merges
#                           later (parked interactive worker, or the user
#                           batch-merging while away) never produces a
#                           second outcome.json, so the reap pass never
#                           re-runs for it. This knob starts an independent
#                           background timer that, every N seconds, runs a
#                           single `gh pr list --state all` call across all
#                           worker branches and re-fires the WATCHER_AUTOCLOSE
#                           reap pass if any tracked worktree's PR has gone
#                           MERGED/CLOSED. Set to 0 to disable (falls back to
#                           the original outcome-only behavior). Gated by
#                           WATCHER_AUTOCLOSE — if that's 0, detection still
#                           logs but no reap fires. Same poll also powers the
#                           check-on-done PR-open backstop (see
#                           WATCH_CHECK_ON_DONE).
#
#                           (issue #225) A terminal PR only becomes a
#                           reap_hit here if a LIVE iss-N tmux window
#                           actually exists — kill-finished-workers.sh
#                           (invoked by cleanup_eligible_workers) iterates
#                           live windows only, so a worktree that outlived
#                           its window (session restart, docker daemon
#                           restart — cf. #217) can never be reaped by that
#                           path. Such window-less worktrees are logged
#                           once (not every poll) as watch.pr_poll
#                           reason=orphan_no_window and left to the slower
#                           WATCH_ORPHAN_SWEEP_SECS sweep below, which
#                           walks worktree DIRECTORIES instead of tmux
#                           windows and can actually clear them.
#   WATCH_ORPHAN_SWEEP_SECS=3600
#                           (issue #225) Independent, much slower timer
#                           that runs reap-orphan-worktrees.sh --pr-finalized
#                           --yes to clear worktrees whose tmux window is
#                           already gone but the directory + local branch
#                           survive with a finalized (MERGED/CLOSED) PR —
#                           exactly the case WATCH_PR_POLL_SECS's
#                           kill-finished-workers.sh pass can't reach. Runs
#                           from the same background timer loop, gated by
#                           WATCHER_AUTOCLOSE (set that to 0 to disable all
#                           auto-reaping, including this). Set to 0 to
#                           disable just the orphan sweep while keeping the
#                           window-based reap on WATCH_PR_POLL_SECS. Honors
#                           DRY_RUN. Override REAP_ORPHAN to point at a
#                           non-standard reap-orphan-worktrees.sh.
#                           Like WATCH_PR_POLL_SECS, the first sweep fires on
#                           the timer loop's very first tick (not one full
#                           interval after startup) — every coordinator-watch
#                           restart runs one immediately. This is a real
#                           (non-dry-run, --yes) reap-orphan-worktrees.sh
#                           pass, not just a detection poll; its own
#                           min-age-days/clean-tree/PR-finalized predicate is
#                           what keeps this safe on a frequent-restart dev
#                           loop, not sweep timing.
#   WATCH_CHECK_ON_DONE=1   Set to 0 to disable check-on-done. When enabled,
#                           the watcher treats a worker as "done" via either
#                           signal: (a) a `.swarm/tasks/status/<id>.json`
#                           file with state "ready-for-review" (fast path,
#                           polled every 2s), or (b) a PR appearing on
#                           fix/issue-N with no status file (backstop, via
#                           the WATCH_PR_POLL_SECS poll). On first done
#                           signal per task (atomic claim via mkdir — losing
#                           path no-ops), resolves the same acceptance check
#                           worker-listener.sh would (brief marker ->
#                           .swarm/check.sh -> WORKER_CHECK_CMD) and runs it
#                           once in a visible tmux window `chk-N`, recording
#                           the result to `<id>.check.json` and events.log.
#                           (issue #181) If the PR is already MERGED/CLOSED
#                           by the time the claim is won, the check is
#                           skipped entirely (merge already validated the
#                           work) and recorded as state=skipped. The claim
#                           dir doubles as a reap-side guard — see
#                           kill-worktree.sh, which defers removing a
#                           worktree while its check-claim is unexpired —
#                           and is released the moment the check reaches a
#                           terminal outcome, or after CHECK_CLAIM_STALE_SECS
#                           (default WORKER_CHECK_TIMEOUT+300s) if the check
#                           process itself crashed without releasing it.
#   CHECK_RUNNER=<path>     Test-only override: when set, check-on-done runs
#                           `$CHECK_RUNNER <worktree> <check_cmd>` synchronously
#                           instead of spawning a real tmux window. Lets tests
#                           exercise the claim/resolve/record logic without a
#                           live tmux session.
#   SESSION_NAME=<name>     tmux session check-on-done spawns chk-N windows
#                           in. Default: llm-$(basename PROJECT_DIR), matching
#                           kill-finished-workers.sh / provision-worker.sh.
#   WATCHER_QUIET=0         (issue #38) Set to 1 to suppress the human-
#                           readable pane echo below, restoring silent-
#                           stdout (banner only) — for headless runs or
#                           when piping the watcher's own stdout elsewhere.
#   AUTO_COMPACT=1          Before waking a long-lived coordinator (live
#                           claude REPL still in the pane, not a fresh
#                           launch), check its context usage and inject a
#                           real `/compact` — not just text in the input
#                           box, an actual submitted command, the same
#                           load-buffer+paste-buffer+Enter mechanism
#                           llm-start.sh's live-REPL reprompt path uses —
#                           if it's at/above AUTO_COMPACT_THRESHOLD_TOKENS.
#                           Blocks (polling capture-pane) until compaction
#                           visibly starts and finishes before proceeding
#                           to the normal wake. Requires
#                           scripts/statusline-with-context.sh to be
#                           installed as the coordinator's statusLine —
#                           that's this feature's only source of context
#                           data (via the probe file it writes); with no
#                           fresh probe file, this is a no-op (fails open,
#                           never blocks the wake). Set to 0 to disable.
#                           After a confirmed compaction, re-checks the
#                           probe once the statusline has had a moment to
#                           re-render — whether a pasted "/compact" is
#                           truly parsed as the slash command (vs. a plain
#                           chat message) isn't verifiable short of a live
#                           session, and a silent miss would otherwise
#                           repeat every wake with no visible symptom. If
#                           usage didn't drop, logs coord.compact.ineffective
#                           loudly rather than let that happen quietly.
#
#                           (issue #210) This wake-path trigger (called from
#                           on_outcome, right before a coord.wake) is one of
#                           TWO triggers into the same maybe_auto_compact —
#                           see AUTO_COMPACT_TICK_SECS below for the other,
#                           a periodic poll-tick trigger that fires even when
#                           no worker ever finishes. maybe_auto_compact takes
#                           a `trigger` arg (wake|poll, defaults to wake) that
#                           is recorded on every coord.compact* event it logs
#                           — see EVENTS LOG below — but otherwise runs
#                           identical logic either way; this wake-path call
#                           site's behavior is unchanged by that addition.
#   AUTO_COMPACT_TICK_SECS=60
#                           (issue #210) A coordinator that stays busy on a
#                           long, purely interactive stretch — the user
#                           driving it directly, no worker ever finishing —
#                           never reaches on_outcome, so the wake-path
#                           trigger above never runs and context can grow
#                           unbounded until a human notices. This starts an
#                           independent tick, from its own dedicated
#                           background process (run_auto_compact_poll_loop —
#                           NOT WATCH_PR_POLL_SECS's run_watch_timer_loop; a
#                           compaction can block for minutes, and sharing
#                           that loop would stall its status/PR polling for
#                           the duration — same reasoning as
#                           WORKER_AUTO_COMPACT's separate loop, see
#                           run_auto_compact_poll_loop's header comment),
#                           that calls maybe_auto_compact with trigger=poll
#                           every AUTO_COMPACT_TICK_SECS — deliberately its
#                           own interval, not reusing WATCH_PR_POLL_SECS's,
#                           so disabling the PR-poll backstop
#                           (WATCH_PR_POLL_SECS=0) doesn't silently disable
#                           this too. Set to 0 to disable just this trigger
#                           while keeping AUTO_COMPACT=1 for the wake path
#                           (the dedicated process itself only starts when
#                           both AUTO_COMPACT=1 and this is nonzero — see the
#                           loop-startup section near the bottom of the
#                           script). Every other precondition (idle cli pane,
#                           fresh probe, threshold) is identical to the
#                           wake-path trigger — see maybe_auto_compact.
#   AUTO_COMPACT_COOLDOWN_SECS=900
#                           (issue #210) Applies ONLY to the poll-tick
#                           trigger above (never to the wake-path trigger —
#                           that one is already rate-limited by DEBOUNCE_SECS
#                           and only runs when a worker actually finishes, so
#                           it needs no extra guard, and adding one there
#                           would violate "wake-path behavior unchanged").
#                           After a poll-tick call to maybe_auto_compact
#                           actually attempts a compaction (i.e. it got far
#                           enough to log a bare coord.compact event —
#                           whether that attempt then finishes cleanly or
#                           turns out coord.compact.ineffective), the poll-
#                           tick trigger suppresses itself for this many
#                           seconds (logging coord.compact.skip
#                           reason=cooldown trigger=poll each tick it would
#                           otherwise have fired) before trying again.
#                           Without this, a probe that hasn't refreshed yet
#                           post-compact (see AUTO_COMPACT_VERIFY_TIMEOUT_SECS)
#                           would still read as over-threshold on the very
#                           next tick and re-inject /compact into a pane
#                           that may just be idling while its statusline
#                           catches up — an unbounded injection loop. Tracked
#                           in-memory by run_auto_compact_poll_loop's own
#                           process (not a file), so it resets on watcher
#                           restart.
#   AUTO_COMPACT_THRESHOLD_TOKENS=150000
#                           Used-token threshold that triggers the above.
#   AUTO_COMPACT_PROBE=<path>
#                           Path to the statusline probe file. Defaults to
#                           the project+role-scoped path
#                           coordinator-claude.sh sets STATUSLINE_PROBE to
#                           for its own claude invocation
#                           (${XDG_RUNTIME_DIR:-/tmp}/claude-statusline-<project-basename>-coordinator.json)
#                           — deliberately NOT the statusline script's own
#                           generic per-UID default, which any other
#                           interactive `claude` session on the same host
#                           would silently clobber. Override only if
#                           you've set STATUSLINE_PROBE to something else
#                           for the coordinator's session specifically.
#   AUTO_COMPACT_PROBE_MAX_AGE_SECS=120
#                           Probe file older than this (mtime) is treated
#                           as stale — the coordinator may not actually be
#                           rendering right now — and the check is skipped
#                           rather than acted on.
#   AUTO_COMPACT_BUSY_PATTERN
#                           Regex checked against (ANSI-stripped) captured
#                           pane content to tell "claude is mid-turn" from
#                           "claude is idle at its input prompt" — both
#                           states show the same pane_current_command, so
#                           this is the only signal available. (issue #252)
#                           Defaults to the "(esc to interrupt)" hint that
#                           accompanies the spinner line for the ENTIRE
#                           duration of any in-flight turn or compaction —
#                           regardless of which present-tense verb Claude
#                           Code renders that cycle — plus the exit-confirm-
#                           pending prompt, which would misfire on a bare
#                           Enter. This replaced an earlier spinner-verb
#                           list (Considering…, Sautéed for, Cooked for,
#                           Baked for, Simmered for, ✻, ✶ — the same list
#                           check-stuck-workers.sh's detect_state() still
#                           uses for its ACTIVE state) after runtime-log
#                           analysis (#252) showed it failing both
#                           directions at once: newer verbs (e.g. "Cogitated
#                           for") aren't in any fixed list, so a live turn
#                           could read as idle, while a *finished* turn's
#                           past-tense summary line ("Simmered for 12s") can
#                           stay visible on screen and falsely read as busy.
#                           The "(esc to interrupt)" hint only renders while
#                           a turn is actually in flight and disappears the
#                           moment it ends, so it doesn't share either
#                           failure mode and needs no maintenance as Claude
#                           Code's verb wording evolves. This is still TUI
#                           chrome, not a documented API, and may need
#                           updating if Claude Code's rendering changes —
#                           keep in sync with WORKER_COMPACT_BUSY_PATTERN if
#                           you touch either (check-stuck-workers.sh's
#                           separate pattern is out of scope for #252 and
#                           still uses the verb list).
#   AUTO_COMPACT_START_TIMEOUT_SECS=15
#                           Max wait for the busy indicator to APPEAR after
#                           sending /compact (confirms the CLI actually
#                           picked it up). Giving up here just skips ahead
#                           to the normal wake — never blocks it.
#   AUTO_COMPACT_FINISH_TIMEOUT_SECS=300
#                           Max wait for the busy indicator to clear
#                           (compaction is a real, possibly minutes-long
#                           turn). Giving up here also just proceeds with
#                           the normal wake.
#   AUTO_COMPACT_VERIFY_TIMEOUT_SECS=30
#                           Max wait, after the busy indicator clears, for
#                           the probe file's mtime to actually advance past
#                           its pre-compaction value — confirms the
#                           statusline genuinely re-rendered with fresh
#                           data before trusting it for the ineffective-
#                           compaction check above. If it never refreshes
#                           in time, that's inconclusive (logged as
#                           coord.compact.verify_skip), not a failure —
#                           the wake still proceeds either way.
#   AUTO_COMPACT_POLL_SECS=2
#                           capture-pane / probe-mtime polling interval for
#                           all of the waits above.
#
#   WORKER_AUTO_COMPACT=1   (issue #226) Same idea as AUTO_COMPACT, generalized
#                           to every `iss-*` worker window in the session.
#                           Motivation: a worker running a model with a
#                           native 1M context window (e.g. Sonnet 5) can
#                           cruise past 400k+ tokens without Claude Code's
#                           built-in auto-compact ever firing — that trigger
#                           keys off *window fill*, not absolute token count,
#                           so a 1M-window model stays deep in the quality
#                           "dumb zone" (roughly 150k+) far longer than a
#                           200k-window model would. Workers idle at their
#                           REPL prompt between turns the same way the
#                           coordinator does (interactive mode — see
#                           worker-listener.sh's header comment), so the same
#                           between-turn injection pattern applies.
#                           Context source differs from the coordinator's: a
#                           worker's statusline probe file is written INSIDE
#                           its docker container, to a path the host can't
#                           see (no /tmp or $XDG_RUNTIME_DIR bind-mount — see
#                           sandbox.sh's MOUNTS array). Instead this parses
#                           the rendered statusline text straight out of
#                           `tmux capture-pane` output (the same
#                           statusline-with-context.sh output the coordinator
#                           uses, "ctx: <used>/<total> (<pct>%)" — installed
#                           per-user in ~/.claude/settings.json, which
#                           sandbox.sh bind-mounts into every worker
#                           container too). No probe file, no staleness
#                           check needed — whatever's currently on screen IS
#                           current. See worker_pane_ctx_used().
#                           A background pass (worker_compact_pass(), run
#                           from its OWN dedicated loop — run_worker_compact_
#                           loop, on its own WORKER_COMPACT_SCAN_SECS
#                           interval, deliberately NOT sharing the existing
#                           WATCH_PR_POLL_SECS/status-file timer loop — see
#                           run_worker_compact_loop's header comment for why)
#                           enumerates every `iss-*` window each cycle and,
#                           for any that's idle (cli foreground, not
#                           mid-turn) and over threshold, injects /compact
#                           the same way maybe_auto_compact does for the
#                           coordinator, then sends a short "continue" nudge
#                           once compaction finishes. Fails open exactly
#                           like AUTO_COMPACT: a busy pane, an unparseable
#                           statusline, or any timeout just skips that
#                           window this cycle. A single compaction can block
#                           for minutes (see WORKER_COMPACT_FINISH_TIMEOUT_
#                           SECS below) — this never blocks the coordinator-
#                           watch.sh outcome/status/PR-poll machinery
#                           because it runs in its own process, but it DOES
#                           mean other over-threshold windows in the same
#                           sweep queue up behind it (serial, not parallel).
#                           Known limitation: a single marathon turn offers
#                           no idle window until it ends — this only catches
#                           workers idling BETWEEN turns, not mid-turn (that
#                           would be a much riskier Esc-to-interrupt "Tier B"
#                           this issue deliberately does not build — see
#                           worker_compact_pass()'s header comment).
#                           Set to 0 to disable.
#                           (issue #252) Before injecting, maybe_worker_compact
#                           now also skips (worker.compact.skip
#                           reason=task_done) any window whose CURRENT task
#                           has already finished — see worker_task_done().
#                           Runtime-log analysis found 13/88 real injections
#                           landing within 3 minutes of the same worker's
#                           finish event: the pre-#252 wrap-up-threshold
#                           guard (WORKER_COMPACT_WRAPUP_THRESHOLD_TOKENS
#                           above) loses this race because the status file's
#                           "pr" field is written LAST in worker-listener.sh's
#                           wind-down, well after the pane already shows the
#                           final summary. worker_task_done checks three
#                           signals, earliest-available first: (a) an outcome
#                           file already in the worktree's
#                           `.swarm/tasks/done/` (the on_outcome/
#                           WATCHER_AUTOCLOSE reap path will pick this window
#                           up shortly, so compacting it first is pure waste);
#                           (b) the status file's `state` at "ready-for-review"
#                           or "done-no-pr" (NOT "blocked" — a blocked worker
#                           is idle awaiting a decision but may still resume,
#                           so it's still a normal compact candidate); (c) the
#                           pane itself showing worker-listener.sh's
#                           print_completion_block output (the "TASK
#                           COMPLETE"/"TASK FAILED" banner) — the only signal
#                           available during the roughly one-minute window
#                           before (a) or (b) land. A compacted-then-reaped
#                           worker gains nothing from compaction: it just
#                           burns a ~150k-token summarization pass and risks
#                           the post-compact nudge waking an already-finished
#                           worker for a pointless turn. Signals (a) and (b)
#                           are themselves guarded on `.swarm/tasks/
#                           processing/` being empty — old done/status files
#                           never get cleaned up, so a worktree reused via
#                           requeue.sh would otherwise read as permanently
#                           task_done from its first-ever completed task
#                           onward, silently disabling this feature for
#                           every later follow-up. See worker_task_done's
#                           own header comment for the full reasoning.
#                           NOTE: because worker_has_open_pr's "pr" field is
#                           only ever non-null together with state=
#                           "ready-for-review" (see the schema in
#                           worker.md), this done-guard fires for
#                           essentially the SAME condition
#                           WORKER_COMPACT_WRAPUP_THRESHOLD_TOKENS below was
#                           written to raise the bar for, and fires first
#                           (skip, not "raise the threshold to 300k") — so
#                           in practice a worker with an open PR is no
#                           longer compacted via the wrap-up path at all —
#                           worker_task_done's status check and
#                           worker_has_open_pr key off the same "pr" field,
#                           so WORKER_COMPACT_WRAPUP_THRESHOLD_TOKENS is now
#                           effectively unreachable code in normal
#                           operation. That's an intentional consequence of
#                           the corpus evidence motivating #252 (zero of the
#                           20 completed compactions in the analyzed logs
#                           were confirmed effective — raising the
#                           threshold was never actually buying anything),
#                           not an oversight, and left in place rather than
#                           deleted since it's still a well-defined,
#                           independently-tested fallback if a future change
#                           narrows worker_task_done's status check (e.g.
#                           back to done-no-pr only).
#   WORKER_COMPACT_PCT=75
#   WORKER_COMPACT_THRESHOLD_CAP_TOKENS=250000
#                           (issue #259, follow-up to #252) The fixed
#                           WORKER_COMPACT_THRESHOLD_TOKENS below ignores the
#                           worker model's own context window — on a 1M-
#                           context worker (Sonnet 5's statusline reads
#                           "ctx: 259k/1M (26%)") the 150k default triggered
#                           a compact at just 15% capacity: pure waste, since
#                           compaction is lossy and costs a summarization
#                           pass plus re-reading turns. worker_pane_ctx_window()
#                           parses the SAME statusline text worker_pane_ctx_
#                           used() already reads ("ctx: <used>/<window>
#                           (<pct>%)") for its denominator, and
#                           worker_compact_effective_threshold() computes the
#                           actual trigger as min(WORKER_COMPACT_PCT% of that
#                           window, WORKER_COMPACT_THRESHOLD_CAP_TOKENS) —
#                           falling back to the flat WORKER_COMPACT_THRESHOLD_
#                           TOKENS below when the denominator can't be parsed
#                           (statusline not installed/rendered yet, or the "?"
#                           JSON-schema-mismatch fallback). Defaults yield
#                           150000 on a 200k-window worker (today's behavior,
#                           unchanged) and 250000 on a 1M-window worker. The
#                           250k cap (not a bare 75% = 750k) is deliberate:
#                           long-context quality research reviewed 2026-08-10
#                           (Chroma "context rot", NoLiMa, Fiction.LiveBench,
#                           LOCA-bench, MRCR-v2 on 2026 frontier models) shows
#                           effective capacity for the best models is roughly
#                           50-65% of nominal, with measurable degradation
#                           cliffs by ~512k and agent-task degradation
#                           starting earlier — 250k keeps workers in the
#                           high-quality zone while roughly halving compaction
#                           frequency vs. 150k on 1M models. This is a quality
#                           decision, not a pricing one (Anthropic bills the
#                           full window at standard per-token rates on
#                           ≥4.6-era models — no >200k premium tier).
#   WORKER_COMPACT_THRESHOLD_TOKENS=150000
#                           Used-token threshold that triggers the above for
#                           a worker with no PR open yet (still mid-task —
#                           plenty of work likely remains, so compact now
#                           rather than let it degrade further). Also the
#                           fallback used verbatim when the window denominator
#                           can't be parsed — see WORKER_COMPACT_PCT above.
#   WORKER_COMPACT_WRAPUP_THRESHOLD_TOKENS=300000
#                           Raised threshold used instead of the above once
#                           the worker's worktree has an open PR (per its
#                           `.swarm/tasks/status/<task_id>.json`, the same
#                           file worker-listener.sh's completion block reads
#                           — see worker.md's status-file convention). A
#                           worker that's already at PR-open, wrap-up phase
#                           may be about to land; compacting a worker that's
#                           only slightly over the lower threshold and about
#                           to finish just costs a needless pause. The gap
#                           between the two thresholds is deliberate
#                           hysteresis — it takes real, sustained context
#                           growth after PR-open to trigger a compact, so
#                           this can't flap back and forth as the PR-open
#                           signal itself doesn't change turn to turn. That
#                           gap (WORKER_COMPACT_WRAPUP_THRESHOLD_TOKENS minus
#                           WORKER_COMPACT_THRESHOLD_TOKENS, 150000 by
#                           default) is preserved verbatim on top of the
#                           scaled base threshold above — e.g. a 1M-window
#                           worker's effective wrap-up threshold is 250000 +
#                           150000 = 400000, not the fixed 300000 that would
#                           otherwise leave only 50000 of headroom above the
#                           scaled 250000 base.
#   WORKER_COMPACT_BUSY_PATTERN
#                           Same purpose and default as AUTO_COMPACT_BUSY_PATTERN,
#                           applied per iss-* window instead of the
#                           coordinator window — see that entry above.
#   WORKER_COMPACT_START_TIMEOUT_SECS=15
#   WORKER_COMPACT_FINISH_TIMEOUT_SECS=300
#   WORKER_COMPACT_VERIFY_TIMEOUT_SECS=30
#   WORKER_COMPACT_POLL_SECS=2
#                           Same purpose as their AUTO_COMPACT_* counterparts,
#                           applied per worker window.
#   WORKER_COMPACT_SCAN_SECS=30
#                           How often worker_compact_pass() sweeps every
#                           iss-* window, from its own dedicated background
#                           loop (run_worker_compact_loop). Deliberately
#                           coarser than the 2s status-file poll — each
#                           sweep is one capture-pane per live worker, and
#                           injecting /compact is a rare event gated by the
#                           threshold, not something that benefits from 2s
#                           responsiveness the way status_poll_pass's
#                           done-detection does.
#   WORKER_COMPACT_NUDGE_PROMPT=Continue your task from where you left off.
#                           Text submitted (as a real turn, same paste-buffer
#                           +Enter mechanism as /compact itself) right after
#                           a worker's compaction finishes — /compact alone
#                           leaves the agent sitting idle with a summarized
#                           context; without a nudge it would just wait at
#                           the prompt indefinitely instead of resuming work.
#   WORKER_COMPACT_BACKOFF_SECS=600  (issue #252) Runtime-log analysis found
#                           one worker taking ~10 injections over ~30 minutes
#                           while its context climbed 161k -> 275k — every
#                           single attempt logged worker.compact.timeout or
#                           worker.compact.ineffective, meaning the injected
#                           text was never actually being recognized as a
#                           slash command by that pane. Each swallowed
#                           injection can cost a full worker turn at 160k+
#                           context, far more expensive than the problem
#                           compaction was meant to solve. After a
#                           maybe_worker_compact attempt for a window ends in
#                           `timeout` (either phase) or `ineffective` — see
#                           worker_compact_record_failure() — that window is
#                           skipped (worker.compact.skip reason=backoff,
#                           logged every sweep it would otherwise have
#                           fired, same as coord.compact.skip reason=cooldown
#                           above) until this many seconds have passed since
#                           the failure. A verify_skip verdict (inconclusive
#                           — the pane's ctx reading just never refreshed in
#                           time) does NOT count as a failure and starts no
#                           backoff; only a definite timeout or a confirmed-
#                           unchanged ctx reading does. A later attempt that
#                           actually succeeds (worker_compact_record_success)
#                           clears the backoff and the consecutive-failure
#                           count below immediately.
#   WORKER_COMPACT_MAX_FAILURES=3  (issue #252) After this many CONSECUTIVE
#                           timeout/ineffective verdicts for the same window
#                           (the backoff above resets between attempts but
#                           the failure count doesn't, until a success does),
#                           maybe_worker_compact gives up on that window
#                           entirely: logs one worker.compact.giving_up
#                           warning and, from then on, returns silently
#                           without even attempting the backoff-cooldown
#                           check — no repeated warnings every sweep. Both
#                           the backoff timestamp and the failure count are
#                           in-memory associative arrays (WORKER_COMPACT_
#                           LAST_FAIL / WORKER_COMPACT_FAIL_COUNT /
#                           WORKER_COMPACT_GAVE_UP), not files — scoped to
#                           run_worker_compact_loop's own dedicated
#                           background process, same as LAST_AUTO_COMPACT_
#                           POLL_TRIGGER and ORPHAN_PR_LOGGED elsewhere in
#                           this file — so a watcher restart clears them and
#                           gives every window a fresh start.
#
# Watch backend (auto-detected):
#   - inotifywait (preferred): instant response. Install with:
#       sudo apt install inotify-tools
#     and bump inotify watches if you watch large repos:
#       sudo sysctl fs.inotify.max_user_watches=524288
#   - polling find (fallback): ~2s latency. No dependencies.

set -euo pipefail

# --- Help / usage ---
case "${1:-}" in
    -h|--help)
        cat <<EOF
coordinator-watch.sh — Wake the coordinator on worker-finished events

USAGE
    coordinator-watch.sh [project-dir]

ARGUMENTS
    project-dir     Path to project root (default: \$PWD)

DESCRIPTION
    Long-running daemon. Watches every worker's .swarm/tasks/done/ dir
    under the workspace (parent of project-dir). When a new outcome JSON
    appears, wakes the coordinator via llm-start.sh so it can triage,
    re-dispatch, and top up workers.

CONFIG  (precedence: shell env > <project>/.swarm/.env > <sandbox>/.env.example)
    DEBOUNCE_SECS       30        coalesce window for repeat events
    POLL_SECS           2         poll-mode latency (when inotify absent)
    DRY_RUN             0         log triggers, don't invoke llm-start.sh
    ONCE                0         exit after first wake (smoke-test)
    LLM_START           (auto)    override path to llm-start.sh
    WAKE_PROMPT         (top-up)  what the coordinator does on wake
    POST_OUTCOMES       0         run sweep-swarm-outcomes.sh per outcome
    OUTCOME_HOOK        (none)    path to per-outcome poster
    SWEEP               (auto)    override sweep-swarm-outcomes.sh path
    WATCHER_AUTOCLOSE   1         reap eligible workers (window+worktree+branch) before wake; see WATCHER_AUTOCLOSE_MODE
    WATCHER_AUTOCLOSE_MODE merged which terminal PR states are reap-eligible: merged (MERGED only, default) | finalized (MERGED or CLOSED)
    WATCH_PR_POLL_SECS  60        periodic gh-poll backstop reap (0=off); see header comment
    WATCH_ORPHAN_SWEEP_SECS 3600  periodic reap-orphan-worktrees.sh sweep for window-less worktrees (0=off); see header comment
    WATCH_CHECK_ON_DONE 1         run acceptance check when a worker signals done; see header comment
    SESSION_NAME        (auto)    tmux session for chk-N windows (llm-<project-basename>)
    WORKSPACE           (auto)    parent dir for wt-issue-* worktrees
    MAX_WORKERS         5         (referenced by default WAKE_PROMPT)
    MAX_TMUX_WINDOWS    10        (referenced by default WAKE_PROMPT)
    WATCHER_QUIET       0         suppress human-readable pane echo (banner only); see PANE ECHO
    AUTO_COMPACT        1         inject real /compact into a long-lived coordinator before waking it if over threshold; see header comment
    AUTO_COMPACT_THRESHOLD_TOKENS     150000  used-token trigger
    AUTO_COMPACT_TICK_SECS            60      periodic poll-tick trigger interval (0=off); catches long interactive stretches with no worker completions; see header comment
    AUTO_COMPACT_COOLDOWN_SECS        900     poll-tick-only cooldown after an attempted compact, before it may re-trigger
    AUTO_COMPACT_PROBE                (auto)  statusline probe file path
    AUTO_COMPACT_PROBE_MAX_AGE_SECS   120     probe staleness cutoff
    AUTO_COMPACT_BUSY_PATTERN         (auto)  capture-pane busy-indicator regex
    AUTO_COMPACT_START_TIMEOUT_SECS   15      max wait for compaction to start
    AUTO_COMPACT_FINISH_TIMEOUT_SECS  300     max wait for compaction to finish
    AUTO_COMPACT_VERIFY_TIMEOUT_SECS  30      max wait for probe to refresh post-compact
    AUTO_COMPACT_POLL_SECS            2       capture-pane/probe poll interval
    WORKER_AUTO_COMPACT               1       same idea as AUTO_COMPACT, generalized to iss-* worker windows; see header comment
    WORKER_COMPACT_PCT                       75      percent of the worker's own context window used as the effective threshold; see header comment
    WORKER_COMPACT_THRESHOLD_CAP_TOKENS      250000  cap on the above (250k on a 1M-window worker, not 750k)
    WORKER_COMPACT_THRESHOLD_TOKENS         150000  used-token trigger (no PR open yet); also the fallback when the window can't be parsed
    WORKER_COMPACT_WRAPUP_THRESHOLD_TOKENS  300000  raised trigger once the worker's PR is open (scales with the base threshold; see header comment)
    WORKER_COMPACT_BUSY_PATTERN             (auto)  capture-pane busy-indicator regex (per iss-* window)
    WORKER_COMPACT_START_TIMEOUT_SECS       15      max wait for compaction to start
    WORKER_COMPACT_FINISH_TIMEOUT_SECS      300     max wait for compaction to finish
    WORKER_COMPACT_VERIFY_TIMEOUT_SECS      30      max wait for the pane's ctx reading to refresh post-compact
    WORKER_COMPACT_POLL_SECS                2       capture-pane poll interval
    WORKER_COMPACT_SCAN_SECS                30      how often its own loop sweeps all iss-* windows
    WORKER_COMPACT_NUDGE_PROMPT       (see header)  text sent to resume the worker after compaction
    WORKER_COMPACT_BACKOFF_SECS             600     cooldown for a window after a timeout/ineffective verdict
    WORKER_COMPACT_MAX_FAILURES             3       consecutive failures before giving up on a window entirely

DEFAULT WAKE_PROMPT (top-up mode)
    Coordinator triages outcomes, then refills workers toward MAX_WORKERS
    (capped by MAX_TMUX_WINDOWS) using the @me-or-unassigned filter.
    Set WAKE_PROMPT explicitly to revert to triage-only behavior.

EVENTS LOG
    Appends to <project>/.swarm/events.log:
      watch.start          boot banner with backend + caps
      worker.finish        outcome JSON detected (issue, ok|err) — fired only
                           for worktrees registered with this PROJECT_DIR
      worker.finish.skip   outcome JSON detected for a foreign worktree
                           (sibling repo sharing the same WORKSPACE parent)
      coord.wake           llm-start.sh invoked (or coord.wake.skip on debounce)
      sweep.run            sweep-swarm-outcomes.sh fired (when POST_OUTCOMES=1)
      watch.autoclose      kill-finished-workers.sh reaped ≥1 window (trigger=outcome|pr_poll,
                           killed=N); passes that reap nothing are not logged
      reap.window          per-target kill record written by kill-finished-workers.sh
                           (issue, window, branch, reasons, capture=<pane snapshot path>)
      watch.timer.start    a background timer loop started — pr-poll/check-on-done
                           timer loop, and/or (issue #226) the separate
                           worker-compact loop; up to two lines, one per loop
      watch.pr_poll        terminal PR detected via periodic gh poll (reap backstop);
                           reason=stale_pr_ignored when the terminal PR
                           predates the worktree (issue #185 — recycled
                           branch name, not evidence about this worktree);
                           reason=orphan_no_window when the worktree has no
                           live iss-N tmux window for kill-finished-workers.sh
                           to reap (issue #225 — logged once per issue, left
                           to watch.orphan_sweep instead)
      watch.orphan_sweep   reap-orphan-worktrees.sh --pr-finalized sweep ran
                           (issue #225 — reaped=N); passes that reap nothing
                           are not logged (dry runs always are)
      watch.check_on_done  check-on-done result (issue, task_id, result=running|pass|fail|skipped)
      cap.refused          provision-worker.sh hit MAX_WORKERS / MAX_TMUX_WINDOWS
      coord.compact        /compact injected before wake (used, threshold, trigger=poll|wake)
      coord.compact.skip   auto-compact skipped this cycle (reason=pane_busy|no_fresh_probe|cooldown|...,
                           trigger=poll|wake — reason=cooldown only ever fires trigger=poll)
      coord.compact.timeout  gave up waiting on the busy indicator (phase=start|finish, waited, trigger=poll|wake)
      coord.compact.done   busy indicator cleared — compaction confirmed finished (waited, trigger=poll|wake)
      coord.compact.ineffective  context didn't drop post-compact (before, after, trigger=poll|wake) — investigate
      coord.compact.verify_skip  probe never refreshed post-compact — inconclusive, not a failure (trigger=poll|wake)
      worker.compact        /compact injected into an iss-* window (issue, used, threshold, wrapup)
      worker.compact.skip   worker auto-compact skipped this window this cycle (issue,
                           reason=pane_busy|no_ctx_parsed|task_done|backoff|...; reason=task_done
                           means the window's current task already finished — see worker_task_done()
                           — reason=backoff means a prior timeout/ineffective is still cooling down,
                           logged every sweep it would otherwise have fired, same as
                           coord.compact.skip reason=cooldown)
      worker.compact.timeout  gave up waiting on the worker's busy indicator (issue, phase=start|finish, waited)
      worker.compact.done   worker busy indicator cleared — compaction confirmed finished (issue, waited)
      worker.compact.ineffective  worker context didn't drop post-compact (issue, before, after) — investigate
      worker.compact.verify_skip  worker's ctx reading never refreshed post-compact — inconclusive, not a failure
      worker.compact.giving_up  (issue #252) N consecutive timeout/ineffective verdicts for this
                           window (issue, failures=N) — maybe_worker_compact stops attempting
                           /compact for it until the watcher restarts; logged once, not every sweep

PANE ECHO (issue #38)
    By default, every line appended to events.log — by this process OR any
    sibling script sharing the same file (provision-worker.sh's
    worker.start/cap.refused, worker-listener.sh's worker.requeue) — is
    echoed to stdout as a colorized, glyph-prefixed one-liner, so the
    watcher's tmux window becomes a live status feed instead of sitting
    empty behind the startup banner. events.log itself is untouched — this
    is a stdout-only presentation layer. Set WATCHER_QUIET=1 to disable and
    restore silent-stdout (banner only).

BACKEND
    Auto-detects inotifywait (instant) or falls back to polling find
    (POLL_SECS latency). Install inotify-tools for instant wakes.

EXAMPLES
    coordinator-watch.sh                                # watch \$PWD
    DRY_RUN=1 coordinator-watch.sh                      # log only, no wakes
    POST_OUTCOMES=1 OUTCOME_HOOK=/path coordinator-watch.sh   # + auditing
EOF
        exit 0
        ;;
esac

PROJECT_DIR="$(realpath "${1:-$PWD}")"
# Self-locate so defaults follow the script wherever it lives. LLM_START and
# SWEEP env overrides still win for non-standard installs.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLM_SWARM_DIR="${LLM_SWARM_DIR:-$(dirname "$SCRIPT_DIR")}"

# Apply <project>/.swarm/.env then sandbox .env.example before reading
# tunables, so caller env > project file > sandbox defaults. This script
# is normally inheriting from the tmux session env (set up by llm-start.sh),
# but the explicit load lets us run it standalone too. The sourced file
# also defines swarm_worktree_parent() which we use below to derive the
# scan directory in a way that honors SWARM_WORKTREE_GROUPING.
# shellcheck source=_load-env.sh
. "$SCRIPT_DIR/_load-env.sh" "$PROJECT_DIR"

# Worker worktrees live at $(swarm_worktree_parent)/wt-issue-N — that's
# either <parent>/wt-issue-N (flat grouping, default) or
# <parent>/<project>-worktrees/wt-issue-N (project grouping; multi-swarm
# hosts). Calling the helper avoids drifting from provision-worker.sh.
# Override with WORKSPACE=<dir> for non-standard layouts.
WORKSPACE="$(realpath "${WORKSPACE:-$(swarm_worktree_parent "$PROJECT_DIR")}")"

DEBOUNCE_SECS="${DEBOUNCE_SECS:-30}"
DRY_RUN="${DRY_RUN:-0}"
ONCE="${ONCE:-0}"
LLM_START="${LLM_START:-$LLM_SWARM_DIR/llm-start.sh}"
# Default wake prompt: top-up mode. The coordinator triages, then refills
# alive worker count toward MAX_WORKERS (subject to MAX_TMUX_WINDOWS) using
# the AVAILABLE filter defined in prompts/coordinator.md. To suppress
# auto-provisioning (old conservative default), set WAKE_PROMPT explicitly
# or invoke with INCLUDE_ASSIGNED_TO_OTHERS / triage-only language.
WAKE_PROMPT="${WAKE_PROMPT:-Worker(s) just finished. Triage their outcome JSONs in worktrees/.swarm/tasks/done/, then top up workers per the Initial Startup Checklist (compute AVAILABLE, count alive workers, fill open slots up to MAX_WORKERS subject to MAX_TMUX_WINDOWS). Use the @me-or-unassigned filter unless INCLUDE_ASSIGNED_TO_OTHERS=1.}"
POLL_SECS="${POLL_SECS:-2}"
POST_OUTCOMES="${POST_OUTCOMES:-0}"
SWEEP="${SWEEP:-$LLM_SWARM_DIR/scripts/sweep-swarm-outcomes.sh}"
WATCHER_AUTOCLOSE="${WATCHER_AUTOCLOSE:-1}"
# issue #237 — which terminal PR states are reap-eligible for WATCHER_AUTOCLOSE;
# see header comment. Validated below alongside the other enumerated/numeric knobs.
WATCHER_AUTOCLOSE_MODE="${WATCHER_AUTOCLOSE_MODE:-merged}"
KILL_FINISHED="${KILL_FINISHED:-$LLM_SWARM_DIR/scripts/kill-finished-workers.sh}"
WATCH_PR_POLL_SECS="${WATCH_PR_POLL_SECS:-60}"
WATCH_ORPHAN_SWEEP_SECS="${WATCH_ORPHAN_SWEEP_SECS:-3600}"
REAP_ORPHAN="${REAP_ORPHAN:-$LLM_SWARM_DIR/scripts/reap-orphan-worktrees.sh}"
WATCH_CHECK_ON_DONE="${WATCH_CHECK_ON_DONE:-1}"
CHECK_RUNNER="${CHECK_RUNNER:-}"
SESSION_NAME="${SESSION_NAME:-llm-$(basename "$PROJECT_DIR")}"
WATCHER_QUIET="${WATCHER_QUIET:-0}"
AUTO_COMPACT="${AUTO_COMPACT:-1}"
AUTO_COMPACT_THRESHOLD_TOKENS="${AUTO_COMPACT_THRESHOLD_TOKENS:-150000}"
# issue #210 — periodic poll-tick trigger (see header comment). Independent
# interval and cooldown from WATCH_PR_POLL_SECS/its gate, on purpose.
AUTO_COMPACT_TICK_SECS="${AUTO_COMPACT_TICK_SECS:-60}"
AUTO_COMPACT_COOLDOWN_SECS="${AUTO_COMPACT_COOLDOWN_SECS:-900}"
# Matches coordinator-claude.sh's own STATUSLINE_PROBE default for its
# claude invocation — a project+role-scoped path, NOT the statusline
# script's generic per-UID default. Using the generic default here would
# mean any other interactive `claude` session on the same host (sharing
# the same UID) silently clobbers the coordinator's probe data, and this
# feature would act on the wrong session's context usage. This feature
# has no context data source other than that probe file, so if the
# statusline isn't installed at all, it's simply a no-op (see
# probe_ctx_used's staleness/missing-file handling below).
AUTO_COMPACT_PROBE="${AUTO_COMPACT_PROBE:-${STATUSLINE_PROBE:-${XDG_RUNTIME_DIR:-/tmp}/claude-statusline-$(basename "$PROJECT_DIR")-coordinator.json}}"
AUTO_COMPACT_PROBE_MAX_AGE_SECS="${AUTO_COMPACT_PROBE_MAX_AGE_SECS:-120}"
# issue #252: anchored on the "(esc to interrupt)" hint that accompanies the
# spinner line for the full duration of any in-flight turn or compaction,
# regardless of which present-tense verb Claude Code renders that cycle —
# see this file's AUTO_COMPACT_BUSY_PATTERN header comment for why this
# replaced the old spinner-verb list. Plus the Ctrl-C exit-confirm prompt (a
# bare Enter into that state would confirm an unintended exit rather than
# compact).
AUTO_COMPACT_BUSY_PATTERN="${AUTO_COMPACT_BUSY_PATTERN:-\(esc to interrupt\)|Press Ctrl-C again to .xit}"
AUTO_COMPACT_START_TIMEOUT_SECS="${AUTO_COMPACT_START_TIMEOUT_SECS:-15}"
AUTO_COMPACT_FINISH_TIMEOUT_SECS="${AUTO_COMPACT_FINISH_TIMEOUT_SECS:-300}"
AUTO_COMPACT_VERIFY_TIMEOUT_SECS="${AUTO_COMPACT_VERIFY_TIMEOUT_SECS:-30}"
AUTO_COMPACT_POLL_SECS="${AUTO_COMPACT_POLL_SECS:-2}"
# issue #226 — worker-side generalization of the above. No probe/staleness
# knobs here: worker context comes from parsing the rendered statusline
# straight out of capture-pane (see worker_pane_ctx_used()), not a probe
# file, so there's nothing to go stale.
WORKER_AUTO_COMPACT="${WORKER_AUTO_COMPACT:-1}"
# issue #259 — scale the effective threshold to the worker model's own
# context window (min(WORKER_COMPACT_PCT% of window, ..._CAP_TOKENS)); see
# worker_compact_effective_threshold() and this file's WORKER_AUTO_COMPACT
# header comment for the full rationale and the wrap-up gap-preservation math.
WORKER_COMPACT_PCT="${WORKER_COMPACT_PCT:-75}"
WORKER_COMPACT_THRESHOLD_CAP_TOKENS="${WORKER_COMPACT_THRESHOLD_CAP_TOKENS:-250000}"
WORKER_COMPACT_THRESHOLD_TOKENS="${WORKER_COMPACT_THRESHOLD_TOKENS:-150000}"
WORKER_COMPACT_WRAPUP_THRESHOLD_TOKENS="${WORKER_COMPACT_WRAPUP_THRESHOLD_TOKENS:-300000}"
# issue #252: same anchor as AUTO_COMPACT_BUSY_PATTERN above — keep in sync.
WORKER_COMPACT_BUSY_PATTERN="${WORKER_COMPACT_BUSY_PATTERN:-\(esc to interrupt\)|Press Ctrl-C again to .xit}"
WORKER_COMPACT_START_TIMEOUT_SECS="${WORKER_COMPACT_START_TIMEOUT_SECS:-15}"
WORKER_COMPACT_FINISH_TIMEOUT_SECS="${WORKER_COMPACT_FINISH_TIMEOUT_SECS:-300}"
WORKER_COMPACT_VERIFY_TIMEOUT_SECS="${WORKER_COMPACT_VERIFY_TIMEOUT_SECS:-30}"
WORKER_COMPACT_POLL_SECS="${WORKER_COMPACT_POLL_SECS:-2}"
WORKER_COMPACT_SCAN_SECS="${WORKER_COMPACT_SCAN_SECS:-30}"
WORKER_COMPACT_NUDGE_PROMPT="${WORKER_COMPACT_NUDGE_PROMPT:-Continue your task from where you left off.}"
# issue #252 — per-window backoff after a failed (timeout/ineffective)
# injection attempt; see this file's WORKER_AUTO_COMPACT header comment.
WORKER_COMPACT_BACKOFF_SECS="${WORKER_COMPACT_BACKOFF_SECS:-600}"
WORKER_COMPACT_MAX_FAILURES="${WORKER_COMPACT_MAX_FAILURES:-3}"

case "$WATCHER_AUTOCLOSE_MODE" in
    merged)    AUTOCLOSE_PR_FLAG="--merged-only" ;;
    finalized) AUTOCLOSE_PR_FLAG="--pr-finalized" ;;
    *)
        echo "ERROR: WATCHER_AUTOCLOSE_MODE must be 'merged' or 'finalized' (got: $WATCHER_AUTOCLOSE_MODE)" >&2
        exit 1
        ;;
esac
if ! [[ "$WATCH_PR_POLL_SECS" =~ ^[0-9]+$ ]]; then
    echo "ERROR: WATCH_PR_POLL_SECS must be a non-negative integer (got: $WATCH_PR_POLL_SECS)" >&2
    exit 1
fi
if ! [[ "$WATCH_ORPHAN_SWEEP_SECS" =~ ^[0-9]+$ ]]; then
    echo "ERROR: WATCH_ORPHAN_SWEEP_SECS must be a non-negative integer (got: $WATCH_ORPHAN_SWEEP_SECS)" >&2
    exit 1
fi
for _var in AUTO_COMPACT_THRESHOLD_TOKENS AUTO_COMPACT_PROBE_MAX_AGE_SECS \
            AUTO_COMPACT_START_TIMEOUT_SECS AUTO_COMPACT_FINISH_TIMEOUT_SECS \
            AUTO_COMPACT_VERIFY_TIMEOUT_SECS AUTO_COMPACT_TICK_SECS AUTO_COMPACT_COOLDOWN_SECS \
            WORKER_COMPACT_PCT WORKER_COMPACT_THRESHOLD_CAP_TOKENS \
            WORKER_COMPACT_THRESHOLD_TOKENS WORKER_COMPACT_WRAPUP_THRESHOLD_TOKENS \
            WORKER_COMPACT_START_TIMEOUT_SECS WORKER_COMPACT_FINISH_TIMEOUT_SECS \
            WORKER_COMPACT_VERIFY_TIMEOUT_SECS WORKER_COMPACT_SCAN_SECS \
            WORKER_COMPACT_BACKOFF_SECS WORKER_COMPACT_MAX_FAILURES; do
    if ! [[ "${!_var}" =~ ^[0-9]+$ ]]; then
        echo "ERROR: $_var must be a non-negative integer (got: ${!_var})" >&2
        exit 1
    fi
done
if ! [[ "$AUTO_COMPACT_POLL_SECS" =~ ^[0-9]+$ ]] || [ "$AUTO_COMPACT_POLL_SECS" -lt 1 ]; then
    echo "ERROR: AUTO_COMPACT_POLL_SECS must be a positive integer (got: $AUTO_COMPACT_POLL_SECS)" >&2
    exit 1
fi
if ! [[ "$WORKER_COMPACT_POLL_SECS" =~ ^[0-9]+$ ]] || [ "$WORKER_COMPACT_POLL_SECS" -lt 1 ]; then
    echo "ERROR: WORKER_COMPACT_POLL_SECS must be a positive integer (got: $WORKER_COMPACT_POLL_SECS)" >&2
    exit 1
fi
unset _var

# jq is optional throughout this codebase (see worker-listener.sh's
# append_eval_log). status_poll_pass/maybe_run_check parse status-file JSON
# with it; under `set -e`, an unguarded `var=$(jq ...)` with jq missing
# would silently kill the background timer loop's subshell. Guard instead
# of hard-requiring it — the PR-open backstop degrades gracefully to a
# synthetic per-issue claim key, and the status-file fast path just no-ops.
HAVE_JQ=0
command -v jq >/dev/null 2>&1 && HAVE_JQ=1

# Append-only structured event log. Every observable event (start, outcome,
# wake, sweep, cap-refusal) gets a single line so `tail -F` gives live status.
EVENTS_LOG="$PROJECT_DIR/.swarm/events.log"
mkdir -p "$(dirname "$EVENTS_LOG")" 2>/dev/null || true

# issue #210: maybe_auto_compact is now reachable from two separate OS
# processes (the wake path in the main watcher process, and the poll-tick
# path in run_auto_compact_poll_loop's own background process) — this lock
# serializes them. See maybe_auto_compact's header comment for why.
AUTO_COMPACT_LOCK="$PROJECT_DIR/.swarm/coord-compact.lock"

# log_event <category> <key=val>...
# Writes one line: "<utc-iso8601>  <category>  k=v k=v ..."
# Failures are non-fatal — log writes never break watcher work.
log_event() {
    local cat="$1"; shift
    local ts
    ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    printf '%s  %-15s %s\n' "$ts" "$cat" "$*" >> "$EVENTS_LOG" 2>/dev/null || true
}

# format_event_line <raw-events.log-line>
#
# Presentation layer for the pane echo (issue #38): parses one
# log_event-formatted line ("<iso8601-ts>  <category>  k=v k=v ...") and
# prints a colorized, column-aligned human line to stdout. Read-only w.r.t.
# the log file — never writes back to it, so events.log's format is
# untouched by this feature.
format_event_line() {
    local line="$1" ts cat kv hhmmss glyph color
    read -r ts cat kv <<< "$line"
    [ -n "$cat" ] || return 0
    hhmmss="$(date -d "$ts" +%T 2>/dev/null || echo "$ts")"

    case "$cat" in
        worker.finish)
            case "$kv" in
                *outcome=ok*)  glyph="✓"; color=$'\033[32m' ;;
                *)             glyph="✗"; color=$'\033[31m' ;;
            esac ;;
        worker.finish.skip)        glyph="·"; color=$'\033[2m'  ;;
        worker.start)               glyph="◐"; color=$'\033[33m' ;;
        worker.requeue)              glyph="↺"; color=$'\033[36m' ;;
        cap.refused)                  glyph="⚠"; color=$'\033[33m' ;;
        coord.wake)                   glyph="→"; color=$'\033[36m' ;;
        coord.wake.skip)              glyph="⏸"; color=$'\033[33m' ;;
        coord.wake.error)             glyph="✗"; color=$'\033[31m' ;;
        coord.compact)                 glyph="◈"; color=$'\033[36m' ;;
        coord.compact.skip)             glyph="·"; color=$'\033[2m'  ;;
        coord.compact.timeout)           glyph="⚠"; color=$'\033[33m' ;;
        coord.compact.done)               glyph="◈"; color=$'\033[32m' ;;
        coord.compact.ineffective)          glyph="⚠"; color=$'\033[31m' ;;
        coord.compact.verify_skip)            glyph="·"; color=$'\033[2m'  ;;
        worker.compact)                 glyph="◈"; color=$'\033[36m' ;;
        worker.compact.skip)             glyph="·"; color=$'\033[2m'  ;;
        worker.compact.timeout)           glyph="⚠"; color=$'\033[33m' ;;
        worker.compact.done)               glyph="◈"; color=$'\033[32m' ;;
        worker.compact.ineffective)          glyph="⚠"; color=$'\033[31m' ;;
        worker.compact.verify_skip)            glyph="·"; color=$'\033[2m'  ;;
        worker.compact.giving_up)                glyph="⚠"; color=$'\033[31m' ;;
        watch.autoclose)               glyph="♻"; color=$'\033[36m' ;;
        watch.orphan_sweep)             glyph="♻"; color=$'\033[36m' ;;
        reap.window)                    glyph="✂"; color=$'\033[36m' ;;
        watch.pr_poll)                  glyph="⚠"; color=$'\033[33m' ;;
        pr_poll.error)                   glyph="✗"; color=$'\033[31m' ;;
        watch.check_on_done)
            case "$kv" in
                *result=pass*)     glyph="✓"; color=$'\033[32m' ;;
                *result=fail*)     glyph="✗"; color=$'\033[31m' ;;
                *result=running*)  glyph="◐"; color=$'\033[33m' ;;
                *)                 glyph="·"; color=$'\033[2m'  ;;
            esac ;;
        watch.check_on_done.error)  glyph="✗"; color=$'\033[31m' ;;
        watch.start|watch.timer.start) glyph="▶"; color=$'\033[36m' ;;
        watch.exit)                     glyph="■"; color=$'\033[2m'  ;;
        sweep.run|sweep.dry)             glyph="↻"; color=$'\033[36m' ;;
        sweep.error)                      glyph="✗"; color=$'\033[31m' ;;
        *)                                 glyph="·"; color=$'\033[0m'  ;;
    esac

    printf '[watch] %s  %s%s\033[0m %-22s %s\n' "$hhmmss" "$color" "$glyph" "$cat" "$kv"
}

# Validation
[ -d "$PROJECT_DIR" ] || { echo "ERROR: not a directory: $PROJECT_DIR" >&2; exit 1; }
[ -d "$WORKSPACE" ]   || { echo "ERROR: workspace not a directory: $WORKSPACE" >&2; exit 1; }
[ -x "$LLM_START" ]   || { echo "ERROR: llm-start.sh not executable: $LLM_START" >&2; exit 1; }
if [ "$POST_OUTCOMES" = "1" ]; then
    [ -x "$SWEEP" ] || { echo "ERROR: sweep script not executable: $SWEEP" >&2; exit 1; }
fi
if [ "$WATCHER_AUTOCLOSE" = "1" ] && [ ! -x "$KILL_FINISHED" ]; then
    echo "WARN: WATCHER_AUTOCLOSE=1 but kill-finished-workers.sh not executable: $KILL_FINISHED" >&2
    echo "      Disabling autoclose; set WATCHER_AUTOCLOSE=0 to silence this." >&2
    WATCHER_AUTOCLOSE=0
fi
if [ "$WATCH_ORPHAN_SWEEP_SECS" -gt 0 ] && [ ! -x "$REAP_ORPHAN" ]; then
    echo "WARN: WATCH_ORPHAN_SWEEP_SECS>0 but reap-orphan-worktrees.sh not executable: $REAP_ORPHAN" >&2
    echo "      Disabling orphan sweep; set WATCH_ORPHAN_SWEEP_SECS=0 to silence this." >&2
    WATCH_ORPHAN_SWEEP_SECS=0
fi

# Pick a backend
BACKEND="poll"
if command -v inotifywait >/dev/null 2>&1; then
    BACKEND="inotify"
fi

# Banner
cat <<EOF
=== coordinator-watch.sh ===
project:       $PROJECT_DIR
workspace:     $WORKSPACE (scanning $WORKSPACE/wt-issue-*/.swarm/tasks/done/)
backend:       $BACKEND$([ "$BACKEND" = "poll" ] && echo " (install inotify-tools for instant response)")
debounce:      ${DEBOUNCE_SECS}s
poll interval: ${POLL_SECS}s$([ "$BACKEND" = "inotify" ] && echo " (unused in inotify mode)")
llm-start.sh:  $LLM_START
post-outcomes: $POST_OUTCOMES$([ "$POST_OUTCOMES" = "1" ] && echo " (sweep: $SWEEP, hook: ${OUTCOME_HOOK:-default dry-run stub})")
autoclose:     $WATCHER_AUTOCLOSE$([ "$WATCHER_AUTOCLOSE" = "1" ] && echo " (mode: $WATCHER_AUTOCLOSE_MODE [$AUTOCLOSE_PR_FLAG], script: $KILL_FINISHED)")
pr-poll:       ${WATCH_PR_POLL_SECS}s$([ "$WATCH_PR_POLL_SECS" = "0" ] && echo " (disabled)")
orphan-sweep:  ${WATCH_ORPHAN_SWEEP_SECS}s$([ "$WATCH_ORPHAN_SWEEP_SECS" = "0" ] && echo " (disabled)" || echo " (script: $REAP_ORPHAN)")
check-on-done: $WATCH_CHECK_ON_DONE$([ "$WATCH_CHECK_ON_DONE" = "1" ] && echo " (session: $SESSION_NAME)")
auto-compact:  $AUTO_COMPACT$([ "$AUTO_COMPACT" = "1" ] && echo " (threshold: ${AUTO_COMPACT_THRESHOLD_TOKENS} tokens, probe: $AUTO_COMPACT_PROBE, poll-tick: ${AUTO_COMPACT_TICK_SECS}s$([ "$AUTO_COMPACT_TICK_SECS" = "0" ] && echo " disabled"), cooldown: ${AUTO_COMPACT_COOLDOWN_SECS}s)")
worker-compact: $WORKER_AUTO_COMPACT$([ "$WORKER_AUTO_COMPACT" = "1" ] && echo " (threshold: min(${WORKER_COMPACT_PCT}% of window, ${WORKER_COMPACT_THRESHOLD_CAP_TOKENS})/wrapup+$(( WORKER_COMPACT_WRAPUP_THRESHOLD_TOKENS - WORKER_COMPACT_THRESHOLD_TOKENS )), fallback: ${WORKER_COMPACT_THRESHOLD_TOKENS}/${WORKER_COMPACT_WRAPUP_THRESHOLD_TOKENS} tokens, scan: ${WORKER_COMPACT_SCAN_SECS}s)")
dry-run:       $DRY_RUN
once:          $ONCE
pane-echo:     $([ "$WATCHER_QUIET" = "1" ] && echo "disabled (WATCHER_QUIET=1)" || echo "enabled (WATCHER_QUIET=1 to silence)")

EOF
[ "$BACKEND" = "poll" ] && echo "Press Ctrl-C to stop. Polling every ${POLL_SECS}s for new outcome JSONs..." || \
    echo "Press Ctrl-C to stop. Listening for create/moved_to events..."
echo ""

log_event watch.start \
    "project=$PROJECT_DIR backend=$BACKEND debounce=${DEBOUNCE_SECS}s max_workers=${MAX_WORKERS:-?} max_tmux_windows=${MAX_TMUX_WINDOWS:-?}"

# Pane echo (issue #38): tail events.log itself — rather than only echoing
# the events THIS process logs — so events written by sibling processes
# sharing the same events.log (provision-worker.sh's worker.start/
# cap.refused, worker-listener.sh's worker.requeue, etc.) also show up
# live in the watcher's tmux window. `-n 1` replays just the watch.start
# line we wrote above (guaranteeing it appears with no startup race)
# without dumping older sessions' history. WATCHER_QUIET=1 skips this
# entirely, restoring silent-stdout (banner only).
WATCHER_ECHO_PID=""
if [ "$WATCHER_QUIET" != "1" ]; then
    # --sleep-interval=0.2: only takes effect when tail falls back to
    # polling (inotify unavailable — the common case in containers/
    # sandboxes without inotify support). GNU tail's polling default is
    # 1.0s, which reads as sluggish for a "live" pane; 0.2s keeps it snappy
    # without meaningfully raising CPU use. No-op when inotify IS available
    # (events forward immediately regardless of this value).
    #
    # Feature-detected, not assumed: --sleep-interval is GNU-only. On a
    # BSD/busybox tail (no such flag), passing it unconditionally would
    # make tail exit immediately on an unrecognized option — with stderr
    # suppressed below, the whole pane-echo feature would silently vanish
    # rather than degrade to plain default-interval following.
    TAIL_OPTS=(-n 1 -F)
    tail --help 2>/dev/null | grep -q -- '--sleep-interval' && TAIL_OPTS+=(--sleep-interval=0.2)
    tail "${TAIL_OPTS[@]}" "$EVENTS_LOG" 2>/dev/null | while IFS= read -r line; do
        format_event_line "$line"
    done &
    WATCHER_ECHO_PID=$!
fi

# Single shared trap for the pane-echo pipeline, the background timer loop
# (issue #119, started later), the worker-compact loop (issue #226, its own
# separate process — see run_worker_compact_loop's header comment for why
# it isn't folded into the same loop), the coordinator poll-tick auto-compact
# loop (issue #210, same reasoning — see run_auto_compact_poll_loop's header
# comment), and run_poll's seen_file (script-global — see the NOTE at its
# mktemp near run_poll). Installed immediately after the first backgrounded
# process (WATCHER_ECHO_PID) that needs it — under `set -e`, any ordinary
# command between spawning a background job and installing its cleanup trap
# is a window where an early failure orphans that job. WATCH_TIMER_PID,
# WORKER_COMPACT_TIMER_PID, AUTO_COMPACT_POLL_TIMER_PID, and seen_file are
# pre-declared empty here too so the trap is safe to fire before any of them
# is actually assigned further down. Set once, so nothing downstream can
# silently clobber it with a second `trap ... EXIT` and drop one of these
# kills.
WATCH_TIMER_PID=""
WORKER_COMPACT_TIMER_PID=""
AUTO_COMPACT_POLL_TIMER_PID=""
seen_file=""
cleanup_on_exit() {
    [ -n "${WATCH_TIMER_PID:-}" ] && kill "$WATCH_TIMER_PID" 2>/dev/null || true
    [ -n "${WORKER_COMPACT_TIMER_PID:-}" ] && kill "$WORKER_COMPACT_TIMER_PID" 2>/dev/null || true
    [ -n "${AUTO_COMPACT_POLL_TIMER_PID:-}" ] && kill "$AUTO_COMPACT_POLL_TIMER_PID" 2>/dev/null || true
    # WATCHER_ECHO_PID is the `while read` reader — the last stage of the
    # `tail | while` pipeline, and the only PID $! gives us for it. `tail`
    # itself is a separate direct child of this script (pipeline stages
    # aren't parent/child of each other), so it needs its own kill too —
    # otherwise it lingers until its next write hits the now-closed pipe.
    [ -n "${WATCHER_ECHO_PID:-}" ] && kill "$WATCHER_ECHO_PID" 2>/dev/null || true
    # Scoped to WATCHER_ECHO_PID (only runs if the pane-echo tail was
    # actually spawned) and matched by its exact args (-f against
    # EVENTS_LOG's path), not "-x tail" — so this can't collide with some
    # unrelated tail a future change might add as another direct child of
    # this script.
    [ -n "${WATCHER_ECHO_PID:-}" ] && pkill -P $$ -f "tail .* -F .*$EVENTS_LOG" 2>/dev/null || true
    [ -n "${seen_file:-}" ] && rm -f -- "$seen_file"
}
trap cleanup_on_exit EXIT INT TERM

# Shared state
LAST_WAKE=0

# issue #225: dedups the watch.pr_poll reason=orphan_no_window log line so a
# window-less worktree with a terminal PR gets logged once, not every
# WATCH_PR_POLL_SECS tick forever. Keyed by issue number; cleared in
# pr_poll_pass once the worktree directory is gone (reaped, or never
# provisioned here) so a future worktree reusing the same issue number isn't
# permanently suppressed.
declare -A ORPHAN_PR_LOGGED=()

# is_our_worktree <outcome-path>
#
# Filter cross-talk from sibling repos that share the same WORKSPACE parent
# (e.g., /opt/work/oconeco/ holds wt-issue-* worktrees for fand-guide,
# fand-etl, fand-app, fand-poc). Without this filter, a worker finishing in
# any sibling repo wakes EVERY coordinator running under the same parent.
#
# Returns 0 (caller treats as "ours, fire") if the outcome's containing
# worktree is registered with $PROJECT_DIR's git. Returns 1 otherwise.
#
# Fail-open policy: if `git worktree list` errors out (PROJECT_DIR isn't a
# git repo, git missing, etc.), we treat all events as ours. Preserves the
# pre-patch behavior for non-git or broken-install setups — the filter
# only adds scoping when it can verify scoping.
is_our_worktree() {
    local path="$1"
    local worktree_root
    # Strip "/.swarm/tasks/done/<file>.json" suffix to get the worktree root.
    worktree_root="$(echo "$path" | sed -E 's|/\.swarm/tasks/done/[^/]+$||')"

    local wt_list
    wt_list="$(git -C "$PROJECT_DIR" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}')" || return 0
    [ -z "$wt_list" ] && return 0

    grep -Fxq "$worktree_root" <<< "$wt_list"
}

# dispatch_outcome <outcome-path>
#
# Wrapper around on_outcome that applies the is_our_worktree filter.
# Used by both inotify and poll backends so the scoping logic lives in
# exactly one place.
dispatch_outcome() {
    local path="$1"
    if is_our_worktree "$path"; then
        on_outcome "$path"
    else
        local issue
        issue=$(basename "$path" | sed -E 's/.*-([0-9]+)\.(ok|err)\.json$/\1/')
        log_event worker.finish.skip "issue=$issue reason=foreign_worktree path=$path"
    fi
}

# cleanup_eligible_workers
#
# Full reap of workers whose PR has reached a reap-eligible terminal GitHub
# state, per WATCHER_AUTOCLOSE_MODE (issue #237): MERGED only (mode=merged,
# default), or MERGED *or* CLOSED (mode=finalized). Kills the tmux window,
# removes the worktree, deletes the local branch. Called inside on_outcome
# (after debounce passes, before coord.wake) so freed slots show up in the
# coordinator's window/alive count on its next wake.
#
# Uses $AUTOCLOSE_PR_FLAG (--merged-only or --pr-finalized, derived from
# WATCHER_AUTOCLOSE_MODE above) + --with-worktree. In finalized mode,
# CLOSED-without-merge is treated as terminal because the human explicitly
# said "not this work" — keeping the listener parked just burns a slot.
# Recovery is cheap if the closure was accidental: kill-worktree.sh only
# deletes the LOCAL branch (never pushes a delete), so origin/fix/issue-N
# survives and `gh pr reopen N` restores the PR. In the default merged mode,
# CLOSED-without-merge is left alone entirely (window + worktree intact) so
# the operator can inspect it before it vanishes.
#
# OPEN PRs and "no PR yet" cases are always left untouched, regardless of
# mode — those represent work the user may still want to land or babysit.
#
# This is the smooth-flow contract: PR reaches a terminal state -> watcher
# reaps everything -> slot fully free for the next dispatch. No manual
# scripts.
#
# Failures are non-fatal — the watcher's job is wake the coordinator, and
# the coordinator can still JIT-reap and/or report cap-reached if cleanup
# didn't fire.
#
# trigger (default "outcome"): who called us, for the events.log line.
# "outcome" = fired from on_outcome (a new outcome.json arrived); "pr_poll"
# = fired from the WATCH_PR_POLL_SECS backstop (issue #119) — same cleanup,
# different reason it ran.
cleanup_eligible_workers() {
    local trigger="${1:-outcome}"
    local dry_arg=""
    [ "$DRY_RUN" = "1" ] && dry_arg="--dry-run"

    # Capture stdout to count kills from the "Done. Closed N window(s)."
    # summary — per-target detail is kill-finished-workers.sh's own
    # reap.window events, so this line only carries the aggregate. A pass
    # that killed nothing is not logged (killed=0 heartbeats used to be
    # ~95% of events.log — the watch.pr_poll line already records that the
    # backstop fired); dry runs are always logged for visibility.
    local kf_out killed
    kf_out="$("$KILL_FINISHED" --idle-min 0 "$AUTOCLOSE_PR_FLAG" --with-worktree --yes $dry_arg 2>&1 || true)"
    killed="$(sed -nE 's/^Done\. Closed ([0-9]+) window\(s\)\.$/\1/p' <<<"$kf_out" | tail -1)"
    killed="${killed:-0}"
    if [ "$killed" != "0" ] || [ "$DRY_RUN" = "1" ]; then
        log_event watch.autoclose "trigger=$trigger mode=${WATCHER_AUTOCLOSE_MODE}+worktree dry_run=$DRY_RUN killed=$killed"
    fi
}

# Portable mtime (epoch seconds). GNU coreutils first, BSD fallback. Mirrors
# reap-orphan-worktrees.sh's mtime_epoch — kept local since scripts here are
# self-contained (see scripts/README.md). Also used below by
# probe_ctx_used for the auto-compact probe's staleness check.
mtime_epoch() {
    stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

# worktree_birth_path <worktree-dir>
#
# issue #232: the worktree ROOT directory's mtime bumps on every direct
# child create/rename/delete — .agent-task.md rewrites, build/.gradle
# creation, status-file writes — so any worker activity after the PR opens
# makes the root look "born" later than it really was, permanently
# defeating pr_predates_worktree below. `<worktree>/.git` is a FILE (not a
# dir) for a worktree checkout, written once by `git worktree add` and
# never touched again by normal work, so its mtime is a stable proxy for
# "when this worktree was born." Falls back to the worktree dir itself if
# that file is somehow absent (e.g. a non-worktree checkout in tests).
worktree_birth_path() {
    local wt_dir="$1"
    if [ -f "$wt_dir/.git" ]; then
        printf '%s/.git' "$wt_dir"
    else
        printf '%s' "$wt_dir"
    fi
}

# pr_predates_worktree <created_at-iso8601> <worktree-dir>
#
# issue #185: `gh pr list --state all` returns every PR that ever existed
# for a branch name — a recycled branch name whose previous PR is
# MERGED/CLOSED makes a freshly provisioned worktree on that branch look
# "finalized" to pr_poll_pass below, even though the terminal PR predates
# this worktree entirely (observed: a worker reaped 3s after provisioning
# because an old closed PR on the same branch name was still terminal).
# Compares the PR's createdAt against the worktree's birth timestamp (see
# worktree_birth_path — issue #232 moved this off the root dir's unstable
# mtime; same fix applied to kill-finished-workers.sh's
# pr_is_merged/pr_is_finalized).
#
# Fails CLOSED (i.e. "does NOT predate", not stale) whenever either
# timestamp can't be resolved, so a parsing hiccup falls back to the
# pre-#185 behavior (treat the terminal PR as reap evidence) rather than
# silently suppressing a legitimate reap forever.
pr_predates_worktree() {
    local created_at="$1" wt_dir="$2"
    [ -n "$created_at" ] && [ -d "$wt_dir" ] || return 1
    local pr_epoch wt_epoch
    pr_epoch=$(date -d "$created_at" +%s 2>/dev/null) || return 1
    [ -n "$pr_epoch" ] || return 1
    wt_epoch=$(mtime_epoch "$(worktree_birth_path "$wt_dir")") || return 1
    [ -n "$wt_epoch" ] || return 1
    [ "$pr_epoch" -lt "$wt_epoch" ]
}

# has_live_window <issue>
#
# issue #225: kill-finished-workers.sh (invoked by cleanup_eligible_workers)
# only ever iterates LIVE iss-N tmux windows in $SESSION_NAME — it has no way
# to see a worktree whose window is already gone. Callers use this to decide
# whether a terminal-PR worktree is actually reapable via that path, or is an
# orphan that needs reap-orphan-worktrees.sh instead (see orphan_sweep_pass).
# Returns 1 (no window) if the session itself doesn't exist — that's still
# correctly "kill-finished-workers.sh can't reach this."
has_live_window() {
    tmux list-windows -t "$SESSION_NAME" -F '#W' 2>/dev/null | grep -qx "iss-$1"
}

# pr_poll_pass
#
# Behavior A backstop (issue #119): the outcome-driven reap above only
# fires when a NEW outcome.json appears, but outcome.json is written once
# — usually right after the PR opens, well before it merges. A worker
# that's parked (interactive REPL still open) or whose listener already
# exited never produces a second outcome.json, so a PR merging later never
# re-triggers the reap. This runs on its own timer (WATCH_PR_POLL_SECS),
# independent of the outcome-driven backend, so it fires even when that
# backend is blocked waiting on filesystem events that will never come.
#
# One `gh pr list --state all` call covers every worker branch in a single
# API round-trip (vs. kill-finished-workers.sh's N per-window `gh pr view`
# calls) — cheap enough to run every 60s indefinitely (~60 req/hr).
#
# Also drives the Behavior B (check-on-done) PR-open backstop: any branch
# with a PR at all (regardless of state) counts as "done" for a worker
# that never wrote a status file.
pr_poll_pass() {
    local prs
    prs="$(cd "$PROJECT_DIR" && gh pr list --state all --limit 500 \
            --json headRefName,state,number,createdAt \
            --jq '.[] | "\(.headRefName)\t\(.state)\t\(.number)\t\(.createdAt)"' 2>/dev/null)" || {
        log_event pr_poll.error "reason=gh_pr_list_failed"
        return 0
    }
    [ -n "$prs" ] || return 0

    local reap_hit=0 branch state pr_number created_at issue wt_dir
    while IFS=$'\t' read -r branch state pr_number created_at; do
        [ -z "$branch" ] && continue
        case "$branch" in
            fix/issue-*) : ;;
            *) continue ;;
        esac
        issue="${branch#fix/issue-}"
        [[ "$issue" =~ ^[0-9]+$ ]] || continue
        wt_dir="$WORKSPACE/wt-issue-$issue"
        if [ ! -d "$wt_dir" ]; then
            # already reaped, or never provisioned here — drop any stale
            # dedup entry so a future worktree reusing this issue number
            # starts fresh (see ORPHAN_PR_LOGGED comment above).
            unset "ORPHAN_PR_LOGGED[$issue]" 2>/dev/null || true
            continue
        fi

        # issue #237: in the default merged mode, a CLOSED-without-merge PR
        # is not reap-eligible at all — skip it here so it never triggers
        # stale_pr_ignored/orphan_no_window logging or a wasted
        # cleanup_eligible_workers pass for a worker WATCHER_AUTOCLOSE_MODE
        # says to leave alone. finalized mode keeps the original MERGED-or-
        # CLOSED behavior.
        if [ "$state" = "MERGED" ] || { [ "$state" = "CLOSED" ] && [ "$WATCHER_AUTOCLOSE_MODE" = "finalized" ]; }; then
            if pr_predates_worktree "$created_at" "$wt_dir"; then
                log_event watch.pr_poll "reason=stale_pr_ignored issue=$issue branch=$branch pr=$pr_number state=$state"
            elif has_live_window "$issue"; then
                reap_hit=1
            else
                # issue #225: this worktree outlived its tmux window
                # (session restart, docker daemon restart — cf. #217).
                # cleanup_eligible_workers's kill-finished-workers.sh only
                # iterates LIVE iss-N windows, so routing this into reap_hit
                # would just re-run that pass forever with killed=0 every
                # cycle. Log once per issue and leave the actual reap to
                # orphan_sweep_pass (reap-orphan-worktrees.sh), which walks
                # worktree DIRECTORIES instead of tmux windows.
                if [ -z "${ORPHAN_PR_LOGGED[$issue]:-}" ]; then
                    log_event watch.pr_poll "reason=orphan_no_window issue=$issue branch=$branch pr=$pr_number state=$state"
                    ORPHAN_PR_LOGGED[$issue]=1
                fi
            fi
        fi

        if [ "$WATCH_CHECK_ON_DONE" = "1" ]; then
            maybe_run_check "$wt_dir" "$issue"
        fi
    done <<< "$prs"

    if [ "$reap_hit" = "1" ]; then
        log_event watch.pr_poll "reason=terminal_pr_detected"
        if [ "$WATCHER_AUTOCLOSE" = "1" ]; then
            echo "[$(date +%T)] pr-poll: terminal PR(s) detected on unreaped worktree(s) — running autoclose"
            cleanup_eligible_workers pr_poll
        else
            echo "[$(date +%T)] pr-poll: terminal PR(s) detected but WATCHER_AUTOCLOSE=0 — not reaping"
        fi
    fi
}

# orphan_sweep_pass
#
# issue #225: the reap in cleanup_eligible_workers (kill-finished-workers.sh)
# only ever sees LIVE iss-N tmux windows, so a worktree whose window is
# already gone (session restart, docker daemon restart — cf. #217) can never
# be cleared by pr_poll_pass's reap_hit path above — it just gets logged
# once as orphan_no_window and would otherwise sit there forever. This runs
# reap-orphan-worktrees.sh, which walks worktree DIRECTORIES instead of tmux
# windows and has its own independent safety predicate (min-age, clean tree,
# PR finalized), on a much slower cadence (WATCH_ORPHAN_SWEEP_SECS) since
# it's a heavier full-directory sweep rather than a single gh round-trip.
# Failures are non-fatal, same policy as cleanup_eligible_workers.
#
# issue #237: deliberately NOT gated by WATCHER_AUTOCLOSE_MODE — always
# --pr-finalized. Every target here already has no live tmux window (that's
# the whole reason it's an orphan), so there's no scrollback left to
# preserve either way; the "leave CLOSED-without-merge open for inspection"
# motivation behind WATCHER_AUTOCLOSE_MODE doesn't apply to a window that's
# already gone.
orphan_sweep_pass() {
    local dry_arg=""
    [ "$DRY_RUN" = "1" ] && dry_arg="--dry-run"

    local out reaped
    out="$(cd "$PROJECT_DIR" && "$REAP_ORPHAN" --pr-finalized --yes $dry_arg 2>&1 || true)"
    reaped="$(sed -nE 's/^Done\. Reaped ([0-9]+) worktree\(s\).*/\1/p' <<<"$out" | tail -1)"
    reaped="${reaped:-0}"
    if [ "$reaped" != "0" ] || [ "$DRY_RUN" = "1" ]; then
        log_event watch.orphan_sweep "mode=pr-finalized dry_run=$DRY_RUN reaped=$reaped"
    fi
}

# status_poll_pass
#
# Behavior B fast path (issue #119): scan every worktree's
# .swarm/tasks/status/ dir (worker->coordinator "done" declaration, see
# issue #129) for a state of "ready-for-review" and fire the acceptance
# check. Cheap (local filesystem only), so this runs every 2s from the
# timer loop regardless of WATCH_PR_POLL_SECS.
status_poll_pass() {
    [ "$HAVE_JQ" = "1" ] || return 0
    shopt -s nullglob
    local f wt_dir issue state task_id
    for f in "$WORKSPACE"/wt-issue-*/.swarm/tasks/status/*.json; do
        case "$f" in *.check.json) continue ;; esac
        wt_dir="${f%/.swarm/tasks/status/*}"
        issue="$(basename "$wt_dir")"; issue="${issue#wt-issue-}"
        # task_id = filename sans .json, per the #129 status-file path
        # convention (<task_id>.json) — not the JSON body's task_id field,
        # so this stays correct even without jq.
        task_id="$(basename "$f" .json)"
        state=$(jq -r '.state // empty' "$f" 2>/dev/null) || continue
        if [ "$state" = "ready-for-review" ]; then
            maybe_run_check "$wt_dir" "$issue" "$task_id"
        fi
    done
    shopt -u nullglob
}

# pr_state_for_worktree <worktree-dir> <issue>
#
# Best-effort PR state lookup for whatever branch is actually checked out
# in the worktree (falls back to fix/issue-N if that can't be resolved —
# e.g. a fixture dir in tests, or a worktree mid-provision). One `gh pr
# view` round-trip; only called right after a check-claim is won (see
# maybe_run_check), so it's not on any hot polling path. Echoes the state
# string (OPEN/MERGED/CLOSED/...) or nothing on any failure — callers must
# treat empty as "unknown, don't skip."
pr_state_for_worktree() {
    local wt_dir="$1" issue="$2" branch
    branch="$(git -C "$wt_dir" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    [ -n "$branch" ] || branch="fix/issue-$issue"
    (cd "$wt_dir" 2>/dev/null && gh pr view "$branch" --json state -q .state 2>/dev/null) || true
}

# check_json_state <check-json-path>
#
# Extracts .state from a *.check.json without requiring jq (this runs from
# both the jq-gated status_poll_pass and the always-on pr_poll_pass).
check_json_state() {
    sed -n 's/.*"state":"\([a-zA-Z_]*\)".*/\1/p' "$1" 2>/dev/null | head -1
}

# maybe_run_check <worktree-dir> <issue> [task_id]
#
# Resolve + claim + run the acceptance check for a worker that has
# signaled done (either status_poll_pass or pr_poll_pass called us). Both
# callers converge here so a task that fires both signals in the same
# window only runs its check once — the claim is an atomic `mkdir`
# (kernel-level single-writer).
#
# task_id: status_poll_pass always knows it (the file it just read).
# pr_poll_pass (PR-open backstop) doesn't — it only knows the issue. In
# that case we look for the first status file that hasn't already been
# claimed/checked and use ITS task_id, rather than guessing (a prior
# version picked the lexicographically-latest status file, which could
# grab the WRONG task in a worktree that's processed more than one, and
# permanently consume the claim so the real ready-for-review task never
# gets checked). We only fall back to a synthetic per-issue key when the
# worktree has no status file at all — the literal "worker never wrote
# the #129 convention" case the backstop exists for.
#
# issue #181: the claim dir is released (rmdir) as soon as its run reaches
# a terminal outcome (pass/fail/skipped) — see execute_check below — so
# kill-worktree.sh's reap-side guard only sees it as "in flight" for the
# actual duration of the check, not forever. That means claim-dir
# ABSENCE can no longer be used as an "already handled" signal (a
# completed task's claim is gone too) — the "unclaimed" scan below and
# the fast-path re-entry check just above it both key off the *.check.json
# terminal state instead, which IS permanent.
maybe_run_check() {
    local wt_dir="$1" issue="$2" task_id="${3:-}"
    local status_dir="$wt_dir/.swarm/tasks/status"
    mkdir -p "$status_dir" 2>/dev/null || return 0

    if [ -z "$task_id" ]; then
        # Distinguish "no status file exists at all" (synthesize a key —
        # this is the literal backstop case) from "a status file exists
        # but is already claimed or resolved" (some other pass already
        # owns/finished it — return, don't synthesize a SECOND key for the
        # same issue, which would double-run the check under a different
        # task_id).
        local f candidate any_status=0 unclaimed=""
        shopt -s nullglob
        for f in "$status_dir"/*.json; do
            case "$f" in *.check.json) continue ;; esac
            any_status=1
            candidate="$(basename "$f" .json)"
            if [ -d "$status_dir/${candidate}.check-claim" ]; then
                continue   # in flight — some other pass owns it
            fi
            if [ -f "$status_dir/${candidate}.check.json" ]; then
                case "$(check_json_state "$status_dir/${candidate}.check.json")" in
                    pass|fail|skipped) continue ;;   # already resolved
                esac
            fi
            unclaimed="$candidate"
            break
        done
        shopt -u nullglob
        if [ -n "$unclaimed" ]; then
            task_id="$unclaimed"
        elif [ "$any_status" = "1" ]; then
            return 0
        fi
    fi
    [ -n "$task_id" ] || task_id="pr-issue-$issue"

    local check_json="$status_dir/${task_id}.check.json"
    if [ -f "$check_json" ]; then
        case "$(check_json_state "$check_json")" in
            pass|fail|skipped) return 0 ;;   # already resolved — don't re-run
        esac
    fi

    local claim_dir="$status_dir/${task_id}.check-claim"
    mkdir "$claim_dir" 2>/dev/null || return 0   # already claimed (in flight) — nothing to do

    # issue #181: the PR may already be MERGED/CLOSED by the time we win
    # the claim — the merge already validated the work, so spawning a
    # check now is redundant and would only hold the reap-blocking claim
    # for no benefit. Skip and let reap proceed.
    local pr_state
    pr_state="$(pr_state_for_worktree "$wt_dir" "$issue")"
    if [ "$pr_state" = "MERGED" ] || [ "$pr_state" = "CLOSED" ]; then
        printf '{"task_id":"%s","state":"skipped","check_exit":null,"ts":"%s"}\n' \
            "$task_id" "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" > "$check_json" 2>/dev/null || true
        log_event watch.check_on_done "issue=$issue task_id=$task_id result=skipped reason=pr_terminal_$pr_state"
        rmdir "$claim_dir" 2>/dev/null || true
        return 0
    fi

    printf '{"task_id":"%s","state":"checking","check_exit":null,"ts":"%s"}\n' \
        "$task_id" "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" > "$check_json" 2>/dev/null || true

    # Resolve the check command the same order worker-listener.sh does:
    #   1. brief marker in the task file (processing/ if still parked,
    #      done/ if the listener already archived it)
    #   2. standing per-issue check in the worktree
    #   3. listener-wide env default
    local check_cmd="" brief
    brief=$(find "$wt_dir/.swarm/tasks/processing" "$wt_dir/.swarm/tasks/done" \
                -maxdepth 1 -name "${task_id}*.md" 2>/dev/null | head -1)
    if [ -n "$brief" ]; then
        check_cmd=$(sed -n 's/.*<!-- SWARM_CHECK: \(.*\) -->.*/\1/p' "$brief" | head -1)
    fi
    if [ -z "$check_cmd" ] && [ -r "$wt_dir/.swarm/check.sh" ]; then
        check_cmd="bash .swarm/check.sh"
    fi
    [ -z "$check_cmd" ] && check_cmd="${WORKER_CHECK_CMD:-}"

    if [ -z "$check_cmd" ]; then
        printf '{"task_id":"%s","state":"skipped","check_exit":null,"ts":"%s"}\n' \
            "$task_id" "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" > "$check_json" 2>/dev/null || true
        log_event watch.check_on_done "issue=$issue task_id=$task_id result=skipped reason=no_check_resolved"
        rmdir "$claim_dir" 2>/dev/null || true
        return 0
    fi

    log_event watch.check_on_done "issue=$issue task_id=$task_id result=running"

    if [ "$DRY_RUN" = "1" ]; then
        echo "[$(date +%T)] [DRY] check-on-done issue #$issue (task $task_id): $check_cmd"
        printf '{"task_id":"%s","state":"skipped","check_exit":null,"ts":"%s"}\n' \
            "$task_id" "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" > "$check_json" 2>/dev/null || true
        rmdir "$claim_dir" 2>/dev/null || true
        return 0
    fi

    execute_check "$wt_dir" "$issue" "$task_id" "$check_cmd" "$check_json" "$claim_dir"
}

# record_check_result <task_id> <issue> <check_json> <exit-code>
#
# Single place that writes the watcher-owned <task_id>.check.json + the
# events.log line, so both the synchronous CHECK_RUNNER (test) path and
# the real tmux path record results identically.
record_check_result() {
    local task_id="$1" issue="$2" check_json="$3" rc="$4"
    local state="pass"
    [ "$rc" -eq 0 ] || state="fail"
    printf '{"task_id":"%s","state":"%s","check_exit":%d,"ts":"%s"}\n' \
        "$task_id" "$state" "$rc" "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" > "$check_json" 2>/dev/null || true
    log_event watch.check_on_done "issue=$issue task_id=$task_id result=$state check_exit=$rc"
}

# execute_check <worktree-dir> <issue> <task_id> <check-cmd> <check-json> <claim-dir>
#
# Runs the resolved check exactly once (claim already taken by the caller)
# and records the result. Two backends:
#   - CHECK_RUNNER set (tests): synchronous — run "$CHECK_RUNNER <worktree>
#     <check_cmd>", record the result immediately via record_check_result.
#     No tmux dependency.
#   - default: spawn a visible tmux window `chk-N` (mirrors provision-worker.sh's
#     `iss-N` windows) so the operator can watch/scroll back the run. check_cmd
#     is free-form text (from a SWARM_CHECK marker, .swarm/check.sh, or
#     WORKER_CHECK_CMD) — rather than interpolate it into a `tmux ... bash -c
#     "..."` string (a stray single quote would break, or worse, the nested
#     shell), we write a small standalone script and hand tmux its path. Each
#     dynamic value is written as its own `NAME=%q` assignment (printf %q
#     shell-quotes it correctly regardless of content); the rest of the
#     script is a literal heredoc ('SCRIPT' — unexpanded by this shell) that
#     just references those variables normally.
#
# issue #181: claim_dir is released (rmdir) as soon as this reaches a
# terminal outcome — synchronously here for the CHECK_RUNNER/no-tmux/spawn-
# failure paths, or inside the runner_script itself for the real tmux path
# (that one completes asynchronously, long after this function returns).
# kill-worktree.sh's reap-side guard treats claim_dir existence as "check
# in flight, defer" — releasing it promptly is what lets reap proceed
# right after the check finishes instead of waiting out the stale-claim TTL.
execute_check() {
    local wt_dir="$1" issue="$2" task_id="$3" check_cmd="$4" check_json="$5" claim_dir="$6"

    if [ -n "$CHECK_RUNNER" ]; then
        local rc=0
        "$CHECK_RUNNER" "$wt_dir" "$check_cmd" || rc=$?
        record_check_result "$task_id" "$issue" "$check_json" "$rc"
        rmdir "$claim_dir" 2>/dev/null || true
        return 0
    fi

    if ! command -v tmux >/dev/null 2>&1 || ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        log_event watch.check_on_done "issue=$issue task_id=$task_id result=skipped reason=no_tmux_session"
        printf '{"task_id":"%s","state":"skipped","check_exit":null,"ts":"%s"}\n' \
            "$task_id" "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" > "$check_json" 2>/dev/null || true
        rmdir "$claim_dir" 2>/dev/null || true
        return 0
    fi

    local win="chk-$issue"
    local timeout_secs="${WORKER_CHECK_TIMEOUT:-600}"
    local runner_script="$wt_dir/.swarm/tasks/status/${task_id}.check-run.sh"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'ISSUE=%q\n'        "$issue"
        printf 'TASK_ID=%q\n'      "$task_id"
        printf 'CHECK_CMD=%q\n'    "$check_cmd"
        printf 'CHECK_JSON=%q\n'   "$check_json"
        printf 'CLAIM_DIR=%q\n'    "$claim_dir"
        printf 'EVENTS_LOG=%q\n'   "$EVENTS_LOG"
        printf 'TIMEOUT_SECS=%q\n' "$timeout_secs"
        # Mirrors record_check_result's output shape exactly — see that
        # function if this drifts. Kept as inline shell (not a call back
        # into this script) because this runs as a separate tmux process.
        cat <<'SCRIPT'
echo "--- check-on-done: issue #$ISSUE (task $TASK_ID) ---"
echo "check: $CHECK_CMD"
timeout "$TIMEOUT_SECS" bash -c "$CHECK_CMD"
rc=$?
state=pass; [ "$rc" -eq 0 ] || state=fail
ts=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
printf '{"task_id":"%s","state":"%s","check_exit":%d,"ts":"%s"}\n' "$TASK_ID" "$state" "$rc" "$ts" > "$CHECK_JSON"
rmdir "$CLAIM_DIR" 2>/dev/null || true
printf '%s  %-15s %s\n' "$ts" 'watch.check_on_done' "issue=$ISSUE task_id=$TASK_ID result=$state check_exit=$rc" >> "$EVENTS_LOG"
echo "--- check $state (exit $rc) — this window stays open for review ---"
exec bash
SCRIPT
    } > "$runner_script" 2>/dev/null
    chmod +x "$runner_script" 2>/dev/null

    tmux new-window -d -t "$SESSION_NAME" -n "$win" -c "$wt_dir" bash "$runner_script" 2>/dev/null \
        || { log_event watch.check_on_done.error "issue=$issue task_id=$task_id reason=tmux_new_window_failed"; rmdir "$claim_dir" 2>/dev/null || true; }
}

# run_watch_timer_loop
#
# Single background process driving Behavior A (WATCH_PR_POLL_SECS) and
# Behavior B fast-path (2s status-file poll). One process (not two) to keep
# trap-based cleanup simple — see the trap wired up near the bottom of the
# script.
#
# issue #226's worker auto-compact sweep deliberately does NOT live in this
# loop, even though it's gated by its own interval the same way pr_poll_pass
# is — a single maybe_worker_compact call can block for minutes (up to
# WORKER_COMPACT_START_TIMEOUT_SECS + WORKER_COMPACT_FINISH_TIMEOUT_SECS +
# WORKER_COMPACT_VERIFY_TIMEOUT_SECS ≈ 345s by default) waiting out a real
# compaction, and worker_compact_pass sweeps EVERY over-threshold iss-*
# window serially. Sharing this loop would stall status_poll_pass's 2s
# done-detection and the WATCH_PR_POLL_SECS reap backstop for every OTHER
# worker for the full duration of that wait — a real regression to
# already-shipped responsiveness, not an acceptable tradeoff for keeping
# process/trap bookkeeping simple. See run_worker_compact_loop below,
# started as its own background process.
#
# issue #210's coordinator poll-tick auto-compact trigger doesn't live here
# either, for the identical blocking-duration reason (a single
# maybe_auto_compact call, not a sweep, but the same ~345s worst case) — see
# run_auto_compact_poll_loop, started as its own background process right
# after this function.
run_watch_timer_loop() {
    local last_pr_poll=0 last_orphan_sweep=0 now
    while true; do
        sleep 2
        [ "$WATCH_CHECK_ON_DONE" = "1" ] && { status_poll_pass || true; }
        if [ "$WATCH_PR_POLL_SECS" -gt 0 ]; then
            now=$(date +%s)
            if [ $((now - last_pr_poll)) -ge "$WATCH_PR_POLL_SECS" ]; then
                pr_poll_pass || true
                last_pr_poll=$now
            fi
        fi
        if [ "$WATCH_ORPHAN_SWEEP_SECS" -gt 0 ] && [ "$WATCHER_AUTOCLOSE" = "1" ]; then
            now=$(date +%s)
            if [ $((now - last_orphan_sweep)) -ge "$WATCH_ORPHAN_SWEEP_SECS" ]; then
                orphan_sweep_pass || true
                last_orphan_sweep=$now
            fi
        fi
    done
}

# run_auto_compact_poll_loop
#
# issue #210: own background process for the coordinator poll-tick
# auto-compact trigger, on its own AUTO_COMPACT_TICK_SECS interval — NOT
# folded into run_watch_timer_loop, for the same reason WORKER_AUTO_COMPACT's
# sweep (run_worker_compact_loop, just below) isn't either: a single
# maybe_auto_compact call can block for minutes (up to
# AUTO_COMPACT_START_TIMEOUT_SECS + AUTO_COMPACT_FINISH_TIMEOUT_SECS +
# AUTO_COMPACT_VERIFY_TIMEOUT_SECS ≈ 345s by default) waiting out a real
# compaction. Sharing run_watch_timer_loop would stall status_poll_pass's 2s
# done-detection and the WATCH_PR_POLL_SECS reap backstop for that entire
# duration on every tick a compaction actually fires — the exact regression
# run_worker_compact_loop's header comment already documents avoiding for
# the per-worker case.
run_auto_compact_poll_loop() {
    while true; do
        sleep "$AUTO_COMPACT_TICK_SECS"
        auto_compact_poll_pass || true
    done
}

# run_worker_compact_loop
#
# Own background process for the worker auto-compact sweep (issue #226),
# separate from run_watch_timer_loop for the blocking-duration reason
# documented on that function above. A plain fixed-interval loop (not the
# "gate inside a tighter loop" shape run_watch_timer_loop uses for
# WATCH_PR_POLL_SECS) since this loop has exactly one job — there's no
# faster-cadence sibling pass it needs to interleave with.
run_worker_compact_loop() {
    while true; do
        sleep "$WORKER_COMPACT_SCAN_SECS"
        worker_compact_pass || true
    done
}

# --- Auto-compact (before wake) ---------------------------------------------
#
# mtime_epoch is defined above, near pr_predates_worktree (issue #185) —
# probe_ctx_used below reuses it for the auto-compact probe's staleness
# check.

# coordinator_pane_state
#
# Echoes "absent" (no session, or no coordinator window), "shell" (pane's
# foreground process is a bare shell — claude already exited, nothing to
# compact), or "cli" (a CLI process, e.g. claude, is the foreground
# command — compaction may be possible, subject to coordinator_pane_busy).
# Mirrors llm-start.sh's coordinator_idle detection (pane_current_command).
coordinator_pane_state() {
    tmux has-session -t "$SESSION_NAME" 2>/dev/null || { echo absent; return; }
    tmux list-windows -t "$SESSION_NAME" -F '#W' 2>/dev/null | grep -qx 'coordinator' || { echo absent; return; }
    local pane_cmd
    pane_cmd="$(tmux list-panes -t "$SESSION_NAME:coordinator" -F '#{pane_current_command}' 2>/dev/null | head -1)" || pane_cmd=""
    case "$pane_cmd" in
        bash|zsh|sh|fish|"") echo shell ;;
        *)                   echo cli ;;
    esac
}

# coordinator_pane_busy
#
# True (rc 0) if the coordinator pane's currently rendered content matches
# AUTO_COMPACT_BUSY_PATTERN — i.e. claude is mid-turn (or sitting at an
# exit-confirmation prompt) rather than idle at its input box.
# pane_current_command can't tell these apart (claude is the foreground
# command in both states), so this greps the actual screen content
# instead — same technique check-stuck-workers.sh's detect_state() uses to
# classify worker panes, applied here to the coordinator's own pane.
# ANSI-stripped and LC_ALL=C for the same reason documented there: raw
# escape sequences and the Unicode spinner glyphs (✻/✶) can otherwise trip
# bash's here-string handling under a UTF-8 locale.
coordinator_pane_busy() {
    local content clean
    content="$(tmux capture-pane -t "$SESSION_NAME:coordinator" -p 2>/dev/null)" || return 1
    clean="$(printf '%s\n' "$content" | sed 's/\x1b\[[0-9;?]*[A-Za-z]//g; s/\x1b\][^\x07]*\x07//g; s/\x1b[()][AB012]//g; s/\r/\n/g')"
    printf '%s\n' "$clean" | LC_ALL=C grep -qE "$AUTO_COMPACT_BUSY_PATTERN"
}

# probe_ctx_used
#
# Echoes the coordinator's last-reported used-token count and returns 0,
# or returns 1 with no output, when the probe file (written by
# scripts/statusline-with-context.sh, when installed as the coordinator's
# statusLine) is missing, stale (mtime older than
# AUTO_COMPACT_PROBE_MAX_AGE_SECS — the coordinator may not actually be
# rendering right now, e.g. pane not visible), or doesn't parse to a plain
# integer. Fails closed throughout: no probe file (feature not set up) is
# indistinguishable here from "can't tell," and both correctly skip
# auto-compact rather than guess. jq paths mirror the statusline script's
# own ctx_used extraction — the probe file IS that script's raw stdin
# payload, so the same field-path fallbacks apply.
probe_ctx_used() {
    [ "$HAVE_JQ" = "1" ] || return 1
    [ -r "$AUTO_COMPACT_PROBE" ] || return 1
    local mtime now
    mtime=$(mtime_epoch "$AUTO_COMPACT_PROBE") || return 1
    [ -n "$mtime" ] || return 1
    now=$(date +%s)
    [ $((now - mtime)) -le "$AUTO_COMPACT_PROBE_MAX_AGE_SECS" ] || return 1

    local used
    used=$(jq -r '
        .context_window.total_input_tokens //
        .context_window.used_tokens //
        .context.input_tokens //
        .context.used //
        .usage.input_tokens //
        empty
    ' "$AUTO_COMPACT_PROBE" 2>/dev/null) || true
    [[ "$used" =~ ^[0-9]+$ ]] || return 1
    echo "$used"
}

# maybe_auto_compact [trigger]
#
# Called from two places (issue #210): on_outcome, right before waking the
# coordinator (after the debounce check has already passed — i.e. we're
# committed to waking) — trigger=wake (the default, so pre-#210 call sites
# and the test fixture's bare `maybe_auto_compact` are unchanged); and
# auto_compact_poll_pass, on its own AUTO_COMPACT_TICK_SECS timer — trigger=
# poll. `trigger` is recorded on every coord.compact* event this logs (see
# EVENTS LOG in the header) but otherwise doesn't change this function's
# logic at all — the wake path's behavior is identical to before #210.
# If AUTO_COMPACT is enabled, the coordinator pane holds a live and
# currently-idle CLI session, and its last-probed context usage is
# at/above AUTO_COMPACT_THRESHOLD_TOKENS, injects a real `/compact` via
# the same load-buffer + paste-buffer + send-keys-Enter mechanism
# llm-start.sh's live-REPL reprompt path uses (Enter actually submits it —
# this is not just populating the input box), then blocks in a poll loop
# until the busy indicator confirms compaction started and later cleared.
#
# Fails open at every step: a missing precondition, a stale/absent probe,
# or either timeout just returns 0 and falls through to the normal wake —
# this is strictly an optimization on top of that wake, never a gate on
# it. Blocking here (a real compaction run is commonly a minute or more)
# is consistent with the rest of on_outcome, which is already a
# synchronous, one-outcome-at-a-time call chain. The poll-tick caller
# blocks the SAME way — it runs from its own dedicated background process
# (see run_auto_compact_poll_loop), separate from both the wake path and
# run_watch_timer_loop, so blocking there for a minute+ never delays a
# coordinator wake or the status/PR-poll timer loop's own ticks.
maybe_auto_compact() {
    local trigger="${1:-wake}"
    [ "$AUTO_COMPACT" = "1" ] || return 0

    # issue #210: this function is now reachable from two separate
    # processes — the wake path (on_outcome, in the main watcher process)
    # and the poll-tick path (auto_compact_poll_pass, in
    # run_auto_compact_poll_loop's own dedicated process) — that can fire
    # within milliseconds of each other. Without serialization, both could
    # pass the coordinator_pane_busy check while the pane is still idle,
    # then both hit the SAME tmux buffer (llm-coord-autocompact) below,
    # corrupting what actually lands in the live user-facing session. flock
    # the whole busy-check-through-injection critical section in a subshell
    # so only one caller is ever "in flight" at a time; the subshell scopes
    # the lock release to fd 9 closing on any exit path, without threading
    # cleanup through every early return below. On contention — a narrow
    # window, only when a wake and a poll tick land back to back — skip and
    # let the loser's own next trigger (wake or poll) retry, same as every
    # other precondition here (pane_busy, no_fresh_probe, ...).
    (
        flock -n 9 || { log_event coord.compact.skip "reason=locked trigger=$trigger"; exit 0; }

        local state
        state="$(coordinator_pane_state)" || state="absent"
        [ "$state" = "cli" ] || exit 0   # no live session to compact

        if coordinator_pane_busy; then
            log_event coord.compact.skip "reason=pane_busy trigger=$trigger"
            exit 0   # don't race a live turn — see docs/tmux-as-channel.md on send-keys races
        fi

        local used
        used="$(probe_ctx_used)" || {
            log_event coord.compact.skip "reason=no_fresh_probe trigger=$trigger"
            exit 0
        }

        [ "$used" -ge "$AUTO_COMPACT_THRESHOLD_TOKENS" ] || exit 0   # under threshold — the common case

        echo "[$(date +%T)] coordinator context at ${used} tokens (>= ${AUTO_COMPACT_THRESHOLD_TOKENS}) — compacting before wake..."
        log_event coord.compact "used=$used threshold=$AUTO_COMPACT_THRESHOLD_TOKENS trigger=$trigger"

        if [ "$DRY_RUN" = "1" ]; then
            echo "[DRY] would inject /compact into $SESSION_NAME:coordinator and wait for it to finish"
            exit 0
        fi

        # Reference point for the post-compaction verification below: captured
        # BEFORE injection so we can later tell "the probe genuinely re-rendered
        # with fresh data" from "the statusline just hasn't refreshed yet" —
        # only the former is meaningful evidence either way.
        local probe_mtime_before
        probe_mtime_before=$(mtime_epoch "$AUTO_COMPACT_PROBE" 2>/dev/null) || probe_mtime_before=0
        [ -n "$probe_mtime_before" ] || probe_mtime_before=0

        # Every step below is best-effort — a transient tmux failure here must
        # degrade to "compaction never visibly started" (caught by the start-
        # timeout below) rather than take the whole daemon down via set -e.
        #
        # Deliberately NO trailing newline in the pasted buffer (unlike
        # llm-start.sh's own reprompt path, which pastes an arbitrary multi-line
        # prompt where a trailing newline is harmless either way): "/compact" is
        # a single slash command, and pasting it with an embedded newline plus a
        # separate trailing Enter leaves it ambiguous whether the CLI's input
        # buffer sees "/compact" (trimmed) or "/compact\n" at submit time.
        # Pasting the bare text with no newline at all, then a genuinely
        # separate Enter keystroke, removes that ambiguity outright.
        local tmp_compact
        tmp_compact=$(mktemp) || { log_event coord.compact.skip "reason=mktemp_failed trigger=$trigger"; exit 0; }
        printf '/compact' > "$tmp_compact" 2>/dev/null || true
        tmux load-buffer -b llm-coord-autocompact "$tmp_compact" 2>/dev/null || true
        tmux paste-buffer -b llm-coord-autocompact -t "$SESSION_NAME:coordinator" -d 2>/dev/null || true
        tmux send-keys -t "$SESSION_NAME:coordinator" Enter 2>/dev/null || true
        rm -f "$tmp_compact" 2>/dev/null || true

        # Wait for compaction to actually start (busy indicator appears) —
        # confirms the CLI picked up the input. If it never appears within
        # the timeout, something's off (race, rejected input, wrong pane
        # state); log it and fall through rather than block further.
        local waited=0
        while ! coordinator_pane_busy; do
            sleep "$AUTO_COMPACT_POLL_SECS"
            waited=$((waited + AUTO_COMPACT_POLL_SECS))
            if [ "$waited" -ge "$AUTO_COMPACT_START_TIMEOUT_SECS" ]; then
                log_event coord.compact.timeout "phase=start waited=${waited}s trigger=$trigger"
                exit 0
            fi
        done

        # Now wait for it to finish (busy indicator clears).
        waited=0
        while coordinator_pane_busy; do
            sleep "$AUTO_COMPACT_POLL_SECS"
            waited=$((waited + AUTO_COMPACT_POLL_SECS))
            if [ "$waited" -ge "$AUTO_COMPACT_FINISH_TIMEOUT_SECS" ]; then
                log_event coord.compact.timeout "phase=finish waited=${waited}s trigger=$trigger"
                exit 0
            fi
        done

        echo "[$(date +%T)] compaction done (${waited}s) — proceeding with wake"
        log_event coord.compact.done "waited=${waited}s trigger=$trigger"

        # Whether a pasted "/compact" is actually recognized as the slash
        # command (vs. submitted as a plain chat message) isn't something this
        # script can verify short of a live session — the busy indicator
        # appears and clears identically either way, since both cases are just
        # "claude processing a turn". If it silently landed as a chat message,
        # context grows instead of shrinking, and since it'd still be over
        # threshold, this would otherwise repeat on every subsequent wake with
        # no visible symptom.
        #
        # Poll for the probe's mtime to actually advance past
        # probe_mtime_before, rather than trusting a fixed sleep — the
        # statusline's render cadence isn't guaranteed to land within any fixed
        # window, and checking a probe that hasn't been rewritten yet would
        # just re-read the pre-compaction value and misreport a working
        # compaction as ineffective. If it never refreshes within
        # AUTO_COMPACT_VERIFY_TIMEOUT_SECS, this is inconclusive (not a
        # failure) — logged as verify_skip, not ineffective.
        local verify_waited=0 probe_mtime_after used_after=""
        while [ "$verify_waited" -lt "$AUTO_COMPACT_VERIFY_TIMEOUT_SECS" ]; do
            sleep "$AUTO_COMPACT_POLL_SECS"
            verify_waited=$((verify_waited + AUTO_COMPACT_POLL_SECS))
            probe_mtime_after=$(mtime_epoch "$AUTO_COMPACT_PROBE" 2>/dev/null) || probe_mtime_after=0
            [ -n "$probe_mtime_after" ] || probe_mtime_after=0
            if [ "$probe_mtime_after" -gt "$probe_mtime_before" ]; then
                used_after="$(probe_ctx_used)" || used_after=""
                break
            fi
        done

        if [ -z "$used_after" ]; then
            log_event coord.compact.verify_skip "reason=probe_not_refreshed waited=${verify_waited}s trigger=$trigger"
        elif [ "$used_after" -ge "$used" ]; then
            echo "[$(date +%T)] WARNING: context did not drop after /compact (before=$used after=$used_after) — the injected command may not have been recognized as a slash command; investigate before this repeats every wake"
            log_event coord.compact.ineffective "before=$used after=$used_after trigger=$trigger"
        fi
    ) 9>"$AUTO_COMPACT_LOCK"
}

# LAST_AUTO_COMPACT_POLL_TRIGGER (issue #210)
#
# Cooldown timestamp for auto_compact_poll_pass below, in epoch seconds; 0
# means "no compact attempted yet this run." Deliberately a plain global,
# not a file: it's only ever read/written from run_auto_compact_poll_loop's
# own background process (the only caller of auto_compact_poll_pass), so a
# same-process global is sufficient — no cross-process sharing needed the
# way, say, ORPHAN_PR_LOGGED's declare -A doesn't need to be (also
# process-local for the same reason). Resets to 0 on watcher restart, same
# as every other timer-loop cooldown/dedup state in this file.
LAST_AUTO_COMPACT_POLL_TRIGGER=0

# auto_compact_poll_pass
#
# issue #210: periodic poll-tick trigger for maybe_auto_compact, called from
# run_auto_compact_poll_loop's own dedicated background process on its own
# AUTO_COMPACT_TICK_SECS cadence. Exists because the wake-path trigger
# (on_outcome -> maybe_auto_compact, above)
# only ever runs right before a coord.wake — during a long purely
# interactive stretch (the human driving the coordinator directly, no
# worker ever finishing), on_outcome never fires, so a coordinator can grow
# unbounded past AUTO_COMPACT_THRESHOLD_TOKENS with nothing to catch it.
# This tick is that catch.
#
# Cooldown-gated (AUTO_COMPACT_COOLDOWN_SECS) so a probe that hasn't
# refreshed yet right after a compact doesn't read as still-over-threshold
# on the very next tick and re-inject /compact into a pane that's simply
# waiting for its statusline to catch up — see LAST_AUTO_COMPACT_POLL_
# TRIGGER above. The wake-path trigger has no equivalent cooldown, by
# design: wake events are already rate-limited by DEBOUNCE_SECS and only
# ever happen when a worker actually finishes, so adding one there would
# only add a way for it to (incorrectly) skip a legitimate wake-time
# compact — see maybe_auto_compact's header comment: "wake-path behavior
# unchanged" is a hard requirement of issue #210, not just a nice-to-have.
#
# Detects whether THIS call actually attempted a compaction (rather than
# skipping under threshold, which needs no cooldown) by checking whether it
# added a bare "coord.compact " line to events.log — log_event's category
# field is fixed-width-padded (see format_event_line's comment on the same
# distinction), so "coord.compact " (with the trailing space) matches only
# the literal injection event, never coord.compact.skip/.timeout/.done/
# .ineffective/.verify_skip (all of which have a "." immediately after
# "compact", not a space). A bare coord.compact line is written the moment
# a compaction is ATTEMPTED (threshold exceeded, pane idle) — before the
# blocking wait for it to start/finish/verify — so this correctly starts
# the cooldown whether the attempt goes on to finish cleanly or turns out
# coord.compact.ineffective; either way, re-firing immediately would be
# thrash, not progress.
#
# The grep also requires "trigger=poll" specifically, not just a bare
# coord.compact line — maybe_auto_compact's own flock (issue #210) keeps a
# concurrent wake-triggered attempt from running WHILE this call holds the
# lock, but a wake can still log its own "trigger=wake" coord.compact line
# in the tiny unlocked gap between maybe_auto_compact returning above and
# the "after" line count being read below. Scoping the grep to this call's
# own trigger avoids the cooldown being armed by someone else's compact.
auto_compact_poll_pass() {
    [ "$AUTO_COMPACT" = "1" ] || return 0

    local now
    now=$(date +%s)
    if [ "$LAST_AUTO_COMPACT_POLL_TRIGGER" -gt 0 ] \
        && [ $((now - LAST_AUTO_COMPACT_POLL_TRIGGER)) -lt "$AUTO_COMPACT_COOLDOWN_SECS" ]; then
        log_event coord.compact.skip "reason=cooldown trigger=poll"
        return 0
    fi

    local before after
    before=$(wc -l < "$EVENTS_LOG" 2>/dev/null || echo 0)
    maybe_auto_compact poll
    after=$(wc -l < "$EVENTS_LOG" 2>/dev/null || echo 0)
    if [ "$after" -gt "$before" ] \
        && tail -n "$((after - before))" "$EVENTS_LOG" 2>/dev/null | grep -q 'coord.compact  .*trigger=poll'; then
        LAST_AUTO_COMPACT_POLL_TRIGGER=$now
    fi
}

# --- Worker auto-compact (issue #226) ---------------------------------------
#
# Generalizes the coordinator's maybe_auto_compact above to every `iss-*`
# worker window. See the WORKER_AUTO_COMPACT header comment for the full
# design rationale (1M-window models, why the pane is parsed instead of a
# probe file, the wrap-up hysteresis). The pane-injection mechanism
# (load-buffer + paste-buffer -d + send-keys Enter, no trailing newline in
# the pasted buffer) is identical to maybe_auto_compact's — see that
# function's comments for why.

# worker_pane_state <window>
#
# Same classification as coordinator_pane_state, parameterized by window
# name instead of hardcoded "coordinator": "absent" (no session or no such
# window), "shell" (foreground process is a bare shell — nothing live to
# compact — this is the normal state for a parked worker sitting at
# run_idle_shell's bash prompt between tasks), or "cli" (a CLI process,
# e.g. claude, is in the foreground — compaction may be possible, subject
# to worker_pane_busy).
worker_pane_state() {
    local win="$1"
    tmux has-session -t "$SESSION_NAME" 2>/dev/null || { echo absent; return; }
    tmux list-windows -t "$SESSION_NAME" -F '#W' 2>/dev/null | grep -qx "$win" || { echo absent; return; }
    local pane_cmd
    pane_cmd="$(tmux list-panes -t "$SESSION_NAME:$win" -F '#{pane_current_command}' 2>/dev/null | head -1)" || pane_cmd=""
    case "$pane_cmd" in
        bash|zsh|sh|fish|"") echo shell ;;
        *)                   echo cli ;;
    esac
}

# worker_pane_busy <window>
#
# True (rc 0) if the window's currently rendered content matches
# WORKER_COMPACT_BUSY_PATTERN — mid-turn (or at the exit-confirmation
# prompt) rather than idle. Same technique as coordinator_pane_busy /
# check-stuck-workers.sh's detect_state(), parameterized by window.
worker_pane_busy() {
    local win="$1" content clean
    content="$(tmux capture-pane -t "$SESSION_NAME:$win" -p 2>/dev/null)" || return 1
    clean="$(printf '%s\n' "$content" | sed 's/\x1b\[[0-9;?]*[A-Za-z]//g; s/\x1b\][^\x07]*\x07//g; s/\x1b[()][AB012]//g; s/\r/\n/g')"
    printf '%s\n' "$clean" | LC_ALL=C grep -qE "$WORKER_COMPACT_BUSY_PATTERN"
}

# worker_pane_ctx_used <window>
#
# Echoes the worker's last-rendered used-token count and returns 0, or
# returns 1 with no output when nothing parseable is on screen. Unlike the
# coordinator's probe_ctx_used, there is no probe file to read (a worker's
# statusline runs inside its docker container and writes to a path the host
# can't see — no /tmp or $XDG_RUNTIME_DIR bind-mount; see sandbox.sh's
# MOUNTS array) — so this parses statusline-with-context.sh's OWN rendered
# output straight out of `tmux capture-pane`: "ctx: <used>/<total> (<pct>%)"
# where <used>/<total> are each an integer optionally suffixed k (×1000) or
# M (×1000000), per that script's fmt_tokens(). No staleness check is
# needed the way the probe file needs one — whatever's currently on screen
# IS current; if the statusline hasn't rendered at all (script not
# installed, or the "?" fallback because Claude Code's JSON schema didn't
# match any of its jq paths), there's simply no match and this fails
# closed, same fail-open-to-skip contract as probe_ctx_used.
worker_pane_ctx_used() {
    local win="$1" content clean line
    content="$(tmux capture-pane -t "$SESSION_NAME:$win" -p 2>/dev/null)" || return 1
    clean="$(printf '%s\n' "$content" | sed 's/\x1b\[[0-9;?]*[A-Za-z]//g; s/\x1b\][^\x07]*\x07//g; s/\x1b[()][AB012]//g; s/\r/\n/g')"
    # tail -1: if the pattern somehow appears more than once in the visible
    # screen (shouldn't normally happen — the statusline is one line — but
    # scrollback wrap or a stale duplicate render shouldn't pick the wrong
    # one), the most recently rendered occurrence is the last line matched.
    line="$(printf '%s\n' "$clean" | LC_ALL=C grep -oE 'ctx: [0-9]+[kM]?/[0-9]+[kM]?[[:space:]]*\([0-9]+%\)' | tail -1)"
    [ -n "$line" ] || return 1
    [[ "$line" =~ ctx:\ ([0-9]+)([kM]?)/ ]] || return 1
    local num="${BASH_REMATCH[1]}" suffix="${BASH_REMATCH[2]}"
    case "$suffix" in
        M) echo $((num * 1000000)) ;;
        k) echo $((num * 1000)) ;;
        *) echo "$num" ;;
    esac
}

# worker_pane_ctx_window <window>
#
# Sibling of worker_pane_ctx_used() above, parsing the SAME rendered
# "ctx: <used>/<total> (<pct>%)" statusline text for the DENOMINATOR instead
# of the numerator — the worker model's own context-window size, used by
# worker_compact_effective_threshold() to scale the compact trigger (issue
# #259). Echoes the parsed window size and returns 0, or returns 1 with no
# output on the same failure modes as worker_pane_ctx_used() (nothing
# parseable on screen, or the "?" fallback). Deliberately a separate
# capture-pane + parse rather than sharing state with worker_pane_ctx_used()
# — same one-concern-per-function, no-shared-mutable-state convention as
# worker_pane_busy()/worker_pane_ctx_used() already follow in this file.
worker_pane_ctx_window() {
    local win="$1" content clean line
    content="$(tmux capture-pane -t "$SESSION_NAME:$win" -p 2>/dev/null)" || return 1
    clean="$(printf '%s\n' "$content" | sed 's/\x1b\[[0-9;?]*[A-Za-z]//g; s/\x1b\][^\x07]*\x07//g; s/\x1b[()][AB012]//g; s/\r/\n/g')"
    line="$(printf '%s\n' "$clean" | LC_ALL=C grep -oE 'ctx: [0-9]+[kM]?/[0-9]+[kM]?[[:space:]]*\([0-9]+%\)' | tail -1)"
    [ -n "$line" ] || return 1
    [[ "$line" =~ /([0-9]+)([kM]?)[[:space:]]*\( ]] || return 1
    local num="${BASH_REMATCH[1]}" suffix="${BASH_REMATCH[2]}"
    case "$suffix" in
        M) echo $((num * 1000000)) ;;
        k) echo $((num * 1000)) ;;
        *) echo "$num" ;;
    esac
}

# worker_compact_effective_threshold <window>
#
# Echoes "<base-threshold> <wrapup-threshold>" (always succeeds — this is
# pure arithmetic over WORKER_COMPACT_* env vars plus whatever
# worker_pane_ctx_window() could parse, never a pane/tmux failure mode of its
# own). base-threshold = min(WORKER_COMPACT_PCT% of the worker's parsed
# context window, WORKER_COMPACT_THRESHOLD_CAP_TOKENS); falls back to the
# flat WORKER_COMPACT_THRESHOLD_TOKENS when the window denominator isn't
# parseable (statusline not installed/rendered, or the "?" fallback) — same
# fail-open contract as every other pane-parsing helper in this file.
# wrapup-threshold = base-threshold + the CONFIGURED gap (WORKER_COMPACT_
# WRAPUP_THRESHOLD_TOKENS - WORKER_COMPACT_THRESHOLD_TOKENS, 150000 by
# default), preserved verbatim rather than recomputed as its own percentage
# — issue #259's "keep wrap-up headroom meaningfully above the base"
# criterion, satisfied by holding the absolute gap constant as the base
# scales up with the window, and this same formula reduces to today's exact
# 150000/300000 defaults when the denominator can't be parsed (base falls
# back to WORKER_COMPACT_THRESHOLD_TOKENS, so base+gap == WORKER_COMPACT_
# WRAPUP_THRESHOLD_TOKENS unchanged).
worker_compact_effective_threshold() {
    local win="$1" window base gap
    gap=$(( WORKER_COMPACT_WRAPUP_THRESHOLD_TOKENS - WORKER_COMPACT_THRESHOLD_TOKENS ))
    if window="$(worker_pane_ctx_window "$win")" && [ -n "$window" ]; then
        base=$(( window * WORKER_COMPACT_PCT / 100 ))
        [ "$base" -gt "$WORKER_COMPACT_THRESHOLD_CAP_TOKENS" ] && base="$WORKER_COMPACT_THRESHOLD_CAP_TOKENS"
    else
        base="$WORKER_COMPACT_THRESHOLD_TOKENS"
    fi
    echo "$base $((base + gap))"
}

# worker_has_open_pr <worktree-dir>
#
# True (rc 0) if any status file in <worktree>/.swarm/tasks/status/ (the
# worker.md "queue-v2" convention — task_id.json, non-null "pr" field once
# a PR is opened; see prompts/worker.md and worker-listener.sh's
# print_completion_block, which reads the same file for its own pane
# output) records an open PR. This is the "wrap-up" signal used to raise
# the compact threshold — a worker that already has a PR up may be close to
# landing, so it takes more headroom (WORKER_COMPACT_WRAPUP_THRESHOLD_TOKENS)
# before this feature interrupts it with a compact. Deliberately reading
# the status file directly (host-visible — the worktree is bind-mounted at
# the same path in and out of the container) rather than parsing "PR #NNN"
# out of pane text: the status file is the authoritative source
# worker-listener.sh itself uses, and is already read this way elsewhere in
# this script (see status_poll_pass/maybe_run_check above).
worker_has_open_pr() {
    local wt_dir="$1"
    [ "$HAVE_JQ" = "1" ] || return 1
    local f has_pr
    shopt -s nullglob
    for f in "$wt_dir/.swarm/tasks/status"/*.json; do
        case "$f" in *.check.json) continue ;; esac
        has_pr=$(jq -r 'if (.pr // null) == null then "" else "1" end' "$f" 2>/dev/null) || continue
        if [ "$has_pr" = "1" ]; then
            shopt -u nullglob
            return 0
        fi
    done
    shopt -u nullglob
    return 1
}

# worker_task_done <window> <worktree-dir>
#
# True (rc 0) if the worker owning <window> has already finished its
# CURRENT task (issue #252's "after-the-fact compact" fix — see this file's
# WORKER_AUTO_COMPACT header comment for the full timeline this addresses).
# Checked in order of how early each signal becomes available, since the
# last one is the ONLY signal that exists during the ~1-minute window
# before the first two land:
#   (a) an outcome file already landed in the worktree's
#       `.swarm/tasks/done/` — worker-listener.sh's final write for this
#       task; the watcher's own on_outcome/WATCHER_AUTOCLOSE path will reap
#       this window shortly, so compacting it first is pure waste;
#   (b) the worker's status file (queue-v2 protocol, same file
#       worker_has_open_pr reads above) reports "ready-for-review" or
#       "done-no-pr" — terminal for the current task. Deliberately NOT
#       "blocked": a blocked worker is idle awaiting a human decision but
#       may still resume once unblocked, so it stays a normal compact
#       candidate rather than being permanently skipped;
#   (c) the pane itself shows worker-listener.sh's print_completion_block
#       output (the "TASK COMPLETE"/"TASK FAILED" banner) — the only
#       signal available before (a) or (b) land; see that function's
#       header comment for why this exact substring is load-bearing there
#       too.
#
# (a) and (b) are guarded by a `.swarm/tasks/processing/` check first: a
# worktree that's been requeued (worker.md's "Follow up here: requeue.sh")
# keeps EVERY past task's done/status files on disk forever — nothing ever
# deletes them. Without this guard, a worktree that completed task #1 weeks
# ago would read as permanently task_done for task #2, #3, ... every
# follow-up ever dispatched into it, silently disabling WORKER_AUTO_COMPACT
# for that window's entire remaining life. claim_next_task() only clears
# processing/ for an entry once write_outcome/print_completion_block have
# already run for THAT entry (worker-listener.sh's main loop), so a
# non-empty processing/ reliably means "a task is currently claimed and has
# NOT concluded yet" regardless of what's sitting in done/ or status/ from
# earlier work. (c) is deliberately NOT gated the same way — it exists
# specifically to catch the window BEFORE processing/ empties, so gating it
# on processing/ being empty would defeat its own purpose; the residual
# risk of stale completion-block text lingering into a genuinely new task's
# first few lines of screen output is bounded and self-correcting (new
# output pushes it out of the visible, unscrolled capture-pane view).
#
# Fails open like every other check in this file: an unreadable done/
# dir, missing jq, or no tmux session just falls through to "not done".
worker_task_done() {
    local win="$1" wt_dir="$2"

    if [ -z "$(find "$wt_dir/.swarm/tasks/processing" -maxdepth 1 -type f 2>/dev/null | head -1)" ]; then
        local f
        shopt -s nullglob
        for f in "$wt_dir/.swarm/tasks/done"/*.ok.json "$wt_dir/.swarm/tasks/done"/*.err.json; do
            shopt -u nullglob
            return 0
        done
        shopt -u nullglob

        if [ "$HAVE_JQ" = "1" ]; then
            local state
            shopt -s nullglob
            for f in "$wt_dir/.swarm/tasks/status"/*.json; do
                case "$f" in *.check.json) continue ;; esac
                state=$(jq -r '.state // empty' "$f" 2>/dev/null) || continue
                case "$state" in
                    ready-for-review|done-no-pr)
                        shopt -u nullglob
                        return 0
                        ;;
                esac
            done
            shopt -u nullglob
        fi
    fi

    local content clean
    content="$(tmux capture-pane -t "$SESSION_NAME:$win" -p 2>/dev/null)" || return 1
    clean="$(printf '%s\n' "$content" | sed 's/\x1b\[[0-9;?]*[A-Za-z]//g; s/\x1b\][^\x07]*\x07//g; s/\x1b[()][AB012]//g; s/\r/\n/g')"
    # Anchored on the literal completion-block line shape from
    # worker-listener.sh's print_completion_block() — "  TASK COMPLETE    exit=0    duration=42s"
    # — not just the bare phrase. An unanchored match on "TASK (COMPLETE|FAILED)"
    # would also fire if a worker's own pane happened to display that phrase
    # via source/test-fixture content (e.g. this repo's own worker-listener.sh
    # or test-shape-stuck-workers.sh), falsely marking an in-progress worker done.
    printf '%s\n' "$clean" | LC_ALL=C grep -qE '^[[:space:]]*TASK (COMPLETE|FAILED)[[:space:]]+exit='
}

# WORKER_COMPACT_LAST_FAIL / WORKER_COMPACT_FAIL_COUNT / WORKER_COMPACT_GAVE_UP
# (issue #252)
#
# Per-window backoff bookkeeping, keyed by issue number. In-memory
# associative arrays, not files — exactly like ORPHAN_PR_LOGGED and
# LAST_AUTO_COMPACT_POLL_TRIGGER elsewhere in this file: only ever read/
# written from run_worker_compact_loop's own dedicated background process,
# so a same-process global is sufficient, and a watcher restart correctly
# clears all three and gives every window a fresh start.
declare -A WORKER_COMPACT_LAST_FAIL=()
declare -A WORKER_COMPACT_FAIL_COUNT=()
declare -A WORKER_COMPACT_GAVE_UP=()

# worker_compact_record_failure <issue>
#
# Called after a maybe_worker_compact attempt ends in `timeout` (either
# phase) or `ineffective` — the two verdicts that mean the injection
# didn't do what it was supposed to (see WORKER_COMPACT_BACKOFF_SECS'
# header comment for the runtime-log evidence this fixes). Records the
# failure timestamp (starts the WORKER_COMPACT_BACKOFF_SECS cooldown) and
# bumps the consecutive-failure count; once that count reaches
# WORKER_COMPACT_MAX_FAILURES, gives up on this window for good — one loud
# warning, then silence (see the WORKER_COMPACT_GAVE_UP check at the top of
# maybe_worker_compact).
worker_compact_record_failure() {
    local issue="$1" now count
    now=$(date +%s)
    WORKER_COMPACT_LAST_FAIL[$issue]=$now
    count=$(( ${WORKER_COMPACT_FAIL_COUNT[$issue]:-0} + 1 ))
    WORKER_COMPACT_FAIL_COUNT[$issue]=$count
    if [ "$count" -ge "$WORKER_COMPACT_MAX_FAILURES" ]; then
        WORKER_COMPACT_GAVE_UP[$issue]=1
        echo "[$(date +%T)] WARNING: worker iss-$issue failed /compact $count times in a row (timeout or ineffective every attempt) — giving up on this window; investigate why the injection isn't taking effect before it repeats"
        log_event worker.compact.giving_up "issue=$issue failures=$count"
    fi
}

# worker_compact_record_success <issue>
#
# Called after a compaction that neither timed out nor came back
# ineffective — a real success, so any prior backoff/near-give-up state no
# longer applies and is cleared.
worker_compact_record_success() {
    local issue="$1"
    unset "WORKER_COMPACT_LAST_FAIL[$issue]" "WORKER_COMPACT_FAIL_COUNT[$issue]" "WORKER_COMPACT_GAVE_UP[$issue]"
}

# maybe_worker_compact <window>
#
# Per-window counterpart to maybe_auto_compact, called by worker_compact_pass
# below for each `iss-*` window on every WORKER_COMPACT_SCAN_SECS sweep.
# Fails open at every step, exactly like maybe_auto_compact — a missing
# precondition, unparseable pane text, or either timeout just returns 0 and
# leaves the worker alone this cycle. This is purely an optimization; it
# never blocks or otherwise gates the worker's own progress.
maybe_worker_compact() {
    local win="$1" issue wt_dir
    issue="${win#iss-}"
    [[ "$issue" =~ ^[0-9]+$ ]] || return 0
    wt_dir="$WORKSPACE/wt-issue-$issue"

    local state
    state="$(worker_pane_state "$win")" || state="absent"
    [ "$state" = "cli" ] || return 0   # parked at a bash prompt, or gone — nothing live to compact

    if worker_task_done "$win" "$wt_dir"; then
        log_event worker.compact.skip "issue=$issue reason=task_done"
        return 0   # about to be reaped, or just finished — see worker_task_done's header comment
    fi

    if [ "${WORKER_COMPACT_GAVE_UP[$issue]:-0}" = "1" ]; then
        return 0   # already logged the one worker.compact.giving_up warning — stay silent from here on
    fi

    local bo_now bo_last_fail
    bo_now=$(date +%s)
    bo_last_fail="${WORKER_COMPACT_LAST_FAIL[$issue]:-0}"
    if [ "$bo_last_fail" -gt 0 ] && [ $(( bo_now - bo_last_fail )) -lt "$WORKER_COMPACT_BACKOFF_SECS" ]; then
        log_event worker.compact.skip "issue=$issue reason=backoff remaining=$(( WORKER_COMPACT_BACKOFF_SECS - (bo_now - bo_last_fail) ))s"
        return 0
    fi

    if worker_pane_busy "$win"; then
        log_event worker.compact.skip "issue=$issue reason=pane_busy"
        return 0   # don't race a live turn — see docs/tmux-as-channel.md on send-keys races
    fi

    local used
    used="$(worker_pane_ctx_used "$win")" || {
        log_event worker.compact.skip "issue=$issue reason=no_ctx_parsed"
        return 0
    }

    local base_threshold wrapup_threshold
    read -r base_threshold wrapup_threshold < <(worker_compact_effective_threshold "$win")
    local threshold="$base_threshold" wrapup=0
    if worker_has_open_pr "$wt_dir"; then
        threshold="$wrapup_threshold"
        wrapup=1
    fi

    [ "$used" -ge "$threshold" ] || return 0   # under threshold — the common case

    echo "[$(date +%T)] worker $win context at ${used} tokens (>= ${threshold}, wrapup=$wrapup) — compacting before next turn..."
    log_event worker.compact "issue=$issue used=$used threshold=$threshold wrapup=$wrapup"

    if [ "$DRY_RUN" = "1" ]; then
        echo "[DRY] would inject /compact into $SESSION_NAME:$win, wait for it to finish, then nudge to continue"
        return 0
    fi

    # Buffer names scoped per-issue (unlike the coordinator's single
    # llm-coord-autocompact buffer) — worker_compact_pass may be mid-sweep
    # across several windows, and tmux buffer names are session-global, so
    # a shared name would race between concurrent windows' load/paste pairs.
    local tmp_compact
    tmp_compact=$(mktemp) || { log_event worker.compact.skip "issue=$issue reason=mktemp_failed"; return 0; }
    printf '/compact' > "$tmp_compact" 2>/dev/null || true
    tmux load-buffer -b "llm-worker-autocompact-$issue" "$tmp_compact" 2>/dev/null || true
    tmux paste-buffer -b "llm-worker-autocompact-$issue" -t "$SESSION_NAME:$win" -d 2>/dev/null || true
    tmux send-keys -t "$SESSION_NAME:$win" Enter 2>/dev/null || true
    rm -f "$tmp_compact" 2>/dev/null || true

    # Wait for compaction to actually start (busy indicator appears).
    local waited=0
    while ! worker_pane_busy "$win"; do
        sleep "$WORKER_COMPACT_POLL_SECS"
        waited=$((waited + WORKER_COMPACT_POLL_SECS))
        if [ "$waited" -ge "$WORKER_COMPACT_START_TIMEOUT_SECS" ]; then
            log_event worker.compact.timeout "issue=$issue phase=start waited=${waited}s"
            worker_compact_record_failure "$issue"
            return 0
        fi
    done

    # Now wait for it to finish (busy indicator clears).
    waited=0
    while worker_pane_busy "$win"; do
        sleep "$WORKER_COMPACT_POLL_SECS"
        waited=$((waited + WORKER_COMPACT_POLL_SECS))
        if [ "$waited" -ge "$WORKER_COMPACT_FINISH_TIMEOUT_SECS" ]; then
            log_event worker.compact.timeout "issue=$issue phase=finish waited=${waited}s"
            worker_compact_record_failure "$issue"
            return 0
        fi
    done

    echo "[$(date +%T)] worker $win compaction done (${waited}s) — nudging to continue"
    log_event worker.compact.done "issue=$issue waited=${waited}s"

    # Poll for the pane to show SOME parseable ctx reading post-compaction,
    # rather than trusting a fixed sleep — the statusline's render cadence
    # isn't guaranteed to land within any fixed window. This is NOT quite
    # the same freshness test as maybe_auto_compact's probe-mtime loop:
    # pane text carries no mtime, so there's no way to tell "genuinely
    # re-rendered with an unchanged value" from "stale leftover frame" —
    # the busy indicator having just cleared (confirmed above) is the only
    # freshness evidence available, and the first sleep in this loop is
    # deliberately BEFORE the first read to give that redraw a moment to
    # land. Any parseable value ends the wait; only the total absence of
    # one within the timeout counts as inconclusive (verify_skip) — an
    # unchanged-but-parseable value is treated as evidence the compact
    # didn't help (ineffective), same verdict maybe_auto_compact reaches
    # when its mtime-fresh probe shows an unchanged value.
    local verify_waited=0 used_after=""
    while [ "$verify_waited" -lt "$WORKER_COMPACT_VERIFY_TIMEOUT_SECS" ]; do
        sleep "$WORKER_COMPACT_POLL_SECS"
        verify_waited=$((verify_waited + WORKER_COMPACT_POLL_SECS))
        used_after="$(worker_pane_ctx_used "$win")" && break
        used_after=""
    done

    if [ -z "$used_after" ]; then
        log_event worker.compact.verify_skip "issue=$issue reason=ctx_not_refreshed waited=${verify_waited}s"
        # Inconclusive, not a confirmed failure — no backoff/failure-count
        # bump either way; see WORKER_COMPACT_BACKOFF_SECS's header comment.
    elif [ "$used_after" -ge "$used" ]; then
        echo "[$(date +%T)] WARNING: worker $win context did not drop after /compact (before=$used after=$used_after) — the injected command may not have been recognized as a slash command; investigate before this repeats every sweep"
        log_event worker.compact.ineffective "issue=$issue before=$used after=$used_after"
        worker_compact_record_failure "$issue"
    else
        worker_compact_record_success "$issue"
    fi

    # /compact leaves the agent idle with a summarized context — without a
    # nudge it would just sit at the prompt indefinitely instead of
    # resuming work. Same injection mechanism as /compact itself, just a
    # different buffer name (avoids clobbering the one still in flight
    # above on some backend that reuses buffer content after paste).
    local tmp_nudge
    tmp_nudge=$(mktemp) || return 0
    printf '%s' "$WORKER_COMPACT_NUDGE_PROMPT" > "$tmp_nudge" 2>/dev/null || true
    tmux load-buffer -b "llm-worker-nudge-$issue" "$tmp_nudge" 2>/dev/null || true
    tmux paste-buffer -b "llm-worker-nudge-$issue" -t "$SESSION_NAME:$win" -d 2>/dev/null || true
    tmux send-keys -t "$SESSION_NAME:$win" Enter 2>/dev/null || true
    rm -f "$tmp_nudge" 2>/dev/null || true
}

# worker_compact_pass
#
# Enumerates every `iss-*` window in the session and runs maybe_worker_compact
# against each. Called from run_worker_compact_loop's own dedicated
# background process on its own WORKER_COMPACT_SCAN_SECS interval — kept
# separate from run_watch_timer_loop's tighter status/PR-poll loop because a
# single compaction can block for minutes; see that function's header
# comment for the full rationale. A missing session (no workers provisioned
# yet) or zero iss-* windows is the common case and simply no-ops — this
# always fails open, same as every other pass in this file.
worker_compact_pass() {
    [ "$WORKER_AUTO_COMPACT" = "1" ] || return 0
    tmux has-session -t "$SESSION_NAME" 2>/dev/null || return 0

    local windows win
    windows="$(tmux list-windows -t "$SESSION_NAME" -F '#{window_name}' 2>/dev/null | grep '^iss-' || true)"
    [ -n "$windows" ] || return 0

    while IFS= read -r win; do
        [ -n "$win" ] || continue
        maybe_worker_compact "$win"
    done <<< "$windows"
}

# Trigger logic — called when a NEW outcome JSON path is observed
on_outcome() {
    local path="$1"
    local now issue outcome
    now=$(date +%s)

    # Parse outcome filename: <task-id>-<issue>.<ok|err>.json
    issue=$(basename "$path" | sed -E 's/.*-([0-9]+)\.(ok|err)\.json$/\1/')
    case "$path" in
        *.ok.json)  outcome=ok ;;
        *.err.json) outcome=err ;;
        *)          outcome=unknown ;;
    esac
    log_event worker.finish "issue=$issue outcome=$outcome path=$path"

    # Audit posting fires for EVERY outcome (not gated by wake-debounce).
    # The sweep is idempotent via .posted markers, so repeated calls are
    # cheap, and we don't want auditing to be coalesced — every finished
    # task should get its comment posted.
    if [ "$POST_OUTCOMES" = "1" ]; then
        if [ "$DRY_RUN" = "1" ]; then
            echo "[$(date +%T)] [DRY] would: $SWEEP $PROJECT_DIR"
            log_event sweep.dry "issue=$issue"
        else
            echo "[$(date +%T)] sweep: posting outcomes…"
            log_event sweep.run "issue=$issue"
            "$SWEEP" "$PROJECT_DIR" || {
                echo "[$(date +%T)] WARN: sweep returned non-zero (continuing watch)"
                log_event sweep.error "issue=$issue"
            }
        fi
    fi

    if [ $((now - LAST_WAKE)) -lt "$DEBOUNCE_SECS" ]; then
        echo "[$(date +%T)] outcome: $path — within debounce window (${DEBOUNCE_SECS}s), skipping wake"
        log_event coord.wake.skip "issue=$issue reason=debounce window=${DEBOUNCE_SECS}s"
        return
    fi

    # Free slots from parked + PR-safe workers (PRs merged/closed) before
    # the coordinator wakes — otherwise its slot computation sees stale
    # alive-worker counts and reports cap-reached when wave 2 should fire.
    if [ "$WATCHER_AUTOCLOSE" = "1" ]; then
        echo "[$(date +%T)] running autoclose pass before wake..."
        cleanup_eligible_workers outcome
    fi

    maybe_auto_compact wake

    echo "[$(date +%T)] outcome: $path"
    echo "[$(date +%T)] waking coordinator..."
    log_event coord.wake "issue=$issue trigger=$(basename "$path")"

    if [ "$DRY_RUN" = "1" ]; then
        echo "[DRY] would: cd $PROJECT_DIR && NON_INTERACTIVE=1 $LLM_START \"$WAKE_PROMPT\""
    else
        # Run llm-start.sh in a subshell so its `set -e` doesn't kill us.
        # NON_INTERACTIVE=1 prevents auto-attach; coordinator runs detached
        # in its tmux session.
        ( cd "$PROJECT_DIR" && NON_INTERACTIVE=1 "$LLM_START" "$WAKE_PROMPT" ) || {
            echo "[$(date +%T)] WARN: coordinator wake exited non-zero (continuing watch)"
            log_event coord.wake.error "issue=$issue"
        }
    fi
    LAST_WAKE=$now

    if [ "$ONCE" = "1" ]; then
        echo "[$(date +%T)] ONCE=1 — exiting after first wake."
        log_event watch.exit "reason=once"
        # Brief grace period so the pane-echo tail (issue #38) catches up on
        # this burst of writes (worker.finish, watch.autoclose, coord.wake,
        # watch.exit) before cleanup_on_exit kills it — without this, a
        # fast ONCE=1 exit can race past tail's polling interval and
        # silently drop the last few lines from stdout (the log file
        # itself is unaffected either way). 1.5s (not 0.2s) deliberately:
        # this smoke-test-only path has to clear tail's WORST-CASE
        # interval, not the GNU --sleep-interval=0.2 fast path above — a
        # non-GNU tail without that flag falls back to its own default
        # (commonly ~1.0s), and ONCE=1 is never on the real long-running
        # daemon's hot path, so the extra latency here is free.
        [ "$WATCHER_QUIET" = "1" ] || sleep 1.5
        exit 0
    fi
}

# ---------------------------------------------------------------------------
# Backend: inotify
# ---------------------------------------------------------------------------
run_inotify() {
    # Watch the workspace (parent of project) recursively, filtering events
    # to only outcomes inside wt-issue-*/.swarm/tasks/done/. The listener
    # does `mv processing/X.md done/X.md` followed by writing done/X.json —
    # both surface as create/moved_to events.
    #
    # --exclude noisy dirs to keep watch count low.
    inotifywait -m -r \
        --exclude '/(\.git|node_modules|build|target|\.gradle|dist|out|\.next|\.venv|venv)(/|$)' \
        -e create -e moved_to \
        --format '%w%f' \
        "$WORKSPACE" 2>/dev/null \
    | while IFS= read -r path; do
        case "$path" in
            */wt-issue-*/.swarm/tasks/done/*.ok.json|*/wt-issue-*/.swarm/tasks/done/*.err.json)
                dispatch_outcome "$path"
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Backend: polling (find)
# ---------------------------------------------------------------------------
run_poll() {
    # Build a baseline of currently-known outcome JSONs so we don't fire
    # for anything that existed before the watcher started.
    # NOTE: seen_file is intentionally script-global (no `local`) so the
    # shared EXIT/INT/TERM trap (set once, near the bottom of the script —
    # see cleanup_on_exit) can reach it even if a signal arrives outside of
    # run_poll's stack frame. Deliberately NOT setting a trap here: bash
    # traps are process-wide, so a second `trap ... EXIT` here would
    # silently replace the one that also kills the background timer loop.
    seen_file=$(mktemp -t coord-watch-seen-XXXXXX)

    # Scan only wt-issue-*/.swarm/tasks/done dirs under WORKSPACE. The glob
    # may expand to nothing if no worker worktrees exist yet — handle that
    # gracefully via nullglob so the find call gets an empty arg list.
    scan_outcomes() {
        local done_dirs=()
        shopt -s nullglob
        done_dirs=("$WORKSPACE"/wt-issue-*/.swarm/tasks/done)
        shopt -u nullglob
        if [ "${#done_dirs[@]}" -eq 0 ]; then
            return 0   # no worker worktrees — emit empty
        fi
        find "${done_dirs[@]}" -maxdepth 1 \
            \( -name '*.ok.json' -o -name '*.err.json' \) -print 2>/dev/null \
            | sort -u
    }

    scan_outcomes > "$seen_file"

    while true; do
        local current diff_new
        current=$(scan_outcomes)

        # New paths = in current, not in seen. Guard against the shutdown
        # race where the EXIT trap removes seen_file mid-iteration.
        [ -f "$seen_file" ] || break
        diff_new=$(comm -23 <(echo "$current") "$seen_file" 2>/dev/null || true)
        if [ -n "$diff_new" ]; then
            while IFS= read -r path; do
                [ -z "$path" ] && continue
                dispatch_outcome "$path"
            done <<< "$diff_new"
            echo "$current" > "$seen_file"
        fi

        sleep "$POLL_SECS"
    done
}

# ---------------------------------------------------------------------------
# Timer loop startup (issue #119) — independent of the outcome-driven
# backend selected above. Started here (after every function it calls is
# defined, and after the backend case below so shutdown ordering doesn't
# matter) so it's live before we block in run_inotify/run_poll.
# WATCH_TIMER_PID / WORKER_COMPACT_TIMER_PID / AUTO_COMPACT_POLL_TIMER_PID
# are pre-declared (empty) up near the shared trap installation, above —
# this just fills them in when each feature is on. Three separate processes
# (issues #226 and #210) — see run_worker_compact_loop's and
# run_auto_compact_poll_loop's header comments for why those sweeps don't
# share run_watch_timer_loop's process.
# ---------------------------------------------------------------------------
if [ "$WATCH_PR_POLL_SECS" -gt 0 ] || [ "$WATCH_CHECK_ON_DONE" = "1" ] || [ "$WATCH_ORPHAN_SWEEP_SECS" -gt 0 ]; then
    run_watch_timer_loop &
    WATCH_TIMER_PID=$!
    log_event watch.timer.start "pr_poll_secs=$WATCH_PR_POLL_SECS check_on_done=$WATCH_CHECK_ON_DONE orphan_sweep_secs=$WATCH_ORPHAN_SWEEP_SECS"
fi
if [ "$WORKER_AUTO_COMPACT" = "1" ]; then
    run_worker_compact_loop &
    WORKER_COMPACT_TIMER_PID=$!
    log_event watch.timer.start "worker_auto_compact=$WORKER_AUTO_COMPACT scan_secs=$WORKER_COMPACT_SCAN_SECS"
fi
if [ "$AUTO_COMPACT" = "1" ] && [ "$AUTO_COMPACT_TICK_SECS" -gt 0 ]; then
    run_auto_compact_poll_loop &
    AUTO_COMPACT_POLL_TIMER_PID=$!
    log_event watch.timer.start "auto_compact_tick_secs=$AUTO_COMPACT_TICK_SECS auto_compact_cooldown_secs=$AUTO_COMPACT_COOLDOWN_SECS"
fi

case "$BACKEND" in
    inotify) run_inotify ;;
    poll)    run_poll ;;
esac
