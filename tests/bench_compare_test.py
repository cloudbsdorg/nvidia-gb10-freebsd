#!/usr/bin/env python3
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# bench_compare_test.py - tests for scripts/bench_compare.py (the percentage
# tables of docs/llm.md).
"""Tests for scripts/bench_compare.py.

Every expected value in this file is written by hand: the tests never ask
bench_compare.py to compute the answer they are checking.  bench_compare.py is
exercised through its command line, so the exit codes and the stderr contract
are covered too.

The published reference numbers are in tests/data/published-llama2-7b-q4_0.json
(the numbers other people published for Llama 2 7B Q4_0).  The files next to it
are our own llama-bench runs, kept as fixed data so the expectations of the
tests below do not move: tests/data/nv-linux-b12531-llama-2-7b-q4_0-community.json
(the NVIDIA card, llama.cpp b12531) and the two Ornith 1.5 9B runs used by the
delta mode.

Red/green note: with no scripts/bench_compare.py the import in load_compare()
fails and the command line runs fail, so this module is red before the script
exists and green afterwards.

Run with: python3 tests/bench_compare_test.py -v
"""

import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
SCRIPTS = os.path.join(REPO, "scripts")
DATA = os.path.join(HERE, "data")
COMPARE_PY = os.path.join(SCRIPTS, "bench_compare.py")

# Scratch inside the repository (tmp/ is git-ignored), never in the system
# temporary directory.
TMPROOT = os.path.join(REPO, "tmp")
os.makedirs(TMPROOT, exist_ok=True)

PUBLISHED = os.path.join(DATA, "published-llama2-7b-q4_0.json")
NV_OURS = os.path.join(DATA, "nv-linux-b12531-llama-2-7b-q4_0-community.json")
SPLIT = os.path.join(DATA, "split-amd+nvrpc-Ornith-1.5-9B-Q4_K_M.json")
NATIVE = os.path.join(DATA, "amd-native-b12531-Ornith-1.5-9B-Q4_K_M.json")

# U+2212 MINUS SIGN.  ASCII "-" is what a broken build would print.
MINUS = "\u2212"


def load_compare():
    """Import bench_compare.py.  Raises ImportError while it does not exist."""
    sys.path.insert(0, SCRIPTS)
    import bench_compare

    return bench_compare


def run_cli(*args):
    """Run bench_compare.py and return the CompletedProcess (never a traceback)."""
    return subprocess.run(
        [sys.executable, COMPARE_PY, *args],
        capture_output=True,
        text=True,
        cwd=REPO,
    )


def write_bench(directory, name, entries):
    """Write a llama-bench style JSON file.

    entries is a list of (test, fa, avg_ts, stddev_ts) tuples.
    """
    payload = []
    for test, fa, avg_ts, stddev_ts in entries:
        if test.startswith("pp"):
            n_prompt, n_gen = int(test[2:]), 0
        else:
            n_prompt, n_gen = 0, int(test[2:])
        payload.append(
            {
                "build_commit": "e4b620af1",
                "build_number": 12531,
                "cpu_info": "CPU",
                "gpu_info": "Test GPU",
                "backends": "Vulkan",
                "model_filename": "test-model.gguf",
                "model_type": "test",
                "n_batch": 2048,
                "n_ubatch": 512,
                "n_threads": 64,
                "n_gpu_layers": 99,
                "flash_attn": fa,
                "n_prompt": n_prompt,
                "n_gen": n_gen,
                "avg_ts": avg_ts,
                "stddev_ts": stddev_ts,
            }
        )
    path = os.path.join(directory, name)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2)
    return path


def write_bench_raw(directory, name, entries):
    """Write a llama-bench style JSON file from explicit counters.

    entries is a list of dicts with the keys n_prompt, n_gen, fa, avg_ts and
    stddev_ts.  It is the way to write a row that measures the prompt and the
    generation together (n_prompt > 0 and n_gen > 0), which the tuple form of
    write_bench() cannot express.
    """
    payload = []
    for entry in entries:
        payload.append(
            {
                "build_commit": "e4b620af1",
                "build_number": 12531,
                "cpu_info": "CPU",
                "gpu_info": "Test GPU",
                "backends": "Vulkan",
                "model_filename": "test-model.gguf",
                "model_type": "test",
                "n_batch": 2048,
                "n_ubatch": 512,
                "n_threads": 64,
                "n_gpu_layers": 99,
                "flash_attn": entry["fa"],
                "n_prompt": entry["n_prompt"],
                "n_gen": entry["n_gen"],
                "avg_ts": entry["avg_ts"],
                "stddev_ts": entry["stddev_ts"],
            }
        )
    path = os.path.join(directory, name)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2)
    return path


