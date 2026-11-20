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
Prints the timings each server reports and the generated text, and the same
generation done entirely on each server for comparison.

Both servers must be started with --slot-save-path naming the same directory
(the slot file is written by one and read by the other), with the same model
and the same context size, and with one slot (-np 1). Slot 0 of each server is
erased first and used for every request. See docs/llm.md.
"""
import json
import sys
import time
import urllib.parse
import urllib.request

if len(sys.argv) < 3:
    sys.exit("usage: pd_split.py PREFILL_URL DECODE_URL [N_PREDICT]")
PREFILL, DECODE = sys.argv[1].rstrip("/"), sys.argv[2].rstrip("/")
for _u in (PREFILL, DECODE):
    # Only http(s) server URLs: urllib would also open file: and other schemes.
    if urllib.parse.urlsplit(_u).scheme not in ("http", "https"):
        sys.exit(f"pd_split.py: not an http(s) URL: {_u}")
N = int(sys.argv[3]) if len(sys.argv) > 3 else 128
SLOT_FILE = "pd-slot.bin"

# A long prompt (about 2000 tokens) so prefill dominates.
para = ("FreeBSD on the Ampere Altra maps PCIe write-combining memory as Device "
        "for the kernel and Normal Non-cacheable for user processes, because the "
        "root complex mishandles writes with discontiguous byte enables. ")
PROMPT = ("<|begin_of_text|><|start_header_id|>user<|end_header_id|>\n\n"
          + para * 45 + "\nSummarise the text above in three sentences."
          "<|eot_id|><|start_header_id|>assistant<|end_header_id|>\n\n")


def post(url, path, body):
    req = urllib.request.Request(url + path, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    # The scheme is checked to be http(s) at startup, above.
    with urllib.request.urlopen(req, timeout=600) as r:  # nosec B310 -- http(s) only, checked above  # nosemgrep: dynamic-urllib-use-detected
        return json.load(r)


def complete(url, n):
    return post(url, "/completion", {"prompt": PROMPT, "n_predict": n,
                                     "id_slot": 0, "cache_prompt": True,
                                     "temperature": 0, "seed": 1})


def erase(url):
    post(url, "/slots/0?action=erase", {})


def show(label, r, wall):
    t = r["timings"]
    print(f"{label}: prompt {t['prompt_n']} tok in {t['prompt_ms']:.0f} ms "
          f"({t['prompt_per_second']:.0f} t/s); generated {t['predicted_n']} tok "
          f"in {t['predicted_ms']:.0f} ms ({t['predicted_per_second']:.1f} t/s); "
          f"wall {wall:.2f} s")


for url in (PREFILL, DECODE):
    erase(url)

# 1. Prefill only, on the prefill server, then save the slot.
t0 = time.time()
r = complete(PREFILL, 0)
show("prefill server, prompt only", r, time.time() - t0)
s = post(PREFILL, "/slots/0?action=save", {"filename": SLOT_FILE})
print(f"saved slot: {s.get('n_saved')} tokens, {s.get('n_written')} bytes, "
      f"{s['timings']['save_ms']:.0f} ms")

# 2. Restore on the decode server and generate there.
t0 = time.time()
s = post(DECODE, "/slots/0?action=restore", {"filename": SLOT_FILE})
print(f"restored slot: {s.get('n_restored')} tokens, "
      f"{s['timings']['restore_ms']:.0f} ms")
r = complete(DECODE, N)
split_wall = time.time() - t0
show("decode server, after restore", r, split_wall)
split_text = r["content"]

# 3. Baselines: the whole request on each server, from an empty cache.
base = {}
for name, url in (("prefill server alone", PREFILL), ("decode server alone", DECODE)):
    erase(url)
    t0 = time.time()
    r = complete(url, N)
    show(name, r, time.time() - t0)
    base[name] = r["content"]

print("\nsplit output == decode-server-alone output:",
      split_text == base["decode server alone"])
print("\n--- split output ---\n" + split_text.strip())
