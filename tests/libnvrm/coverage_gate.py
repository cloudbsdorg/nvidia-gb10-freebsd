#!/usr/bin/env python3
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-2-Clause
#
# coverage_gate.py - fail unless every named source file has 100% line and
# 100% branch coverage in an llvm-cov export.  Reads the JSON on stdin.
#   llvm-cov export BIN -instr-profile=P --summary-only | coverage_gate.py FILE...
import json
import os
import sys

want = [os.path.basename(a) for a in sys.argv[1:]]
data = json.load(sys.stdin)
seen = {}
for f in data["data"][0]["files"]:
    seen[os.path.basename(f["filename"])] = f["summary"]
bad = 0
for name in want:
    s = seen.get(name)
    if s is None:
        print("%s: not in the coverage data" % name)
        bad += 1
        continue
    lines, br = s["lines"], s["branches"]
    ok = lines["percent"] == 100 and br["percent"] == 100
    print("%-14s lines %d/%d  branches %d/%d  %s" % (
        name, lines["covered"], lines["count"], br["covered"], br["count"],
        "ok" if ok else "BELOW 100%"))
    bad += not ok
sys.exit(1 if bad else 0)
