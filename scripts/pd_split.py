#!/usr/bin/env python3
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# pd_split.py - prefill/decode split across two llama.cpp servers by slot
# save and restore (docs/llm.md). Standard library only.
"""Prefill on one llama-server, decode on another: the prompt's KV cache is
computed by the prefill server, saved to a slot file, restored into the decode
server, and generation continues there without recomputing the prompt.

Usage: pd_split.py PREFILL_URL DECODE_URL [N_PREDICT]
       pd_split.py PREFILL_URL DECODE_URL [N_PREDICT] [--slot-file NAME]
               [--json PATH] [--label-prefill X] [--label-decode Y]

Prints the timings each server reports and the generated text, the same
generation done entirely on each server for comparison, and whether the split
output matches either baseline.  A mismatch is reported with the first
differing character, so a broken split run can be traced.  With --json PATH
the same results are written to a JSON file.

Both servers must be started with --slot-save-path naming the same directory
(the slot file is written by one and read by the other), with the same model
and the same context size, and with one slot (-np 1). Slot 0 of each server is
erased first and used for every request. See docs/llm.md.

The two URLs must be http(s) URLs, written as they are given: the scheme is
matched case-insensitively (HTTP:// is an http URL), but a URL with leading or
trailing whitespace, a URL with a whitespace or control character in it, a URL
that is not ASCII, a URL with another scheme, a URL without a host, a URL with
a query or a fragment and a URL whose port is not a number are refused before
the first request is made.

Options:
  --slot-file NAME    slot file name used by the save and restore requests
                       (default: pd-slot.bin)
  --json PATH         write the results (timings, outputs, comparisons) to
                       this JSON file
  --label-prefill X   label for the prefill server in the printed lines
                       (default: prefill server)
  --label-decode Y    label for the decode server in the printed lines
                       (default: decode server)
"""
import argparse
import json
import socket
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

PROG = "pd_split.py"

# A long prompt (about 2000 tokens) so prefill dominates.
para = ("FreeBSD on the Ampere Altra maps PCIe write-combining memory as Device "
        "for the kernel and Normal Non-cacheable for user processes, because the "
        "root complex mishandles writes with discontiguous byte enables. ")
PROMPT = ("<|begin_of_text|><|start_header_id|>user<|end_header_id|>\n\n"
          + para * 45 + "\nSummarise the text above in three sentences."
          "<|eot_id|><|start_header_id|>assistant<|end_header_id|>\n\n")


class PdError(Exception):
    """A failure that is reported as one line, never as a traceback."""

    def __init__(self, url, reason):
        super().__init__("%s: %s: %s" % (PROG, url, reason))
        self.url = url
        self.reason = reason


