#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# pd_split_test.sh - tests for scripts/pd_split.py against two stub
# llama-servers (a small Python HTTP server on 127.0.0.1, no model needed).
#
# Argument cases:
#   (a) no arguments:                    rc != 0, usage on stderr, no request
#   (b) file: URL as PREFILL_URL:        rc != 0, "not an http(s) URL", no
#                                        request made to either server
#   (c) ftp: URL as DECODE_URL:          rc != 0, refused the same way
# Flow cases (both stubs running):
#   (d) happy path:                      rc 0; the prefill server sees
#                                        erase, prompt-only completion
#                                        (n_predict 0), save of pd-slot.bin;
#                                        the decode server sees erase,
#                                        restore of pd-slot.bin, then a
#                                        completion - restore before it
#   (e) output:                          prints the saved/restored lines and
#                                        "split == decode-server-alone: True";
#                                        each stub answers with its own text,
#                                        so the comparison with the prefill
#                                        server's output is False
#   (f) trailing slash on a URL:         accepted; no "//" in any request
#                                        path
#   (g) --slot-file other.bin:           both stub servers see other.bin in
#                                        the save and in the restore request
#   (h) the option tests:                tests/pd_split_options_test.py (the
#                                        python suite of the new options)
#                                        runs from here and must pass; the
#                                        number of tests that ran is checked
#                                        against a floor, because a suite that
#                                        lost its test cases still exits 0
#   (i) the script is executable:        scripts/pd_split.py keeps its mode
#                                        755 (it has a shebang)
#
# Run: sh tests/pd_split_test.sh

set -eu

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

TESTSDIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$TESTSDIR/.." && pwd)
SCRIPT=$REPO/scripts/pd_split.py
# Scratch inside the repository (tmp/ is git-ignored), not in the system
# temporary directory and not outside the repository.
mkdir -p "$REPO/tmp"
TESTROOT=$(mktemp -d "$REPO/tmp/pd-split-test.XXXXXXXX") || exit 1

PASSED=0
FAILED=0
PIDS=

# cleanup - stop this run's stub servers and remove exactly its test root.
# Time:  O(files created by this test).
# Space: O(1).
cleanup() {
	for p in $PIDS; do
		kill "$p" 2>/dev/null || true
	done
	rm -rf "$TESTROOT"
}
trap cleanup EXIT INT TERM

ok() {
	PASSED=$((PASSED + 1))
	printf 'ok   %s\n' "$1"
}

fail() {
	FAILED=$((FAILED + 1))
	printf 'FAIL %s\n' "$1"
}

# The stub: answers the four llama-server calls pd_split.py makes, logs each
# request as "METHOD RAW-TARGET BODY" to its log file, and writes the port it bound
# (port 0, chosen by the kernel) to its port file.
cat > "$TESTROOT/stub.py" <<'EOF'
import http.server, json, sys
log, portfile, name = sys.argv[1], sys.argv[2], sys.argv[3]

class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n).decode()
        # The raw request target: http.server collapses a leading "//" in
        # self.path, which would hide the double slash case (f) looks for.
        raw = self.requestline.split(" ")[1]
        with open(log, "a") as f:
            f.write(f"POST {raw} {body}\n")
        b = json.loads(body or "{}")
        if self.path.startswith("/completion"):
            t = {"prompt_n": 10, "prompt_ms": 5.0, "prompt_per_second": 2000.0,
                 "predicted_n": b.get("n_predict", 0), "predicted_ms": 1.0,
                 "predicted_per_second": 10.0}
            # Content depends on the server, so (e) can tell which baseline
            # the split output was compared with.
            r = {"content": f"{name} text", "timings": t}
        elif "action=save" in self.path:
            r = {"n_saved": 10, "n_written": 1234, "timings": {"save_ms": 3.0}}
        elif "action=restore" in self.path:
            r = {"n_restored": 10, "timings": {"restore_ms": 2.0}}
        else:
            r = {}
        out = json.dumps(r).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *a):
        pass

