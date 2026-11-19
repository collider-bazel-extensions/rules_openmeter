#!/usr/bin/env python3
"""Build-time check of an openmeter_server `meters` file.

  validate_meters.py LABEL METERS_FILE OPENMETER_BIN OUT

The file must be YAML whose only top-level key is `meters:` (a list of
OpenMeter meter definitions, as in OpenMeter's config.yaml); it is appended
to the generated config.yaml at run time, so another top-level key would
override rules_openmeter's settings.

Checks, each failing with the file, the line and the meter's slug:
  - only `meters:` at the top level, no tabs, one YAML document;
  - each meter: `slug` present, a valid meter key
    (^[a-z0-9]+(?:_[a-z0-9]+)*$, at most 64 characters: the API's path
    pattern) and unique; `aggregation` one of OpenMeter's;
  - OpenMeter's own validation, by running `openmeter --validate` (the
    pinned server binary: config parsing + Configuration.Validate, which
    exits before connecting to anything) on the file, and on each meter
    alone so its errors name the meter.
On success the file is copied to OUT (the file the server runs with).
"""

import os
import re
import shutil
import subprocess
import sys
import tempfile

AGGREGATIONS = ["SUM", "COUNT", "AVG", "MIN", "MAX", "UNIQUE_COUNT", "LATEST"]
SLUG = re.compile(r"^[a-z0-9]+(?:_[a-z0-9]+)*$")

# Enough config for OpenMeter's Validate to reach the meters (placeholders;
# --validate exits before connecting to anything).
BASE = """
postgres:
  url: postgres://openmeter:openmeter@127.0.0.1:1/openmeter?sslmode=disable
"""


class Bad(Exception):
    pass


def scalar(text):
    """A plain or quoted YAML scalar on one line, without a trailing comment."""
    text = text.strip()
    if text[:1] in ("'", '"'):
        q = text[0]
        end = text.find(q, 1)
        return text[1:end] if end > 0 else text[1:]
    return re.sub(r"\s+#.*$", "", text).strip()


WORK = {"dir": None}


