#!/usr/bin/env python3
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# pd_split_options_test.py - tests for the options of scripts/pd_split.py
# (--slot-file, --json, --label-prefill, --label-decode) against two fake
# llama-servers on 127.0.0.1.
"""Tests for the options of scripts/pd_split.py.

A fake llama-server (http.server on 127.0.0.1, ephemeral port) answers
/completion and /slots/0?action=erase|save|restore with canned JSON shaped like
the real server, and records every request it receives.  pd_split.py is then
run as a subprocess against two such fakes (prefill and decode) and the
recorded requests and the printed output are checked.

Run with: python3 tests/pd_split_options_test.py -v
"""
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
SCRIPT = os.path.join(REPO, "scripts", "pd_split.py")

# Scratch inside the repository (tmp/ is git-ignored), never in the system
# temporary directory.
TMPROOT = os.path.join(REPO, "tmp")
os.makedirs(TMPROOT, exist_ok=True)

# Canned outputs.  The split run and the decode-server-alone run agree; the
# prefill-server-alone run differs at index DIFF_INDEX ("A" vs "X").
SPLIT_TEXT = "Prefill on A, decode on B."
DECODE_ALONE_TEXT = "Prefill on A, decode on B."
PREFILL_ALONE_TEXT = "Prefill on X, decode on B."
PREFILL_ONLY_TEXT = ""          # n_predict 0: nothing generated
DIFF_INDEX = 11                 # "Prefill on " is 11 characters

TIMINGS = {
    "prompt_n": 2000,
    "prompt_ms": 500.0,
    "prompt_per_second": 4000.0,
    "predicted_n": 12,
    "predicted_ms": 100.0,
    "predicted_per_second": 120.0,
}


def free_port():
    """A port nothing is listening on (bind, then release)."""
    s = socket.socket()
    try:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]
    finally:
        s.close()


class FakeLlama:
    """A canned llama-server that records every request it receives."""

    def __init__(self, completion_texts):
        self.completion_texts = list(completion_texts)
        self.requests = []
        self.fail_actions = set()
        self._lock = threading.Lock()
        self._n_completion = 0
        self._httpd = ThreadingHTTPServer(("127.0.0.1", 0), _handler_for(self))
        self._httpd.daemon_threads = True
        self.port = self._httpd.server_address[1]
        self._thread = threading.Thread(target=self._httpd.serve_forever,
                                        daemon=True)
        self._thread.start()

    @property
    def url(self):
        return "http://127.0.0.1:%d" % self.port

    def stop(self):
        self._httpd.shutdown()
        self._httpd.server_close()
        self._thread.join(timeout=5)

    def respond(self, path, query, body):
        """Return (http status, payload) for one request."""
        action = parse_qs(query).get("action", [""])[0]
        if path == "/completion":
            with self._lock:
                index = self._n_completion
                self._n_completion += 1
            if index < len(self.completion_texts):
                text = self.completion_texts[index]
            else:
                text = self.completion_texts[-1]
            return 200, {"content": text, "timings": dict(TIMINGS)}
        if path == "/slots/0":
            if action in self.fail_actions:
                return 500, {"error": "injected failure"}
            if action == "erase":
                return 200, {"n_erased": 1}
            if action == "save":
                return 200, {"n_saved": 2000, "n_written": 4096,
                             "timings": {"save_ms": 25.0}}
            if action == "restore":
                return 200, {"n_restored": 2000,
                             "timings": {"restore_ms": 18.0}}
            return 200, {}
        return 404, {"error": "not found"}


def _handler_for(fake):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args):
            pass                                   # keep the test output clean

        def do_POST(self):
            length = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(length) if length else b""
            try:
                body = json.loads(raw.decode("utf-8") or "{}")
            except ValueError:
                body = {"_raw": raw.decode("utf-8", "replace")}
            path, _, query = self.path.partition("?")
            with fake._lock:
                fake.requests.append({"path": path, "query": query,
                                      "body": body})
            status, payload = fake.respond(path, query, body)
            data = json.dumps(payload).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    return Handler


