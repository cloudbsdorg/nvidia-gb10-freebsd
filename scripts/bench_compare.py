#!/usr/bin/env python3
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# bench_compare.py - percentage-difference tables for llama-bench JSON
# results (docs/llm.md). Standard library only.
"""bench_compare.py - percentage tables for llama-bench JSON results.

Two modes:

  published PUBLISHED.json CARD=OURS.json [CARD=OURS.json ...] [--format FMT]
      Compare our llama-bench runs against published reference numbers.
      For every CARD=FILE pair, every fa value present in the OURS file and
      every test in (pp512, tg128):

        ours   = avg_ts of the OURS row with that test and fa
        median = median of the published values with the same card and fa
                 whose "compare" flag is true (plus min, max and n)
        pct    = (ours - median) / median * 100

      A bench row is named from both counters: a row that measured the
      prompt only is ppN, a row that measured the generation only is tgN and
      a row that measured both is ppNtgM.  Only pp512 and tg128 are compared
      with the published numbers, so a combined row is never mistaken for a
      pure prefill row.  A file with the same test+fa key twice is refused:
      one of the two rows would disappear without a word.

      Published rows with "compare" false are listed separately as
      "reference only".  They never enter the median; they carry their own
      percentage, computed with the same convention as the main table:
      pct = (ours - reference) / reference * 100, so a positive number always
      means our run is faster than the number it is compared against.
      A published row without a "compare" key at all is compared: only an
      explicit "compare": false keeps a row out of the median.  The flag
      must be a JSON boolean: a string, a number or null is an error, not a
      flag.

      An ours row that has no published row for its card, its test and its
      flash-attention setting is reported on stderr: it is in the table with
      an empty median and an "n/a" percentage, which says nothing about the
      run.  llama-bench's own default flash attention is AUTO, and it writes
      that as -1, which matches no published fa 0 or fa 1 row.

  delta A.json B.json [--label-a X --label-b Y] [--format FMT]
      Compare two of our own runs.  For every test+fa key present in both
      files: pct = (a - b) / b * 100.  Keys present in only one file are
      listed with pct "n/a".

Formats: md (default), json, html.  The percentage string is signed, one
decimal place, uses U+2212 MINUS SIGN for negatives and a plus sign for
positives: -12.44 -> "−12.4%", 3.06 -> "+3.1%", 0 -> "+0.0%".
A negative value that rounds to zero keeps its sign: -0.04 -> "−0.0%".

Standard library only.  Bad input prints one line "bench_compare.py: ..." on
stderr and exits 2; no traceback is ever printed.  A number that is not
finite (NaN, Infinity) is bad input: no table can hold it.  -h and --help
print the usage and exit 0.
"""

from __future__ import annotations

import html
import json
import math
import os
import statistics
import sys
from dataclasses import dataclass, field
from typing import Any

PROGRAM = "bench_compare.py"
TESTS = ("pp512", "tg128")
MINUS = "\u2212"
NA = "n/a"
FORMATS = ("md", "json", "html")


class CompareError(Exception):
    """A user facing error, printed as one 'bench_compare.py: ...' line."""


# --------------------------------------------------------------------------
# formatting
# --------------------------------------------------------------------------


def fmt_pct(value: float | None) -> str:
    """Format a percentage difference.

    Signed, one decimal place, U+2212 MINUS SIGN for negatives, a plus sign
    for positives, then "%".  None becomes "n/a".
    """
    if value is None:
        return NA
    text = f"{value:+.1f}"
    if text.startswith("-"):
        text = MINUS + text[1:]
    return text + "%"


def fmt_value(value: float | None) -> str:
    """Format a throughput in t/s with two decimals ("" when missing)."""
    if value is None:
        return ""
    return f"{value:.2f}"


def fmt_ours(value: float | None, stddev: float | None) -> str:
    """Format our own throughput with its standard deviation."""
    if value is None:
        return ""
    text = f"{value:.2f}"
    if stddev is not None:
        text += f" \u00b1 {stddev:.2f}"
    return text


