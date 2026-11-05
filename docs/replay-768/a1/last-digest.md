## Run digest — 2026-11-05T21:42Z (woke for: outcome, issue 1767)
This was a replay run: `gh` writes, both reviews and the worker start were recorded, not performed.

**A. Needs you (ranked by risk × age):**
- **A1** 🟡 PR #1912 — "Adds the \"do we match John?\" check against his pinned published values." Rule on the coarse Resource-wealth and Net Worth rows, because the body and the coordinator's comment disagree; recommend keeping them coarse until the first minti9 run (medium confidence). No CI result is visible on cc43e20. Merge before #1911 (V264 is below V265/V266). `merge PR 1912` in the conversation session. Default if silent: stays open. https://github.com/seanoc5/fand-app/pull/1912
- **A2** 🟡 PR #1912 Decide item — map ADR 0022 rows 2, 3, 7, 9 to natural-capital differences? Recommend deciding after the first real run (high confidence). Default if silent: they stay out of the register. https://github.com/seanoc5/fand-app/pull/1912
- **A3** Backlog nearly empty of dispatchable work; name an epic to carve (#1718 or #779, low confidence, titles only). Default if silent: slots go idle.
- **A4** #1611 — is your mapping done? #1602 is no longer open. Default if silent: stays blocked.

**What surprised me:**
- PR #1911 had lost its hold banner, and its body has no round 4 entry. The banner is restored and a marked hold comment posted (recorded).
- PR #1912 stayed a draft after its hold was lifted at 07:19, so I ran the missing `gh pr ready` (recorded).
- Neither PR's hold comments carry the machine markers, so `pr-ready.sh` could not have seen the earlier holds.
- The open-PR migration check failed (exit 5, jq error) and the default-branch check found no migrations (exit 4), so the V264/V265 ordering comes from the PR bodies only.
- PR diffs and most issue bodies were unavailable, so #1857 was dispatched on its title and labels alone, and I could not rule out duplicates among closed issues for the 4 follow-ups.

**Moved since last run:** first run, no previous digest.
- iss-1767 finished round 4 (head 7a13316); PR #1911 still held. Both reviews requested (default model and Opus); no verdict, because the reviews did not run. C1 (row locking) matches the commit title only; C2 (test cleanup) is unconfirmed.
- Filed 4 follow-ups, labeled `blocked` until their parent PR merges: carried rows lose estimate marks; seed comment overclaims (from #1911); narrow the coarse register rows; admin nav link (from #1912).
- Not filed from #1911: granting John the Publisher role (operator step, already in its Your move) and the S3 slice (already #1768).
- #1768 labeled `blocked` on #1767. #1857 dispatched to the one open slot.

**In flight:** iss-1767 (round 4 pushed, outcome ok), iss-1722 (last commit cc43e20), iss-1857 (start recorded only). check-stuck-workers shows both existing windows without containers; pane state unknown.
**Backlog:** OPEN=27 AVAILABLE=1 before dispatch, 0 after. ALIVE=2/3 (3/3 if the #1857 start were real) WINDOWS=4/10. ROADMAP absent. No operator notes, no `.swarm-policy.md`. 🟢 automerge on, no 🟢 PR open; 🟡 automerge off.
