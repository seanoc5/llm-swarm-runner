# Reference Docs Index

*This doc is read by a worker or coordinator agent mid-task who needs to
find the right deep-dive reference doc before a non-trivial git/`gh`
operation.*

Docs under `$LLM_SWARM_DOCS/` (read-only bind mount; the matching host path
works too). When a trigger below fires, read the whole doc before acting — it
is more authoritative than model memory, especially for exact command forms.
Project policy and the active brief win over these general references. If a
doc doesn't cover your case, note the gap in a `## Note` block (worker.md
§ "Surface, don't bury") so the index can grow.

| When you encounter… | Read |
|---|---|
| A git merge conflict, rebase decision, lost-commit recovery, or any non-trivial git/`gh` operation you're unsure about | `$LLM_SWARM_DOCS/VCS/git-github.md` |
