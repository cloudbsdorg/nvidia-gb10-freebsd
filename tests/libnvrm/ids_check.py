#!/usr/bin/env python3
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-2-Clause
#
# ids_check.py - the identifiers of the nvrm-info schema may only grow.
#
# A consumer keys on reason ids, error codes, source names and the capability
# index and name pairs, so removing, renaming or renumbering one is a breaking
# change (a new schema major), whatever the minor says.  The baseline
# (schema/nvrm-info-1.ids) lists every identifier as "KIND NUMBER NAME MINOR",
# MINOR being the schema minor that introduced it (the field is required).  This
# check fails when one of its lines is not in the schema.  New
# identifiers (schema lines the baseline does not have) are allowed in the
# plain mode; the --strict mode, which the test suite runs on the schema of the
# tree, also requires each of them to be appended to the baseline, so the
# baseline cannot be truncated to hide a rename, and no line to name a minor
# above the schema's.  A missing or unreadable baseline, a kind with no line, a
# gap in the numbering of a kind and a duplicated number all FAIL: the check
# never reads as "nothing to compare".
#
# --frozen compares the baseline with an earlier copy of itself (the suite
# fetches the copy of the revision it names, see tests/libnvrm_test.sh):
# every earlier line
# must still be there unchanged, and a line that is new must name a minor above
# every earlier one and not above the schema's, so adding an identifier without
# raising the minor is refused.
#
# Limit: without an earlier copy (the first commit of the baseline) one change
# that edits a baseline line and the schema together is not caught; the suite
# says so when it skips --frozen.
USAGE = """usage: ids_check.py [--strict] SCHEMA BASELINE   exit 0 ok, 1 violation, 2 usage
       ids_check.py --frozen OLD NEW SCHEMA        NEW only adds to OLD, at a higher minor
       ids_check.py --emit SCHEMA [OLD]            print the identifiers of SCHEMA: the
                                                   lines of OLD as they are, then the
                                                   new ones at the schema minor"""
import json
import sys

KINDS = ("source", "reason", "error", "capability")
# the number of the first identifier of each kind (0 is "available" for the
# reasons and "success" for the errors, which are not identifiers)
FIRST = {"source": 0, "reason": 1, "error": 1, "capability": 0}


def numbered(kind, names):
    return {(kind, FIRST[kind] + i): n for i, n in enumerate(names)}


def extract(schema):
    """Return {(kind, number): name} read from a generated schema."""
    d = schema["$defs"]
    ids = numbered("source", d["source"]["enum"])
    ids.update(numbered("reason", d["reason_id"]["enum"]))
    code = d["error"]["properties"]["error"]["properties"]["code"]["enum"]
    ids.update(numbered("error", code))
    caps = d["device"]["properties"]["capabilities"]["prefixItems"]
    for i, c in enumerate(caps):
        p = c["properties"]
        if p["index"]["const"] != FIRST["capability"] + i:
            raise ValueError("capability %d is pinned at index %r" %
                             (i, p["index"]["const"]))
    ids.update(numbered("capability",
                        [c["properties"]["name"]["const"] for c in caps]))
    return ids


def load_schema(path):
    """Return (ids, minor) of a schema file, or None after saying why."""
    try:
        with open(path) as f:
            schema = json.load(f)
        minor = schema["$defs"]["document"]["properties"]["schema_minor"]["const"]
        return extract(schema), minor
    except (OSError, ValueError, KeyError, TypeError) as e:
        print("ids_check: cannot read the identifiers of %s: %s" % (path, e))
        return None


def parse_line(line):
    """Return ((kind, number), (name, minor)) for one line, or None."""
    f = line.split()
    if len(f) != 4 or f[0] not in KINDS or not f[1].isdigit() or not f[3].isdigit():
        return None
    return (f[0], int(f[1])), (f[2], int(f[3]))