class PdSplitTest(unittest.TestCase):

    def setUp(self):
        self.prefill = FakeLlama([PREFILL_ONLY_TEXT, PREFILL_ALONE_TEXT])
        self.decode = FakeLlama([SPLIT_TEXT, DECODE_ALONE_TEXT])
        self.addCleanup(self.prefill.stop)
        self.addCleanup(self.decode.stop)

    # -- helpers ---------------------------------------------------------
    def run_pd(self, *args):
        return subprocess.run([sys.executable, SCRIPT] + list(args),
                              capture_output=True, text=True, timeout=120,
                              cwd=HERE)

    @staticmethod
    def actions(fake):
        """The request sequence, as 'erase'/'save'/'restore'/'completion'."""
        out = []
        for r in fake.requests:
            if r["path"] == "/completion":
                out.append("completion")
            elif r["path"] == "/slots/0":
                out.append(parse_qs(r["query"]).get("action", [""])[0])
            else:
                out.append(r["path"])
        return out

    @staticmethod
    def completions(fake):
        return [r for r in fake.requests if r["path"] == "/completion"]

    @staticmethod
    def slot_filenames(fake, action):
        out = []
        for r in fake.requests:
            if r["path"] != "/slots/0":
                continue
            if parse_qs(r["query"]).get("action", [""])[0] == action:
                out.append(r["body"].get("filename"))
        return out

    # -- tests ------------------------------------------------------------
    def test_request_order_on_both_servers(self):
        p = self.run_pd(self.prefill.url, self.decode.url, "32",
                        "--slot-file", "my-slot.bin")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.actions(self.prefill),
                         ["erase", "completion", "save", "erase", "completion"])
        self.assertEqual(self.actions(self.decode),
                         ["erase", "restore", "completion", "erase",
                          "completion"])
        # the prefill-only completion asks for no tokens, the rest ask for N
        self.assertEqual([r["body"]["n_predict"]
                          for r in self.completions(self.prefill)], [0, 32])
        self.assertEqual([r["body"]["n_predict"]
                          for r in self.completions(self.decode)], [32, 32])

    def test_request_bodies_are_unchanged(self):
        p = self.run_pd(self.prefill.url, self.decode.url, "16")
        self.assertEqual(p.returncode, 0, p.stderr)
        for r in self.completions(self.prefill) + self.completions(self.decode):
            self.assertEqual(r["body"]["temperature"], 0)
            self.assertEqual(r["body"]["seed"], 1)
            self.assertEqual(r["body"]["id_slot"], 0)
            self.assertIs(r["body"]["cache_prompt"], True)
            self.assertIn("prompt", r["body"])

    def test_slot_file_name_is_taken_from_the_option(self):
        p = self.run_pd(self.prefill.url, self.decode.url, "32",
                        "--slot-file", "my-slot.bin")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.slot_filenames(self.prefill, "save"),
                         ["my-slot.bin"])
        self.assertEqual(self.slot_filenames(self.decode, "restore"),
                         ["my-slot.bin"])

    def test_comparison_lines_and_first_difference(self):
        p = self.run_pd(self.prefill.url, self.decode.url, "32")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("split == decode-server-alone: True", p.stdout)
        self.assertIn("split == prefill-server-alone: False", p.stdout)
        # all three outputs are printed under their own header
        self.assertIn("--- split ---", p.stdout)
        self.assertIn("--- prefill-server-alone ---", p.stdout)
        self.assertIn("--- decode-server-alone ---", p.stdout)
        # the first difference is reported at the index the canned data sets up
        indexes = [int(m) for m in re.findall(r"index (\d+)", p.stdout)]
        self.assertIn(DIFF_INDEX, indexes)
        self.assertIn(repr(SPLIT_TEXT[DIFF_INDEX:]), p.stdout)
        self.assertIn(repr(PREFILL_ALONE_TEXT[DIFF_INDEX:]), p.stdout)

    def test_labels_are_used_in_the_printed_lines(self):
        p = self.run_pd(self.prefill.url, self.decode.url, "16",
                        "--label-prefill", "nodeA", "--label-decode", "nodeB")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("nodeA", p.stdout)
        self.assertIn("nodeB", p.stdout)

    def test_json_result_file(self):
        with tempfile.TemporaryDirectory(dir=TMPROOT) as tmp:
            path = os.path.join(tmp, "result.json")
            p = self.run_pd(self.prefill.url, self.decode.url, "24",
                            "--slot-file", "slot-42.bin", "--json", path)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertTrue(os.path.exists(path))
            with open(path) as fh:
                data = json.load(fh)
        self.assertEqual(data["prefill_url"], self.prefill.url)
        self.assertEqual(data["decode_url"], self.decode.url)
        self.assertEqual(data["n_predict"], 24)
        self.assertEqual(data["slot_file"], "slot-42.bin")
        self.assertEqual(data["save"]["n_saved"], 2000)
        self.assertEqual(data["save"]["n_written"], 4096)
        self.assertEqual(data["restore"]["n_restored"], 2000)
        self.assertEqual(sorted(data["runs"]),
                         ["decode_alone", "prefill_alone", "prefill_only",
                          "split_decode"])
        self.assertEqual(data["runs"]["prefill_only"]["prompt_n"], 2000)
        self.assertEqual(data["runs"]["split_decode"]["predicted_n"], 12)
        self.assertEqual(sorted(data["outputs"]),
                         ["decode_alone", "prefill_alone", "split"])
        self.assertEqual(data["outputs"]["split"], SPLIT_TEXT)
        self.assertEqual(data["outputs"]["prefill_alone"], PREFILL_ALONE_TEXT)
        self.assertEqual(data["outputs"]["decode_alone"], DECODE_ALONE_TEXT)
        self.assertEqual(data["equal"], {"split_vs_decode_alone": True,
                                         "split_vs_prefill_alone": False})
        self.assertIsInstance(data["split_wall_s"], float)
        self.assertGreater(data["split_wall_s"], 0.0)

    def test_dead_url_gives_one_clean_line_and_exit_1(self):
        dead = "http://127.0.0.1:%d" % free_port()
        p = self.run_pd(dead, self.decode.url)
        self.assertEqual(p.returncode, 1)
        self.assertNotIn("Traceback", p.stderr)
        self.assertIn("pd_split.py: ", p.stderr)
        self.assertIn(dead, p.stderr)
        self.assertIn("/slots/0?action=erase", p.stderr)

    def test_http_error_gives_one_clean_line_and_exit_1(self):
        self.prefill.fail_actions.add("save")
        p = self.run_pd(self.prefill.url, self.decode.url, "16")
        self.assertEqual(p.returncode, 1)
        self.assertNotIn("Traceback", p.stderr)
        self.assertIn("pd_split.py: ", p.stderr)
        self.assertIn("/slots/0?action=save", p.stderr)
        self.assertIn("500", p.stderr)

    def test_non_http_url_is_refused(self):
        # The hardening of the repository version: only http(s) is opened.
        p = self.run_pd("file:///etc/passwd", self.decode.url)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("not an http(s) URL: file:///etc/passwd", p.stderr)
        self.assertEqual(self.prefill.requests, [])
        self.assertEqual(self.decode.requests, [])