def write_published(directory, name, rows):
    """Write a published.json style file.

    rows is a list of dicts with card, fa, pp512, tg128, compare and backend.
    A row with "compare": None is written without the key at all, which is how
    the default of the script is exercised.
    """
    payload = {"rows": []}
    for row in rows:
        item = {
            "card": row.get("card", "nv"),
            "gpu": row.get("gpu", "Test GPU"),
            "backend": row.get("backend", "Vulkan"),
            "os": row.get("os", "Linux"),
            "build": row.get("build", "test build"),
            "fa": row.get("fa", 1),
            "pp512": row.get("pp512"),
            "tg128": row.get("tg128"),
            "url": row.get("url", "https://example.invalid/"),
        }
        compare = row.get("compare", True)
        if compare is not None:
            item["compare"] = compare
        payload["rows"].append(item)
    path = os.path.join(directory, name)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2)
    return path


class PercentFormatTests(unittest.TestCase):
    """The percentage string format is the contract other tools read."""

    def test_negative_uses_one_decimal_and_minus_sign(self):
        compare = load_compare()
        self.assertEqual(compare.fmt_pct(-12.44), MINUS + "12.4%")

    def test_positive_carries_a_plus_sign(self):
        compare = load_compare()
        self.assertEqual(compare.fmt_pct(3.06), "+3.1%")

    def test_zero_is_plus_zero(self):
        compare = load_compare()
        self.assertEqual(compare.fmt_pct(0.0), "+0.0%")

    def test_tiny_negative_rounds_to_minus_zero(self):
        # Documented choice: the sign of the number is kept, so a negative
        # value that rounds to zero prints "-0.0%" (U+2212), not "+0.0%".
        compare = load_compare()
        self.assertEqual(compare.fmt_pct(-0.04), MINUS + "0.0%")

    def test_missing_value_is_not_available(self):
        compare = load_compare()
        self.assertEqual(compare.fmt_pct(None), "n/a")

    def test_values_use_two_decimals(self):
        compare = load_compare()
        self.assertEqual(compare.fmt_value(3350.338805), "3350.34")
        self.assertEqual(compare.fmt_ours(3350.338805, 100.906650), "3350.34 " + "\u00b1" + " 100.91")


