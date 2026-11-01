#!/usr/bin/env bash
# Issue #660 (fix round, PR #685): llm-start.sh now keeps .env.example/.env
# defaults OUT of the tmux server's global env so a project's .swarm/.env can
# win. The flip side: a script that reads one of those keys but neither
# sources scripts/_load-env.sh nor receives the key through the tmux -e list
# (llm-start.sh) or provision-worker.sh's PASS_VARS silently falls back to its
# in-script default. This test catches the next such script by shape.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0; ok() { echo "PASS: $1"; }; bad() { echo "FAIL: $1"; fail=1; }

# Keys handed over explicitly: the llm-start.sh `for _v in` list (session -e),
# its named -e options, and provision-worker.sh PASS_VARS (worker windows).
passed_keys() {
  local r="$1"
  sed -n '/^    for _v in MAX_WORKERS/,/; do$/p' "$r/llm-start.sh" | tr -s ' \;' '\n\n\n\n' |
      grep -E '^[A-Z][A-Z0-9_]+$' | grep -vx 'for\|do\|in' || true
  grep -oE 'TMUX_ENV_OPTS\+=\(-e "[A-Z_]+=' "$r/llm-start.sh" | sed -E 's/.*"([A-Z_]+)=/\1/' || true
  sed -n '/^    PASS_VARS=(/,/^    )/p' "$r/scripts/provision-worker.sh" | tr ' ' '\n' |
      sed -E 's/=.*//' | grep -E '^[A-Z][A-Z0-9_]+$' || true
}

# Scripts that read keys without reloading, with the reason that is OK.
# "inherits": only ever runs as a child of a script that sources the loader.
# "worker": only runs in worker windows/containers, which get PASS_VARS.
declare -A ALLOW=(
  [scripts/coord-hook.sh]="inherits: hook child of coordinator-claude.sh, which sources the loader"
  [scripts/coord-inbox-wait.sh]="inherits: armed from inside the coordinator claude process"
  [scripts/dep-proxy.sh]="worker: started by sandbox.sh/provision-worker.sh (PASS_VARS)"
  [scripts/worker-listener.sh]="worker: runs via sandbox.sh listener; PASS_VARS carries its keys"
  [sandbox.sh]="worker: invoked by provision-worker.sh with PASS_VARS in its env"
  [entrypoint.sh]="worker: container entrypoint, env from sandbox.sh"
)
# These still get the .env.example key check; only the wider "defaulted read"
# scan is skipped for them.
declare -A TOOL_ONLY=()
# Standalone tools whose defaulted ${NAME:-x} reads are ad-hoc/test override
# knobs (CI_WAIT_*, PR_SCREEN_*, SELF_REVIEW_SCRIPT, ...), never set via a
# project's .swarm/.env. A NEW script reading a defaulted key lands here only
# by a deliberate edit; otherwise the scan fails and asks for a loader.
for _t in _compose-down-for-worktree _window-flags available-issues ci-wait daily-changelog \
          demo-driver demo-record-setup gh-token-probe lint-pr-screen nightly-full-tests \
          pr-ready ready-sweep self-review-pr setup statusline-with-context \
          swarm-idle-report task-done build-image check-stuck-workers demo-segments-pick \
          gh-status-bar install-tmux-binding run-all-tests worker-merge; do
  TOOL_ONLY[scripts/$_t.sh]="tool: standalone/test-override knobs, not project config"
done

# Names that are never project config: ambient shell/tool variables, or
# script-internal knobs that exist only for tests/overrides of sibling paths.
NOT_CONFIG=" HOME PATH PWD TMPDIR TMUX TMUX_PANE USER SHELL NO_COLOR COLORTERM XDG_RUNTIME_DIR SSH_AUTH_SOCK CLAUDE_PROJECT_DIR LLM_SWARM_DIR LLM_SWARM_DOCS "