def pct_against(ours: float | None, baseline: float | None) -> float | None:
    """Percentage difference of ours against a baseline (None when unusable)."""
    if ours is None or baseline is None or baseline == 0:
        return None
    return (ours - baseline) / baseline * 100.0


# --------------------------------------------------------------------------
# input
# --------------------------------------------------------------------------


def read_json(path: str, what: str) -> Any:
    """Read one JSON file, turning every failure into a CompareError."""
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError:
        raise CompareError(f"{what}: no such file: {path}") from None
    except IsADirectoryError:
        raise CompareError(f"{what}: not a file: {path}") from None
    except OSError as exc:
        raise CompareError(f"{what}: cannot read {path}: {exc.strerror}") from None
    except UnicodeDecodeError:
        raise CompareError(f"{what}: not UTF-8 text: {path}") from None
    except json.JSONDecodeError as exc:
        raise CompareError(
            f"{what}: invalid JSON in {path}: {exc.msg} (line {exc.lineno})"
        ) from None


def as_int(value: Any, default: int = 0, what: str = "number") -> int:
    if isinstance(value, bool):
        # A JSON true/false is 1/0, not "not a number": a producer that
        # writes the flag as a boolean still means flash attention on.
        return int(value)
    if value is None:
        return default
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        if not math.isfinite(value):
            raise CompareError(f"{what}: not a finite number: {value}")
        return int(value)
    if isinstance(value, str):
        try:
            return int(value.strip())
        except ValueError:
            return default
    return default


def as_float(value: Any, what: str = "number") -> float | None:
    if isinstance(value, bool) or value is None:
        return None
    if isinstance(value, (int, float)):
        try:
            number = float(value)
        except OverflowError:
            raise CompareError(f"{what}: not a finite number: {value}") from None
        if not math.isfinite(number):
            raise CompareError(f"{what}: not a finite number: {value}")
        return number
    if isinstance(value, str):
        try:
            number = float(value.strip())
        except ValueError:
            return None
        if not math.isfinite(number):
            raise CompareError(f"{what}: not a finite number: {value}")
        return number
    return None


def label_of(path: str) -> str:
    """The label of a run: the file name without its .json extension."""
    return os.path.splitext(os.path.basename(path))[0]


@dataclass(frozen=True)
class BenchRow:
    """One measured llama-bench row."""

    test: str
    fa: int
    avg_ts: float
    stddev_ts: float | None
    build_number: str
    build_commit: str
    backends: str
    gpu_info: str
    model_filename: str


def test_name(n_prompt: int, n_gen: int) -> str:
    """The name of a bench row, from both counters.

    A row that measured the prompt only is ppN, a row that measured the
    generation only is tgN, and a row that measured both is ppNtgM.  The
    combined row comes from llama-bench's -pg N,M (the combined
    prompt-and-generation test), not from -p with -n: -p and -n are the two
    separate tests, ppN and tgN.  The combined row is not a pure prefill
    row, so it must not take the name of one.
    """
    if n_prompt > 0 and n_gen > 0:
        return f"pp{n_prompt}tg{n_gen}"
    if n_prompt > 0:
        return f"pp{n_prompt}"
    return f"tg{n_gen}"


def bench_rows(path: str) -> list[BenchRow]:
    """Load a llama-bench -o json file (a list of objects)."""
    data = read_json(path, "bench file")
    if not isinstance(data, list):
        raise CompareError(f"bench file is not a JSON list: {path}")
    rows: list[BenchRow] = []
    seen: set[tuple[str, int]] = set()
    for index, item in enumerate(data):
        if not isinstance(item, dict):
            raise CompareError(f"bench file entry {index} is not an object: {path}")
        where = f"bench file entry {index}"
        n_prompt = as_int(item.get("n_prompt"), 0, f"{where}: n_prompt")
        n_gen = as_int(item.get("n_gen"), 0, f"{where}: n_gen")
        test = test_name(n_prompt, n_gen)
        fa = as_int(item.get("flash_attn"), 0, f"{where}: flash_attn")
        avg_ts = as_float(item.get("avg_ts"), f"{where}: avg_ts")
        if avg_ts is None:
            raise CompareError(f"{where} has no avg_ts: {path}")
        # A repeated test+fa key would silently drop one of the two rows, so
        # the percentage would be computed from the wrong measurement.
        key = (test, fa)
        if key in seen:
            raise CompareError(
                f"bench file has a duplicate test+fa key: {test} (fa {fa}): {path}"
            )
        seen.add(key)
        rows.append(
            BenchRow(
                test=test,
                fa=fa,
                avg_ts=avg_ts,
                stddev_ts=as_float(item.get("stddev_ts"), f"{where}: stddev_ts"),
                build_number=str(item.get("build_number", "")),
                build_commit=str(item.get("build_commit", "")),
                backends=str(item.get("backends", "")),
                gpu_info=str(item.get("gpu_info", "")),
                model_filename=str(item.get("model_filename", "")),
            )
        )
    return rows