s = http.server.HTTPServer(("127.0.0.1", 0), H)
with open(portfile + ".tmp", "w") as f:
    f.write(str(s.server_address[1]))
import os
os.rename(portfile + ".tmp", portfile)
s.serve_forever()
EOF

# start_stub NAME - start one stub server; sets PORT to its port.
# Time:  O(1) plus the wait for the port file (bounded, 10 s).
# Space: O(1).
start_stub() {
	: > "$TESTROOT/$1.log"
	python3 -I "$TESTROOT/stub.py" "$TESTROOT/$1.log" "$TESTROOT/$1.port" "$1" &
	PIDS="$PIDS $!"
	i=0
	while [ ! -s "$TESTROOT/$1.port" ]; do
		i=$((i + 1))
		if [ "$i" -gt 100 ]; then
			echo "stub $1 did not start" >&2
			exit 1
		fi
		sleep 0.1
	done
	PORT=$(cat "$TESTROOT/$1.port")
}

start_stub pre
PRE=http://127.0.0.1:$PORT
start_stub dec
DEC=http://127.0.0.1:$PORT

# (a) no arguments.
rc=0
python3 -I "$SCRIPT" > "$TESTROOT/a.out" 2> "$TESTROOT/a.err" || rc=$?
if [ "$rc" -ne 0 ] && grep -q '^usage: pd_split.py' "$TESTROOT/a.err"; then
	ok "(a) no arguments: usage, rc $rc"
else
	fail "(a) no arguments: rc=$rc stderr=$(cat "$TESTROOT/a.err")"
fi

# (b) file: URL refused before any request.
rc=0
python3 -I "$SCRIPT" file:///etc/passwd "$DEC" 4 \
    > "$TESTROOT/b.out" 2> "$TESTROOT/b.err" || rc=$?
if [ "$rc" -ne 0 ] && grep -q 'not an http(s) URL: file:///etc/passwd' "$TESTROOT/b.err" &&
    [ ! -s "$TESTROOT/pre.log" ] && [ ! -s "$TESTROOT/dec.log" ]; then
	ok "(b) file: URL refused, no request made"
else
	fail "(b) file: URL: rc=$rc stderr=$(cat "$TESTROOT/b.err") requests=$(cat "$TESTROOT/pre.log" "$TESTROOT/dec.log" | wc -l)"
fi

# (c) ftp: URL refused.
rc=0
python3 -I "$SCRIPT" "$PRE" ftp://127.0.0.1/x 4 \
    > "$TESTROOT/c.out" 2> "$TESTROOT/c.err" || rc=$?
if [ "$rc" -ne 0 ] && grep -q 'not an http(s) URL: ftp://' "$TESTROOT/c.err" &&
    [ ! -s "$TESTROOT/pre.log" ] && [ ! -s "$TESTROOT/dec.log" ]; then
	ok "(c) ftp: URL refused, no request made"
else
	fail "(c) ftp: URL: rc=$rc stderr=$(cat "$TESTROOT/c.err")"
fi

# (d), (e), (f): the whole flow, DECODE_URL given with a trailing slash.
rc=0
python3 -I "$SCRIPT" "$PRE" "$DEC/" 4 \
    > "$TESTROOT/d.out" 2> "$TESTROOT/d.err" || rc=$?

# Line numbers of a request in a stub log (first match), 0 if absent.
first() {
	n=$(grep -n -- "$2" "$TESTROOT/$1.log" | head -n 1 | cut -d: -f1)
	echo "${n:-0}"
}

