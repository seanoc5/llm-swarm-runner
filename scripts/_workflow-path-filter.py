#!/usr/bin/env python3
"""_workflow-path-filter.py — decide whether a single GitHub Actions
workflow file's `pull_request` trigger would fire for a given set of
changed file paths (issue #639).

Not a full YAML parser (stdlib only, no PyYAML dependency) — a tolerant,
indentation-based line scanner over the narrow subset of workflow syntax
that `on:` / `pull_request:` / `paths:` / `paths-ignore:` actually use:
block mappings, block sequences ("- item"), and single-line flow lists
("[a, b]"). Good enough for real-world workflow files; anything it can't
confidently parse prints "unknown" rather than guessing, so a caller can
fail toward "this workflow still applies" (the safe direction: keep
waiting on CI) instead of silently warning-and-proceeding on a file it
misread.

Usage:
    _workflow-path-filter.py <workflow-yaml-file> <changed-files-file>

<changed-files-file> is one repo-relative path per line (blank lines
ignored). Prints exactly one line to stdout and exits 0:

    no-trigger   the workflow has no `pull_request` trigger at all
    triggers     it has a pull_request trigger with no path filter, or
                 with a filter that at least one changed file satisfies
    excluded     it has a path filter (paths-ignore, or paths) and NONE
                 of the changed files would satisfy it
    unknown      couldn't confidently parse the trigger or its filters

A non-zero exit (should only happen on a bad invocation, e.g. a missing
argument) must be treated by the caller the same as "unknown".
"""
import re
import sys

LIST_ITEM_RE = re.compile(r"^-\s*(.+)$")
KEY_RE = re.compile(r'^(?:["\']?(?P<key>[A-Za-z0-9_-]+)["\']?)\s*:(?P<rest>.*)$')


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
    return items


def path_to_regex(pattern):
    """GitHub Actions path-filter glob -> anchored regex. `**` matches
    anything including `/`; `*` and `?` stop at `/`, matching a single
    path segment's worth of characters."""
    out = ["^"]
    i, n = 0, len(pattern)
    while i < n:
        c = pattern[i]
        if pattern[i : i + 2] == "**":
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


def verdict(text, changed_files):
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
        # or "on: [push, pull_request]" — neither can carry a path filter.
        # ("pull_request" is a substring of "pull_request_target", so this
        # also catches that event correctly.)
        return "triggers" if "pull_request" in on_rest else "no-trigger"

    on_children = direct_children(lines, on_idx + 1, 0)
    on_entries = own_level_entries(on_children)
    # pull_request_target uses the identical paths/paths-ignore syntax and
    # is just as real a trigger for this PR as pull_request — a block-form
    # "pull_request_target:" key must not be read as "no-trigger".
    pr_entry = find_key(on_entries, "pull_request")
    if pr_entry is None:
        pr_entry = find_key(on_entries, "pull_request_target")
    if pr_entry is None:
        return "no-trigger"

    pr_rest, pr_children = pr_entry
    if pr_rest:
        # Inline value on the "pull_request:" line itself (e.g. "{}" or a
        # one-line flow map). Only a flow map could embed a paths filter,
        # and parsing nested flow maps isn't worth the complexity here —
        # fail toward "unknown" rather than assume unrestricted.
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


def main(argv):
    if len(argv) != 3:
        print("usage: _workflow-path-filter.py <workflow-yaml-file> <changed-files-file>", file=sys.stderr)
        return 2
    with open(argv[1], "r", encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    with open(argv[2], "r", encoding="utf-8", errors="replace") as fh:
        changed_files = [line.strip() for line in fh if line.strip()]

    try:
        result = verdict(text, changed_files)
    except Exception:  # noqa: BLE001 — a parse surprise must fail toward "unknown", never crash the CI gate
        result = "unknown"
    print(result)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
