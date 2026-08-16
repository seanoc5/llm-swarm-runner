# Announcement drafts — August 2026 feedback ask

Two pieces: YouTube description and the substack post (Nate's Newsletter
community, or similar). Tiered CTA per the 2026-08-13 planning session:
primary = value-vs-native, secondary = adoption friction; critique and
roadmap invited in the comment structure rather than the headline ask.

---

## YouTube description (draft)

**Title:** A self-healing Claude Code swarm: GitHub issues in, risk-rated PRs out

Claude Code has swarms built in now — so why does this project still exist?
This demo shows the layer native swarms don't cover: a durable queue that
lives in GitHub instead of a context window, workers that are full
multi-hour sessions in tmux + git worktrees, and human merge gates with
risk-rated PRs. The second half is a true story: the swarm's own busy
detection broke when Claude Code 2.1.x changed its TUI, and the swarm
diagnosed it from its event log, filed the issue, fixed itself, and
redeployed — across three different Claude sessions that shared no memory.

Honest caveats included (TUI scraping is brittle; native is simpler for
single-session work). I want real feedback, not applause — see the pinned
comment.

Repo: https://github.com/seanoc5/llm-swarm-runner
Positioning ADR (including claims that did NOT survive scrutiny):
https://github.com/seanoc5/llm-swarm-runner/blob/master/docs/adr/0004-positioning-vs-native-claude-code-swarms.md

Chapters:
0:00 Why this exists when Claude Code has native swarms
0:45 Scripted core: issue → worker → risk-rated PR → merge
2:15 The incident: the swarm fixes the swarm
4:30 Honest cons + what feedback I'm asking for

**Pinned comment:** Two questions I'd genuinely value answers to:
(1) Knowing Claude Code has swarms built in, would you run this? Why or why
not? (2) If yes-ish — what would stop you from setting it up tonight?
Architecture attacks and "this feature would make it worth it" comments
equally welcome.

---

## Substack post (draft — Nate's Newsletter community or similar)

**Title:** I built a swarm layer on top of Claude Code before it had swarms.
Now it does. Tell me if mine still matters.

I've spent a few months building [llm-swarm-runner](https://github.com/seanoc5/llm-swarm-runner):
a local-first orchestrator that points Claude Code (or Gemini/Codex CLI) at
a GitHub backlog and runs a pool of workers in parallel — each in its own
git worktree and Docker sandbox, each visible live in tmux, each ending in
a PR with a machine-readable blind-merge risk rating that a human (me)
gates.

Claude Code now ships subagents, workflow orchestration, and cloud agents
natively. So before I sink more months in, I want adversarial feedback on
whether the layer I built still earns its keep. My current claim, made
honest by a written [ADR](https://github.com/seanoc5/llm-swarm-runner/blob/master/docs/adr/0004-positioning-vs-native-claude-code-swarms.md)
that also lists the claims that did NOT survive scrutiny:

**Native swarms are better inside a session. This is the layer above
sessions** — the backlog lives in GitHub, not a context window, so
everything can die mid-flight and resume; workers are full sessions that
run for days across multiple projects; integration is gated by risk-rated
PRs, not trust.

The demo (video: LINK) makes the case with an incident from last week:
Claude Code 2.1.x changed a TUI detail, silently breaking my watcher's
busy-detection, which caused spurious `/compact` injections into working
agents. The swarm's event log caught it, a session diagnosed it days after
the fact from artifacts alone, filed the issue with a verified root cause,
a worker shipped the fix, and six running swarms picked it up. That
end-to-end trace — and the fact that it's also an example of the
*brittleness* native approaches don't have — is exactly the trade I want
your read on.

Questions, in order of how much I'd value an answer (I'm a paying
subscriber here because this community actually engages — hoping that cuts
both ways):

1. Knowing Claude Code has swarms built in, would you run this? Why/why not?
2. What would stop you from setting it up tonight? (Docs, Docker, trust,
   anything — adoption friction is fixable, silence isn't.)
3. Attack the architecture: tmux pane-scraping, GitHub-issues-as-queue,
   risk-rated self-merge. Where does it fall over first?
4. What single feature would make this worth real money or real time to you?

MIT licensed, no monetization angle — I'm deciding where to spend my
building time.

---

## Venue notes (operator decisions, not in the post)

- Nate's Newsletter: Sean is checking what the venue actually offers
  subscribers (chat thread vs comment vs Notes) before posting — the draft
  above is deliberately venue-neutral so it works in any of the three.
  Subscriber standing may earn attention but keep the ask concrete and
  short — the four questions carry it.
- Secondary: r/ClaudeAI or Hacker News *after* the substack pass has
  hardened the framing — the feedback there is higher-volume, lower-signal.
