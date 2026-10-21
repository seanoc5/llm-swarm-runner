#!/usr/bin/env python3
"""_workflow-path-filter.py — decide whether a single GitHub Actions
workflow file's trigger would create a run attached to a given PR's head
commit, for a given set of changed file paths (issue #639, #644 follow-up
"no-trigger must not mean no CI coming").

Not a full YAML parser (stdlib only, no PyYAML dependency) — a tolerant,
indentation-based line scanner over the narrow subset of workflow syntax
that `on:` / `pull_request:` / `push:` / `paths:` / `paths-ignore:` /
`branches:` / `branches-ignore:` actually use: block mappings, block
sequences ("- item"), and single-line flow lists ("[a, b]"). Good enough
for real-world workflow files; anything it can't confidently parse prints
"unknown" rather than guessing, so a caller can fail toward "this workflow
still applies" (the safe direction: keep waiting on CI) instead of silently
warning-and-proceeding on a file it misread.

Usage:
    _workflow-path-filter.py <workflow-yaml-file> <changed-files-file> <head-branch>

<head-branch> is the PR's own head branch name (`head.ref`, not a glob —
one literal branch name). It is used ONLY to evaluate a `push` trigger's
`branches`/`branches-ignore` filter (issue #644 round-4): GitHub applies a
`push` workflow's `paths`/`paths-ignore` to THAT PUSH'S OWN diff, which
this scanner has no way to know (it only ever sees the PR's changed-file
list, from `pulls/<pr>/files`) — so a push trigger's path filter is never
read at all, in either direction. Its branch filter, by contrast, really
does decide whether a push event can fire for this branch name, so that
part IS evaluated, against <head-branch>. A push trigger whose branch
filter excludes <head-branch> can never attach a run to this PR's head, no
matter what its push diff contains — that is reported as "no-trigger" for
that trigger, never "excluded" (which this scanner reserves for a
confident PATH-filter exclusion on pull_request/pull_request_target).

<changed-files-file> is one repo-relative path per line (blank lines
ignored), and is used only for pull_request/pull_request_target path
filters, never for push. Prints exactly one line to stdout and exits 0:

    no-trigger   the workflow has none of pull_request, pull_request_target,
                 push or workflow_run — nothing that attaches a run to this
                 PR's head commit (a schedule/workflow_dispatch/release-only
                 workflow, say) — OR it has only push trigger(s), and every
                 one's branch filter rules out this PR's own head branch
                 (issue #644 round-4): legitimate (no push run can ever
                 attach), but NOT by itself evidence of a confident
                 exclusion the way "excluded" below is
    triggers     it has a pull_request/pull_request_target trigger with no
                 path filter, or with a filter that at least one changed
                 file satisfies; OR a push trigger whose branch filter (if
                 any) allows this PR's head branch — a push trigger's own
                 path filter is NEVER evaluated (see <head-branch> above)
    excluded     every pull_request/pull_request_target trigger present
                 confidently path-filters out all of <changed-files-file>
                 (paths-ignore, or paths), AND no push trigger's branch
                 filter allows this PR's head branch to fire one instead
    unknown      couldn't confidently parse a trigger or its filters, or
                 the workflow has a workflow_run trigger (its path filter,
                 if any, isn't evaluated by this scanner at all, and
                 whether it attaches to the PR's head SHA depends on the
                 job's own code — never guess, always fail toward "still
                 relevant")

A same-repo PR's branch push fires `push`-triggered workflows too, and
those runs land on the exact head SHA a caller's `gh pr checks` reads —
a bare `on: push` workflow with no branch filter is therefore just as
real a source of CI as `pull_request` and must never be read as
"no-trigger" (that was issue #644's third follow-up: a push-only workflow
fell through a caller's no-trigger handling straight to "excluded",
silently readying any PR, source changes included, in a push-only repo).

issue #644 round-4: a `push` trigger's branch filter CAN rule it out for a
given PR, though — if `branches`/`branches-ignore` means this event can
never fire for the PR's own head branch, no push run will EVER attach to
that PR's head commit, full stop. That is reported the same way as a
workflow with no relevant trigger at all ("no-trigger" for that trigger),
which is evidence of absence only when paired with another trigger
(typically `pull_request`) that independently confirms a confident path
exclusion — see `_path_filtered_trigger_verdict`'s and this scanner's
overall `verdict()` docstring below for how the two combine.

A non-zero exit (should only happen on a bad invocation, e.g. a missing
argument) must be treated by the caller the same as "unknown".
"""
import re
import sys