p_erase=$(first pre 'POST /slots/0?action=erase')
p_fill=$(first pre 'POST /completion .*"n_predict": 0')
p_save=$(first pre 'POST /slots/0?action=save {"filename": "pd-slot.bin"}')
d_erase=$(first dec 'POST /slots/0?action=erase')
d_restore=$(first dec 'POST /slots/0?action=restore {"filename": "pd-slot.bin"}')
d_comp=$(first dec 'POST /completion .*"n_predict": 4')
if [ "$rc" -eq 0 ] && [ "$p_erase" -gt 0 ] && [ "$p_fill" -gt "$p_erase" ] &&
    [ "$p_save" -gt "$p_fill" ] && [ "$d_erase" -gt 0 ] &&
    [ "$d_restore" -gt "$d_erase" ] &&
    [ "$d_comp" -gt "$d_restore" ]; then
	ok "(d) flow: erase, prefill, save; restore before decode"
else
	fail "(d) flow: rc=$rc erase=$p_erase fill=$p_fill save=$p_save d_erase=$d_erase restore=$d_restore decode=$d_comp stderr=$(cat "$TESTROOT/d.err")"
fi

if grep -q '^saved slot: 10 tokens, 1234 bytes' "$TESTROOT/d.out" &&
    grep -q '^restored slot: 10 tokens' "$TESTROOT/d.out" &&
    grep -q '^split == decode-server-alone: True$' "$TESTROOT/d.out"; then
	ok "(e) output: save, restore and comparison lines"
else
	fail "(e) output: $(cat "$TESTROOT/d.out")"
fi

if ! grep -q '^POST //' "$TESTROOT/pre.log" "$TESTROOT/dec.log"; then
	ok "(f) trailing slash: no // in request paths"
else
	fail "(f) trailing slash: $(grep '^POST //' "$TESTROOT/dec.log")"
fi

# (g) --slot-file other.bin: the name must reach both stub servers, the
# prefill one in the save request and the decode one in the restore request.
rc=0
python3 -I "$SCRIPT" "$PRE" "$DEC" 4 --slot-file other.bin \
    > "$TESTROOT/g.out" 2> "$TESTROOT/g.err" || rc=$?
p_save_other=$(grep -c 'POST /slots/0?action=save {"filename": "other.bin"}' \
    "$TESTROOT/pre.log" || true)
d_restore_other=$(grep -c 'POST /slots/0?action=restore {"filename": "other.bin"}' \
    "$TESTROOT/dec.log" || true)
if [ "$rc" -eq 0 ] && [ "$p_save_other" -ge 1 ] && [ "$d_restore_other" -ge 1 ]; then
	ok "(g) --slot-file other.bin: both servers see the name"
else
	fail "(g) --slot-file other.bin: rc=$rc saves=$p_save_other restores=$d_restore_other stderr=$(cat "$TESTROOT/g.err")"
fi

# (h) The python suite of the new options (--slot-file, --json, --label-*).
# The floor on the number of tests that ran: a python suite that lost its
# test cases still exits 0 ("Ran 0 tests ... OK"), so the exit code alone
# would keep the gate green over nothing.
MIN_TESTS=22
if TMPDIR="$REPO/tmp" python3 -I "$TESTSDIR/pd_split_options_test.py" -v \
    > "$TESTROOT/h.out" 2>&1; then
	n_ok=$(grep -c '\.\.\. ok$' "$TESTROOT/h.out" || true)
	if [ "$n_ok" -ge "$MIN_TESTS" ]; then
		ok "(h) pd_split_options_test.py: $n_ok tests passed"
	else
		fail "(h) pd_split_options_test.py: only $n_ok tests ran, $MIN_TESTS required"
	fi
else
	fail "(h) pd_split_options_test.py: $(tail -n 25 "$TESTROOT/h.out")"
fi

# (i) The script keeps its executable bit: it has a shebang and is run
# directly.
if [ -x "$SCRIPT" ]; then
	ok "(i) scripts/pd_split.py is executable"
else
	fail "(i) scripts/pd_split.py is not executable"
fi

echo "passed: $PASSED failed: $FAILED"
if [ "$FAILED" -gt 0 ]; then
	exit 1
fi
exit 0
