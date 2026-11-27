#!/usr/bin/env python3
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# schema_check.py - the JSON Schema checker of the test suite.
#
# It reads the keywords the schemas of this repository use: $ref, oneOf,
# const, enum, type, pattern, minimum, maximum, minLength, maxLength,
# minItems, maxItems, items, required, properties and additionalProperties.
# A document the registered schema refuses is refused here too, and a
# document the schema holds is held here.
#
# Usage: python3 tests/schema_check.py SCHEMA FILE [FILE ...]
#   A .jsonl file is read line by line, and every line must match one
#   branch of the schema.  A .json file is read as one document.
"""Check a document (or a stream of them) against a JSON Schema."""
import json
import re
import sys


def _is(value, kind):
    """Is the value of this JSON type?"""
    if kind == "object":
        return isinstance(value, dict)
    if kind == "array":
        return isinstance(value, list)
    if kind == "string":
        return isinstance(value, str)
    if kind == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if kind == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if kind == "boolean":
        return isinstance(value, bool)
    if kind == "null":
        return value is None
    return False


def check(value, rule, root, where):
    """Raise AssertionError when the value does not hold the rule."""
    if "$ref" in rule:
        name = rule["$ref"].rsplit("/", 1)[1]
        return check(value, root["$defs"][name], root, where)
    if "oneOf" in rule:
        return _check_one_of(value, rule, root, where)
    _check_value(value, rule, where)
    if isinstance(value, str):
        _check_string(value, rule, where)
    if isinstance(value, int) and not isinstance(value, bool):
        _check_number(value, rule, where)
    if isinstance(value, list):
        _check_list(value, rule, root, where)
    if isinstance(value, dict):
        _check_object(value, rule, root, where)


def _check_one_of(value, rule, root, where):
    """Exactly one branch of a oneOf may hold the value."""
    good = 0
    for branch in rule["oneOf"]:
        try:
            check(value, branch, root, where)
        except AssertionError:
            continue
        good += 1
    if good != 1:
        raise AssertionError("%s: %d of the branches match, not 1" % (where, good))


def _check_value(value, rule, where):
    """The keywords every value carries: const, enum and type."""
    if "const" in rule and value != rule["const"]:
        raise AssertionError("%s: %r is not %r" % (where, value, rule["const"]))
    if "enum" in rule and value not in rule["enum"]:
        raise AssertionError("%s: %r is not one of %r" % (where, value, rule["enum"]))
    kind = rule.get("type")
    if not kind:
        return
    kinds = kind if isinstance(kind, list) else [kind]
    if not any(_is(value, one) for one in kinds):
        raise AssertionError("%s: %r is not %s" % (where, value, kind))


def _check_string(value, rule, where):
    """The keywords a string carries: minLength, maxLength and pattern."""
    if "minLength" in rule and len(value) < rule["minLength"]:
        raise AssertionError("%s: %r is shorter than %d" % (where, value, rule["minLength"]))
    if "maxLength" in rule and len(value) > rule["maxLength"]:
        raise AssertionError("%s: %r is longer than %d" % (where, value, rule["maxLength"]))
    if "pattern" in rule and not re.search(rule["pattern"], value):
        raise AssertionError("%s: %r does not match %s" % (where, value, rule["pattern"]))


def _check_number(value, rule, where):
    """The keywords a number carries: minimum and maximum."""
    if "minimum" in rule and value < rule["minimum"]:
        raise AssertionError("%s: %d is below %d" % (where, value, rule["minimum"]))
    if "maximum" in rule and value > rule["maximum"]:
        raise AssertionError("%s: %d is above %d" % (where, value, rule["maximum"]))


def _check_list(value, rule, root, where):
    """The keywords a list carries: minItems, maxItems and items."""
    if "minItems" in rule and len(value) < rule["minItems"]:
        raise AssertionError("%s: %d items, at least %d" % (where, len(value), rule["minItems"]))
    if "maxItems" in rule and len(value) > rule["maxItems"]:
        raise AssertionError("%s: %d items, at most %d" % (where, len(value), rule["maxItems"]))
    if "items" in rule:
        for index, item in enumerate(value):
            check(item, rule["items"], root, "%s[%d]" % (where, index))


def _check_object(value, rule, root, where):
    """The keywords an object carries: required, properties and additional."""
    for key in rule.get("required", []):
        if key not in value:
            raise AssertionError("%s: no %s field" % (where, key))
    properties = rule.get("properties", {})
    if rule.get("additionalProperties") is False:
        for key in value:
            if key not in properties:
                raise AssertionError("%s: the %s field is not in the schema" % (where, key))
    for key, item in value.items():
        if key in properties:
            check(item, properties[key], root, "%s.%s" % (where, key))


def validate(value, schema, where="the document"):
    """Raise AssertionError when the value does not hold the schema."""
    check(value, schema, schema, where)


def validate_lines(lines, schema, where="the record"):
    """Raise AssertionError when a line of the stream does not hold it."""
    for number, line in enumerate(lines, 1):
        if not line.strip():
            continue
        record = json.loads(line)
        try:
            check(record, schema, schema, where)
        except AssertionError as exc:
            raise AssertionError("line %d: %s" % (number, exc))


def main(argv):
    if len(argv) < 2:
        print("usage: schema_check.py SCHEMA FILE [FILE ...]", file=sys.stderr)
        return 2
    with open(argv[0], encoding="utf-8") as handle:
        schema = json.load(handle)
    for path in argv[1:]:
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
        if path.endswith(".jsonl"):
            validate_lines(text.splitlines(), schema)
        else:
            validate(json.loads(text), schema, path)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