def parse_lines(lines, path):
    """Parse a baseline into {key: (name, minor)}; None after saying why."""
    base = {}
    for n, line in enumerate(lines, 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        got = parse_line(line)
        if got is None:
            print("ids_check: %s line %d is not 'KIND NUMBER NAME MINOR': "
                  "%r" % (path, n, line))
            return None
        if got[0] in base:
            print("ids_check: %s line %d repeats %s %s" %
                  (path, n, got[0][0], got[0][1]))
            return None
        base[got[0]] = got[1]
    return base


def complete(base, path):
    """True when each kind is present and numbered without a gap."""
    for k in KINDS:
        nums = sorted(n for (kind, n) in base if kind == k)
        if not nums:
            print("ids_check: baseline %s has no %s identifiers" % (path, k))
            return False
        if nums != list(range(FIRST[k], FIRST[k] + len(nums))):
            print("ids_check: baseline %s has a gap in the %s numbers %s" %
                  (path, k, nums))
            return False
    return True


def load_baseline(path):
    try:
        with open(path) as f:
            lines = f.read().splitlines()
    except OSError as e:
        print("ids_check: no baseline %s (%s): the check cannot run, which "
              "is a failure" % (path, e))
        return None
    base = parse_lines(lines, path)
    if base is None or not complete(base, path):
        return None
    return base


def emit(path, old_path=None):
    """Print the identifiers of a schema, one line each.  Lines of the old
    baseline come out as they are; the others carry the schema's minor."""
    got = load_schema(path)
    old = {}
    if old_path is not None:
        old = load_baseline(old_path)
    if got is None or old is None:
        return 1
    ids, minor = got
    for k in KINDS:
        for (kind, num), name in sorted(ids.items()):
            if kind == k:
                print("%s %d %s %d" % (kind, num, old.get((kind, num), (name, minor))[0],
                                       old.get((kind, num), (name, minor))[1]))
    return 0


def compare(cur, minor, base, strict):
    """Print every violation; return how many there are."""
    bad = 0
    for (kind, num), (name, _) in sorted(base.items()):
        if cur.get((kind, num)) == name:
            continue
        bad += 1
        where = [n for (k, n), v in cur.items() if k == kind and v == name]
        if where:
            print("ids_check: %s %s was number %d and is now %d" %
                  (kind, name, num, where[0]))
        else:
            print("ids_check: %s %s (number %d) is gone: removing or "
                  "renaming an identifier is a new schema major" %
                  (kind, name, num))
    if not strict:
        return bad
    for (kind, num), name in sorted(cur.items()):
        if (kind, num) not in base:
            bad += 1
            print("ids_check: %s %s (number %d) is in the schema and not "
                  "in the baseline: append it to the baseline" %
                  (kind, name, num))
    for (kind, num), (name, m) in sorted(base.items()):
        if m > minor:
            bad += 1
            print("ids_check: %s %s names minor %d, above the schema's %d" %
                  (kind, name, m, minor))
    return bad


def frozen(old_path, new_path, schema_path):
    """The new baseline only adds to the old one, at a higher minor."""
    try:
        with open(old_path) as f:
            old = parse_lines(f.read().splitlines(), old_path)
    except OSError as e:
        print("ids_check: cannot read %s: %s" % (old_path, e))
        return 1
    new = load_baseline(new_path)
    got = load_schema(schema_path)
    if old is None or new is None or got is None:
        return 1
    minor, top = got[1], max([m for _, m in old.values()] or [0])
    bad = 0
    for key, val in sorted(old.items()):
        if new.get(key) != val:
            bad += 1
            print("ids_check: %s %s (number %d) was %r and is now %r: a "
                  "frozen line never changes" %
                  (key[0], val[0], key[1], val, new.get(key)))
    for key, (name, m) in sorted(new.items()):
        if key not in old and not top < m <= minor:
            bad += 1
            print("ids_check: %s %s (number %d) is new and names minor %d: "
                  "it must be above %d and not above the schema's %d (an "
                  "added identifier raises the minor)" %
                  (key[0], name, key[1], m, top, minor))
    return 1 if bad else 0


def main(argv):
    if len(argv) == 5 and argv[1] == "--frozen":
        return frozen(argv[2], argv[3], argv[4])
    strict = len(argv) == 4 and argv[1] == "--strict"
    if strict:
        argv = argv[:1] + argv[2:]
    if len(argv) in (3, 4) and argv[1] == "--emit":
        return emit(argv[2], argv[3] if len(argv) == 4 else None)
    if len(argv) != 3:
        print(USAGE, file=sys.stderr)
        return 2
    got = load_schema(argv[1])
    base = load_baseline(argv[2])
    if got is None or base is None:
        return 1
    return 1 if compare(got[0], got[1], base, strict) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
