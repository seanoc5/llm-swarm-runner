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
#   coordinator-watch.sh --check-stale [project-dir]
#                           (issue #296) Cheap, one-shot: print this
#                           project's watcher state (pid, start time, script
#                           path, script mtime at launch vs. now) and exit
#                           0 FRESH (a live watcher, on-disk script unchanged
#                             since it started),
#                           1 STALE (a live watcher, but the on-disk script
#                             has changed since it started — see
#                             WATCHER_STALE_CHECK below for why this happens
#                             and for the self-check that normally catches
#                             it without needing this command run by hand),
#                           2 no state file at all (no watcher has ever run
#                             for this project-dir), or
#                           3 NOT RUNNING (a state file exists, but its
#                             recorded pid isn't alive — the watcher exited
#                             since it last wrote that file, e.g. ONCE=1, a
#                             crash, or WATCHER_STALE_CHECK's own shutdown;
#                             the state file is never removed on exit, so
#                             this liveness check is what keeps a corpse
#                             from reading as FRESH).
#                           Reads <project-dir>/.swarm/coordinator-watch.state,
#                           written by a live watcher at startup — no tmux,
#                           only a `kill -0` liveness probe (no signal sent,
#                           just existence), never touching the running
#                           daemon's actual behavior.
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
#   WATCH_OUTBOX=1          (issue #129) Also watch every worker's
#                           `.swarm/tasks/outbox/` dir. When a worker drops
#                           a message file (`*.md`, atomic mktemp+mv) there,
#                           wake the coordinator with a message-triage prompt
#                           instead of the outcome top-up prompt. This is the
#                           worker→coordinator mid-task channel: workers
#                           can't reach the coordinator's tmux socket (not
#                           mounted — docs/tmux-as-channel.md §2a), so the
#                           outbox file + this doorbell is how a worker says
#                           anything before its terminal outcome lands.
#                           Messages the coordinator has handled are archived
#                           to `outbox/processed/` (never re-triggers). Set
#                           to 0 to disable outbox watching entirely.
#   OUTBOX_WAKE_PROMPT=<text>
#                           Override the coordinator prompt used for outbox
#                           wakes. Default (built per-event) names the
#                           triggering message path and instructs a full
#                           scan of $WORKSPACE/wt-issue-*/.swarm/tasks/outbox/
#                           — so messages coalesced away by the debounce
#                           window are still picked up on the next wake.
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
#   WATCH_BG_VIOLATION_SWEEP_SECS=60
#                           (issue #298) Fallback layer for the foreground-
#                           only rule (prompts/worker.md § "Run long commands
#                           in the foreground"). sandbox.sh's
#                           CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1 (#301) is
#                           the primary, mechanical enforcement for claude
#                           workers, but a project can opt out of it
#                           (SANDBOX_ALLOW_BACKGROUND_TASKS=1) and gemini/
#                           codex have no equivalent switch at all — for
#                           those the prompt rule remains the only guard.
#                           This sweep runs from the same background timer
#                           loop as pr_poll_pass/orphan_sweep_pass above
#                           (cheap: local capture-pane only, no gh/network
#                           calls) and greps every iss-* window's rendered
#                           pane, PLUS the coordinator's own window (issue
#                           #385 — #383/#384 closed the mechanical switch for
#                           claude coordinators, but this sweep is the
#                           backstop for gemini/codex coordinators and any
#                           future path that reopens the door, and the #298
#                           incident that motivated this whole sweep was
#                           itself a coordinator pane, not a worker one), for
#                           WATCH_BG_VIOLATION_PATTERN — the background-shell
#                           UI markers Claude Code leaves behind ("Running in
#                           the background", "N shells still running" at
#                           rest). A NEW sighting (edge-triggered via the
#                           BG_VIOLATION_LOGGED dedup map, so a still-open
#                           background shell doesn't re-fire every sweep) is
#                           delivered per role: a worker window gets a
#                           `kind: fyi` message dropped into that worker's
#                           own .swarm/tasks/outbox/ — reusing the existing
#                           WATCH_OUTBOX wake path (on_message) instead of
#                           inventing a second one, so the violation reaches
#                           the coordinator's wake report the same way a
#                           worker-authored outbox message does; the
#                           coordinator window has no outbox of its own, so
#                           it gets only a watch.bg_violation events.log line
#                           and relies on prompts/coordinator.md's per-wake
#                           self-check to surface it on the next wake digest
#                           (issue #385's chosen delivery — no new wake
#                           plumbing). Set to 0 to disable. See
#                           bg_violation_sweep_pass for the detection logic
#                           and prompts/coordinator.md's existing "If a
#                           worker backgrounds anyway" / bg-violation
#                           self-check guidance for what the coordinator does
#                           once it sees this (flag it — never autoremediate
#                           a possibly mid-task worker; for its own pane,
#                           just report the finding, since there's no other
#                           agent to hand it to).
#   WATCH_BG_VIOLATION_PATTERN
#                           (issue #298) Override the grep -E pattern
#                           bg_violation_sweep_pass matches against each
#                           iss-* window's cleaned (ANSI-stripped) pane text.
#                           Defaults to the two Claude Code UI markers named
#                           above.
#   WATCH_ACTIVITY_POLL_SECS=300
#                           (issue #392) Every wake trigger above — the
#                           outcome-driven backend, WATCH_PR_POLL_SECS,
#                           WATCH_ORPHAN_SWEEP_SECS — either reacts to a file
#                           a WORKER wrote, or only looks at PRs/worktrees
#                           this swarm still has a live tmux window or
#                           worktree directory for. An operator who resolves
#                           something entirely out-of-band — merging or
#                           closing a PR, or closing an issue, straight in
#                           the GitHub web UI, for a worker that was reaped
#                           long ago — produces none of those: no new
#                           outcome.json, no live window, no worktree left to
#                           poll from. The coordinator can sit there
#                           reporting a decision as "pending your call" for
#                           however long it takes a human to next look at the
#                           pane, because nothing ever tells it the human
#                           already acted (the incident this closes: PR
#                           #1070 merged / #1064 closed in the web UI,
#                           coordinator still parked on both ~35 minutes
#                           later — issue #392).
#
#                           This runs on its own timer, independent of every
#                           reap pass above: two `gh ... list --search
#                           "<field>:>=<cursor>"` calls per tick (PRs merged,
#                           issues closed since the last tick), where the
#                           cursor is simply "when did we last check" —
#                           advanced ACTIVITY_POLL_OVERLAP_SECS BEHIND the
#                           actual query time (issue #392 self-review: gh's
#                           search index can lag the real merge/close by a
#                           few seconds, so cutting the cursor exactly at
#                           query time risks permanently skipping an item
#                           that isn't indexed yet). That overlap means the
#                           same item can appear in two consecutive polls —
#                           the ACTIVITY_ANNOUNCED_PR/_ISSUE maps (process-
#                           local, reset on watcher restart, same as every
#                           other timer-loop dedup state here) skip anything
#                           already announced. A hit wakes the coordinator
#                           (its own debounce clock, LAST_ACTIVITY_WAKE, so
#                           it can't be swallowed by an unrelated outcome/
#                           outbox wake, or swallow one) with a message
#                           naming what changed — see activity_poll_pass/
#                           on_activity. Set to 0 to disable.
#
#                           Concurrency (issue #392 self-review): unlike
#                           every prior wake trigger, on_activity fires from
#                           run_watch_timer_loop's own backgrounded subshell
#                           — a genuinely separate OS process from the main
#                           watcher process that on_outcome/on_message run
#                           in. llm-start.sh's live-REPL reprompt path
#                           (reprompt_inject) pastes through one FIXED,
#                           otherwise-unlocked tmux buffer name — safe only
#                           because every prior caller ran serialized in the
#                           same process. All three wake functions now flock
#                           COORD_WAKE_LOCK around their llm-start.sh call so
#                           at most one is ever in flight; see that lock's
#                           own header comment.
#
#                           Noise control, two checks (both applied to the
#                           merged-PR loop AND the closed-issue loop — a
#                           merged PR with "Closes #N" auto-closes issue #N
#                           too, so a merge already suppressed by either
#                           check would otherwise still slip through as a
#                           same-event "issue closed" line):
#                             - reason=skipped_self_reaped: a reap.window
#                               event for this issue number is logged at or
#                               after the poll's cursor — this swarm's OWN
#                               pr_poll_pass/cleanup_eligible_workers
#                               pipeline already reaped it in the same
#                               window, so it already knows.
#                             - reason=skipped_worktree_live (issue #392
#                               self-review): $WORKSPACE/wt-issue-<N> still
#                               exists — there's a real gap between a
#                               swarm-driven merge and reap.window's log
#                               line landing (up to WATCH_PR_POLL_SECS,
#                               longer if the kill gate defers), and a
#                               still-live worktree means pr_poll_pass's own
#                               reap machinery just hasn't reached this one
#                               yet, not that an operator acted out-of-band
#                               — exactly the case this feature (workers
#                               "reaped long ago") isn't meant to cover;
#                               left for pr_poll_pass's own next tick.
#                           Either way, this poll skips announcing it rather
#                           than waking the coordinator over its own action.
#   ACTIVITY_POLL_OVERLAP_SECS=30
#                           (issue #392) How far behind the actual query
#                           time to advance activity_poll_pass's cursor —
#                           see WATCH_ACTIVITY_POLL_SECS's header comment for
#                           why. The ACTIVITY_ANNOUNCED_PR/_ISSUE dedup maps
#                           make raising this safe against the resulting
#                           overlap; it should track how long gh's search
#                           index can realistically lag, not how noisy a
#                           larger value would be.
#   ACTIVITY_WAKE_PROMPT=(built-in)
#                           (issue #392) Override the coordinator prompt used
#                           for an activity-poll wake. Default names what
#                           activity_poll_pass found and asks the coordinator
#                           to reconcile its own picture of outstanding
#                           decisions/PRs against it.
#   WATCH_WORKTREE_SWEEP_SECS=60
#                           (issue #439) Detects a worktree that vanished
#                           without going through any blessed reap path — the
#                           SAMlytics incident: a bare `git worktree remove`
#                           (or `rm -rf`) run outside kill-worktree.sh and
#                           its callers destroys any brief still queued in
#                           that worktree's .swarm/tasks/{inbox,processing,
#                           outbox}/ with no salvage and no record at all,
#                           and today nothing notices. Every one of the
#                           three sites in this codebase that actually
#                           remove a worktree — kill-worktree.sh (covering
#                           this script's callers), reap-orphan-worktrees.sh's
#                           reap_dangling, and swarm-merge.sh's fallback
#                           removal (issue #446; see kill-worktree.sh's own
#                           header comment for the full topology) — now logs
#                           a `reap.worktree` event on a successful removal,
#                           so this sweep can diff `git
#                           worktree list` against its own in-memory
#                           inventory (seeded on the first tick — a worktree
#                           already gone before the watcher started is never
#                           flagged) and treat a disappearance with no
#                           matching reap.worktree event logged since it was
#                           last confirmed present as unblessed
#                           (deliberately NOT reap.window too — see
#                           wt_reap_event_since's own header comment).
#                           Local-only (git + events.log, no
#                           network), so this runs on the same cheap cadence
#                           as WATCH_BG_VIOLATION_SWEEP_SECS. The runtime
#                           analog of llm-start.sh's stranded-worktree
#                           warning (issue #376), which only ever fires once
#                           at session/watcher startup. A hit writes a
#                           coord-inbox entry (issue #430 idiom: durable, no
#                           doorbell — the worktree is already gone, so
#                           nothing here is urgent enough to interrupt a live
#                           turn) pointing at .swarm/salvaged/ and this
#                           issue's PR history. Set to 0 to disable. See
#                           worktree_vanish_sweep_pass.
#   WATCH_PENDING_BRIEF_SWEEP_SECS=300
#                           (issue #439) Backstop for requeue.sh's
#                           `SWARM_PENDING_BRIEF: queued` PR marker
#                           (notify_pr_pending_brief), which can only post
#                           at the moment a brief is queued — if the target
#                           branch has no PR yet (the SAMlytics timeline: a
#                           follow-up queued at 18:36, PR opened at 18:45),
#                           the marker never posts, and nothing ever catches
#                           up once the PR exists. On this timer, every own
#                           worktree with a real (non-tmp) file sitting in
#                           .swarm/tasks/inbox/ (worker_pending_brief) and an
#                           OPEN PR whose latest SWARM_PENDING_BRIEF marker
#                           isn't already "queued" gets one posted now — same
#                           anchor comment and idempotency contract as
#                           requeue.sh's own marker, so worker-listener.sh's
#                           clear_pr_pending_brief_marker clears it exactly
#                           the same way once the queue drains. Does real
#                           `gh` calls per own worktree, so this runs on a
#                           slower cadence than the local-only sweep above —
#                           comparable to WATCH_ACTIVITY_POLL_SECS. Set to 0
#                           to disable. See pending_brief_marker_sweep_pass.
#   COORD_WAKE_RETRY_SECS=15
#                           (issue #422, #366 part B) llm-start.sh's
#                           reprompt_inject refuses to paste a wake over a
#                           coordinator composer that holds an unsubmitted
#                           human draft — it defers instead (exit 3) rather
#                           than risk pasting mid-sentence into someone's
#                           in-progress message (the corpusminder-spring
#                           incident, 2026-09-14, that prompted this: a
#                           default WAKE_PROMPT landed mid-draft and got
#                           Enter'd before the operator could stop it).
#                           on_outcome/on_message/on_activity all persist a
#                           deferred prompt to COORD_WAKE_PENDING_FILE
#                           (coord_wake_set_pending) instead of dropping
#                           it, and this timer — same gate-inside-the-
#                           tighter-loop shape as WATCH_PR_POLL_SECS —
#                           retries it (coord_wake_retry_pass) until the
#                           composer clears and the prompt actually lands.
#                           Set to 0 to disable retrying (a deferred wake
#                           then just stays deferred).
#   COORD_WAKE_DEFER_WARN_SECS=300
#                           (issue #422) How long a wake can sit deferred
#                           before coord_wake_retry_pass logs one loud WARN
#                           (repeated at this same interval, not every
#                           retry tick) rather than retrying in total
#                           silence. The retry itself never gives up — a
#                           deferred wake must not be dropped — but a
#                           composer that reads dirty on every single retry
#                           is itself worth a human's attention, especially
#                           given reprompt_composer_dirty's one known
#                           false-positive source (Claude Code's dimmed
#                           autofill suggestion reads identically to a real
#                           draft in a plain-text capture-pane — see that
#                           function's header comment in llm-start.sh).
#   COORD_INBOX_DIR=(auto)  (issue #430) <project>/.swarm/coord-inbox/ — every
#                           outcome/outbox/activity-poll wake writes its full
#                           payload here (mktemp+mv, mirroring the worker
#                           outbox convention) BEFORE any doorbell is even
#                           considered, so a lost or deferred doorbell paste
#                           never loses the content itself — only the nudge
#                           to go look. prompts/coordinator.md's "Inbox"
#                           section has the coordinator-side triage contract
#                           (scan at the start of every turn and after
#                           finishing an operator request; archive handled
#                           items to coord-inbox/processed/). Not itself
#                           overridable — derived from PROJECT_DIR, same as
#                           COORD_WAKE_PENDING_FILE.
#   COORD_INBOX_NUDGE_TEMPLATE=(built-in)
#                           (issue #430) The ONE-LINE doorbell text pasted
#                           into the coordinator's composer once the wake is
#                           allowed to fire — replaces the old practice of
#                           pasting the FULL WAKE_PROMPT/OUTBOX_WAKE_PROMPT
#                           text directly (that text is now the inbox
#                           file's content instead, read on the
#                           coordinator's own schedule). "%N" is substituted
#                           with the current count of unprocessed
#                           coord-inbox/*.md files at paste time.
#   COORD_WAKE_BUSY_RETRY_SECS=30
#                           (issue #430) coordinator_pane_busy() gate on the
#                           doorbell: on_outcome/on_message no longer paste
#                           a wake into a coordinator pane that's mid-turn —
#                           doing so used to let Claude Code queue the paste
#                           and deliver it as an unrelated ❯ user turn
#                           spliced into the middle of whatever the
#                           coordinator was already doing (the fand-app
#                           swarm PR #1108 merge-turn incident, 2026-09-16,
#                           that prompted this issue). A busy pane instead
#                           marks coord_wake_hold_retry_pass (below
#                           on_activity, ticked from run_watch_timer_loop on
#                           this interval) to keep checking; the doorbell
#                           fires as soon as the pane goes idle, or once
#                           COORD_WAKE_BUSY_CEILING_SECS is reached,
#                           whichever comes first. 0 disables this gate
#                           entirely — on_outcome/on_message revert to the
#                           pre-#430 behavior of pasting immediately
#                           regardless of busy state (an explicit rollback
#                           switch, not a recommended setting). Deliberately
#                           a SEPARATE pending file/gate from
#                           COORD_WAKE_PENDING_FILE's dirty-draft deferral
#                           above: a busy pane is safe to force a paste into
#                           (Claude Code queues it) so it gets a ceiling; an
#                           unsubmitted human draft is NOT safe to paste
#                           over at any age, so that one never forces and
#                           only ever warns (COORD_WAKE_DEFER_WARN_SECS).
#   COORD_WAKE_BUSY_CEILING_SECS=900
#                           (issue #430) How long (15 minutes by default)
#                           coord_wake_hold_retry_pass will keep deferring a
#                           busy-pane wake before delivering it anyway
#                           (coord.wake.defer_ceiling) so a long-running
#                           coordinator turn can never starve a wake
#                           forever. 0 disables the ceiling — a busy-deferred
#                           wake then waits indefinitely for the pane to go
#                           idle on its own, same posture as the dirty-draft
#                           case.
#   COORD_HUMAN_IDLE_SECS=600
#                           (issue #459) Hold EVERY doorbell while the
#                           operator has typed into the coordinator's own
#                           Claude Code session within this many seconds.
#                           The #430 gate above only covers a pane that is
#                           mid-turn; a pane BETWEEN turns reads idle, which
#                           is precisely when a human is sitting there
#                           reading and thinking. The operator-reported
#                           symptom this exists for: seven doorbells landing
#                           in twelve minutes while they were working through
#                           a request with the coordinator, each a
#                           legitimately new worker outcome.
#
#                           Unlike every other hold, this one has NO CEILING.
#                           A busy pane is safe to force a paste into
#                           eventually (Claude Code queues it); a session
#                           someone is actively working in is not — forcing
#                           there IS the interruption. Nothing is lost by
#                           waiting: inbox payloads are written
#                           unconditionally (#430), so only the regenerable
#                           nudge waits, and it renders a live count when it
#                           finally rings.
#
#                           0 disables the gate (pre-#459 behavior).
#
#                           Detection is NOT simply "read the last user turn"
#                           — see coord_human_present / human_typed_since. A
#                           pasted doorbell is recorded in the transcript
#                           with origin {kind: human} and promptSource
#                           "typed", identical in shape to a human typing it
#                           (verified on live fand-app transcripts,
#                           2026-09-23). The watcher's own pastes have to be
#                           subtracted, or the gate reads itself as a present
#                           human and mutes the swarm permanently.
#   WORKER_HUMAN_IDLE_SECS=300
#                           (issue #459) Same gate, applied to any of this
#                           project's OWN worker sessions (scoped via the
#                           #357 enumeration, never a flat glob, so a sibling
#                           project's swarm can't hold this one's doorbells).
#                           An operator driving a worker pane by hand is
#                           still the operator being present, and a
#                           coordinator that wakes and re-dispatches
#                           underneath them is the same interruption. Shorter
#                           window than the coordinator's because direct
#                           worker interaction is usually a quick look, not a
#                           conversation. In practice nearly always false,
#                           and costs one mtime check per worktree.
#                           0 disables.
#   COORD_HUMAN_PASTE_GRACE_SECS=15
#                           (issue #459) How far either side of a paste the
#                           watcher recorded in its own events.log a typed
#                           turn may land and still be attributed to that
#                           paste rather than to a human. See
#                           human_typed_since for why this correlation is
#                           needed alongside the text match, and why erring
#                           large is the safe direction (a turn misread as
#                           machine means the doorbell rings, never that the
#                           swarm goes quiet).
#   WAKE_DEFER_ON_SWARM_BUSY=0
#                           (issue #459) Opt-in: also hold doorbells while
#                           any own worker is mid-turn or has a brief queued
#                           and unclaimed in its tasks/inbox/.
#
#                           OFF by default, deliberately. Holding doorbells
#                           on worker BUSYNESS was considered for #459 and
#                           rejected: the moment one worker finishes while
#                           others churn, it parks idle needing a top-up, and
#                           this gate suppresses precisely the wake that
#                           would dispatch its next brief. On a long run the
#                           swarm never goes fully quiet, so triage never
#                           re-engages and worker slots bleed. Human presence
#                           is the lever that matches the reported problem;
#                           this knob exists for operators who want the
#                           stricter whole-swarm quiescence rule anyway, and
#                           is ceilinged like pane_busy so it can't starve a
#                           wake forever.
#
#                           Note the asymmetry in what counts as busy: a
#                           brief ALREADY WRITTEN into a worker's inbox and
#                           not yet claimed is busy (dispatched; nothing owed
#                           by the coordinator). A worker parked with an
#                           EMPTY inbox is the opposite — idle and demanding
#                           attention — and never registers as busy here.
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
#   WATCH_SYNTH_OUTCOME     REMOVED (issue #451, α of #450's finding 1). Used
#                           to (issue #314) fabricate a done/<id>.ok.json the
#                           moment maybe_run_check won a check-claim for a
#                           done signal, because the coordinator's
#                           worker-finished wake only triggers on a NEW
#                           done/<id>.{ok,err}.json and default interactive
#                           workers park at the claude REPL indefinitely
#                           without ever making worker-listener.sh write one.
#                           That fix worked but put FIVE independent places
#                           in a position to each decide a task was "done"
#                           and write their own outcome file under a
#                           different task_id — status_poll_pass's real
#                           task_id, pr_poll_pass's invented
#                           "pr-issue-$issue" fallback, and (once the
#                           listener eventually did exit) worker-listener.sh
#                           itself — the same completion recorded 2-3x, each
#                           copy independently re-triggering worker.finish +
#                           coord.wake (#450's corpusminder #708 case: four
#                           ok.json files over 15 minutes for one finish).
#                           Fixed at the source instead: the worker now
#                           writes its own outcome via scripts/task-done.sh
#                           as the mandatory last step of every task
#                           (prompts/worker.md § "Task completion") — that
#                           file lands in the SAME watched path a listener
#                           write always did, so the existing inotify/poll
#                           pickup -> worker.finish -> autoclose ->
#                           debounced coord.wake pipeline fires unmodified,
#                           with no coordinator-side synthesis needed.
#                           maybe_run_check now calls
#                           reconcile_missing_outcome() where synth_outcome
#                           used to fire — it only logs watch.reconcile and
#                           never writes done/*.json. See task-done.sh's own
#                           header for the pre-#451-worktree migration
#                           story. (An earlier version of this PR also had
#                           reconcile_missing_outcome() drop a one-time
#                           inbox reminder brief — removed on self-review:
#                           that file is indistinguishable from a real task
#                           brief to claim_next_task()/WORKER_AUTO_DELIVER,
#                           so it could get "claimed" and dispatched as a
#                           full extra agent session, and a synthesized
#                           "pr-issue-N" task_id in its instructions would
#                           defeat on_outcome's issue-number parser. Pure
#                           logging fully closes the duplicate-record gap
#                           this issue exists for; a safer proactive nudge
#                           is future scope.)
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
#   WATCHER_STALE_CHECK=1   (issue #296) This script's functions are parsed
#                           into the running bash process's memory once, at
#                           startup — a watcher pane, once spawned, keeps
#                           running whatever code existed at that moment
#                           forever, even after a fix lands on disk and is
#                           pulled into the checkout. This is exactly how
#                           issues #265 and #274 both got silently
#                           un-fixed in production: a watcher launched
#                           2026-08-08 misfired a spurious /compact at 16%
#                           context into a live worker pane on 2026-08-16,
#                           despite both issues having been closed days
#                           earlier — the running process simply never
#                           picked up either fix. With this on, a background
#                           loop (run_stale_check_loop) periodically compares
#                           this process's own script file's mtime, as it
#                           was at launch, against its CURRENT on-disk
#                           mtime. A mismatch means a fix (or any other
#                           change) landed since this daemon started; there
#                           is no way to make an already-running bash
#                           process start executing a function body it
#                           already parsed differently, so instead this logs
#                           watch.stale_daemon loudly and shuts the whole
#                           daemon down (all timer loops, not just this
#                           one) via an uncatchable SIGKILL to its process
#                           group — see watcher_check_staleness()'s own
#                           header comment for why a plain SIGTERM (or
#                           Ctrl-C's SIGINT) does NOT reliably work here,
#                           confirmed by code review: this script's own
#                           EXIT/INT/TERM trap catches it and never calls
#                           `exit`, so the poll backend's bare `while true`
#                           loop just keeps looping past it. When
#                           WATCHER_STALE_RESPAWN=1 (the default, see below)
#                           and this pane's identity is known, the shutdown
#                           asks tmux to respawn this same pane before the
#                           kill lands, so the gap is bounded to seconds, not
#                           however long it takes a human to notice. Failing
#                           that (respawn disabled, not running under tmux,
#                           or the respawn attempt itself fails), a human (or
#                           the coordinator) needs to notice the dead pane
#                           and re-run llm-start.sh (WATCH=1, the default, is
#                           idempotent about spawning the watcher — see that
#                           script's own comment). Use
#                           `coordinator-watch.sh --check-stale` (see USAGE
#                           above) to check this cheaply without waiting for
#                           the periodic sweep. Set to 0 to disable the
#                           self-check entirely.
#
#                           Verified end-to-end against a real tmux pane
#                           (issue #296 code review): the SIGKILL takes the
#                           watcher's whole tmux pane down along with it,
#                           since it's the pane's own foreground process
#                           group — so the human-readable "STALE DAEMON"
#                           banner this prints right before shutting down
#                           may never actually be SEEN in the pane.
#                           events.log's watch.stale_daemon line is the
#                           durable record either way; don't rely on
#                           spotting the banner live.
#   WATCHER_STALE_CHECK_SECS=300
#                           How often the self-check above runs. Kept
#                           independent of every other timer interval in
#                           this file on purpose — this check must keep
#                           running even when every other feature
#                           (WATCH_PR_POLL_SECS, WORKER_AUTO_COMPACT, ...)
#                           is disabled, since a stale daemon can misapply
#                           ANY of this file's logic, not just auto-compact.
#   WATCHER_STALE_RESPAWN=1  (issue #405) A bare self-kill on staleness left
#                           a real swarm (fand-etl) wake-dead for ~2 days:
#                           its tmux session had been up since before the
#                           watcher pane died, so it never got a fresh
#                           `llm-start.sh` run to relaunch the watcher, and
#                           nothing else ever did. With this on (the
#                           default), watcher_check_staleness — after logging
#                           watch.stale_daemon and running cleanup_on_exit as
#                           before — checks $TMUX_PANE (set automatically by
#                           tmux for every process it spawns, including the
#                           `split-window` command llm-start.sh uses to
#                           launch this script) and, when set and a `tmux`
#                           binary is on PATH, runs
#                           `tmux respawn-pane -k -t "$TMUX_PANE"`: this
#                           kills whatever's running in the pane (this
#                           process) and immediately restarts the pane's
#                           ORIGINAL start command — the very
#                           coordinator-watch.sh invocation, with the same
#                           env, that llm-start.sh built — which reparses the
#                           now-current script and starts clean (this
#                           script's state is always re-derived at startup,
#                           same as any fresh watcher launch, so there's
#                           nothing to carry across). This is exactly the
#                           manual recovery issue #405 verified by hand
#                           (`tmux respawn-pane -t <session>:util.<pane>`
#                           immediately drained the backlog: synthesized
#                           outcome files, fired the pending wake) — now
#                           automatic. watch.stale_daemon_respawn is logged
#                           only on that command's SUCCESS (exit 0), not
#                           merely on attempting it — a gone/stale pane id or
#                           a dead tmux server exits non-zero and logs
#                           watch.stale_daemon_respawn_failed instead, so the
#                           events.log distinction actually reflects whether
#                           the pane came back, not just whether a respawn
#                           was tried. The uncatchable SIGKILL below still
#                           always runs right after, unconditionally: it's
#                           the backstop for when TMUX_PANE is unset (not
#                           running under tmux — e.g. these tests), `tmux` is
#                           missing, or the respawn attempt itself fails — in
#                           every one of those cases this still degrades to
#                           the old kill-only behavior, never a hang. Set to
#                           0 to keep the pre-#405 kill-only behavior (a
#                           human or the coordinator must notice and re-run
#                           llm-start.sh).
#   AUTO_COMPACT=1          Before waking a long-lived coordinator (live
#                           claude REPL still in the pane, not a fresh
#                           launch), check its context usage and inject a
#                           real `/compact` — not just text in the input
#                           box, an actual submitted command, the same
#                           load-buffer+paste-buffer+Enter mechanism
#                           llm-start.sh's live-REPL reprompt path uses —
#                           if it's at/above the effective threshold (scaled
#                           to the coordinator's own context window; see
#                           AUTO_COMPACT_PCT below). Blocks (polling
#                           capture-pane) until compaction
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
#   AUTO_COMPACT_PCT=75
#   AUTO_COMPACT_THRESHOLD_CAP_TOKENS=250000
#                           (issue #273, follow-up to #259) The fixed
#                           AUTO_COMPACT_THRESHOLD_TOKENS below ignores the
#                           coordinator model's own context window — on a
#                           1M-context coordinator (Fable 5) the flat 150k
#                           default triggered a compact at just 15%
#                           capacity, the exact worker-side waste #259 fixed,
#                           just not yet mirrored on the coordinator side
#                           (see the 2026-08-13 fand-guide incident: threshold
#                           150000, used 150883, on a 1M-window coordinator).
#                           probe_ctx_window() reads the SAME statusline probe
#                           file probe_ctx_used() already reads (the
#                           coordinator's context data comes from that probe,
#                           not a rendered pane statusline the way workers'
#                           does — see AUTO_COMPACT above), pulling
#                           context_window.context_window_size instead of the
#                           used-tokens field, and
#                           coordinator_compact_effective_threshold() computes
#                           the actual trigger as min(AUTO_COMPACT_PCT% of
#                           that window, AUTO_COMPACT_THRESHOLD_CAP_TOKENS) —
#                           falling back to the flat AUTO_COMPACT_THRESHOLD_
#                           TOKENS below when the denominator can't be parsed
#                           (probe missing/stale, or a schema mismatch none of
#                           probe_ctx_window()'s jq paths match). Defaults
#                           yield 150000 on a 200k-window coordinator (today's
#                           behavior, unchanged) and 250000 on a 1M-window
#                           coordinator — same 250k cap and same quality
#                           rationale as WORKER_COMPACT_THRESHOLD_CAP_TOKENS
#                           above, kept identical on purpose rather than
#                           tuned separately, since both knobs bound the same
#                           underlying models' effective context capacity.
#   AUTO_COMPACT_THRESHOLD_TOKENS=150000
#                           Used-token threshold that triggers the above for
#                           a coordinator whose window size can't be parsed
#                           from the probe — see AUTO_COMPACT_PCT above. Also
#                           the threshold used verbatim when AUTO_COMPACT_PCT
#                           scaling is effectively a no-op (e.g. probe has no
#                           context_window_size field yet).
#   AUTO_COMPACT_REQUIRE_WINDOW=1
#                           (issue #296) Refuse to inject /compact whenever
#                           the coordinator's context-window SIZE can't be
#                           confirmed at all (probe_ctx_window() fails: no
#                           fresh probe, schema mismatch) — rather than
#                           silently trusting the flat AUTO_COMPACT_THRESHOLD_
#                           TOKENS fallback the threshold computation above
#                           degrades to in that same situation (see
#                           AUTO_COMPACT_PCT above). That flat number (150000
#                           by default) can be a much lower percentage of
#                           whatever the coordinator's TRUE window actually is
#                           than intended — e.g. only 15% of a 1M-token
#                           window — with no way to tell from here. Logs
#                           coord.compact.skip reason=no_window_for_floor when
#                           it refuses this way.
#
#                           An earlier version of this guard instead compared
#                           the window's OBSERVED percentage against a fixed
#                           floor (e.g. 60%) even when the window WAS
#                           successfully parsed — code review caught that
#                           this actively fights AUTO_COMPACT_PCT/
#                           AUTO_COMPACT_THRESHOLD_CAP_TOKENS's own scaling:
#                           on a 1M-token window the cap intentionally targets
#                           250000 tokens (25%, not 60%) specifically to keep
#                           compaction frequent enough to avoid the model's
#                           quality-degradation zone past ~512k tokens (see
#                           AUTO_COMPACT_PCT's header comment) — a flat
#                           percentage floor would have delayed compaction on
#                           every large-context-window coordinator until 60%
#                           regardless of that tuning. This guard therefore
#                           only ever refuses when the window genuinely can't
#                           be read at all; it never second-guesses a
#                           threshold that WAS successfully computed from a
#                           real window size, since AUTO_COMPACT_PCT/
#                           _CAP_TOKENS already handles that correctly. Set to
#                           0 to restore the pre-#296 behavior of trusting the
#                           flat AUTO_COMPACT_THRESHOLD_TOKENS fallback
#                           verbatim, for a deployment that deliberately
#                           relies on it (e.g. a probe that never reports a
#                           window size).
#
#                           Known consequence (code review): probe_ctx_used()
#                           and probe_ctx_window() try DIFFERENT jq field
#                           paths against the same probe payload, so a probe
#                           whose schema includes a used-tokens field but
#                           never a window-size field is a real, reachable
#                           shape — not just a hypothetical. On that shape,
#                           this guard refuses EVERY attempt for as long as
#                           the probe keeps rendering that way: auto-compact
#                           effectively goes dark for the coordinator's whole
#                           session rather than ever falling back to the flat
#                           threshold. That's the intended trade (see the
#                           2026-08-16 incident above), but it's a real
#                           functional loss for that specific probe shape,
#                           not just a one-time skip — events.log will show
#                           repeating coord.compact.skip reason=
#                           no_window_for_floor lines the whole time; that
#                           repetition is itself the signal to either fix the
#                           probe's schema or set this to 0.
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
#                           issue #266: Claude Code 2.1.x REMOVED the "(esc to
#                           interrupt)" hint entirely, so that alternation
#                           silently stopped matching anything — a live
#                           worker read as idle, and /compact got injected
#                           mid-turn and then queued/repeated. Two more
#                           alternations were added to restore coverage on
#                           2.1.x: the spinner's "· ↓ <n> tokens" download
#                           counter (present only while a turn/compaction is
#                           actually running — the finished-turn summary line
#                           "✻ Churned for 13s" has no token counter, so this
#                           doesn't false-positive on completed turns left on
#                           screen) and the "Press up to edit queued messages"
#                           marker shown while input is queued behind a live
#                           turn. issue #274: none of the above anchors
#                           cover an in-flight COMPACTION specifically — 2.1.x
#                           renders that as "Compacting conversation…
#                           (<elapsed>)" plus a progress bar, sharing no text
#                           with the turn-streaming anchors above. Without a
#                           dedicated anchor, coordinator_pane_busy/
#                           worker_pane_busy read idle for a compaction's
#                           entire duration, so maybe_auto_compact/
#                           maybe_worker_compact's start-wait loop never sees
#                           busy and logs a false phase=start timeout even
#                           though the compaction is genuinely running (see
#                           #274's incident: a real 1m49s compaction, still
#                           logged as a 16s start timeout) — which in turn
#                           makes compact_retract_queued's Escape/Backspace
#                           fire into a session that is actively compacting.
#                           A "Compacting conversation" alternation was added
#                           to close that gap. The "(esc to interrupt)" and
#                           Ctrl-C alternations are kept for ≤2.0.x
#                           compatibility. This is still TUI chrome, not a
#                           documented API — it needs no maintenance for
#                           verb-wording changes, but MUST be re-verified
#                           against real panes after
#                           every Claude Code CLI upgrade, since #266 shows
#                           the chrome itself (not just the verbs) can change
#                           out from under it. Keep in sync with
#                           WORKER_COMPACT_BUSY_PATTERN if you touch either
#                           (check-stuck-workers.sh's separate pattern is out
#                           of scope for #252/#266 and still uses the verb
#                           list).
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
#   WORKER_COMPACT_REQUIRE_WINDOW=1
#                           (issue #296) Worker-side twin of
#                           AUTO_COMPACT_REQUIRE_WINDOW above — see that
#                           knob's header comment for the full rationale,
#                           including why this is a narrower "refuse only
#                           when the window can't be read at all" check
#                           rather than a fixed percentage floor (a flat
#                           floor would fight WORKER_COMPACT_PCT/
#                           _CAP_TOKENS's own scaling for large windows the
#                           same way it would on the coordinator side).
#                           Refuses (worker.compact.skip
#                           reason=no_window_for_floor) whenever
#                           worker_pane_ctx_window() can't parse a window
#                           size from the rendered statusline — the same
#                           helper worker_compact_effective_threshold() uses,
#                           so this only ever fires when that threshold
#                           computation ALSO had to fall back to the flat
#                           WORKER_COMPACT_THRESHOLD_TOKENS default. In
#                           practice this is unreachable today:
#                           worker_pane_ctx_used() and worker_pane_ctx_window()
#                           parse numerator and denominator off the SAME
#                           rendered "ctx: N/N (N%)" line, so if one parses
#                           the other does too — kept for symmetry with the
#                           coordinator side (whose probe file genuinely CAN
#                           have one field present without the other) and as
#                           a backstop against a future statusline format
#                           change decoupling them. Set to 0 to restore the
#                           pre-#296 behavior of trusting the flat
#                           WORKER_COMPACT_THRESHOLD_TOKENS fallback verbatim.
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
#   WORKER_AUTO_DELIVER=1  (issue #313) Fixes the "parked interactive worker
#                           never gets its requeue.sh follow-up" gap.
#                           worker-listener.sh's interactive mode dispatches
#                           the agent as a FOREGROUND process
#                           (dispatch_agent) and blocks on it until the
#                           agent exits (/quit) — only then does the
#                           listener's own bash loop return to
#                           claim_next_task and notice anything new in
#                           inbox/. A worker that finishes its task and
#                           parks at rest INSIDE that still-running agent
#                           session (never running /quit) is invisible to
#                           its own listener: a coordinator follow-up
#                           dropped via requeue.sh just sits in inbox/
#                           until a human attaches and quits the session by
#                           hand (see the fand-etl incident this issue was
#                           filed from — two briefs sat unclaimed for 2.5+
#                           hours). Distinct from, and complementary to,
#                           task-done.sh (issue #451, above): that script
#                           records the done/*.json outcome for a parked
#                           worker's CURRENT (already finished) task, for
#                           coordinator-wake/monitoring purposes — it does
#                           nothing about a NEW brief waiting behind that
#                           still-live session, which is this feature's
#                           entire job. This reuses the SAME
#                           background sweep as
#                           WORKER_AUTO_COMPACT (worker_compact_pass(), see
#                           above) rather than a dedicated loop — same
#                           per-window capture-pane cost, same cadence
#                           (WORKER_COMPACT_SCAN_SECS) is plenty since this
#                           is a correctness backstop, not something that
#                           benefits from sub-second responsiveness (the
#                           inbox write itself is instant; only the STUCK
#                           case this exists for is slow). For any `iss-*`
#                           window that is (a) a live agent session
#                           (worker_pane_state == cli, not the listener's
#                           own idle bash shell — that case already self-
#                           heals via run_idle_shell, issue #43), (b)
#                           genuinely idle (NOT worker_pane_busy — never
#                           interrupt a live turn), (c) has a real brief
#                           waiting in its inbox/ (worker_pending_brief),
#                           (d) has POSITIVELY CONFIRMED its current task
#                           already reached a terminal status —
#                           "ready-for-review" or "done-no-pr", never
#                           "blocked" or no status at all — via
#                           worker_current_task_terminal() (self-review
#                           finding: a `blocked` worker awaiting a decision
#                           is idle/cli/composer-empty too, and ending ITS
#                           session would make worker-listener.sh record a
#                           false "ok" outcome for a task that never
#                           actually finished — see that function's header
#                           comment for the full incident), (e) has a
#                           rendered statusline confirming a real
#                           interactive TUI is actually on screen
#                           (worker_pane_ctx_used — self-review finding: a
#                           WORKER_HEADLESS=1 `claude -p` run renders no busy
#                           chrome at all, so it can otherwise sit in state
#                           "cli" with worker_pane_busy() never true for its
#                           whole run; this is the same structural guard
#                           maybe_worker_compact already gets from its own
#                           ctx-parsing requirement), and (f) has nothing
#                           unsubmitted sitting in its composer
#                           (compact_composer_clear — see the observed
#                           composer-suggestion case in issue #313's
#                           constraints), maybe_worker_deliver_brief()
#                           pastes "/quit" and Enter, the same injection
#                           mechanism as maybe_worker_compact's /compact.
#                           This does NOT paste the brief's own text —
#                           requeue.sh already wrote it to inbox/ atomically;
#                           ending the session is the only missing step, and
#                           once the agent exits, worker-listener.sh's
#                           existing claim_next_task/dispatch_agent/
#                           write_outcome path runs exactly as it does for
#                           any other follow-up, so done/*.json outcomes and
#                           status/*.json files keep working unchanged for
#                           this class of task too.
#                           Deliberately claude-only in effect, though not
#                           gated on agent identity (the pane alone doesn't
#                           reliably reveal which CLI is running — see
#                           worker_pane_state()): "/quit" is claude's own
#                           documented exit command (worker-listener.sh's
#                           header comment: "/quit (claude) or Ctrl-D
#                           (gemini)"). Against a gemini/codex pane this
#                           fails safe — the text is typed but not
#                           recognized as an exit command, the session stays
#                           "cli", the WORKER_DELIVER_END_TIMEOUT_SECS wait
#                           below times out, and the per-window backoff
#                           kicks in exactly like a failed /compact
#                           injection. Never sends anything more aggressive
#                           than a slash-command paste + Enter.
#                           Known limitation: a worker parked `blocked`
#                           (asked a decision-needed question, awaiting the
#                           coordinator's answer) is deliberately NOT
#                           released by this feature (see gate (d) above) —
#                           only a task that already reached a terminal
#                           status. Answering a blocked worker still needs
#                           the manual path (attach and type the answer
#                           directly, continuing that same conversation) or
#                           a future feature that delivers an answer as a
#                           continuing chat turn instead of ending the
#                           session outright.
#                           Set to 0 to disable; requeue.sh's own hint text
#                           documents the manual fallback (attach and
#                           /quit).
#   WORKER_DELIVER_POLL_SECS=2
#                           capture-pane polling interval while waiting for
#                           the injected /quit to actually end the session.
#   WORKER_DELIVER_END_TIMEOUT_SECS=15
#                           Max wait for worker_pending_brief to go false
#                           (claim_next_task's atomic mv out of inbox/) after
#                           injecting /quit. Deliberately NOT keyed on
#                           worker_pane_state flipping "cli" -> "shell"
#                           (issue #344): worker-listener.sh can claim the
#                           brief and dispatch_agent() re-launch claude
#                           within the SAME poll window the old session
#                           ended in, so the pane goes cli -> shell -> cli
#                           again entirely between two WORKER_DELIVER_POLL_
#                           SECS polls and a pane-state-only check would
#                           misread that normal success as a timeout —
#                           worst case then running compact_retract_queued's
#                           Escape/BSpace against the just-relaunched
#                           session's live first turn. Giving up here just
#                           leaves the brief queued for the next sweep (or a
#                           human) — never blocks anything.
#   WORKER_DELIVER_BACKOFF_SECS=600
#   WORKER_DELIVER_MAX_FAILURES=3
#                           Same shape as WORKER_COMPACT_BACKOFF_SECS/
#                           WORKER_COMPACT_MAX_FAILURES above, own in-memory
#                           associative arrays (WORKER_DELIVER_LAST_FAIL/
#                           FAIL_COUNT/GAVE_UP) so a run of failed injections
#                           against one window (e.g. a non-claude agent, or
#                           a composer that never clears) doesn't retry every
#                           sweep forever.
#   COMPACT_QUEUED_MARKER_PATTERN
#   COMPACT_RETRACT_BACKSPACES=12
#                           (issue #265) Shared by BOTH the coordinator and
#                           per-window retraction paths (see
#                           compact_retract_queued's header comment): when a
#                           phase=start timeout fires, the injected
#                           "/compact" + Enter may simply be sitting queued
#                           behind an already-in-flight turn that AUTO_
#                           COMPACT_BUSY_PATTERN/WORKER_COMPACT_BUSY_PATTERN
#                           failed to recognize as busy (a detection blind
#                           spot — issue #266 was one such regression; issue
#                           #290 was another — see COMPACT_SUBMIT_SETTLE_SECS
#                           below — and this is the safety net for ANY future
#                           one). Left alone, that queued /compact fires
#                           whenever the real in-flight turn eventually ends,
#                           often minutes later against a since-stale
#                           rationale. compact_retract_queued sends one
#                           Escape (clears a QUEUED follow-up without
#                           touching an in-flight turn — no Ctrl-C, ever)
#                           then this many Backspace keystrokes to clear any
#                           stray composer text Escape didn't reach.
#                           issue #290: raised from 3 to 12 — empirically,
#                           Escape does NOT clear the composer (settling the
#                           uncertainty #265/#272's original header comment
#                           flagged); the composer holds "/compact " (9
#                           chars, including the autocomplete menu's
#                           trailing space) at the moment a phase=start
#                           timeout fires, and 3 backspaces reliably left a
#                           "/compa" ghost sitting there — the symptom that
#                           motivated this fix. 12 covers the full 9 with
#                           margin. compact_retract_queued then re-captures
#                           the pane and requires BOTH: COMPACT_QUEUED_
#                           MARKER_PATTERN (same literal embedded in AUTO_
#                           COMPACT_BUSY_PATTERN/WORKER_COMPACT_BUSY_PATTERN
#                           above — kept as its own var since the full busy
#                           pattern also matches spinner/exit-confirm text
#                           irrelevant to "is there still something queued")
#                           gone, AND the composer's own last rendered line
#                           genuinely empty (issue #290 — the marker-only
#                           check could never have caught a partial-clear
#                           ghost, since nothing about a leftover "/compa"
#                           matches the queued-marker text) — NEVER assumes
#                           the keystrokes worked either way. Also refuses to
#                           send Escape/Backspace at all — logging a no-op
#                           instead — when the pane's busy pattern still
#                           matches at retraction time (issue #290's
#                           reconciliation with #274: a phase=start timeout
#                           can be FALSE, e.g. a compaction that's genuinely
#                           running but whose busy anchor a future regression
#                           misses again, and Escape must never fire into a
#                           live compaction). Logs coord.compact.retracted/
#                           retract_failed/retract_skip or worker.compact.
#                           retracted/retract_failed/retract_skip accordingly.
#   COMPACT_SUBMIT_SETTLE_SECS=1
#                           (issue #290) Root cause of the injection never
#                           submitting: pasting text that starts with "/"
#                           opens the CLI's slash-command autocomplete menu,
#                           and an Enter sent immediately afterward (no delay
#                           at all, previously) is consumed by the menu —
#                           accepting the completion, which leaves
#                           "/compact " with a trailing space sitting in the
#                           composer — instead of submitting. maybe_auto_
#                           compact/maybe_worker_compact now sleep this many
#                           seconds after paste-buffer before sending Enter
#                           (lets the menu resolve/auto-close on the exact,
#                           unambiguous "/compact" match), sleep it again,
#                           then re-capture and confirm the Enter actually
#                           submitted — pane already busy, or the composer's
#                           last line no longer holds the pasted text —
#                           retrying the Enter once if not, before falling
#                           through to the normal start-wait loop. Shared
#                           between the coordinator and worker injection
#                           paths; not used by retraction.
#   COMPACT_REPLAY_PATTERN
#                           (issue #292) Transcript-verified 2026-08-16
#                           (corpusminder coordinator, 02:50:04Z): when the
#                           prompt that triggered a compaction was itself
#                           "/compact", the CLI's post-compact continuation
#                           replays that same prompt — {"type":"last-prompt",
#                           "lastPrompt":"/compact"} — producing an immediate,
#                           harmless second execution that renders "Not
#                           enough messages to compact." The watcher's own
#                           finish-wait was still asleep when this fired (no
#                           wake, no human input — the flock was held the
#                           whole time), so this is a genuine CLI quirk, not
#                           anything maybe_auto_compact/maybe_worker_compact
#                           themselves inject. Both functions' post-.done
#                           verify loop now checks for this text; if seen,
#                           the ineffective-compaction check is skipped
#                           entirely (coord.compact.replayed/worker.compact.
#                           replayed logged instead) rather than risking a
#                           misread if the replay's rejection text is still
#                           on screen when used_after is sampled.
#
#                           A second, DISTINCT #292 failure mode — no shared
#                           pattern var, just a compact_composer_clear check
#                           reused at the phase=start timeout site — is the
#                           "delivered as literal text" case: transcript-
#                           verified the same night (01:25:10Z) that an
#                           injected "/compact" can reach the model as a
#                           plain chat message (no command-name execution
#                           pair in the transcript) rather than executing as
#                           a slash command — composer empties, nothing ever
#                           compacts. Because it was queued behind another
#                           turn, the busy indicator this file's start-wait
#                           loop polls for never appeared before
#                           AUTO_COMPACT_START_TIMEOUT_SECS/WORKER_COMPACT_
#                           START_TIMEOUT_SECS elapsed, yet the composer is
#                           ALREADY empty by then (the plain-text message was
#                           accepted and answered, not left sitting
#                           un-submitted) — unlike a genuine non-submit (see
#                           COMPACT_RETRACT_BACKSPACES above), which always
#                           leaves ghost/un-cleared composer text behind at
#                           this same checkpoint. maybe_auto_compact/
#                           maybe_worker_compact now check compact_composer_
#                           clear BEFORE calling compact_retract_queued at a
#                           phase=start timeout: composer already clear ->
#                           log coord.compact.delivered_as_text/worker.
#                           compact.delivered_as_text (no Escape/Backspace —
#                           there is nothing queued left to retract) instead
#                           of the misleading "retracted" verdict the old
#                           code would have logged (retraction "succeeding"
#                           for a reason that has nothing to do with
#                           retraction). Still counts as a failure for the
#                           worker-side backoff (worker_compact_record_
#                           failure) — no compaction ran either way.
#
#   COMPACT_COMPOSER_CHROME_PATTERN
#                           (issue #436) compact_last_pane_line's own
#                           exclusion list (ctx:/shift+tab hint/box-drawing
#                           rule, added for issue #440) didn't cover every
#                           shape of non-input chrome that can render as a
#                           pane's LAST line while the composer itself is
#                           genuinely empty — corpusminder-spring, 2026-09-18/
#                           19: a parked worker's composer read "dirty" on
#                           worker.deliver.skip reason=composer_not_clear
#                           1,812 consecutive times (~14h) with a read-only
#                           capture-worker.sh dump showing an empty `❯`
#                           composer, but a "※ recap:" line, "Baked for 31m"
#                           spinner residue, and a "new task? /clear to save
#                           257.5k tokens" hint also on screen — any one of
#                           which lands as the trimmed last line whenever the
#                           coordinator's own statusline-wrap or a narrower
#                           terminal width splits it off the "ctx: N/M (P%)"
#                           line the existing exclusion already drops whole.
#                           This is the SAME chrome catalog docs/tmux-as-
#                           channel.md §1d and capture-worker.sh's tag_chrome
#                           already tag as non-conversation (recap chrome,
#                           the spinner past/present-tense verb list, and the
#                           "/clear to save Nk tokens" hint) — added here as
#                           its OWN pattern (not folded into AUTO_COMPACT_
#                           BUSY_PATTERN/WORKER_COMPACT_BUSY_PATTERN above)
#                           because those anchor "a turn is actively
#                           running", a different question from "this line
#                           isn't something a human typed", and conflating
#                           the two would make a genuinely busy pane
#                           misread as an idle empty composer. Lines matching
#                           this are dropped by compact_last_pane_line the
#                           same way the ctx:/shift+tab/box-drawing
#                           exclusions already are — never kept-but-
#                           recognized at a call site, so every consumer
#                           (compact_composer_clear, compact_confirm_
#                           submitted, compact_replay_detected, compact_
#                           retract_queued) benefits identically. The verb
#                           list is anchored behind the spinner glyph
#                           (independent-review finding, same PR): see the
#                           variable's own assignment comment below for why
#                           an unanchored substring match would have let a
#                           human draft mentioning one of those phrases
#                           misread as chrome.
#   WORKER_DELIVER_COMPOSER_STALL_THRESHOLD
#                           (issue #436) The composer-clear fix above closes
#                           the false-positive that caused the observed
#                           1,812-skip stall, but a GENUINE stall (a real
#                           human draft sitting in the composer, or a future
#                           unrecognized chrome shape) must not go silent
#                           forever the same way — worker.deliver.skip
#                           reason=composer_not_clear never calls worker_
#                           deliver_record_failure (no /quit was ever
#                           attempted), so it's invisible to the WORKER_
#                           DELIVER_BACKOFF_SECS/MAX_FAILURES machinery that
#                           already escalates every OTHER stuck-delivery
#                           shape. Once the SAME pending brief has racked up
#                           this many reason=composer_not_clear skips —
#                           counted since the brief started stalling, NOT
#                           reset by an intervening sweep that skips for a
#                           DIFFERENT reason (pane_busy, backoff,
#                           task_not_terminal): only a different BRIEF
#                           resets the count, so a genuinely stuck composer
#                           interleaved with the occasional busy/backoff
#                           sweep still escalates on schedule instead of
#                           the threshold silently never being reached —
#                           worker_deliver_record_composer_stall logs one
#                           loud, distinct worker.deliver.composer_stalled
#                           event (never
#                           repeated for the same streak) and durably writes
#                           it to the coordinator inbox (coord_inbox_write,
#                           issue #430) so it surfaces on the coordinator's
#                           NEXT wake — triage per prompts/coordinator.md
#                           "Inbox" — rather than requiring a human to
#                           notice the silent skip lines on their own. Scoped
#                           per (issue, brief) pair, not just per issue: a
#                           NEW brief landing means whatever was stalling
#                           before is moot, so the streak resets rather than
#                           inheriting an unrelated prior count.
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
    re-dispatch, and top up workers. Also watches every worker's
    .swarm/tasks/outbox/ dir (WATCH_OUTBOX, issue #129): a message file
    dropped there by a worker wakes the coordinator with a message-triage
    prompt — the worker→coordinator mid-task channel.

CONFIG  (precedence: shell env > <project>/.swarm/.env > <sandbox>/.env.example)
    DEBOUNCE_SECS       30        coalesce window for repeat events
    POLL_SECS           2         poll-mode latency (when inotify absent)
    DRY_RUN             0         log triggers, don't invoke llm-start.sh
    ONCE                0         exit after first wake (smoke-test)
    LLM_START           (auto)    override path to llm-start.sh
    WAKE_PROMPT         (top-up)  what the coordinator does on wake
    WATCH_OUTBOX        1         wake on worker outbox messages (issue #129); 0=off
    OUTBOX_WAKE_PROMPT  (scan-all) what the coordinator does on an outbox wake
    POST_OUTCOMES       0         run sweep-swarm-outcomes.sh per outcome
    OUTCOME_HOOK        (none)    path to per-outcome poster
    SWEEP               (auto)    override sweep-swarm-outcomes.sh path
    WATCHER_AUTOCLOSE   1         reap eligible workers (window+worktree+branch) before wake; see WATCHER_AUTOCLOSE_MODE
    WATCHER_AUTOCLOSE_MODE merged which terminal PR states are reap-eligible: merged (MERGED only, default) | finalized (MERGED or CLOSED)
    WATCH_PR_POLL_SECS  60        periodic gh-poll backstop reap (0=off); see header comment
    WATCH_ORPHAN_SWEEP_SECS 3600  periodic reap-orphan-worktrees.sh sweep for window-less worktrees (0=off); see header comment
    WATCH_BG_VIOLATION_SWEEP_SECS 60  periodic sweep for backgrounded-shell UI markers on iss-* panes + the coordinator pane (0=off); see header comment
    WATCH_BG_VIOLATION_PATTERN    (auto)  grep -E pattern for the sweep above
    WATCH_ACTIVITY_POLL_SECS 300  periodic gh poll for PRs/issues resolved out-of-band, e.g. in the GitHub web UI (0=off); see header comment (issue #392)
    ACTIVITY_POLL_OVERLAP_SECS 30  cursor overlap tolerating gh search-index lag; dedup maps prevent re-announcing
    WATCH_WORKTREE_SWEEP_SECS 60  periodic detection of a worktree removed outside every blessed reap path (0=off); see header comment (issue #439)
    WATCH_PENDING_BRIEF_SWEEP_SECS 300  periodic backstop posting SWARM_PENDING_BRIEF when a queued brief predates its PR (0=off); see header comment (issue #439)
    COORD_WAKE_LOCK_TIMEOUT_SECS 60  max wait to flock COORD_WAKE_LOCK before a wake gives up (see that lock's header comment)
    COORD_WAKE_RETRY_SECS 15      retry interval for a wake llm-start.sh deferred (composer held an unsubmitted human draft, issue #422); 0=off
    COORD_WAKE_DEFER_WARN_SECS 300  loud WARN threshold for a wake still deferred this long (issue #422); retries never stop on their own
    COORD_WAKE_BUSY_RETRY_SECS 30  retry interval for a wake deferred because the coordinator pane was mid-turn (issue #430); 0=off (pastes immediately, pre-#430 behavior)
    COORD_WAKE_BUSY_CEILING_SECS 900  deliver a busy-deferred wake anyway after this long (issue #430, 15min); 0=no ceiling; never applies to a human_present hold
    COORD_HUMAN_IDLE_SECS 600     hold every doorbell while the operator has typed into the COORDINATOR session this recently (issue #459); 0=off
    WORKER_HUMAN_IDLE_SECS 300    same, for any of this project's own WORKER sessions (issue #459); 0=off
    COORD_HUMAN_PASTE_GRACE_SECS 15  how close to a watcher paste recorded in events.log a typed turn counts as that paste, not a human (issue #459)
    WAKE_DEFER_ON_SWARM_BUSY 0    also hold doorbells while any worker is mid-turn or has a queued unclaimed brief; OFF by default — see header comment for why worker busyness is the wrong lever (issue #459)
    COORD_INBOX_NUDGE_TEMPLATE (built-in) one-line doorbell text pasted once a wake is allowed to fire; %N = live coord-inbox/*.md count (issue #430)
    ACTIVITY_WAKE_PROMPT (built-in) what the coordinator writes to the inbox on an activity-poll finding (issue #430: inbox-only, no doorbell)
    WATCH_CHECK_ON_DONE 1         run acceptance check when a worker signals done; see header comment
    SESSION_NAME        (auto)    tmux session for chk-N windows (llm-<project-basename>)
    WORKSPACE           (auto)    parent dir for wt-issue-* worktrees
    MAX_WORKERS         5         (referenced by default WAKE_PROMPT)
    MAX_TMUX_WINDOWS    10        (referenced by default WAKE_PROMPT)
    WATCHER_QUIET       0         suppress human-readable pane echo (banner only); see PANE ECHO
    WATCHER_STALE_CHECK 1         periodically self-check for stale on-disk code and shut down if found (issue #296); see header comment
    WATCHER_STALE_CHECK_SECS 300  how often the self-check above runs
    AUTO_COMPACT        1         inject real /compact into a long-lived coordinator before waking it if over threshold; see header comment
    AUTO_COMPACT_PCT                  75      percent of the coordinator's own context window used as the effective threshold; see header comment
    AUTO_COMPACT_THRESHOLD_CAP_TOKENS 250000  cap on the above (250k on a 1M-window coordinator, not 750k)
    AUTO_COMPACT_THRESHOLD_TOKENS     150000  used-token trigger; also the fallback when the window can't be parsed
    AUTO_COMPACT_REQUIRE_WINDOW       1       (issue #296) refuse to inject via the flat-fallback threshold when the coordinator's window size can't be confirmed at all (0=off); see header comment
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
    WORKER_COMPACT_REQUIRE_WINDOW            1       (issue #296) refuse to inject via the flat-fallback threshold when the worker's window size can't be confirmed at all (0=off); see header comment
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
    WORKER_AUTO_DELIVER               1       (issue #313) end a parked-at-rest interactive worker session (/quit) so its listener claims an already-queued requeue.sh brief; see header comment
    WORKER_DELIVER_POLL_SECS                2       capture-pane poll interval while waiting for the session to end
    WORKER_DELIVER_END_TIMEOUT_SECS         15      max wait for the session to actually end after /quit
    WORKER_DELIVER_BACKOFF_SECS             600     cooldown for a window after a failed delivery attempt
    WORKER_DELIVER_MAX_FAILURES             3       consecutive failures before giving up on a window entirely
    WORKER_DELIVER_COMPOSER_STALL_THRESHOLD 20      (issue #436) composer_not_clear skips racked up against the same pending brief (not reset by an interleaved skip for a different reason) before a loud, once-only escalation; see header comment
    COMPACT_QUEUED_MARKER_PATTERN     (auto)  queued-input marker checked when retracting a stuck phase=start injection; see header comment
    COMPACT_RETRACT_BACKSPACES        12      Backspace keystrokes sent alongside the retraction Escape (coord + worker, shared; issue #265/#290)
    COMPACT_SUBMIT_SETTLE_SECS        1       settle delay around the injection-submit Enter (coord + worker, shared; issue #290); see header comment
    COMPACT_REPLAY_PATTERN            (auto)  post-compact replayed-/compact rejection text tolerated during verify (coord + worker, shared; issue #292); see header comment
    COMPACT_REPLAY_MIN_REAL_SECS      5       min finish-phase duration to trust a detected replay as real (coord + worker, shared; issue #292); see header comment
    COMPACT_COMPOSER_CHROME_PATTERN   (auto)  non-input UI chrome (recap/spinner-verb/"clear to save" hint) excluded from compact_last_pane_line's result (issue #436); see header comment

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
      coord.wake           the one-line inbox nudge was pasted via llm-start.sh
                           (or coord.wake.skip reason=debounce|pane_busy — the
                           latter only on a coord_wake_retry_pass dirty-draft
                           retry finding the pane busy now, issue #430 self-
                           review); the FULL payload for this wake already
                           landed in coord-inbox/ beforehand — see
                           coord.inbox.write below (issue #430)
      coord.inbox.write    (issue #430) a wake payload (outcome/outbox/activity-poll)
                           was written to <project>/.swarm/coord-inbox/ as its own
                           .md file — unconditional, fires even when the doorbell
                           itself is about to be debounced/deferred, and (for
                           trigger=activity_poll) with NO accompanying coord.wake at
                           all, since activity-poll findings are inbox-only
      coord.wake.defer     the doorbell paste was held this cycle and marked pending;
                           coord_wake_hold_retry_pass keeps checking every
                           COORD_WAKE_BUSY_RETRY_SECS. reason= says which gate held it:
                             pane_busy     (issue #430) coordinator mid-turn
                             human_present (issue #459) the operator typed into the
                                           coordinator session within COORD_HUMAN_IDLE_SECS,
                                           or a worker session within WORKER_HUMAN_IDLE_SECS
                             debounce      (issue #456) another doorbell rang inside
                                           DEBOUNCE_SECS. Pre-#456 this was a
                                           coord.wake.skip that dropped the doorbell
                                           permanently; it is now held and re-rung
                             swarm_busy    (issue #459) WAKE_DEFER_ON_SWARM_BUSY=1 and a
                                           worker is mid-turn or holds a queued brief
      coord.wake.defer_ceiling
                           (issue #430) a held wake hit COORD_WAKE_BUSY_CEILING_SECS
                           (15min default) with its gate still closed — delivered anyway
                           so a long coordinator turn can't starve a wake forever.
                           reason= names the gate. NEVER fires for human_present
                           (issue #459): a present operator is never forced over, so
                           that hold has no ceiling and waits them out
      coord.wake.deferred  (issue #422) llm-start.sh reported a dirty coordinator
                           composer (rc 3) instead of pasting — reason=composer_dirty;
                           the prompt is persisted for coord_wake_retry_pass, not dropped
      coord.wake.retry     (issue #422) coord_wake_retry_pass re-attempted a
                           previously-deferred wake (age=Ns since it first deferred)
      coord.wake.deferred_delivered
                           (issue #422/#430) a retried deferred wake finally landed —
                           the dirty-draft pending file is cleared (issue #422), or,
                           for trigger=pane_busy (issue #430), the pane went idle (or
                           the ceiling fired) and coord_wake_hold_retry_pass delivered it
      coord.wake.deferred_stale
                           (issue #422) a wake has been deferred ≥COORD_WAKE_DEFER_WARN_SECS
                           with every retry still reading the composer dirty — loud WARN,
                           not a give-up (retries continue); see that var's header comment
      sweep.run            sweep-swarm-outcomes.sh fired (when POST_OUTCOMES=1)
      watch.autoclose      kill-finished-workers.sh reaped ≥1 window (trigger=outcome|pr_poll,
                           killed=N); passes that reap nothing are not logged
      reap.window          per-target kill record written by kill-finished-workers.sh
                           (issue, window, branch, reasons, capture=<pane snapshot path>)
      reap.worktree        (issue #439) a worktree was actually removed (issue, branch, dir)
                           — logged, right after the removal SUCCEEDS (issue #446: moved from
                           before to after so a failed removal can't leave a blessed event on
                           record for a still-present worktree), by each of the three sites in
                           this codebase that ever do it: kill-worktree.sh (covering this
                           script and kill-finished-workers.sh's --with-worktree path, its
                           only callers), reap-orphan-worktrees.sh's own dangling-registration
                           path, and swarm-merge.sh's own fallback removal — three call sites,
                           same event shape, so worktree_vanish_sweep_pass below can check for
                           it regardless of which one triggered the removal, before flagging a
                           disappearance as unblessed
      reap.worktree.error  (issue #446) the removal at one of those same three call sites
                           failed (issue, branch, dir, reason=remove_failed|rm_failed) — no
                           reap.worktree event was logged for it, so the worktree stays
                           "known" and a later genuine disappearance still gets caught by
                           worktree_vanish_sweep_pass
      watch.timer.start    a background timer loop started — pr-poll/check-on-done
                           timer loop, and/or (issue #226) the separate
                           worker-compact loop; up to two lines, one per loop
      watch.stale_daemon   (issue #296) this process's own script changed on disk since it
                           started — logged once, immediately before this daemon shuts itself
                           down entirely (script, launch_mtime, current_mtime, pid, started_at);
                           see WATCHER_STALE_CHECK in the header comment
      watch.stale_daemon_respawn
                           (issue #405) logged right after watch.stale_daemon, only when
                           WATCHER_STALE_RESPAWN=1, this pane's identity (TMUX_PANE) is
                           known, AND `tmux respawn-pane -k` (asked to restart this pane's
                           original command under the now-current code) exited 0 — this is
                           a claim the pane actually came back, not just that a respawn was
                           attempted; see WATCHER_STALE_RESPAWN in the header comment
      watch.stale_daemon_respawn_failed
                           (issue #405) logged instead of watch.stale_daemon_respawn when
                           `tmux respawn-pane -k` exited non-zero (gone/stale pane id, dead
                           tmux server) — the pane may still be dead; the old kill-only
                           recovery (re-run llm-start.sh) applies (pane, pid)
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
      watch.activity_poll  (issue #392) periodic gh-search poll found a PR
                           merged / issue closed with no other wake path —
                           reason=detected (count=N, followed by a
                           coord.inbox.write trigger=activity_poll — issue #430:
                           activity-poll findings are inbox-only, no doorbell,
                           so no coord.wake accompanies this) or a skip
                           (pr, issue — see WATCH_ACTIVITY_POLL_SECS's
                           header comment for the full noise-control
                           rationale): reason=skipped_self_reaped (already
                           covered by this swarm's own reap.window event)
                           or reason=skipped_worktree_live ($WORKSPACE/
                           wt-issue-<N> still exists — pr_poll_pass's own
                           reap machinery just hasn't reached it yet)
      activity_poll.error  (issue #392) gh pr list/issue list failed this
                           cycle (reason=gh_pr_list_failed|gh_issue_list_failed);
                           cursor is NOT advanced on this path, so the next
                           tick retries the same window
      watch.worktree_vanished  (issue #439) a tracked worktree disappeared with no
                           reap.worktree event logged for it since it was last
                           confirmed present (issue, dir, reason=no_reap_event) — the
                           signature of a bare `git worktree remove`/`rm -rf` run outside
                           every blessed reap path; followed by a coord.inbox.write
                           trigger=worktree_vanished (no doorbell — the worktree is already
                           gone, nothing here is urgent)
      watch.pending_brief_sweep  (issue #439) pending_brief_marker_sweep_pass posted a
                           SWARM_PENDING_BRIEF: queued PR comment for an own worktree whose
                           inbox/ has a real unclaimed brief and whose PR's marker wasn't
                           already "queued" (pr, dir, reason=posted) — the backstop for a
                           brief queued before its PR existed, so requeue.sh's own marker
                           post never fired
      watch.check_on_done  check-on-done result (issue, task_id, result=running|pass|fail|skipped)
      watch.reconcile      (issue #451, superseded issue #314's watch.outcome.synth
                           — see WATCH_SYNTH_OUTCOME's removal note below) a
                           done-ish signal (ready-for-review status, or a PR
                           appearing) was seen with no completion record for
                           that task_id yet (issue, task_id, reason=
                           status_ready_no_outcome|pr_open_no_outcome). Never
                           writes done/*.json — the worker is the only writer
                           now (scripts/task-done.sh). Usually means the
                           worker hasn't reached its task-done.sh step yet;
                           self-heals on the next poll once it does. Pure
                           observability — takes no other action.
      cap.refused          provision-worker.sh hit MAX_WORKERS / MAX_TMUX_WINDOWS
      coord.compact        /compact injected before wake (used, threshold, trigger=poll|wake)
      coord.compact.skip   auto-compact skipped this cycle (reason=pane_busy|no_fresh_probe|cooldown|...,
                           trigger=poll|wake — reason=cooldown only ever fires trigger=poll)
      coord.compact.timeout  gave up waiting on the busy indicator (phase=start|finish, waited, trigger=poll|wake)
      coord.compact.resubmit  (issue #290) the injection Enter didn't appear to submit
                           (composer still held the pasted text, pane not busy) — resent
                           it once before falling through to the normal start-wait
                           (trigger=poll|wake)
      coord.compact.retracted  (issue #265/#290) a phase=start timeout's injected /compact was
                           retracted (Escape/Backspace) — the queued-input marker was gone AND
                           the composer's own last line was genuinely empty on re-capture
                           (trigger=poll|wake)
      coord.compact.retract_failed  (issue #265/#290) same retraction attempt, but the
                           queued-input marker was STILL visible, or the composer still held
                           leftover text, after Escape/Backspace — investigate (trigger=poll|wake)
      coord.compact.retract_skip  (issue #290) retraction skipped entirely — the pane's busy
                           pattern still matched at retraction time (e.g. a compaction that IS
                           genuinely running despite the phase=start timeout — see #274), so no
                           Escape/Backspace was sent (trigger=poll|wake)
      coord.compact.delivered_as_text  (issue #292) a phase=start timeout fired, but the
                           composer was ALREADY empty (no ghost text) — no retraction attempted
                           (nothing queued left to retract). Most likely explanation: the injected
                           /compact reached the model as a plain chat message instead of executing
                           as a slash command, so no compaction ran despite looking "submitted"
                           (trigger=poll|wake)
      coord.compact.done   busy indicator cleared — compaction confirmed finished (waited, trigger=poll|wake)
      coord.compact.replayed  (issue #292) the CLI's post-compact continuation replayed the
                           same /compact prompt and it rejected harmlessly ("Not enough messages
                           to compact.") within the verify window, AND the finish-phase busy
                           duration cleared COMPACT_REPLAY_MIN_REAL_SECS (rules out the text
                           instead being an outright rejection of the injection itself — see that
                           var's header comment) — the ineffective-compaction check is skipped for
                           this attempt rather than risking a misread (before, trigger=poll|wake)
      coord.compact.ineffective  context didn't drop post-compact (before, after, trigger=poll|wake) — investigate
      coord.compact.verify_skip  probe never refreshed post-compact — inconclusive, not a failure (trigger=poll|wake)
      coord.compact.skip reason=no_window_for_floor  (issue #296, AUTO_COMPACT_REQUIRE_WINDOW=1
                           default) at/over the (flat-fallback) threshold, but the coordinator's
                           window size couldn't be confirmed at all — refused rather than trust that
                           fallback blindly (trigger=poll|wake); see header comment
      worker.compact        /compact injected into an iss-* window (issue, used, threshold, wrapup)
      worker.compact.skip   worker auto-compact skipped this window this cycle (issue,
                           reason=pane_busy|no_ctx_parsed|task_done|backoff|...; reason=task_done
                           means the window's current task already finished — see worker_task_done()
                           — reason=backoff means a prior timeout/ineffective is still cooling down,
                           logged every sweep it would otherwise have fired, same as
                           coord.compact.skip reason=cooldown)
      worker.compact.timeout  gave up waiting on the worker's busy indicator (issue, phase=start|finish, waited)
      worker.compact.resubmit  (issue #290) the injection Enter didn't appear to submit
                           (composer still held the pasted text, pane not busy) — resent
                           it once before falling through to the normal start-wait (issue)
      worker.compact.retracted  (issue #265/#290) a phase=start timeout's injected /compact was
                           retracted (Escape/Backspace) — the queued-input marker was gone AND
                           the composer's own last line was genuinely empty on re-capture (issue)
      worker.compact.retract_failed  (issue #265/#290) same retraction attempt, but the
                           queued-input marker was STILL visible, or the composer still held
                           leftover text, after Escape/Backspace — investigate (issue)
      worker.compact.retract_skip  (issue #290) retraction skipped entirely — the pane's busy
                           pattern still matched at retraction time (see coord.compact.retract_skip
                           above) — no Escape/Backspace was sent (issue)
      worker.compact.delivered_as_text  (issue #292) same signal as coord.compact.delivered_as_text
                           above — composer already empty at a phase=start timeout, no ghost text
                           to retract; most likely the injected /compact was delivered as a plain
                           chat message rather than executed as a slash command. Still counted as
                           a failure (worker_compact_record_failure) — no compaction ran (issue)
      worker.compact.done   worker busy indicator cleared — compaction confirmed finished (issue, waited)
      worker.compact.replayed  (issue #292) same signal as coord.compact.replayed above — the
                           CLI's post-compact continuation replayed /compact and it rejected
                           harmlessly ("Not enough messages to compact.") within the verify
                           window, AND the finish-phase busy duration cleared COMPACT_REPLAY_
                           MIN_REAL_SECS (rules out the text instead being an outright rejection
                           of the injection itself); ineffective-compaction check skipped for this
                           attempt, and counted as a SUCCESS (worker_compact_record_success) — the
                           busy indicator already confirmed this attempt's own compaction genuinely
                           ran; the replay is noise in the verify comparison, not evidence of
                           failure (issue, before)
      worker.compact.ineffective  worker context didn't drop post-compact (issue, before, after) — investigate
      worker.compact.verify_skip  worker's ctx reading never refreshed post-compact — inconclusive, not a failure
      worker.compact.skip reason=no_window_for_floor  (issue #296) same guard as
                           coord.compact.skip reason=no_window_for_floor above, applied to a worker
                           window (issue) — in practice unreachable today, see
                           WORKER_COMPACT_REQUIRE_WINDOW's header comment
      worker.compact.giving_up  (issue #252) N consecutive timeout/ineffective verdicts for this
                           window (issue, failures=N) — maybe_worker_compact stops attempting
                           /compact for it until the watcher restarts; logged once, not every sweep
      worker.deliver.attempt  (issue #313) a worker window is idle-at-rest inside a live agent
                           session with a brief genuinely waiting in inbox/ — about to inject /quit (issue)
      worker.deliver.skip   parked-brief delivery skipped this cycle (issue, reason=task_not_terminal|
                           pane_busy|no_ctx_parsed|composer_not_clear|backoff|mktemp_failed —
                           task_not_terminal means the CURRENT processing/ task's status isn't
                           ready-for-review/done-no-pr yet (e.g. "blocked", or no status file at all);
                           no_ctx_parsed means no interactive statusline is rendered on screen — most
                           likely a WORKER_HEADLESS=1 worker's `claude -p` run, which never shows busy
                           chrome for worker_pane_busy() to key off — see worker_current_task_terminal()'s
                           header comment for the false-completion bug this positive gate closes)
      worker.deliver.resubmit  (issue #290-style) the /quit Enter didn't appear to submit
                           (composer still held the pasted text, pane not busy) — resent it
                           once before falling through to the normal end-wait (issue)
      worker.deliver.ended  the session ended and its listener claimed the pending brief
                           (worker_pending_brief went false — issue #344, NOT a worker_pane_state
                           cli -> shell read, which a same-poll-window relaunch can miss entirely)
                           within WORKER_DELIVER_END_TIMEOUT_SECS (issue, waited)
      worker.deliver.ok     (issue #437) a queued brief was actually delivered/claimed — the
                           positive counterpart to worker.deliver.skip, so a stall's eventual
                           recovery is attributable after the fact instead of vanishing into
                           silence once the skip lines stop (issue, brief=<inbox filename>,
                           release=auto_deliver|listener_claim_after_quit[, waited][, late=1] —
                           auto_deliver: this script's own /quit injection above ended the
                           session and its listener claimed the brief, logged right alongside
                           worker.deliver.ended; auto_deliver with late=1 (self-review, round 2):
                           the same /quit injection, but its effect only landed on a LATER sweep,
                           after this script's own synchronous wait had already given up and
                           logged worker.deliver.timeout — worker_deliver_detect_claim() ties the
                           eventual departure back to WORKER_DELIVER_TIMED_OUT_BRIEF's record of
                           exactly which brief that timed-out attempt was waiting on, however many
                           sweeps late the departure is observed; listener_claim_after_quit:
                           worker_deliver_detect_claim() noticed, on a LATER sweep, that a brief it
                           had previously seen genuinely pending while the window sat parked in
                           "cli" state has since vanished WITHOUT either of the above having
                           claimed credit for it — i.e. something else released the parked
                           session, almost always a human attaching and running /quit by hand per
                           the documented manual fallback. Never logged for a "shell"-state
                           window's routine self-heal (issue #43) — only for a brief this script
                           had already flagged as stuck in the exact parked-session scenario
                           worker.deliver.attempt/.skip describe, so this event's presence or
                           absence answers "did WORKER_AUTO_DELIVER=1 do its job, or did a human
                           have to intervene?" for every such stall)
      worker.deliver.timeout  gave up waiting for the session to end after /quit (issue, waited) —
                           counted as a failure (worker_deliver_record_failure)
      worker.deliver.delivered_as_text  composer already empty at the end-timeout — no ghost text
                           to retract; most likely /quit was delivered as a plain chat message
                           rather than executed as a slash/exit command (issue)
      worker.deliver.retracted / .retract_failed / .retract_skip  same shape as the worker.compact.*
                           retraction events above, applied to a stuck /quit injection (issue)
      worker.deliver.giving_up  (issue #313) N consecutive failed delivery attempts for this window
                           (issue, failures=N) — maybe_worker_deliver_brief stops attempting /quit
                           for it until the watcher restarts; the brief stays queued for a human
                           to release manually (attach and /quit) — logged once, not every sweep
      worker.deliver.composer_stalled  (issue #436) WORKER_DELIVER_COMPOSER_STALL_THRESHOLD
                           worker.deliver.skip reason=composer_not_clear events racked up against
                           the SAME pending brief (issue, brief=<inbox filename>, skips=N) — a
                           sweep that skips for a DIFFERENT reason in between (pane_busy, backoff,
                           task_not_terminal) does not reset this count, only a different brief
                           does, so it's not strictly "N consecutive sweeps" but does mean the
                           threshold is always eventually reached rather than reset away by
                           routine interleaved traffic. Unlike
                           worker.deliver.giving_up, this never stops maybe_worker_deliver_brief
                           from retrying (composer_not_clear can still self-heal on its own,
                           e.g. a human submits or clears their draft): it's a loud, once-per-
                           streak WARNING plus a durable coord_inbox_write so the stall surfaces
                           on the coordinator's next wake instead of aging silently behind
                           routine .skip lines; the streak resets (and can re-escalate) if a
                           DIFFERENT brief starts pending for this window

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
    coordinator-watch.sh --check-stale                  # is my watcher stale? (issue #296)
EOF
        exit 0
        ;;
    --check-stale)
        shift
        # issue #296 self-review finding: a missing/typo'd project-dir made
        # `realpath` fail outright, which — under this script's
        # `set -euo pipefail` — crashed the whole invocation before it could
        # reach the "no state file" case below, giving an opaque error
        # instead of the same clear, distinct exit 2. Validate first.
        CHECK_PROJECT_ARG="${1:-$PWD}"
        if [ ! -d "$CHECK_PROJECT_ARG" ]; then
            echo "'$CHECK_PROJECT_ARG' is not a directory — usage: coordinator-watch.sh --check-stale [project-dir]" >&2
            exit 2
        fi
        CHECK_PROJECT_DIR="$(realpath "$CHECK_PROJECT_ARG")"
        CHECK_STATE_FILE="$CHECK_PROJECT_DIR/.swarm/coordinator-watch.state"
        if [ ! -r "$CHECK_STATE_FILE" ]; then
            echo "No watcher state file at $CHECK_STATE_FILE — is coordinator-watch.sh running for this project?" >&2
            exit 2
        fi
        # Extracted via grep/cut rather than sourced — script_path could
        # theoretically contain characters that aren't safe to source as
        # shell (e.g. a space in the project's path), and this only ever
        # needs to read four plain key=value lines.
        #
        # issue #296 self-review finding: the state-file WRITE already
        # tolerates a partial/failed write (`... || true` at the write
        # site, above) — a process killed mid-write, or a full disk, can
        # leave a truncated file missing one or more keys. Without `|| true`
        # here too, a missing key makes grep return 1 (no match); under
        # this script's `set -euo pipefail`, and with `pipefail` making a
        # pipeline's status the FIRST failing stage's status regardless of
        # what `cut` did with the empty input, that silently aborted this
        # entire --check-stale invocation before printing anything at all —
        # exiting 1, which reads as STALE with zero explanation. `|| true`
        # makes a missing key resolve to an empty string instead, so the
        # normal "?" placeholders and the liveness check below (empty
        # CHECK_PID correctly falls into the NOT RUNNING branch) still
        # produce a coherent, explained verdict.
        state_get() { grep -m1 "^$1=" "$CHECK_STATE_FILE" | cut -d= -f2- || true; }
        CHECK_PID="$(state_get pid)"
        CHECK_STARTED_AT="$(state_get started_at)"
        CHECK_SCRIPT_PATH="$(state_get script_path)"
        CHECK_MTIME_AT_LAUNCH="$(state_get script_mtime_at_launch)"
        CHECK_MTIME_NOW="$(stat -c %Y "$CHECK_SCRIPT_PATH" 2>/dev/null || stat -f %m "$CHECK_SCRIPT_PATH" 2>/dev/null || echo "")"
        echo "watcher pid:          ${CHECK_PID:-?}"
        echo "started at:           ${CHECK_STARTED_AT:-?}"
        echo "script:               ${CHECK_SCRIPT_PATH:-?}"
        echo "script mtime@launch:  ${CHECK_MTIME_AT_LAUNCH:-?}"
        echo "script mtime@now:     ${CHECK_MTIME_NOW:-?}"
        # This state file is written once at startup and never removed, so
        # it outlives the watcher itself — a clean ONCE=1 exit, a crash, or
        # even this daemon's OWN staleness self-check shutting it down all
        # leave it behind unchanged. Without checking liveness, a dead
        # watcher whose script hasn't changed since it launched would report
        # FRESH/exit 0 — telling the operator "nothing to do" when there is
        # no watcher running here at all. `kill -0` sends no signal, just
        # tests whether the pid exists and is ours to signal.
        #
        # Known limitation (code review, issue #296): `kill -0` alone can't
        # tell "this is still the same watcher" from "an unrelated process
        # was later started and happened to reuse this exact pid" — a
        # narrow race in practice (the OS cycles through a large pid range
        # before reusing one), and CHECK_STARTED_AT is recorded precisely
        # so a future version of this check COULD cross-reference it
        # against the live process's actual start time. Not done here:
        # there's no portable, dependency-free way to read a process's
        # start time across the platforms this project already supports
        # (GNU vs BSD `ps`/`stat` output differs, and `/proc` isn't
        # available everywhere) — accepted as a rare, low-severity gap
        # rather than adding a fragile platform-specific parse for it.
        if [ -z "$CHECK_PID" ] || ! kill -0 "$CHECK_PID" 2>/dev/null; then
            echo "status:               NOT RUNNING — no live watcher process for this pid; run llm-start.sh to start one"
            exit 3
        fi
        if [ -n "$CHECK_MTIME_AT_LAUNCH" ] && [ -n "$CHECK_MTIME_NOW" ] && [ "$CHECK_MTIME_AT_LAUNCH" = "$CHECK_MTIME_NOW" ]; then
            echo "status:               FRESH — running code matches the on-disk script"
            exit 0
        else
            echo "status:               STALE — on-disk script changed since this watcher started; re-run llm-start.sh to get a fresh watcher"
            exit 1
        fi
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
# issue #129 — worker→coordinator outbox channel; see header comment.
WATCH_OUTBOX="${WATCH_OUTBOX:-1}"
OUTBOX_WAKE_PROMPT="${OUTBOX_WAKE_PROMPT:-}"
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
# issue #298 — fallback detection for the foreground-only rule; see header comment.
WATCH_BG_VIOLATION_SWEEP_SECS="${WATCH_BG_VIOLATION_SWEEP_SECS:-60}"
WATCH_BG_VIOLATION_PATTERN="${WATCH_BG_VIOLATION_PATTERN:-Running in the background|[0-9]+ shells? still running}"
# issue #392 — periodic backstop for operator actions taken entirely
# outside this swarm (e.g. merging/closing a PR, or closing an issue,
# straight in the GitHub web UI) that no other wake path can ever observe;
# see header comment.
WATCH_ACTIVITY_POLL_SECS="${WATCH_ACTIVITY_POLL_SECS:-300}"
# issue #392 self-review: GitHub's search index can lag the actual merge/
# close event by a few seconds — advancing the cursor to the exact query
# time risks permanently skipping an item that isn't indexed yet at query
# time but would be a few seconds later. This overlaps consecutive polls'
# windows by that many seconds; the ACTIVITY_ANNOUNCED_PR/_ISSUE dedup maps
# (see activity_poll_pass) keep the overlap from re-announcing anything.
ACTIVITY_POLL_OVERLAP_SECS="${ACTIVITY_POLL_OVERLAP_SECS:-30}"
ACTIVITY_WAKE_PROMPT="${ACTIVITY_WAKE_PROMPT:-}"
# issue #439 — see header comment for both.
WATCH_WORKTREE_SWEEP_SECS="${WATCH_WORKTREE_SWEEP_SECS:-60}"
WATCH_PENDING_BRIEF_SWEEP_SECS="${WATCH_PENDING_BRIEF_SWEEP_SECS:-300}"
WATCH_CHECK_ON_DONE="${WATCH_CHECK_ON_DONE:-1}"
CHECK_RUNNER="${CHECK_RUNNER:-}"
SESSION_NAME="${SESSION_NAME:-llm-$(basename "$PROJECT_DIR")}"
WATCHER_QUIET="${WATCHER_QUIET:-0}"
# issue #296 — see this file's WATCHER_STALE_CHECK header comment.
WATCHER_STALE_CHECK="${WATCHER_STALE_CHECK:-1}"
WATCHER_STALE_CHECK_SECS="${WATCHER_STALE_CHECK_SECS:-300}"
# issue #405 — see this file's WATCHER_STALE_RESPAWN header comment (near
# WATCHER_STALE_CHECK above): auto-respawn the pane on staleness instead of
# a bare self-kill that nothing ever un-does.
WATCHER_STALE_RESPAWN="${WATCHER_STALE_RESPAWN:-1}"
AUTO_COMPACT="${AUTO_COMPACT:-1}"
AUTO_COMPACT_THRESHOLD_TOKENS="${AUTO_COMPACT_THRESHOLD_TOKENS:-150000}"
# issue #296 — refuse the flat-fallback threshold above when the window
# can't be confirmed at all; see this file's AUTO_COMPACT_REQUIRE_WINDOW
# header comment.
AUTO_COMPACT_REQUIRE_WINDOW="${AUTO_COMPACT_REQUIRE_WINDOW:-1}"
# issue #273 — scale the effective threshold to the coordinator model's own
# context window (min(AUTO_COMPACT_PCT% of window, ..._CAP_TOKENS)); see
# coordinator_compact_effective_threshold() and this file's AUTO_COMPACT_PCT
# header comment for the full rationale (mirrors WORKER_COMPACT_PCT below).
AUTO_COMPACT_PCT="${AUTO_COMPACT_PCT:-75}"
AUTO_COMPACT_THRESHOLD_CAP_TOKENS="${AUTO_COMPACT_THRESHOLD_CAP_TOKENS:-250000}"
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
# compact). issue #266: Claude Code 2.1.x dropped the "(esc to interrupt)"
# hint, so two more anchors (spinner token counter, queued-input marker)
# were added — see the AUTO_COMPACT_BUSY_PATTERN header comment above.
# issue #274: added a "Compacting conversation" anchor — 2.1.x renders an
# in-flight compaction with none of the turn-streaming anchors above.
AUTO_COMPACT_BUSY_PATTERN="${AUTO_COMPACT_BUSY_PATTERN:-\(esc to interrupt\)|Press Ctrl-C again to .xit|· ↓ [0-9.,]+k? tokens|Press up to edit queued messages|Compacting conversation}"
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
# issue #296 — worker-side twin of AUTO_COMPACT_REQUIRE_WINDOW; see this
# file's WORKER_COMPACT_REQUIRE_WINDOW header comment.
WORKER_COMPACT_REQUIRE_WINDOW="${WORKER_COMPACT_REQUIRE_WINDOW:-1}"
WORKER_COMPACT_WRAPUP_THRESHOLD_TOKENS="${WORKER_COMPACT_WRAPUP_THRESHOLD_TOKENS:-300000}"
# issue #252/#266/#274: same anchors as AUTO_COMPACT_BUSY_PATTERN above — keep in sync.
WORKER_COMPACT_BUSY_PATTERN="${WORKER_COMPACT_BUSY_PATTERN:-\(esc to interrupt\)|Press Ctrl-C again to .xit|· ↓ [0-9.,]+k? tokens|Press up to edit queued messages|Compacting conversation}"
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
# issue #313 — parked-brief delivery: a follow-up brief dropped by
# requeue.sh into a worker's inbox/ never reaches it if that worker's
# interactive agent session is idle at rest rather than back at
# worker-listener.sh's own bash loop (dispatch_agent is blocked on the
# still-running `claude` process, so claim_next_task never runs again).
# Same background sweep as WORKER_AUTO_COMPACT above; see
# maybe_worker_deliver_brief()'s header comment for the full design and
# worker_compact_pass()'s header comment for why this shares that loop.
WORKER_AUTO_DELIVER="${WORKER_AUTO_DELIVER:-1}"
WORKER_DELIVER_POLL_SECS="${WORKER_DELIVER_POLL_SECS:-2}"
WORKER_DELIVER_END_TIMEOUT_SECS="${WORKER_DELIVER_END_TIMEOUT_SECS:-15}"
WORKER_DELIVER_BACKOFF_SECS="${WORKER_DELIVER_BACKOFF_SECS:-600}"
WORKER_DELIVER_MAX_FAILURES="${WORKER_DELIVER_MAX_FAILURES:-3}"
# issue #436 — see this file's WORKER_DELIVER_COMPOSER_STALL_THRESHOLD header
# comment above (near COMPACT_COMPOSER_CHROME_PATTERN's) for the gap this
# closes: reason=composer_not_clear skips never touch WORKER_DELIVER_
# BACKOFF_SECS/MAX_FAILURES above at all, so they need their own counter.
WORKER_DELIVER_COMPOSER_STALL_THRESHOLD="${WORKER_DELIVER_COMPOSER_STALL_THRESHOLD:-20}"
# issue #265 — shared between the coordinator and per-window retraction
# paths; see this file's COMPACT_QUEUED_MARKER_PATTERN header comment above.
COMPACT_QUEUED_MARKER_PATTERN="${COMPACT_QUEUED_MARKER_PATTERN:-Press up to edit queued messages}"
# issue #290: bumped from 3 to 12 — the composer holds "/compact " (9 chars,
# including the autocomplete menu's trailing space) when a phase=start
# timeout fires, and 3 backspaces reliably left a "/compa" ghost behind (see
# COMPACT_QUEUED_MARKER_PATTERN's header comment above for the full incident
# this fixes). 12 covers the full 9 with margin for a stray extra char.
COMPACT_RETRACT_BACKSPACES="${COMPACT_RETRACT_BACKSPACES:-12}"
# issue #290 — shared settle delay used by the injection-submit path
# (maybe_auto_compact/maybe_worker_compact): once between paste-buffer and
# the submitting Enter, and again before checking whether it landed. See
# maybe_auto_compact's injection comment for the autocomplete-menu race
# this closes.
COMPACT_SUBMIT_SETTLE_SECS="${COMPACT_SUBMIT_SETTLE_SECS:-1}"
# issue #292 — see this file's COMPACT_REPLAY_PATTERN header comment above.
COMPACT_REPLAY_PATTERN="${COMPACT_REPLAY_PATTERN:-Not enough messages to compact\.}"
# issue #292 self-review: minimum finish-phase duration (the same "waited"
# a coord.compact.done/worker.compact.done event reports) required before a
# detected replay is trusted as "a real compaction ran, then got harmlessly
# replayed" rather than "the injected /compact was itself rejected
# outright, and never compacted at all" — both produce IDENTICAL pane text
# and an identical brief busy-then-idle transition, so text alone can't
# tell them apart. A genuine compaction necessarily invokes the model to
# summarize the conversation (several seconds minimum); an outright
# rejection is a local CLI-side check with no model call, resolving in a
# small fraction of a second. Below this floor, a detected replay is
# ignored entirely and falls through to the normal ineffective/verify_skip
# path — deliberately NOT logged as a distinct "rejected outright" event,
# so it still counts as a failure (worker_compact_record_failure) via the
# same ineffective path a plain unchanged-context compaction would.
COMPACT_REPLAY_MIN_REAL_SECS="${COMPACT_REPLAY_MIN_REAL_SECS:-5}"
# issue #436 — see this file's COMPACT_COMPOSER_CHROME_PATTERN header comment
# above for the full incident (corpusminder-spring, 2026-09-18/19: a
# 1,812-skip/~14h composer_not_clear stall against a pane whose composer was
# genuinely empty). Same catalog docs/tmux-as-channel.md §1d and capture-
# worker.sh's tag_chrome already recognize: the "※ recap:" summary line, the
# spinner's past/present-tense verb residue (the SAME fixed list check-
# stuck-workers.sh's detect_state()/capture-worker.sh's tag_chrome use —
# deliberately NOT the "(esc to interrupt)"-anchored AUTO_COMPACT_BUSY_
# PATTERN/WORKER_COMPACT_BUSY_PATTERN, which answers "is a turn actively
# running", a different question from "is this line something a human
# typed"), and the "/clear to save Nk tokens" hint that can render as its
# own pane line once terminal width or a longer token count wraps it off
# the "ctx: N/M (P%)" line compact_last_pane_line's own exclusion already
# drops whole.
#
# Independent-review finding (issue #436): the past/present-tense verb list
# (Considering…/Sautéed for/.../Crunched for) was originally an UNANCHORED
# substring match, same as bare "✻"/"✶" — so a genuine human draft that
# happened to contain one of those phrases ("❯ I baked for hours on this
# bug, need a second pair of eyes") would read as chrome, get dropped by
# compact_last_pane_line, and make an occupied composer look clear —
# exactly the false-clear direction issue #436 exists to close, just
# triggered by draft text instead of scrollback residue. Every real
# rendering of this chrome (verified against Test 10's fixtures below and
# the live corpusminder-spring capture) puts the spinner glyph at the very
# start of its OWN pane line, never sharing a line with composer content
# (which is prefixed by "❯"/other box-drawing chars, not the glyph) — so
# anchoring the verb group behind "^[[:space:]]*(✻|✶)" keeps every genuine
# chrome shape matched while a human line (always ❯-prefixed at this point
# in the pipeline, since the leading-prompt-char strip happens AFTER this
# filter) can no longer match on phrase content alone. The verb group
# itself stays optional so a bare glyph-only line (no verb text captured,
# e.g. if only the glyph survived truncation) still matches, same as
# before.
#
# Self-caught bug while implementing the above: the glyph alternation MUST
# be a group "(✻|✶)", never a bracket class "[✻✶]". grep runs under
# LC_ALL=C throughout this function (multi-byte-unsafe on purpose, per
# compact_last_pane_line's own header comment), and under the C locale a
# bracket expression matches byte-by-byte, not character-by-character — the
# 3-byte UTF-8 encodings of ✻ (E2 9C BB) and ✶ (E2 9C B6) share their
# leading byte (E2) with the composer's own "❯" prompt glyph (E2 9D AF), so
# "[✻✶]" anchored at line start matched a genuinely empty "❯ " composer
# line too (byte E2 alone satisfied the class), making an OCCUPIED-looking
# composer line vanish and misreading a real draft as clear — caught by
# this PR's own Test 6 regression (a bare "❯ " composer line was being
# dropped instead of surviving to sed's prompt-char strip). "(✻|✶)" as a
# literal alternation matches the full 3-byte sequence in order like any
# other literal text, which is safe under LC_ALL=C the same way the
# pattern's other literal strings (e.g. "Baked for") already are.
COMPACT_COMPOSER_CHROME_PATTERN="${COMPACT_COMPOSER_CHROME_PATTERN:-^※ recap:|^[[:space:]]*(✻|✶)[[:space:]]*(Considering…|Sautéed for|Cooked for|Baked for|Simmered for|Brewed for|Crunched for)?|/clear to save [0-9.]+k tokens}"

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
if ! [[ "$WATCH_BG_VIOLATION_SWEEP_SECS" =~ ^[0-9]+$ ]]; then
    echo "ERROR: WATCH_BG_VIOLATION_SWEEP_SECS must be a non-negative integer (got: $WATCH_BG_VIOLATION_SWEEP_SECS)" >&2
    exit 1
fi
if ! [[ "$WATCH_ACTIVITY_POLL_SECS" =~ ^[0-9]+$ ]]; then
    echo "ERROR: WATCH_ACTIVITY_POLL_SECS must be a non-negative integer (got: $WATCH_ACTIVITY_POLL_SECS)" >&2
    exit 1
fi
if ! [[ "$ACTIVITY_POLL_OVERLAP_SECS" =~ ^[0-9]+$ ]]; then
    echo "ERROR: ACTIVITY_POLL_OVERLAP_SECS must be a non-negative integer (got: $ACTIVITY_POLL_OVERLAP_SECS)" >&2
    exit 1
fi
if ! [[ "$WATCH_WORKTREE_SWEEP_SECS" =~ ^[0-9]+$ ]]; then
    echo "ERROR: WATCH_WORKTREE_SWEEP_SECS must be a non-negative integer (got: $WATCH_WORKTREE_SWEEP_SECS)" >&2
    exit 1
fi
if ! [[ "$WATCH_PENDING_BRIEF_SWEEP_SECS" =~ ^[0-9]+$ ]]; then
    echo "ERROR: WATCH_PENDING_BRIEF_SWEEP_SECS must be a non-negative integer (got: $WATCH_PENDING_BRIEF_SWEEP_SECS)" >&2
    exit 1
fi
for _var in AUTO_COMPACT_THRESHOLD_TOKENS AUTO_COMPACT_PROBE_MAX_AGE_SECS \
            AUTO_COMPACT_START_TIMEOUT_SECS AUTO_COMPACT_FINISH_TIMEOUT_SECS \
            AUTO_COMPACT_VERIFY_TIMEOUT_SECS AUTO_COMPACT_TICK_SECS AUTO_COMPACT_COOLDOWN_SECS \
            AUTO_COMPACT_PCT AUTO_COMPACT_THRESHOLD_CAP_TOKENS \
            WORKER_COMPACT_PCT WORKER_COMPACT_THRESHOLD_CAP_TOKENS \
            WORKER_COMPACT_THRESHOLD_TOKENS WORKER_COMPACT_WRAPUP_THRESHOLD_TOKENS \
            WORKER_COMPACT_START_TIMEOUT_SECS WORKER_COMPACT_FINISH_TIMEOUT_SECS \
            WORKER_COMPACT_VERIFY_TIMEOUT_SECS WORKER_COMPACT_SCAN_SECS \
            WORKER_COMPACT_BACKOFF_SECS WORKER_COMPACT_MAX_FAILURES \
            COMPACT_RETRACT_BACKSPACES COMPACT_SUBMIT_SETTLE_SECS \
            WATCHER_STALE_CHECK_SECS; do
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
# issue #392: same problem, one level up. Before this feature, every
# NON_INTERACTIVE=1 "$LLM_START" wake call (on_outcome, on_message) ran
# from the single main watcher process, so llm-start.sh's reprompt_inject —
# which pastes through one FIXED, unlocked tmux buffer name
# (llm-coord-reprompt) — was implicitly serialized: nothing could call it
# twice at once. on_activity (activity_poll_pass, run from
# run_watch_timer_loop's own background subshell — a genuinely separate OS
# process) breaks that invariant: a concurrent on_outcome/on_message wake
# from the main process and an on_activity wake from the timer subshell
# could both touch that buffer within the same tmux load-buffer -> paste-
# buffer window, corrupting whichever one pastes second (self-review
# finding on this issue's own PR — the coordinator-claude.sh live-REPL
# reprompt path llm-start.sh:685-690 funnels every caller through).
# on_outcome/on_message/on_activity all flock this around their own
# llm-start.sh call so at most one is ever in flight — see each function's
# call site.
COORD_WAKE_LOCK="$PROJECT_DIR/.swarm/coord-wake.lock"
# issue #392 self-review: before this feature, the main watcher process
# never waited on any lock before its own wake calls — a bounded `flock -w`
# (not an unbounded blocking flock) keeps a wedged llm-start.sh call in
# run_watch_timer_loop's background subshell from being able to freeze
# on_outcome/on_message's wake pipeline in the main process indefinitely.
# llm-start.sh's own live-REPL reprompt path settles/retries on the order of
# a few seconds (COMPACT_SUBMIT_SETTLE_SECS-scaled); 60s is generous
# headroom above that, not a tuned worst case, since a real wedge here means
# something is already badly wrong (dead tmux server, full disk) and this
# is a last-resort escape hatch, not a normal-path timing budget.
COORD_WAKE_LOCK_TIMEOUT_SECS="${COORD_WAKE_LOCK_TIMEOUT_SECS:-60}"
if ! [[ "$COORD_WAKE_LOCK_TIMEOUT_SECS" =~ ^[0-9]+$ ]]; then
    echo "ERROR: COORD_WAKE_LOCK_TIMEOUT_SECS must be a non-negative integer (got: $COORD_WAKE_LOCK_TIMEOUT_SECS)" >&2
    exit 1
fi

# issue #422 (#366 part B): llm-start.sh's reprompt_inject now defers
# (exit 3, see its header comment) rather than pastes when the coordinator
# composer holds an unsubmitted human draft, instead of blindly pasting
# over it. A deferred wake must not be dropped — coord_wake_set_pending/
# coord_wake_retry_pass (below on_activity) persist it here as a FILE, not
# a plain global: on_outcome/on_message run in the main watcher process,
# but the retry pass runs from run_watch_timer_loop's own background
# subshell (a genuinely separate OS process — same cross-process
# constraint COORD_WAKE_LOCK exists for, see its header comment above),
# and an in-memory global written in one process is invisible in the
# other. COORD_WAKE_PENDING_FILE's own mtime doubles as "since when has
# this been deferred" (mtime_epoch, defined below) rather than embedding a
# timestamp in the file — the file's content is the prompt text verbatim,
# which could otherwise collide with any timestamp-parsing convention.
# COORD_WAKE_PENDING_WARNED_FILE's mtime is "when did we last emit the
# bounded-deferral WARN" (its own file so touch(1) doesn't disturb the
# prompt file's mtime). Reads/writes to both are flocked under
# COORD_WAKE_LOCK — the same lock already serializing every process's
# llm-start.sh call — rather than a dedicated lock, since the two classes
# of access never need to be ordered against each other independently.
COORD_WAKE_PENDING_FILE="$PROJECT_DIR/.swarm/coord-wake-pending.prompt"
COORD_WAKE_PENDING_WARNED_FILE="$PROJECT_DIR/.swarm/coord-wake-pending.warned"

# COORD_WAKE_RETRY_SECS (issue #422): how often run_watch_timer_loop
# retries a deferred wake (coord_wake_retry_pass), same gate-inside-the-
# tighter-loop shape as WATCH_PR_POLL_SECS/WATCH_ACTIVITY_POLL_SECS. 0
# disables retrying — a deferred wake then simply stays deferred until the
# next value change, which is never what you want outside a test; not
# validated against 0 the way AUTO_COMPACT_POLL_SECS is against <1,
# because "off" is a legitimate (if unusual) choice here, unlike a poll
# tick that would otherwise busy-loop.
COORD_WAKE_RETRY_SECS="${COORD_WAKE_RETRY_SECS:-15}"
if ! [[ "$COORD_WAKE_RETRY_SECS" =~ ^[0-9]+$ ]]; then
    echo "ERROR: COORD_WAKE_RETRY_SECS must be a non-negative integer (got: $COORD_WAKE_RETRY_SECS)" >&2
    exit 1
fi

# COORD_WAKE_DEFER_WARN_SECS (issue #422): once a wake has stayed deferred
# this long, coord_wake_retry_pass logs one loud WARN (repeated every
# further COORD_WAKE_DEFER_WARN_SECS, not every retry tick) instead of
# retrying silently forever. This is the bound the issue's own constraint
# calls for: reprompt_composer_dirty has a known false-positive risk (the
# composer's dimmed autofill suggestion reads identically to a real draft
# in a plain-text capture — see that function's header comment in
# llm-start.sh), so an operator needs a visible signal if a wake is stuck
# behind a misread rather than a real draft — the retry itself never gives
# up (the wake must not be dropped), only the SILENCE around it is bounded.
COORD_WAKE_DEFER_WARN_SECS="${COORD_WAKE_DEFER_WARN_SECS:-300}"
if ! [[ "$COORD_WAKE_DEFER_WARN_SECS" =~ ^[0-9]+$ ]]; then
    echo "ERROR: COORD_WAKE_DEFER_WARN_SECS must be a non-negative integer (got: $COORD_WAKE_DEFER_WARN_SECS)" >&2
    exit 1
fi

# --- issue #430: coordinator inbox + busy-pane doorbell deferral ----------
#
# COORD_INBOX_DIR mirrors the worker outbox pattern (mktemp+mv, processed/
# archive subdir) one level up: every wake source (on_outcome, on_message,
# on_activity) writes its full payload here BEFORE the doorbell is even
# considered, so a deferred or failed doorbell paste never loses content —
# only the nudge to go look is at risk, and that nudge is now a cheap,
# regenerable one-liner (coord_inbox_nudge_text), not the payload itself.
COORD_INBOX_DIR="$PROJECT_DIR/.swarm/coord-inbox"
COORD_INBOX_PROCESSED_DIR="$COORD_INBOX_DIR/processed"

# COORD_INBOX_NUDGE_TEMPLATE: the fixed, short doorbell text — "%N" is
# substituted with the live coord-inbox/*.md count at paste time (never
# baked into a persisted pending file, so a nudge delivered late after
# COORD_WAKE_BUSY_CEILING_SECS still reports an accurate count instead of a
# stale one captured when the defer first started).
COORD_INBOX_NUDGE_TEMPLATE="${COORD_INBOX_NUDGE_TEMPLATE:-Inbox: %N item(s) in .swarm/coord-inbox/ — read and triage them (see prompts/coordinator.md \"Inbox\").}"

# COORD_WAKE_HOLD_PENDING_FILE: a marker that a doorbell wake is currently
# withheld, whose CONTENT is the reason it's being held (issue #459 widened
# this from #430's empty content-unused marker — see coord_wake_hold_reason
# for the reason vocabulary and each reason's retry policy). Deliberately
# separate from COORD_WAKE_PENDING_FILE (issue #422's dirty-draft deferral)
# since the two have different retry policies: the reasons recorded here are
# either safe to force a paste past eventually (a busy pane — Claude Code
# queues it) or self-clearing on a clock (debounce, human presence), whereas
# an unsubmitted human draft is never safe to paste over, so that one never
# forces. Its own mtime is "since when has this been held", same technique
# as COORD_WAKE_PENDING_FILE's mtime_epoch use below.
#
# Filename kept stable across the #430 → #459 rename so a watcher upgraded
# in place doesn't orphan a live marker; an empty file (pre-#459 writer)
# reads back as reason "pane_busy", which is what it always meant.
COORD_WAKE_HOLD_PENDING_FILE="$PROJECT_DIR/.swarm/coord-wake-busy-pending"

# COORD_WAKE_LAST_FILE: (issue #456) the doorbell debounce clock, on disk
# rather than in a shell global. Two reasons it has to be a file:
#
#   1. It is now SHARED between the outcome and outbox-message wake paths
#      (issue #459 collapsed LAST_WAKE and LAST_MSG_WAKE — see on_outcome's
#      debounce check for why one clock, not two).
#   2. run_watch_timer_loop runs as a separate OS process from the inotify
#      reader that calls on_outcome/on_message, so a global set in one is
#      invisible to the other. coord_wake_hold_retry_pass both reads this
#      (has the debounce window passed?) and writes it (it just rang) —
#      pre-#456 it did neither, so a busy-deferred delivery didn't reset the
#      debounce window at all and the next outcome could ring 2s later.
#
# Being a file, it also survives a watcher restart, where the old globals
# reset to 0. That is the better behavior, not an accident: a watcher
# respawn loop no longer gets a free doorbell per restart. The cost is that
# the first outcome after a restart can be held for up to DEBOUNCE_SECS —
# held, not dropped, so it still rings.
COORD_WAKE_LAST_FILE="$PROJECT_DIR/.swarm/coord-wake-last"

# --- issue #459: human-presence gate --------------------------------------
#
# COORD_HUMAN_IDLE_SECS / WORKER_HUMAN_IDLE_SECS: how recently a HUMAN turn
# must have landed in a session for that session to count as "the operator
# is here right now", holding every doorbell. See their header-comment
# entries above for the full rationale, and coord_human_present /
# swarm_human_present for the detection (which is not as simple as reading
# the last user turn — the watcher's own pastes look identical).
COORD_HUMAN_IDLE_SECS="${COORD_HUMAN_IDLE_SECS:-600}"
if ! [[ "$COORD_HUMAN_IDLE_SECS" =~ ^[0-9]+$ ]]; then
    echo "ERROR: COORD_HUMAN_IDLE_SECS must be a non-negative integer (got: $COORD_HUMAN_IDLE_SECS)" >&2
    exit 1
fi
WORKER_HUMAN_IDLE_SECS="${WORKER_HUMAN_IDLE_SECS:-300}"
if ! [[ "$WORKER_HUMAN_IDLE_SECS" =~ ^[0-9]+$ ]]; then
    echo "ERROR: WORKER_HUMAN_IDLE_SECS must be a non-negative integer (got: $WORKER_HUMAN_IDLE_SECS)" >&2
    exit 1
fi

# COORD_HUMAN_PASTE_GRACE_SECS: how far either side of a paste the watcher
# itself recorded in events.log a typed turn can land and still be treated
# as that paste rather than as a human typing. 15s covers llm-start.sh's
# paste→Enter→transcript-flush path with room to spare; too large starts
# swallowing a human who typed immediately after reading a nudge, which is
# the safe direction anyway (it reads as machine, so the doorbell rings).
COORD_HUMAN_PASTE_GRACE_SECS="${COORD_HUMAN_PASTE_GRACE_SECS:-15}"
# COORD_HUMAN_MAX_TYPED_CHARS: a "typed" turn longer than this is treated as
# a machine paste (see human_typed_since exclusion 3). Set very high rather
# than tight: the cost of misreading a long operator paste as machine is one
# doorbell ringing while they read, whereas misreading a delivered brief as
# an operator holds doorbells for a whole idle window.
COORD_HUMAN_MAX_TYPED_CHARS="${COORD_HUMAN_MAX_TYPED_CHARS:-2000}"
if ! [[ "$COORD_HUMAN_PASTE_GRACE_SECS" =~ ^[0-9]+$ ]]; then
    echo "ERROR: COORD_HUMAN_PASTE_GRACE_SECS must be a non-negative integer (got: $COORD_HUMAN_PASTE_GRACE_SECS)" >&2
    exit 1
fi

# WAKE_DEFER_ON_SWARM_BUSY: opt-in, default OFF. See its header-comment
# entry above for why worker BUSYNESS deliberately does not gate
# dispatch-bearing doorbells by default.
WAKE_DEFER_ON_SWARM_BUSY="${WAKE_DEFER_ON_SWARM_BUSY:-0}"


# COORD_WAKE_BUSY_RETRY_SECS / COORD_WAKE_BUSY_CEILING_SECS: see their
# header-comment entries above (near WATCH_CHECK_ON_DONE) for the full
# rationale. 0 on either disables that half of the gate (see each var's own
# comment above for what "disabled" means for it specifically).
COORD_WAKE_BUSY_RETRY_SECS="${COORD_WAKE_BUSY_RETRY_SECS:-30}"
if ! [[ "$COORD_WAKE_BUSY_RETRY_SECS" =~ ^[0-9]+$ ]]; then
    echo "ERROR: COORD_WAKE_BUSY_RETRY_SECS must be a non-negative integer (got: $COORD_WAKE_BUSY_RETRY_SECS)" >&2
    exit 1
fi
COORD_WAKE_BUSY_CEILING_SECS="${COORD_WAKE_BUSY_CEILING_SECS:-900}"
if ! [[ "$COORD_WAKE_BUSY_CEILING_SECS" =~ ^[0-9]+$ ]]; then
    echo "ERROR: COORD_WAKE_BUSY_CEILING_SECS must be a non-negative integer (got: $COORD_WAKE_BUSY_CEILING_SECS)" >&2
    exit 1
fi
# COORD_WAKE_HOLD_RETRY_SECS: the EFFECTIVE retry cadence for
# coord_wake_hold_retry_pass, derived rather than configured. It follows
# COORD_WAKE_BUSY_RETRY_SECS (the #430 knob operators already know), but
# #430's rollback switch — setting that to 0 — must no longer switch off the
# whole retry loop: the human-presence (#459) and debounce (#456) holds now
# ride the same pass, and a held doorbell with no tick to deliver it is a
# permanently muted swarm, the one outcome every gate here fails open to
# avoid. So when the busy gate is rolled back but another hold can still
# fire, fall back to a 30s tick.
COORD_WAKE_HOLD_RETRY_SECS="$COORD_WAKE_BUSY_RETRY_SECS"
if [ "$COORD_WAKE_HOLD_RETRY_SECS" -eq 0 ] && \
   { [ "$COORD_HUMAN_IDLE_SECS" -gt 0 ] || [ "$WORKER_HUMAN_IDLE_SECS" -gt 0 ] || [ "$DEBOUNCE_SECS" -gt 0 ]; }; then
    COORD_WAKE_HOLD_RETRY_SECS=30
fi

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
        coord.wake.defer)             glyph="⏸"; color=$'\033[33m' ;;
        coord.wake.defer_ceiling)     glyph="→"; color=$'\033[33m' ;;
        coord.wake.deferred)          glyph="⏸"; color=$'\033[33m' ;;
        coord.wake.retry)             glyph="↻"; color=$'\033[36m' ;;
        coord.wake.deferred_delivered) glyph="→"; color=$'\033[32m' ;;
        coord.wake.deferred_stale)    glyph="⚠"; color=$'\033[31m' ;;
        coord.inbox.write)             glyph="✉"; color=$'\033[36m' ;;
        coord.compact)                 glyph="◈"; color=$'\033[36m' ;;
        coord.compact.skip)             glyph="·"; color=$'\033[2m'  ;;
        coord.compact.timeout)           glyph="⚠"; color=$'\033[33m' ;;
        coord.compact.resubmit)          glyph="↻"; color=$'\033[33m' ;;
        coord.compact.retracted)          glyph="↩"; color=$'\033[32m' ;;
        coord.compact.retract_failed)      glyph="⚠"; color=$'\033[31m' ;;
        coord.compact.retract_skip)          glyph="·"; color=$'\033[2m'  ;;
        coord.compact.delivered_as_text)  glyph="⚠"; color=$'\033[33m' ;;
        coord.compact.done)               glyph="◈"; color=$'\033[32m' ;;
        coord.compact.replayed)             glyph="·"; color=$'\033[2m'  ;;
        coord.compact.ineffective)          glyph="⚠"; color=$'\033[31m' ;;
        coord.compact.verify_skip)            glyph="·"; color=$'\033[2m'  ;;
        worker.compact)                 glyph="◈"; color=$'\033[36m' ;;
        worker.compact.skip)             glyph="·"; color=$'\033[2m'  ;;
        worker.compact.timeout)           glyph="⚠"; color=$'\033[33m' ;;
        worker.compact.resubmit)          glyph="↻"; color=$'\033[33m' ;;
        worker.compact.retracted)          glyph="↩"; color=$'\033[32m' ;;
        worker.compact.retract_failed)      glyph="⚠"; color=$'\033[31m' ;;
        worker.compact.retract_skip)          glyph="·"; color=$'\033[2m'  ;;
        worker.compact.delivered_as_text)  glyph="⚠"; color=$'\033[33m' ;;
        worker.compact.done)               glyph="◈"; color=$'\033[32m' ;;
        worker.compact.replayed)             glyph="·"; color=$'\033[2m'  ;;
        worker.compact.ineffective)          glyph="⚠"; color=$'\033[31m' ;;
        worker.compact.verify_skip)            glyph="·"; color=$'\033[2m'  ;;
        worker.compact.giving_up)                glyph="⚠"; color=$'\033[31m' ;;
        worker.deliver.attempt)          glyph="⏏"; color=$'\033[36m' ;;
        worker.deliver.skip)               glyph="·"; color=$'\033[2m'  ;;
        worker.deliver.resubmit)            glyph="↻"; color=$'\033[33m' ;;
        worker.deliver.ended)                glyph="⏏"; color=$'\033[32m' ;;
        worker.deliver.ok)                    glyph="✓"; color=$'\033[32m' ;;
        worker.deliver.timeout)              glyph="⚠"; color=$'\033[33m' ;;
        worker.deliver.delivered_as_text)  glyph="⚠"; color=$'\033[33m' ;;
        worker.deliver.retracted)            glyph="↩"; color=$'\033[32m' ;;
        worker.deliver.retract_failed)        glyph="⚠"; color=$'\033[31m' ;;
        worker.deliver.retract_skip)            glyph="·"; color=$'\033[2m'  ;;
        worker.deliver.giving_up)                  glyph="⚠"; color=$'\033[31m' ;;
        worker.deliver.composer_stalled)   glyph="⚠"; color=$'\033[31m' ;;
        watch.autoclose)               glyph="♻"; color=$'\033[36m' ;;
        watch.orphan_sweep)             glyph="♻"; color=$'\033[36m' ;;
        reap.window)                    glyph="✂"; color=$'\033[36m' ;;
        reap.worktree)                  glyph="✂"; color=$'\033[36m' ;;
        reap.worktree.error)            glyph="✗"; color=$'\033[31m' ;;
        watch.worktree_vanished)        glyph="⚠"; color=$'\033[31m' ;;
        watch.worktree_sweep.error)     glyph="✗"; color=$'\033[31m' ;;
        watch.pending_brief_sweep)      glyph="✉"; color=$'\033[33m' ;;
        watch.pr_poll)                  glyph="⚠"; color=$'\033[33m' ;;
        pr_poll.error)                   glyph="✗"; color=$'\033[31m' ;;
        watch.activity_poll)
            case "$kv" in
                *reason=skipped_self_reaped*|*reason=skipped_worktree_live*)
                    glyph="·"; color=$'\033[2m'  ;;
                *)                            glyph="⚠"; color=$'\033[33m' ;;
            esac ;;
        activity_poll.error)             glyph="✗"; color=$'\033[31m' ;;
        watch.check_on_done)
            case "$kv" in
                *result=pass*)     glyph="✓"; color=$'\033[32m' ;;
                *result=fail*)     glyph="✗"; color=$'\033[31m' ;;
                *result=running*)  glyph="◐"; color=$'\033[33m' ;;
                *)                 glyph="·"; color=$'\033[2m'  ;;
            esac ;;
        watch.check_on_done.error)  glyph="✗"; color=$'\033[31m' ;;
        watch.reconcile)             glyph="?"; color=$'\033[33m' ;;
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
# Under SWARM_WORKTREE_GROUPING=project, WORKSPACE is <parent>/<project>-worktrees,
# which doesn't exist until provision-worker.sh creates the first worktree there
# (mirrors that script's own `mkdir -p "$(dirname "$WT")"`) — self-heal instead
# of hard-failing the watcher on a fresh project with no workers provisioned yet.
mkdir -p "$WORKSPACE" 2>/dev/null
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
workspace:     $WORKSPACE (scanning this project's own wt-issue-*/.swarm/tasks/done/$([ "$WATCH_OUTBOX" = "1" ] && echo " + outbox/") — see issue #357)
outbox:        $WATCH_OUTBOX$([ "$WATCH_OUTBOX" = "1" ] && echo " (worker→coordinator messages; wake prompt: ${OUTBOX_WAKE_PROMPT:-built-in scan-all})")
backend:       $BACKEND$([ "$BACKEND" = "poll" ] && echo " (install inotify-tools for instant response)")
debounce:      ${DEBOUNCE_SECS}s
poll interval: ${POLL_SECS}s$([ "$BACKEND" = "inotify" ] && echo " (unused in inotify mode)")
llm-start.sh:  $LLM_START
post-outcomes: $POST_OUTCOMES$([ "$POST_OUTCOMES" = "1" ] && echo " (sweep: $SWEEP, hook: ${OUTCOME_HOOK:-default dry-run stub})")
autoclose:     $WATCHER_AUTOCLOSE$([ "$WATCHER_AUTOCLOSE" = "1" ] && echo " (mode: $WATCHER_AUTOCLOSE_MODE [$AUTOCLOSE_PR_FLAG], script: $KILL_FINISHED)")
pr-poll:       ${WATCH_PR_POLL_SECS}s$([ "$WATCH_PR_POLL_SECS" = "0" ] && echo " (disabled)")
orphan-sweep:  ${WATCH_ORPHAN_SWEEP_SECS}s$([ "$WATCH_ORPHAN_SWEEP_SECS" = "0" ] && echo " (disabled)" || echo " (script: $REAP_ORPHAN)")
bg-violation:  ${WATCH_BG_VIOLATION_SWEEP_SECS}s$([ "$WATCH_BG_VIOLATION_SWEEP_SECS" = "0" ] && echo " (disabled)" || echo " (foreground-only fallback detection, issue #298)")
activity-poll: ${WATCH_ACTIVITY_POLL_SECS}s$([ "$WATCH_ACTIVITY_POLL_SECS" = "0" ] && echo " (disabled)" || echo " (out-of-band PR/issue resolution backstop, issue #392)")
worktree-sweep: ${WATCH_WORKTREE_SWEEP_SECS}s$([ "$WATCH_WORKTREE_SWEEP_SECS" = "0" ] && echo " (disabled)" || echo " (unblessed worktree-removal detection, issue #439)")
pending-brief-sweep: ${WATCH_PENDING_BRIEF_SWEEP_SECS}s$([ "$WATCH_PENDING_BRIEF_SWEEP_SECS" = "0" ] && echo " (disabled)" || echo " (SWARM_PENDING_BRIEF marker-gap backstop, issue #439)")
coord-wake-retry: ${COORD_WAKE_RETRY_SECS}s$([ "$COORD_WAKE_RETRY_SECS" = "0" ] && echo " (disabled)" || echo " (retry a dirty-composer-deferred wake, warn after ${COORD_WAKE_DEFER_WARN_SECS}s, issue #422)")
coord-inbox:   $COORD_INBOX_DIR (issue #430; busy-pane doorbell defer: $([ "$COORD_WAKE_BUSY_RETRY_SECS" = "0" ] && echo "disabled — pastes immediately regardless of busy" || echo "retry ${COORD_WAKE_BUSY_RETRY_SECS}s, ceiling $([ "$COORD_WAKE_BUSY_CEILING_SECS" = "0" ] && echo "none" || echo "${COORD_WAKE_BUSY_CEILING_SECS}s")"))
human-gate:    $([ "$COORD_HUMAN_IDLE_SECS" = "0" ] && [ "$WORKER_HUMAN_IDLE_SECS" = "0" ] && echo "disabled (issue #459)" || echo "coordinator ${COORD_HUMAN_IDLE_SECS}s / workers ${WORKER_HUMAN_IDLE_SECS}s, no ceiling (issue #459)"); swarm-busy hold: $([ "$WAKE_DEFER_ON_SWARM_BUSY" = "1" ] && echo "on" || echo "off")$([ "$HAVE_JQ" = "1" ] || echo " [no jq — human gate inert, doorbells always ring]")
check-on-done: $WATCH_CHECK_ON_DONE$([ "$WATCH_CHECK_ON_DONE" = "1" ] && echo " (session: $SESSION_NAME)")
auto-compact:  $AUTO_COMPACT$([ "$AUTO_COMPACT" = "1" ] && echo " (threshold: min(${AUTO_COMPACT_PCT}% of window, ${AUTO_COMPACT_THRESHOLD_CAP_TOKENS}), fallback: ${AUTO_COMPACT_THRESHOLD_TOKENS} tokens, require-window: ${AUTO_COMPACT_REQUIRE_WINDOW}, probe: $AUTO_COMPACT_PROBE, poll-tick: ${AUTO_COMPACT_TICK_SECS}s$([ "$AUTO_COMPACT_TICK_SECS" = "0" ] && echo " disabled"), cooldown: ${AUTO_COMPACT_COOLDOWN_SECS}s)")
worker-compact: $WORKER_AUTO_COMPACT$([ "$WORKER_AUTO_COMPACT" = "1" ] && echo " (threshold: min(${WORKER_COMPACT_PCT}% of window, ${WORKER_COMPACT_THRESHOLD_CAP_TOKENS})/wrapup+$(( WORKER_COMPACT_WRAPUP_THRESHOLD_TOKENS - WORKER_COMPACT_THRESHOLD_TOKENS )), fallback: ${WORKER_COMPACT_THRESHOLD_TOKENS}/${WORKER_COMPACT_WRAPUP_THRESHOLD_TOKENS} tokens, require-window: ${WORKER_COMPACT_REQUIRE_WINDOW}, scan: ${WORKER_COMPACT_SCAN_SECS}s)")
worker-deliver: $WORKER_AUTO_DELIVER$([ "$WORKER_AUTO_DELIVER" = "1" ] && echo " (parked-in-agent requeue.sh briefs released via /quit, end-timeout: ${WORKER_DELIVER_END_TIMEOUT_SECS}s, scan: ${WORKER_COMPACT_SCAN_SECS}s — issue #313)")
stale-check:   $WATCHER_STALE_CHECK$([ "$WATCHER_STALE_CHECK" = "1" ] && echo " (every ${WATCHER_STALE_CHECK_SECS}s — issue #296; check anytime: coordinator-watch.sh --check-stale)")
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
STALE_CHECK_PID=""
seen_file=""
cleanup_on_exit() {
    [ -n "${WATCH_TIMER_PID:-}" ] && kill "$WATCH_TIMER_PID" 2>/dev/null || true
    [ -n "${WORKER_COMPACT_TIMER_PID:-}" ] && kill "$WORKER_COMPACT_TIMER_PID" 2>/dev/null || true
    [ -n "${AUTO_COMPACT_POLL_TIMER_PID:-}" ] && kill "$AUTO_COMPACT_POLL_TIMER_PID" 2>/dev/null || true
    [ -n "${STALE_CHECK_PID:-}" ] && kill "$STALE_CHECK_PID" 2>/dev/null || true
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
    # issue #296 self-review finding: this line was missing the `|| true`
    # every other line in this function already has. Under `set -e`, a
    # false `[ -n ... ]` test (seen_file unset — the inotify backend never
    # sets it at all, and run_poll only sets it inside its OWN process,
    # after the fork) made the whole `&&` list's exit status non-zero,
    # which never mattered while this function was ONLY ever invoked via
    # the EXIT/INT/TERM trap (the process is exiting either way at that
    # point) — but watcher_check_staleness (below) now also calls this
    # function directly, as a plain statement, BEFORE its own kill/exit
    # calls. Without this fix, that failing test aborted the whole calling
    # context right here under `set -e`, silently skipping every kill
    # below it — the stale-daemon self-check would log watch.stale_daemon
    # and print its shutdown banner, then keep running the stale code
    # forever, exactly the failure mode issue #296 exists to close.
    [ -n "${seen_file:-}" ] && rm -f -- "$seen_file" || true
}
trap cleanup_on_exit EXIT INT TERM

# Shared state
# issue #459: the outcome and outbox-message doorbell clocks were separate
# globals (LAST_WAKE / LAST_MSG_WAKE) until this issue collapsed them into
# one on-disk clock, COORD_WAKE_LAST_FILE — see wake_clock_get.
#
# The #129 argument for keeping them apart was that an outbox-message wake
# must not be swallowed by a just-fired outcome wake, since the two carried
# DIFFERENT prompts and the outcome's top-up prompt said nothing about
# outboxes. That argument died with #430: both paths now paste the identical
# one-line inbox doorbell, and the payload that used to differ lives in
# coord-inbox/ where the coordinator reads every item regardless of which
# trigger rang. Two clocks simply meant two sources could each ring inside
# the same 30s window — half the "wake storm" the operator reported.
#
# issue #392's activity clock deliberately stays separate below, and is NOT
# a doorbell clock: activity-poll findings are inbox-only and never ring, so
# what it debounces is the inbox WRITE. Folding it in would let an unrelated
# doorbell suppress a payload write and lose content outright — the opposite
# of what the doorbell clocks do, which is delay a regenerable nudge.
LAST_ACTIVITY_WAKE=0
# Moving cursor for activity_poll_pass's gh search queries — "what went
# terminal since this timestamp". Starts at watcher-boot time deliberately:
# this feature exists to catch operator actions taken WHILE the watcher is
# running that nothing else notices, not to backfill history from before it
# started (older history, if still relevant, is what the coordinator's last
# triage before this watcher started already had a chance to see).
LAST_ACTIVITY_POLL_TS="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

# issue #392: ACTIVITY_POLL_OVERLAP_SECS makes activity_poll_pass's cursor
# windows overlap slightly (tolerating gh search-index lag), so the same
# merged PR / closed issue can legitimately turn up in two consecutive
# polls. These dedup maps (keyed by PR/issue number, process-local like
# every other timer-loop dedup state here) make sure it's only ever
# announced once.
declare -A ACTIVITY_ANNOUNCED_PR=()
declare -A ACTIVITY_ANNOUNCED_ISSUE=()

# issue #225: dedups the watch.pr_poll reason=orphan_no_window log line so a
# window-less worktree with a terminal PR gets logged once, not every
# WATCH_PR_POLL_SECS tick forever. Keyed by issue number; cleared in
# pr_poll_pass once the worktree directory is gone (reaped, or never
# provisioned here) so a future worktree reusing the same issue number isn't
# permanently suppressed.
declare -A ORPHAN_PR_LOGGED=()

# issue #298: dedups bg_violation_sweep_pass's outbox drop + log line so a
# worker window with a still-open background shell doesn't get a fresh
# violation message every WATCH_BG_VIOLATION_SWEEP_SECS tick forever. Keyed
# by window name; cleared as soon as a sweep no longer matches
# WATCH_BG_VIOLATION_PATTERN on that window's pane, so a later, genuinely
# new occurrence re-fires instead of staying permanently suppressed.
declare -A BG_VIOLATION_LOGGED=()

# issue #439: worktree_vanish_sweep_pass's own inventory — dir -> epoch it
# was last confirmed present. Seeded whole on the first tick (WT_INVENTORY_
# SEEDED below) so a worktree already gone before the watcher started is
# never treated as "vanished"; this sweep only catches a disappearance that
# happens WHILE the watcher is running and watching for it.
declare -A KNOWN_WORKTREE_SEEN=()
WT_INVENTORY_SEEDED=0

# is_own_worktree_dir <dir>
#
# issue #357: the directory-level primitive behind is_our_worktree below —
# extracted so any pass that builds a "$WORKSPACE/wt-issue-N" path (from a
# tmux window name or a gh PR branch, both of which are trustworthy on
# their own) can verify the RESULT of pasting that onto $WORKSPACE before
# treating it as this project's own. $WORKSPACE can be a parent directory
# shared with sibling projects' swarms under flat grouping (e.g.
# /opt/work/ holding wt-issue-* worktrees for several unrelated repos), so
# a same-numbered foreign worktree can otherwise be mistaken for this
# project's — see is_our_worktree's header for the sibling-repo scenario
# this was first written for.
#
# Returns 0 if $dir is registered as a worktree of $PROJECT_DIR's git.
#
# Fail-open policy: if `git worktree list` errors out (PROJECT_DIR isn't a
# git repo, git missing, etc.), we treat all dirs as ours. Preserves the
# pre-patch behavior for non-git or broken-install setups — the filter
# only adds scoping when it can verify scoping.
is_own_worktree_dir() {
    local dir="$1"
    local wt_list
    wt_list="$(git -C "$PROJECT_DIR" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}')" || return 0
    [ -z "$wt_list" ] && return 0

    grep -Fxq "$dir" <<< "$wt_list"
}

# is_our_worktree <outcome-path>
#
# Filter cross-talk from sibling repos that share the same WORKSPACE parent
# (e.g., /opt/work/oconeco/ holds wt-issue-* worktrees for fand-guide,
# fand-etl, fand-app, fand-poc). Without this filter, a worker finishing in
# any sibling repo wakes EVERY coordinator running under the same parent.
#
# Returns 0 (caller treats as "ours, fire") if the outcome's containing
# worktree is registered with $PROJECT_DIR's git. Returns 1 otherwise.
is_our_worktree() {
    local path="$1"
    local worktree_root
    # Strip the "/.swarm/tasks/done/<file>.json" (outcome) or
    # "/.swarm/tasks/outbox/<file>.md" (worker message, issue #129) suffix
    # to get the worktree root.
    worktree_root="$(echo "$path" | sed -E 's%/\.swarm/tasks/(done|outbox)/[^/]+$%%')"
    is_own_worktree_dir "$worktree_root"
}

# own_wt_dir_for_issue <issue>
#
# issue #357: resolves the worktree directory for a LOCAL issue number
# (parsed from this project's own tmux window name "iss-N", or from a `gh
# pr list` branch on THIS project's repo — both trustworthy on their own).
# The risk is the next step: string-pasting the issue number onto
# $WORKSPACE, which is shared with sibling projects under flat grouping
# (see is_own_worktree_dir above). Verifies the resulting path before
# handing it back, so callers never act on a same-numbered foreign
# worktree. Echoes the path and returns 0 on success; returns 1 (echoing
# nothing) when there's no such directory, or it exists but belongs to a
# different project's git.
own_wt_dir_for_issue() {
    local issue="$1" wt_dir
    wt_dir="$WORKSPACE/wt-issue-$issue"
    [ -d "$wt_dir" ] || return 1
    is_own_worktree_dir "$wt_dir" || return 1
    echo "$wt_dir"
}

# own_worktree_dirs_for_scan <project_dir>
#
# Fail-open wrapper around swarm_own_worktree_dirs() for the live watcher's
# outcome/outbox scan (run_poll's scan_outcomes below). swarm_own_worktree_dirs()
# is deliberately fail-QUIET (see its header in _load-env.sh) — the right
# default for a cold CLI listing about to act on the result, but wrong here:
# "no worktrees exist yet" and "git failed against $project_dir" must never
# look the same, because the watcher's whole job is to not miss events.
# Falls back to the pre-#357 raw glob (matching is_own_worktree_dir's own
# documented fail-open policy, used by every other polling pass in this
# file) instead of silently scanning nothing forever. Real production
# PROJECT_DIR is always a git checkout — this only guards a broken-install
# or non-git edge case.
own_worktree_dirs_for_scan() {
    local project_dir="$1" dirs
    dirs="$(swarm_own_worktree_dirs "$project_dir")"
    if [ -n "$dirs" ]; then
        printf '%s\n' "$dirs"
        return 0
    fi
    git -C "$project_dir" rev-parse --git-common-dir >/dev/null 2>&1 && return 0

    local cand
    shopt -s nullglob
    for cand in "$WORKSPACE"/wt-issue-*/; do
        echo "${cand%/}"
    done
    shopt -u nullglob
}

# outcome_path_issue <outcome-path>
#
# Issue number for a done/*.{ok,err}.json path. Prefers the path's own
# "wt-issue-<N>" directory segment — always present for any outcome file
# that reached here (every own-worktree layout in this codebase is
# WORKSPACE/wt-issue-<N>/...) — over the OLD convention of parsing the
# FILENAME's trailing "-<issue>" before .ok/.err.json.
#
# issue #451 self-review finding: that filename-trailing-digits parse was
# only ever reliable because #314's synth_outcome (removed by this PR)
# defensively appended "-$issue" to every filename it wrote, using the
# issue number it was called with directly — never by parsing task_id.
# scripts/task-done.sh and worker-listener.sh's write_outcome() both use
# the BARE task_id with no such suffixing (matching write_outcome's own
# long-standing convention, unchanged by this PR) — a task_id that
# doesn't happen to end in "-<issue>" (requeue.sh's <wt-path> form, or
# provision-worker.sh's "-2"/"-3" collision suffix landing AFTER the
# issue number) parses wrong under the old filename-only method. The path
# itself was always the more reliable source and needs no writer-side
# change to fix.
outcome_path_issue() {
    local path="$1"
    local issue
    issue=$(printf '%s' "$path" | sed -nE 's#.*/wt-issue-([0-9]+)/.*#\1#p')
    if [ -z "$issue" ]; then
        # Fallback for a path shape that doesn't match the convention at
        # all (e.g. a test fixture) — the old filename-trailing-digits parse.
        issue=$(basename "$path" | sed -E 's/.*-([0-9]+)\.(ok|err)\.json$/\1/')
    fi
    printf '%s' "$issue"
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
        log_event worker.finish.skip "issue=$(outcome_path_issue "$path") reason=foreign_worktree path=$path"
    fi
}

# dispatch_message <outbox-message-path>
#
# (issue #129) Outbox counterpart of dispatch_outcome: same is_our_worktree
# scoping, routed to on_message. Used by both backends.
dispatch_message() {
    local path="$1"
    if is_our_worktree "$path"; then
        on_message "$path"
    else
        local issue
        issue=$(msg_issue "$path")
        log_event worker.message.skip "issue=$issue reason=foreign_worktree path=$path"
    fi
}

# msg_issue <outbox-message-path> — issue number from the worktree dir name
# (wt-issue-42/... -> 42; "?" when the path doesn't match, e.g. custom
# worktree layouts).
msg_issue() {
    local n
    n=$(echo "$1" | sed -nE 's|.*/wt-issue-([0-9]+)/.*|\1|p')
    echo "${n:-?}"
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

# Portable ctime (epoch seconds — "last metadata change", GNU %Z / BSD %c).
# Deliberately distinct from mtime_epoch: a same-filesystem `mv` (rename(2))
# preserves a file's mtime (content unchanged) but always bumps its ctime,
# which is exactly what worker_current_task_terminal()'s issue #370 fallback
# needs — "when was this brief actually claimed into processing/", not "when
# was its content last written" (those can be far apart for a brief that sat
# queued in inbox/ for a while before being claimed).
ctime_epoch() {
    stat -c %Z "$1" 2>/dev/null || stat -f %c "$1" 2>/dev/null
}

# --- Stale-daemon self-check (issue #296) -----------------------------------
#
# WATCHER_SELF_PATH/WATCHER_LAUNCH_MTIME capture this script's own identity
# (resolved real path + on-disk mtime) once, here at startup. watcher_is_stale
# (below, polled periodically by run_stale_check_loop) re-reads the CURRENT
# mtime of that same path and compares — a mismatch means the file was
# rewritten on disk since this bash process parsed it into memory, and
# THIS process's function bodies are the un-rewritten ones; there is no way
# to make an already-running interpreter start executing new code for an
# already-defined function. Deliberately mtime, not a content hash: enough
# to detect "the file changed underneath me" without a sha256sum dependency,
# and a false positive (e.g. a no-op touch) just costs one harmless restart.
#
# Also written to WATCHER_STATE_FILE so `coordinator-watch.sh --check-stale`
# (see USAGE in the header comment) can answer "is my watcher stale?" from a
# second terminal without touching this live process.
WATCHER_SELF_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
WATCHER_LAUNCH_MTIME="$(mtime_epoch "$WATCHER_SELF_PATH" 2>/dev/null || echo 0)"
[ -n "$WATCHER_LAUNCH_MTIME" ] || WATCHER_LAUNCH_MTIME=0
WATCHER_STARTED_AT="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
WATCHER_STATE_FILE="$PROJECT_DIR/.swarm/coordinator-watch.state"
{
    printf 'pid=%s\n' "$$"
    printf 'started_at=%s\n' "$WATCHER_STARTED_AT"
    printf 'script_path=%s\n' "$WATCHER_SELF_PATH"
    printf 'script_mtime_at_launch=%s\n' "$WATCHER_LAUNCH_MTIME"
} > "$WATCHER_STATE_FILE" 2>/dev/null || true

# watcher_is_stale
#
# Pure predicate, no side effects: rc0 (stale) when the on-disk mtime of
# this script no longer matches what it was at launch, rc1 (fresh)
# otherwise. Split out from watcher_check_staleness below so the detection
# logic is unit-testable without also triggering the shutdown side effects.
watcher_is_stale() {
    local current_mtime
    current_mtime="$(mtime_epoch "$WATCHER_SELF_PATH" 2>/dev/null || echo 0)"
    [ -n "$current_mtime" ] || current_mtime=0
    [ "$current_mtime" != "$WATCHER_LAUNCH_MTIME" ]
}

# watcher_check_staleness
#
# Called periodically from run_stale_check_loop's own background process.
# On staleness (watcher_is_stale above), logs watch.stale_daemon with both
# mtimes, then shuts the ENTIRE daemon down — every timer loop, not just
# this one — rather than trying to hot-reload (not possible from inside a
# running bash process). $$ here still refers to the top-level watcher
# process's PID even though this function runs inside a backgrounded child
# (bash's `&`/subshell forking never changes what $$ reports — only
# $BASHPID does — so this is the same PID cleanup_on_exit's own kills use
# elsewhere in this file).
#
# Uses SIGKILL, not SIGTERM — deliberately, after a code-review-caught bug
# in an earlier version of this function proved SIGTERM insufficient here.
# This script installs `trap cleanup_on_exit EXIT INT TERM` (near the top),
# and cleanup_on_exit — by design also reused as the plain graceful-
# shutdown EXIT trap — never calls `exit` itself. Empirically verified
# (both in a plain bash job and in a real tmux pane): a caught SIGTERM with
# no `exit` in its handler just runs the trap and resumes whatever was
# interrupted — the poll backend's bare `while true` loop doesn't even
# notice its `sleep` was cut short, so it keeps looping past a SIGTERM
# indefinitely; only the inotify backend's incidental child-death cascade
# (killing `inotifywait` closes its pipe, ending the `while read` loop
# naturally) happened to make manual Ctrl-C look like it worked, backend-
# dependently and by accident. SIGKILL cannot be caught, blocked, or
# ignored by anyone, so it's the only signal that reliably guarantees
# termination regardless of backend or trap state. The GROUP form (`-$$`)
# additionally reaps whichever foreground child (sleep/find/inotifywait) is
# currently blocking run_poll/run_inotify in the same shot, rather than
# orphaning it; the direct-PID form right after is a redundant, harmless
# backstop in case `-$$` somehow doesn't resolve to this process's own
# group. cleanup_on_exit() is called directly BEFORE either kill — SIGKILL
# skips traps entirely, so this is the only chance for sibling timer loops
# (WATCH_TIMER_PID etc.) to be reaped; without it they'd be orphaned rather
# than cleaned up, even though the group-kill below would still catch any
# of them that happen to share this process group. Before #405,
# this relied on something else — a human or the coordinator — noticing the
# resulting dead pane and re-running llm-start.sh to get a fresh process
# running the current code; see WATCHER_STALE_CHECK's header comment for the
# incident that closed (fand-etl went wake-dead for ~2 days) and
# WATCHER_STALE_RESPAWN's header comment (just above) for the tmux
# respawn-pane call this function now attempts first, and --check-stale for
# a cheap way to notice a dead watcher without waiting on the pane.
watcher_check_staleness() {
    [ "$WATCHER_STALE_CHECK" = "1" ] || return 0
    watcher_is_stale || return 0
    local current_mtime
    current_mtime="$(mtime_epoch "$WATCHER_SELF_PATH" 2>/dev/null || echo 0)"
    [ -n "$current_mtime" ] || current_mtime=0
    log_event watch.stale_daemon "script=$WATCHER_SELF_PATH launch_mtime=$WATCHER_LAUNCH_MTIME current_mtime=$current_mtime pid=$$ started_at=$WATCHER_STARTED_AT"
    echo "[$(date +%T)] STALE DAEMON: $WATCHER_SELF_PATH changed on disk since this watcher started ($WATCHER_STARTED_AT, mtime $WATCHER_LAUNCH_MTIME -> $current_mtime)."
    cleanup_on_exit
    # issue #405 — respawn our own pane before the unconditional kill below,
    # so the current code comes back up in seconds instead of leaving the
    # pane dead until a human (or a fresh llm-start.sh run) notices. See
    # WATCHER_STALE_RESPAWN's header comment for why this is safe (state is
    # always re-derived at startup) and why the kill below still always runs
    # regardless — this is a best-effort head start, not a replacement for
    # the backstop.
    if [ "$WATCHER_STALE_RESPAWN" = "1" ] && [ -n "${TMUX_PANE:-}" ] && command -v tmux >/dev/null 2>&1; then
        echo "[$(date +%T)] Respawning pane $TMUX_PANE so the current code restarts automatically — no human action needed."
        # Logged AFTER the call, keyed on ITS exit status — not unconditionally
        # before — so watch.stale_daemon_respawn is a claim the pane actually
        # came back, not just that a respawn was attempted (self-review
        # finding: a gone/stale pane id or a dead tmux server exits non-zero
        # here, and the earlier unconditional log line made that look
        # identical to success in events.log).
        if tmux respawn-pane -k -t "$TMUX_PANE" 2>/dev/null; then
            log_event watch.stale_daemon_respawn "pane=$TMUX_PANE pid=$$"
        else
            log_event watch.stale_daemon_respawn_failed "pane=$TMUX_PANE pid=$$"
            echo "[$(date +%T)] Respawn attempt failed — the pane may stay dead. Re-run llm-start.sh (WATCH=1, the default) if it does."
        fi
    else
        echo "[$(date +%T)] Shutting down so a fresh process can pick up the current code — re-run llm-start.sh (WATCH=1, the default) to restart the watcher."
    fi
    kill -KILL -$$ 2>/dev/null || true
    kill -KILL "$$" 2>/dev/null || true
    exit 0
}

# run_stale_check_loop
#
# Own background process (issue #296), started unconditionally whenever
# WATCHER_STALE_CHECK=1 — unlike run_watch_timer_loop/run_worker_compact_loop/
# run_auto_compact_poll_loop above, which only start when their own feature
# is enabled, this one must keep running regardless of which OTHER features
# are on, since a stale daemon can misapply any of this file's logic, not
# just auto-compact.
run_stale_check_loop() {
    while true; do
        sleep "$WATCHER_STALE_CHECK_SECS"
        watcher_check_staleness
    done
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
        if [ ! -d "$wt_dir" ] || ! is_own_worktree_dir "$wt_dir"; then
            # Already reaped, never provisioned here, or (issue #357) this
            # PR's issue number happens to collide with a SIBLING project's
            # worktree under the same flat $WORKSPACE — either way, drop
            # any stale dedup entry so a future worktree reusing this issue
            # number starts fresh (see ORPHAN_PR_LOGGED comment above).
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

# swarm_already_reaped <issue> <since-iso8601>
#
# issue #392 noise control: true if a reap.window event for this issue was
# logged at/after $since — i.e. this swarm's OWN pr_poll_pass/
# cleanup_eligible_workers pipeline already reaped it within the very
# window activity_poll_pass is looking at, so announcing it again here
# would just be the swarm waking itself over its own action. String
# comparison against the log line's leading ISO8601 timestamp field is
# enough (no date-parsing dependency needed): the format is fixed-width, so
# lexicographic order matches chronological order.
swarm_already_reaped() {
    local issue="$1" since="$2"
    [ -f "$EVENTS_LOG" ] || return 1
    awk -v since="$since" -v needle="issue=$issue " '
        $1 >= since && $2 == "reap.window" && index($0, needle) { found=1; exit }
        END { exit !found }
    ' "$EVENTS_LOG"
}

# activity_worktree_still_live <issue>
#
# issue #392 self-review: deliberately NOT is_own_worktree_dir (used by
# pr_poll_pass et al) for two reasons, both because that helper's
# safety direction is backwards for THIS caller:
#   1. is_own_worktree_dir alone never checks `-d` — it only asks git
#      whether the path is a REGISTERED worktree, which stays true for a
#      prunable entry whose directory a reap already `rm -rf`'d
#      (kill-worktree.sh does exactly that; provision-worker.sh's own
#      operator-facing docs describe manual removal the same way) until a
#      `git worktree prune` happens to run. pr_poll_pass avoids this with
#      its own `[ ! -d "$wt_dir" ] || ! is_own_worktree_dir "$wt_dir"`
#      combination (mirrored in own_wt_dir_for_issue) — replicated here.
#   2. On a git error (or an empty worktree list), is_own_worktree_dir
#      fails OPEN — "yes, treat this as live" — which is the right default
#      for pr_poll_pass/orphan_sweep_pass (uncertain -> don't reap
#      something real) but the WRONG default here: for this poll, "treat
#      as live" means "don't announce it," and staying silent on a
#      genuine out-of-band merge/close is the exact failure #392 exists to
#      close. So this fails CLOSED instead — on any git error, "not
#      confirmed live" (proceed to announce) rather than "assume live"
#      (silently skip forever, since a merge announcement not made this
#      tick will fall out of the cursor's window and never come back).
activity_worktree_still_live() {
    local issue="$1"
    # Deliberately a SEPARATE `local` from the one above, not `local
    # issue="$1" wt_dir="...$issue"` (shellcheck SC2318): bash does not
    # make an earlier name=value in the SAME `local` statement visible to
    # a later one in that statement, so `wt_dir` would silently pick up
    # whatever `issue` already meant in an ANCESTOR call frame (bash
    # locals are dynamically scoped) — under `set -u`, with no such
    # ancestor variable, that's a hard "unbound variable" crash instead.
    local wt_dir="$WORKSPACE/wt-issue-$issue"
    [ -d "$wt_dir" ] || return 1
    local wt_list
    wt_list="$(git -C "$PROJECT_DIR" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}')" || return 1
    grep -Fxq "$wt_dir" <<< "$wt_list"
}

# activity_poll_pass
#
# issue #392: pr_poll_pass/orphan_sweep_pass above exist to REAP — both only
# ever look at PRs/worktrees this swarm still has a live tmux window or
# worktree directory for. Once a worker is reaped, its PR/issue drops out of
# both passes entirely, so an operator action taken later, entirely
# out-of-band (merging/closing a PR, closing an issue, straight in the
# GitHub web UI), produces no wake at all: no new outcome.json (the wake
# channel is worker-outcome-file-driven), no live worktree left to poll
# from, nothing. See WATCH_ACTIVITY_POLL_SECS's header comment for the
# incident this closes.
#
# Runs on its own timer, independent of the reap passes: two `gh ... list
# --search "<field>:>=<cursor>"` calls per tick using LAST_ACTIVITY_POLL_TS
# as a moving cursor, so each merge/close is returned exactly once — the
# NEXT tick's window starts right after this tick's — rather than needing a
# separate per-item dedup map. The cursor only advances once BOTH queries
# have actually succeeded, so a transient gh failure re-tries the same
# window next tick instead of silently skipping it.
#
# issue #392 self-review (second finding): the cursor must also NOT advance
# past an item that was found but never successfully announced (on_activity
# returned 1 — debounced, or its llm-start.sh call failed). ACTIVITY_
# ANNOUNCED_PR/_ISSUE only guards against DOUBLE-announcing something still
# inside the gh query window; once the cursor moves past an item's merge/
# close time, gh's `merged:>=cursor` search will never return it again,
# REGARDLESS of dedup-map state — so advancing unconditionally, before
# knowing whether the wake actually landed, would drop that item forever
# (the exact "parked on pending" bug #392 exists to fix — the two ARE the
# same bug at different layers). So the cursor only advances when every
# candidate this tick either produced no pending items at all (nothing to
# lose) or on_activity actually succeeded for the pending ones; a
# debounced/failed on_activity call leaves LAST_ACTIVITY_POLL_TS exactly
# where it was, so the identical window (now growing, since $since stays
# fixed while real time passes) is re-queried — and the item re-found — on
# the very next tick.
#
# issue #392 self-review: swarm_already_reaped only catches a merge the
# swarm's OWN reap.window pipeline has already LOGGED — there's a real gap
# between a swarm-driven merge and that log line landing (up to
# WATCH_PR_POLL_SECS, longer if the kill gate defers), during which this
# poll would otherwise announce the swarm's own merge as if an operator did
# it out-of-band. This feature exists for workers "reaped long ago" (see
# header comment above) — a still-live worktree/window means pr_poll_pass's
# own reap machinery hasn't gotten to it yet, which is exactly that gap, so
# a merged PR (or closed issue) whose $WORKSPACE/wt-issue-<N> worktree
# still exists is skipped here too (reason=skipped_worktree_live) and left
# for pr_poll_pass to handle on its own next tick.
activity_poll_pass() {
    local since="$LAST_ACTIVITY_POLL_TS"
    local now_epoch new_cursor
    now_epoch=$(date +%s)

    local merged_prs closed_issues
    merged_prs="$(cd "$PROJECT_DIR" && gh pr list --state merged --limit 100 \
            --search "merged:>=$since" \
            --json number,title,headRefName \
            --jq '.[] | "\(.number)\t\(.title)\t\(.headRefName)"' 2>/dev/null)" || {
        log_event activity_poll.error "reason=gh_pr_list_failed"
        return 0
    }
    closed_issues="$(cd "$PROJECT_DIR" && gh issue list --state closed --limit 100 \
            --search "closed:>=$since" \
            --json number,title \
            --jq '.[] | "\(.number)\t\(.title)"' 2>/dev/null)" || {
        log_event activity_poll.error "reason=gh_issue_list_failed"
        return 0
    }

    # Both queries succeeded. Compute the candidate next cursor —
    # ACTIVITY_POLL_OVERLAP_SECS BEHIND now, not AT now (issue #392
    # self-review): gh's search index can lag the actual merge/close by a
    # few seconds, so cutting the cursor exactly at query time risks
    # permanently skipping an item indexed just after this query ran. The
    # ACTIVITY_ANNOUNCED_PR/_ISSUE maps guard the resulting overlap window
    # against double-announcing — but do NOT assign this to
    # LAST_ACTIVITY_POLL_TS yet: whether it's safe to advance at all
    # depends on whether every pending item below actually gets announced
    # (see this function's header comment, second self-review finding).
    new_cursor="$(date -u -d "@$((now_epoch - ACTIVITY_POLL_OVERLAP_SECS))" +'%Y-%m-%dT%H:%M:%SZ')"
    # Never move backwards — a since that already exceeds the overlapped
    # cursor (WATCH_ACTIVITY_POLL_SECS < ACTIVITY_POLL_OVERLAP_SECS) would
    # otherwise re-query a window this tick already covered.
    [[ "$new_cursor" > "$since" ]] || new_cursor="$since"

    if [ -z "$merged_prs" ] && [ -z "$closed_issues" ]; then
        LAST_ACTIVITY_POLL_TS="$new_cursor"
        return 0
    fi

    # ACTIVITY_ANNOUNCED_PR/_ISSUE are only marked AFTER a successful
    # (non-debounced) on_activity call below — not here, per-item — so a
    # debounced wake (on_activity returns 1) doesn't permanently lose these
    # items: leaving them unmarked means a later tick, while they're still
    # inside the gh query's cursor window, gets to retry announcing them.
    local pr_number title branch issue lines="" pending_prs=() pending_issues=()
    while IFS=$'\t' read -r pr_number title branch; do
        [ -n "$pr_number" ] || continue
        [ -n "${ACTIVITY_ANNOUNCED_PR[$pr_number]:-}" ] && continue
        issue=""
        case "$branch" in
            fix/issue-*)
                issue="${branch#fix/issue-}"
                [[ "$issue" =~ ^[0-9]+$ ]] || issue=""
                ;;
        esac
        if [ -n "$issue" ] && swarm_already_reaped "$issue" "$since"; then
            log_event watch.activity_poll "reason=skipped_self_reaped pr=$pr_number issue=$issue"
            continue
        fi
        if [ -n "$issue" ] && activity_worktree_still_live "$issue"; then
            log_event watch.activity_poll "reason=skipped_worktree_live pr=$pr_number issue=$issue"
            continue
        fi
        pending_prs+=("$pr_number")
        lines="$lines"$'\n'"PR #$pr_number merged: $title"
    done <<< "$merged_prs"

    local issue_number
    while IFS=$'\t' read -r issue_number title; do
        [ -n "$issue_number" ] || continue
        [ -n "${ACTIVITY_ANNOUNCED_ISSUE[$issue_number]:-}" ] && continue
        # A merged PR with "Closes #N" auto-closes issue #N too — without
        # these two checks, a merge already suppressed above (self-reaped
        # or worktree-live) would still slip through here as a same-event
        # "Issue #N closed" line.
        if swarm_already_reaped "$issue_number" "$since"; then
            log_event watch.activity_poll "reason=skipped_self_reaped issue=$issue_number"
            continue
        fi
        if activity_worktree_still_live "$issue_number"; then
            log_event watch.activity_poll "reason=skipped_worktree_live issue=$issue_number"
            continue
        fi
        pending_issues+=("$issue_number")
        lines="$lines"$'\n'"Issue #$issue_number closed: $title"
    done <<< "$closed_issues"

    lines="${lines#$'\n'}"
    if [ -z "$lines" ]; then
        # Every candidate this tick was already handled (self-reaped,
        # worktree-live, or previously announced) — nothing pending means
        # nothing to lose, so it's safe to advance past this whole window.
        LAST_ACTIVITY_POLL_TS="$new_cursor"
        return 0
    fi

    log_event watch.activity_poll "reason=detected count=$(grep -c . <<< "$lines")"
    if on_activity "$lines"; then
        local p
        for p in "${pending_prs[@]}"; do ACTIVITY_ANNOUNCED_PR[$p]=1; done
        for p in "${pending_issues[@]}"; do ACTIVITY_ANNOUNCED_ISSUE[$p]=1; done
        # Only NOW is it safe to advance the cursor: every pending item was
        # actually announced. A debounced/failed on_activity call (return
        # 1) intentionally leaves LAST_ACTIVITY_POLL_TS untouched — see
        # this function's header comment.
        LAST_ACTIVITY_POLL_TS="$new_cursor"
    fi
}

# wt_reap_event_since <issue> <since-iso8601>
#
# True if a `reap.worktree` event (kill-worktree.sh, and now
# reap-orphan-worktrees.sh's dangling path / swarm-merge.sh's fallback
# removal — all three log it, issue #439) for this issue was logged
# at/after $since. Mirrors swarm_already_reaped's exact awk/cursor idiom
# above — events.log's fixed-width ISO8601 timestamp field sorts
# lexicographically, so no date-parsing dependency is needed.
#
# issue #439 self-review (round 4): deliberately `reap.worktree` ONLY, not
# `reap.window` too, despite kill-finished-workers.sh logging reap.window
# for EVERY kill (including its default window-only mode, with no
# --with-worktree, which never touches the worktree directory at all).
# Trusting reap.window here would let an unrelated window-only kill for
# this issue mask a genuinely unblessed worktree removal that happened to
# land in the same lookback window — every path that actually removes a
# worktree (kill-worktree.sh, reap-orphan-worktrees.sh's dangling `rm -rf`,
# swarm-merge.sh's fallback removal) already logs reap.worktree itself, so
# reap.window brings no additional real coverage, only a false-negative
# risk.
wt_reap_event_since() {
    local issue="$1" since="$2"
    [ -f "$EVENTS_LOG" ] || return 1
    awk -v since="$since" -v needle="issue=$issue " '
        $1 >= since && $2 == "reap.worktree" && index($0, needle) { found=1; exit }
        END { exit !found }
    ' "$EVENTS_LOG"
}

# unblessed_worktree_vanish_notify <issue> <dir>
#
# issue #439: writes a coord-inbox entry (issue #430 idiom — durable, no
# doorbell) pointing at the same salvage/PR-history trail a human would
# have to check by hand. By the time this fires the worktree is already
# gone, so there's nothing left here to act on urgently — the value is
# making sure the coordinator goes and checks .swarm/salvaged/ and the
# issue's own PR history before trusting that nothing was lost.
unblessed_worktree_vanish_notify() {
    local issue="$1" dir="$2"
    local body
    body="A worktree this swarm was tracking (issue #$issue, $dir) disappeared with no reap.worktree event logged for it since it was last confirmed present. That's the signature of a bare \`git worktree remove\` or \`rm -rf\` run outside every blessed reap path (kill-worktree.sh and its callers all log reap.worktree on removal — issue #439) — no salvage ran, so any brief still sitting in that worktree's .swarm/tasks/{inbox,processing,outbox}/ was destroyed, not preserved under .swarm/salvaged/iss-$issue/.
Check .swarm/salvaged/iss-$issue/ (won't exist if nothing was queued), check issue #$issue's PR history for a SWARM_PENDING_BRIEF marker that never got a matching cleared/orphaned follow-up, and re-file any lost work as a fresh issue if the PR already merged past it."
    if [ "$DRY_RUN" = "1" ]; then
        echo "[DRY] would write coord-inbox worktree-vanished entry for issue #$issue"
        return 0
    fi
    if coord_inbox_write worktree_vanished "$body"; then
        log_event coord.inbox.write "trigger=worktree_vanished issue=$issue"
    else
        echo "[$(date +%T)] WARN: failed to write coord-inbox worktree-vanished entry for issue #$issue" >&2
    fi
}

# worktree_vanish_sweep_pass
#
# issue #439: detects a worktree removed outside every blessed reap path —
# see WATCH_WORKTREE_SWEEP_SECS's header comment for the full incident
# (SAMlytics wt-issue-296: a queued follow-up brief destroyed with no event
# and no salvage). Diffs the current own-worktree inventory
# (own_worktree_dirs_for_scan, the same #357-safe enumeration pr_poll_pass/
# activity_poll_pass use) against KNOWN_WORKTREE_SEEN. The first tick only
# seeds the map — a worktree already gone before the watcher started was
# never "watched" disappear, so it's not this sweep's business. Every dir
# still present each tick gets its last-seen timestamp bumped, which is
# also what bounds wt_reap_event_since's search window tightly (only needs
# to cover the gap since the previous tick, not this worktree's entire
# life).
#
# issue #439 self-review (round 3): "current" REQUIRES `[ -d "$dir" ]`, not
# just git's own registration. `git worktree list` (what
# own_worktree_dirs_for_scan reads) keeps listing a worktree whose
# directory was `rm -rf`'d directly — as opposed to `git worktree
# remove`d — until something runs `git worktree prune` or otherwise
# touches the registration, which can be long after the directory itself
# (and anything queued inside it) is already gone. Without this check, a
# bare `rm -rf` — the SAMlytics incident's actual leading hypothesis,
# alongside `git worktree remove --force` — would stay "present" in this
# diff forever, and the eventual dangling-registration cleanup
# (reap_dangling) would then log a blessed reap.worktree for it, silently
# retconning a real unblessed removal into a non-event.
#
# issue #439 self-review (round 5, corrected round 10): guards against a
# transient git failure being misread as "every tracked worktree vanished
# in the same tick". own_worktree_dirs_for_scan can legitimately return
# EMPTY with no error at all when git itself is healthy but this project
# genuinely has zero registered worktrees right now — a real, common tick
# this sweep must still process correctly (e.g. a bulk
# `kill-finished-workers.sh --all --with-worktree` reaping everything at
# once is exactly this case, and every one of those removals already has
# its own reap.worktree event). The DIFFERENT failure this guards against
# is `git worktree list` itself glitching for a tick while the repo is
# otherwise fine.
#
# Round 10: probes `git worktree list` directly, not `rev-parse
# --git-common-dir` (round 5's original probe). Those are different git
# operations that fail independently — a round-9 self-review caveat
# confirmed a `worktree list`-specific glitch could return empty with
# rc 0 while `rev-parse --git-common-dir` (much cheaper plumbing, no
# worktree-registry read at all) still succeeds fine, defeating the whole
# point of this guard. own_worktree_dirs_for_scan's own health probe
# (used only on ITS empty-fallback path) has the same mismatch, but that
# path already has a second fallback (the raw wt-issue-* glob) covering
# it; this sweep has no such fallback, so it needs the precise probe.
worktree_vanish_sweep_pass() {
    local dir issue now_epoch since found seen
    now_epoch=$(date +%s)

    if ! git -C "$PROJECT_DIR" worktree list >/dev/null 2>&1; then
        log_event watch.worktree_sweep.error "reason=git_unavailable"
        return 1
    fi

    local -a current_dirs=()
    while IFS= read -r dir; do
        [ -n "$dir" ] && [ -d "$dir" ] && current_dirs+=("$dir")
    done < <(own_worktree_dirs_for_scan "$PROJECT_DIR")

    if [ "$WT_INVENTORY_SEEDED" != "1" ]; then
        for dir in "${current_dirs[@]}"; do
            KNOWN_WORKTREE_SEEN["$dir"]=$now_epoch
        done
        WT_INVENTORY_SEEDED=1
        return 0
    fi

    for dir in "${!KNOWN_WORKTREE_SEEN[@]}"; do
        found=0
        for seen in "${current_dirs[@]}"; do
            [ "$seen" = "$dir" ] && { found=1; break; }
        done
        [ "$found" = "1" ] && continue

        issue="$(basename "$dir" | sed -nE 's/^wt-issue-([0-9]+)$/\1/p')"
        # issue #439 self-review (round 6, widened in round 7): padded
        # back by TWO sweep intervals, not the bare last-seen timestamp.
        # A `git worktree remove` on a large worktree (or the compose-down
        # step immediately before it) can take real wall-clock time — long
        # enough to span a tick or two — during which the directory still
        # exists (still present in this tick's scan), so its last-seen
        # timestamp keeps advancing while the removal is still in flight.
        # issue #446 self-review moved kill-worktree.sh's reap.worktree
        # logging to AFTER a successful removal, not before as this
        # comment originally said — so the event now lands essentially
        # back-to-back with the directory's actual disappearance, rather
        # than sitting on record however long the removal then takes. The
        # 2x buffer is no longer load-bearing for that original multi-tick
        # scenario, but it's kept anyway as cheap defense-in-depth against
        # ordinary tick-cadence slop and the sub-second gap between the
        # removal finishing and the log line executing (see
        # kill-worktree.sh's own comment on that trade-off). Without
        # enough buffer, the eventual tick that finally sees the dir gone
        # could compute a `since` later than that event's own timestamp,
        # and wt_reap_event_since's `$1 >= since` would then miss it — a
        # blessed removal gets flagged as unblessed (noise: one spurious
        # coord-inbox entry, not data loss — the worktree and its salvage
        # state are exactly what they'd be either way). Same
        # bounded-overlap idiom as ACTIVITY_POLL_OVERLAP_SECS elsewhere in
        # this file.
        since="$(date -u -d "@$(( KNOWN_WORKTREE_SEEN[$dir] - 2 * WATCH_WORKTREE_SWEEP_SECS ))" +'%Y-%m-%dT%H:%M:%SZ')"
        if [ -z "$issue" ] || ! wt_reap_event_since "$issue" "$since"; then
            log_event watch.worktree_vanished "issue=${issue:-?} dir=$dir reason=no_reap_event"
            unblessed_worktree_vanish_notify "${issue:-?}" "$dir"
        fi
        unset 'KNOWN_WORKTREE_SEEN[$dir]'
    done

    for dir in "${current_dirs[@]}"; do
        KNOWN_WORKTREE_SEEN["$dir"]=$now_epoch
    done
}

# post_pending_brief_marker_sweep <pr#> <worktree-dir> <brief-file>
#
# issue #439: posts the same `<!-- SWARM_PENDING_BRIEF: queued -->` anchor
# comment/idempotency contract as requeue.sh's notify_pr_pending_brief —
# worker-listener.sh's clear_pr_pending_brief_marker clears either one the
# same way — but written from the watcher's own vantage point: it doesn't
# know which requeue.sh call is responsible or what the listener's pane
# state was at queue time, only that a real brief is sitting unclaimed
# right now. Mirrors kill-worktree.sh's notify_pr_brief_orphaned in
# independently composing its own body rather than sourcing requeue.sh's —
# same self-contained-scripts convention as this file's other local
# helpers (see e.g. mtime_epoch elsewhere in this codebase).
post_pending_brief_marker_sweep() {
    local pr="$1" wt="$2" brief_file="$3"
    local -a comment_body=()
    comment_body+=('<!-- SWARM_PENDING_BRIEF: queued -->')
    comment_body+=(':warning: **Swarm: a follow-up brief is queued for the worker on this PR** (found by coordinator-watch.sh'"'"'s periodic sweep, issue #439 — most likely queued before this PR existed, so requeue.sh'"'"'s own marker never posted).')
    comment_body+=('')
    comment_body+=('Merging now may ship without that queued fix.')

    if [ -r "$brief_file" ]; then
        local max_lines=20 total excerpt
        total="$(wc -l < "$brief_file" 2>/dev/null || echo 0)"
        excerpt="$(head -n "$max_lines" "$brief_file" 2>/dev/null | cut -c1-200 | sed -e 's/`\{6,\}/[fence]/g')"
        if [ -n "$excerpt" ]; then
            comment_body+=('')
            comment_body+=('<details><summary><b>What was queued</b> (head of the brief — judge severity without leaving this page)</summary>')
            comment_body+=('')
            comment_body+=('``````text')
            comment_body+=("$excerpt")
            [ "${total:-0}" -gt "$max_lines" ] && comment_body+=("$(printf '… truncated (%s more lines)' "$((total - max_lines))")")
            comment_body+=('``````')
            comment_body+=('</details>')
        fi
    fi

    comment_body+=('')
    comment_body+=('**Next steps — pick one:**')
    comment_body+=('')
    comment_body+=("$(printf '1. **Check whether it is still pending** — on the swarm host:\n   ```bash\n   ls -1 %s/.swarm/tasks/{inbox,processing}\n   ```\n   A file in `inbox/` means not yet claimed; in `processing/` means the worker is on it.' "$wt")")
    comment_body+=('2. **Merge anyway.** Nothing re-dispatches the brief for you. If the worktree is later reaped, the brief is salvaged and a `SWARM_BRIEF_ORPHANED` comment appears here — but that is a record, not a fix.')
    comment_body+=("$(printf '3. **Cancel it** if the brief is obsolete — remove the file(s) listed above from `%s/.swarm/tasks/inbox/`.' "$wt")")
    comment_body+=('')
    comment_body+=('<sub>scripts/coordinator-watch.sh pending_brief_marker_sweep_pass — issue #439 (marker gap when a brief predates its PR).</sub>')

    local comment
    comment="$(printf '%s\n' "${comment_body[@]}")"
    # issue #439 self-review (round 6): `cd "$wt" &&`, matching every other
    # gh call in this file (e.g. activity_poll_pass) — gh resolves the
    # target repo from the CALLER's cwd absent -R, so a coordinator-watch.sh
    # invoked against a project dir different from wherever it happens to
    # be running from would otherwise silently query the wrong repo (or
    # fail) for every one of this pass's PR lookups.
    (cd "$wt" && gh pr comment "$pr" --body "$comment") >/dev/null 2>&1
}

# pending_brief_marker_sweep_pass
#
# issue #439: backstop for requeue.sh's SWARM_PENDING_BRIEF marker — see
# WATCH_PENDING_BRIEF_SWEEP_SECS's header comment for the SAMlytics gap
# this closes (a brief queued before its target PR existed never gets a
# marker at all). For every own worktree with a real unclaimed brief
# (worker_pending_brief) and an OPEN PR whose latest SWARM_PENDING_BRIEF
# marker isn't already "queued", posts one now.
#
# issue #439 self-review (round 7): requeue.sh writes the inbox file
# BEFORE posting its own marker (mktemp+mv, then the PR comment) — a
# sweep tick landing in that narrow window sees a real brief and an OPEN
# PR with no "queued" marker yet, and posts its own. Harmless (both
# comments say the same thing, and worker-listener.sh's clear step
# handles either), just not perfectly idempotent — a rare double "queued"
# comment on the PR, not a functional bug.
pending_brief_marker_sweep_pass() {
    command -v gh >/dev/null 2>&1 || return 0

    local wt branch json pr_num pr_state last brief_file issue comments_raw comments_rc
    local -a dirs=()
    while IFS= read -r wt; do
        [ -n "$wt" ] && dirs+=("$wt")
    done < <(own_worktree_dirs_for_scan "$PROJECT_DIR")

    for wt in "${dirs[@]}"; do
        [ -d "$wt" ] || continue
        worker_pending_brief "$wt" || continue
        branch="$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null)" || continue
        [ -n "$branch" ] || continue
        # cd "$wt" && for both gh calls below: gh resolves the target repo
        # from the caller's cwd absent -R (self-review round 6) — every
        # own worktree here belongs to the same repo as PROJECT_DIR, so
        # either cwd works, but $wt is already at hand.
        json="$(cd "$wt" && gh pr view "$branch" --json number,state -q '"\(.number)\t\(.state)"' 2>/dev/null)" || continue
        [ -n "$json" ] || continue
        IFS=$'\t' read -r pr_num pr_state <<< "$json"
        [ "$pr_state" = "OPEN" ] || continue

        # issue #439 self-review (round 9): the comments lookup's success
        # is checked SEPARATELY from whether it found a marker. Folding a
        # failed `gh pr view` into the same "no marker found" bucket as a
        # genuinely marker-less PR would repost a fresh "queued" comment
        # on every tick gh has a transient hiccup, for as long as the
        # hiccup lasts — worse than round 7's harmless one-time race.
        comments_rc=0
        comments_raw="$(cd "$wt" && gh pr view "$pr_num" --json comments \
            -q '[.comments[] | select(.body | test("SWARM_PENDING_BRIEF:"))] | last | .body // empty' 2>/dev/null)" \
            || comments_rc=$?
        [ "$comments_rc" -eq 0 ] || continue
        # Anchored to the marker line itself, same reason as requeue.sh's
        # notify_pr_pending_brief (its body text mentions the OTHER state
        # in prose, which a bare substring match would also catch).
        last="$(printf '%s' "$comments_raw" \
            | grep -oE '^<!-- SWARM_PENDING_BRIEF: (queued|cleared) -->$' \
            | sed -E 's/^<!-- SWARM_PENDING_BRIEF: (queued|cleared) -->$/\1/' || true)"
        [ "$last" = "queued" ] && continue

        issue="$(basename "$wt" | sed -nE 's/^wt-issue-([0-9]+)$/\1/p')"
        if [ "$DRY_RUN" = "1" ]; then
            echo "[DRY] would post SWARM_PENDING_BRIEF: queued on PR #$pr_num (issue #${issue:-?})"
            continue
        fi
        brief_file="$(worker_pending_brief_path "$wt")"
        if post_pending_brief_marker_sweep "$pr_num" "$wt" "$brief_file"; then
            log_event watch.pending_brief_sweep "pr=$pr_num dir=$wt reason=posted"
        fi
    done
}

# bg_violation_sweep_pass
#
# issue #298: fallback layer for the foreground-only rule — see
# WATCH_BG_VIOLATION_SWEEP_SECS's header comment for the full rationale.
# Enumerates every iss-* window (same style as worker_compact_pass below)
# PLUS the coordinator's own window (issue #385 — the incident #298 exists
# to catch, a ~20h leaked poll loop, happened in a coordinator pane, and the
# original sweep only ever looked at workers), greps its cleaned
# (ANSI-stripped, same technique as worker_pane_busy) pane text for
# WATCH_BG_VIOLATION_PATTERN, and on a NEW match (per the BG_VIOLATION_LOGGED
# dedup map) delivers it. Delivery differs by role: a worker window gets a
# `kind: fyi` message dropped into its own outbox — mktemp-without-.md-suffix
# then mv, the exact atomic convention prompts/worker.md documents for
# worker-authored messages — so the existing WATCH_OUTBOX watcher backend
# (run_inotify/run_poll, already watching every wt-issue-*/.swarm/tasks/
# outbox/*.md) picks it up and wakes the coordinator via the normal
# on_message path; the coordinator window has no outbox of its own to drop a
# message into (nor should the watcher send-keys into it — prompts/
# coordinator.md's "Never tmux send-keys into another agent's pane" applies
# to the watcher's own restraint here too), so it gets only the log_event
# call below (category watch.bg_violation, window=coordinator) and relies on
# prompts/coordinator.md's per-wake self-check to surface it in the next wake
# digest. Local capture-pane only (no gh/network calls), so this lives in
# run_watch_timer_loop like orphan_sweep_pass, not its own dedicated
# background process.
#
# Known gap, shared with coordinator_pane_state/coordinator_pane_busy below
# (pre-existing, not introduced here): `capture-pane -t "$SESSION_NAME:$win"`
# with no pane index captures the window's ACTIVE pane. If the coordinator
# window ever gets split with the new pane left active — demo-driver.sh's
# Beat 6 (`tail -F .swarm/events.log`) does exactly this — this sweep (like
# every other coordinator-pane probe in this file) is scanning that split
# pane, not the actual claude coordinator pane, until focus returns. A real
# coordinator violation during that window would go undetected until the
# split pane loses focus, not just risk a false positive (the embedded
# self-match-guard token above handles the false-positive side of that same
# scenario). Fixing this for every coordinator-pane probe at once (pin
# `coordinator.0`, or iterate `list-panes`) is out of scope for #385.
bg_violation_sweep_pass() {
    tmux has-session -t "$SESSION_NAME" 2>/dev/null || return 0

    local windows
    windows="$(tmux list-windows -t "$SESSION_NAME" -F '#{window_name}' 2>/dev/null | grep '^iss-' || true)"
    if tmux list-windows -t "$SESSION_NAME" -F '#{window_name}' 2>/dev/null | grep -qx 'coordinator'; then
        windows="$(printf '%s\n%s\n' "$windows" 'coordinator' | sed '/^$/d')"
    fi
    [ -n "$windows" ] || return 0

    local win
    while IFS= read -r win; do
        [ -n "$win" ] || continue
        local issue wt_dir is_coordinator content clean matched_lines ml cand_lineno cand lineno matched
        if [ "$win" = "coordinator" ]; then
            is_coordinator=1
            issue="coordinator"
            wt_dir=""
        else
            is_coordinator=0
            issue="${win#iss-}"
            [[ "$issue" =~ ^[0-9]+$ ]] || continue
            wt_dir="$(own_wt_dir_for_issue "$issue")" || continue
        fi

        content="$(tmux capture-pane -t "$SESSION_NAME:$win" -p -S -200 2>/dev/null)" || continue
        clean="$(printf '%s\n' "$content" | sed 's/\x1b\[[0-9;?]*[A-Za-z]//g; s/\x1b\][^\x07]*\x07//g; s/\x1b[()][AB012]//g; s/\r/\n/g')"
        # `-n` (line-numbered) + `-o` (match-only) gives "N:matched-text"
        # per hit, one per line — every candidate is needed (not just the
        # latest) because the self-match guard below can disqualify the
        # most recent one and a real earlier marker would otherwise be
        # hidden behind it (a self-review finding on the tail-1 version of
        # this line). `|| true`: under this file's `set -euo pipefail`,
        # the common no-match case makes grep exit 1 — pipefail then makes
        # the whole pipeline (and thus this bare assignment) exit
        # non-zero, which would abort the script under `set -e` on every
        # ordinary tick. Only this function's sole call site
        # (`bg_violation_sweep_pass || true`) currently masks that; fix it
        # here too so a future direct call doesn't silently kill the
        # watcher on its most common path.
        matched_lines="$(printf '%s\n' "$clean" | LC_ALL=C grep -noE "$WATCH_BG_VIOLATION_PATTERN" 2>/dev/null)" || true

        if [ -z "$matched_lines" ]; then
            unset "BG_VIOLATION_LOGGED[$win]" 2>/dev/null || true
            continue
        fi
        # Self-match guard (#298): the marker text this sweep looks for is
        # quoted verbatim in this project's own docs/comments/PR text
        # (docs/advanced-usage.md, prompts/worker.md, this file's header,
        # the issue itself) — a worker that cats/greps those files, or
        # views this feature's PR, renders the literal marker in its pane
        # with no real backgrounded shell behind it. Rather than tighten
        # WATCH_BG_VIOLATION_PATTERN (risking a missed real marker), treat
        # a self-reference token found NEAR a candidate's line (prose
        # quotes the marker and the token in the same sentence/paragraph)
        # as documentation, not a violation for THAT candidate — scoped to
        # a small window instead of the whole 200-line capture, since an
        # earlier self-review found scanning the whole capture lets an
        # unrelated, distant appearance of these tokens (e.g. worker.md's
        # own description of this feature sitting in scrollback) mask a
        # real, current violation elsewhere in the pane. Walks candidates
        # most-recent-first (`tac`) and takes the first one NOT guarded,
        # so a guarded/quoted latest hit no longer hides a real earlier one.
        matched=""
        lineno=""
        while IFS= read -r ml; do
            [ -n "$ml" ] || continue
            cand_lineno="${ml%%:*}"
            cand="${ml#*:}"
            if printf '%s\n' "$clean" | sed -n "$((cand_lineno > 3 ? cand_lineno - 3 : 1)),$((cand_lineno + 3))p" \
                | LC_ALL=C grep -qE 'WATCH_BG_VIOLATION|SANDBOX_ALLOW_BACKGROUND_TASKS|CLAUDE_CODE_DISABLE_BACKGROUND_TASKS'; then
                continue
            fi
            matched="$cand"
            lineno="$cand_lineno"
            break
        done < <(printf '%s\n' "$matched_lines" | tac)

        if [ -z "$matched" ]; then
            unset "BG_VIOLATION_LOGGED[$win]" 2>/dev/null || true
            continue
        fi
        [ -n "${BG_VIOLATION_LOGGED[$win]:-}" ] && continue
        BG_VIOLATION_LOGGED[$win]=1

        # DRY_RUN=1 (log-only, like every other side-effecting pass in this
        # file — autoclose, orphan_sweep_pass above): don't actually drop a
        # real outbox message into a worker's worktree, just log that this
        # pass would have.
        #
        # The "(WATCH_BG_VIOLATION_PATTERN)" tag right next to marker=$matched
        # (issue #385): demo-driver.sh's Beat 6 tails this project's own
        # events.log into a pane split off the coordinator window (window 0
        # is named "coordinator" — see llm-start.sh's `new-session -n
        # coordinator`), so any WORKER's violation line can end up rendered
        # inside the very coordinator window bg_violation_sweep_pass now
        # scans. Without a guard token embedded in the logged line itself,
        # that tailed line has nothing to stop it from being reattributed as
        # a fresh window=coordinator sighting on the next sweep tick — the
        # self-match guard only helps once the candidate match's surrounding
        # ±3 lines actually carry one of its tokens, and a bare events.log
        # line otherwise doesn't.
        if [ "$DRY_RUN" = "1" ]; then
            log_event watch.bg_violation "issue=$issue window=$win marker=$matched (WATCH_BG_VIOLATION_PATTERN) dry_run=1"
            continue
        fi
        log_event watch.bg_violation "issue=$issue window=$win marker=$matched (WATCH_BG_VIOLATION_PATTERN)"

        # The coordinator window has no worktree/outbox of its own to drop
        # a message into, and send-keys'ing a live coordinator pane is
        # exactly what prompts/coordinator.md forbids doing to any agent's
        # pane (see this function's header comment) — the log_event call
        # above is this role's entire delivery. prompts/coordinator.md's
        # per-wake self-check greps events.log for its own violations.
        [ "$is_coordinator" = "1" ] && continue

        [ "$WATCH_OUTBOX" = "1" ] || continue
        local outbox tmp
        outbox="$wt_dir/.swarm/tasks/outbox"
        mkdir -p "$outbox" 2>/dev/null || continue
        tmp="$(mktemp -p "$outbox" .tmp.XXXXXX 2>/dev/null)" || continue
        # Mentions WATCH_BG_VIOLATION_SWEEP_SECS deliberately: besides
        # pointing the reader at the config knob, it's one of this
        # function's own self-match guard tokens (see above) — so if this
        # message ever gets rendered back into an iss-* pane (a worker
        # cats its own outbox, or the coordinator relays it), the sweep
        # recognizes its own output instead of re-triggering on it.
        cat > "$tmp" <<EOF
---
kind: fyi
task_id: watcher-bg-violation
ts: $(date -u +%Y-%m-%dT%H:%M:%SZ)
---
Automated foreground-only check (issue #298, WATCH_BG_VIOLATION_SWEEP_SECS) detected a background-shell UI marker in iss-$issue's tmux pane: "$matched". This usually means a Bash call ran with run_in_background=true (or a shell-level &/nohup/disown), against prompts/worker.md's "Run long commands in the foreground" rule. Flag it in your next report as a worker-policy violation per prompts/coordinator.md's existing "If a worker backgrounds anyway" guidance — the pane may be mid-task, so don't try to autoremediate, just surface it.
EOF
        mv "$tmp" "$outbox/$(date -u +%Y%m%dT%H%M%SZ)-bg-violation-iss-$issue.md" 2>/dev/null \
            || rm -f "$tmp" 2>/dev/null
    done <<< "$windows"
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
        # issue #357: $WORKSPACE can be shared with sibling projects under
        # flat grouping, so verify this glob hit is actually registered
        # against THIS project's git before acting on it (see
        # is_own_worktree_dir) — a same-numbered foreign worktree's status
        # file would otherwise trigger maybe_run_check inside SOMEONE
        # ELSE's worktree.
        is_own_worktree_dir "$wt_dir" || continue
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

# reconcile_missing_outcome <worktree-dir> <issue> <task_id> <reason>
#
# (issue #451, α of #450 finding 1 — supersedes #314's synth_outcome)
# Called from maybe_run_check right after the check-claim is won, i.e. the
# same one-per-done-task moment synth_outcome used to fire. Where that
# function FABRICATED a done/<id>.ok.json so the coordinator's
# worker-finished wake (on_outcome -> coord.wake, which only triggers on a
# new done/<id>.{ok,err}.json) had something to trigger on, this function
# never writes one — the worker is now the sole writer, via
# scripts/task-done.sh (prompts/worker.md § "Task completion"), so a
# genuine completion record lands in the SAME watched path on its own and
# the existing inotify/poll -> worker.finish -> coord.wake pipeline fires
# unmodified with no coordinator help needed.
#
# A done signal (ready-for-review status, or a PR appearing) with no
# outcome record yet is not itself a problem — it usually just means the
# worker hasn't reached its task-done.sh step yet, or (pre-#451 worktree)
# never will on its own; see task-done.sh's header for that migration
# story. Log it (watch.reconcile) for visibility and no-op otherwise:
# duplicate suppression (this — or a second call — seeing an existing
# record does nothing) plus this function deliberately taking NO other
# action.
#
# An earlier version of this also dropped a one-time reminder brief into
# the worktree's inbox/. Removed (self-review finding on this PR): that
# file is indistinguishable from a real task brief to claim_next_task()
# AND to WORKER_AUTO_DELIVER's worker_pending_brief() — a parked worker
# whose current task is already status=ready-for-review gets /quit'd to
# "claim" it, burning a full extra agent dispatch on what was meant to be
# a one-line reminder, and (when maybe_run_check's PR-open backstop had
# fallen back to a synthesized task_id like "pr-issue-N", which isn't
# purely digits) the resulting done/nudge-pr-issue-N.ok.json defeats
# on_outcome's `-<issue>` filename parser. Logging alone fully solves the
# duplicate-record problem this issue exists for; a safer proactive nudge
# (a channel claim_next_task never treats as claimable work) is future
# scope, not this α slice.
reconcile_missing_outcome() {
    local wt_dir="$1" issue="$2" task_id="$3" reason="${4:-check_claim_won}"
    local done_dir="$wt_dir/.swarm/tasks/done"

    local f
    for f in "$done_dir/${task_id}.ok.json" "$done_dir/${task_id}.err.json"; do
        [ -e "$f" ] && return 0   # already recorded — nothing to reconcile
    done

    log_event watch.reconcile "issue=$issue task_id=$task_id reason=$reason"
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

    # Reason for reconcile_missing_outcome below, fixed BEFORE task_id gets
    # resolved/defaulted a few lines down: status_poll_pass always passes
    # an explicit task_id (it just read the status file); pr_poll_pass
    # never does (PR-open backstop, issue-only).
    local reconcile_reason="pr_open_no_outcome"
    [ -n "$task_id" ] && reconcile_reason="status_ready_no_outcome"

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

    # issue #451 (was #314's synth_outcome call): winning the claim is the
    # one moment each done task passes through exactly once — reconcile
    # here, before any of the skip/return branches below, so EVERY done
    # detection that still lacks an outcome record gets logged, including
    # pr_terminal skips: a merged-while-coordinator-slept PR with no
    # outcome yet is precisely a gap worth flagging. Never writes
    # done/*.json itself.
    reconcile_missing_outcome "$wt_dir" "$issue" "$task_id" "$reconcile_reason"

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
    local last_pr_poll=0 last_orphan_sweep=0 last_bg_violation_sweep=0 last_activity_poll=0 last_coord_wake_retry=0 last_coord_wake_busy_retry=0 last_worktree_sweep=0 last_pending_brief_sweep=0 now
    while true; do
        sleep 2
        [ "$WATCH_CHECK_ON_DONE" = "1" ] && { status_poll_pass || true; }
        if [ "$COORD_WAKE_RETRY_SECS" -gt 0 ]; then
            now=$(date +%s)
            if [ $((now - last_coord_wake_retry)) -ge "$COORD_WAKE_RETRY_SECS" ]; then
                coord_wake_retry_pass || true
                last_coord_wake_retry=$now
            fi
        fi
        # issue #430: independent cadence/state from the dirty-draft retry
        # above — see COORD_WAKE_BUSY_RETRY_SECS's header comment for why
        # these are two separate gates rather than one shared retry.
        if [ "$COORD_WAKE_HOLD_RETRY_SECS" -gt 0 ]; then
            now=$(date +%s)
            if [ $((now - last_coord_wake_busy_retry)) -ge "$COORD_WAKE_HOLD_RETRY_SECS" ]; then
                coord_wake_hold_retry_pass || true
                last_coord_wake_busy_retry=$now
            fi
        fi
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
        if [ "$WATCH_BG_VIOLATION_SWEEP_SECS" -gt 0 ]; then
            now=$(date +%s)
            if [ $((now - last_bg_violation_sweep)) -ge "$WATCH_BG_VIOLATION_SWEEP_SECS" ]; then
                bg_violation_sweep_pass || true
                last_bg_violation_sweep=$now
            fi
        fi
        if [ "$WATCH_ACTIVITY_POLL_SECS" -gt 0 ]; then
            now=$(date +%s)
            if [ $((now - last_activity_poll)) -ge "$WATCH_ACTIVITY_POLL_SECS" ]; then
                activity_poll_pass || true
                last_activity_poll=$now
            fi
        fi
        if [ "$WATCH_WORKTREE_SWEEP_SECS" -gt 0 ]; then
            now=$(date +%s)
            if [ $((now - last_worktree_sweep)) -ge "$WATCH_WORKTREE_SWEEP_SECS" ]; then
                worktree_vanish_sweep_pass || true
                last_worktree_sweep=$now
            fi
        fi
        if [ "$WATCH_PENDING_BRIEF_SWEEP_SECS" -gt 0 ]; then
            now=$(date +%s)
            if [ $((now - last_pending_brief_sweep)) -ge "$WATCH_PENDING_BRIEF_SWEEP_SECS" ]; then
                pending_brief_marker_sweep_pass || true
                last_pending_brief_sweep=$now
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

# probe_ctx_window
#
# Sibling of probe_ctx_used() above, reading the SAME probe file for the
# DENOMINATOR instead of the numerator — the coordinator model's own
# context-window size, used by coordinator_compact_effective_threshold() to
# scale the compact trigger (issue #273, mirroring worker_pane_ctx_window()
# from issue #259). Echoes the parsed window size and returns 0, or returns
# 1 with no output, on the same failure modes as probe_ctx_used() (missing/
# stale/unreadable probe, or nothing parseable at any of the jq paths below
# — the "?" JSON-schema-mismatch fallback). jq paths mirror
# statusline-with-context.sh's own ctx_total extraction, since the probe
# file IS that script's raw stdin payload.
probe_ctx_window() {
    [ "$HAVE_JQ" = "1" ] || return 1
    [ -r "$AUTO_COMPACT_PROBE" ] || return 1
    local mtime now
    mtime=$(mtime_epoch "$AUTO_COMPACT_PROBE") || return 1
    [ -n "$mtime" ] || return 1
    now=$(date +%s)
    [ $((now - mtime)) -le "$AUTO_COMPACT_PROBE_MAX_AGE_SECS" ] || return 1

    local window
    window=$(jq -r '
        .context_window.context_window_size //
        .context_window.total //
        .context.window_size //
        .context.total //
        .model_context_window //
        empty
    ' "$AUTO_COMPACT_PROBE" 2>/dev/null) || true
    [[ "$window" =~ ^[0-9]+$ ]] || return 1
    echo "$window"
}

# coordinator_compact_effective_threshold
#
# Echoes the coordinator's effective compact threshold (always succeeds —
# pure arithmetic over AUTO_COMPACT_* env vars plus whatever
# probe_ctx_window() could parse, never a probe/jq failure mode of its own).
# = min(AUTO_COMPACT_PCT% of the parsed context window,
# AUTO_COMPACT_THRESHOLD_CAP_TOKENS); falls back to the flat
# AUTO_COMPACT_THRESHOLD_TOKENS when the window denominator isn't parseable
# (no fresh probe, or a schema mismatch none of probe_ctx_window()'s jq
# paths match) — same fail-open contract as every other probe-parsing
# helper in this file. Mirrors worker_compact_effective_threshold() (issue
# #259) minus the wrap-up gap, which has no coordinator-side equivalent —
# see issue #273.
coordinator_compact_effective_threshold() {
    local window base
    if window="$(probe_ctx_window)" && [ -n "$window" ]; then
        base=$(( window * AUTO_COMPACT_PCT / 100 ))
        [ "$base" -gt "$AUTO_COMPACT_THRESHOLD_CAP_TOKENS" ] && base="$AUTO_COMPACT_THRESHOLD_CAP_TOKENS"
    else
        base="$AUTO_COMPACT_THRESHOLD_TOKENS"
    fi
    echo "$base"
}

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
    clean="$(printf '%s\n' "$content" | LC_ALL=C sed 's/\x1b\[2m[^\x1b]*//g' | LC_ALL=C sed 's/\x1b\[[0-9;?]*[A-Za-z]//g; s/\x1b\][^\x07]*\x07//g; s/\x1b[()][AB012]//g; s/\r/\n/g; s/\xc2\xa0/ /g')"
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
    printf '%s\n' "$clean" \
        | LC_ALL=C grep -vE "ctx: [0-9]+[kM]?/[0-9]+[kM]?[[:space:]]*\([0-9]+%\)|\(shift\+tab to cycle\)|^[[:space:]]*[─╭╮╰╯│]+[[:space:]]*\$|$COMPACT_COMPOSER_CHROME_PATTERN" \
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

# compact_confirm_submitted <tmux-target> <busy-pattern> <pasted-text>
#
# (issue #290) Best-effort check that an injected <pasted-text> + Enter
# actually submitted, rather than being consumed by the CLI's slash-command
# autocomplete menu (see maybe_auto_compact/maybe_worker_compact's
# injection comment for the race this guards). True (rc 0, "confirmed
# submitted") if the pane already matches <busy-pattern> (a turn/compaction
# started) OR the composer's last rendered line no longer starts with
# <pasted-text>. False (rc 1) only when that exact text is still sitting
# there un-submitted — the caller resends Enter once in that case.
compact_confirm_submitted() {
    local target="$1" busy_pattern="$2" pasted="$3" content clean last
    content="$(tmux capture-pane -t "$target" -p 2>/dev/null)" || return 1
    clean="$(printf '%s\n' "$content" | sed 's/\x1b\[[0-9;?]*[A-Za-z]//g; s/\x1b\][^\x07]*\x07//g; s/\x1b[()][AB012]//g; s/\r/\n/g')"
    printf '%s\n' "$clean" | LC_ALL=C grep -qE "$busy_pattern" && return 0
    last="$(compact_last_pane_line "$target")" || true
    case "$last" in
        "$pasted"*) return 1 ;;
        *) return 0 ;;
    esac
}

# compact_replay_detected <tmux-target>
#
# (issue #292) True (rc 0) if <target>'s pane's LAST rendered line (via
# compact_last_pane_line, not a whole-pane grep) matches COMPACT_REPLAY_
# PATTERN — the CLI's post-compact continuation replaying the prompt that
# triggered the compaction, when that prompt was itself "/compact" (see this
# file's COMPACT_REPLAY_PATTERN header comment for the transcript-verified
# forensics). Deliberately scoped to the last line rather than the whole
# visible pane (self-review finding on this function's first version): a
# whole-pane grep would still match long after the replay text scrolled to
# a non-terminal line — including, on THIS repo specifically, a worker pane
# that's simply viewing/editing this file or its tests, both of which
# contain the literal string "Not enough messages to compact." as plain
# source text, nowhere near an actual compaction. Scoping to the last line
# matches the real incident's actual shape (it WAS the last thing printed)
# while self-healing the moment anything else renders below it (a new turn,
# a statusline refresh, an idle prompt redraw) — the same trade-off
# compact_composer_clear already makes for the same reason.
compact_replay_detected() {
    local target="$1" last
    last="$(compact_last_pane_line "$target")" || true
    printf '%s\n' "$last" | LC_ALL=C grep -qE "$COMPACT_REPLAY_PATTERN"
}

# compact_retract_queued <tmux-target> <event-prefix> <extra-log-fields> [busy-pattern]
#
# (issue #265) Best-effort retraction of an injected "/compact" that a
# phase=start timeout suggests never actually started — most likely because
# it landed queued behind an already-in-flight turn that AUTO_COMPACT_BUSY_
# PATTERN/WORKER_COMPACT_BUSY_PATTERN failed to recognize as busy (a
# detection blind spot; issue #266 was one such regression, issue #290's
# autocomplete-menu race was another — see COMPACT_SUBMIT_SETTLE_SECS — and
# this is the safety net for any future one). Left alone, that queued
# "/compact" fires whenever the real in-flight turn eventually ends — often
# minutes later, well after the reasoning that justified compacting has
# gone stale, and sometimes stacking with a second stale injection from the
# very next sweep (the originally reported symptom).
#
# issue #290/#274: if <busy-pattern> is given and STILL matches the pane at
# retraction time, this is a no-op — logs "<event-prefix>.retract_skip" and
# returns without sending a single keystroke. A phase=start timeout can be
# a FALSE positive (e.g. a compaction that's genuinely running but whose
# busy anchor some future regression misses, the same shape as #274's
# incident this file's AUTO_COMPACT_BUSY_PATTERN header comment describes),
# and Escape/Backspace must never fire into a pane that's actually busy.
#
# Otherwise sends a single Escape — per issue #265, BELIEVED (not
# independently verified against a live pane) to clear a QUEUED follow-up
# message without touching an in-flight turn. Take that belief with a grain
# of salt: this same file's AUTO_COMPACT_BUSY_PATTERN/WORKER_COMPACT_BUSY_
# PATTERN header comments document a persistent "(esc to interrupt)" hint
# shown for the ENTIRE duration of any in-flight turn — i.e. Escape is
# ALSO documented, elsewhere in this very file, as the interrupt key for a
# turn with nothing queued behind it. Whether a genuinely queued follow-up
# changes that (cancel-the-queue-first, common in chat TUIs) or Escape just
# interrupts regardless is exactly the "re-verify against a live pane"
# uncertainty a self-review flagged on this function's first version. This
# is why this function must NEVER send Ctrl-C or anything else definitely
# more destructive than Escape, and why the retraction's actual effect is
# never assumed either way — only re-capture-and-log decides the verdict.
# COMPACT_RETRACT_BACKSPACES keystrokes follow as cleanup for any stray
# composer text Escape didn't reach — issue #290 settled EMPIRICALLY (via
# the observed "/compa" ghost, a 6-char leftover after only 3 backspaces
# against a 9-char "/compact " composer) that Escape does NOT clear the
# composer on its own; see that var's header comment for why the default
# moved from 3 to 12.
#
# Then re-captures the pane and requires BOTH: COMPACT_QUEUED_MARKER_PATTERN
# gone, AND compact_composer_clear true (issue #290 — the marker-only check
# used by #265/#272 could never have caught a partial-clear ghost, which is
# how "coord.compact.retracted" got logged four times on 2026-08-16 against
# panes that still visibly held "/compa"). Logs "<event-prefix>.retracted"
# (both hold) or "<event-prefix>.retract_failed" (either doesn't)
# accordingly. Fails open like everything else in this file: a tmux error
# along the way just leaves the re-capture to decide the verdict.
compact_retract_queued() {
    local target="$1" prefix="$2" extra="$3" busy_pattern="${4:-}"

    if [ -n "$busy_pattern" ]; then
        local pre_content pre_clean
        pre_content="$(tmux capture-pane -t "$target" -p 2>/dev/null)" || pre_content=""
        pre_clean="$(printf '%s\n' "$pre_content" | sed 's/\x1b\[[0-9;?]*[A-Za-z]//g; s/\x1b\][^\x07]*\x07//g; s/\x1b[()][AB012]//g; s/\r/\n/g')"
        if printf '%s\n' "$pre_clean" | LC_ALL=C grep -qE "$busy_pattern"; then
            log_event "${prefix}.retract_skip" "reason=busy $extra"
            return 0
        fi
    fi

    tmux send-keys -t "$target" Escape 2>/dev/null || true
    sleep 1
    local i
    for ((i = 0; i < COMPACT_RETRACT_BACKSPACES; i++)); do
        tmux send-keys -t "$target" BSpace 2>/dev/null || true
    done
    sleep 1

    local content clean
    content="$(tmux capture-pane -t "$target" -p 2>/dev/null)" || content=""
    clean="$(printf '%s\n' "$content" | sed 's/\x1b\[[0-9;?]*[A-Za-z]//g; s/\x1b\][^\x07]*\x07//g; s/\x1b[()][AB012]//g; s/\r/\n/g')"
    if printf '%s\n' "$clean" | LC_ALL=C grep -qE "$COMPACT_QUEUED_MARKER_PATTERN"; then
        log_event "${prefix}.retract_failed" "$extra"
        return 1
    fi
    if ! compact_composer_clear "$target"; then
        log_event "${prefix}.retract_failed" "$extra"
        return 1
    fi
    log_event "${prefix}.retracted" "$extra"
    return 0
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
# currently-idle CLI session, and its last-probed context usage is at/above
# the effective threshold (coordinator_compact_effective_threshold(), issue
# #273 — scaled to the coordinator's own context window, falling back to
# the flat AUTO_COMPACT_THRESHOLD_TOKENS when that can't be parsed),
# injects a real `/compact` via
# the same load-buffer + paste-buffer + send-keys-Enter mechanism
# llm-start.sh's live-REPL reprompt path uses (Enter actually submits it —
# this is not just populating the input box), then blocks in a poll loop
# until the busy indicator confirms compaction started and later cleared.
#
# Fails open at every step: a missing precondition, a stale/absent probe,
# or either timeout just returns 0 and falls through to the normal wake —
# this is strictly an optimization on top of that wake, never a gate on
# it. ONE deliberate exception (issue #296, AUTO_COMPACT_REQUIRE_WINDOW):
# when `used` parses but the window denominator doesn't — a real, reachable
# probe shape, since probe_ctx_used()/probe_ctx_window() try different jq
# field paths against the same payload — this now fails CLOSED instead
# (coord.compact.skip reason=no_window_for_floor), and will keep doing so
# on every subsequent attempt for as long as that probe shape persists:
# auto-compact effectively goes dark for the session rather than silently
# trusting the flat AUTO_COMPACT_THRESHOLD_TOKENS fallback against an
# unknown true window size (see that knob's header comment for the
# incident this trades off against). The wake itself is NEVER gated by
# this — only the compaction attempt is skipped, same as any other
# coord.compact.skip reason. Set AUTO_COMPACT_REQUIRE_WINDOW=0 to restore
# the old fail-open behavior for a probe shape that's known to trigger
# this in your environment.
#
# Blocking here (a real compaction run is commonly a minute or more)
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

        # issue #273: scale the trigger to the coordinator's own context
        # window instead of the flat AUTO_COMPACT_THRESHOLD_TOKENS — see
        # coordinator_compact_effective_threshold().
        local threshold
        threshold="$(coordinator_compact_effective_threshold)"

        [ "$used" -ge "$threshold" ] || exit 0   # under threshold — the common case

        # issue #296: refuse to inject via the flat-fallback threshold when
        # the coordinator's window size can't be confirmed at all —
        # probe_ctx_window() here is the SAME helper
        # coordinator_compact_effective_threshold() already called above, so
        # this only ever fires when that threshold computation ALSO had to
        # fall back to the flat AUTO_COMPACT_THRESHOLD_TOKENS default rather
        # than a properly scaled/capped one (e.g. a probe schema mismatch,
        # or a daemon running code predating issue #273's window scaling) —
        # see AUTO_COMPACT_REQUIRE_WINDOW's header comment for the incident
        # this closes, and for why this deliberately does NOT re-check the
        # computed threshold's percentage-of-window when the window WAS
        # parsed (an earlier version of this guard did exactly that, and
        # code review caught that it fights AUTO_COMPACT_PCT/
        # _CAP_TOKENS's own intentional scaling for large windows).
        # AUTO_COMPACT_REQUIRE_WINDOW=0 disables this check — same "0
        # disables" convention as AUTO_COMPACT_TICK_SECS/WATCH_PR_POLL_SECS
        # elsewhere in this file — restoring the pre-#296 behavior of
        # trusting the flat fallback verbatim.
        if [ "$AUTO_COMPACT_REQUIRE_WINDOW" = "1" ] && ! probe_ctx_window >/dev/null 2>&1; then
            log_event coord.compact.skip "reason=no_window_for_floor trigger=$trigger"
            exit 0
        fi

        echo "[$(date +%T)] coordinator context at ${used} tokens (>= ${threshold}) — compacting before wake..."
        log_event coord.compact "used=$used threshold=$threshold trigger=$trigger"

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
        rm -f "$tmp_compact" 2>/dev/null || true

        # issue #290: pasting text that starts with "/" opens the CLI's
        # slash-command autocomplete menu. Sending Enter immediately (as
        # this code used to do, with no delay at all) is reliably consumed
        # by that menu — accepting the completion, which leaves
        # "/compact " with a trailing space sitting in the composer —
        # instead of submitting. Runtime-log evidence: nearly every
        # injection across every project logged a phase=start timeout, and
        # only 2 ever reached coord.compact.done. Give the menu
        # COMPACT_SUBMIT_SETTLE_SECS to settle (it auto-resolves once the
        # typed text is an exact, unambiguous command match) before
        # pressing Enter, then re-capture and CONFIRM the Enter actually
        # submitted — never just assume it did — retrying it once if not,
        # before falling through to the start-wait loop below (which still
        # owns the authoritative timeout either way).
        sleep "$COMPACT_SUBMIT_SETTLE_SECS"
        tmux send-keys -t "$SESSION_NAME:coordinator" Enter 2>/dev/null || true
        sleep "$COMPACT_SUBMIT_SETTLE_SECS"
        if ! compact_confirm_submitted "$SESSION_NAME:coordinator" "$AUTO_COMPACT_BUSY_PATTERN" "/compact"; then
            log_event coord.compact.resubmit "trigger=$trigger"
            tmux send-keys -t "$SESSION_NAME:coordinator" Enter 2>/dev/null || true
        fi

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
                # issue #292: an already-empty composer at this checkpoint means
                # there is nothing queued left to retract — a genuine non-submit
                # always leaves ghost/un-cleared composer text here (see
                # COMPACT_RETRACT_BACKSPACES's header comment). The likelier
                # explanation, transcript-verified, is that the injected
                # /compact was delivered to the model as a plain chat message
                # rather than executed as a slash command — see this file's
                # COMPACT_REPLAY_PATTERN header comment for the full forensics.
                if compact_composer_clear "$SESSION_NAME:coordinator"; then
                    log_event coord.compact.delivered_as_text "trigger=$trigger"
                else
                    compact_retract_queued "$SESSION_NAME:coordinator" coord.compact "trigger=$trigger" "$AUTO_COMPACT_BUSY_PATTERN" || true
                fi
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
        #
        # issue #292: also watch for the CLI's own post-compact continuation
        # replaying this same /compact prompt (transcript-verified — see
        # COMPACT_REPLAY_PATTERN's header comment) — a harmless, immediate
        # "Not enough messages to compact." rejection that has nothing to do
        # with whether THIS compaction worked. If seen, skip the ineffective
        # check entirely rather than risk a misread while that text is still
        # on screen. issue #292 self-review: a detected replay is only
        # trusted when the finish-phase "waited" above cleared COMPACT_
        # REPLAY_MIN_REAL_SECS — otherwise the injected /compact may simply
        # have been rejected OUTRIGHT (identical pane text, identical brief
        # busy-then-idle shape) and never compacted anything at all; see
        # COMPACT_REPLAY_MIN_REAL_SECS's header comment.
        local verify_waited=0 probe_mtime_after used_after="" replayed=0
        while [ "$verify_waited" -lt "$AUTO_COMPACT_VERIFY_TIMEOUT_SECS" ]; do
            sleep "$AUTO_COMPACT_POLL_SECS"
            verify_waited=$((verify_waited + AUTO_COMPACT_POLL_SECS))
            if compact_replay_detected "$SESSION_NAME:coordinator"; then
                replayed=1
            fi
            probe_mtime_after=$(mtime_epoch "$AUTO_COMPACT_PROBE" 2>/dev/null) || probe_mtime_after=0
            [ -n "$probe_mtime_after" ] || probe_mtime_after=0
            if [ "$probe_mtime_after" -gt "$probe_mtime_before" ]; then
                used_after="$(probe_ctx_used)" || used_after=""
                break
            fi
        done

        if [ "$replayed" = "1" ] && [ "$waited" -ge "$COMPACT_REPLAY_MIN_REAL_SECS" ]; then
            log_event coord.compact.replayed "before=$used trigger=$trigger"
        elif [ -z "$used_after" ]; then
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

# ── Parked-brief delivery (issue #313) ──────────────────────────────────────
# See this file's WORKER_AUTO_DELIVER header comment for the full incident
# and design. Short version: worker-listener.sh's interactive dispatch_agent
# blocks on the live `claude` process, so a worker that finishes its task and
# parks at rest INSIDE that still-running session (rather than running
# /quit) can never notice a follow-up brief requeue.sh drops into its
# inbox/ — its own claim_next_task loop simply never runs again. Ending the
# session (the same action a human would take per worker-listener.sh's own
# printed instructions) hands control back to that already-correct loop.

# worker_pending_brief_path <worktree-dir>
#
# Prints the path of the oldest real (non-tmp) brief sitting in
# <worktree>/.swarm/tasks/inbox/, or nothing if none. Same non-tmp filter
# and oldest-first ordering claim_next_task() itself uses, so the filename
# this reports is always the one claim_next_task would actually pick up
# next — needed so issue #437's worker.deliver.ok event can name the brief
# it's reporting on, not just "something".
worker_pending_brief_path() {
    local wt_dir="$1"
    find "$wt_dir/.swarm/tasks/inbox" -maxdepth 1 -type f -not -name '.tmp.*' 2>/dev/null | sort | head -1
}

# worker_pending_brief <worktree-dir>
#
# True (rc 0) if a real (non-tmp) brief is sitting in <worktree>/.swarm/
# tasks/inbox/, waiting to be claimed.
worker_pending_brief() {
    [ -n "$(worker_pending_brief_path "$1")" ]
}

# worker_current_task_terminal <worktree-dir>
#
# True (rc 0) ONLY if the task currently claimed — normally the one entry
# in <worktree>/.swarm/tasks/processing/ (claim_next_task() moves it there
# on pickup and doesn't move it out again until dispatch_agent returns),
# OR, since issue #451, the most recently archived done/*.md when
# processing/ is already empty because scripts/task-done.sh moved it
# there while the agent process is still alive (see this function's own
# "if [ -z "$proc_file" ]" branch below for why processing/-empty can no
# longer mean "nothing in flight" the way it always used to) — has a
# status file reporting a genuinely terminal state: "ready-for-review" or
# "done-no-pr".
#
# Self-review finding on this feature's first version: gating delivery on
# pane idleness alone is not enough. A worker parked `blocked` (asked a
# decision-needed question, awaiting the coordinator's answer — exactly the
# state prompts/coordinator.md's "unblock it with a requeue.sh follow-up
# brief" line describes) renders as idle, cli, composer-empty — indistinguishable
# from a worker that's actually finished. Injecting /quit there would end the
# session before its current task ever truly concluded; worker-listener.sh's
# write_outcome() can't tell a natural post-completion /quit from one forced
# mid-decision — exit code 0 maps straight to "ok", and the #287 minimum-
# interaction floor doesn't catch it either (a blocked worker already has a
# status file, so that check's own no-status-file precondition never fires).
# The result: a real fand-etl-shaped decision-needed task gets recorded as a
# false, silent success. So this is a positive (fail-CLOSED) gate — the
# opposite of every other check in this feature, which fail open — because
# the cost of a missed automatic delivery (falls back to the documented
# manual /quit) is far lower than the cost of corrupting a task's outcome
# record. A processing/ entry with no status file yet, or one whose state is
# "blocked" (or anything else), is treated as NOT confirmed finished and
# blocks delivery — see worker.deliver.skip reason=task_not_terminal.
#
# Deliberately NOT worker_task_done(): that function's (a)/(b) signals are
# themselves gated on `.swarm/tasks/processing/` being EMPTY (a staleness
# guard against stale done/status files from an EARLIER, already-concluded
# task — see its own header comment) — a precondition that, pre-#451,
# could never hold while this function's primary (processing/-non-empty)
# branch is the one running, since processing/ then holds exactly the
# in-flight task for as long as its agent process is alive. This reads
# the CURRENT processing/ entry's own status file directly instead, with
# no such guard needed (there's nothing stale to guard against — it's
# always THIS task's own record or nothing). The issue #451 fallback
# branch below, which DOES run with processing/ empty, still doesn't
# reuse worker_task_done() — it targets one specific archived task_id
# (the most recently moved done/*.md) rather than accepting any
# ready-for-review status file in the worktree, avoiding exactly the
# stale-record risk worker_task_done()'s own guard exists for.
#
# issue #370: the exact-name lookup above can miss even when the current
# task genuinely IS terminal — observed in the wild as status/issue-517.json
# / status/pr-issue-397.json sitting next to a
# processing/20260906-230823-517.md brief (a worker session that didn't
# echo its brief's own inbox filename back as the $TASK_ID it names its
# status write after — see prompts/worker.md's "Worker status file"
# convention; the coordinator side never writes a bare status/<id>.json
# itself, only <id>.check.json/.check-claim/.check-run.sh, so a mismatched
# NAME always traces back to the worker). Exact-name miss then wedges
# delivery FOREVER — task_not_terminal never self-heals on its own, unlike
# this function's every other caller-side skip reason. So on a miss, fall
# back to scanning status/ for another record — but naively accepting "any
# ready-for-review file in this worktree" would reintroduce exactly the
# false-completion bug this function exists to prevent: per
# worker_task_done()'s header comment, nothing ever deletes a requeued
# worktree's past status files, so a genuinely in-flight NEW task could
# misread an OLD task's leftover ready-for-review record as its own. Guard
# with a timestamp instead — but ctime of proc_file, NOT its mtime:
# requeue.sh can drop a follow-up brief into inbox/ well before it's
# claimed (worker.md's "mid-task" follow-up case), and claim_next_task()'s
# same-filesystem mv preserves that brief's mtime (content unchanged) while
# only bumping its ctime (rename(2) always updates ctime). mtime would
# therefore read as "when the brief was authored", which can predate a
# PRIOR task's own conclusion and status write — exactly the false-positive
# a self-review pass on this fix caught: an in-flight/blocked task B (brief
# authored before task A even finished) would wrongly inherit A's terminal
# status. ctime is "when this brief was actually claimed into processing/",
# which — because dispatch_agent(A) fully returns before the SAME listener
# process ever calls claim_next_task() again — is always strictly after any
# prior task's own status write.
#
# Among candidates newer than proc_file's ctime, trust the newest mtime
# second, not just the first terminal one a glob happens to visit — another
# self-review finding: if the same anomalous worker session wrote status
# under two different mismatched names at different points (e.g. an earlier
# ready-for-review under one name, then genuinely went `blocked` again and
# recorded that under another), taking the first terminal match in glob
# order could pick the STALE ready-for-review one and miss the newer,
# authoritative blocked state — the false-completion bug all over again.
# And on a TIE within that newest second (same whole-second resolution
# problem as the claim boundary above), a non-terminal record wins over a
# terminal one — see the second loop below.
#
# mtime_epoch/ctime_epoch resolve to whole seconds, so the boundary compare
# below is strict (>), not >=: a same-second collision between a PRIOR
# task's status write and the claim that follows it (both bucket into the
# same epoch second) must NOT let that prior record satisfy the fallback —
# false-completion risk again, on the more dangerous side of this fail-
# CLOSED gate. The cost of the stricter bound falls on the harmless side
# instead: a same-second write of the CURRENT task's own mismatched-name
# status just misses this sweep and gets picked up on the next
# WORKER_COMPACT_SCAN_SECS tick once its mtime reads a full second later —
# a delay, not a wrong answer, which is exactly the trade this whole
# function is built to prefer (see this function's very first comment
# block above).
worker_current_task_terminal() {
    local wt_dir="$1"
    [ "$HAVE_JQ" = "1" ] || return 1
    local proc_file task_id status_file state
    proc_file="$(find "$wt_dir/.swarm/tasks/processing" -maxdepth 1 -type f 2>/dev/null | head -1)"
    if [ -z "$proc_file" ]; then
        # issue #451 self-review finding: scripts/task-done.sh (the
        # worker's own mandatory last step) moves processing/<id>.md into
        # done/ WHILE the dispatched agent process may still be alive —
        # that's the entire point of task-done.sh (see its own header).
        # Pre-#451, "processing/ is empty" only ever meant "no task in
        # flight", so returning 1 (not confirmed terminal) here was safe.
        # Now it doesn't: a worker that correctly calls task-done.sh would
        # make this function return 1 FOREVER for that window, and per
        # this function's own #370 comment above, task_not_terminal never
        # self-heals on its own — permanently wedging WORKER_AUTO_DELIVER,
        # the exact 2.5-hour fand-etl stall it exists to prevent. Recover
        # the task_id from the most recently ARCHIVED brief in done/
        # instead (ctime, same "when was this actually claimed/moved"
        # signal the #370 fallback below already relies on — task-done.sh's
        # mv bumps it same as claim_next_task's mv does) and apply the
        # same terminal check against it. Deliberately NOT replicating
        # #370's mismatched-status-filename fallback machinery below for
        # this branch — that edge case is orthogonal and stays scoped to
        # the processing/-based path; a done/*.{ok,err}.json's mere
        # existence is checked instead, which needs no such fallback since
        # (unlike a still-in-progress processing/ entry) task-done.sh only
        # ever writes one once the worker has actually declared done.
        local done_dir="$wt_dir/.swarm/tasks/done" f fctime best_ctime=-1
        shopt -s nullglob
        for f in "$done_dir"/*.md; do
            fctime="$(ctime_epoch "$f")"
            [ -n "$fctime" ] || continue
            if [ "$fctime" -gt "$best_ctime" ]; then
                best_ctime="$fctime"
                proc_file="$f"
            fi
        done
        shopt -u nullglob
        [ -n "$proc_file" ] || return 1
        task_id="$(basename "$proc_file" .md)"
        status_file="$wt_dir/.swarm/tasks/status/${task_id}.json"
        if [ -r "$status_file" ]; then
            state="$(jq -r '.state // empty' "$status_file" 2>/dev/null)" || return 1
            case "$state" in
                ready-for-review|done-no-pr) return 0 ;;
                *)                           return 1 ;;
            esac
        fi
        if [ -f "$done_dir/${task_id}.ok.json" ] || [ -f "$done_dir/${task_id}.err.json" ]; then
            return 0
        fi
        return 1
    fi
    task_id="$(basename "$proc_file" .md)"
    status_file="$wt_dir/.swarm/tasks/status/${task_id}.json"
    if [ -r "$status_file" ]; then
        state="$(jq -r '.state // empty' "$status_file" 2>/dev/null)" || return 1
        case "$state" in
            ready-for-review|done-no-pr) return 0 ;;
            *)                           return 1 ;;
        esac
    fi

    local proc_ctime f mtime best_mtime=-1
    proc_ctime="$(ctime_epoch "$proc_file")"
    [ -n "$proc_ctime" ] || return 1
    shopt -s nullglob
    for f in "$wt_dir/.swarm/tasks/status"/*.json; do
        case "$f" in *.check.json) continue ;; esac
        mtime="$(mtime_epoch "$f")"
        [ -n "$mtime" ] && [ "$mtime" -gt "$proc_ctime" ] || continue
        [ "$mtime" -gt "$best_mtime" ] && best_mtime="$mtime"
    done
    if [ "$best_mtime" -eq -1 ]; then
        shopt -u nullglob
        return 1
    fi

    # Second pass, over candidates tied at the newest mtime second only:
    # whole-second resolution can't order same-second writes, so on a tie a
    # NON-terminal record wins — the same fail-closed direction as the
    # strict-> boundary above, applied to the tie-break too (a self-review
    # finding: picking whichever tied file a glob happens to visit first
    # could let a stale ready-for-review beat an equally-timestamped, more
    # current blocked record). saw_terminal tracks whether this pass
    # actually CONFIRMED a terminal record rather than just failing to find
    # a non-terminal one — another self-review finding: a tied file that's
    # unreadable or mid-write (jq parse fails, `continue`s) must not read as
    # an implicit "no objection, must be terminal" default; with nothing
    # confirmed, this falls through to the same fail-closed return 1 as
    # every other uncertain case in this function.
    local saw_terminal=0
    for f in "$wt_dir/.swarm/tasks/status"/*.json; do
        case "$f" in *.check.json) continue ;; esac
        mtime="$(mtime_epoch "$f")"
        [ "$mtime" = "$best_mtime" ] || continue
        state="$(jq -r '.state // empty' "$f" 2>/dev/null)" || continue
        case "$state" in
            ready-for-review|done-no-pr) saw_terminal=1 ;;
            *)
                shopt -u nullglob
                return 1
                ;;
        esac
    done
    shopt -u nullglob
    [ "$saw_terminal" = "1" ] && return 0
    return 1
}

# WORKER_DELIVER_LAST_FAIL / WORKER_DELIVER_FAIL_COUNT / WORKER_DELIVER_GAVE_UP
#
# Same shape and same rationale as WORKER_COMPACT_LAST_FAIL/FAIL_COUNT/
# GAVE_UP just below — per-window backoff bookkeeping, in-memory only, reset
# on a watcher restart.
declare -A WORKER_DELIVER_LAST_FAIL=()
declare -A WORKER_DELIVER_FAIL_COUNT=()
declare -A WORKER_DELIVER_GAVE_UP=()

# worker_deliver_record_failure <issue>
#
# Mirrors worker_compact_record_failure — called after an injected /quit
# fails to end the session (timeout) or ends up as a harmless plain-text
# message (delivered_as_text, still a failure: no session was ended).
worker_deliver_record_failure() {
    local issue="$1" now count
    now=$(date +%s)
    WORKER_DELIVER_LAST_FAIL[$issue]=$now
    count=$(( ${WORKER_DELIVER_FAIL_COUNT[$issue]:-0} + 1 ))
    WORKER_DELIVER_FAIL_COUNT[$issue]=$count
    if [ "$count" -ge "$WORKER_DELIVER_MAX_FAILURES" ]; then
        WORKER_DELIVER_GAVE_UP[$issue]=1
        echo "[$(date +%T)] WARNING: worker iss-$issue failed to end its parked session via /quit $count times in a row — giving up on automatic delivery for this window; the queued brief needs a human to attach and /quit manually"
        log_event worker.deliver.giving_up "issue=$issue failures=$count"
    fi
}

# worker_deliver_record_success <issue>
worker_deliver_record_success() {
    local issue="$1"
    unset "WORKER_DELIVER_LAST_FAIL[$issue]" "WORKER_DELIVER_FAIL_COUNT[$issue]" "WORKER_DELIVER_GAVE_UP[$issue]" "WORKER_DELIVER_TIMED_OUT_BRIEF[$issue]"
    worker_deliver_composer_stall_clear "$issue"
}

# WORKER_DELIVER_COMPOSER_STALL_BRIEF / _COUNT / _ESCALATED (issue #436)
#
# Cross-sweep bookkeeping keyed by issue: how many times in a row
# reason=composer_not_clear has fired for the SAME pending brief — NOT
# strictly "consecutive sweeps": a sweep that skips for a DIFFERENT reason
# in between (pane_busy, backoff, task_not_terminal) leaves this count
# untouched rather than resetting it, since none of those mean the
# composer-clear problem went away. Only a different BRIEF resets it (see
# worker_deliver_record_composer_stall below). This is deliberately
# separate from WORKER_DELIVER_LAST_FAIL/FAIL_COUNT/GAVE_UP above — that
# trio only ever gets touched by worker_deliver_record_failure, which is
# called after a real /quit injection times out or lands as text;
# composer_not_clear returns BEFORE maybe_worker_deliver_brief ever
# attempts an injection, so it's structurally invisible to that machinery.
# Without this, a stuck composer-clear read can skip forever with nothing
# escalating it — exactly the corpusminder-spring 2026-09-18/19 incident
# (1,812 consecutive skips, ~14h) this issue exists for. In-memory only,
# reset on a watcher restart, same contract as every other WORKER_DELIVER_*
# tracker.
declare -A WORKER_DELIVER_COMPOSER_STALL_BRIEF=()
declare -A WORKER_DELIVER_COMPOSER_STALL_COUNT=()
declare -A WORKER_DELIVER_COMPOSER_STALL_ESCALATED=()

# worker_deliver_composer_stall_clear <issue>
#
# Drops this issue's composer-stall bookkeeping entirely — called once a
# delivery actually succeeds (worker_deliver_record_success) or
# worker_deliver_detect_claim confirms the previously-stalled brief was
# claimed some other way (a human's manual /quit). Distinct from the
# per-brief reset inside worker_deliver_record_composer_stall itself (which
# only fires on the NEXT composer_not_clear skip, keyed by comparing against
# whatever brief is pending then) — this is the positive, success-side
# cleanup so a resolved stall doesn't leave a stale WORKER_DELIVER_COMPOSER_
# STALL_ESCALATED flag sitting around under this issue.
worker_deliver_composer_stall_clear() {
    local issue="$1"
    unset "WORKER_DELIVER_COMPOSER_STALL_BRIEF[$issue]" "WORKER_DELIVER_COMPOSER_STALL_COUNT[$issue]" "WORKER_DELIVER_COMPOSER_STALL_ESCALATED[$issue]"
}

# worker_deliver_record_composer_stall <issue> <brief>
#
# Called on every worker.deliver.skip reason=composer_not_clear, right
# alongside that log_event call. Resets the streak to 1 whenever <brief>
# differs from the last one counted against for this issue — a NEW brief
# landing means whatever was stalling before is moot, not a continuation of
# the same stall (see this section's header comment). Once the streak
# reaches WORKER_DELIVER_COMPOSER_STALL_THRESHOLD, logs ONE loud, distinct
# worker.deliver.composer_stalled event — never repeated for the same
# streak (WORKER_DELIVER_COMPOSER_STALL_ESCALATED) — and durably records it
# to the coordinator inbox (coord_inbox_write, issue #430) so it surfaces on
# the coordinator's NEXT wake even if nothing else wakes it in the
# meantime, per prompts/coordinator.md's "Inbox" triage. Deliberately does
# NOT set WORKER_DELIVER_GAVE_UP or otherwise stop maybe_worker_deliver_
# brief from retrying — unlike a failed /quit injection, composer_not_clear
# can still self-heal on its own (a human submits or clears their draft),
# so there's nothing to "give up" on, only something to escalate.
worker_deliver_record_composer_stall() {
    local issue="$1" brief="$2" count
    if [ "${WORKER_DELIVER_COMPOSER_STALL_BRIEF[$issue]:-}" != "$brief" ]; then
        WORKER_DELIVER_COMPOSER_STALL_BRIEF[$issue]="$brief"
        WORKER_DELIVER_COMPOSER_STALL_COUNT[$issue]=0
        unset "WORKER_DELIVER_COMPOSER_STALL_ESCALATED[$issue]"
    fi
    count=$(( ${WORKER_DELIVER_COMPOSER_STALL_COUNT[$issue]:-0} + 1 ))
    WORKER_DELIVER_COMPOSER_STALL_COUNT[$issue]=$count
    if [ "$count" -ge "$WORKER_DELIVER_COMPOSER_STALL_THRESHOLD" ] && [ -z "${WORKER_DELIVER_COMPOSER_STALL_ESCALATED[$issue]:-}" ]; then
        WORKER_DELIVER_COMPOSER_STALL_ESCALATED[$issue]=1
        echo "[$(date +%T)] WARNING: worker iss-$issue has skipped brief delivery $count times (reason=composer_not_clear) for the same queued brief ($brief) — its composer may be misread as dirty (see COMPACT_COMPOSER_CHROME_PATTERN's header comment), or a real draft/decision is genuinely sitting there; investigate with scripts/capture-worker.sh iss-$issue"
        log_event worker.deliver.composer_stalled "issue=$issue brief=$brief skips=$count"
        coord_inbox_write deliver_stall "$(printf 'Worker iss-%s: brief delivery has skipped %s times (reason=composer_not_clear) for the queued brief %s.\n\nCheck: scripts/capture-worker.sh iss-%s\n\nThe composer-clear check may be misreading UI chrome as a draft (docs/tmux-as-channel.md §1d), or a human/decision is genuinely blocking the pane. If the pane really is stuck, attach and either clear the composer or run /quit manually so the queued brief can be claimed.\n' "$issue" "$count" "$brief" "$issue")" || true
    fi
}

# WORKER_DELIVER_PENDING_SEEN (issue #437)
#
# Cross-sweep bookkeeping keyed by issue: the pending brief's basename last
# observed while the window sat parked in "cli" state (empty string once
# nothing is pending). Only ever touched from worker_deliver_detect_claim,
# which maybe_worker_deliver_brief calls only after its own
# `[ "$state" = "cli" ]` gate — so a "busy" or "shell" sweep never reaches
# that call at all, and this tracker just holds its last cli-observed value
# unchanged straight through those sweeps rather than being cleared. In-memory
# only, same reset-on-restart contract as WORKER_DELIVER_LAST_FAIL et al above.
declare -A WORKER_DELIVER_PENDING_SEEN=()

# WORKER_DELIVER_TIMED_OUT_BRIEF (issue #437 self-review)
#
# Cross-sweep bookkeeping keyed by issue: the basename of the brief this
# script's OWN /quit injection most recently gave up waiting on (maybe_
# worker_deliver_brief's timeout branch below), kept until worker_deliver_
# detect_claim actually observes that exact brief leave inbox/ for
# processing/ — no matter how many sweeps later that turns out to be.
# Without this, only the very next sweep after a timeout was protected from
# misattributing a late-landing effect of our own /quit to a human's manual
# one (release=listener_claim_after_quit); a second or third late sweep
# would wrongly credit the human path. See worker_deliver_detect_claim's
# header comment for how this is consumed.
declare -A WORKER_DELIVER_TIMED_OUT_BRIEF=()

# worker_deliver_detect_claim <issue> <worktree-dir> <pane-state>
#
# The events-log stall this closes (issue #437): a 2026-09-19 delivery
# stall logged 1,812 worker.deliver.skip lines and nothing else, so once it
# finally cleared there was no record of WHETHER it cleared because this
# script's own /quit injection (below, "auto_deliver") finally succeeded,
# or because a human noticed and attached to run /quit by hand
# ("listener_claim_after_quit") — both leave the exact same end state (the
# brief moved out of inbox/), and only maybe_worker_deliver_brief's own
# synchronous wait loop can tell the two apart from the inside. This
# function is that outside observer: called on every sweep a window sits in
# "cli" state (mirroring exactly the scenario maybe_worker_deliver_brief
# itself gates on — a worker parked at rest with a brief genuinely queued),
# it remembers the pending brief's name and, if a PREVIOUSLY remembered
# brief has since vanished, logs the generic success event for it — unless
# maybe_worker_deliver_brief's own auto_deliver path already logged that
# exact transition itself (it clears WORKER_DELIVER_PENDING_SEEN on success
# before this function ever gets a chance to see the "vanished" half of the
# transition, so the two can never double-log the same delivery).
#
# Deliberately scoped to state="cli" only (never called for "shell"): a
# "shell" window is the listener's own idle poll loop already in control
# and self-healing onto new briefs as ordinary, un-ambiguous operation
# (issue #43) — logging every one of *those* routine claims as
# "listener_claim_after_quit" would be false attribution (no /quit, manual
# or otherwise, was ever involved) and would drown the genuinely-ambiguous
# recoveries this event exists to surface in noise from normal traffic.
#
# Self-review finding: "prior brief no longer pending" alone isn't proof it
# was actually claimed — a DRY_RUN=1 sweep (which intentionally never
# delivers anything) still records a $prior, and if the worktree's queue
# state is later disturbed some other way (an operator deleting the stale
# brief outright, a test fixture resetting inbox/) that same $prior would
# read as "vanished" with nothing to do with a real delivery. Requiring the
# exact brief to actually be sitting in processing/ — claim_next_task's own
# atomic mv target, which per worker_current_task_terminal()'s header
# comment stays populated for the task's entire in-flight lifetime — is
# cheap positive confirmation a genuine claim happened, not just an absence.
#
# Self-review finding (round 2): a vanished-and-now-claimed $prior is
# ambiguous between two causes — a human attaching and running /quit by
# hand, or this script's OWN earlier /quit finally taking effect after
# maybe_worker_deliver_brief's synchronous wait already gave up and logged
# worker.deliver.timeout. Checking WORKER_DELIVER_TIMED_OUT_BRIEF (set by
# that timeout branch) tells the two apart correctly no matter how many
# sweeps late the effect surfaces, instead of only the one sweep immediately
# following the timeout.
worker_deliver_detect_claim() {
    local issue="$1" wt_dir="$2" state="$3"
    local current="" prior
    [ "$state" = "cli" ] && current="$(basename "$(worker_pending_brief_path "$wt_dir")" 2>/dev/null || true)"
    prior="${WORKER_DELIVER_PENDING_SEEN[$issue]:-}"
    if [ -n "$prior" ] && [ "$prior" != "$current" ] && [ -e "$wt_dir/.swarm/tasks/processing/$prior" ]; then
        if [ -n "${WORKER_DELIVER_TIMED_OUT_BRIEF[$issue]:-}" ] && [ "$prior" = "${WORKER_DELIVER_TIMED_OUT_BRIEF[$issue]}" ]; then
            log_event worker.deliver.ok "issue=$issue brief=$prior release=auto_deliver late=1"
            unset "WORKER_DELIVER_TIMED_OUT_BRIEF[$issue]"
        else
            log_event worker.deliver.ok "issue=$issue brief=$prior release=listener_claim_after_quit"
        fi
        # issue #436: whatever composer-stall streak was counted against
        # $prior is moot now that it's actually been claimed — clear it here
        # too (not just on worker_deliver_record_success's auto_deliver
        # path) so a listener_claim_after_quit resolution also drops a
        # stale WORKER_DELIVER_COMPOSER_STALL_ESCALATED flag.
        worker_deliver_composer_stall_clear "$issue"
    fi
    WORKER_DELIVER_PENDING_SEEN[$issue]="$current"
}

# maybe_worker_deliver_brief <window>
#
# Called by worker_compact_pass for each `iss-*` window on every
# WORKER_COMPACT_SCAN_SECS sweep (shares that loop rather than its own —
# see WORKER_AUTO_DELIVER's header comment). Fails open at every step: a
# missing precondition, unparseable pane text, or a timeout just leaves the
# window alone this cycle — the brief stays queued for the next sweep or a
# human.
maybe_worker_deliver_brief() {
    local win="$1" issue wt_dir
    issue="${win#iss-}"
    [[ "$issue" =~ ^[0-9]+$ ]] || return 0
    wt_dir="$(own_wt_dir_for_issue "$issue")" || return 0

    local state
    state="$(worker_pane_state "$win")" || state="absent"
    # "shell": the listener's own idle bash loop is in control and already
    # self-heals onto a new brief (run_idle_shell/poll_for_brief, issue #43)
    # — nothing to do. "absent": no such window.
    [ "$state" = "cli" ] || return 0

    worker_deliver_detect_claim "$issue" "$wt_dir" "$state"

    local brief_before
    brief_before="$(basename "$(worker_pending_brief_path "$wt_dir")" 2>/dev/null || true)"
    [ -n "$brief_before" ] || return 0

    # Self-review finding: never end a session whose CURRENT task hasn't
    # positively confirmed finishing — see worker_current_task_terminal()'s
    # header comment for the false-completion bug this closes (a `blocked`
    # worker awaiting a decision looks identical to a finished one from pane
    # state alone). A worker parked `blocked` still needs the documented
    # manual path (attach and answer it directly) until a future feature can
    # deliver an answer as a continuing turn instead of ending the session.
    if ! worker_current_task_terminal "$wt_dir"; then
        log_event worker.deliver.skip "issue=$issue reason=task_not_terminal"
        return 0
    fi

    if [ "${WORKER_DELIVER_GAVE_UP[$issue]:-0}" = "1" ]; then
        return 0   # already logged the one worker.deliver.giving_up warning
    fi

    local bo_now bo_last_fail
    bo_now=$(date +%s)
    bo_last_fail="${WORKER_DELIVER_LAST_FAIL[$issue]:-0}"
    if [ "$bo_last_fail" -gt 0 ] && [ $(( bo_now - bo_last_fail )) -lt "$WORKER_DELIVER_BACKOFF_SECS" ]; then
        log_event worker.deliver.skip "issue=$issue reason=backoff remaining=$(( WORKER_DELIVER_BACKOFF_SECS - (bo_now - bo_last_fail) ))s"
        return 0
    fi

    if worker_pane_busy "$win"; then
        log_event worker.deliver.skip "issue=$issue reason=pane_busy"
        return 0   # never interrupt a live turn — see docs/tmux-as-channel.md
    fi

    # Self-review finding: a WORKER_HEADLESS=1 worker's `claude -p` run
    # renders no interactive TUI chrome at all — worker_pane_busy() never
    # matches it (no "(esc to interrupt)"/spinner), so worker_pane_state()
    # reads "cli" for its entire, possibly still-running, duration with no
    # busy signal to gate on. maybe_worker_compact is structurally immune to
    # this (it already requires worker_pane_ctx_used() to parse a real
    # statusline before doing anything); give this feature the same
    # protection rather than relying solely on compact_composer_clear()'s
    # last-rendered-line check below, which can coincidentally read as
    # "empty" for one poll between two lines of a live `-p` run's plain
    # stdout — nowhere near proof of an actual idle interactive composer.
    # statusline-with-context.sh's "ctx: <used>/<total> (<pct>%)" only
    # renders inside the interactive TUI, never in -p's plain output, so
    # requiring it here is a cheap, already-tested structural gate against
    # ever touching a live headless run (worst case without it: a wasted
    # WORKER_DELIVER_END_TIMEOUT_SECS wait and a false backoff — not outcome
    # corruption, since headless workers write done/*.json themselves the
    # normal way — but free to close outright).
    if ! worker_pane_ctx_used "$win" >/dev/null 2>&1; then
        log_event worker.deliver.skip "issue=$issue reason=no_ctx_parsed"
        return 0
    fi

    # issue #313's constraint: a composer holding unsubmitted text (an
    # observed dimmed suggestion on one parked pane) must never be pasted
    # over — pasting "/quit" into it would produce garbled, unpredictable
    # input rather than a clean exit command.
    local target="$SESSION_NAME:$win"
    if ! compact_composer_clear "$target"; then
        log_event worker.deliver.skip "issue=$issue reason=composer_not_clear"
        worker_deliver_record_composer_stall "$issue" "$brief_before"
        return 0
    fi

    echo "[$(date +%T)] worker $win has a brief waiting in inbox/ but its agent session is parked at rest — ending the session (/quit) so its listener claims it..."
    log_event worker.deliver.attempt "issue=$issue"

    if [ "$DRY_RUN" = "1" ]; then
        echo "[DRY] would inject /quit into $target to release the parked session back to worker-listener.sh"
        return 0
    fi

    # Same load-buffer + paste-buffer -d + settle + Enter + resubmit-check
    # mechanism as maybe_worker_compact's /compact injection; own buffer
    # name so a concurrent compact/deliver pass across windows can't clobber
    # each other's buffer content.
    local tmp_quit
    tmp_quit=$(mktemp) || { log_event worker.deliver.skip "issue=$issue reason=mktemp_failed"; return 0; }
    printf '/quit' > "$tmp_quit" 2>/dev/null || true
    tmux load-buffer -b "llm-worker-deliver-$issue" "$tmp_quit" 2>/dev/null || true
    tmux paste-buffer -b "llm-worker-deliver-$issue" -t "$target" -d 2>/dev/null || true
    rm -f "$tmp_quit" 2>/dev/null || true

    sleep "$COMPACT_SUBMIT_SETTLE_SECS"
    tmux send-keys -t "$target" Enter 2>/dev/null || true
    sleep "$COMPACT_SUBMIT_SETTLE_SECS"
    if ! compact_confirm_submitted "$target" "$WORKER_COMPACT_BUSY_PATTERN" "/quit"; then
        log_event worker.deliver.resubmit "issue=$issue"
        tmux send-keys -t "$target" Enter 2>/dev/null || true
    fi

    # issue #344: polling worker_pane_state for "cli" -> "shell" misses a
    # NORMAL SUCCESS. After /quit, worker-listener.sh's claim_next_task()
    # atomically moves the brief out of inbox/ into processing/ and
    # dispatch_agent() re-launches claude within the same iteration — well
    # inside WORKER_DELIVER_END_TIMEOUT_SECS — so the pane can go
    # cli -> shell -> cli again entirely between two WORKER_DELIVER_POLL_SECS
    # polls, and this loop would then see "cli" on every single poll, time
    # out, and (worst case) run compact_retract_queued's Escape/BSpace
    # against the just-relaunched session's live first turn — keystroke
    # injection into a running agent, exactly what docs/tmux-as-channel.md
    # exists to prevent. worker_pending_brief() going false is the fix:
    # claim_next_task's mv is atomic, so it can never be missed the way a
    # same-poll-window pane-state flap can, and it's true success — the
    # brief left inbox/ — independent of whatever the pane happens to be
    # rendering at that instant.
    local waited=0
    while worker_pending_brief "$wt_dir"; do
        sleep "$WORKER_DELIVER_POLL_SECS"
        waited=$((waited + WORKER_DELIVER_POLL_SECS))
        if [ "$waited" -ge "$WORKER_DELIVER_END_TIMEOUT_SECS" ]; then
            # Final re-check right at the boundary: the mv could land in the
            # gap between the loop's last poll and this instant. Never let a
            # last-second success get recorded as a timeout, and never let
            # compact_retract_queued fire against a session that already
            # moved on to the delivered brief (fix part 2 — the retract path
            # must not fire once delivery has actually succeeded).
            if ! worker_pending_brief "$wt_dir"; then
                break
            fi
            log_event worker.deliver.timeout "issue=$issue waited=${waited}s"
            if compact_composer_clear "$target"; then
                log_event worker.deliver.delivered_as_text "issue=$issue"
            else
                compact_retract_queued "$target" worker.deliver "issue=$issue" "$WORKER_COMPACT_BUSY_PATTERN" || true
            fi
            worker_deliver_record_failure "$issue"
            # Self-review finding (issue #437): if this /quit's effect lands
            # LATE — just past this timeout, e.g. a slow-to-render CLI
            # finally processing it a beat after we gave up waiting — a
            # future cli-state sweep's worker_deliver_detect_claim would
            # otherwise see $brief_before vanish and, with nothing to say
            # otherwise, misattribute this script's own (merely late)
            # success to release=listener_claim_after_quit. Recording it
            # here (rather than blindly clearing WORKER_DELIVER_PENDING_SEEN,
            # which only protected the very next sweep — see that tracker's
            # header comment) lets detect_claim correctly credit
            # release=auto_deliver whenever this exact brief's departure is
            # finally observed, however many sweeps late that is.
            WORKER_DELIVER_TIMED_OUT_BRIEF[$issue]="$brief_before"
            return 0
        fi
    done

    echo "[$(date +%T)] worker $win session ended (${waited}s) — its listener claimed the pending brief."
    log_event worker.deliver.ended "issue=$issue waited=${waited}s"
    log_event worker.deliver.ok "issue=$issue brief=$brief_before release=auto_deliver waited=${waited}s"
    # Clears the transition worker_deliver_detect_claim would otherwise see
    # on its NEXT sweep (prior=$brief_before, current=empty) — this success
    # is already fully attributed above; without this, that next sweep
    # would log the exact same delivery a second time as
    # release=listener_claim_after_quit.
    WORKER_DELIVER_PENDING_SEEN[$issue]=""
    worker_deliver_record_success "$issue"
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
    wt_dir="$(own_wt_dir_for_issue "$issue")" || return 0

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

    # issue #296: worker-side twin of maybe_auto_compact's window-confirmation
    # guard above — see AUTO_COMPACT_REQUIRE_WINDOW's header comment for the
    # incident and design rationale (including why this deliberately does
    # NOT re-check the computed threshold's percentage-of-window once the
    # window WAS parsed), and WORKER_COMPACT_REQUIRE_WINDOW's for why this
    # specific branch is unreachable in practice today. Refuses only when
    # worker_pane_ctx_window() — the SAME helper
    # worker_compact_effective_threshold() already called above — can't
    # parse a window size at all, meaning that threshold ALSO fell back to
    # the flat WORKER_COMPACT_THRESHOLD_TOKENS default.
    # WORKER_COMPACT_REQUIRE_WINDOW=0 disables this check.
    if [ "$WORKER_COMPACT_REQUIRE_WINDOW" = "1" ] && ! worker_pane_ctx_window "$win" >/dev/null 2>&1; then
        log_event worker.compact.skip "issue=$issue reason=no_window_for_floor"
        return 0
    fi

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
    rm -f "$tmp_compact" 2>/dev/null || true

    # issue #290: same autocomplete-menu race as maybe_auto_compact's
    # injection (see that function's comment) — settle, submit, verify,
    # retry once if the composer still holds the pasted text.
    sleep "$COMPACT_SUBMIT_SETTLE_SECS"
    tmux send-keys -t "$SESSION_NAME:$win" Enter 2>/dev/null || true
    sleep "$COMPACT_SUBMIT_SETTLE_SECS"
    if ! compact_confirm_submitted "$SESSION_NAME:$win" "$WORKER_COMPACT_BUSY_PATTERN" "/compact"; then
        log_event worker.compact.resubmit "issue=$issue"
        tmux send-keys -t "$SESSION_NAME:$win" Enter 2>/dev/null || true
    fi

    # Wait for compaction to actually start (busy indicator appears).
    local waited=0
    while ! worker_pane_busy "$win"; do
        sleep "$WORKER_COMPACT_POLL_SECS"
        waited=$((waited + WORKER_COMPACT_POLL_SECS))
        if [ "$waited" -ge "$WORKER_COMPACT_START_TIMEOUT_SECS" ]; then
            log_event worker.compact.timeout "issue=$issue phase=start waited=${waited}s"
            # issue #292 — see maybe_auto_compact's twin check (this file's
            # COMPACT_REPLAY_PATTERN header comment has the full forensics):
            # an already-empty composer here means nothing is left to
            # retract — most likely the injected /compact was delivered as a
            # plain chat message rather than executed as a slash command.
            if compact_composer_clear "$SESSION_NAME:$win"; then
                log_event worker.compact.delivered_as_text "issue=$issue"
            else
                compact_retract_queued "$SESSION_NAME:$win" worker.compact "issue=$issue" "$WORKER_COMPACT_BUSY_PATTERN" || true
            fi
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
    #
    # issue #292: also watch for the CLI's own post-compact continuation
    # replaying this same /compact prompt (see COMPACT_REPLAY_PATTERN's
    # header comment) — a harmless, immediate "Not enough messages to
    # compact." rejection unrelated to whether THIS compaction worked.
    # issue #292 self-review: only trusted when the finish-phase "waited"
    # above cleared COMPACT_REPLAY_MIN_REAL_SECS — otherwise the injected
    # /compact may simply have been rejected OUTRIGHT (identical pane text,
    # identical brief busy-then-idle shape) and never compacted anything at
    # all; see COMPACT_REPLAY_MIN_REAL_SECS's header comment.
    local verify_waited=0 used_after="" replayed=0
    while [ "$verify_waited" -lt "$WORKER_COMPACT_VERIFY_TIMEOUT_SECS" ]; do
        sleep "$WORKER_COMPACT_POLL_SECS"
        verify_waited=$((verify_waited + WORKER_COMPACT_POLL_SECS))
        if compact_replay_detected "$SESSION_NAME:$win"; then
            replayed=1
        fi
        used_after="$(worker_pane_ctx_used "$win")" && break
        used_after=""
    done

    if [ "$replayed" = "1" ] && [ "$waited" -ge "$COMPACT_REPLAY_MIN_REAL_SECS" ]; then
        log_event worker.compact.replayed "issue=$issue before=$used"
        # issue #292 self-review: the replay only ever fires after this
        # attempt's OWN busy indicator was already confirmed to start and
        # clear above — a real compaction genuinely ran; the replay is just
        # noise in the verify comparison, not evidence of failure. Treating
        # it as a no-verdict (neither success nor failure) would leave a
        # stale WORKER_COMPACT_FAIL_COUNT from an EARLIER, unrelated attempt
        # uncleared, letting it tip into worker.compact.giving_up (#252) one
        # failure early despite this attempt having worked.
        worker_compact_record_success "$issue"
    elif [ -z "$used_after" ]; then
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
# Enumerates every `iss-*` window in the session and runs
# maybe_worker_deliver_brief then maybe_worker_compact against each (issue
# #313 folded parked-brief delivery into this same sweep rather than giving
# it a dedicated loop — same per-window capture-pane cost either feature
# would pay alone, and delivery is cheap/fast-path in the common case where
# nothing is queued). Called from run_worker_compact_loop's own dedicated
# background process on its own WORKER_COMPACT_SCAN_SECS interval — kept
# separate from run_watch_timer_loop's tighter status/PR-poll loop because a
# single compaction can block for minutes; see that function's header
# comment for the full rationale. A missing session (no workers provisioned
# yet) or zero iss-* windows is the common case and simply no-ops — this
# always fails open, same as every other pass in this file. Either feature
# can be disabled independently (WORKER_AUTO_COMPACT / WORKER_AUTO_DELIVER)
# without affecting the other.
worker_compact_pass() {
    { [ "$WORKER_AUTO_COMPACT" = "1" ] || [ "$WORKER_AUTO_DELIVER" = "1" ]; } || return 0
    tmux has-session -t "$SESSION_NAME" 2>/dev/null || return 0

    local windows win
    windows="$(tmux list-windows -t "$SESSION_NAME" -F '#{window_name}' 2>/dev/null | grep '^iss-' || true)"
    [ -n "$windows" ] || return 0

    while IFS= read -r win; do
        [ -n "$win" ] || continue
        [ "$WORKER_AUTO_DELIVER" = "1" ] && maybe_worker_deliver_brief "$win"
        [ "$WORKER_AUTO_COMPACT" = "1" ] && maybe_worker_compact "$win"
    done <<< "$windows"
}

# coord_inbox_write <kind> <content>
#
# (issue #430) Durably records one wake payload to COORD_INBOX_DIR as its
# own <UTC-timestamp>-<kind>-<pid>-<rand>.md file — atomic mktemp (inside
# the dir, WITHOUT the .md suffix, so a glob on *.md never matches a
# half-written temp file) + mv, same convention the worker outbox uses.
# Unconditional and independent of debounce/defer state: called before any
# doorbell decision is made, so the payload is on disk even if the doorbell
# itself is about to be skipped (debounce), deferred (busy pane / dirty
# composer), or fails to submit — the exact gap that let a
# coord.wake.submit_failed wake's content exist "nowhere but the failed
# paste" before this issue (see this file's header comment). Failure here
# is logged but non-fatal — an inbox write that can't land shouldn't also
# block the doorbell attempt that follows it.
coord_inbox_write() {
    local kind="$1" content="$2" tmp final
    mkdir -p "$COORD_INBOX_DIR" "$COORD_INBOX_PROCESSED_DIR" 2>/dev/null || true
    tmp="$(mktemp "$COORD_INBOX_DIR/.tmp.coord-inbox.XXXXXX" 2>/dev/null)" || return 1
    printf '%s\n' "$content" > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
    final="$COORD_INBOX_DIR/$(date -u +%Y%m%dT%H%M%SZ)-${kind}-$$-${RANDOM}.md"
    mv -f "$tmp" "$final" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
}

# coord_inbox_count
#
# (issue #430) Echoes the number of unprocessed coord-inbox/*.md files —
# "unprocessed" because coord_inbox_write's targets always land directly in
# COORD_INBOX_DIR, never COORD_INBOX_PROCESSED_DIR, and the coordinator's
# own triage (prompts/coordinator.md "Inbox") archives each one it handles
# into processed/ by moving it out of this glob's reach. Used only to
# render coord_inbox_nudge_text's "%N" live at paste time.
coord_inbox_count() {
    # `|| true` on the whole pipeline (not just find's own 2>/dev/null,
    # which only silences find's stderr, not its exit status) — under this
    # script's `set -e -o pipefail`, a missing COORD_INBOX_DIR (nothing
    # written yet) would otherwise make find's non-zero status the
    # pipeline's status and abort the caller via the `local n; n=$(...)`
    # two-line assignment pattern (a single-line `local n=$(...)` would
    # mask it instead — see mtime_epoch's callers for why this file always
    # splits local/assign, and why that means failures here DO need an
    # explicit `|| true`, unlike there).
    find "$COORD_INBOX_DIR" -maxdepth 1 -name '*.md' -type f 2>/dev/null | wc -l | tr -d '[:space:]' || true
}

# coord_inbox_nudge_text
#
# (issue #430) Renders COORD_INBOX_NUDGE_TEMPLATE with "%N" replaced by the
# CURRENT coord_inbox_count — computed fresh at call time, not captured
# once and persisted, so a nudge delivered late (after a busy-pane defer or
# a dirty-composer retry) still reports an accurate count instead of a
# stale one from whenever the defer first started.
coord_inbox_nudge_text() {
    local n
    n="$(coord_inbox_count)"
    printf '%s\n' "${COORD_INBOX_NUDGE_TEMPLATE//%N/$n}"
}

# ── issue #456: the doorbell debounce clock, on disk ─────────────────────────
#
# wake_clock_get echoes the epoch seconds of the last doorbell actually
# delivered (0 when none ever was, or the file is missing/unparseable —
# fail-open, i.e. "debounce window has long passed, ring it").
# wake_clock_set stamps it. See COORD_WAKE_LAST_FILE's declaration for why
# this is a file and not the pre-#456 pair of shell globals.
wake_clock_get() {
    local v
    v="$(cat "$COORD_WAKE_LAST_FILE" 2>/dev/null)" || v=""
    [[ "$v" =~ ^[0-9]+$ ]] || v=0
    printf '%s\n' "$v"
}

wake_clock_set() {
    printf '%s\n' "${1:-$(date +%s)}" > "$COORD_WAKE_LAST_FILE" 2>/dev/null || true
}

# wake_debounced
#
# True (rc 0) if a doorbell right now would fall inside DEBOUNCE_SECS of the
# last one. DEBOUNCE_SECS=0 disables the window entirely.
#
# Never true under ONCE=1. Coalescing only makes sense when there is a later
# tick to deliver the held doorbell on, and ONCE=1 exits after the first
# wake — so a debounce hold there would strand the doorbell AND swallow the
# exit, leaving the smoke-test watcher running forever. (Pre-#456 this was
# latent: the clock was a per-process global, so a fresh ONCE=1 watcher
# always started at 0 and never debounced. Making it a file, which is what
# lets the retry pass in another process see it, is what exposed it.)
wake_debounced() {
    [ "$ONCE" = "1" ] && return 1
    [ "$DEBOUNCE_SECS" -gt 0 ] || return 1
    local last now
    last="$(wake_clock_get)"
    now=$(date +%s)
    [ $((now - last)) -lt "$DEBOUNCE_SECS" ]
}

# ── issue #459: human-presence detection ────────────────────────────────────
#
# watcher_paste_epochs
#
# Echoes, one per line, the epoch seconds of every paste THIS WATCHER made
# into a Claude Code pane recently enough to still matter — read back out of
# its own events.log. Used by human_typed_since to subtract the watcher's own
# pastes from "someone typed into this session".
#
# Why this is needed at all: a pasted doorbell is recorded in the session
# transcript with `origin: {kind: "human"}` and `promptSource: "typed"` —
# byte-identical in shape to the operator typing it by hand (verified on live
# fand-app transcripts, 2026-09-23; worker brief deliveries land the same
# way). There is no metadata field that distinguishes them, so the only
# ground truth available is the watcher's own record of what it sent and when.
#
# Bounded by `tail -n $WATCHER_PASTE_SCAN_LINES` rather than reading the whole
# log: only pastes inside the largest idle window can possibly correlate, and
# events.log grows without bound over a swarm's life. 2000 lines is generous
# on purpose — the window that matters is the largest idle window (10 min by
# default), and a busy swarm mid-storm can log hundreds of events in that
# time. Undershooting here is the one direction with a bad failure mode: a
# paste whose event has scrolled out of the tail reads as a human, and the
# doorbell stays held.
WATCHER_PASTE_SCAN_LINES="${WATCHER_PASTE_SCAN_LINES:-2000}"
watcher_paste_epochs() {
    [ -r "$EVENTS_LOG" ] || return 0
    tail -n "$WATCHER_PASTE_SCAN_LINES" "$EVENTS_LOG" 2>/dev/null \
        | LC_ALL=C grep -E '(coord\.wake|coord\.wake\.deferred_delivered|worker\.deliver\.(ok|attempt))[[:space:]]' \
        | awk '{print $1}' \
        | while read -r ts; do
              date -u -d "$ts" +%s 2>/dev/null || true
          done
}

# human_typed_since <transcript-dir> <cutoff-epoch> <paste-epochs>
#
# True (rc 0) if that Claude Code session has a typed turn newer than
# <cutoff-epoch> that is NOT one of this watcher's own pastes. <paste-epochs>
# is watcher_paste_epochs' output, passed in so a sweep over many worker
# sessions computes it once.
#
# Two independent exclusions, either of which marks a turn machine-origin:
#
#   1. Text match — the turn reads as the rendered inbox nudge (the template
#      with its "%N" wildcarded) or opens with a known wake-prompt line.
#   2. Event correlation — the turn's timestamp lands within
#      COORD_HUMAN_PASTE_GRACE_SECS of a paste in <paste-epochs>.
#   3. Length — the turn is longer than COORD_HUMAN_MAX_TYPED_CHARS. Worker
#      brief deliveries are thousands of characters and match neither of the
#      above (a brief is not the nudge, and its delivery event can scroll out
#      of the tail); nobody types 2000 characters into a pane by hand.
#
# All three, not any one: text match alone misses operator-customised
# templates (COORD_INBOX_NUDGE_TEMPLATE / WAKE_PROMPT are env-overridable),
# event correlation alone misses a paste whose event has scrolled out of the
# log tail, and length alone would misread a long pasted spec as machine.
# Each exclusion only ever moves a turn from "human" to "machine", i.e.
# toward ringing the doorbell — the safe direction.
#
# Fails OPEN throughout (rc 1 — "no human here") on a missing transcript dir,
# absent jq, or an unreadable file. A muted swarm is a far worse failure than
# a doorbell that rings while the operator is reading, so every uncertainty
# resolves toward ringing.
human_typed_since() {
    local dir="$1" cutoff="$2" pastes="$3"
    [ "$HAVE_JQ" = "1" ] || return 1
    [ -d "$dir" ] || return 1

    # Every transcript in this dir touched since the cutoff, not just the
    # newest one. A single working dir routinely holds several concurrent
    # session files — subagent runs write their own (promptSource "sdk", no
    # typed turns at all), and a resumed session starts a fresh file — so
    # "newest file" can easily be a subagent's while the operator is typing
    # in the main session next to it, which would read as nobody here.
    #
    # The mtime pre-filter keeps this cheap: a dir with no recent activity
    # costs one stat per file and no reads at all.
    local candidates=() f fmtime
    for f in "$dir"/*.jsonl; do
        [ -r "$f" ] || continue
        fmtime=$(mtime_epoch "$f") || fmtime=0
        # mtime_epoch can echo nothing (both stat spellings failed); an empty
        # operand makes `[ -ge ]` a syntax error under `set -e`, so normalize
        # to 0 = "far older than any cutoff" rather than let it through.
        [[ "$fmtime" =~ ^[0-9]+$ ]] || fmtime=0
        [ "$fmtime" -ge "$cutoff" ] && candidates+=("$f")
    done
    [ "${#candidates[@]}" -gt 0 ] || return 1

    # The nudge template with "%N" turned into a digit wildcard, anchored —
    # so an operator quoting a nudge back mid-sentence doesn't match. The
    # wildcard is ERE ("[0-9]+", not BRE's "[0-9]\+") because the matcher
    # below is grep -E; getting that wrong makes the pattern match nothing,
    # which reads every pasted doorbell as a human and mutes the swarm.
    local nudge_re
    nudge_re="^$(printf '%s' "$COORD_INBOX_NUDGE_TEMPLATE" \
        | sed 's/[][\.^$*+?(){}|\\]/\\&/g; s/%N/[0-9]+/')"

    # Walk each candidate's typed turns newest-first and stop at the first
    # one that survives both exclusions. tac + grep on the raw line keeps jq
    # off every line of what can be a very large transcript.
    local line ts epoch text p wake_head
    wake_head="$(printf '%s' "$WAKE_PROMPT" | head -1)"
    for f in "${candidates[@]}"; do
        while IFS= read -r line; do
            ts="$(printf '%s' "$line" | jq -r '.timestamp // empty' 2>/dev/null)" || continue
            [ -n "$ts" ] || continue
            epoch=$(date -u -d "$ts" +%s 2>/dev/null) || continue
            # Turns are appended in order, so once we are past the cutoff
            # going backwards, every remaining turn in THIS file is older
            # still — move on to the next candidate.
            [ "$epoch" -ge "$cutoff" ] || break

            text="$(printf '%s' "$line" | jq -r '
                .message.content as $c |
                if ($c | type) == "string" then $c
                elif ($c | type) == "array" then ([$c[] | select(.type == "text") | .text] | join("\n"))
                else "" end' 2>/dev/null)" || text=""

            # Exclusion 3 — too long to have been typed by a person. Cheapest
            # of the three, so it runs first.
            [ "${#text}" -gt "$COORD_HUMAN_MAX_TYPED_CHARS" ] && continue

            # Exclusion 1 — this is the watcher's own doorbell or wake prompt.
            printf '%s' "$text" | LC_ALL=C grep -qE "$nudge_re" && continue
            [ -n "$wake_head" ] && \
                printf '%s' "$text" | LC_ALL=C grep -qF -- "$wake_head" && continue

            # Exclusion 2 — it coincides with a paste the watcher logged.
            local matched=0
            for p in $pastes; do
                local delta=$((epoch - p))
                [ "$delta" -lt 0 ] && delta=$((-delta))
                if [ "$delta" -le "$COORD_HUMAN_PASTE_GRACE_SECS" ]; then matched=1; break; fi
            done
            [ "$matched" = "1" ] && continue

            return 0
        # Whitespace-tolerant: the CLI writes compact JSON today, but a
        # pretty-printed or re-spaced line must not silently read as "no
        # typed turns here" — that direction ends in a permanently held
        # doorbell. (A miss the other way just rings.)
        done < <(LC_ALL=C grep -E '"promptSource"[[:space:]]*:[[:space:]]*"typed"' "$f" 2>/dev/null | tac)
    done

    return 1
}

# transcript_dir_for <dir>
#
# Echoes the Claude Code session-transcript directory for a working dir,
# using the CLI's own slug convention (path with "/" → "-"). Same derivation
# as scripts/capture-worker.sh's --verify path (issue #360) and
# worker-listener.sh's no-op detector.
transcript_dir_for() {
    printf '%s\n' "$HOME/.claude/projects/$(printf '%s' "$1" | tr '/' '-')"
}

# coord_human_present
#
# True (rc 0) if the operator has typed into the COORDINATOR session within
# COORD_HUMAN_IDLE_SECS. 0 disables the gate (pre-#459 behavior).
coord_human_present() {
    [ "$COORD_HUMAN_IDLE_SECS" -gt 0 ] || return 1
    local cutoff
    cutoff=$(( $(date +%s) - COORD_HUMAN_IDLE_SECS ))
    human_typed_since "$(transcript_dir_for "$PROJECT_DIR")" "$cutoff" "$(watcher_paste_epochs)"
}

# worker_human_present
#
# True (rc 0) if the operator has typed into ANY of this project's own worker
# sessions within WORKER_HUMAN_IDLE_SECS — the operator driving a worker pane
# by hand is still the operator being present, and a coordinator that wakes
# and re-dispatches underneath them is the same interruption. Scoped through
# list-own-worktrees.sh (issue #357), never a flat glob, so a sibling
# project's swarm in the same workspace can't hold this one's doorbells.
#
# In practice this is nearly always false and costs one mtime check per
# worktree (human_typed_since's pre-filter) — worker sessions get very little
# direct human input.
worker_human_present() {
    [ "$WORKER_HUMAN_IDLE_SECS" -gt 0 ] || return 1
    local cutoff pastes wt
    cutoff=$(( $(date +%s) - WORKER_HUMAN_IDLE_SECS ))
    pastes="$(watcher_paste_epochs)"
    while read -r wt; do
        [ -n "$wt" ] || continue
        human_typed_since "$(transcript_dir_for "$wt")" "$cutoff" "$pastes" && return 0
    done < <(own_worktree_dirs_for_scan "$PROJECT_DIR" 2>/dev/null || true)
    return 1
}

# swarm_busy
#
# True (rc 0) if any own worker is mid-turn, or has a brief sitting queued
# and unclaimed in its tasks/inbox/ — i.e. work is already in flight and the
# coordinator is not what it's waiting on.
#
# Deliberately NOT consulted by default (WAKE_DEFER_ON_SWARM_BUSY=0). Holding
# doorbells while workers are busy was considered for issue #459 and rejected:
# the moment one worker finishes while others churn, it parks idle needing a
# top-up, and a swarm-busy gate suppresses precisely the wake that would
# dispatch its next brief. On a long run the swarm never goes fully quiet, so
# triage never re-engages and slots bleed. Human presence is the lever that
# matches the reported problem; this one is kept behind a flag for the
# low-value paths and for operators who want the stricter quiescence rule.
#
# Note the asymmetry in what counts: a brief ALREADY WRITTEN into a worker's
# inbox and not yet claimed is busy (the work is dispatched; nothing is owed
# by the coordinator). A worker parked with an EMPTY inbox is the opposite —
# idle and demanding attention — and must never register as busy here, or the
# gate would suppress the very doorbell that feeds it.
swarm_busy() {
    local wt issue
    while read -r wt; do
        [ -n "$wt" ] || continue
        worker_pending_brief "$wt" && return 0
        issue="$(basename "$wt" | sed -nE 's/^wt-issue-([0-9]+)$/\1/p')"
        [ -n "$issue" ] || continue
        worker_pane_busy "iss-$issue" && return 0
    done < <(own_worktree_dirs_for_scan "$PROJECT_DIR" 2>/dev/null || true)
    return 1
}

# coord_wake_hold_reason
#
# (issue #459) The single gate every doorbell path consults. Echoes the
# reason this doorbell must be HELD right now, or nothing at all when it is
# clear to ring. Reason vocabulary, and each one's retry policy in
# coord_wake_hold_retry_pass:
#
#   human_present  the operator typed into the coordinator (or a worker)
#                  session inside its idle window. NO CEILING — a present
#                  human is never forced over; the doorbell waits for them
#                  to leave. Durability is unaffected: inbox payloads are
#                  written unconditionally (#430), so nothing is lost.
#   pane_busy      the coordinator is mid-turn (#430). Ceilinged by
#                  COORD_WAKE_BUSY_CEILING_SECS — Claude Code queues a paste
#                  into a busy pane, so forcing eventually is safe.
#   debounce       another doorbell rang inside DEBOUNCE_SECS (#456). Clears
#                  on its own once the window passes.
#   swarm_busy     opt-in only (WAKE_DEFER_ON_SWARM_BUSY=1), ceilinged the
#                  same way pane_busy is.
#
# Order matters: the reason reported is the one a human reading the log most
# needs to see, so human presence outranks a busy pane outranks the clock.
coord_wake_hold_reason() {
    coord_human_present && { printf 'human_present\n'; return 0; }
    worker_human_present && { printf 'human_present\n'; return 0; }
    if [ "$COORD_WAKE_BUSY_RETRY_SECS" -gt 0 ] && coordinator_pane_busy; then
        printf 'pane_busy\n'; return 0
    fi
    if [ "$WAKE_DEFER_ON_SWARM_BUSY" = "1" ] && swarm_busy; then
        printf 'swarm_busy\n'; return 0
    fi
    wake_debounced && { printf 'debounce\n'; return 0; }
    return 0
}

# coord_wake_hold_mark_pending <reason>
#
# (issue #430; #459 added the reason) Records "a doorbell wake is currently
# withheld, for <reason>" by writing COORD_WAKE_HOLD_PENDING_FILE. Only the
# reason is persisted, not the nudge text (unlike COORD_WAKE_PENDING_FILE,
# which stores the deferred prompt itself) — this gate's eventual delivery
# always re-renders coord_inbox_nudge_text fresh, so a nudge held for an
# hour still reports an accurate live inbox count.
#
# Never overwrites an already-pending marker — same "earliest defer time
# wins" reasoning as coord_wake_set_pending, since COORD_WAKE_BUSY_CEILING_
# SECS counts from when this wake was FIRST held, not from the most recent
# on_outcome/on_message call that found it still held. The first reason
# recorded therefore sticks even if the cause has since changed; that only
# affects the log line and the ceiling, and coord_wake_hold_retry_pass
# re-evaluates the LIVE reason on every tick before deciding anything.
coord_wake_hold_mark_pending() {
    local reason="${1:-pane_busy}"
    (
        flock -w "$COORD_WAKE_LOCK_TIMEOUT_SECS" 9 || exit 0
        [ -e "$COORD_WAKE_HOLD_PENDING_FILE" ] && exit 0
        printf '%s\n' "$reason" > "$COORD_WAKE_HOLD_PENDING_FILE" 2>/dev/null || true
    ) 9>"$COORD_WAKE_LOCK" || true
}

# coord_wake_hold_clear_pending
#
# (issue #430) Removes COORD_WAKE_HOLD_PENDING_FILE — called once
# coord_wake_hold_retry_pass has either delivered the wake (pane went idle,
# or the ceiling fired) or handed it off to the dirty-draft mechanism
# instead (coord_wake_set_pending).
coord_wake_hold_clear_pending() {
    ( flock -w "$COORD_WAKE_LOCK_TIMEOUT_SECS" 9 && rm -f "$COORD_WAKE_HOLD_PENDING_FILE" ) 9>"$COORD_WAKE_LOCK" || true
}

# coord_wake_hold_retry_pass
#
# (issue #430) Ticked from run_watch_timer_loop on COORD_WAKE_BUSY_RETRY_SECS
# — a no-op when nothing is busy-pending. Otherwise: if the pane is STILL
# busy and the marker's age hasn't reached COORD_WAKE_BUSY_CEILING_SECS yet,
# waits for the next tick without logging (per-tick log spam adds nothing —
# coord.wake.defer already fired once, at first detection, in
# on_outcome/on_message). Once either the pane goes idle OR the ceiling is
# reached (logged as coord.wake.defer_ceiling, still-busy case only), it
# delivers through the SAME single injection site every other wake path
# uses (llm-start.sh's reprompt_inject via $LLM_START) — no new send-keys
# surface. A dirty-composer rc 3 from that delivery attempt is handed off
# to coord_wake_set_pending rather than invented as a second parallel
# mechanism: once the busy phase is over, a human draft sitting in the
# composer is exactly issue #422's case, with its own indefinite-retry-
# without-forcing semantics.
coord_wake_hold_retry_pass() {
    [ -e "$COORD_WAKE_HOLD_PENDING_FILE" ] || return 0

    local since now age held_for
    since=$(mtime_epoch "$COORD_WAKE_HOLD_PENDING_FILE") || since=$(date +%s)
    now=$(date +%s)
    age=$((now - since))
    # Pre-#459 writers left this file empty; empty always meant pane_busy.
    held_for="$(cat "$COORD_WAKE_HOLD_PENDING_FILE" 2>/dev/null | tr -d '[:space:]')" || held_for=""
    [ -n "$held_for" ] || held_for="pane_busy"

    # Re-evaluate LIVE — the reason recorded at mark time may have cleared,
    # or been replaced by a different one (the operator started typing while
    # the pane was busy, say). The recorded reason only decides the ceiling.
    local reason_now
    reason_now="$(coord_wake_hold_reason)"

    if [ -n "$reason_now" ]; then
        # issue #459: a present human is NEVER forced over. Unlike a busy
        # pane (Claude Code queues a paste into one, so forcing eventually is
        # safe), pasting into a session someone is actively working in is the
        # exact interruption this gate exists to prevent — so no ceiling
        # applies while a human is here, however long that lasts. The inbox
        # payload is already durable (#430); only the nudge waits.
        if [ "$reason_now" = "human_present" ]; then
            return 0
        fi
        # Every other reason is self-clearing (debounce) or ceilinged.
        if [ "$reason_now" = "debounce" ]; then
            return 0
        fi
        if [ "$COORD_WAKE_BUSY_CEILING_SECS" -eq 0 ] || [ "$age" -lt "$COORD_WAKE_BUSY_CEILING_SECS" ]; then
            return 0
        fi
        echo "[$(date +%T)] coordinator wake held for ${reason_now} hit its ${COORD_WAKE_BUSY_CEILING_SECS}s ceiling — delivering anyway"
        log_event coord.wake.defer_ceiling "age=${age}s reason=$reason_now"
    fi

    local nudge
    nudge="$(coord_inbox_nudge_text)"

    if [ "$DRY_RUN" = "1" ]; then
        echo "[DRY] would deliver held wake: cd $PROJECT_DIR && NON_INTERACTIVE=1 $LLM_START \"$nudge\" (held ${age}s, reason=$held_for)"
        coord_wake_hold_clear_pending
        wake_clock_set "$now"
        return 0
    fi

    echo "[$(date +%T)] delivering held coordinator wake (pending ${age}s, reason=$held_for)..."
    local wake_rc=0
    ( flock -w "$COORD_WAKE_LOCK_TIMEOUT_SECS" 9 && cd "$PROJECT_DIR" && NON_INTERACTIVE=1 "$LLM_START" "$nudge" ) 9>"$COORD_WAKE_LOCK" || wake_rc=$?
    coord_wake_hold_clear_pending
    case "$wake_rc" in
        0)
            echo "[$(date +%T)] held coordinator wake delivered."
            log_event coord.wake.deferred_delivered "age=${age}s trigger=$held_for"
            # issue #456: stamp the shared debounce clock. Pre-#456 this path
            # didn't, so a held delivery left the window looking stale and the
            # next outcome could ring again seconds later.
            wake_clock_set "$now"
            ;;
        3)
            echo "[$(date +%T)] coordinator composer now holds an unsubmitted draft — handing off to the dirty-composer retry"
            log_event coord.wake.deferred "reason=composer_dirty trigger=${held_for}_handoff age=${age}s"
            coord_wake_set_pending "$nudge"
            ;;
        *)
            echo "[$(date +%T)] WARN: held coordinator wake retry exited non-zero (continuing watch)"
            log_event coord.wake.error "trigger=${held_for}_retry rc=$wake_rc age=${age}s"
            ;;
    esac
}

# coord_wake_set_pending <prompt>
#
# (issue #422) Records <prompt> as a wake still owed to the coordinator
# after llm-start.sh's reprompt_inject deferred it (rc 3 — composer held
# an unsubmitted human draft; see that function's header comment in
# llm-start.sh). Writes COORD_WAKE_PENDING_FILE atomically (mktemp + mv)
# under COORD_WAKE_LOCK, and — deliberately — never overwrites an already-
# pending prompt: the first deferred wake already instructs a full
# re-triage/re-scan (every default WAKE_PROMPT/OUTBOX_WAKE_PROMPT/
# ACTIVITY_WAKE_PROMPT does), so delivering it late is sufficient to catch
# whatever a second, still-deferred wake would also have said, and
# overwriting would reset the file's mtime — the "since when has this been
# deferred" clock coord_wake_retry_pass's bounded warning depends on —
# for no benefit. Failure to acquire the lock or write the file is
# non-fatal and silent here on purpose: the ORIGINAL caller (on_outcome/
# on_message/on_activity) has already logged coord.wake.deferred before
# calling this, so a lost pending-file write degrades to "wake dropped,
# but visibly logged" rather than a wholly silent failure — the same
# fail-open posture every other best-effort write in this file takes.
coord_wake_set_pending() {
    local prompt="$1"
    (
        flock -w "$COORD_WAKE_LOCK_TIMEOUT_SECS" 9 || exit 0
        [ -e "$COORD_WAKE_PENDING_FILE" ] && exit 0
        local tmp
        tmp="$(mktemp "$(dirname "$COORD_WAKE_PENDING_FILE")/.tmp.coord-wake-pending.XXXXXX")" || exit 0
        printf '%s' "$prompt" > "$tmp" 2>/dev/null && mv -f "$tmp" "$COORD_WAKE_PENDING_FILE" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    ) 9>"$COORD_WAKE_LOCK" || true
}

# coord_wake_clear_pending
#
# (issue #422) Removes both pending-wake files under COORD_WAKE_LOCK —
# called once coord_wake_retry_pass confirms a deferred wake actually
# landed (rc 0 from the retry's own llm-start.sh call).
coord_wake_clear_pending() {
    ( flock -w "$COORD_WAKE_LOCK_TIMEOUT_SECS" 9 && rm -f "$COORD_WAKE_PENDING_FILE" "$COORD_WAKE_PENDING_WARNED_FILE" ) 9>"$COORD_WAKE_LOCK" || true
}

# coord_wake_retry_pass
#
# (issue #422) Re-attempts a wake previously deferred by
# coord_wake_set_pending, on COORD_WAKE_RETRY_SECS's cadence from
# run_watch_timer_loop (see COORD_WAKE_RETRY_SECS's header comment). A
# no-op when nothing is pending. Otherwise re-invokes llm-start.sh with
# the SAME saved prompt through the SAME single injection site every other
# wake path uses (llm-start.sh's reprompt_inject) — no new send-keys
# surface, per this issue's own constraint. A clean delivery (rc 0) clears
# the pending file; a repeat deferral (rc 3) leaves it in place for the
# next tick, so the wake is retried indefinitely and never dropped —
# only the SILENCE around a long-stuck deferral is bounded, via the
# COORD_WAKE_DEFER_WARN_SECS WARN below (see that var's header comment for
# why: reprompt_composer_dirty has one known false-positive source — the
# TUI's dimmed autofill suggestion reads identically to a real draft in a
# plain-text capture — so a wake CAN get stuck on a misread rather than a
# genuine draft, and that needs to be visible to a human, not silent).
#
# (issue #430 self-review) Also checks coordinator_pane_busy before
# retrying: a composer that was dirty (human draft) when first deferred may
# since have been submitted, making the pane busy rather than idle —
# retrying blindly through llm-start.sh's busy-always-clears rule would
# splice this stale wake into that live turn, which is exactly what #430
# exists to prevent. A busy pane on a retry tick just skips this tick
# (coord.wake.skip reason=pane_busy) rather than delivering or escalating —
# the pending file stays in place for the next tick either way.
coord_wake_retry_pass() {
    [ -e "$COORD_WAKE_PENDING_FILE" ] || return 0

    local pending_prompt
    pending_prompt="$(cat "$COORD_WAKE_PENDING_FILE" 2>/dev/null)" || return 0
    if [ -z "$pending_prompt" ]; then
        # Empty/unreadable — nothing worth retrying; drop it rather than
        # retry forever on a file that can never satisfy anything.
        coord_wake_clear_pending
        return 0
    fi

    local since now age
    since=$(mtime_epoch "$COORD_WAKE_PENDING_FILE") || since=$(date +%s)
    now=$(date +%s)
    age=$((now - since))

    if [ "$age" -ge "$COORD_WAKE_DEFER_WARN_SECS" ]; then
        local warned_at=0
        if [ -e "$COORD_WAKE_PENDING_WARNED_FILE" ]; then
            warned_at=$(mtime_epoch "$COORD_WAKE_PENDING_WARNED_FILE" 2>/dev/null || echo 0)
        fi
        if [ $((now - warned_at)) -ge "$COORD_WAKE_DEFER_WARN_SECS" ]; then
            echo "[$(date +%T)] WARNING: coordinator wake has been deferred for ${age}s — composer keeps reading dirty on every retry (every ${COORD_WAKE_RETRY_SECS}s); check pane $SESSION_NAME:coordinator for a stuck human draft, or an autofill suggestion being misread as one (docs/tmux-as-channel.md §1d)"
            log_event coord.wake.deferred_stale "age=${age}s"
            touch "$COORD_WAKE_PENDING_WARNED_FILE" 2>/dev/null || true
        fi
    fi

    # issue #430 self-review finding: a composer that was DIRTY (human
    # draft) when this got deferred may since have been SUBMITTED — which
    # makes the pane BUSY (Claude Code processing that turn), not idle.
    # llm-start.sh's reprompt_composer_dirty treats a busy match as always
    # "clear, proceed to paste" (safe for a FRESH wake, since Claude Code
    # queues it) — but blindly retrying through that same path here would
    # splice this stale wake into the middle of the turn the human's draft
    # just started, exactly the incident #430 exists to prevent. Skip this
    # tick (not a ceiling — a genuinely stuck dirty draft still gets the
    # existing indefinite-retry-with-WARN treatment above; this only delays
    # delivery while the pane is ACTIVELY busy) and let the next
    # COORD_WAKE_RETRY_SECS tick re-check.
    #
    # issue #459 widened this from coordinator_pane_busy to the full hold
    # gate: an operator who submitted that draft and is now mid-conversation
    # is the same "don't splice a stale wake into their turn" case, and a
    # dirty composer that has since been submitted is exactly how a session
    # with a live human looks. Same skip-this-tick treatment, whatever the
    # reason.
    local hold_reason
    hold_reason="$(coord_wake_hold_reason)"
    if [ -n "$hold_reason" ]; then
        echo "[$(date +%T)] deferred coordinator wake still pending (held: $hold_reason) — retrying next tick"
        log_event coord.wake.skip "reason=$hold_reason trigger=retry age=${age}s"
        return 0
    fi

    echo "[$(date +%T)] retrying deferred coordinator wake (pending ${age}s)..."
    log_event coord.wake.retry "age=${age}s"

    if [ "$DRY_RUN" = "1" ]; then
        echo "[DRY] would retry: cd $PROJECT_DIR && NON_INTERACTIVE=1 $LLM_START <pending prompt, deferred ${age}s>"
        log_event coord.wake.deferred_delivered "age=${age}s dry_run=1"
        coord_wake_clear_pending
        return 0
    fi

    local wake_rc=0
    ( flock -w "$COORD_WAKE_LOCK_TIMEOUT_SECS" 9 && cd "$PROJECT_DIR" && NON_INTERACTIVE=1 "$LLM_START" "$pending_prompt" ) 9>"$COORD_WAKE_LOCK" || wake_rc=$?

    case "$wake_rc" in
        0)
            echo "[$(date +%T)] deferred coordinator wake delivered."
            log_event coord.wake.deferred_delivered "age=${age}s"
            coord_wake_clear_pending
            ;;
        3)
            log_event coord.wake.skip "reason=composer_dirty trigger=retry age=${age}s"
            ;;
        *)
            echo "[$(date +%T)] WARN: deferred coordinator wake retry exited non-zero (continuing watch)"
            log_event coord.wake.error "trigger=retry rc=$wake_rc age=${age}s"
            ;;
    esac
}

# Trigger logic — called when a NEW outcome JSON path is observed
on_outcome() {
    local path="$1"
    local now issue outcome
    now=$(date +%s)

    issue=$(outcome_path_issue "$path")
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

    # issue #430: the inbox write is UNCONDITIONAL, before the debounce
    # check below — a burst of outcomes landing inside one coalesced
    # doorbell window still produces one coord-inbox/*.md file PER outcome
    # (only the doorbell paste itself, below, is coalesced to one nudge).
    # This is also what fixes the "content existed nowhere but the failed
    # paste" gap a coord.wake.submit_failed used to leave (see this file's
    # own header comment): the payload is durable before any paste attempt.
    if [ "$DRY_RUN" = "1" ]; then
        echo "[$(date +%T)] [DRY] would write coord-inbox entry: issue=$issue outcome=$outcome path=$path"
    else
        if coord_inbox_write outcome "$(printf '%s\n\nTriggering outcome: issue=%s outcome=%s path=%s\n' "$WAKE_PROMPT" "$issue" "$outcome" "$path")"; then
            log_event coord.inbox.write "issue=$issue trigger=outcome:$(basename "$path")"
        else
            echo "[$(date +%T)] WARN: failed to write coord-inbox entry for $path" >&2
        fi
    fi

    # issue #456: a debounced doorbell is HELD, not dropped. Pre-#456 this
    # returned outright, so when two workers finished inside one window the
    # second outcome's inbox item had no doorbell attached at all and could
    # sit unread until some unrelated later wake — measured at ~11h in the
    # 2026-09-22 SAMlytics incident. Marking it pending hands it to
    # coord_wake_hold_retry_pass, which rings once the window passes; N
    # skipped doorbells coalesce into one "Inbox: N item(s)" nudge, which is
    # the intended outcome. Zero doorbells was the bug.
    if wake_debounced; then
        echo "[$(date +%T)] outcome: $path — within debounce window (${DEBOUNCE_SECS}s), holding doorbell for retry"
        log_event coord.wake.defer "issue=$issue reason=debounce window=${DEBOUNCE_SECS}s trigger=outcome"
        coord_wake_hold_mark_pending debounce
        return
    fi

    # Free slots from parked + PR-safe workers (PRs merged/closed) before
    # the coordinator wakes — otherwise its slot computation sees stale
    # alive-worker counts and reports cap-reached when wave 2 should fire.
    if [ "$WATCHER_AUTOCLOSE" = "1" ]; then
        echo "[$(date +%T)] running autoclose pass before wake..."
        cleanup_eligible_workers outcome
    fi

    echo "[$(date +%T)] outcome: $path"

    # issue #430/#459: don't paste a doorbell into a coordinator pane that
    # isn't free to take it. #430 covered "mid-turn" — Claude Code queues an
    # ill-timed paste and delivers it as an unrelated ❯ user turn spliced
    # into whatever the coordinator was already doing (the fand-app swarm PR
    # #1108 merge-turn incident, 2026-09-16). #459 added "the operator is
    # sitting here working" — a pane between turns reads idle, which is
    # exactly when someone is reading and thinking. coord_wake_hold_reason
    # is the single gate; see its header for the reason vocabulary.
    #
    # This gate sits BEFORE maybe_auto_compact too: a /compact injection is
    # itself a paste into the same composer, so there's nothing safe to
    # attempt while held either.
    local hold_reason
    hold_reason="$(coord_wake_hold_reason)"
    if [ -n "$hold_reason" ]; then
        echo "[$(date +%T)] coordinator not free to take a doorbell ($hold_reason) — deferring, will retry"
        log_event coord.wake.defer "issue=$issue reason=$hold_reason trigger=outcome"
        coord_wake_hold_mark_pending "$hold_reason"
    else
        maybe_auto_compact wake

        echo "[$(date +%T)] waking coordinator..."
        local nudge
        nudge="$(coord_inbox_nudge_text)"
        log_event coord.wake "issue=$issue trigger=$(basename "$path")"

        if [ "$DRY_RUN" = "1" ]; then
            echo "[DRY] would: cd $PROJECT_DIR && NON_INTERACTIVE=1 $LLM_START \"$nudge\""
        else
            # Run llm-start.sh in a subshell so its `set -e` doesn't kill us.
            # NON_INTERACTIVE=1 prevents auto-attach; coordinator runs detached
            # in its tmux session. flock's COORD_WAKE_LOCK (issue #392) so this
            # can't race on_activity's own llm-start.sh call from a different
            # OS process — see that lock's header comment. -w (not an unbounded
            # wait) plus && (not `;`) so EITHER a lock timeout OR a flock error
            # skips the unlocked llm-start.sh call entirely, falling through to
            # the same error handling below.
            local wake_rc=0
            ( flock -w "$COORD_WAKE_LOCK_TIMEOUT_SECS" 9 && cd "$PROJECT_DIR" && NON_INTERACTIVE=1 "$LLM_START" "$nudge" ) 9>"$COORD_WAKE_LOCK" || wake_rc=$?
            if [ "$wake_rc" = "3" ]; then
                # issue #422: llm-start.sh's reprompt_inject found the composer
                # holding an unsubmitted human draft and refused to paste over
                # it. Not an error — persist the prompt for coord_wake_retry_pass
                # (run_watch_timer_loop, COORD_WAKE_RETRY_SECS) instead of
                # dropping it; see coord_wake_set_pending's header comment for
                # why it's a file, not a plain global.
                echo "[$(date +%T)] coordinator composer holds an unsubmitted draft — deferring wake, will retry"
                log_event coord.wake.deferred "issue=$issue reason=composer_dirty"
                coord_wake_set_pending "$nudge"
            elif [ "$wake_rc" != "0" ]; then
                echo "[$(date +%T)] WARN: coordinator wake exited non-zero (continuing watch)"
                log_event coord.wake.error "issue=$issue rc=$wake_rc"
            else
                # issue #422 self-review finding: this fresh wake just landed
                # directly — drop any STALE prompt left over from an earlier
                # deferral (coord_wake_set_pending never overwrites a pending
                # entry, so one could still be sitting there from before the
                # composer cleared). Without this, coord_wake_retry_pass would
                # later deliver that stale prompt as a redundant duplicate wake,
                # even though the coordinator already has fresher instructions.
                # No-op (cheap) when nothing was pending.
                coord_wake_clear_pending
                # issue #430 self-review finding, same class as #422's above:
                # a PRIOR outcome/message could have busy-marked a pending
                # doorbell (coord_wake_hold_mark_pending) that hasn't been
                # retried yet — if the pane went idle and THIS wake pasted
                # directly (this branch) before coord_wake_hold_retry_pass's
                # next tick, that marker is now stale. Left uncleared,
                # coord_wake_hold_retry_pass would still deliver a SECOND,
                # redundant nudge once its tick runs, even though the
                # coordinator already got one just now.
                coord_wake_hold_clear_pending
            fi
        fi
    fi
    wake_clock_set "$now"

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

# on_message <outbox-message-path>
#
# (issue #129) A worker dropped a message file into its
# `.swarm/tasks/outbox/`. Wake the coordinator with a message-triage prompt.
# Mirrors on_outcome's shape (inbox write -> debounce -> busy gate ->
# pre-wake compact -> llm-start -> ONCE) minus the outcome-only steps: no
# sweep (nothing to post — the message IS the payload) and no autoclose
# pass (a message never frees a slot).
on_message() {
    local path="$1"
    local now issue
    now=$(date +%s)
    issue=$(msg_issue "$path")
    log_event worker.message "issue=$issue path=$path"

    # Default prompt is built per-event so it can name the triggering file,
    # but it always instructs a full outbox scan — that's what makes the
    # debounce below safe (coalesced messages surface on the next wake) and
    # what picks up messages that predate this watcher process.
    local wake_prompt="$OUTBOX_WAKE_PROMPT"
    if [ -z "$wake_prompt" ]; then
        wake_prompt="Worker iss-$issue posted a message to its outbox: $path. List every unprocessed message with: for wt in \$($LLM_SWARM_DIR/scripts/list-own-worktrees.sh $PROJECT_DIR); do ls \"\$wt\"/.swarm/tasks/outbox/*.md 2>/dev/null; done — then, oldest first, read each and act on its kind (fyi: note it in your status picture; decision-needed: decide or surface to the operator; brief-draft: review the drafted brief and dispatch it via provision-worker.sh or requeue.sh if warranted, otherwise tell the operator why not). After handling a message, archive it: mkdir -p <its-outbox>/processed && mv <message> <its-outbox>/processed/. Never leave a handled message in outbox/ — unarchived means unread."
    fi

    # issue #430: unconditional inbox write — see on_outcome's identical
    # step for the full rationale.
    if [ "$DRY_RUN" = "1" ]; then
        echo "[$(date +%T)] [DRY] would write coord-inbox entry: issue=$issue path=$path"
    else
        if coord_inbox_write outbox "$(printf '%s\n\nTriggering message: %s\n' "$wake_prompt" "$path")"; then
            log_event coord.inbox.write "issue=$issue trigger=outbox:$(basename "$path")"
        else
            echo "[$(date +%T)] WARN: failed to write coord-inbox entry for $path" >&2
        fi
    fi

    # issue #456 — see on_outcome's identical branch for the full rationale
    # (hold, don't drop; the outbox path had the same hole).
    if wake_debounced; then
        echo "[$(date +%T)] message: $path — within debounce window (${DEBOUNCE_SECS}s), holding doorbell for retry"
        log_event coord.wake.defer "issue=$issue reason=debounce window=${DEBOUNCE_SECS}s trigger=outbox"
        coord_wake_hold_mark_pending debounce
        return
    fi

    echo "[$(date +%T)] message: $path"

    # issue #430/#459: same doorbell hold gate as on_outcome — see that
    # function's identical branch for the full rationale.
    local hold_reason
    hold_reason="$(coord_wake_hold_reason)"
    if [ -n "$hold_reason" ]; then
        echo "[$(date +%T)] coordinator not free to take a doorbell ($hold_reason) — deferring, will retry"
        log_event coord.wake.defer "issue=$issue reason=$hold_reason trigger=outbox"
        coord_wake_hold_mark_pending "$hold_reason"
    else
        maybe_auto_compact wake

        echo "[$(date +%T)] waking coordinator (outbox)..."
        local nudge
        nudge="$(coord_inbox_nudge_text)"
        log_event coord.wake "issue=$issue trigger=outbox:$(basename "$path")"

        if [ "$DRY_RUN" = "1" ]; then
            echo "[DRY] would: cd $PROJECT_DIR && NON_INTERACTIVE=1 $LLM_START \"$nudge\""
        else
            # flock's COORD_WAKE_LOCK (issue #392, bounded -w) — see its
            # header comment and on_outcome's call site above for why -w/&&.
            local wake_rc=0
            ( flock -w "$COORD_WAKE_LOCK_TIMEOUT_SECS" 9 && cd "$PROJECT_DIR" && NON_INTERACTIVE=1 "$LLM_START" "$nudge" ) 9>"$COORD_WAKE_LOCK" || wake_rc=$?
            if [ "$wake_rc" = "3" ]; then
                # issue #422 — see on_outcome's identical branch for the full
                # rationale.
                echo "[$(date +%T)] coordinator composer holds an unsubmitted draft — deferring wake, will retry"
                log_event coord.wake.deferred "issue=$issue reason=composer_dirty trigger=outbox"
                coord_wake_set_pending "$nudge"
            elif [ "$wake_rc" != "0" ]; then
                echo "[$(date +%T)] WARN: coordinator wake exited non-zero (continuing watch)"
                log_event coord.wake.error "issue=$issue trigger=outbox rc=$wake_rc"
            else
                # issue #422 self-review finding — see on_outcome's identical
                # branch for the full rationale (drop a stale pending prompt
                # now that a fresh one just landed directly).
                coord_wake_clear_pending
                # issue #430 self-review finding — see on_outcome's identical
                # branch for the full rationale (drop a stale busy-pending
                # marker too, or coord_wake_hold_retry_pass's next tick would
                # deliver a redundant second nudge).
                coord_wake_hold_clear_pending
            fi
        fi
    fi
    wake_clock_set "$now"

    if [ "$ONCE" = "1" ]; then
        echo "[$(date +%T)] ONCE=1 — exiting after first wake."
        log_event watch.exit "reason=once"
        # Same pane-echo grace period as on_outcome's ONCE path — see the
        # comment there for why 1.5s.
        [ "$WATCHER_QUIET" = "1" ] || sleep 1.5
        exit 0
    fi
}

# on_activity <lines>
#
# (issue #392) activity_poll_pass found operator activity (PR merge / issue
# close) with no other wake path — see WATCH_ACTIVITY_POLL_SECS's header
# comment. Called from the run_watch_timer_loop background process (not
# the main inotify/poll loop that calls on_outcome/on_message) — its own
# debounce clock, LAST_ACTIVITY_WAKE, keeps it from being swallowed by, or
# swallowing, an unrelated outcome/outbox wake.
#
# (issue #430) INBOX-ONLY, no doorbell: unlike on_outcome/on_message, this
# never calls llm-start.sh at all. An activity-poll finding only matters
# the next time the coordinator speaks — "something you may be reporting
# as pending was resolved in the GitHub web UI" is never urgent enough to
# justify interrupting a live turn or a busy-pane retry/ceiling dance — and
# prompts/coordinator.md's "Inbox" section already has the coordinator
# scanning coord-inbox/ at the start of every turn and after finishing an
# operator request, which is sufficient delivery. This also removes the
# COORD_WAKE_LOCK cross-process race this function used to need to guard
# against (issue #392 self-review) — coord_inbox_write's own mktemp+mv is
# safe against concurrent writers on its own, no lock required.
#
# Returns 1 on a debounced skip OR a failed inbox write, 0 otherwise — the
# caller, activity_poll_pass, only marks its ACTIVITY_ANNOUNCED_PR/_ISSUE
# dedup maps on a 0 return, so a finding that didn't actually get recorded
# stays eligible for a later tick to retry rather than being marked
# "announced" for a write that never landed. DRY_RUN always counts as
# success (0), matching every other side-effecting pass in this file.
on_activity() {
    local lines="$1"
    local now
    now=$(date +%s)

    if [ $((now - LAST_ACTIVITY_WAKE)) -lt "$DEBOUNCE_SECS" ]; then
        echo "[$(date +%T)] activity: within debounce window (${DEBOUNCE_SECS}s), skipping"
        log_event coord.wake.skip "reason=debounce window=${DEBOUNCE_SECS}s trigger=activity_poll"
        return 1
    fi

    local body="$ACTIVITY_WAKE_PROMPT"
    if [ -z "$body" ]; then
        body="A periodic gh-search poll (issue #392) found GitHub activity that didn't come through the usual worker-outcome wake path — most likely the operator resolved it directly in the GitHub web UI while this swarm's workers for it were already reaped:
$lines
Re-check your own picture of outstanding decisions/PRs/issues against this (gh pr list / gh issue list) and correct anything you were still reporting as pending on these."
    fi

    echo "[$(date +%T)] activity: detected — writing to coordinator inbox (no doorbell, issue #430)"

    local write_ok=1
    if [ "$DRY_RUN" = "1" ]; then
        echo "[DRY] would write coord-inbox activity entry"
    else
        if coord_inbox_write activity "$body"; then
            log_event coord.inbox.write "trigger=activity_poll"
        else
            echo "[$(date +%T)] WARN: failed to write coord-inbox activity entry" >&2
            write_ok=0
        fi
    fi

    [ "$write_ok" = "1" ] || return 1
    LAST_ACTIVITY_WAKE=$now
    return 0
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
    # issue #357: this name-glob CAN match a sibling project's worktree
    # under flat grouping (inotifywait has no equivalent of `git worktree
    # list` to scope its recursive watch), but that's harmless here — every
    # matched path is still run through dispatch_outcome/dispatch_message
    # below, which reject anything not registered as $PROJECT_DIR's own
    # worktree via is_our_worktree() before any action is taken. Left as a
    # glob rather than watching each own-worktree dir individually because
    # inotify has no cheap way to add watches for worktrees created AFTER
    # this process starts without re-globbing anyway.
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
            */wt-issue-*/.swarm/tasks/outbox/processed/*)
                # Lifecycle archive (coordinator mv after handling) — the
                # mv into processed/ raises moved_to too; not a new message.
                ;;
            */wt-issue-*/.swarm/tasks/outbox/*.md)
                # Worker message (issue #129). Only final names trigger:
                # the write convention is mktemp WITHOUT the .md suffix,
                # then mv — so half-written temp files never match *.md.
                [ "$WATCH_OUTBOX" = "1" ] && dispatch_message "$path"
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

    # Scan only wt-issue-*/.swarm/tasks/done dirs under this project's OWN
    # worktrees (own_worktree_dirs_for_scan() -> swarm_own_worktree_dirs(),
    # issue #357 — `git worktree list` against $PROJECT_DIR's own repo, not
    # a name-glob under $WORKSPACE that a sibling project's swarm can also
    # populate under flat grouping; own_worktree_dirs_for_scan() falls back
    # to that raw glob, fail-open, if $PROJECT_DIR isn't a working git repo
    # — see its header above). May expand to nothing if no worker worktrees
    # exist yet — handle that gracefully so the find call gets an empty arg
    # list.
    scan_outcomes() {
        local done_dirs=() outbox_dirs=() wt
        while IFS= read -r wt; do
            [ -n "$wt" ] || continue
            [ -d "$wt/.swarm/tasks/done" ] && done_dirs+=("$wt/.swarm/tasks/done")
            [ -d "$wt/.swarm/tasks/outbox" ] && outbox_dirs+=("$wt/.swarm/tasks/outbox")
        done < <(own_worktree_dirs_for_scan "$PROJECT_DIR")
        {
            if [ "${#done_dirs[@]}" -gt 0 ]; then
                find "${done_dirs[@]}" -maxdepth 1 \
                    \( -name '*.ok.json' -o -name '*.err.json' \) -print 2>/dev/null
            fi
            # Worker messages (issue #129). -maxdepth 1 keeps the archived
            # outbox/processed/ subtree out of the scan.
            if [ "$WATCH_OUTBOX" = "1" ] && [ "${#outbox_dirs[@]}" -gt 0 ]; then
                find "${outbox_dirs[@]}" -maxdepth 1 -name '*.md' -print 2>/dev/null
            fi
        } | sort -u
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
                case "$path" in
                    */.swarm/tasks/outbox/*.md) dispatch_message "$path" ;;
                    *)                          dispatch_outcome "$path" ;;
                esac
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
# issue #430: COORD_WAKE_BUSY_RETRY_SECS must also start this loop —
# coord_wake_hold_retry_pass is ticked from inside it, same as every other
# pass here — or a deployment with every other timer-loop feature disabled
# (all plausible in a minimal/test config) would silently never retry a
# busy-pane-deferred wake at all, leaving it stuck until the process
# restarts. (COORD_WAKE_RETRY_SECS, issue #422's older dirty-draft retry,
# has this identical gap and predates this fix — out of scope here, but
# worth folding in alongside this one if it's ever revisited.)
if [ "$WATCH_PR_POLL_SECS" -gt 0 ] || [ "$WATCH_CHECK_ON_DONE" = "1" ] || [ "$WATCH_ORPHAN_SWEEP_SECS" -gt 0 ] || [ "$WATCH_BG_VIOLATION_SWEEP_SECS" -gt 0 ] || [ "$WATCH_ACTIVITY_POLL_SECS" -gt 0 ] || [ "$WATCH_WORKTREE_SWEEP_SECS" -gt 0 ] || [ "$WATCH_PENDING_BRIEF_SWEEP_SECS" -gt 0 ] || [ "$COORD_WAKE_HOLD_RETRY_SECS" -gt 0 ]; then
    run_watch_timer_loop &
    WATCH_TIMER_PID=$!
    log_event watch.timer.start "pr_poll_secs=$WATCH_PR_POLL_SECS check_on_done=$WATCH_CHECK_ON_DONE orphan_sweep_secs=$WATCH_ORPHAN_SWEEP_SECS bg_violation_sweep_secs=$WATCH_BG_VIOLATION_SWEEP_SECS activity_poll_secs=$WATCH_ACTIVITY_POLL_SECS worktree_sweep_secs=$WATCH_WORKTREE_SWEEP_SECS pending_brief_sweep_secs=$WATCH_PENDING_BRIEF_SWEEP_SECS"
fi
if [ "$WORKER_AUTO_COMPACT" = "1" ] || [ "$WORKER_AUTO_DELIVER" = "1" ]; then
    run_worker_compact_loop &
    WORKER_COMPACT_TIMER_PID=$!
    log_event watch.timer.start "worker_auto_compact=$WORKER_AUTO_COMPACT worker_auto_deliver=$WORKER_AUTO_DELIVER scan_secs=$WORKER_COMPACT_SCAN_SECS"
fi
if [ "$AUTO_COMPACT" = "1" ] && [ "$AUTO_COMPACT_TICK_SECS" -gt 0 ]; then
    run_auto_compact_poll_loop &
    AUTO_COMPACT_POLL_TIMER_PID=$!
    log_event watch.timer.start "auto_compact_tick_secs=$AUTO_COMPACT_TICK_SECS auto_compact_cooldown_secs=$AUTO_COMPACT_COOLDOWN_SECS"
fi
# issue #296 — unconditional (subject only to its own WATCHER_STALE_CHECK
# flag), unlike the three loops above which only start when their own
# feature is enabled; see run_stale_check_loop's header comment.
if [ "$WATCHER_STALE_CHECK" = "1" ] && [ "$WATCHER_STALE_CHECK_SECS" -gt 0 ]; then
    run_stale_check_loop &
    STALE_CHECK_PID=$!
    log_event watch.timer.start "watcher_stale_check_secs=$WATCHER_STALE_CHECK_SECS"
fi

case "$BACKEND" in
    inotify) run_inotify ;;
    poll)    run_poll ;;
esac
