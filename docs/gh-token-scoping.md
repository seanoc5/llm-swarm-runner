# Scoping the swarm's GitHub credential — findings and procedure

Issue #418. Companion script: [`scripts/gh-token-probe.sh`](../scripts/gh-token-probe.sh).

## What reaches a worker container today

Two credentials, not one:

| Credential | How it gets in | What it authorises | Reach |
|---|---|---|---|
| `gh` OAuth token (`gho_…`, scopes `gist read:org repo workflow`) | `sandbox.sh` runs `gh auth token` on the host, injects as `GH_TOKEN` | Every `gh` call: PR create/merge/comment/close, issue create/edit/close, run list, label create, GraphQL | **Every repo the account can reach** |
| SSH key `~/.ssh` (+ agent socket) | mounted read-only into the container | `git push` / `git fetch` — all remotes are `git@github.com:` | **Every repo the account can reach** |

This is the finding that changes the earlier framing: **scoping the `gh` token limits the API half only.** A worker could still `git push --force` to any branch of any repo via SSH. Halving the exposure is still worth doing, but it is a half.

## Repos the swarm actually works in (from `*-worktrees/` on this host)

seanoc5/llm-swarm-runner · seanoc5/fand-app · seanoc5/fand-etl · seanoc5/fand-guide · seanoc5/civicstrata · seanoc5/corpusminder-spring · seanoc5/SAMlytics

## Fine-grained PAT permissions the swarm's `gh` usage needs

Derived by grepping every `gh` call in `scripts/`, `sandbox.sh`, `llm-start.sh`, `prompts/`:

| Permission | Level | Needed by |
|---|---|---|
| Metadata | read | (always on) |
| Contents | **read + write** | `gh pr merge` (a merge is a write to the default branch), `gh pr diff` |
| Pull requests | **read + write** | `gh pr create/view/list/comment/edit/close/reopen/ready/checks/merge` — 38 `pr view` sites alone |
| Issues | **read + write** | `gh issue create/view/list/comment/edit/close`, `gh label create/list` |
| Actions | read | `gh run list`, `gh run watch`, `gh workflow list` (CI gate + claude-code-action routing) |
| Workflows | **not needed** | the classic `workflow` scope only governs pushing `.github/workflows/*` over HTTPS; the swarm pushes over SSH |
| Gist, Org, Projects, Discussions | none | never used |

Repository access: **Only select repositories** → the seven above. Expiry: pick 90 days and put the renewal date somewhere you'll see it — a lapsed token makes every worker die at `gh pr create` with a 401, which the swarm reports as a task failure, not an auth failure.

## The one thing the probe exists to answer

`gh pr view` / `gh pr list` / `review-scoreboard.sh` use **GraphQL** under the hood. Fine-grained PATs did not support GraphQL at launch and gained it later; `gh`'s own fine-grained support has had gaps. If GraphQL fails, ~80% of the swarm's `gh` surface fails with it. The probe's `gh api graphql` line is the single most important check. Baseline with the current OAuth token: 15/15 pass.

## Procedure (nothing below is done yet — each step is yours)

1. **Create the token** (browser, ~3 min): https://github.com/settings/personal-access-tokens/new → "Only select repositories" → the seven → permissions per the table → generate → copy once.

2. **Create a throwaway repo** for write probes, e.g. `seanoc5/swarm-token-probe` (private, empty README). Open one PR on it from any branch so `PROBE_PR` has a target.

3. **Probe, read-only first:**
   ```bash
   PROBE_TOKEN='github_pat_…' scripts/gh-token-probe.sh
   ```
   Anything red here means a permission is missing or `gh`+fine-grained has a gap. Fix the token; re-run. Do not proceed on red.

4. **Probe writes, against the throwaway only:**
   ```bash
   PROBE_TOKEN='github_pat_…' PROBE_WRITE=1 PROBE_REPO=seanoc5/swarm-token-probe PROBE_PR=1 scripts/gh-token-probe.sh
   PROBE_TOKEN='github_pat_…' PROBE_WRITE=1 PROBE_REPO=seanoc5/swarm-token-probe PROBE_PR=1 PROBE_MERGE=1 scripts/gh-token-probe.sh   # last: actually merges
   ```
   The script refuses to run write ops against any of the seven real repos.

5. **Swap — one project at a time, nothing on the host changes.** Do NOT `gh auth login --with-token` on the host; that replaces the credential your own shell uses too. Instead add one line to the project's env file:
   ```bash
   echo 'GH_TOKEN=github_pat_…' >> /opt/work/oconeco/fand-app/.sandbox-env
   ```
   `.sandbox-env` is per-project, gitignored, symlinked into every worktree by `provision-worker.sh`, and read by Docker as a *file* (`--env-file`) — the token never appears in any argv. When that line is present `sandbox.sh` skips the host-token injection (otherwise its `-e GH_TOKEN` would outrank the env-file value and silently hand the worker the broad credential anyway); the session header prints `GH token: .sandbox-env` so you can see which credential a worker got. Takes effect on the next worker spawn. Roll back by deleting the line.

   Host-side scripts — the coordinator, `coordinator-watch.sh`, `kill-finished-workers.sh` — keep using your login. Only the agents running arbitrary code have their reach reduced.

6. **Watch the first worker** on the swapped swarm through one full PR cycle: create, marker comment, `gh pr checks`, merge. Then the next swarm.

7. **Revoke nothing yet.** The `gho_` OAuth grant is also your interactive `gh`. Leave it.

## What this does not fix, and what would

The SSH key. Options, in increasing cost:
- **Per-repo deploy keys with write access** — seven keys, one per repo, mounted instead of `~/.ssh`. Removes cross-repo push entirely. Cost: key management × 7, and `sandbox.sh` needs to mount a swarm-specific `~/.ssh` with a matching `config` (`Host github.com-fand-app` aliases) — the remotes would have to change per worktree. Medium plumbing.
- **Machine account** with its own SSH key and its own fine-grained PAT — the parked option (issue #403 "known limits"). Fixes both halves at once, and gives PR-author separation as a side effect. Highest cost, cleanest result.

Verdict: do steps 1–6 for the token (low cost, halves the exposure, reversible in one env var). Leave the SSH half until there is a concrete reason to spend on it; if that reason arrives, go straight to the machine account rather than deploy keys — deploy keys cost nearly as much and fix less.
