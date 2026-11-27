#!/usr/bin/env python3
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# gpu_check_coverage_gate.py - fail unless the new library is covered enough.
#
# The gate of the repository for the C library asks for 100% of the lines and
# of the branches of every file it names (tests/libnvrm/coverage_gate.py).
# This is the same gate for the new Python code: it reads the JSON report of
# coverage.py, prints the lines and the branches every file has, and fails
# when a file is below its floor.
#
# The floors are a ratchet: they are the numbers the code has today and they
# may only go up.  The gate says RAISE when a file is above its floor, so a
# floor that was left behind is loud, and a file without a floor is refused
# (the gate fails closed: a new file has no floor until it has one).
#
# Usage: gpu_check_coverage_gate.py <coverage.json> <floor file> <directory>...
# The JSON report is the one of "coverage json".  The floor file holds one
# line per file: the name of the file, a space, and the floor (a whole
# percentage).

import json
import os
import sys


def floors(path):
    """The floor of every file of the floor file."""
    wanted = {}
    with open(path, encoding="utf-8") as handle:
        for number, line in enumerate(handle, 1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            if len(parts) != 2:
                raise ValueError("line %d of the floor file is not a file and a number: %r"
                                 % (number, line))
            wanted[parts[0]] = int(parts[1])
    return wanted


def covered(summary):
    """The percentage of the lines and of the branches that were covered."""
    lines = summary.get("percent_covered")
    branches = summary.get("percent_branches_covered")
    if branches is None and summary.get("num_branches"):
        branches = summary.get("covered_branches", 0) * 100.0 / summary["num_branches"]
    return lines, branches


def files_of(directory):
    """The Python files of a directory, sorted."""
    found = []
    for name in sorted(os.listdir(directory)):
        if name.endswith(".py"):
            found.append(os.path.join(directory, name))
    return found


def main(argv):
    if len(argv) < 4:
        sys.stderr.write("usage: gpu_check_coverage_gate.py <coverage.json> "
                         "<floor file> <directory>...\n")
        return 2
    report = argv[1]
    try:
        wanted = floors(argv[2])
    except (OSError, ValueError) as exc:
        sys.stderr.write("the floor file cannot be read: %s\n" % exc)
        return 2
    try:
        with open(report, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError) as exc:
        sys.stderr.write("the coverage report cannot be read: %s\n" % exc)
        return 2
    measured = data.get("files") or {}
    bad = 0
    for directory in argv[3:]:
        for path in files_of(directory):
            name = os.path.basename(path)
            floor = wanted.get(name)
            if floor is None:
                print("%-14s no floor: the gate is closed for a file without one" % name)
                bad += 1
                continue
            entry = measured.get(name) or measured.get(path)
            if entry is None:
                print("%-14s not in the coverage data" % name)
                bad += 1
                continue
            summary = entry.get("summary") or {}
            lines, branches = covered(summary)
            lines = lines if lines is not None else 0.0
            branches = branches if branches is not None else 0.0
            lowest = min(lines, branches)
            ok = lowest >= floor
            if not ok:
                bad += 1
            elif int(lowest) > floor:
                print("%-14s lines %5.1f%%  branches %5.1f%%  RAISE THE FLOOR to %d%%"
                      % (name, lines, branches, int(lowest)))
            else:
                print("%-14s lines %5.1f%%  branches %5.1f%%  ok" % (name, lines, branches))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
