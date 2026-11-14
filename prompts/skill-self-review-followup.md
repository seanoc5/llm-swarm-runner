# Skill — Self-Review, Later Round (converging)

*This doc is appended to `skill-self-review.md` by `scripts/self-review-pr.sh`
only when the PR already has earlier review rounds. It is read by a fresh
Claude or Codex session that needs to say whether the author's fixes
resolved the earlier findings.*

This is **not the first review of this PR.** Below the PR body you also get
`PRIOR ROUNDS` (the verdicts and findings of earlier rounds) and, when it
could be fetched, `CHANGES SINCE LAST REVIEW` (the diff between the commit the
last round reviewed and the current head). The full diff is still included for
context.

Your verdict may only get stricter if there is **new evidence**. So:

1. **BLOCK only for** (a) a prior `BLOCK` finding that is still unresolved in
   the current diff — check each one against the current code, don't assume
   a commit message means it was fixed — or (b) a **new** BLOCK-level problem
   (wrong logic, broken invariant, data loss, security, contradicts the PR's
   stated intent) that the `CHANGES SINCE LAST REVIEW` introduced.
2. **Do not BLOCK on anything else**, including problems in code that was
   already in the diff at the last round and that earlier rounds did not flag.
   If you now notice such a problem, put it in the caveat line: you had the
   same diff last round, so it is not evidence that the author's fixes failed.
   **One exception:** a clear data-loss, security or destructive-migration
   problem may BLOCK even in code earlier rounds saw; say it is newly noticed.
3. **Minor items** (style, wording, small test gaps, register of the PR body)
   go in an `APPROVE_WITH_CAVEATS:` line, never a `BLOCK:`.
4. If every prior BLOCK is resolved and the new changes introduce no
   BLOCK-level problem, the verdict is `APPROVE` or `APPROVE_WITH_CAVEATS:`.

Name each prior BLOCK you checked and say "resolved" or "unresolved" in the
justification paragraph (the ~100-word budget in the main skill is raised to
~150 words for later rounds). The verdict line format is unchanged.