@dataclass(frozen=True)
class PublishedRow:
    """One published reference row."""

    card: str
    gpu: str
    backend: str
    os: str
    build: str
    fa: int
    values: dict[str, float] = field(default_factory=dict)
    compare: bool = True
    url: str = ""


def compare_flag(item: dict[str, Any], index: int) -> bool:
    """The compare flag of a published row.

    A missing key means the row is compared.  The value must be a JSON
    boolean: a string, a number or null is a mistake in the file, and
    reading it as false would move the row out of the median without a
    word.
    """
    if "compare" not in item:
        return True
    value = item["compare"]
    if not isinstance(value, bool):
        raise CompareError(
            f"published row {index}: the compare flag must be true or false: {value!r}"
        )
    return value


def published_rows(path: str) -> list[PublishedRow]:
    """Load a published.json file (an object with a "rows" list)."""
    data = read_json(path, "published file")
    if not isinstance(data, dict):
        raise CompareError(f"published file is not a JSON object: {path}")
    raw = data.get("rows")
    if not isinstance(raw, list):
        raise CompareError(f"published file has no 'rows' list: {path}")
    rows: list[PublishedRow] = []
    for index, item in enumerate(raw):
        if not isinstance(item, dict):
            raise CompareError(f"published row {index} is not an object: {path}")
        values: dict[str, float] = {}
        for test in TESTS:
            value = as_float(item.get(test), f"published row {index}: {test}")
            if value is not None:
                values[test] = value
        rows.append(
            PublishedRow(
                card=str(item.get("card", "")),
                gpu=str(item.get("gpu", "")),
                backend=str(item.get("backend", "")),
                os=str(item.get("os", "")),
                build=str(item.get("build", "")),
                fa=as_int(item.get("fa"), 0, f"published row {index}: fa"),
                values=values,
                compare=compare_flag(item, index),
                url=str(item.get("url", "")),
            )
        )
    return rows


# --------------------------------------------------------------------------
# rows
# --------------------------------------------------------------------------


@dataclass
class CompareRow:
    """One of our runs against the published median."""

    source: str
    card: str
    fa: int
    test: str
    ours: float
    ours_stddev: float | None
    median: float | None
    minimum: float | None
    maximum: float | None
    n: int
    pct: float | None
    kind: str = "compare"


@dataclass
class ReferenceRow:
    """A published row that is reference only (compare false)."""

    source: str
    card: str
    fa: int
    test: str
    backend: str
    os: str
    build: str
    gpu: str
    published: float
    pct: float | None
    kind: str = "reference"


@dataclass
class DeltaRow:
    """Two of our own runs against each other."""

    label_a: str
    label_b: str
    test: str
    fa: int
    a: float | None
    b: float | None
    a_stddev: float | None
    b_stddev: float | None
    pct: float | None
    kind: str = "delta"


# --------------------------------------------------------------------------
# published mode
# --------------------------------------------------------------------------


def published_values(
    published: list[PublishedRow],
    card: str,
    fa: int,
    test: str,
) -> list[float]:
    """The published values of one card, fa and test that enter the median.

    Only the rows that are compared (the compare flag is true) and that
    carry a value for this test are used.
    """
    return [
        prow.values[test]
        for prow in published
        if prow.card == card and prow.fa == fa and prow.compare and test in prow.values
    ]


