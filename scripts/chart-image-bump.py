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


def set_scalar(text, dotted, value):
    """Replace the scalar at `dotted` (e.g. images.tools.tag), keeping the
    line's indentation and any trailing comment. Returns (text, changed)."""
    want = dotted.split(".")
    lines = text.splitlines(keepends=True)
    depth, indent_of = 0, [-1]
    for i, raw in enumerate(lines):
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        m = re.match(r"^( *)([^\s:#][^:]*):(.*)$", raw)
        if not m:
            continue
        indent, key, rest = len(m.group(1)), m.group(2).strip(), m.group(3)
        # Leaving a nesting level: pop until this line's indent fits.
        while depth > 0 and indent <= indent_of[depth]:
            depth -= 1
            indent_of.pop()
        if depth < len(want) and key == want[depth]:
            if depth == len(want) - 1:
                val = re.match(r"^(\s*)([^#]*?)(\s*(?:#.*)?)$", rest)
                new = f"{m.group(1)}{key}:{val.group(1)}{value}{val.group(3)}\n"
                if new == raw:
                    return text, False
                lines[i] = new
                return "".join(lines), True
            depth += 1
            indent_of.append(indent)
    raise KeyError(dotted)


def main(argv):
    if len(argv) != 5:
        print(__doc__, file=sys.stderr)
        return 2
    values_file, key_template, releases_raw, images_raw = argv[1:]
    releases = json.loads(releases_raw or "{}")
    images = json.loads(images_raw or "{}")

    text = open(values_file, encoding="utf-8").read()
    changed, missing = [], []
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
            if did:
                changed.append(f"{dotted} = {value}")
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