def post(url, path, body):
    full = url + path
    req = urllib.request.Request(full, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    try:
        # The scheme is checked to be http(s) at startup, above.
        with urllib.request.urlopen(req, timeout=600) as r:  # nosec B310 -- http(s) only, checked above  # nosemgrep: dynamic-urllib-use-detected
            return json.load(r)
    except urllib.error.HTTPError as e:
        raise PdError(full, "HTTP %d: %s" % (e.code, e.reason)) from None
    except urllib.error.URLError as e:
        raise PdError(full, str(e.reason)) from None
    except (TimeoutError, socket.timeout):
        raise PdError(full, "timed out") from None
    except OSError as e:
        raise PdError(full, str(e)) from None
    except ValueError as e:                 # includes json.JSONDecodeError
        raise PdError(full, "invalid JSON response: %s" % e) from None


def complete(url, n):
    return post(url, "/completion", {"prompt": PROMPT, "n_predict": n,
                                     "id_slot": 0, "cache_prompt": True,
                                     "temperature": 0, "seed": 1})


def erase(url):
    post(url, "/slots/0?action=erase", {})


def _num(timings, key, spec=".0f"):
    """A timing field as text, or '?' when the server did not report it."""
    try:
        return format(float(timings.get(key)), spec)
    except (AttributeError, TypeError, ValueError):
        return "?"


def show(label, r, wall):
    t = r.get("timings") or {}
    print(f"{label}: prompt {t.get('prompt_n', '?')} tok in "
          f"{_num(t, 'prompt_ms')} ms ({_num(t, 'prompt_per_second')} t/s); "
          f"generated {t.get('predicted_n', '?')} tok in "
          f"{_num(t, 'predicted_ms')} ms "
          f"({_num(t, 'predicted_per_second', '.1f')} t/s); "
          f"wall {wall:.2f} s")


def first_diff_index(a, b):
    """Index of the first differing character, or -1 when the texts match."""
    for i in range(min(len(a), len(b))):
        if a[i] != b[i]:
            return i
    if len(a) != len(b):
        return min(len(a), len(b))
    return -1


def report_diff(name, split_text, other_text):
    """Print where the split output and another output start to differ."""
    i = first_diff_index(split_text, other_text)
    if i < 0:
        return
    print(f"first difference (split vs {name}) at index {i}:")
    print(f"  split: {split_text[i:i + 40]!r}")
    print(f"  {name}: {other_text[i:i + 40]!r}")


def refuse_url(url):
    """Refuse a URL that is not an http(s) URL and stop."""
    sys.exit(f"{PROG}: not an http(s) URL: {url}")


def check_url(url):
    """Refuse anything that is not an http(s) URL written as it was given.

    The scheme is matched case-insensitively (RFC 3986), so "HTTP://host" is
    an http URL and is accepted.  What is refused:

      - a URL whose string changes when it is stripped (leading or trailing
        whitespace): urllib strips it again in Request.full_url, so the
        request would go out under a URL that was never validated;
      - a URL that contains any whitespace or control character;
      - a URL that is not ASCII (a zero width space is not whitespace and
        would survive every other check);
      - a scheme other than http or https after the case-insensitive match;
      - a URL without a host;
      - a URL with a query or a fragment: they would be sent to the server
        as part of the request path, where they mean something else;
      - a URL whose port is not a number.

    The string is checked, not the parser's view of it: urlsplit lowercases
    the scheme and removes tabs and newlines before it looks at the URL.
    """
    if url != url.strip():
        refuse_url(url)
    for char in url:
        if char.isspace() or ord(char) < 0x20 or ord(char) == 0x7F:
            refuse_url(url)
    if not url.isascii():
        refuse_url(url)
    try:
        parts = urllib.parse.urlsplit(url)
        # The port is read here: a port that is not a number raises
        # ValueError, and such a URL is not an http(s) URL.
        _port = parts.port
    except ValueError:
        refuse_url(url)
    if parts.scheme.lower() not in ("http", "https"):
        refuse_url(url)
    if not parts.hostname:
        refuse_url(url)
    # An empty "?" or "#" leaves query and fragment empty, so test the
    # string itself: the API path would otherwise land after it.
    if "?" in url or "#" in url:
        refuse_url(url)


def parse_args(argv):
    ap = argparse.ArgumentParser(
        prog=PROG,
        description="Prefill on one llama-server, decode on another.")
    ap.add_argument("prefill_url",
                    help="URL of the llama-server that prefills the prompt")
    ap.add_argument("decode_url",
                    help="URL of the llama-server that decodes the answer")
    ap.add_argument("n_predict", nargs="?", type=int, default=128,
                    help="tokens to generate (default: 128)")
    ap.add_argument("--slot-file", default="pd-slot.bin",
                    help="slot file name used by save and restore "
                         "(default: pd-slot.bin)")
    ap.add_argument("--json", dest="json_path", default=None,
                    help="write the results to this JSON file")
    ap.add_argument("--label-prefill", default="prefill server",
                    help="label for the prefill server in the printed lines")
    ap.add_argument("--label-decode", default="decode server",
                    help="label for the decode server in the printed lines")
    return ap.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    prefill_url = args.prefill_url.rstrip("/")
    decode_url = args.decode_url.rstrip("/")
    n = args.n_predict
    slot_file = args.slot_file
    label_prefill = args.label_prefill
    label_decode = args.label_decode

    # Only http(s) server URLs: urllib would also open file: and other
    # schemes.  The check is on the string as it was given.
    for url in (prefill_url, decode_url):
        check_url(url)

    print(f"{label_prefill}: {prefill_url}")
    print(f"{label_decode}: {decode_url}")

    for url in (prefill_url, decode_url):
        erase(url)

    # 1. Prefill only, on the prefill server, then save the slot.
    t0 = time.time()
    r_prefill_only = complete(prefill_url, 0)
    show(f"{label_prefill}, prompt only", r_prefill_only, time.time() - t0)
    save = post(prefill_url, "/slots/0?action=save", {"filename": slot_file})
    print(f"saved slot: {save.get('n_saved')} tokens, "
          f"{save.get('n_written')} bytes, "
          f"{_num(save.get('timings') or {}, 'save_ms')} ms ({slot_file})")

    # 2. Restore on the decode server and generate there.
    t0 = time.time()
    restore = post(decode_url, "/slots/0?action=restore",
                   {"filename": slot_file})
    print(f"restored slot: {restore.get('n_restored')} tokens, "
          f"{_num(restore.get('timings') or {}, 'restore_ms')} ms ({slot_file})")
    r_split = complete(decode_url, n)
    split_wall = time.time() - t0
    show(f"{label_decode}, after restore", r_split, split_wall)

    # 3. Baselines: the whole request on each server, from an empty cache.
    runs = {"prefill_only": r_prefill_only.get("timings") or {},
            "split_decode": r_split.get("timings") or {}}
    outputs = {"split": r_split.get("content") or ""}
    for key, label, url in (("prefill_alone", f"{label_prefill} alone",
                             prefill_url),
                            ("decode_alone", f"{label_decode} alone",
                             decode_url)):
        erase(url)
        t0 = time.time()
        r = complete(url, n)
        show(label, r, time.time() - t0)
        runs[key] = r.get("timings") or {}
        outputs[key] = r.get("content") or ""

    split_text = outputs["split"]
    prefill_alone = outputs["prefill_alone"]
    decode_alone = outputs["decode_alone"]
    equal_decode = split_text == decode_alone
    equal_prefill = split_text == prefill_alone

    print()
    print("--- split ---")
    print(split_text.strip())
    print("--- prefill-server-alone ---")
    print(prefill_alone.strip())
    print("--- decode-server-alone ---")
    print(decode_alone.strip())
    print()
    print(f"split == decode-server-alone: {equal_decode}")
    print(f"split == prefill-server-alone: {equal_prefill}")
    if not equal_decode:
        report_diff("decode-server-alone", split_text, decode_alone)
    if not equal_prefill:
        report_diff("prefill-server-alone", split_text, prefill_alone)

    if args.json_path:
        result = {
            "prefill_url": prefill_url,
            "decode_url": decode_url,
            "n_predict": n,
            "slot_file": slot_file,
            "save": save,
            "restore": restore,
            "runs": {
                "prefill_only": runs["prefill_only"],
                "split_decode": runs["split_decode"],
                "prefill_alone": runs["prefill_alone"],
                "decode_alone": runs["decode_alone"],
            },
            "outputs": {
                "split": split_text,
                "prefill_alone": prefill_alone,
                "decode_alone": decode_alone,
            },
            "equal": {
                "split_vs_decode_alone": equal_decode,
                "split_vs_prefill_alone": equal_prefill,
            },
            "split_wall_s": split_wall,
        }
        with open(args.json_path, "w") as fh:
            json.dump(result, fh, indent=2, sort_keys=True)
            fh.write("\n")
        print(f"wrote {args.json_path}")

    return 0


def cli(argv=None):
    try:
        return main(argv)
    except PdError as e:
        print(str(e), file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("%s: interrupted" % PROG, file=sys.stderr)
        return 130
    except Exception as e:                  # never show a traceback
        print("%s: %s: %s" % (PROG, type(e).__name__, e), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(cli())