def compare_row(
    source: str,
    card: str,
    fa: int,
    test: str,
    ours: BenchRow,
    values: list[float],
) -> CompareRow:
    """One of our runs against the published median.

    With no published value the row keeps an empty median and no
    percentage: it is in the table, and it says nothing about the run.
    """
    if not values:
        return CompareRow(
            source=source,
            card=card,
            fa=fa,
            test=test,
            ours=ours.avg_ts,
            ours_stddev=ours.stddev_ts,
            median=None,
            minimum=None,
            maximum=None,
            n=0,
            pct=None,
        )
    median = statistics.median(values)
    return CompareRow(
        source=source,
        card=card,
        fa=fa,
        test=test,
        ours=ours.avg_ts,
        ours_stddev=ours.stddev_ts,
        median=median,
        minimum=min(values),
        maximum=max(values),
        n=len(values),
        pct=pct_against(ours.avg_ts, median),
    )


def reference_rows(
    published: list[PublishedRow],
    source: str,
    card: str,
    fa: int,
    test: str,
    ours: BenchRow,
) -> list[ReferenceRow]:
    """The published rows of one card, fa and test that are reference only.

    A row whose compare flag is false never enters the median, but it is
    still reported, with its own percentage.
    """
    rows: list[ReferenceRow] = []
    for prow in published:
        if prow.card != card or prow.fa != fa or prow.compare:
            continue
        if test not in prow.values:
            continue
        rows.append(
            ReferenceRow(
                source=source,
                card=card,
                fa=fa,
                test=test,
                backend=prow.backend,
                os=prow.os,
                build=prow.build,
                gpu=prow.gpu,
                published=prow.values[test],
                pct=pct_against(ours.avg_ts, prow.values[test]),
            )
        )
    return rows


def build_published_rows(
    pairs: list[tuple[str, str, list[BenchRow]]],
    published: list[PublishedRow],
) -> list[CompareRow | ReferenceRow]:
    """Build the compare rows and the reference only rows."""
    rows: list[CompareRow | ReferenceRow] = []
    for card, label, bench in pairs:
        by_key = {(row.test, row.fa): row for row in bench}
        for fa in sorted({row.fa for row in bench}):
            for test in TESTS:
                ours = by_key.get((test, fa))
                if ours is None:
                    continue
                rows.append(
                    compare_row(
                        label,
                        card,
                        fa,
                        test,
                        ours,
                        published_values(published, card, fa, test),
                    )
                )
                rows.extend(reference_rows(published, label, card, fa, test, ours))
    return rows


def missing_published_rows(
    pairs: list[tuple[str, str, list[BenchRow]]],
    published: list[PublishedRow],
) -> list[str]:
    """The ours rows that have no published row for the same card and fa.

    Such a row is in the table with an empty median and an "n/a"
    percentage, which says nothing about the run: the name of the row is
    reported instead.  A published row that is reference only is still a
    published row: the ours row is listed under "reference only".
    """
    missing: list[str] = []
    for card, _label, bench in pairs:
        for row in bench:
            found = any(
                prow.card == card and prow.fa == row.fa and row.test in prow.values
                for prow in published
            )
            if not found:
                missing.append(
                    f"no published row for card {card}, test {row.test}, "
                    f"fa {row.fa}: our row is not compared"
                )
    return missing


# --------------------------------------------------------------------------
# delta mode
# --------------------------------------------------------------------------


def build_delta_rows(
    a_rows: list[BenchRow],
    b_rows: list[BenchRow],
    label_a: str,
    label_b: str,
) -> list[DeltaRow]:
    """Build the delta rows: every test+fa key of either file."""
    a_map = {(row.test, row.fa): row for row in a_rows}
    b_map = {(row.test, row.fa): row for row in b_rows}
    rows: list[DeltaRow] = []
    for test, fa in sorted(set(a_map) | set(b_map)):
        a = a_map.get((test, fa))
        b = b_map.get((test, fa))
        a_value = a.avg_ts if a else None
        b_value = b.avg_ts if b else None
        rows.append(
            DeltaRow(
                label_a=label_a,
                label_b=label_b,
                test=test,
                fa=fa,
                a=a_value,
                b=b_value,
                a_stddev=a.stddev_ts if a else None,
                b_stddev=b.stddev_ts if b else None,
                pct=pct_against(a_value, b_value),
            )
        )
    return rows


