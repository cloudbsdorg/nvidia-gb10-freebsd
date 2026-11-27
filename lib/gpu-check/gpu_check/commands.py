# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# commands.py - the questions a person asks the database afterwards.
#
# A run that is recorded can be read back: what runs there are, what one
# run said, how two runs differ, and what the machine held while it
# ran.  The answers come from the database and take three shapes: the
# table a person reads, the JSON document a machine reads, and the JSON
# Lines stream a program reads.
#
# The document of a run is the document the tool printed when the run
# was made.  The export of a run is those bytes: the record is not a
# second account of the run, it is the same one.
"""The questions asked of the database afterwards."""

import json
import sys

from . import table

# The three shapes an answer takes.
TABLE = "table"
JSON = "json"
JSONL = "jsonl"

# The number of runs the history shows when nothing says otherwise.
DEFAULT_HISTORY = 20

# The gap between the columns of a table.
GAP = "  "


# --- the tables -------------------------------------------------------------

def _pad(text, width):
    """The text, padded to the width."""
    return text + " " * max(0, width - len(text))


def render_table(headers, rows):
    """A table of aligned columns.

    Every column is as wide as its widest cell, and the columns are
    separated by two spaces.  The table is plain text: the same bytes
    every time, whatever the terminal of whoever reads it.
    """
    cells = [[str(cell) for cell in row] for row in rows]
    widths = [len(head) for head in headers]
    for row in cells:
        for index, cell in enumerate(row):
            if index < len(widths):
                widths[index] = max(widths[index], len(cell))
    lines = []
    lines.append(GAP.join(_pad(head, widths[index])
                          for index, head in enumerate(headers)).rstrip())
    for row in cells:
        lines.append(GAP.join(_pad(cell, widths[index])
                              for index, cell in enumerate(row)).rstrip())
    return "\n".join(lines)


def _cell(value, empty="-"):
    """One cell of a table: the value, or a word when there is none."""
    if value is None:
        return empty
    if value is True:
        return "yes"
    if value is False:
        return "no"
    return str(value)


def _counts(checks):
    """The counts of the checks of a run, as a phrase."""
    if not checks:
        return "no checks"
    parts = []
    for status, phrase in table.PHRASES:
        number = checks.get(status, 0)
        if number:
            parts.append("%d %s" % (number, phrase))
    return ", ".join(parts) if parts else "no checks"


def history_table(runs):
    """The table of the runs."""
    rows = []
    for run in runs:
        rows.append([_cell(run.get("id")), _cell(run.get("started_at")),
                     _cell(run.get("ended_at")), _cell(run.get("mode")),
                     _cell(run.get("arch")), _cell(run.get("platform")),
                     _cell(run.get("devices")), _cell(run.get("checks")),
                     _cell(run.get("exit_code")),
                     _cell(run.get("finished"))])
    headers = ["RUN", "STARTED", "ENDED", "MODE", "ARCH", "PLATFORM", "CARDS",
               "CHECKS", "EXIT", "FINISHED"]
    if not rows:
        return "no run is recorded in this database"
    return render_table(headers, rows)


def show_table(document, run_id=None):
    """The table of one run: its facts, and the table of every card."""
    host = document.get("host") or {}
    release = host.get("os_release") or {}
    summary = document.get("summary") or {}
    checks = summary.get("checks") or {}
    lines = []
    lines.append("run %s: %s %s, mode %s, exit %s"
                 % (_cell(run_id),
                    _cell(host.get("os")), _cell(release.get("string")),
                    _cell(document.get("mode")), _cell(document.get("exit"))))
    lines.append("cards %s, supported %s, refused %s, no provider %s; checks: %s"
                 % (_cell(summary.get("devices")), _cell(summary.get("supported")),
                    _cell(summary.get("refused")), _cell(summary.get("no_provider")),
                    _counts(checks)))
    for entry in document.get("devices") or []:
        lines.append("")
        lines.append(entry.get("english") or _cell(entry.get("label")))
        rows = entry.get("checks") or []
        if rows:
            lines.append(table.render(rows))
            lines.append(table.summary(rows))
    return "\n".join(lines)


