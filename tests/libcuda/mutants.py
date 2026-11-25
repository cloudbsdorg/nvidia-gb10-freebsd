#!/usr/bin/env python3
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-2-Clause
#
# The derivation of the mutants of the test.  A mutant is derived from the
# source of the production code: the helper finds the place to change by
# the name of a function, of a variable or of a macro, and it changes that
# place.  The test holds no copy of the production text, so a source that is
# reformatted, or whose private names change, does not break the test: only
# a change of the public names the helper is given breaks it, and then it
# says so.
#
# Every command writes the file it is given and prints nothing when it
# succeeds.  A command that cannot find its place fails with a message
# that names what it did not find.
"""The derivation of the mutants of the test."""

import re
import sys


def match_brace(text, start):
    """The index of the brace that closes the one at start."""
    depth = 0
    for index in range(start, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return index
    raise SystemExit("the braces of the source are not balanced")


def find_function(text, name):
    """The span of the body of the function of that name."""
    # The name is the last token before the argument list, on a line that
    # holds no statement: the return type may be on the line above it.
    pattern = re.compile(
        r"(?m)^[^\n;]*\b" + re.escape(name) + r"\s*\(")
    for match in pattern.finditer(text):
        start = text.index("(", match.start() + len(match.group(0)) - 1)
        depth = 0
        index = start
        while index < len(text):
            if text[index] == "(":
                depth += 1
            elif text[index] == ")":
                depth -= 1
                if depth == 0:
                    break
            index += 1
        brace = text.find("{", index)
        if brace < 0:
            continue
        if text[index + 1:brace].strip():
            # A call and not a definition: the body does not follow the
            # argument list.
            continue
        return brace + 1, match_brace(text, brace)
    raise SystemExit("the function %s is not in the source" % name)


def function_body(text, name):
    """The body of the function of that name."""
    start, end = find_function(text, name)
    return text[start:end]


def command_function_body(path, name, body_path):
    """Replace the body of the function of that name with the given body."""
    with open(path) as handle:
        text = handle.read()
    start, end = find_function(text, name)
    with open(body_path) as handle:
        body = handle.read().rstrip("\n")
    patched = text[:start] + "\n" + body + "\n" + text[end:]
    with open(path, "w") as handle:
        handle.write(patched)


def find_condition(text, token):
    """The span of the condition of the if that mentions the token."""
    for match in re.finditer(r"\bif\s*\(", text):
        start = match.end() - 1
        depth = 0
        index = start
        while index < len(text):
            if text[index] == "(":
                depth += 1
            elif text[index] == ")":
                depth -= 1
                if depth == 0:
                    break
            index += 1
        condition = text[start + 1:index]
        if token in condition:
            return start + 1, index
    raise SystemExit("no condition of an if mentions %s" % token)


def command_if_condition(path, function, token, condition):
    """Replace the condition of the if of the function that mentions the
    token."""
    with open(path) as handle:
        text = handle.read()
    body_start, body_end = find_function(text, function)
    body = text[body_start:body_end]
    start, end = find_condition(body, token)
    patched = body[:start] + condition + body[end:]
    with open(path, "w") as handle:
        handle.write(text[:body_start] + patched + text[body_end:])


def command_initializer(path, function, variable, value):
    """Replace the initializer of the declaration of the variable."""
    with open(path) as handle:
        text = handle.read()
    body_start, body_end = find_function(text, function)
    body = text[body_start:body_end]
    pattern = re.compile(r"\b" + re.escape(variable) + r"\s*=\s*[^;]+;")
    match = pattern.search(body)
    if match is None:
        raise SystemExit("the variable %s is not initialized in %s" %
            (variable, function))
    patched = body[:match.start()] + "%s = %s;" % (variable, value) + \
        body[match.end():]
    with open(path, "w") as handle:
        handle.write(text[:body_start] + patched + text[body_end:])


def command_drop_check(path, function, macro, argument):
    """Replace the check of the macro with a read of the argument."""
    with open(path) as handle:
        text = handle.read()
    body_start, body_end = find_function(text, function)
    body = text[body_start:body_end]
    pattern = re.compile(
        r"\b" + re.escape(macro) + r"\s*\(\s*" + re.escape(argument) +
        r"\s*,[^)]*\)\s*;")
    match = pattern.search(body)
    if match is None:
        raise SystemExit("the check %s of %s is not in %s" %
            (macro, argument, function))
    patched = body[:match.start()] + "(void)%s;" % argument + body[match.end():]
    with open(path, "w") as handle:
        handle.write(text[:body_start] + patched + text[body_end:])


def command_rename_member(path, struct, member, new):
    """Rename a member of a named struct: the declaration and the uses of
    it.  The change keeps the behavior of the code."""
    with open(path) as handle:
        text = handle.read()
    declaration = re.search(
        r"(?m)^\}\s*" + re.escape(struct) + r"\s*;", text)
    if declaration is None:
        raise SystemExit("the struct %s is not in the source" % struct)
    end = declaration.start()
    start = text.rfind("{", 0, end)
    if start < 0:
        raise SystemExit("the struct %s has no body" % struct)
    body = text[start:end]
    member_declaration = re.compile(
        r"(?m)^([ \t]*[^;\n]*?)\b" + re.escape(member) + r"\s*;")
    found = member_declaration.search(body)
    if found is None:
        raise SystemExit("the member %s is not in %s" % (member, struct))
    body = body[:found.start()] + found.group(1) + new + ";" + body[found.end():]
    text = text[:start] + body + text[end:]
    patched, count = re.subn(
        r"\b" + re.escape(struct) + r"\." + re.escape(member) + r"\b",
        struct + "." + new, text)
    if count == 0:
        raise SystemExit("the member %s of %s is not used" % (member, struct))
    with open(path, "w") as handle:
        handle.write(patched)


def command_include(path, header):
    """Add the include of the header after the first include of the file."""
    with open(path) as handle:
        text = handle.read()
    match = re.search(r"(?m)^#include\s+[<\"][^\n]*\n", text)
    if match is None:
        raise SystemExit("the source has no include to add one after")
    patched = text[:match.end()] + "#include <%s>\n" % header + text[match.end():]
    with open(path, "w") as handle:
        handle.write(patched)


COMMANDS = {
    "function-body": command_function_body,
    "if-condition": command_if_condition,
    "initializer": command_initializer,
    "drop-check": command_drop_check,
    "rename-member": command_rename_member,
    "include": command_include,
}


def main(argv):
    if len(argv) < 3:
        raise SystemExit("usage: mutants.py COMMAND FILE ARGUMENT ...")
    command = COMMANDS.get(argv[1])
    if command is None:
        raise SystemExit("unknown command %s" % argv[1])
    command(*argv[2:])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