# --------------------------------------------------------------------------
# output
# --------------------------------------------------------------------------

COMPARE_HEADER = [
    "source",
    "card",
    "fa",
    "test",
    "ours (t/s)",
    "median (t/s)",
    "min (t/s)",
    "max (t/s)",
    "n",
    "pct vs median",
]
COMPARE_NUMERIC_COLUMNS = (4, 5, 6, 7, 8, 9)

REFERENCE_HEADER = [
    "source",
    "card",
    "fa",
    "test",
    "backend",
    "os",
    "build",
    "published (t/s)",
    "pct vs published",
]
REFERENCE_NUMERIC_COLUMNS = (7, 8)

DELTA_HEADER = ["test", "fa", "a (t/s)", "b (t/s)", "pct"]
DELTA_NUMERIC_COLUMNS = (2, 3, 4)


def md_cell(value: Any) -> str:
    """One Markdown table cell."""
    text = "" if value is None else str(value)
    return text.replace("|", "\\|")


def md_table(header: list[str], body: list[list[Any]]) -> list[str]:
    """A Markdown table as a list of lines."""
    lines = ["| " + " | ".join(md_cell(cell) for cell in header) + " |"]
    lines.append("|" + "|".join("---" for _ in header) + "|")
    for row in body:
        lines.append("| " + " | ".join(md_cell(cell) for cell in row) + " |")
    return lines


def compare_body(rows: list[CompareRow]) -> list[list[Any]]:
    return [
        [
            row.source,
            row.card,
            row.fa,
            row.test,
            fmt_ours(row.ours, row.ours_stddev),
            fmt_value(row.median),
            fmt_value(row.minimum),
            fmt_value(row.maximum),
            row.n if row.n else "",
            fmt_pct(row.pct),
        ]
        for row in rows
    ]


def reference_body(rows: list[ReferenceRow]) -> list[list[Any]]:
    return [
        [
            row.source,
            row.card,
            row.fa,
            row.test,
            row.backend,
            row.os,
            row.build,
            fmt_value(row.published),
            fmt_pct(row.pct),
        ]
        for row in rows
    ]


def delta_body(rows: list[DeltaRow]) -> list[list[Any]]:
    return [
        [row.test, row.fa, fmt_value(row.a), fmt_value(row.b), fmt_pct(row.pct)]
        for row in rows
    ]


def render_md(rows: list[Any]) -> str:
    """Render the rows as Markdown."""
    compare_rows = [row for row in rows if row.kind == "compare"]
    reference_rows = [row for row in rows if row.kind == "reference"]
    delta_rows = [row for row in rows if row.kind == "delta"]

    lines: list[str] = []
    if delta_rows:
        header = [
            "test",
            "fa",
            f"{delta_rows[0].label_a} (t/s)",
            f"{delta_rows[0].label_b} (t/s)",
            "pct",
        ]
        lines.extend(md_table(header, delta_body(delta_rows)))
    else:
        lines.extend(md_table(COMPARE_HEADER, compare_body(compare_rows)))
        if reference_rows:
            lines.append("")
            lines.append("## Reference only")
            lines.append("")
            lines.append(
                "Published rows with compare=false. They are listed for context and "
                "never enter the median."
            )
            lines.append("")
            lines.extend(md_table(REFERENCE_HEADER, reference_body(reference_rows)))
    return "\n".join(lines) + "\n"


