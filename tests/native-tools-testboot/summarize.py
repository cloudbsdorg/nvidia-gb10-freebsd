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
#   - a planned row other than done that records info is an error (a check must give a result);
#   - verdict: fail when native_verdict is fail or the run has no final done row; incomplete when no row failed but a
#     planned row is needs-linux, needs-linuxkpi, not-available or not-run; pass only when every planned row passed.
#     A run that measured little therefore reads incomplete, never pass.
#   - the stream of the tool (gpu-check.jsonl, JSON Lines) is read as it is: the section gpu_check of summary.json
#     holds the checks the tool made and what it said about each of them.  A run without that file says so.
#   - the database of the run (gpu-check.db) is the record of the tool: the section gpu_check is read from it when it
#     is there, because it is the source of truth of the run, and the section says which of the two it was read from
#     ("database" or "stream").  A run without the database is read from the stream, as it was before.
# Exit: 0 pass, 1 fail, 3 incomplete, 2 usage or unreadable input, 4 a crash (the run could not be read).  The last line printed is PASS, FAIL or INCOMPLETE.

import json
import os
import sys

SCHEMA = "native-tools-summary/1"
# The version of the database of the tool this reader knows.  A file that is
# newer than this is refused: the tables may have changed under it.
DB_VERSION = (2, 0, 0)
PLANNED = [
    "deadman", "panic-settings", "linux-enable", "env-before",
    "hash-nvidia_gsp_ga10x_fw.ko", "hash-nvidia.ko", "hash-nvidia-modeset.ko", "hash-nvrm-info", "hash-libnvrm.so.1", "hash-mem_probe", "hash-chan_probe", "ko-native-nvidia", "ko-native-nvidia-modeset",
    "load-nvidia_gsp_ga10x_fw", "load-nvidia", "load-nvidia-modeset", "load", "env-loaded",
    "gpu-node", "gpu-detect-native", "root-open", "gpu-verify", "nvidiactl-open", "modeset-open",
    "gpu-check", "gpu-check-native", "gpu-check-no-new-module", "nvrm-info",
    "uvm-ioctl-suite", "uvm-owner-probe", "uvm-owner-race", "prime-import", "render-uapi", "nvrm-s2-memory", "nvrm-s3-channel",
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
    for name in PLANNED:
        if name in rows and name != "done" and rows[name]["status"] == "info":
            rows[name] = {"status": "error", "detail": "a planned check recorded info, not a result: " + rows[name].get("detail", "")}
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


def read_tool_database(path):
    """The record of the run (gpu-check.db): the checks the tool made and what it said.

    The database is the source of truth of a run: the stream of the tool is made of the same events, so
    the two say the same thing.  The database is read when it is there, because it holds more than the
    stream does (the run, the exit status, the properties of the machine).  A file that is newer than
    this reader knows is refused, and the run falls back to the stream.

    The file is opened read-only: the summary never writes to the record of a run.
    """
    section = {"present": False, "source": "none", "counts": {}, "checks": [], "unreadable": 0}
    try:
        import sqlite3
    except ImportError:
        # no sqlite3 module in this python: the stream is read instead
        return section
    if not os.path.isfile(path):
        return section
    try:
        con = sqlite3.connect("file:%s?mode=ro" % path.replace("?", "%3f"), uri=True)
    except sqlite3.Error:
        return section
    try:
        row = con.execute("SELECT major, minor, patch FROM schema_version WHERE id = 1").fetchone()
        if row is None:
            return section
        if (row[0], row[1], row[2]) > DB_VERSION:
            section["error"] = ("the database is version %d.%d.%d, and this reader knows %d.%d.%d" %
                                (row[0], row[1], row[2], DB_VERSION[0], DB_VERSION[1], DB_VERSION[2]))
            return section
        run = con.execute("SELECT id, exit_code FROM runs ORDER BY id DESC LIMIT 1").fetchone()
        if run is None:
            return section
        section["present"] = True
        section["source"] = "database"
        section["run"] = run[0]
        if isinstance(run[1], int):
            section["exit"] = run[1]
        counts = {}
        for name, status, reason in con.execute(
                "SELECT i.name, k.name, c.reason FROM run_checks c"
                " JOIN check_defs d ON d.id = c.def_id"
                " JOIN check_ids i ON i.id = d.check_id"
                " JOIN result_kinds k ON k.id = c.status_id"
                " WHERE c.run_id = ? ORDER BY c.ordinal", (run[0],)):
            if status not in ("pass", "fail", "not_tested", "not_available"):
                # a status the tool does not write: the reader says so instead of inventing one
                section["unreadable"] += 1
                continue
            counts[status] = counts.get(status, 0) + 1
            section["checks"].append({"name": name or "", "status": status, "reason": reason or ""})
        section["counts"] = counts
    except sqlite3.Error as e:
        section = {"present": False, "source": "none", "counts": {}, "checks": [], "unreadable": 0}
        section["error"] = "the database could not be read: %s" % e
        return section
    finally:
        con.close()
    return section


def read_tool_stream(path):
    """The stream of the tool (gpu-check.jsonl): the checks it made and what it said.

    The stream is JSON Lines: one record per line.  A line that does not parse, and a record that is not a check,
    are counted and left out: the reader says how many it did not understand, so nothing is silently dropped.
    """
    section = {"present": False, "source": "none", "counts": {}, "checks": [], "unreadable": 0}
    try:
        with open(path, encoding="utf-8") as handle:
            lines = handle.read().splitlines()
    except OSError:
        return section
    section["present"] = True
    section["source"] = "stream"
    counts = {}
    for line in lines:
        if not line.strip():
            continue
        try:
            record = json.loads(line)
        except ValueError:
            section["unreadable"] += 1
            continue
        if not isinstance(record, dict):
            section["unreadable"] += 1
            continue
        kind = record.get("kind")
        if kind == "check":
            status = record.get("status")
            if status not in ("pass", "fail", "not_tested", "not_available"):
                # a status the tool does not write: the reader says so instead
                # of inventing one
                section["unreadable"] += 1
                continue
            counts[status] = counts.get(status, 0) + 1
            section["checks"].append({"name": record.get("name") or "",
                                      "status": status,
                                      "reason": record.get("reason") or ""})
        elif kind == "end":
            if isinstance(record.get("exit"), int):
                section["exit"] = record["exit"]
        elif kind == "error":
            section["error"] = record.get("error") or ""
    section["counts"] = counts
    return section


def report(run, rows, order, r, tool):
    counts = {}
    for row in rows.values():
        counts[row["status"]] = counts.get(row["status"], 0) + 1
    names = PLANNED + [n for n in order + list(rows) if n not in PLANNED]
    names = list(dict.fromkeys(names))
    doc = {"schema": SCHEMA, "version": 1, "run": os.path.basename(os.path.normpath(run)),
           "verdict": r["verdict"], "native_verdict": r["native_verdict"], "counts": counts, "planned": PLANNED,
           "native_rows": r["native_rows"], "failed_rows": r["failed_rows"], "skipped_rows": r["skipped_rows"],
           "rows": [dict(name=n, **rows[n]) for n in names], "gpu_check": tool}
    with open(os.path.join(run, "summary.json"), "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=2, sort_keys=True)
        f.write("\n")
    for n in names:
        print("%-15s %-28s %s" % (rows[n]["status"], n, clip(rows[n]["detail"])))
    if tool["present"]:
        _c = tool["counts"]
        print("gpu-check: %d check(s): %s" % (len(tool["checks"]),
                                               ", ".join("%d %s" % (v, k) for k, v in sorted(_c.items())) or "none"))
        print("gpu-check: read from the %s" % (tool.get("source") or "stream"))
        if tool.get("error"):
            print("gpu-check: %s" % tool["error"])
    else:
        print("gpu-check: the run has no stream of the tool (gpu-check.jsonl)")
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
    # The record of the tool is the database of the run when it is there; the
    # stream is what the tool wrote while it ran, and says the same thing.
    tool = read_tool_database(os.path.join(argv[1], "gpu-check.db"))
    if not tool["present"]:
        tool = read_tool_stream(os.path.join(argv[1], "gpu-check.jsonl"))
    report(argv[1], rows, order, r, tool)
    return {"pass": 0, "fail": 1, "incomplete": 3}[r["verdict"]]


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Exception as e:  # a crash is not a verdict: exit 4, and the one-shot writes a FAIL summary
        print("summarize: could not read the run: %s: %s" % (type(e).__name__, e), file=sys.stderr)
        sys.exit(4)