class UrlCheckTests(unittest.TestCase):
    """The http(s) check: what it accepts and what it refuses.

    The scheme is case-insensitive (RFC 3986), so "HTTP://host" is an http URL
    and is accepted.  What is refused: a URL whose string changes when it is
    stripped (leading or trailing whitespace), a URL that contains any
    whitespace or control character, a scheme other than http or https after a
    case-insensitive match, a URL without a host, a URL with a query or a
    fragment, a URL whose port is not a number, and a URL that is not ASCII.
    """

    def setUp(self):
        self.prefill = FakeLlama([PREFILL_ONLY_TEXT, PREFILL_ALONE_TEXT])
        self.decode = FakeLlama([SPLIT_TEXT, DECODE_ALONE_TEXT])
        self.addCleanup(self.prefill.stop)
        self.addCleanup(self.decode.stop)

    def run_pd(self, *args):
        return subprocess.run([sys.executable, SCRIPT] + list(args),
                              capture_output=True, text=True, timeout=120,
                              cwd=HERE)

    def assert_refused(self, url):
        """The URL must be refused before a request is made to anybody."""
        p = self.run_pd(url, self.decode.url)
        self.assertNotEqual(p.returncode, 0, p.stdout)
        self.assertIn("not an http(s) URL: ", p.stderr)
        self.assertNotIn("Traceback", p.stderr)
        self.assertEqual(self.prefill.requests, [])
        self.assertEqual(self.decode.requests, [])

    def test_uppercase_scheme_is_accepted(self):
        # RFC 3986: the scheme is case-insensitive, so HTTP:// and HtTp:// are
        # http URLs and the request goes out.
        for scheme in ("HTTP", "HtTp"):
            with self.subTest(scheme=scheme):
                url = scheme + self.prefill.url[len("http"):]
                p = self.run_pd(url, self.decode.url, "8")
                self.assertEqual(p.returncode, 0, p.stderr)
                self.assertTrue(self.prefill.requests)
                self.assertTrue(self.decode.requests)

    def test_leading_space_is_refused(self):
        # The string changes when it is stripped, and urllib would strip it
        # again in Request.full_url: the request would go out under a URL that
        # was never validated as written.
        self.assert_refused(" " + self.prefill.url)

    def test_trailing_space_is_refused(self):
        self.assert_refused(self.prefill.url + " ")

    def test_tab_inside_the_url_is_refused(self):
        # urlsplit removes the tab before it looks at the URL, so the check has
        # to look at the string itself.
        self.assert_refused(self.prefill.url + "\t/x")

    def test_newline_inside_the_url_is_refused(self):
        self.assert_refused(self.prefill.url + "\n/x")

    def test_data_scheme_is_refused(self):
        self.assert_refused("data:text/plain,hello")

    def test_file_scheme_with_a_leading_space_is_refused(self):
        self.assert_refused(" file:///etc/passwd")

    def test_url_without_a_host_is_refused(self):
        self.assert_refused("http:///path")

    def test_url_with_a_query_is_refused(self):
        # A query would be sent to the server as part of the request path,
        # where it means something else than the base URL.
        self.assert_refused("http://127.0.0.1:9?x")

    def test_url_with_a_fragment_is_refused(self):
        self.assert_refused("http://127.0.0.1:9#frag")

    def test_url_with_an_empty_query_or_fragment_is_refused(self):
        # urlsplit gives an empty query and fragment for a bare "?" or "#",
        # which is falsy; the API path would still land after them.
        self.assert_refused("http://127.0.0.1:9?")
        self.assert_refused("http://127.0.0.1:9#")

    def test_url_with_an_invalid_port_is_refused(self):
        # The port is read: a port that is not a number is not an http(s)
        # URL, and the error must say so instead of coming from urllib
        # later.
        self.assert_refused("http://127.0.0.1:abc")

    def test_non_ascii_url_is_refused(self):
        # U+200B ZERO WIDTH SPACE is not whitespace, so it survives every
        # other check; the URL is not ASCII either.
        zwsp = chr(0x200B)
        for url in ("http://127.0.0.1:9" + zwsp, "http://127.0.0.1:9/" + zwsp):
            with self.subTest(url=url):
                self.assert_refused(url)


if __name__ == "__main__":
    unittest.main()