def html_table(header: list[str], body: list[list[Any]], numeric: tuple[int, ...]) -> str:
    """One <table> element with escaped values and class="num" on numbers."""
    parts = ["<table>", "<thead><tr>"]
    parts.extend(f"<th>{html.escape(str(cell))}</th>" for cell in header)
    parts.append("</tr></thead>")
    parts.append("<tbody>")
    for row in body:
        parts.append("<tr>")
        for index, cell in enumerate(row):
            css = ' class="num"' if index in numeric else ""
            parts.append(f"<td{css}>{html.escape(str(cell))}</td>")
        parts.append("</tr>")
    parts.append("</tbody>")
    parts.append("</table>")
    return "\n".join(parts)


def render_html(rows: list[Any]) -> str:
    """Render the rows as HTML table elements (no html/head/body wrapper)."""
    compare_rows = [row for row in rows if row.kind == "compare"]
    reference_rows = [row for row in rows if row.kind == "reference"]
    delta_rows = [row for row in rows if row.kind == "delta"]

    tables: list[str] = []
    if delta_rows:
        header = [
            "test",
            "fa",
            f"{delta_rows[0].label_a} (t/s)",
            f"{delta_rows[0].label_b} (t/s)",
            "pct",
        ]
        tables.append(html_table(header, delta_body(delta_rows), DELTA_NUMERIC_COLUMNS))
    else:
        tables.append(
            html_table(COMPARE_HEADER, compare_body(compare_rows), COMPARE_NUMERIC_COLUMNS)
        )
        if reference_rows:
            tables.append(
                html_table(
                    REFERENCE_HEADER, reference_body(reference_rows), REFERENCE_NUMERIC_COLUMNS
                )
            )
    return "\n".join(tables) + "\n"


def render_json(rows: list[Any]) -> str:
    """Render the rows as a JSON list of objects."""
    payload: list[dict[str, Any]] = []
    for row in rows:
        if row.kind == "compare":
            payload.append(
                {
                    "kind": "compare",
                    "source": row.source,
                    "card": row.card,
                    "fa": row.fa,
                    "test": row.test,
                    "ours": row.ours,
                    "ours_stddev": row.ours_stddev,
                    "median": row.median,
                    "min": row.minimum,
                    "max": row.maximum,
                    "n": row.n,
                    "pct": fmt_pct(row.pct),
                    "pct_value": row.pct,
                }
            )
        elif row.kind == "reference":
            payload.append(
                {
                    "kind": "reference",
                    "source": row.source,
                    "card": row.card,
                    "fa": row.fa,
                    "test": row.test,
                    "backend": row.backend,
                    "os": row.os,
                    "build": row.build,
                    "gpu": row.gpu,
                    "published": row.published,
                    "pct": fmt_pct(row.pct),
                    "pct_value": row.pct,
                }
            )
        else:
            payload.append(
                {
                    "kind": "delta",
                    "label_a": row.label_a,
                    "label_b": row.label_b,
                    "test": row.test,
                    "fa": row.fa,
                    "a": row.a,
                    "b": row.b,
                    "a_stddev": row.a_stddev,
                    "b_stddev": row.b_stddev,
                    "pct": fmt_pct(row.pct),
                    "pct_value": row.pct,
                }
            )
    return json.dumps(payload, indent=2, ensure_ascii=False) + "\n"


def render(rows: list[Any], fmt: str) -> str:
    if fmt == "json":
        return render_json(rows)
    if fmt == "html":
        return render_html(rows)
    return render_md(rows)


# --------------------------------------------------------------------------
# command line
# --------------------------------------------------------------------------


USAGE = (
    "usage: bench_compare.py published PUBLISHED.json CARD=OURS.json\n"
    "                          [CARD=OURS.json ...] [--format md|json|html]\n"
    "       bench_compare.py delta A.json B.json [--label-a X --label-b Y]\n"
    "                          [--format md|json|html]\n"
    "       bench_compare.py -h | --help"
)


class HelpRequested(Exception):
    """The user asked for the usage: print it and stop."""


def option_value(argv: list[str], index: int, message: str) -> str:
    """The value of an option: the argument that follows it.

    The message says what the option needs, and it is printed when the
    value is missing.
    """
    if index + 1 >= len(argv):
        raise CompareError(message)
    return argv[index + 1]