LIST_ITEM_RE = re.compile(r"^-\s*(.+)$")
KEY_RE = re.compile(r'^(?:["\']?(?P<key>[A-Za-z0-9_-]+)["\']?)\s*:(?P<rest>.*)$')
UNSUPPORTED_GLOB_RE = re.compile(r"[\[\]+{}]")


def strip_comment(line):
    """Drop a trailing `# comment` that isn't inside a quoted string (e.g.
    `on:  # ci` or `- 'a#b'`). A naive `split('#')[0]` would also cut
    inside a quoted pattern, so this tracks quote state char by char."""
    quote = None
    for i, c in enumerate(line):
        if quote:
            if c == quote:
                quote = None
        elif c in ("'", '"'):
            quote = c
        elif c == "#" and (i == 0 or line[i - 1].isspace()):
            return line[:i]
    return line


def parse_lines(text):
    """[(indent, stripped_content), ...] — blanks and comments (full-line
    or trailing) dropped; indentation is measured in leading spaces (tabs
    unsupported, same as every real workflow file)."""
    out = []
    for raw in text.splitlines():
        indent = len(raw) - len(raw.lstrip(" "))
        stripped = strip_comment(raw).strip()
        if not stripped:
            continue
        out.append((indent, stripped))
    return out


def direct_children(lines, start_idx, parent_indent):
    """Contiguous run of lines after start_idx with indent > parent_indent."""
    children = []
    i = start_idx
    while i < len(lines) and lines[i][0] > parent_indent:
        children.append(lines[i])
        i += 1
    return children


def own_level_entries(block):
    """Given a children block (as from direct_children), split it into the
    block's own direct keys: [(indent, content, nested_children), ...].
    `nested_children` is that key's own deeper-indented lines, recursively
    usable with the same function."""
    if not block:
        return []
    own_indent = block[0][0]
    entries = []
    i, n = 0, len(block)
    while i < n:
        indent, content = block[i]
        if indent != own_indent:
            # Malformed/unexpected indentation under this block; skip the
            # stray line rather than misparsing it as a sibling.
            i += 1
            continue
        j = i + 1
        nested = []
        while j < n and block[j][0] > own_indent:
            nested.append(block[j])
            j += 1
        entries.append((indent, content, nested))
        i = j
    return entries


def find_key(entries, key):
    """First (rest-after-colon, nested_children) among entries whose key
    matches, or None."""
    for _indent, content, nested in entries:
        m = KEY_RE.match(content)
        if m and m.group("key") == key:
            return m.group("rest").strip(), nested
    return None


def extract_list(inline, nested):
    """A YAML sequence given either as an inline flow list on the key's own
    line ("paths: ['a', 'b']") or as a block list of "- item" lines below
    it. Returns a list of strings, or None if neither form is recognized
    (caller treats that as unknown, not as an empty list)."""
    inline = inline.strip()
    if inline.startswith("["):
        if not inline.endswith("]"):
            return None  # multi-line flow list — not worth guessing at
        inner = inline[1:-1]
        items = [p.strip().strip("'\"") for p in inner.split(",")]
        items = [p for p in items if p]
    elif inline in ("", "~", "null"):
        items = []
        for _indent, content in nested:
            m = LIST_ITEM_RE.match(content)
            if not m:
                return None  # something other than a plain list item
            items.append(m.group(1).strip().strip("'\""))
    else:
        # A bare scalar directly after "paths:" (no list at all) is not
        # valid GitHub Actions syntax for this key — don't guess.
        return None
    if any(p.startswith("!") for p in items):
        # A `!pattern` negation re-includes files the earlier patterns
        # excluded — order-sensitive semantics this matcher doesn't
        # implement. Don't guess at a result that could be wrong in the
        # unsafe direction (claiming "excluded" for a file GitHub would
        # actually run CI on).
        return None
    if any(UNSUPPORTED_GLOB_RE.search(p) for p in items):
        # `[...]` char classes, `+` (one-or-more-of-preceding) and `{}`
        # brace expansion are all valid GitHub Actions path-filter glob
        # syntax that path_to_regex below doesn't implement — fail toward
        # unknown rather than matching them as literal characters.
        return None
    return items


