#!/usr/local/bin/python3 -I
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-2-Clause
#
# summarize.py - read one native-tools test-boot run (Track #2362) and write summary.json (schema
# native-tools-summary/1, native-tools-summary.schema.json) and a text summary on standard output.
#
# usage: summarize.py RUN_DIR      (the directory holding results.jsonl)
#        summarize.py --planned   (print the planned rows, for the kit test)
#
# Reading rule:
#   - every planned row (PLANNED below) appears in summary.json with a status; a planned row the run never wrote is
#     "missing": an error when no row of the run failed (the run lost it), not-run when one did (it was never
#     reached);
#   - a row whose last record is "running" stopped there (a panic or a kill): error;
#   - the native rows are the ones that ran (pass, fail, error); native_verdict is fail when one of them is fail or
#     error, else pass;
#   - verdict: fail when native_verdict is fail or the run has no final done row; incomplete when no row failed but a
#     planned row is needs-linux, needs-linuxkpi, not-available or not-run; pass only when every planned row passed.
#     A run that measured little therefore reads incomplete, never pass.
# Exit: 0 pass, 1 fail, 3 incomplete, 2 usage or unreadable input.  The last line printed is PASS, FAIL or INCOMPLETE.

import json
import os
import sys

SCHEMA = "native-tools-summary/1"
PLANNED = [
    "deadman", "panic-settings", "linux-enable", "env-before",
    "hash-nvidia_gsp_ga10x_fw.ko", "hash-nvidia.ko", "hash-nvidia-modeset.ko", "hash-nvrm-info", "hash-libnvrm.so.1",
    "load-nvidia_gsp_ga10x_fw", "load-nvidia", "load-nvidia-modeset", "load", "env-loaded",
    "gpu-node", "root-open", "gpu-verify", "nvidiactl-open", "modeset-open",
    "nvrm-info", "nvrm-info-native", "nvrm-info-no-new-module",
    "uvm-ioctl-suite", "uvm-owner-probe", "uvm-owner-race", "prime-import", "render-uapi", "nvrm-s2-memory",
    "env-after", "env-after-delta", "done",
]
RAN = {"pass", "fail", "error"}
SKIPPED = {"needs-linux", "needs-linuxkpi", "not-available", "not-run"}
KNOWN = RAN | SKIPPED | {"info", "running"}



def parse(lines):
    """The last record of each row, in first-seen order, and the number of lines that do not parse."""
    order, last, bad = [], {}, 0
    for ln in lines:
        try:
            rec = json.loads(ln)
            name, status, detail = rec["row"], rec["status"], rec.get("detail", "")
        except (ValueError, KeyError, TypeError, AttributeError):
            bad += 1
            continue
        if name not in last:
            order.append(name)
        if status not in KNOWN:
            status, detail = "error", "unknown status %r: %s" % (status, detail)
        if status == "running":
            status, detail = "error", "the run stopped in this step (a panic or a kill): " + detail
        last[name] = {"status": status, "detail": detail}
    return order, last, bad


def complete(rows, bad):
    """Give every planned row a status.  A planned row the run never wrote has no place in the write order, so the
    rule looks at the whole run: when any written row (planned or not: preloaded, guard-lib, ...) failed, the missing
    row was not reached (not-run); when none failed, the run lost it (an error)."""
    any_failed = any(r["status"] in ("fail", "error") for r in rows.values())
    for name in PLANNED:
        if name not in rows:
            rows[name] = ({"status": "not-run", "detail": "not reached: an earlier row failed"} if any_failed else
                          {"status": "error", "detail": "missing: the run never wrote this row and no row failed"})
    if bad:
        rows["results-jsonl"] = {"status": "error", "detail": "%d line(s) of results.jsonl do not parse" % bad}
    return rows


def reading(rows):
    """The two verdicts and the row lists they rest on."""
    native = [n for n, r in rows.items() if r["status"] in RAN]
    failed = [n for n in native if rows[n]["status"] != "pass"]
    skipped = [n for n in PLANNED if rows[n]["status"] in SKIPPED]
    done_ok = rows["done"]["status"] == "info"
    verdict = "fail" if failed or not done_ok else ("incomplete" if skipped else "pass")
    return {"verdict": verdict, "native_verdict": "fail" if failed else "pass", "native_rows": native,
            "failed_rows": failed, "skipped_rows": skipped, "done": done_ok}


def clip(text, n=200):
    return text if len(text) <= n else text[:n] + " ... (full text in summary.json)"


def report(run, rows, order, r):
    counts = {}
    for row in rows.values():
        counts[row["status"]] = counts.get(row["status"], 0) + 1
    names = PLANNED + [n for n in order + list(rows) if n not in PLANNED]
    names = list(dict.fromkeys(names))
    doc = {"schema": SCHEMA, "version": 1, "run": os.path.basename(os.path.normpath(run)),
           "verdict": r["verdict"], "native_verdict": r["native_verdict"], "counts": counts, "planned": PLANNED,
           "native_rows": r["native_rows"], "failed_rows": r["failed_rows"], "skipped_rows": r["skipped_rows"],
           "rows": [dict(name=n, **rows[n]) for n in names]}
    with open(os.path.join(run, "summary.json"), "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=2, sort_keys=True)
        f.write("\n")
    for n in names:
        print("%-15s %-28s %s" % (rows[n]["status"], n, clip(rows[n]["detail"])))
    print("native rows: %d ran, %d failed (%s)" % (len(r["native_rows"]), len(r["failed_rows"]),
                                                    ", ".join(r["failed_rows"]) or "none"))
    print("not run natively: %s" % (", ".join("%s (%s)" % (n, rows[n]["status"]) for n in r["skipped_rows"]) or "none"))
    if not r["done"]:
        print("the run has no final done row: it did not finish")
    print(r["verdict"].upper())


def main(argv):
    if argv[1:] == ["--planned"]:
        print(" ".join(PLANNED))
        return 0
    if len(argv) != 2 or not os.path.isdir(argv[1]):
        print("usage: summarize.py RUN_DIR", file=sys.stderr)
        return 2
    try:
        with open(os.path.join(argv[1], "results.jsonl"), encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError as e:
        print("summarize: cannot read results.jsonl: %s" % e, file=sys.stderr)
        return 2
    order, rows, bad = parse(lines)
    rows = complete(rows, bad)
    r = reading(rows)
    report(argv[1], rows, order, r)
    return {"pass": 0, "fail": 1, "incomplete": 3}[r["verdict"]]


if __name__ == "__main__":
    sys.exit(main(sys.argv))
