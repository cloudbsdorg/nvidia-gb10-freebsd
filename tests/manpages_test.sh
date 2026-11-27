#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# manpages_test.sh - the man pages of the user-visible commands pass
# "mandoc -T lint -W warning".
#
# Every command a person runs has a page under man/:
#   man/run-nv-vulkan.sh.1   the Vulkan launcher
#   man/pd_split.py.1        the prefill/decode split client
#   man/bench_compare.py.1   the llama-bench comparison tables
#   man/gpu-check.8           the card check command
#
# Cases:
#   (a) mandoc is installed:      the lint tool is there
#   (b) the pages exist:           all three pages are in the tree
#   (c) every page lints clean:   "mandoc -T lint -W warning" prints nothing
#                                  for each page (no message of WARNING or
#                                  above)
#   (d) the pages name the modes and the options the commands have: every
#       mode word and every option of the --help output is in the page
#
# Run: sh tests/manpages_test.sh

set -eu

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

TESTSDIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$TESTSDIR/.." && pwd)

PASSED=0
FAILED=0

# Scratch inside the repository (tmp/ is git-ignored), not in the system
# temporary directory and not outside the repository.
mkdir -p "$REPO/tmp"
TESTROOT=$(mktemp -d "$REPO/tmp/manpages-test.XXXXXXXX") || exit 1

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

# (a) mandoc is installed.
if command -v mandoc > /dev/null 2>&1; then
	ok "(a) mandoc is installed"
else
	fail "(a) mandoc is not installed"
	printf 'passed: %s failed: %s\n' "$PASSED" "$FAILED"
	exit 1
fi

PAGES="man/run-nv-vulkan.sh.1 man/pd_split.py.1 man/bench_compare.py.1 man/gpu-check.8 man/gpu-check.db.5"

# (b) the pages exist.
missing=
for page in $PAGES; do
	[ -f "$REPO/$page" ] || missing="$missing $page"
done
if [ -z "$missing" ]; then
	ok "(b) the man pages are in the tree"
else
	fail "(b) these man pages are missing:$missing"
fi

# (c) every page lints clean.  "mandoc -T lint -W warning" prints one line
# per message of WARNING or above; a clean page prints nothing.
for page in $PAGES; do
	[ -f "$REPO/$page" ] || continue
	rc=0
	mandoc -T lint -W warning "$REPO/$page" > "$TESTROOT/lint.out" 2>&1 || rc=$?
	if [ "$rc" -eq 0 ] && [ ! -s "$TESTROOT/lint.out" ]; then
		ok "(c) $page: mandoc -T lint -W warning is quiet"
	else
		fail "(c) $page: rc=$rc $(tr '\n' ' ' < "$TESTROOT/lint.out")"
	fi
done

# (d) the pages say what the commands do.  The words are the modes and the
# options of the --help output of each command; a page that lost one of them
# does not describe the command any more.
check_words() {
	_page=$1
	shift
	# A page that is not there is case (b)'s business, not this case's.
	[ -f "$REPO/$_page" ] || return 0
	_got=
	for _word in "$@"; do
		grep -q -w -- "$_word" "$REPO/$_page" 2> /dev/null || _got="$_got $_word"
	done
	if [ -z "$_got" ]; then
		ok "(d) $_page: every mode and option is in the page"
	else
		fail "(d) $_page: these are not in the page:$_got"
	fi
}

check_words man/run-nv-vulkan.sh.1 vulkaninfo list bench server llama-bench rpc
check_words man/bench_compare.py.1 published delta format label-a label-b
check_words man/pd_split.py.1 slot-file json label-prefill label-decode
# The page spells the options the way mdoc does, with one dash.
check_words man/gpu-check.8 -load -assume-loaded -check -list -json -jsonl -report -registry \
	-pciconf-file -fake -capture -device -module-dir -arch
# The page of the database names the tables and the commands that read a run
# back: a page that lost one of them does not describe the database.
check_words man/gpu-check.db.5 events runs properties schema_version history compare export

printf 'passed: %s failed: %s\n' "$PASSED" "$FAILED"
if [ "$FAILED" -gt 0 ]; then
	exit 1
fi
exit 0
