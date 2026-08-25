#!/usr/bin/env python3
"""Pin a chart's own image tags to the versions that were just released.

Usage:
    chart-image-bump.py VALUES_FILE KEY_TEMPLATE RELEASES_JSON IMAGES_JSON

  VALUES_FILE   Helm values file to edit in place.
  KEY_TEMPLATE  Dotted path with a {name} placeholder, e.g. images.{name}.tag
  RELEASES_JSON release-please's per-path map, i.e. the `releases` output of
                semantic-release.yml: {"images/postfix": {"version": "1.6.7"}}
  IMAGES_JSON   Render-time map component path -> image names:
                {"images/postfix": ["serverkraken/mailstack/postfix"]}

Only components present in RELEASES_JSON are touched, so a component that did
not release in this run keeps its pin.

Why not `yq`: it reformats. On mailstack's heavily commented values.yaml a
single tag change came out as 84 diff lines — blank lines dropped, inline
comments re-aligned. A release that rewrites the chart must produce a diff a
human can read, so this edits exactly the one line that holds the value and
leaves every byte around it alone.
"""
import json
import re
import sys


def _matching_lines(lines, want):
    """Indices of the lines that hold the scalar at the dotted path `want`."""
    hits = []
    depth, indent_of = 0, [-1]
    # Indent at which the keys of the current level live. Without it, the
    # children of a NON-matching sibling get compared against want[depth]:
    # looking for images.tools.tag in a file that also has
    # images.wrapper.tools.tag, `wrapper` failed to match and was passed over
    # without descending, so its child `tools` was then read as `images.tools`
    # and the nested `tag` was rewritten. The real pin stayed stale and the
    # script reported success — the worst possible shape for a chart bump.
    level_indent = [None]
    for i, raw in enumerate(lines):
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        m = re.match(r"^( *)([^\s:#][^:]*):(.*)$", raw)
        if not m:
            continue
        indent, key = len(m.group(1)), m.group(2).strip()
        # Leaving a nesting level: pop until this line's indent fits.
        while depth > 0 and indent <= indent_of[depth]:
            depth -= 1
            indent_of.pop()
            level_indent.pop()
        if level_indent[depth] is None:
            level_indent[depth] = indent
        elif indent > level_indent[depth]:
            # Deeper than this level's own keys, i.e. inside a sibling we did
            # not descend into. Skip the whole subtree.
            continue
        if depth < len(want) and key == want[depth]:
            if depth == len(want) - 1:
                hits.append(i)
                continue
            depth += 1
            indent_of.append(indent)
            level_indent.append(None)
    return hits


def set_scalar(text, dotted, value):
    """Replace the scalar at `dotted` (e.g. images.tools.tag), keeping the
    line's indentation and any trailing comment. Returns (text, changed)."""
    want = dotted.split(".")
    lines = text.splitlines(keepends=True)
    hits = _matching_lines(lines, want)
    if not hits:
        raise KeyError(dotted)
    if len(hits) > 1:
        # YAML permits duplicate keys and Helm's parser takes the LAST one.
        # Editing the first and reporting success would deploy the old tag.
        # There is no safe guess here, so fail loudly.
        where = ", ".join(str(i + 1) for i in hits)
        raise ValueError(
            f"{dotted} appears {len(hits)} times (lines {where}); "
            "refusing to guess which one Helm will use"
        )
    i = hits[0]
    m = re.match(r"^( *)([^\s:#][^:]*):(.*)$", lines[i])
    val = re.match(r"^(\s*)([^#]*?)(\s*(?:#.*)?)$", m.group(3))
    new = f"{m.group(1)}{m.group(2).strip()}:{val.group(1)}{value}{val.group(3)}\n"
    if new == lines[i]:
        return text, False
    lines[i] = new
    return "".join(lines), True


def main(argv):
    if len(argv) != 5:
        print(__doc__, file=sys.stderr)
        return 2
    values_file, key_template, releases_raw, images_raw = argv[1:]
    releases = json.loads(releases_raw or "{}")
    images = json.loads(images_raw or "{}")

    # The key is derived from the image's BASENAME, so two images whose full
    # names differ only in their owner or namespace — acme/worker and
    # other/worker — both target images.worker.tag. Whichever is processed
    # later would silently win and pin the chart to the wrong image's version.
    by_name = {}
    for image_names in images.values():
        for image in image_names:
            by_name.setdefault(image.rsplit("/", 1)[-1], set()).add(image)
    clashes = {n: sorted(v) for n, v in by_name.items() if len(v) > 1}
    if clashes:
        for name, full in sorted(clashes.items()):
            joined = ", ".join(full)
            print(
                f"::error::image basename {name!r} is shared by {joined} — "
                "the key template cannot tell them apart",
                file=sys.stderr,
            )
        return 1

    text = open(values_file, encoding="utf-8").read()
    changed, missing, ambiguous = [], [], []
    for path, image_names in sorted(images.items()):
        release = releases.get(path)
        if not release or not release.get("version"):
            continue
        value = "v" + release["version"]
        for image in image_names:
            name = image.rsplit("/", 1)[-1]
            dotted = key_template.replace("{name}", name)
            try:
                text, did = set_scalar(text, dotted, value)
            except KeyError:
                missing.append(dotted)
                continue
            except ValueError as err:
                ambiguous.append(str(err))
                continue
            if did:
                changed.append(f"{dotted} = {value}")
    if ambiguous:
        for msg in ambiguous:
            print(f"::error::{msg}", file=sys.stderr)
        return 1
    if missing:
        # A path that is not in the file is a configuration error, not a
        # no-op: silently skipping it would leave the chart deploying an old
        # image while the release looked green.
        print("not found in %s: %s" % (values_file, ", ".join(missing)), file=sys.stderr)
        return 1
    if changed:
        open(values_file, "w", encoding="utf-8").write(text)
    for line in changed:
        print(line)
    print("changed=%s" % ("true" if changed else "false"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
