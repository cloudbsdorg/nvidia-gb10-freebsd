#!/usr/bin/env python3
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-2-Clause
#
# schema_validate.py - validate JSON against the subset of JSON Schema that
# the libnvrm schema uses (draft 2020-12 keywords: $ref into #/$defs, oneOf,
# type, const, enum, required, properties, additionalProperties: false, items,
# prefixItems, minimum, maximum, minItems, maxItems; a $ref may carry sibling keywords,
# which apply as well, as in draft 2020-12).  An unknown keyword is an error, so the
# schema cannot start using something this validator silently ignores.
#
# usage: schema_validate.py SCHEMA [FILE]   (FILE or stdin: one JSON value per
#        non-empty line; exit 0 when all validate, 1 otherwise, 2 on usage)
import json
import sys

KNOWN = {"$schema", "$id", "title", "description", "$ref", "$defs", "oneOf",
         "type", "const", "enum", "required", "properties",
         "additionalProperties", "items", "prefixItems", "minimum", "maximum",
         "minItems", "maxItems"}


def is_type(v, t):
    if t == "object":
        return isinstance(v, dict)
    if t == "array":
        return isinstance(v, list)
    if t == "string":
        return isinstance(v, str)
    if t == "boolean":
        return isinstance(v, bool)
    if t == "integer":
        return isinstance(v, int) and not isinstance(v, bool)
    raise ValueError("unsupported type " + t)


def check_oneof(schema, v, root, path):
    ok = [s for s in schema["oneOf"] if not check(s, v, root, path)]
    if len(ok) == 1:
        return []
    errs = ["%s: matches %d of the oneOf alternatives" % (path, len(ok))]
    if not ok:
        # say why the closest alternative failed
        best = min((check(s, v, root, path) for s in schema["oneOf"]),
                   key=len)
        errs.extend(best[:3])
    return errs


def check_scalar(schema, v, path):
    errs = []
    if "const" in schema and (v != schema["const"] or
                              type(v) is not type(schema["const"])):
        errs.append("%s: not the constant %r" % (path, schema["const"]))
    if "enum" in schema and v not in schema["enum"]:
        errs.append("%s: %r not in the enum" % (path, v))
    if "minimum" in schema and isinstance(v, int) and v < schema["minimum"]:
        errs.append("%s: below the minimum" % path)
    if "maximum" in schema and isinstance(v, int) and v > schema["maximum"]:
        errs.append("%s: above the maximum" % path)
    return errs


def check_object(schema, v, root, path):
    errs = ["%s: missing required %s" % (path, r)
            for r in schema.get("required", []) if r not in v]
    props = schema.get("properties", {})
    for k, sub in v.items():
        if k in props:
            errs.extend(check(props[k], sub, root, path + "." + k))
        elif schema.get("additionalProperties", True) is False:
            errs.append("%s: unexpected property %s" % (path, k))
    return errs


def check_array(schema, v, root, path):
    errs = []
    if "minItems" in schema and len(v) < schema["minItems"]:
        errs.append("%s: too few items" % path)
    if "maxItems" in schema and len(v) > schema["maxItems"]:
        errs.append("%s: too many items" % path)
    prefix = schema.get("prefixItems", [])
    for i, sub in enumerate(prefix[:len(v)]):
        errs.extend(check(sub, v[i], root, "%s[%d]" % (path, i)))
    if "items" in schema:
        for i, sub in enumerate(v):
            if i >= len(prefix):
                errs.extend(check(schema["items"], sub, root,
                                  "%s[%d]" % (path, i)))
    return errs


def check(schema, v, root, path):
    """Return a list of error strings (empty when v is valid)."""
    for k in schema:
        if k not in KNOWN:
            return ["%s: validator does not support keyword %s" % (path, k)]
    if "$ref" in schema:
        ref = schema["$ref"]
        if not ref.startswith("#/$defs/"):
            return ["%s: unsupported $ref %s" % (path, ref)]
        rest = {k: x for k, x in schema.items() if k != "$ref"}
        return (check(root["$defs"][ref[8:]], v, root, path) +
                (check(rest, v, root, path) if rest else []))
    errs = check_oneof(schema, v, root, path) if "oneOf" in schema else []
    if "type" in schema and not is_type(v, schema["type"]):
        return errs + ["%s: not a %s" % (path, schema["type"])]
    errs += check_scalar(schema, v, path)
    if isinstance(v, dict):
        errs += check_object(schema, v, root, path)
    if isinstance(v, list):
        errs += check_array(schema, v, root, path)
    return errs


def main(argv):
    if len(argv) not in (2, 3):
        print(__doc__, file=sys.stderr)
        return 2
    with open(argv[1]) as f:
        schema = json.load(f)
    src = open(argv[2]) if len(argv) == 3 else sys.stdin
    n = 0
    bad = 0
    for lineno, line in enumerate(src, 1):
        if not line.strip():
            continue
        n += 1
        try:
            v = json.loads(line)
        except ValueError as e:
            print("line %d: not JSON: %s" % (lineno, e))
            bad += 1
            continue
        errs = check(schema, v, schema, "$")
        for e in errs:
            print("line %d: %s" % (lineno, e))
        bad += bool(errs)
    if n == 0:
        print("no JSON values to validate")
        return 1
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
