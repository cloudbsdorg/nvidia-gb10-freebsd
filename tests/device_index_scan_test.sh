#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# device_index_scan_test.sh - fail when the docs, man pages or scripts
# hard-code a GPU device node index (/dev/nvidia0, dri/renderD128, a dmesg
# line "nvidia0: ..."). Device indexes change with slots and driver load
# order; find the node with the hardware-preflight-and-verify skill instead. A line that is an
# example on purpose carries the marker "hw-preflight: example".
#
# The scan() function is first run against tests/data/device-index/sample.txt
# (three unmarked hits, two marked) and must report exactly three; the same
# function then scans the real tree.

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

TESTSDIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$TESTSDIR/.." && pwd)
FIXTURE=$TESTSDIR/data/device-index/sample.txt
RE='/dev/nvidia[0-9]|dri/(card|renderD)[0-9]|(^|[^a-z_/])nvidia[0-9]+:'
MARKER='hw-preflight: example'

# scan FILE... - print file:line:text for each hit without the marker.
# Exit status: 0 hits printed, 1 no hits, 2 grep failed.
# Time:  O(total lines in the files).
# Space: O(hits).
scan() {
	found=$(grep -HnE -e "$RE" -- "$@")
	rc=$?
	[ "$rc" -ge 2 ] && return 2
	[ "$rc" = 1 ] && return 1
	hits=$(printf '%s\n' "$found" | grep -vF -e "$MARKER")
	[ -z "$hits" ] && return 1
	printf '%s\n' "$hits"
	return 0
}

# Self test on the fixture: exactly three unmarked hits.
HITS=$(scan "$FIXTURE")
rc=$?
n=$(printf '%s\n' "$HITS" | grep -c .)
if [ "$rc" != 0 ] || [ "$n" != 3 ]; then
	printf 'FAIL scanner self test: rc %s, %s hits in the fixture, want 3\n' "$rc" "$n"
	exit 1
fi
printf 'ok   scanner self test: 3 unmarked hits in the fixture, marked ones skipped\n'
if printf '%s\n' "$HITS" | grep -qvE 'sample\.txt:[0-9]+:'; then
	printf 'FAIL scanner output on one file lacks file:line prefixes\n'
	exit 1
fi
printf 'ok   scanner output on a single file keeps file:line prefixes\n'

# Real tree: README, docs/*.md, man/*, scripts/*.
set --
for f in "$ROOT"/README.md "$ROOT"/docs/*.md "$ROOT"/man/* "$ROOT"/scripts/*; do
	[ -f "$f" ] && set -- "$@" "$f"
done
if [ "$#" = 0 ]; then
	printf 'FAIL no files found under %s\n' "$ROOT"
	exit 1
fi
HITS=$(scan "$@")
rc=$?
if [ "$rc" = 2 ]; then
	printf 'FAIL grep failed while scanning %s\n' "$ROOT"
	exit 1
fi
if [ "$rc" = 0 ]; then
	printf 'FAIL hard-coded GPU device nodes (file:line, add "%s" if on purpose):\n' "$MARKER"
	printf '%s\n' "$HITS" | sed "s|^$ROOT/||"
	exit 1
fi
printf 'ok   no hard-coded GPU device nodes in %s files\n' "$#"