def path_to_regex(pattern):
    """GitHub Actions path-filter glob -> anchored regex. `*` and `?` stop
    at `/`, matching a single path segment's worth of characters. `**`
    matches anything including `/` — and, in the `**/` or `/**` idiom,
    the adjacent `/` is part of that match too, so it can also match
    *zero* directories (`src/**/*.py` matches `src/main.py`, `**/*.py`
    matches a root-level `setup.py`, `docs/**` matches `docs` itself) —
    not just one-or-more, which `.*/` or `/.*` alone would require."""
    out = ["^"]
    i, n = 0, len(pattern)
    while i < n:
        c = pattern[i]
        if pattern[i : i + 3] == "**/":
            out.append("(?:.*/)?")
            i += 3
        elif pattern[i : i + 3] == "/**" and i + 3 == n:
            out.append("(?:/.*)?")
            i += 3
        elif pattern[i : i + 2] == "**":
            out.append(".*")
            i += 2
        elif c == "*":
            out.append("[^/]*")
            i += 1
        elif c == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(c))
            i += 1
    out.append("$")
    return "".join(out)


def matches_any(path, patterns):
    return any(re.match(path_to_regex(p), path) for p in patterns)


# All three use identical paths/paths-ignore syntax and are equally real
# sources of a run attached to this PR's head commit (push does, for a
# same-repo PR branch, exactly what pull_request does) — a workflow that
# defines more than one of these, filtered or not, must be read as
# relevant if ANY of them is (GitHub runs each independently).
PATH_FILTERED_TRIGGER_KEYS = ("pull_request", "pull_request_target", "push")

# Triggers this scanner makes no attempt to evaluate path filters for, but
# whose mere presence can still attach a run to a commit (workflow_run's
# job can check out and report status against github.event.workflow_run.
# head_sha, including a PR's head, depending on the job's own code — not
# something a static path-filter read can rule out). Presence must fail
# toward "unknown", never silently toward "no-trigger".
OTHER_RUN_TRIGGER_KEYS = ("workflow_run",)


def _path_filtered_trigger_verdict(pr_rest, pr_children, changed_files):
    """Verdict for a single already-found pull_request(_target) entry."""
    if pr_rest:
        # Inline value on the key's own line (e.g. "{}" or a one-line flow
        # map). Only a flow map could embed a paths filter, and parsing
        # nested flow maps isn't worth the complexity here — fail toward
        # "unknown" rather than assume unrestricted.
        return "unknown" if "paths" in pr_rest else "triggers"

    pr_entries = own_level_entries(pr_children)
    paths = find_key(pr_entries, "paths")
    paths_ignore = find_key(pr_entries, "paths-ignore")

    if paths is None and paths_ignore is None:
        return "triggers"  # no filter at all -> always runs

    if paths is not None:
        rest, nested = paths
        patterns = extract_list(rest, nested)
        if patterns is None:
            return "unknown"
        if not patterns:
            return "triggers"
        return "triggers" if any(matches_any(f, patterns) for f in changed_files) else "excluded"

    rest, nested = paths_ignore
    patterns = extract_list(rest, nested)
    if patterns is None:
        return "unknown"
    if not patterns:
        return "triggers"
    return "excluded" if all(matches_any(f, patterns) for f in changed_files) else "triggers"


def _push_trigger_verdict(push_rest, push_children, head_branch):
    """Verdict for a single already-found `push` entry — branch filter
    only, never path filter (issue #644 round-4: a push's `paths`/
    `paths-ignore` apply to THAT PUSH'S OWN diff, which this scanner never
    sees — only the PR's changed-file list — so reading them at all could
    produce a confident-looking "excluded" that's actually just wrong).
    Returns "triggers" (this branch can fire the event, unconditionally,
    as far as this scanner can tell), "no-trigger" (a branch filter rules
    <head_branch> out — legitimate: no push run can ever attach to this
    PR's head commit), or "unknown" (couldn't confidently parse the
    filter). Never "excluded" — that verdict is reserved for a confident
    PATH-filter exclusion, which a push trigger can never produce here."""
    if push_rest:
        # Inline value (e.g. "{}" or a one-line flow map). Only a flow map
        # could embed a branches filter — fail toward "unknown" rather than
        # assume unrestricted.
        return "unknown" if "branches" in push_rest else "triggers"

    push_entries = own_level_entries(push_children)
    branches = find_key(push_entries, "branches")
    branches_ignore = find_key(push_entries, "branches-ignore")

    if branches is None and branches_ignore is None:
        return "triggers"  # no branch filter at all -> fires for any branch

    if branches is not None:
        rest, nested = branches
        patterns = extract_list(rest, nested)
        if patterns is None:
            return "unknown"
        if not patterns:
            return "triggers"
        return "triggers" if matches_any(head_branch, patterns) else "no-trigger"

    rest, nested = branches_ignore
    patterns = extract_list(rest, nested)
    if patterns is None:
        return "unknown"
    if not patterns:
        return "triggers"
    return "no-trigger" if matches_any(head_branch, patterns) else "triggers"


