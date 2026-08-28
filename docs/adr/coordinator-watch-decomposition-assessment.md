# Assessment: decomposing coordinator-watch.sh

**Status:** Assessment only — not a decision record. Written for issue #257.
No code changes accompany this document; `scripts/coordinator-watch.sh` was
read but not modified (issue #252 was concurrently active in that file per
#257's constraint). This becomes actionable once the follow-up issues in
§5 are filed and prioritized.

## Scope note: the elephant grew while this issue waited

Issue #257 was filed against a **2,273-line / 36-function** script. As of
this assessment (2026-08-28) the file is **3,431 lines / 44 functions** —
+1,158 lines and +8 functions since filing, almost entirely `WORKER_AUTO_COMPACT`
(#226), the pane-injection reliability hardening for it (#252, #259, #265,
#266, #274, #290, #292), and `WATCHER_AUTOCLOSE_MODE` (#237). The growth rate
itself is evidence for this issue's premise: every one of those landed as a
patch to the same file because there was no seam to land it elsewhere. The
longer extraction waits, the more surface area each future extraction has to
untangle. Function line numbers below are current as of this read; re-verify
before treating any as a citation into a future commit.

## 1. Seam map

Eight concern clusters, grouped by what they actually touch, not just by
naming convention.

### 1.1 Preamble (env/config/validation) — lines 1–1195, no functions

Reads env vars with defaults, validates enums/integers, resolves `BACKEND`,
prints the startup banner, installs the exit trap, declares script-global
state (`LAST_WAKE`, `ORPHAN_PR_LOGGED`, etc.). **Not cleanly extractable as
a unit** — it's the initialization for every cluster below, and several
clusters' defaults reference each other in the banner (e.g. autoclose mode
feeding `AUTOCLOSE_PR_FLAG`). It *is* mechanically splittable per-cluster
(each cluster's env vars move with its functions into a sourced lib), which
is the actual seam — see §2.

### 1.2 Event log / formatting — `log_event` (1195), `format_event_line` (1209)

The one truly universal dependency: every other cluster calls `log_event`.
`format_event_line` (pane-echo presentation) is read-only against
`events.log` and referenced by nothing else. **Cleanly extractable** as
`watch-lib-events.sh` — two functions, one global (`EVENTS_LOG`), no tmux/gh
dependency, must be sourced first by everything else.

### 1.3 Outcome/message dispatch & top-up — `is_our_worktree` (1429),
`dispatch_outcome`/`dispatch_message` (1449/1464), `msg_issue` (1478),
`on_outcome` (3166), `on_message` (3257), `run_inotify` (3308), `run_poll`
(3342)

The main event loop. `on_outcome` is the **most entangled function in the
file** — it calls into cluster 1.4 (`cleanup_eligible_workers`), cluster 1.5
(`maybe_auto_compact`), cluster 1.7 (`SWEEP`), and owns `LAST_WAKE`/debounce.
`on_message` is a near-duplicate of `on_outcome` minus the sweep/autoclose
steps, sharing `maybe_auto_compact` and its own `LAST_MSG_WAKE` clock.
`run_inotify`/`run_poll` are pure I/O adapters that just call
`dispatch_outcome`/`dispatch_message` — cleanly separable from the dispatch
logic itself. **Genuinely entangled** at the `on_outcome`/`on_message` level
(they are the orchestration root every other cluster hangs off), but the
backend adapters (`run_inotify`, `run_poll`) and the low-level dispatch
filter (`is_our_worktree`, `dispatch_outcome`, `dispatch_message`, `msg_issue`)
are separable from the two `on_*` handlers themselves.

### 1.4 PR polling & autoclose — `cleanup_eligible_workers` (1518),
`mtime_epoch` (1542), `worktree_birth_path` (1557), `pr_predates_worktree`
(1583), `has_live_window` (1603), `pr_poll_pass` (1625), `pr_state_for_worktree`
(1764)

Self-contained around `$WORKSPACE`, `$SESSION_NAME`, `$AUTOCLOSE_PR_FLAG`,
and shells out to `kill-finished-workers.sh`/`gh pr list`. Only external
coupling: `pr_poll_pass` calls `maybe_run_check` (cluster 1.6) inline at
line 1681, and `cleanup_eligible_workers` is called from `on_outcome` (1.3)
and `pr_poll_pass` itself (backstop trigger). **Cleanly extractable** as
`watch-lib-reap.sh` if that one call into 1.6 becomes a callback/hook
instead of a direct call (see §2 shared-state note on `WATCH_CHECK_ON_DONE`).

### 1.5 Orphan/worker reaping (window-less) — `orphan_sweep_pass` (1715)

One function, thin wrapper around `reap-orphan-worktrees.sh`. Trivially
extractable on its own, or folds into 1.4's lib (they're both "reap" and
share `$DRY_RUN`/`$AUTOCLOSE_PR_FLAG`-adjacent conventions, though
`orphan_sweep_pass` deliberately ignores `WATCHER_AUTOCLOSE_MODE` — see its
own header comment). Recommend folding into 1.4 rather than a fifth tiny
file — no independent value in separating it further.

### 1.6 Acceptance checks (check-on-done) — `status_poll_pass` (1735),
`check_json_state` (1775), `maybe_run_check` (1806), `record_check_result`
(1913), `execute_check` (1947)

Self-contained around `.swarm/tasks/status/*.json` and `*.check.json` /
`*.check-claim` conventions, `CHECK_RUNNER` test seam, and spawns `chk-N`
tmux windows. Two entry points from outside the cluster: `status_poll_pass`
called from `run_watch_timer_loop` (1.3-adjacent), `maybe_run_check` called
directly from `pr_poll_pass` (1.4). **Cleanly extractable** as
`watch-lib-checks.sh` given those two call sites become explicit function
calls across the lib boundary (bash sourcing makes this free — no interface
needed, just correct `source` ordering).

### 1.7 Coordinator auto-compact — `coordinator_pane_state` (2097),
`coordinator_pane_busy` (2120), `probe_ctx_used` (2140), `maybe_auto_compact`
(2375), `auto_compact_poll_pass` (2624), plus five shared pane-chrome helpers
(§1.9)

Coordinator-specific: probe-file staleness (`probe_ctx_used`), the
`$AUTO_COMPACT_LOCK` flock, `$SESSION_NAME:coordinator` as a fixed tmux
target. Calls into 1.9 (pane-chrome helpers) heavily. **Cleanly extractable**
as `watch-lib-coord-compact.sh` once 1.9 is its own lib these two compact
clusters both source.

### 1.8 Worker auto-compact — `worker_pane_state` (2664), `worker_pane_busy`
(2682), `worker_pane_ctx_used` (2705), `worker_pane_ctx_window` (2736),
`worker_compact_effective_threshold` (2770), `worker_has_open_pr` (2797),
`worker_task_done` (2858), `worker_compact_record_failure`/`_success`
(2923/2941), `maybe_worker_compact` (2954), `worker_compact_pass` (3151)

Structurally a mirror of 1.7, parameterized by `<window>` instead of a fixed
target, plus worker-specific concerns 1.7 has no equivalent for:
`worker_has_open_pr` and `worker_task_done` both read
`.swarm/tasks/status/*.json` (crossing into 1.6's data domain, read-only),
and the three in-memory backoff associative arrays
(`WORKER_COMPACT_LAST_FAIL`/`_FAIL_COUNT`/`_GAVE_UP`) are process-local to
`run_worker_compact_loop`. **Cleanly extractable** as
`watch-lib-worker-compact.sh`, same 1.9 dependency as 1.7.

### 1.9 Shared pane-chrome primitives (cross-cutting, not its own cluster)

`compact_last_pane_line` (2183), `compact_composer_clear` (2208),
`compact_confirm_submitted` (2224), `compact_replay_detected` (2254),
`compact_retract_queued` (2311) — all take `<tmux-target>` as their first
arg and touch no globals besides the shared `COMPACT_*` pattern env vars.
This is the **single cleanest extraction in the whole file**: five
parameter-only functions, already written target-agnostic (that's *why*
1.7 and 1.8 can both call them), zero entanglement. Extract first, as
`watch-lib-compact-chrome.sh`, sourced by both 1.7 and 1.8's libs.

### 1.10 Timer-loop shells

`run_watch_timer_loop` (2026), `run_auto_compact_poll_loop` (2062),
`run_worker_compact_loop` (2077) — thin `while true; sleep; call-pass` shells,
one per background process. These are glue, not a cluster of their own;
each moves with the lib whose pass function it drives (1.10a with 1.4/1.6,
1.10b with 1.7, 1.10c with 1.8). Genuinely entangled with the main script
only insofar as their PIDs (`WATCH_TIMER_PID` etc.) are captured at
top-level for `cleanup_on_exit`'s trap — that capture point cannot move
into a lib without changing the trap's shape (see §2).

## 2. Shared-state inventory

| State | Type | Written by | Read by | Extraction implication |
|---|---|---|---|---|
| `EVENTS_LOG` | var (path) | preamble | every cluster via `log_event` | must be set before any lib sources; trivial constant to pass |
| `log_event` | function | 1.2 | every cluster | 1.2 must be sourced first, always |
| `PROJECT_DIR`, `WORKSPACE`, `SESSION_NAME` | vars | preamble | nearly every cluster | pass-through constants; no ordering risk |
| `DRY_RUN` | var | preamble | 1.4, 1.5, 1.6, 1.7, 1.8 | pass-through constant |
| `HAVE_JQ` | var | preamble | 1.4 (`status_poll_pass`), 1.6, 1.8 (`worker_has_open_pr`, `worker_task_done`) | pass-through constant |
| `LAST_WAKE` / `LAST_MSG_WAKE` | var (epoch) | 1.3 (`on_outcome`/`on_message`) | same functions only | stays in 1.3, no extraction impact |
| `ORPHAN_PR_LOGGED` | assoc array | 1.4 (`pr_poll_pass`) | same function only | stays in 1.4 |
| `AUTOCLOSE_PR_FLAG` | var | preamble (derived from `WATCHER_AUTOCLOSE_MODE`) | 1.4 | pass-through constant, computed once |
| `AUTO_COMPACT_LOCK` | var (path) | preamble | 1.7 (`maybe_auto_compact`, via flock) | pass-through constant |
| `LAST_AUTO_COMPACT_POLL_TRIGGER` | var (epoch) | 1.7 (`auto_compact_poll_pass`) | same function only | stays in 1.7 |
| `WORKER_COMPACT_LAST_FAIL`/`_FAIL_COUNT`/`_GAVE_UP` | assoc arrays | 1.8 | 1.8 only | stays in 1.8 |
| `.swarm/tasks/status/<task_id>.json` | file convention | worker-listener.sh (external), 1.6 (`maybe_run_check`) | 1.4 (`pr_state_for_worktree` doesn't read it, but `pr_poll_pass` calls into 1.6), 1.6, 1.8 (`worker_has_open_pr`, `worker_task_done`) | **the real cross-cluster coupling** — 1.6 owns the write path, 1.8 reads it read-only for two independent signals. Safe as a documented file-format contract, not a shared bash variable — no extraction blocker, just needs the contract written down once (see §5 item) |
| `.swarm/tasks/status/<task_id>.check.json` / `.check-claim/` | file convention | 1.6 only | 1.6 only, plus kill-worktree.sh (external) | fully owned by 1.6; external contract (kill-worktree.sh's reap-guard) must not change on extraction |
| `.swarm/tasks/done/*.ok.json` / `*.err.json` | file convention | worker-listener.sh (external) | 1.3 (dispatch), 1.8 (`worker_task_done` signal a) | read-only from both; no coupling risk |
| `.swarm/tasks/outbox/*.md` | file convention | workers (external) | 1.3 only | fully owned by 1.3 |
| `WATCH_TIMER_PID`, `WORKER_COMPACT_TIMER_PID`, `AUTO_COMPACT_POLL_TIMER_PID`, `seen_file` | vars | top-level (after backgrounding each loop) | `cleanup_on_exit` trap only | **must stay top-level** — see §2 note below |
| `COMPACT_QUEUED_MARKER_PATTERN`, `COMPACT_RETRACT_BACKSPACES`, `COMPACT_SUBMIT_SETTLE_SECS`, `COMPACT_REPLAY_PATTERN`, `COMPACT_REPLAY_MIN_REAL_SECS` | vars | preamble | 1.9 (shared by 1.7 and 1.8 call sites) | pass-through constants; literal reason these are named `COMPACT_*` not `AUTO_COMPACT_*`/`WORKER_COMPACT_*` — already designed as the shared layer |

**Extraction order this implies:** 1.2 (events) first — it's the only
zero-dependency cluster and everything else needs it. 1.9 (pane-chrome)
second — zero dependency on anything except tmux and its own env vars.
Then 1.4/1.5 (reap) and 1.6 (checks) in either order, followed by 1.7 and
1.8 (each depends on 1.9 plus the vars above). 1.3 (dispatch/on_outcome/
on_message) last — it is the integration point that calls into every other
cluster, so extracting it first would just mean re-doing the interface
once each other cluster moves.

**The `cleanup_on_exit` trap is the one hard architectural constraint.**
It kills `WATCH_TIMER_PID` / `WORKER_COMPACT_TIMER_PID` /
`AUTO_COMPACT_POLL_TIMER_PID` and `seen_file` by PID/path captured at the
point each background loop is launched (bottom of the script, lines
3412–3426). Moving a `run_*_loop` function into a sourced lib is fine —
functions are still callable after `source`; but the `foo &`/`PID=$!`
launch statements and the trap itself must stay in the top-level script,
because bash trap handlers only see the invoking process's variables, and
`&`-backgrounding from inside a sourced function still returns `$!` to the
caller correctly (this is fine) — the risk is only if a future refactor
tries to move the *launch* into the lib and return the PID some other way.
Flag this explicitly for whoever does the extraction: **launch statements
and the trap stay in `coordinator-watch.sh` itself; only the loop bodies
and pass functions move.**

## 3. Risk ranking

| Extraction | Test coverage | Entanglement (§1) | Risk |
|---|---|---|---|
| 1.2 events (`log_event`, `format_event_line`) | **None dedicated.** `format_event_line` has zero test references in `tests/*.sh`; `log_event` is exercised only incidentally (its output is grepped by other scripts' tests, e.g. test-coordinator-auto-compact.sh, test-worker-auto-compact.sh, test-llm-start-reprompt.sh) | None — leaf cluster | **Low risk to extract, but add a direct shape test for `format_event_line`'s glyph/color table FIRST** — it's pure input→string, trivially testable, and currently has zero direct assertions despite being user-facing (pane echo) |
| 1.9 pane-chrome (`compact_last_pane_line` etc.) | Indirectly covered via test-coordinator-auto-compact.sh (1063 lines) and test-worker-auto-compact.sh (1186 lines), which exercise `maybe_auto_compact`/`maybe_worker_compact` end-to-end against a fake tmux — no isolated unit tests of the five chrome functions themselves | None — leaf cluster (only needs tmux + its own env vars) | **Low.** Existing tests exercise these functions transitively on every scenario (submit-settle, retraction, replay-detection are all covered indirectly per their `9a`–`9d`-style subtests). Safe to extract as-is; the two large compact test files are the regression gate |
| 1.4/1.5 reap (`cleanup_eligible_workers`, `pr_poll_pass`, `orphan_sweep_pass`, `pr_predates_worktree`, etc.) | test-watcher-autoclose.sh (930 lines, 12+ numbered test cases including stale-claim and check-claim defer scenarios), test-pr-predates-worktree.sh (147 lines, dedicated) | Low — one inline call from `pr_poll_pass` into `maybe_run_check` (1.6) | **Low-medium.** Well covered; the one cross-cluster call must survive extraction with an explicit `source watch-lib-checks.sh` (or equivalent) — a missed source line is the realistic failure mode, and it fails LOUD (unbound function) rather than silently, so shape tests will catch it immediately |
| 1.6 checks (`maybe_run_check`, `execute_check`, etc.) | test-shape-checks.sh (229 lines, 4 numbered cases: brief marker, check-fails, `.swarm/check.sh` fallback, no-check-configured) | Called from both `pr_poll_pass` (1.4) and `status_poll_pass` (1.3-adjacent, in `run_watch_timer_loop`) | **Medium.** Test coverage is present but thinner (4 cases) than the claim/backoff logic in `maybe_run_check`'s own header comment implies (claim-dir races, task_id disambiguation across multiple status files, PR-already-terminal skip) — recommend adding cases for "PR already MERGED at claim time" and "second status file's task_id gets picked, not the first" before extracting, since those are the subtlest parts of `maybe_run_check` and not obviously exercised today |
| 1.7 coordinator auto-compact | test-coordinator-auto-compact.sh (1063 lines; subtests through at least `9d`, covering poll-tick cooldown, busy-skip, threshold) | Depends on 1.9; called from `on_outcome` (1.3) and its own poll loop | **Low-medium.** Heavily tested. The flock-based `AUTO_COMPACT_LOCK` serialization between the wake-path and poll-tick callers is the one piece worth a dedicated concurrency-shaped test if one doesn't already exist — verify before extracting, since a lib boundary is exactly where a `9>"$AUTO_COMPACT_LOCK"` fd-redirect subshell trick could silently break if the function moves without care |
| 1.8 worker auto-compact | test-worker-auto-compact.sh (1186 lines, the largest test file in the suite) | Depends on 1.9; reads `.swarm/tasks/status/*.json` (owned by 1.6); called from its own loop only | **Low-medium.** Best-tested cluster by line count. Same flock/subshell caution does NOT apply here (no lock), but the backoff associative arrays are process-local state that must not accidentally get shared with 1.7's — keep them namespaced distinctly if both libs are ever sourced into the same process (they already are, today, in the one script) |
| 1.3 dispatch/`on_outcome`/`on_message`/backends | test-scripts.sh mentions polling-backend/DRY_RUN/ONCE/missing-project coverage per the overview doc (line 603); no dedicated `on_message`/outbox test found | **Highest** — this is the integration root calling into every other cluster | **High — extract last, and only after 1.4/1.6/1.7 are already separately sourced libs it can call into.** `on_message`/`dispatch_message`/`msg_issue`/`WATCH_OUTBOX` have **zero test coverage found in this read** (`grep -rl "dispatch_message\|on_message\|WATCH_OUTBOX" tests/*.sh` returns nothing) — write shape tests for the outbox wake path BEFORE extracting `on_outcome`/`on_message`, not as part of the same PR. This is the single biggest test-coverage gap in the file relative to its risk. |

## 4. Trim candidates

Evidence-based only — each of these is backed by a comment in the script
itself or a direct code observation, not speculation:

1. **`WORKER_COMPACT_WRAPUP_THRESHOLD_TOKENS` is documented dead code in
   normal operation.** The script's own header comment (lines 488–511)
   states plainly: because `worker_task_done`'s status check now fires for
   the same condition `worker_has_open_pr` (and thus the wrapup threshold)
   was gating, "a worker with an open PR is no longer compacted via the
   wrap-up path at all" and the env var is "effectively unreachable code in
   normal operation," kept only as "a well-defined, independently-tested
   fallback." This is a legitimate candidate for **either deletion (if the
   maintainer agrees the fallback isn't worth the config-surface cost) or,
   at minimum, an explicit `WARN` log line the one time it's computed but
   never reached** — right now a maintainer reading `WORKER_COMPACT_*`'s 13
   env vars has no signal that one of them is inert. Do not delete without
   maintainer sign-off — the comment is explicit that this was a deliberate
   keep, not an oversight.
2. **`format_event_line`'s `pr_poll.error` and `sweep.dry`/`sweep.error`
   glyph cases are untested and low-traffic.** Not dead, but candidates to
   fold into the direct test recommended in §3 rather than trim. A literal
   grep for each of the ~40 category strings against `log_event` call
   sites in this file alone shows several at zero (`cap.refused`,
   `reap.window`, `worker.requeue`, `worker.start`, and all six
   `*.retract_failed`/`*.retract_skip`/`*.retracted` variants) — but that's
   a grep artifact, not evidence of dead code: the first four are logged
   by *sibling scripts* sharing the same `events.log` (`provision-worker.sh`,
   `kill-finished-workers.sh`, `worker-listener.sh` — see the header
   comment's own PANE ECHO section), and the retract-verdict trio is
   constructed dynamically as `"${prefix}.retracted"` inside
   `compact_retract_queued` rather than as a literal string, so a plain
   grep can't find the call site even though it's live. Net: nothing in
   `format_event_line`'s case statement is confirmed dead; downgrading
   this from a trim candidate to a test-gap note only.
3. **Polling backend (`run_poll`) is NOT a trim candidate** — despite
   `inotifywait` being the preferred/default backend, `run_poll` is the
   documented fallback for hosts without `inotify-tools`, is exercised
   directly by test-scripts.sh (per the overview doc), and sandboxed/
   containerized environments without inotify support are explicitly
   called out in the script's own `AUTO_COMPACT_TICK_SECS` comment
   (line ~340s region references "containers/sandboxes without inotify
   support" as the common case). Keep.
4. **No evidence found that `WATCHER_AUTOCLOSE_MODE=finalized` is
   unused/superseded** — it's the pre-#237 default behavior preserved as
   an explicit opt-in, still validated in the `case` statement, still
   documented in both the header and `--help` text, and both branches
   (`merged`/`finalized`) have distinct behavior in `pr_poll_pass` and
   `cleanup_eligible_workers`. Not a trim candidate; mentioned here only to
   record that it was checked and ruled out.

No dead flags, no orphaned env vars beyond item 1, and no superseded code
paths were found beyond what's listed above — this script's comment
density made "is this still reachable" verifiable by reading rather than
by speculation, which is itself worth noting as a reason extraction risk
is lower here than the raw line count suggests.

## 5. Proposed follow-up issue breakdown

Ordered for independent, mergeable, tracer-bullet PRs. Each depends only on
issues before it in this list.

1. **Add direct shape tests for `format_event_line` and the outbox
   wake path (`on_message`/`dispatch_message`/`msg_issue`/`WATCH_OUTBOX`).**
   Blast radius: new test file(s) only, zero production code changes.
   Test gate: new tests must pass; no existing gate to preserve. This is
   the prerequisite the risk ranking (§3) flags as missing before touching
   1.2 or 1.3 — do this first regardless of extraction order below.
2. **Extract `watch-lib-events.sh`** (`log_event`, `format_event_line`,
   `$EVENTS_LOG` convention). Blast radius: `coordinator-watch.sh` sources
   one new file at top; every other function's `log_event` calls are
   unchanged (same function name, now defined via `source`). Test gate:
   full existing suite (all watcher-touching tests) plus the new
   format_event_line tests from item 1 — this is the highest-leverage
   canary extraction since literally everything depends on it.
3. **Extract `watch-lib-compact-chrome.sh`** (`compact_last_pane_line`,
   `compact_composer_clear`, `compact_confirm_submitted`,
   `compact_replay_detected`, `compact_retract_queued`). Blast radius:
   sourced by both the coordinator- and worker-compact libs (items 4–5
   below, not yet extracted at this point — so for now this lib is sourced
   directly by `coordinator-watch.sh` alongside the still-inline
   `maybe_auto_compact`/`maybe_worker_compact`). Test gate:
   test-coordinator-auto-compact.sh + test-worker-auto-compact.sh (both
   exercise these functions transitively).
4. **Extract `watch-lib-reap.sh`** (§1.4/1.5: `cleanup_eligible_workers`,
   `mtime_epoch`, `worktree_birth_path`, `pr_predates_worktree`,
   `has_live_window`, `pr_poll_pass`, `pr_state_for_worktree`,
   `orphan_sweep_pass`). Blast radius: the one inline call from
   `pr_poll_pass` into `maybe_run_check` (still inline in
   `coordinator-watch.sh` at this point) must remain callable — source
   ordering means `watch-lib-reap.sh` is sourced before that call site is
   reached, which it already is (function calls resolve at call-time, not
   source-time, so this is a non-issue in bash — flagging so the extractor
   doesn't over-engineer an interface for it). Test gate:
   test-watcher-autoclose.sh + test-pr-predates-worktree.sh.
5. **Extract `watch-lib-checks.sh`** (§1.6, after adding the two extra
   test cases recommended in §3: PR-already-terminal-at-claim-time, and
   correct task_id disambiguation across multiple status files). Blast
   radius: called from `pr_poll_pass` (now in watch-lib-reap.sh) and
   `status_poll_pass` (still inline). Test gate: expanded test-shape-checks.sh.
6. **Extract `watch-lib-coord-compact.sh`** (§1.7, depends on item 3).
   Blast radius: `on_outcome`'s `maybe_auto_compact wake` call site and
   the standalone poll-loop launch statement (which stays top-level per
   §2's trap constraint) both just call into the now-sourced function.
   Test gate: test-coordinator-auto-compact.sh (verify the flock/subshell
   behavior specifically survives the move — see §3's concurrency-test
   caution).
7. **Extract `watch-lib-worker-compact.sh`** (§1.8, depends on item 3).
   Same shape as item 6, worker-side. Test gate: test-worker-auto-compact.sh.
8. **Extract `watch-lib-dispatch.sh`** (§1.3: `is_our_worktree`,
   `dispatch_outcome`, `dispatch_message`, `msg_issue`, `run_inotify`,
   `run_poll` — but leave `on_outcome`/`on_message` themselves in
   `coordinator-watch.sh`, since they're the integration root calling into
   every lib extracted above and moving them buys nothing further). Blast
   radius: the two backend adapters plus the dispatch filter, now calling
   `on_outcome`/`on_message` which remain in the main script. Test gate:
   full suite, since this is the last extraction and touches the hot path
   every event flows through — do not attempt this until items 1–7 are all
   merged and green, and only after the new outbox tests from item 1 are
   in place and passing against the pre-extraction code first (regression
   baseline).

Each item above is independently mergeable and independently revertable —
none blocks the others except by ordering (each genuinely needs the
previous lib(s) already extracted, per §2's dependency order), and skipping
any single item just leaves that cluster inline without blocking the rest.

## Doc drift (feeds #243)

- `docs/llm-swarm-runner-overview.md:495` cites `coordinator-watch.sh:1351-1367`
  as the check-on-done read path. That line range now falls inside the
  pane-echo `tail`/trap setup block (lines ~1340–1396), not check-on-done —
  the actual check-on-done functions are now at lines 1735–1999
  (`status_poll_pass` through `execute_check`). The citation predates
  significant growth in this file and needs updating to a range in that
  area, or better, a function-name reference instead of a line range (line
  citations into a 3,400-line, still-growing file are inherently fragile —
  worth flagging to whoever picks up #243 as a policy question, not just a
  one-line fix).
- `scripts/README.md`'s one-line description of `coordinator-watch.sh`
  ("Daemon that wakes the coordinator via `llm-start.sh` when a worker
  drops a new outcome JSON") describes only cluster 1.3's outcome path —
  accurate as far as it goes, but the same table gives no hint of the
  autoclose/check-on-done/auto-compact functionality that now makes up
  the majority of the file's line count. Not wrong, just incomplete;
  low-priority doc-drift note for #243, not a correctness issue.
- No other line-number or function-name citations into `coordinator-watch.sh`
  were found stale in the two docs checked (`scripts/README.md`,
  `docs/llm-swarm-runner-overview.md`) beyond the one above — the overview
  doc's env-var table and events-log description were spot-checked against
  the current header comment and match.
