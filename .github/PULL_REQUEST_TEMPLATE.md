<!--
  Source of truth for swarm-worker PR bodies. Workers read this file
  (per prompts/worker.md → "PR body skeleton") and use its section
  headings as the skeleton for `gh pr create`. If you change the section
  structure here, the change propagates to worker PRs automatically.

  The BLIND_MERGE_RISK HTML comment must stay at the top — the coordinator
  scrapes it from there to render risk inline in the swarm session output.
  The human-visible risk footer lives at the bottom (intentionally demoted
  so it doesn't dominate the PR body for non-swarm reviewers).
-->
<!-- BLIND_MERGE_RISK: low|medium|high -->

## Summary

What changed and why, in 1–3 sentences. Link the issue (`Closes #N`) if one exists.

## Test plan

- [ ] What you ran locally (commands, scripts) and the result
- [ ] What CI is expected to cover
- [ ] Any manual verification steps a reviewer should repeat

---

<sub>_Swarm metadata (safe to ignore if you're reviewing this as a human)._ **Blind-merge risk:** 🟢 low / 🟡 medium / 🔴 high — one-line rationale naming the riskiest aspect. Rubric: 🟢 docs/tests/single-file fix · 🟡 1–3 source files, CI green, no API/schema/auth · 🔴 schema, auth, multi-file refactor, public API, CI red, or wants a second pair of eyes. When in doubt, rate higher.</sub>
