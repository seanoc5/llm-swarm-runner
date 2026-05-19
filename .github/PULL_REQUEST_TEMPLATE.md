<!-- BLIND_MERGE_RISK: low|medium|high -->
**Blind-merge risk:** 🟢 low / 🟡 medium / 🔴 high — one-line rationale naming the riskiest aspect.

## Summary

What changed and why, in 1–3 sentences. Link the issue (`Closes #N`) if one exists.

## Test plan

- [ ] What you ran locally (commands, scripts) and the result
- [ ] What CI is expected to cover
- [ ] Any manual verification steps a reviewer should repeat

## Risk assessment

Pick a level above and replace the placeholder line. Rubric (matches the
worker blind-merge-risk convention in `.swarm-policy.md` / worker brief):

- 🟢 **low** — docs/comments/tests only, formatting, isolated single-file fix with new tests, dep bump with green CI.
- 🟡 **medium** — source changed in 1–3 files, CI green, no public-API/schema/auth changes.
- 🔴 **high** — schema/migration, auth/security, multi-file refactor, public-API change, CI red/skipped, or wants a second pair of eyes.

When in doubt, rate higher.
