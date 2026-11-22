#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# bench_compare_test.sh - tests for scripts/bench_compare.py (the percentage
# tables of docs/llm.md).
#
# The tests themselves are python (tests/bench_compare_test.py): they read
# llama-bench JSON files, check the medians, the percentages, the three output
# formats (md, json, html) and the one-line error contract.  This script runs
# that suite and prints the summary in the style of the other tests.
#
# Run: sh tests/bench_compare_test.sh

set -eu

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

TESTSDIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$TESTSDIR/.." && pwd)
PYTEST=$TESTSDIR/bench_compare_test.py
SCRIPT=$REPO/scripts/bench_compare.py

PASSED=0
FAILED=0

# Scratch inside the repository (tmp/ is git-ignored), not in the system
# temporary directory and not outside the repository.
mkdir -p "$REPO/tmp"
TESTROOT=$(mktemp -d "$REPO/tmp/bench-compare-test.XXXXXXXX") || exit 1

# cleanup - remove exactly this run's scratch files on every exit path.
# Time:  O(files created by this test).
# Space: O(1).
cleanup() {
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

if [ ! -f "$SCRIPT" ]; then
	fail "scripts/bench_compare.py does not exist"
	printf 'passed: %s failed: %s\n' "$PASSED" "$FAILED"
	exit 1
fi

# The script keeps its executable bit: it has a shebang and is run directly.
if [ -x "$SCRIPT" ]; then
	ok "scripts/bench_compare.py is executable"
else
	fail "scripts/bench_compare.py is not executable"
fi

# The floor on the number of tests that ran.  A python suite that lost its
# test cases still exits 0 ("Ran 0 tests ... OK"), so the exit code alone
# would keep the gate green over nothing.
MIN_TESTS=50

rc=0
TMPDIR="$TESTROOT" python3 -I "$PYTEST" -v > "$TESTROOT/out" 2>&1 || rc=$?
n_run=$(grep -c '\.\.\. ' "$TESTROOT/out" || true)
n_ok=$(grep -c '\.\.\. ok$' "$TESTROOT/out" || true)
if [ "$rc" -eq 0 ] && [ "$n_run" -ge "$MIN_TESTS" ]; then
	ok "bench_compare_test.py: $n_run tests passed"
elif [ "$rc" -eq 0 ]; then
	fail "bench_compare_test.py: only $n_run tests ran, $MIN_TESTS required"
else
	fail "bench_compare_test.py: $n_ok of $n_run tests passed"
	grep -E '^(FAIL|ERROR):' "$TESTROOT/out" | sed -n '1,20p'
	tail -n 5 "$TESTROOT/out"
fi

printf 'passed: %s failed: %s\n' "$PASSED" "$FAILED"
if [ "$FAILED" -gt 0 ]; then
	exit 1
fi
exit 0