# scan_root <root>: prints one "FAIL" line per script reading a config key
# without reloading or being passed it. Config keys = .env.example keys
# (active or commented) PLUS every uppercase name any script reads with a
# default (${NAME:-x}, ${NAME-x}, ${NAME:=x}) and does not assign itself, so a
# project-only key like COORDINATOR_ALLOW_BACKGROUND_TASKS is covered (#691).
scan_root() {
  local r="$1" f rel code k keys passed
  passed="$(passed_keys "$r")"
  local n; n="$(echo "$passed" | grep -c .)"
  [ "$n" -ge 20 ] || echo "FAIL: could not parse the pass lists (got $n: $(echo "$passed" | tr '\n' ' '))"
  local example
  example="$(grep -oE '^#?[[:space:]]*(export )?[A-Z][A-Z0-9_]+=' "$r/.env.example" |
      sed -E 's/^#?[[:space:]]*(export )?//; s/=$//' | sort -u)"
  for f in "$r"/scripts/*.sh "$r"/sandbox.sh "$r"/entrypoint.sh "$r"/llm-start.sh; do
    rel="${f#"$r"/}"
    [ "$rel" = scripts/_load-env.sh ] && continue   # the loader itself
    code="$(grep -vE '^[[:space:]]*#' "$f")"
    # Match the loader on a code line (a comment mention doesn't count).
    # Herestring, not a pipe: pipefail + grep -q's early exit gives SIGPIPE.
    grep -q '_load-env\.sh' <<<"$code" && continue
    [ -n "${ALLOW[$rel]:-}" ] && continue
    # Defaulted reads, minus names the script assigns itself (internal vars).
    keys="$( { echo "$example"
      [ -n "${TOOL_ONLY[$rel]:-}" ] || grep -oE '\$\{[A-Z][A-Z0-9_]{3,}(:-|:=|-)' <<<"$code" | sed -E 's/^\$\{//; s/(:-|:=|-)$//' |
        sort -u | while read -r k; do
          # Skip only true internals: `X=value` that doesn't read X itself.
          # `X="${X:-default}"` is the config-knob idiom and must be checked.
          grep -E "^[[:space:]]*(export |local |declare -?[a-zA-Z]* )?$k=" <<<"$code" |
              grep -qvE "\\$\\{$k(:-|:=|-)" || echo "$k"
        done
      } | sort -u)"
    for k in $keys; do
      [[ "$NOT_CONFIG" == *" $k "* ]] && continue
      echo "$passed" | grep -qx "$k" && continue
      if grep -qE "\\$\\{?$k([^A-Za-z0-9_]|\$)" <<<"$code"; then
        echo "FAIL: $rel reads $k but neither sources _load-env.sh nor gets it via llm-start -e / PASS_VARS"
      fi
    done
  done
}

# Guard: every TOOL_ONLY entry must still be needed. With the list emptied the
# scan must flag exactly the listed scripts; a surplus entry would hide a future
# project-only key from the wider scan.
_saved=("${!TOOL_ONLY[@]}"); TOOL_ONLY=()
flagged="$(scan_root "$ROOT" | sed -nE 's/^FAIL: (\S+) reads .*/\1/p' | sort -u)"
for _s in "${_saved[@]}"; do TOOL_ONLY[$_s]=x; done
surplus="$(comm -13 <(echo "$flagged") <(printf '%s\n' "${_saved[@]}" | sort -u))"
if [ -z "$surplus" ]; then ok "every TOOL_ONLY entry (${#_saved[@]}) trips the wider scan"; else bad "surplus TOOL_ONLY entries: $(echo $surplus)"; fi

out="$(scan_root "$ROOT")"
if [ -n "$out" ]; then echo "$out"; fail=1; else ok "every key-reading script reloads or is passed its keys"; fi

# Mutation check: strip the loader from a wrapper in a scratch copy and the
# scan must flag it (proves the scan can actually fail).
M="$(mktemp -d)"; trap 'rm -rf "$M"' EXIT
mkdir -p "$M/scripts"; cp "$ROOT/llm-start.sh" "$ROOT/sandbox.sh" "$ROOT/entrypoint.sh" "$ROOT/.env.example" "$M/"
cp "$ROOT"/scripts/*.sh "$M/scripts/"
for w in coordinator-claude coordinator-gemini; do
  cp "$ROOT/scripts/$w.sh" "$M/scripts/$w.sh"
  sed -i '/_load-env\.sh/d' "$M/scripts/$w.sh"
  mout="$(scan_root "$M")"
  if grep -q "scripts/$w.sh" <<<"$mout"; then ok "scan flags $w.sh without the loader"
  else bad "scan did not flag $w.sh after removing its loader"; fi
  cp "$ROOT/scripts/$w.sh" "$M/scripts/$w.sh"
done

# Behavioural check: the gemini coordinator launch must see a key that exists
# only in the project's .swarm/.env (bare env, stub gemini records it).
mkdir -p "$M/proj/.swarm" "$M/gbin"
echo 'COORDINATOR_VERBOSE=0' > "$M/proj/.swarm/.env"
printf '#!/bin/sh\necho "$*" > "%s/gemini.args"\n' "$M" > "$M/gbin/gemini"; chmod +x "$M/gbin/gemini"
echo SYS > "$M/sys.md"; echo REQ > "$M/req.md"
(cd "$M/proj" && env -i PATH="$M/gbin:$PATH" HOME="$M" LLM_SWARM_DIR="$ROOT" COORD_MODEL=m1 \
    bash "$ROOT/scripts/coordinator-gemini.sh" "$M/sys.md" "$M/req.md") >/dev/null 2>&1 || true
grep -q -- '-m m1 --yolo --skip-trust -p REQ' "$M/gemini.args" 2>/dev/null \
    && ok "gemini coordinator honors project-only COORDINATOR_VERBOSE=0 (-p)" \
    || bad "gemini coordinator ignored project .swarm/.env (args: $(cat "$M/gemini.args" 2>/dev/null))"
[ ! -e "$M/req.md" ] && ok "gemini wrapper removes its request file" || bad "request file left behind"

# Behavioural check: stale-pr-nudges.sh in a bare env (no tmux-inherited
# defaults) must honor the project's .swarm/.env. Threshold 0 = exit before
# calling gh; the old fallback of 6 would call the stub gh.
T="$(mktemp -d)"; trap 'rm -rf "$T" "$M"' EXIT
mkdir -p "$T/proj/.swarm" "$T/bin"
echo 'STALE_PR_NUDGE_HOURS=0' > "$T/proj/.swarm/.env"
printf '#!/bin/sh\ntouch "%s/gh-called"\necho []\n' "$T" > "$T/bin/gh"; chmod +x "$T/bin/gh"
(cd "$T/proj" && env -i PATH="$T/bin:$PATH" HOME="$T" LLM_SWARM_DIR="$ROOT" bash "$ROOT/scripts/stale-pr-nudges.sh") >/dev/null 2>&1 || true
[ ! -e "$T/gh-called" ] && ok "stale-pr-nudges honors project STALE_PR_NUDGE_HOURS" \
    || bad "stale-pr-nudges ignored project STALE_PR_NUDGE_HOURS=0 (gh was called)"
exit $fail
