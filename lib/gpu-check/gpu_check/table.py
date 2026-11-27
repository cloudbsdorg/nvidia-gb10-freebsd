# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# table.py - the table the command prints when a person reads it.
#
# Three columns: the check, its result, and the detail that says why.  A
# detail that does not fit the width of the terminal wraps under its own
# row, so a line of the table is never cut in the middle of a reason.
#
# The colour is for a person at a terminal: when the output is a file, a
# pipe or a test, the table is plain text, and the plain text is the
# same bytes every time.
"""The table of the checks."""

from . import FAIL, NOT_AVAILABLE, NOT_TESTED, PASS

# The width of the table when the terminal does not say: long enough for
# a reason, short enough to read.
DEFAULT_WIDTH = 100

# The smallest width the detail column may have.
MIN_DETAIL = 24

# The phrase each status has in the summary line.
PHRASES = (
    (PASS, "passed"),
    (FAIL, "failed"),
    (NOT_TESTED, "not tested"),
    (NOT_AVAILABLE, "not available"),
)

# The colour of each status, when the output is a terminal.
COLOURS = {
    PASS: "\033[32m",
    FAIL: "\033[31m",
    NOT_TESTED: "\033[33m",
    NOT_AVAILABLE: "\033[36m",
}

RESET = "\033[0m"

HEAD_CHECK = "CHECK"
HEAD_RESULT = "RESULT"
HEAD_DETAIL = "DETAIL"


def use_colour(stream=None):
    """True when the output may carry colour.

    The output of a file, a pipe or a test is plain: the colour is for
    the person who reads it on a terminal.  NO_COLOR says no, whatever
    the terminal is.
    """
    import os
    import sys

    if os.environ.get("NO_COLOR") is not None:
        return False
    if os.environ.get("TERM") == "dumb":
        return False
    stream = stream if stream is not None else sys.stdout
    try:
        return bool(stream.isatty())
    except (AttributeError, ValueError):
        return False


def terminal_width(stream=None):
    """The width of the table.

    The width of the terminal when there is one: the table of a person
    at a terminal fills the screen.  When the output is a file, a pipe
    or a test, the width is the default: the same bytes every time,
    whatever the terminal of whoever runs it.
    """
    import shutil
    import sys

    stream = stream if stream is not None else sys.stdout
    try:
        if not stream.isatty():
            return DEFAULT_WIDTH
    except (AttributeError, ValueError):
        return DEFAULT_WIDTH
    try:
        size = shutil.get_terminal_size((DEFAULT_WIDTH, 24)).columns
    except (OSError, ValueError):
        size = DEFAULT_WIDTH
    return max(size, 40)


def _wrap(text, width):
    """The text in lines of at most this width.

    A word longer than the width is cut: a table that is never wider than
    the terminal is worth more than a word that is not.
    """
    if width < 1:
        width = 1
    lines = []
    for paragraph in text.split("\n"):
        current = ""
        for word in paragraph.split(" "):
            if not current:
                current = word[:width]
                continue
            if len(current) + 1 + len(word) <= width:
                current += " " + word
                continue
            lines.append(current)
            current = word[:width]
        lines.append(current)
    return lines or [""]


def _pad(text, width):
    """The text, padded to the width."""
    return text + " " * max(0, width - len(text))


def summary(rows):
    """The one line that counts the rows.

    The counts that are not zero are said: a run of twelve passes says
    "12 passed", and the counts that are zero are not said again.
    """
    counts = {}
    for row in rows:
        status = row.get("status")
        counts[status] = counts.get(status, 0) + 1
    parts = []
    for status, phrase in PHRASES:
        number = counts.get(status, 0)
        if number:
            parts.append("%d %s" % (number, phrase))
    if not parts:
        return "no checks were run"
    return ", ".join(parts)


def render(rows, colour=False, width=None):
    """The table of the rows, as text.

    The rows are the checks of one card: each one has a name, a status
    and a reason.  The table is the plain text of the run, or the same
    text with colour when the reader is a terminal.
    """
    if width is None:
        width = terminal_width()
    names = [row.get("name", "") for row in rows]
    check_width = max([len(HEAD_CHECK)] + [len(name) for name in names])
    result_width = max([len(HEAD_RESULT)] +
                       [len(row.get("status", "")) for row in rows])
    gap = "  "
    detail_width = max(MIN_DETAIL, width - check_width - result_width - 2 * len(gap))
    lines = []
    header = "%s%s%s%s%s" % (_pad(HEAD_CHECK, check_width), gap,
                             _pad(HEAD_RESULT, result_width), gap, HEAD_DETAIL)
    lines.append(header)
    for row in rows:
        name = row.get("name", "")
        status = row.get("status", "")
        reason = row.get("reason", "")
        detail = _wrap(reason, detail_width)
        first = "%s%s%s%s%s" % (_pad(name, check_width), gap,
                                _pad(status, result_width), gap, detail[0])
        if colour and status in COLOURS:
            first = _colour(first, check_width, result_width, gap, status)
        lines.append(first)
        indent = " " * (check_width + len(gap) + result_width + len(gap))
        for extra in detail[1:]:
            lines.append(indent + extra)
    return "\n".join(lines)


def _colour(line, check_width, result_width, gap, status):
    """The line with the result in colour."""
    code = COLOURS[status]
    start = check_width + len(gap)
    end = start + result_width
    return line[:start] + code + line[start:end] + RESET + line[end:]