def parse_option(
    argv: list[str],
    index: int,
    fmt: str,
    labels: dict[str, str],
) -> tuple[int, str]:
    """Handle one option: return the next index and the format.

    An option that needs a value takes the argument that follows it; an
    option with an "=" carries its value with it.  The labels are added
    to the dict.
    """
    arg = argv[index]
    if arg in ("-h", "--help"):
        raise HelpRequested()
    if arg == "--format":
        value = option_value(argv, index, "--format needs a value: md, json or html")
        return index + 2, value
    if arg.startswith("--format="):
        return index + 1, arg.split("=", 1)[1]
    if arg in ("--label-a", "--label-b"):
        labels[arg] = option_value(argv, index, f"{arg} needs a value")
        return index + 2, fmt
    if arg.startswith("--label-a="):
        labels["--label-a"] = arg.split("=", 1)[1]
        return index + 1, fmt
    if arg.startswith("--label-b="):
        labels["--label-b"] = arg.split("=", 1)[1]
        return index + 1, fmt
    raise CompareError(f"unknown option: {arg}")


def parse_args(argv: list[str]) -> tuple[list[str], str, dict[str, str]]:
    """Split the command line into positional arguments, format and labels."""
    fmt = "md"
    labels: dict[str, str] = {}
    positional: list[str] = []
    index = 0
    while index < len(argv):
        arg = argv[index]
        if arg.startswith("-") and arg != "-":
            index, fmt = parse_option(argv, index, fmt, labels)
        else:
            positional.append(arg)
            index += 1
    if fmt not in FORMATS:
        raise CompareError(f"unknown format: {fmt} (use md, json or html)")
    return positional, fmt, labels


def run_published(args: list[str]) -> list[Any]:
    """published mode."""
    if len(args) < 2:
        raise CompareError(
            "published mode needs PUBLISHED.json and at least one CARD=OURS.json"
        )
    published = published_rows(args[0])
    pairs: list[tuple[str, str, list[BenchRow]]] = []
    for spec in args[1:]:
        if "=" not in spec:
            raise CompareError(f"malformed CARD=FILE argument: {spec}")
        card, _, path = spec.partition("=")
        card = card.strip()
        # The path is a file name: it is not trimmed, or a name with a space
        # at either end would look for a different file.
        if not card or not path:
            raise CompareError(f"malformed CARD=FILE argument: {spec}")
        pairs.append((card, label_of(path), bench_rows(path)))
    # The ours rows that have no published row are reported: they are in the
    # table with an empty median, which says nothing about the run.
    for warning in missing_published_rows(pairs, published):
        sys.stderr.write(f"{PROGRAM}: warning: {warning}\n")
    return build_published_rows(pairs, published)


def run_delta(args: list[str], labels: dict[str, str]) -> list[Any]:
    """delta mode."""
    if len(args) != 2:
        raise CompareError("delta mode needs exactly two bench files: A.json B.json")
    a_path, b_path = args
    a_rows = bench_rows(a_path)
    b_rows = bench_rows(b_path)
    label_a = labels.get("--label-a", label_of(a_path))
    label_b = labels.get("--label-b", label_of(b_path))
    return build_delta_rows(a_rows, b_rows, label_a, label_b)


def run(argv: list[str]) -> str:
    """Run one command and return the text to print."""
    positional, fmt, labels = parse_args(argv)
    if not positional:
        raise CompareError(USAGE)
    mode = positional[0]
    rest = positional[1:]
    if mode == "published":
        rows = run_published(rest)
    elif mode == "delta":
        rows = run_delta(rest, labels)
    else:
        raise CompareError(f"unknown mode: {mode} (expected published or delta)")
    return render(rows, fmt)


def main(argv: list[str]) -> int:
    try:
        sys.stdout.write(run(argv))
    except HelpRequested:
        sys.stdout.write(USAGE + "\n")
        return 0
    except CompareError as exc:
        sys.stderr.write(f"{PROGRAM}: {exc}\n")
        return 2
    except BrokenPipeError:
        return 2
    except Exception as exc:  # never a traceback
        sys.stderr.write(f"{PROGRAM}: {exc}\n")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
