# Security Policy

`llm-swarm-runner` is a sandbox/experimental project for running autonomous coding agents on a developer workstation. There is **no formal SLA, no guaranteed response time, and no coordinated-disclosure process**.

For the full threat model — including the trusted-but-fallible agent assumption, container boundaries, and known risks (`--network host`, `~/.claude` rw, Docker-out-of-Docker, etc.) — see [`docs/security.md`](docs/security.md).

To report a vulnerability or security concern, email **seanoc5@gmail.com**. Best-effort response; please don't rely on this for anything load-bearing.