def verdict(text, changed_files, head_branch):
    """Overall verdict for the whole workflow file, aggregating every
    pull_request/pull_request_target/push trigger it defines (there can be
    more than one — GitHub evaluates each independently, so the workflow
    is relevant if ANY of them is):

    - any entry "triggers"           -> "triggers"
    - else any entry "unknown"       -> "unknown"
    - else all entries "no-trigger"  -> "no-trigger" (nothing here
      confirms a real exclusion — e.g. a lone push trigger whose branch
      filter just doesn't match this PR's head branch)
    - else (at least one "excluded", rest "excluded"/"no-trigger")
                                      -> "excluded" (issue #644 round-4:
      only pull_request/pull_request_target can ever contribute
      "excluded" — see _push_trigger_verdict — so this case always has
      real path-filter evidence behind it, even when a sibling push
      entry contributed only "no-trigger")
    """
    lines = parse_lines(text)

    on_rest = None
    on_idx = None
    for idx, (indent, content) in enumerate(lines):
        if indent == 0:
            m = KEY_RE.match(content)
            if m and m.group("key") == "on":
                on_rest, on_idx = m.group("rest").strip(), idx
                break
    if on_idx is None:
        return "unknown"  # not a recognizable workflow file at all

    if on_rest:
        # Flow/scalar form on the "on:" line itself, e.g. "on: pull_request"
        # or "on: [push, pull_request]" — none of these forms can carry a
        # path filter. ("pull_request" is a substring of
        # "pull_request_target", so this also catches that event
        # correctly.)
        if "pull_request" in on_rest or "push" in on_rest:
            return "triggers"
        if any(key in on_rest for key in OTHER_RUN_TRIGGER_KEYS):
            return "unknown"
        return "no-trigger"

    on_children = direct_children(lines, on_idx + 1, 0)
    on_entries = own_level_entries(on_children)

    # Evaluate every pull_request(_target)/push trigger the workflow
    # defines (not just the first one found) — the workflow is relevant if
    # ANY of them would fire. `push` is dispatched to its own branch-filter
    # verdict function (issue #644 round-4); it can never contribute
    # "excluded" to this list.
    verdicts = []
    for key in PATH_FILTERED_TRIGGER_KEYS:
        entry = find_key(on_entries, key)
        if entry is None:
            continue
        pr_rest, pr_children = entry
        if key == "push":
            verdicts.append(_push_trigger_verdict(pr_rest, pr_children, head_branch))
        else:
            verdicts.append(_path_filtered_trigger_verdict(pr_rest, pr_children, changed_files))

    if not verdicts:
        for key in OTHER_RUN_TRIGGER_KEYS:
            if find_key(on_entries, key) is not None:
                return "unknown"
        return "no-trigger"
    if "triggers" in verdicts:
        return "triggers"
    if "unknown" in verdicts:
        return "unknown"
    if all(v == "no-trigger" for v in verdicts):
        return "no-trigger"
    return "excluded"  # at least one confident path-filter exclusion, nothing contradicts it


def main(argv):
    if len(argv) != 4:
        print("usage: _workflow-path-filter.py <workflow-yaml-file> <changed-files-file> <head-branch>", file=sys.stderr)
        return 2
    with open(argv[1], "r", encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    with open(argv[2], "r", encoding="utf-8", errors="replace") as fh:
        changed_files = [line.strip() for line in fh if line.strip()]
    head_branch = argv[3]

    try:
        result = verdict(text, changed_files, head_branch)
    except Exception:  # noqa: BLE001 — a parse surprise must fail toward "unknown", never crash the CI gate
        result = "unknown"
    print(result)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
