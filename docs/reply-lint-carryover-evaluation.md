# Evaluation: the `carryover` reply-lint rule (issue #646)

What this measures: whether `lint-coordinator-reply.sh`'s `carryover` rule
catches "I referred to a carried-over item instead of restating it" (Cluster A
of `docs/research/issue-645-reporting-rules.md`) without blocking ordinary
replies. Same shape as `docs/grokkability-evaluation.md`: a known-bad fixture
plus a sample of replies that drew no recorded complaint. The run script
(`scripts/eval-carryover-lint.sh`) was removed in #1067; recover it from git history
(`git show a91e7c2:scripts/eval-carryover-lint.sh`).

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

Sample (rerun 2026-11-14 on master, final rule): all 2,327 assistant text replies
in the 198 local civicstrata coordinator sessions, dated 2026-08-01 to 2026-11-14,
leaving out 2026-10-15 (the one civicstrata complaint day the rule was tuned
against). Script: removed, see the note at the top; it was run with `--transcripts
~/.claude/projects/-opt-work-springboot-civicstrata --skip-dates 2026-10-15`.
The transcripts keep growing, so a later rerun will give different counts; the
numbers below are for that rerun only. "No complaint recorded" is not "was
good", so this is a flag-rate check, not a precision proof.

- **19 of 2,327 flagged (0.8%); 18 of 1,000 replies of 60+ words (1.8%).** At the
  Stop hook that is about one extra block per 55 long replies. Six of the 19 are
  the same C1/C2 digest line repeated across six wake-digest replies on 2026-11-13.
- By my reading of each flagged line (not Sean's judgment): **8 real, 11 false
  positive, so 42% precision (8 of 19).** The 8 real ones point at an item the
  reply never defines ("waits on your B1/B2", "your K1/K2 reply", "per your
  D1/D2", "Follow-ups A-D are waiting on ...", "your question 1: is option A
  county-only?", "per C1" in a PR line). The 11 false positives carry their own
  gloss: a heading that defines the option in parentheses ("option A, merge
  anyway"), "D1, the docs link (PR #622)", "A4, after the restart: run the FEMA
  import", and the six repeated "C1, covering the number, is my recommendation"
  lines (the label is defined by the heading line just above). Without the six
  repeats it is 8 real of 13 distinct hits (62%).
- This replaces an earlier reading of "about 20 real, about 4 false positive". That
  came from the replaced 24-hit rule on 2,136 replies that left out different days
  (2026-08-29, 09-22 and 10-15); it described the old rule, not the merged one.
- First version, before the gloss and colon-block allowances: 211 of 2,134 flagged
  (9.9%), mostly "A1 ..." lines that carried their own explanation. The 12-word
  threshold and the colon-block allowance were set by reading that sample, so the
  rates above are not held-out either.
- The data is civicstrata only; no other project's transcripts were checked. The
  transcripts were read locally and none of their text is committed beyond the
  short flagged-line fragments above.

## Known gaps

- A label defined in an earlier message reads as undefined (the rule sees one
  reply): that is the point, since the operator reads cold.
- A long line can carry an unexplained reference past the 12-word threshold.
- Nothing here can judge whether a gloss is a *good* explanation; a human or the
  grokkability cases still do that.