def compare_table(document):
    """The table of two runs against each other."""
    runs = document.get("runs") or {}
    summary = document.get("summary") or {}
    lines = []
    lines.append("run %s against run %s" % (_cell(runs.get("first")),
                                            _cell(runs.get("second"))))
    checks = document.get("checks") or []
    lines.append("checks that changed: %s" % _cell(summary.get("checks_changed")))
    if checks:
        rows = [[row.get("name"), _cell(row.get("first")), _cell(row.get("second"))]
                for row in checks]
        lines.append(render_table(["CHECK", "FIRST", "SECOND"], rows))
    properties = document.get("properties") or []
    lines.append("properties that changed: %s"
                 % _cell(summary.get("properties_changed")))
    if properties:
        rows = [[row.get("source"), row.get("key"), _cell(row.get("first")),
                 _cell(row.get("second"))] for row in properties]
        lines.append(render_table(["SOURCE", "KEY", "FIRST", "SECOND"], rows))
    if not checks and not properties:
        lines.append("the two runs are the same")
    return "\n".join(lines)


def properties_table(document):
    """The table of the properties of a run."""
    properties = document.get("properties") or []
    if not properties:
        return "this run holds no property"
    rows = []
    for entry in properties:
        values = ", ".join(str(value) for value in entry.get("values") or [])
        rows.append([_cell(entry.get("source")), _cell(entry.get("key")),
                     _cell(entry.get("kind")), _cell(entry.get("classification")),
                     _cell(entry.get("changed")), values])
    return render_table(["SOURCE", "KEY", "KIND", "CLASS", "CHANGED", "VALUES"],
                         rows)


# --- the output -------------------------------------------------------------

def _write(text, stream=None):
    """Write a line of text."""
    out = stream if stream is not None else sys.stdout
    out.write(text + "\n")


def _write_json(document, stream=None):
    """Write a document as JSON: the same bytes the tool prints."""
    out = stream if stream is not None else sys.stdout
    out.write(json.dumps(document, indent=1) + "\n")


def _write_line(record, stream=None):
    """Write one record of a JSON Lines stream."""
    out = stream if stream is not None else sys.stdout
    out.write(json.dumps(record) + "\n")


def _answer(document, mode, text, stream=None):
    """The answer in the shape that was asked for.

    The JSON document of a run is written the way the tool writes it:
    with one space of indent.  The export of a run and the document of a
    live run are then the same bytes.
    """
    if mode == JSON:
        _write_json(document, stream)
    elif mode == JSONL:
        _write_line(document, stream)
    else:
        _write(text, stream)
    return document


# --- the commands -----------------------------------------------------------

def history(database, last=DEFAULT_HISTORY, mode=TABLE, stream=None):
    """The runs that are recorded, the newest first."""
    document = database.history(last)
    if mode == JSONL:
        for run in document.get("runs") or []:
            _write_line(run, stream)
        return document
    return _answer(document, mode, history_table(document.get("runs") or []),
                   stream)


def show(database, run_id, mode=TABLE, stream=None):
    """One run, as the table and as the document."""
    document = database.show(run_id)
    return _answer(document, mode, show_table(document, run_id), stream)


def compare(database, first, second, mode=TABLE, stream=None):
    """Two runs, side by side."""
    document = database.compare(first, second)
    return _answer(document, mode, compare_table(document), stream)


def export(database, run_id, mode=TABLE, stream=None):
    """One run, as the document the tool printed when it was made."""
    document = database.export(run_id)
    if mode == TABLE:
        # The export is the document: it is not a table of its own.
        mode = JSON
    return _answer(document, mode, "", stream)


def properties(database, run_id, changed=False, counters=False, mode=TABLE,
               stream=None):
    """The properties of a run, and the ones that changed."""
    document = database.properties(run_id, changed, counters)
    if mode == JSONL:
        for entry in document.get("properties") or []:
            _write_line(entry, stream)
        return document
    return _answer(document, mode, properties_table(document), stream)