def run_validate(binary, meters_text):
    with tempfile.TemporaryDirectory(dir=WORK["dir"]) as d:
        cfg = os.path.join(d, "config.yaml")
        with open(cfg, "w") as f:
            # Meters first, so YAML line numbers are the file's.
            f.write(meters_text.rstrip("\n") + "\n" + BASE)
        r = subprocess.run([binary, "--validate", "--config", cfg], cwd=d,
                           env={"PATH": "/usr/bin:/bin", "HOME": d},
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if r.returncode == 0:
        return []
    out = r.stdout
    m = re.search(r"panic: (?:While parsing config: )?([^\"\\]+)", out)
    if m:
        return ["YAML: " + m.group(1).strip()]
    lines = [l for l in out.splitlines() if l.strip() and not l.startswith("configuration error")]
    return lines or [out.strip()]


def split_items(lines):
    """[(first line number, [lines])] for each entry of the block sequence
    under `meters:`; None when the value is a flow sequence."""
    start = None
    for i, l in enumerate(lines):
        if re.match(r"^meters\s*:", l):
            start = i
            rest = scalar(l.split(":", 1)[1])
            if rest:
                return None
            break
    items = []
    indent = None
    cur = None
    for i in range(start + 1, len(lines)):
        l = lines[i]
        if not l.strip() or l.lstrip().startswith("#"):
            if cur is not None:
                cur[1].append(l)
            continue
        ind = len(l) - len(l.lstrip(" "))
        if indent is None:
            if not l.lstrip().startswith("-"):
                raise Bad(f"line {i + 1}: `meters:` must be a list of meters (`- slug: ...` entries)")
            indent = ind
        if ind == indent and re.match(r"^-(\s|$)", l[ind:]):
            cur = (i + 1, [l])
            items.append(cur)
        elif ind > indent and cur is not None:
            cur[1].append(l)
        else:
            raise Bad(f"line {i + 1}: unexpected text at this indentation inside `meters:`: {l.strip()!r}")
    return items


def item_field(item_lines, key):
    """The value of a top-level key of one sequence entry, and its line offset."""
    first = item_lines[0]
    dash = first.index("-")
    m = re.match(r"^-\s+", first[dash:])
    key_col = dash + (m.end() if m else 2)
    for off, l in enumerate(item_lines):
        body = l[key_col:] if off else first[key_col:]
        if off and (len(l) - len(l.lstrip(" "))) != key_col:
            continue
        km = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\s*:(.*)$", body)
        if km and km.group(1) == key:
            return scalar(km.group(2)), off
    return None, None


def check(path, binary):
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except UnicodeDecodeError:
        raise Bad("not UTF-8 text")
    lines = text.splitlines()
    seen_meters = False
    for i, l in enumerate(lines):
        if "\t" in l[: len(l) - len(l.lstrip())]:
            raise Bad(f"line {i + 1}: tab in indentation (YAML allows spaces only)")
        if not l.strip() or l.startswith("#") or l[0] in (" ", "-"):
            continue
        if l.rstrip() in ("---", "..."):
            raise Bad(f"line {i + 1}: {l.strip()!r}: one YAML document only, without document markers")
        if re.match(r"^meters\s*:", l):
            if seen_meters:
                raise Bad(f"line {i + 1}: `meters:` appears twice")
            seen_meters = True
            continue
        key = l.split(":", 1)[0].strip()
        raise Bad(f"line {i + 1}: top-level key {key!r}: the meters file may only hold `meters:` "
                  "(rules_openmeter generates the rest of OpenMeter's config)")
    if not seen_meters:
        raise Bad("no top-level `meters:` key (expected `meters:` followed by `- slug: ...` entries)")

    errors = run_validate(binary, text)
    items = split_items(lines)
    if items is None:
        # A flow sequence: OpenMeter's check only.
        if errors:
            raise Bad("OpenMeter rejects the meters:\n" + "\n".join("    " + e for e in errors))
        return

    problems = []
    slugs = {}
    for n, (line, item) in enumerate(items, 1):
        slug, soff = item_field(item, "slug")
        where = f"meter #{n} (line {line}" + (f", slug {slug!r})" if slug else ")")
        if not slug:
            problems.append(f"{where}: no `slug` (the meter's key)")
        elif not SLUG.match(slug) or len(slug) > 64:
            problems.append(f"{where}: slug must match ^[a-z0-9]+(?:_[a-z0-9]+)*$ (lower-case words joined by `_`), at most 64 characters")
        elif slug in slugs:
            problems.append(f"{where}: duplicate slug; meter #{slugs[slug]} has it too")
        else:
            slugs[slug] = n
        agg, _ = item_field(item, "aggregation")
        if agg is not None and agg not in AGGREGATIONS:
            problems.append(f"{where}: aggregation {agg!r}: expected one of {', '.join(AGGREGATIONS)}")
        # OpenMeter on this meter alone (padding keeps its line numbers).
        alone = "meters:\n" + "\n" * (line - 2) + "\n".join(item) + "\n"
        for e in run_validate(binary, alone):
            problems.append(f"{where}: {e}")
    if problems:
        raise Bad("\n".join("  " + p for p in problems))
    if errors:
        raise Bad("OpenMeter rejects the meters:\n" + "\n".join("    " + e for e in errors))


def main(argv):
    label, path, binary, out = argv
    binary = os.path.abspath(binary)
    # Scratch files next to the output, not in /tmp.
    WORK["dir"] = os.path.dirname(os.path.abspath(out))
    try:
        check(path, binary)
    except Bad as e:
        msg = str(e)
        if not msg.startswith("  "):
            msg = "  " + msg
        sys.stderr.write(f"{label}: bad meters file {path}:\n{msg}\n")
        return 1
    shutil.copyfile(path, out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
