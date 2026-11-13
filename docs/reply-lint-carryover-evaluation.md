# Evaluation: the `carryover` reply-lint rule (issue #646)

What this measures: whether `lint-coordinator-reply.sh`'s `carryover` rule
catches "I referred to a carried-over item instead of restating it" (Cluster A
of `docs/research/issue-645-reporting-rules.md`) without blocking ordinary
replies. Same shape as `docs/grokkability-evaluation.md`: a known-bad fixture
plus a sample of replies that drew no recorded complaint. Re-run with
`scripts/eval-carryover-lint.sh --transcripts <claude project dir> --skip-dates <complaint days>`.

## The rule in one paragraph

Outside code fences, code spans and URLs, a line is flagged when it holds a
backward reference (a section pointer like "§4", a phrase like "from earlier",
"carried over", "as noted"; or a short label the reply never defines, used as a
reference: "your A2", "see B1", "per A3", a bare "B3" opening a line, "M1-M3",
"A–D", "option B", "your d)". A mid-sentence H2, p95, G1 or M1 is a tech name, not
a label) and there is too little explanation: fewer
than 12 other words on the line, counting the list a trailing colon introduces
("Needs you (carried over):" followed by restated items passes; the same line
with nothing under it fails). A label counts as defined when a line starts with
it or it is followed by ":", "(" or a dash. Threshold: `--gloss N`; `--why` prints which reference matched.
Where it runs: the coordinator Stop hook (`coord-hook.sh`) lints every reply
with all rules, so a hit blocks the reply once with the fix; `needs-you.sh add`
refuses an item with a bare reference; `scripts/checks/run.sh reply|needs-you`
reports it as the `carryover` check.

## Recall: the 13 known-bad rows (research doc section 2)

Fixture: `tests/fixtures/reply-lint/carryover-incidents.tsv`.

- **7 of 13 caught (54%).** Six by `carryover` (rows 3, 5, 9, 10, 11, 13) and
  one by the existing `backref` rule ("Run the command above", row 7).
- **6 of 13 cannot be caught by a line-level check**, and the fixture marks them
  `expect=miss`: a coined phrase ("the `?` keyboard-shortcuts overlay", row 12;
  "the X gap", row 2), an opener that assumes the last screen ("On #1378: the
  'no' is deliberate", row 4), a compressed decision ("widen, retype or wait",
  row 6), a bare `i) go` item (row 8), and jargon with no recorded text (row 1).
- Caveat: rows 1 and 2 have no verbatim reply text in the research doc (the doc
  records a description), and I tuned the rule while looking at these rows, so
  7/13 is a ceiling on unseen data, not a held-out score.

## False positives: civicstrata coordinator replies

Sample: all 2,239 assistant text replies in the 198 local civicstrata coordinator
sessions (2026-08-08 to 2026-11-12), leaving out the three days the research doc
records a complaint (2026-10-15 only in the round-3 re-run; the original run also left out 08-29 and 09-22). "No complaint recorded" is not
"was good", so this is a flag-rate check, not a precision proof.

- **Round 3 (labels need a reference cue): 12 of 2,239 flagged (0.5%); 11 of 960 replies of 60+ words (1.1%).** The previous rule gave 24 (1.1%; 22 of 960, 2.3%) on the same sample. At the
  Stop hook that is about one extra block per 90 long replies. The numbers below this line are the earlier 24-hit reading (2,136 replies).
- By my reading of each flagged line (not Sean's judgment): about 20 point at an
  item or label the same reply never defines ("waits on your B1/B2", "from my
  last reply", "follow-ups A–D"), so they are the failure the rule targets; about
  4 look self-explanatory (a heading that defines "option A" in parentheses,
  "D1, the docs link (PR #622)") and are false positives (0.2%).
- First version, before the gloss and colon-block allowances: 211 of 2,134 flagged
  (9.9%), mostly "A1 ..." lines that carried their own explanation. The 12-word
  threshold and the colon-block allowance were set by reading that sample, so the
  1.1% is not held-out either.
- The data is civicstrata only; no other project's transcripts were checked. The
  transcripts were read locally and none of their text is committed.

## Known gaps

- A label defined in an earlier message reads as undefined (the rule sees one
  reply): that is the point, since the operator reads cold.
- A long line can carry an unexplained reference past the 12-word threshold.
- Nothing here can judge whether a gloss is a *good* explanation; a human or the
  grokkability cases still do that.
