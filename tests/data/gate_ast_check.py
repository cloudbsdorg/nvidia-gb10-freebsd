# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# gate_ast_check.py - the AST half of the gate-name check of tests/prime_import_test.sh.
#
# usage: gate_ast_check.py <gate_names.txt>     the AST dump on stdin
#
# Reads the output of `clang -fsyntax-only -Xclang -ast-dump=json -Xclang -ast-dump-filter=nv_drm_pi_`
# (a stream of JSON objects, one per declaration whose name contains the filter) on stdin.  The file was
# compiled with the module's own flags, so macros, token pasting, typedefs and attributes are already resolved.
#
# Every declaration named EXACTLY one of the gate names (the first column of gate_names.txt), of any kind and
# at any depth (a local, a parameter, a field, a typedef, a function pointer variable, a static function), must be
# an external declaration of that function with the type of the second column (the header spells it without
# `extern`, lkpi.c with it): no static, no body, no attribute.  The definitions live in
# nvidia-drm-gem-dma-buf.c, which is not part of these translation units.  Names that only contain the filter
# (nv_drm_pi_guard_handler, a static function with a body) are not looked at.  Each name must also be declared
# at least once, so a macro that renames the real declarations is refused too.
#
# Prints one line per violation (file:line, kind, name, reason); nothing when the file is clean.  Exit 0 when it
# ran, 2 when the input or the names file is unreadable.

import json
import sys


def read_names(path):
    gates = {}
    with open(path) as f:
        for line in f:
            if line.startswith("#") or not line.strip():
                continue
            name, _, qual = line.rstrip("\n").partition("\t")
            gates[name] = qual
    return gates


def stream(text):
    dec = json.JSONDecoder()
    i, n = 0, len(text)
    while True:
        while i < n and text[i].isspace():
            i += 1
        if i >= n:
            return
        obj, i = dec.raw_decode(text, i)
        yield obj


class Walker:
    """Walks the dump in document order.  clang leaves the file (and the line) out of a location when it is the
    same as the one printed before it, so the position of a node is what the walk has seen last."""

    def __init__(self, gates):
        self.gates = gates
        self.file = ""
        self.line = 0
        self.seen = set()
        self.out = []

    def absorb(self, loc):
        if not isinstance(loc, dict):
            return
        # a macro location prints the spelling place, then the place the macro was used: the second one wins
        self.absorb(loc.get("spellingLoc"))
        self.absorb(loc.get("expansionLoc"))
        if "file" in loc:
            self.file = loc["file"]
        if "line" in loc:
            self.line = loc["line"]

    def refuse(self, node, why):
        self.out.append("%s:%s %s %s: %s" % (self.file, self.line, node.get("kind", "?"), node.get("name", "?"), why))

    def judge(self, node):
        name = node["name"]
        qual = (node.get("type") or {}).get("qualType")
        inner = node.get("inner") or []
        if node.get("kind") != "FunctionDecl":
            self.refuse(node, "is not a function declaration (a variable, parameter, typedef or field of this name)")
        elif node.get("storageClass") not in (None, "extern"):
            self.refuse(node, "is %s, not an external declaration" % node.get("storageClass"))
        elif any(c.get("kind") != "ParmVarDecl" for c in inner):
            self.refuse(node, "has a body or an attribute")
        elif qual != self.gates[name]:
            self.refuse(node, "has type '%s', expected '%s'" % (qual, self.gates[name]))
        else:
            self.seen.add(name)

    def walk(self, node):
        for key, val in node.items():
            if key == "loc":
                self.absorb(val)
                if node.get("name") in self.gates:
                    self.judge(node)
            elif key == "range" and isinstance(val, dict):
                self.absorb(val.get("begin"))
                self.absorb(val.get("end"))
            elif key == "inner" and isinstance(val, list):
                for c in val:
                    if isinstance(c, dict):
                        self.walk(c)
        if "loc" not in node and node.get("name") in self.gates:
            self.judge(node)


def main():
    if len(sys.argv) != 2:
        print("usage: gate_ast_check.py <gate_names.txt>")
        return 2
    try:
        gates = read_names(sys.argv[1])
        objs = list(stream(sys.stdin.read()))
    except (OSError, ValueError) as e:
        print("unreadable input: %s" % e)
        return 2
    if not gates:
        print("no gate names in %s" % sys.argv[1])
        return 2
    w = Walker(gates)
    for o in objs:
        if isinstance(o, dict):
            w.walk(o)
    for g in sorted(gates):
        if g not in w.seen:
            w.out.append("no external declaration of %s in the translation unit (renamed by a macro, or gone)" % g)
    for line in w.out:
        print(line)
    return 0


sys.exit(main())
