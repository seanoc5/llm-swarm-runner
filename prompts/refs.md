# Reference Docs Index

Docs under `$LLM_SWARM_DOCS/` (read-only bind mount; the matching host path
works too). When a trigger below fires, read the whole doc before acting — it
is more authoritative than model memory, especially for exact command forms.
Project policy and the active brief win over these general references. If a
doc doesn't cover your case, note the gap in your `## Summary` so the index
can grow.

| When you encounter… | Read |
|---|---|
| A git merge conflict, rebase decision, lost-commit recovery, or any non-trivial git/`gh` operation you're unsure about | `$LLM_SWARM_DOCS/VCS/git-github.md` |