class PublishedModeTests(unittest.TestCase):
    """published mode: our runs against the published reference numbers."""

    def test_even_count_median(self):
        # 10, 20, 30, 40 -> median 25 (mean happens to be 25 too, so the
        # next test is the one that separates median from mean).
        with tempfile.TemporaryDirectory(dir=TMPROOT) as tmp:
            pub = write_published(
                tmp,
                "published.json",
                [
                    {"pp512": 10.0, "tg128": 10.0},
                    {"pp512": 20.0, "tg128": 20.0},
                    {"pp512": 30.0, "tg128": 30.0},
                    {"pp512": 40.0, "tg128": 40.0},
                ],
            )
            ours = write_bench(tmp, "ours.json", [("pp512", 1, 20.0, 0.5)])
            result = run_cli("published", pub, "nv=" + ours, "--format", "json")
            self.assertEqual(result.returncode, 0, result.stderr)
            rows = json.loads(result.stdout)
            row = rows[0]
            self.assertEqual(row["kind"], "compare")
            self.assertEqual(row["median"], 25.0)
            self.assertEqual(row["min"], 10.0)
            self.assertEqual(row["max"], 40.0)
            self.assertEqual(row["n"], 4)
            self.assertEqual(row["pct"], MINUS + "20.0%")

    def test_median_is_not_the_mean(self):
        # 10, 20, 30, 60 -> median 25, mean 30.  ours 20 is -20.0% of the
        # median and -33.3% of the mean, so this catches a mean mutant.
        with tempfile.TemporaryDirectory(dir=TMPROOT) as tmp:
            pub = write_published(
                tmp,
                "published.json",
                [
                    {"pp512": 10.0, "tg128": 10.0},
                    {"pp512": 20.0, "tg128": 20.0},
                    {"pp512": 30.0, "tg128": 30.0},
                    {"pp512": 60.0, "tg128": 60.0},
                ],
            )
            ours = write_bench(tmp, "ours.json", [("pp512", 1, 20.0, 0.5)])
            result = run_cli("published", pub, "nv=" + ours, "--format", "json")
            self.assertEqual(result.returncode, 0, result.stderr)
            row = json.loads(result.stdout)[0]
            self.assertEqual(row["median"], 25.0)
            self.assertEqual(row["pct"], MINUS + "20.0%")
            self.assertNotEqual(row["pct"], MINUS + "33.3%")

    def test_real_nv_fa1_pp512(self):
        result = run_cli("published", PUBLISHED, "nv=" + NV_OURS, "--format", "json")
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = json.loads(result.stdout)
        main = [row for row in rows if row["kind"] == "compare"]
        row = next(
            row
            for row in main
            if row["card"] == "nv" and row["fa"] == 1 and row["test"] == "pp512"
        )
        self.assertAlmostEqual(row["ours"], 3350.338805, places=6)
        self.assertAlmostEqual(row["ours_stddev"], 100.906650, places=6)
        self.assertAlmostEqual(row["median"], 3848.92, places=6)
        self.assertAlmostEqual(row["min"], 3504.54, places=6)
        self.assertAlmostEqual(row["max"], 3912.65, places=6)
        self.assertEqual(row["n"], 3)
        # (3350.338805 - 3848.92) / 3848.92 * 100 = -12.954...%
        self.assertEqual(row["pct"], MINUS + "13.0%")
        # ASCII hyphen would be the other mutant.
        self.assertNotIn("-", row["pct"])
        self.assertIn(MINUS, row["pct"])
        # ours is the numerator, the median is the denominator.
        self.assertNotEqual(row["pct"], MINUS + "14.9%")

    def test_real_nv_fa1_tg128(self):
        result = run_cli("published", PUBLISHED, "nv=" + NV_OURS, "--format", "json")
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = json.loads(result.stdout)
        row = next(
            row
            for row in rows
            if row["kind"] == "compare"
            and row["card"] == "nv"
            and row["fa"] == 1
            and row["test"] == "tg128"
        )
        self.assertAlmostEqual(row["ours"], 96.958071, places=6)
        self.assertAlmostEqual(row["median"], 95.98, places=6)
        self.assertEqual(row["n"], 3)
        # (96.958071 - 95.98) / 95.98 * 100 = +1.019...%
        self.assertEqual(row["pct"], "+1.0%")

    def test_compare_false_rows_are_reference_only(self):
        result = run_cli("published", PUBLISHED, "nv=" + NV_OURS, "--format", "json")
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = json.loads(result.stdout)
        main = [row for row in rows if row["kind"] == "compare"]
        reference = [row for row in rows if row["kind"] == "reference"]
        # nv ours has fa 0 and fa 1, each with pp512 and tg128.
        self.assertEqual(len(main), 4)
        # Four CUDA rows in published.json (2 fa values x 2 tests).
        self.assertEqual(len(reference), 8)
        cuda = [
            row
            for row in reference
            if row["backend"] == "CUDA"
            and row["card"] == "nv"
            and row["fa"] == 1
            and row["test"] == "pp512"
        ]
        self.assertEqual(len(cuda), 2)
        self.assertEqual(sorted(row["published"] for row in cuda), [4163.39, 4195.53])
        # The CUDA numbers must not have leaked into the median.
        row = next(
            row
            for row in main
            if row["card"] == "nv" and row["fa"] == 1 and row["test"] == "pp512"
        )
        self.assertEqual(row["n"], 3)
        self.assertNotEqual(row["median"], 4195.53)
        self.assertNotEqual(row["median"], 4163.39)
        self.assertNotEqual(row["max"], 4195.53)
        self.assertNotEqual(row["min"], 4163.39)
        # Every reference row carries its own percentage against ours.
        for ref in cuda:
            self.assertTrue(ref["pct"].endswith("%"))
            self.assertNotEqual(ref["pct"], "n/a")

    def test_no_compare_row_gives_empty_median_and_na(self):
        with tempfile.TemporaryDirectory(dir=TMPROOT) as tmp:
            pub = write_published(
                tmp,
                "published.json",
                [{"card": "nv", "fa": 1, "pp512": 100.0, "tg128": 50.0, "compare": False}],
            )
            ours = write_bench(tmp, "ours.json", [("pp512", 1, 20.0, 0.5)])
            result = run_cli("published", pub, "nv=" + ours, "--format", "json")
            self.assertEqual(result.returncode, 0, result.stderr)
            rows = json.loads(result.stdout)
            row = next(row for row in rows if row["kind"] == "compare")
            self.assertIsNone(row["median"])
            self.assertIsNone(row["min"])
            self.assertIsNone(row["max"])
            self.assertEqual(row["pct"], "n/a")
            # The compare=false row is still listed, for reference.
            reference = [row for row in rows if row["kind"] == "reference"]
            self.assertEqual(len(reference), 1)
            self.assertEqual(reference[0]["published"], 100.0)

    def test_same_card_twice_is_labelled_by_file_stem(self):
        with tempfile.TemporaryDirectory(dir=TMPROOT) as tmp:
            pub = write_published(
                tmp, "published.json", [{"card": "nv", "fa": 1, "pp512": 100.0, "tg128": 10.0}]
            )
            first = write_bench(tmp, "build-a.json", [("pp512", 1, 90.0, 0.5)])
            second = write_bench(tmp, "build-b.json", [("pp512", 1, 110.0, 0.5)])
            result = run_cli(
                "published", pub, "nv=" + first, "nv=" + second, "--format", "json"
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            rows = json.loads(result.stdout)
            sources = sorted({row["source"] for row in rows})
            self.assertEqual(sources, ["build-a", "build-b"])
            by_source = {row["source"]: row for row in rows if row["kind"] == "compare"}
            self.assertEqual(by_source["build-a"]["pct"], MINUS + "10.0%")
            self.assertEqual(by_source["build-b"]["pct"], "+10.0%")

    def test_markdown_output_is_a_table(self):
        result = run_cli("published", PUBLISHED, "nv=" + NV_OURS)
        self.assertEqual(result.returncode, 0, result.stderr)
        out = result.stdout
        self.assertIn("| source |", out)
        self.assertIn("median", out)
        self.assertIn("3350.34", out)
        self.assertIn(MINUS + "13.0%", out)
        self.assertIn("Reference only", out)
        self.assertIn("CUDA", out)

    def test_json_output_is_a_list_of_objects(self):
        result = run_cli("published", PUBLISHED, "nv=" + NV_OURS, "--format", "json")
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = json.loads(result.stdout)
        self.assertIsInstance(rows, list)
        self.assertTrue(rows)
        for row in rows:
            self.assertIsInstance(row, dict)
            self.assertIn("kind", row)
            self.assertIn("pct", row)
            self.assertIsInstance(row["pct"], str)
        compare_rows = [row for row in rows if row["kind"] == "compare"]
        self.assertTrue(compare_rows)
        for row in compare_rows:
            self.assertIsInstance(row["ours"], float)
            self.assertIsInstance(row["median"], float)
            self.assertIsInstance(row["n"], int)

    def test_html_output_is_a_table_element_only(self):
        result = run_cli("published", PUBLISHED, "nv=" + NV_OURS, "--format", "html")
        self.assertEqual(result.returncode, 0, result.stderr)
        out = result.stdout
        self.assertIn("<table>", out)
        self.assertIn("<thead>", out)
        self.assertIn("<tbody>", out)
        self.assertNotIn("<html", out)
        self.assertNotIn("<head>", out)
        self.assertIn('class="num"', out)

    def test_html_escapes_less_than_in_a_label(self):
        result = run_cli(
            "delta",
            SPLIT,
            NATIVE,
            "--label-a",
            "a<b&c",
            "--label-b",
            "d>e",
            "--format",
            "html",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        out = result.stdout
        self.assertIn("a&lt;b&amp;c", out)
        self.assertNotIn("a<b&c", out)
        self.assertNotIn("d>e", out)
        self.assertIn("&gt;", out)


class RowNamingTests(unittest.TestCase):
    """A bench row is named from both counters, and a repeated key is refused."""

    def test_combined_row_does_not_replace_the_pure_prefill_row(self):
        # A row that measures the prompt and the generation together
        # (n_prompt > 0 and n_gen > 0) is not a pure prefill row.  It must not
        # take the place of the pure prefill row of the same file, or the
        # percentage is computed from the wrong measurement.
        with tempfile.TemporaryDirectory(dir=TMPROOT) as tmp:
            pub = write_published(
                tmp, "published.json", [{"card": "nv", "fa": 1, "pp512": 100.0}]
            )
            ours = write_bench_raw(
                tmp,
                "ours.json",
                [
                    {"n_prompt": 512, "n_gen": 0, "fa": 1, "avg_ts": 100.0,
                     "stddev_ts": 1.0},
                    {"n_prompt": 512, "n_gen": 128, "fa": 1, "avg_ts": 50.0,
                     "stddev_ts": 1.0},
                ],
            )
            result = run_cli("published", pub, "nv=" + ours, "--format", "json")
            self.assertEqual(result.returncode, 0, result.stderr)
            rows = json.loads(result.stdout)
            main = [row for row in rows if row["kind"] == "compare"]
            # The pure prefill row is the one that is compared with pp512.
            row = next(
                row
                for row in main
                if row["card"] == "nv" and row["fa"] == 1 and row["test"] == "pp512"
            )
            self.assertEqual(row["ours"], 100.0)
            self.assertEqual(row["median"], 100.0)
            self.assertEqual(row["pct"], "+0.0%")
            # The combined row keeps its own name, so it cannot be mistaken
            # for the pure prefill row.
            self.assertNotIn("pp512", [r["test"] for r in main if r["ours"] == 50.0])

    def test_duplicate_test_and_fa_key_is_refused(self):
        # The same key twice in one file: the first row must not disappear
        # without a word.
        with tempfile.TemporaryDirectory(dir=TMPROOT) as tmp:
            ours = write_bench_raw(
                tmp,
                "ours.json",
                [
                    {"n_prompt": 512, "n_gen": 0, "fa": 1, "avg_ts": 100.0,
                     "stddev_ts": 1.0},
                    {"n_prompt": 512, "n_gen": 0, "fa": 1, "avg_ts": 50.0,
                     "stddev_ts": 1.0},
                ],
            )
            pub = write_published(
                tmp, "published.json", [{"card": "nv", "fa": 1, "pp512": 100.0}]
            )
            result = run_cli("published", pub, "nv=" + ours)
            self.assertEqual(result.returncode, 2, result.stdout)
            self.assertTrue(
                result.stderr.startswith("bench_compare.py: "), repr(result.stderr)
            )
            self.assertEqual(len(result.stderr.strip().splitlines()), 1)
            self.assertNotIn("Traceback", result.stderr)
            self.assertIn("duplicate", result.stderr)
            self.assertEqual(result.stdout, "")

    def test_the_combined_row_comes_from_the_pg_test(self):
        # A combined ppNtgM row comes from llama-bench's -pg N,M (the
        # combined prompt-and-generation test), not from -p with -n: -p and
        # -n are the two separate tests (ppN and tgN).
        compare = load_compare()
        self.assertIn("-pg", compare.test_name.__doc__)


class MissingPublishedRowTests(unittest.TestCase):
    """An ours row with no published row is reported on stderr.

    llama-bench's default flash attention is AUTO and it writes that as -1,
    so a default run matches no published fa 0 or fa 1 row.  The row then
    shows an empty median and an "n/a" percentage, which says nothing about
    the run: the warning says which row has no counterpart.
    """

    def test_ours_row_without_a_published_row_warns(self):
        with tempfile.TemporaryDirectory(dir=TMPROOT) as tmp:
            pub = write_published(
                tmp, "published.json", [{"card": "nv", "fa": 1, "pp512": 100.0}]
            )
            # fa -1 is llama-bench's AUTO: the published file has no such row.
            ours = write_bench(tmp, "ours.json", [("pp512", -1, 20.0, 0.5)])
            result = run_cli("published", pub, "nv=" + ours)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("warning", result.stderr)
            self.assertIn("pp512", result.stderr)
            self.assertIn("-1", result.stderr)
            # The row is still in the table, with no median.
            self.assertIn("n/a", result.stdout)

    def test_ours_row_with_a_published_row_does_not_warn(self):
        with tempfile.TemporaryDirectory(dir=TMPROOT) as tmp:
            pub = write_published(
                tmp, "published.json", [{"card": "nv", "fa": 1, "pp512": 100.0}]
            )
            ours = write_bench(tmp, "ours.json", [("pp512", 1, 20.0, 0.5)])
            result = run_cli("published", pub, "nv=" + ours)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn("warning", result.stderr)

    def test_a_reference_only_row_is_still_a_published_row(self):
        # A published row with compare=false is a published row: the ours row
        # is listed under "reference only", it is not missing.
        with tempfile.TemporaryDirectory(dir=TMPROOT) as tmp:
            pub = write_published(
                tmp,
                "published.json",
                [{"card": "nv", "fa": 1, "pp512": 100.0, "compare": False}],
            )
            ours = write_bench(tmp, "ours.json", [("pp512", 1, 20.0, 0.5)])
            result = run_cli("published", pub, "nv=" + ours)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn("warning", result.stderr)
            self.assertIn("Reference only", result.stdout)


class FlashAttentionFlagTests(unittest.TestCase):
    """The flash_attn flag of a bench row is a number, whatever the producer
    wrote: a JSON boolean is 1, not 0."""

    def test_boolean_true_is_one(self):
        with tempfile.TemporaryDirectory(dir=TMPROOT) as tmp:
            path = os.path.join(tmp, "bool.json")
            with open(path, "w", encoding="utf-8") as handle:
                json.dump(
                    [
                        {
                            "n_prompt": 512,
                            "n_gen": 0,
                            "avg_ts": 100.0,
                            "stddev_ts": 1.0,
                            "flash_attn": True,
                        }
                    ],
                    handle,
                )
            pub = write_published(
                tmp, "published.json", [{"card": "nv", "fa": 1, "pp512": 100.0}]
            )
            result = run_cli("published", pub, "nv=" + path, "--format", "json")
            self.assertEqual(result.returncode, 0, result.stderr)
            rows = json.loads(result.stdout)
            main = [row for row in rows if row["kind"] == "compare"]
            self.assertEqual(len(main), 1)
            self.assertEqual(main[0]["fa"], 1)
            self.assertEqual(main[0]["median"], 100.0)
            self.assertEqual(main[0]["pct"], "+0.0%")


class CompareFlagDefaultTests(unittest.TestCase):
    """A published row without a "compare" key is compared (the default)."""

    def test_row_without_compare_key_is_compared(self):
        with tempfile.TemporaryDirectory(dir=TMPROOT) as tmp:
            pub = write_published(
                tmp,
                "published.json",
                [{"card": "nv", "fa": 1, "pp512": 100.0, "compare": None}],
            )
            ours = write_bench(tmp, "ours.json", [("pp512", 1, 100.0, 0.5)])
            result = run_cli("published", pub, "nv=" + ours, "--format", "json")
            self.assertEqual(result.returncode, 0, result.stderr)
            rows = json.loads(result.stdout)
            main = [row for row in rows if row["kind"] == "compare"]
            self.assertEqual(len(main), 1)
            self.assertEqual(main[0]["median"], 100.0)
            self.assertEqual(main[0]["n"], 1)
            self.assertEqual(main[0]["pct"], "+0.0%")
            # It is not a reference only row either.
            self.assertEqual([row for row in rows if row["kind"] == "reference"], [])


class CompareFlagValueTests(unittest.TestCase):
    """The compare flag is a JSON boolean.  Nothing else is a flag."""

    def assert_rejected(self, result):
        self.assertEqual(result.returncode, 2, result.stdout)
        self.assertTrue(
            result.stderr.startswith("bench_compare.py: "), repr(result.stderr)
        )
        self.assertEqual(len(result.stderr.strip().splitlines()), 1, repr(result.stderr))
        self.assertNotIn("Traceback", result.stderr)
        self.assertEqual(result.stdout, "")

    def write_raw_published(self, tmp, item):
        """Write a published file with one row, exactly as it is given."""
        path = os.path.join(tmp, "published.json")
        with open(path, "w", encoding="utf-8") as handle:
            json.dump({"rows": [item]}, handle)
        return path

    def run_with_compare(self, tmp, value):
        pub = self.write_raw_published(
            tmp,
            {"card": "nv", "fa": 1, "pp512": 100.0, "compare": value},
        )
        ours = write_bench(tmp, "ours.json", [("pp512", 1, 20.0, 0.5)])
        return run_cli("published", pub, "nv=" + ours)

    def test_a_string_compare_flag_is_refused(self):
        # "false" is not false: a string is not a flag.
        for value in ("false", "true", "no", ""):
            with self.subTest(value=value):
                with tempfile.TemporaryDirectory(dir=TMPROOT) as tmp:
                    result = self.run_with_compare(tmp, value)
                    self.assert_rejected(result)
                    self.assertIn("compare", result.stderr)

    def test_a_number_compare_flag_is_refused(self):
        # 1 is not true: a number is not a flag.
        for value in (1, 0, 2):
            with self.subTest(value=value):
                with tempfile.TemporaryDirectory(dir=TMPROOT) as tmp:
                    result = self.run_with_compare(tmp, value)
                    self.assert_rejected(result)
                    self.assertIn("compare", result.stderr)

    def test_a_null_compare_flag_is_refused(self):
        # null is not "the key is missing": the key is there and its value is
        # not a boolean.
        with tempfile.TemporaryDirectory(dir=TMPROOT) as tmp:
            result = self.run_with_compare(tmp, None)
            self.assert_rejected(result)
            self.assertIn("compare", result.stderr)

    def test_true_and_false_are_accepted(self):
        with tempfile.TemporaryDirectory(dir=TMPROOT) as tmp:
            result = self.run_with_compare(tmp, True)
            self.assertEqual(result.returncode, 0, result.stderr)
        with tempfile.TemporaryDirectory(dir=TMPROOT) as tmp:
            result = self.run_with_compare(tmp, False)
            self.assertEqual(result.returncode, 0, result.stderr)


class HelpTests(unittest.TestCase):
    """-h and --help print the usage and exit 0."""

    def test_short_help_prints_the_usage(self):
        result = run_cli("-h")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("usage: bench_compare.py", result.stdout)
        self.assertIn("published", result.stdout)
        self.assertIn("delta", result.stdout)

    def test_long_help_prints_the_usage(self):
        result = run_cli("--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("usage: bench_compare.py", result.stdout)

    def test_help_is_not_an_error(self):
        result = run_cli("--help")
        self.assertEqual(result.stderr, "")
        self.assertNotIn("Traceback", result.stderr)


class NonFiniteNumberTests(unittest.TestCase):
    """NaN and Infinity are refused: no table can hold them."""

    def assert_rejected(self, result):
        self.assertEqual(result.returncode, 2, result.stdout)
        self.assertTrue(
            result.stderr.startswith("bench_compare.py: "), repr(result.stderr)
        )
        self.assertEqual(len(result.stderr.strip().splitlines()), 1, repr(result.stderr))
        self.assertNotIn("Traceback", result.stderr)
        self.assertEqual(result.stdout, "")

    def write_raw_bench(self, tmp, rows):
        """Write a bench file with the rows exactly as they are given."""
        path = os.path.join(tmp, "ours.json")
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(rows, handle)
        return path

    def run_with_row(self, tmp, row):
        ours = self.write_raw_bench(tmp, [row])
        pub = write_published(
            tmp, "published.json", [{"card": "nv", "fa": 1, "pp512": 100.0}]
        )
        return run_cli("published", pub, "nv=" + ours)

    def test_nan_avg_ts_is_refused(self):
        with tempfile.TemporaryDirectory(dir=TMPROOT) as tmp:
            result = self.run_with_row(
                tmp,
                {"n_prompt": 512, "n_gen": 0, "avg_ts": float("nan"),
                 "stddev_ts": 1.0, "flash_attn": 1},
            )
            self.assert_rejected(result)
            self.assertIn("avg_ts", result.stderr)

    def test_infinity_avg_ts_is_refused(self):
        with tempfile.TemporaryDirectory(dir=TMPROOT) as tmp:
            result = self.run_with_row(
                tmp,
                {"n_prompt": 512, "n_gen": 0, "avg_ts": float("inf"),
                 "stddev_ts": 1.0, "flash_attn": 1},
            )
            self.assert_rejected(result)
            self.assertIn("avg_ts", result.stderr)

    def test_nan_stddev_ts_is_refused(self):
        with tempfile.TemporaryDirectory(dir=TMPROOT) as tmp:
            result = self.run_with_row(
                tmp,
                {"n_prompt": 512, "n_gen": 0, "avg_ts": 100.0,
                 "stddev_ts": float("nan"), "flash_attn": 1},
            )
            self.assert_rejected(result)
            self.assertIn("stddev_ts", result.stderr)

    def test_nan_n_prompt_is_refused(self):
        with tempfile.TemporaryDirectory(dir=TMPROOT) as tmp:
            result = self.run_with_row(
                tmp,
                {"n_prompt": float("nan"), "n_gen": 0, "avg_ts": 100.0,
                 "stddev_ts": 1.0, "flash_attn": 1},
            )
            self.assert_rejected(result)
            self.assertIn("n_prompt", result.stderr)

    def test_infinity_published_value_is_refused(self):
        with tempfile.TemporaryDirectory(dir=TMPROOT) as tmp:
            pub = write_published(
                tmp, "published.json", [{"card": "nv", "fa": 1, "pp512": 100.0}]
            )
            path = os.path.join(tmp, "published.json")
            with open(path, "w", encoding="utf-8") as handle:
                json.dump(
                    {"rows": [{"card": "nv", "fa": 1, "pp512": float("inf")}]},
                    handle,
                )
            ours = write_bench(tmp, "ours.json", [("pp512", 1, 20.0, 0.5)])
            result = run_cli("published", pub, "nv=" + ours)
            self.assert_rejected(result)
            self.assertIn("pp512", result.stderr)


class CardFileArgumentTests(unittest.TestCase):
    """The CARD=FILE argument: the card is trimmed, the file name is not."""

    def test_file_name_with_a_trailing_space_is_found(self):
        # The file name is a name: trimming it would look for a different
        # file (and report "cannot read" for one that exists).
        with tempfile.TemporaryDirectory(dir=TMPROOT) as tmp:
            pub = write_published(
                tmp, "published.json", [{"card": "nv", "fa": 1, "pp512": 100.0}]
            )
            ours = write_bench(tmp, "ours.json ", [("pp512", 1, 100.0, 0.5)])
            result = run_cli("published", pub, "nv=" + ours, "--format", "json")
            self.assertEqual(result.returncode, 0, result.stderr)
            rows = json.loads(result.stdout)
            main = [row for row in rows if row["kind"] == "compare"]
            self.assertEqual(len(main), 1)
            self.assertEqual(main[0]["median"], 100.0)


class DocsTests(unittest.TestCase):
    """docs/llm.md has to say the same thing the script does."""

    def test_docs_state_the_two_percentages(self):
        with open(os.path.join(REPO, "docs", "llm.md"), encoding="utf-8") as handle:
            doc = handle.read()
        # published mode: (ours - median) / median
        self.assertIn("(ours \u2212 median) / median", doc)
        # delta mode: (a - b) / b, never a median
        self.assertIn("(a \u2212 b) / b", doc)


    def test_docs_name_the_combined_row_after_the_pg_test(self):
        # A combined ppNtgM row comes from llama-bench's -pg N,M, not from
        # -p with -n.
        with open(os.path.join(REPO, "docs", "llm.md"), encoding="utf-8") as handle:
            doc = handle.read()
        self.assertIn("-pg", doc)
        self.assertNotIn("with `-p` and `-n` together", doc)


class DeltaModeTests(unittest.TestCase):
    """delta mode: two of our own runs against each other."""

    def test_split_against_native(self):
        result = run_cli("delta", SPLIT, NATIVE, "--format", "json")
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = json.loads(result.stdout)

        # The two tg128 numbers, read from the files by this test.
        with open(SPLIT, "r", encoding="utf-8") as handle:
            split_rows = json.load(handle)
        with open(NATIVE, "r", encoding="utf-8") as handle:
            native_rows = json.load(handle)

        def tg128(rows):
            for row in rows:
                if row["n_prompt"] == 0 and row["n_gen"] == 128:
                    return row["avg_ts"]
            raise AssertionError("no tg128 row")

        a_value = tg128(split_rows)
        b_value = tg128(native_rows)
        self.assertEqual(a_value, 45.460031)
        self.assertEqual(b_value, 34.567399)

        # Hand written formula: pct = (a - b) / b * 100.
        pct = (a_value - b_value) / b_value * 100.0
        self.assertAlmostEqual(pct, 31.5112, places=3)
        expected = "+%.1f%%" % pct
        self.assertEqual(expected, "+31.5%")

        row = next(row for row in rows if row["test"] == "tg128")
        self.assertEqual(row["a"], a_value)
        self.assertEqual(row["b"], b_value)
        self.assertEqual(row["pct"], expected)
        self.assertNotIn("-", row["pct"])

        # pp2048 is measured by both runs and has to show up.
        self.assertTrue(any(row["test"] == "pp2048" for row in rows))
        markdown = run_cli("delta", SPLIT, NATIVE)
        self.assertEqual(markdown.returncode, 0, markdown.stderr)
        self.assertIn("pp2048", markdown.stdout)

    def test_key_present_in_one_file_only_is_na(self):
        with tempfile.TemporaryDirectory(dir=TMPROOT) as tmp:
            first = write_bench(tmp, "a.json", [("pp512", 1, 100.0, 0.5)])
            second = write_bench(tmp, "b.json", [("tg128", 1, 50.0, 0.5)])
            result = run_cli("delta", first, second, "--format", "json")
            self.assertEqual(result.returncode, 0, result.stderr)
            rows = json.loads(result.stdout)
            self.assertEqual(len(rows), 2)
            by_test = {row["test"]: row for row in rows}
            self.assertEqual(by_test["pp512"]["a"], 100.0)
            self.assertIsNone(by_test["pp512"]["b"])
            self.assertEqual(by_test["pp512"]["pct"], "n/a")
            self.assertIsNone(by_test["tg128"]["a"])
            self.assertEqual(by_test["tg128"]["b"], 50.0)
            self.assertEqual(by_test["tg128"]["pct"], "n/a")

    def test_labels_default_to_the_file_stems(self):
        result = run_cli("delta", SPLIT, NATIVE, "--format", "json")
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = json.loads(result.stdout)
        self.assertEqual(rows[0]["label_a"], "split-amd+nvrpc-Ornith-1.5-9B-Q4_K_M")
        self.assertEqual(rows[0]["label_b"], "amd-native-b12531-Ornith-1.5-9B-Q4_K_M")


class BadInputTests(unittest.TestCase):
    """Bad input is one stderr line starting with 'bench_compare.py: ' and exit 2."""

    def assert_rejected(self, result):
        self.assertEqual(result.returncode, 2, result.stdout)
        self.assertTrue(
            result.stderr.startswith("bench_compare.py: "), repr(result.stderr)
        )
        self.assertEqual(len(result.stderr.strip().splitlines()), 1, repr(result.stderr))
        self.assertNotIn("Traceback", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_missing_file(self):
        self.assert_rejected(run_cli("published", PUBLISHED, "nv=no-such-file.json"))

    def test_missing_published_file(self):
        self.assert_rejected(run_cli("published", "no-such-published.json", "nv=" + NV_OURS))

    def test_malformed_card_file_argument(self):
        for spec in ("nvfile.json", "=file.json", "nv=", "="):
            with self.subTest(spec=spec):
                self.assert_rejected(run_cli("published", PUBLISHED, spec))

    def test_json_file_that_is_not_a_list(self):
        with tempfile.TemporaryDirectory(dir=TMPROOT) as tmp:
            path = os.path.join(tmp, "notalist.json")
            with open(path, "w", encoding="utf-8") as handle:
                json.dump({"rows": []}, handle)
            self.assert_rejected(run_cli("published", PUBLISHED, "nv=" + path))

    def test_invalid_json(self):
        with tempfile.TemporaryDirectory(dir=TMPROOT) as tmp:
            path = os.path.join(tmp, "broken.json")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write("{not json")
            self.assert_rejected(run_cli("published", PUBLISHED, "nv=" + path))

    def test_unknown_mode(self):
        self.assert_rejected(run_cli("sideways", PUBLISHED))

    def test_unknown_format(self):
        self.assert_rejected(run_cli("published", PUBLISHED, "nv=" + NV_OURS, "--format", "pdf"))


if __name__ == "__main__":
    unittest.main()
