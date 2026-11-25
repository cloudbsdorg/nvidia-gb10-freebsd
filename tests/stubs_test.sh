#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# stubs_test.sh - tests for the fail-closed RM core stubs
# (src/gb10-stubs/nv-gb10-stubs.c) and scripts/build-stubs.sh.
#
# Runs against the real prepared trees under ${GB10_WORK:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)/work}
# (the ogkm build copy, the RM core object - nv-kernel-aarch64.o on aarch64
# and nv-kernel-amd64.o on amd64 - and the OS-layer objects), so
# the stubs are compiled with the core's own flags and linked exactly as
# build-stubs.sh does it. Prerequisite: scripts/prepare-tree.sh and
# scripts/build-rmcore.sh have run. Four cases:
#   (a) symbol set: every name in the missing-symbols list committed at
#       tests/data/rmcore-missing-symbols.txt (the 67 names
#       count_missing reported for the RM core object - nv-kernel-aarch64.o
#       on aarch64, nv-kernel-amd64.o on amd64 - against the prepared OS
#       layer on 2026-11-17, when the stubs were written; tracked in the
#       repo so the test does not depend on a dated, untracked diagnostic
#       log in $WORK/logs) is defined (T) in nv-gb10-stubs.o and nothing
#       else is defined there - exactly 67 global T symbols, compared
#       with comm(1)
#   (b) prototype fidelity: compiling with -Werror against the real
#       headers is the check; falsified by compiling a scratch copy whose
#       first bool stub is given a deliberately wrong return type, which
#       must be rejected
#   (c) build-stubs.sh prints "still undefined vs OS layer: 0"
#   (d) a relative GB10_WORK is refused: build-stubs.sh cds into the ogkm
#       copy before it compiles, so a relative work root would break the
#       build and leave a stray directory behind (pass-3 u09 #1)
#
# Run: sh tests/stubs_test.sh

set -eu

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL
# The architecture this run builds for: the RUNNING architecture, so
# build-stubs.sh looks for the RM core object the live tree actually has -
# nv-kernel-amd64.o on amd64, nv-kernel-aarch64.o on aarch64. The pin that
# used to sit here (GB10_TEST_HOOKS=1 with GB10_TEST_ARCH=aarch64, "so
# these cases stay valid on amd64 hosts") forced the aarch64 object on an
# amd64 tree, and the build died with "build-stubs: missing
# .../build/nv-kernel-aarch64.o" while the tree held nv-kernel-amd64.o
# (Track #2475). The hook now carries the running architecture, so it
# always names the object that is in $WORK/build; a stale exported
# GB10_TEST_ARCH cannot survive it, because the value is set here and not
# inherited.
#
# uname -p is the source (FreeBSD reports amd64 or aarch64); a kernel that
# does not implement it reports "unknown", so uname -m is the fallback,
# mapped onto the two names build-stubs.sh knows.
ARCH=$(uname -p 2>/dev/null || true)
case $ARCH in
aarch64|amd64) ;;
*)
	case $(uname -m 2>/dev/null || true) in
	x86_64) ARCH=amd64 ;;
	arm64|aarch64) ARCH=aarch64 ;;
	*) ARCH='' ;;
	esac
	;;
esac
GB10_TEST_HOOKS=1
GB10_TEST_ARCH=$ARCH
export GB10_TEST_HOOKS GB10_TEST_ARCH

TESTSDIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$TESTSDIR/.." && pwd)
WORK=${GB10_WORK:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)/work}
export TMPDIR="$WORK/tmp"
SYMS=$REPO/tests/data/rmcore-missing-symbols.txt
BUILD=$REPO/scripts/build-stubs.sh
STUBS_SRC=$REPO/src/gb10-stubs/nv-gb10-stubs.c
STUBS_OBJ=$WORK/build/nv-gb10-stubs.o
# Unpredictable scratch directory ($WORK/tmp is <repo>/work/tmp unless
# GB10_WORK says otherwise), removed by the trap on every exit path.
mkdir -p "$WORK/tmp"
TESTROOT=$(mktemp -d "$WORK/tmp/stubs-test.XXXXXXXX") || exit 1

PASSED=0
FAILED=0

# cleanup - remove exactly this run's scratch files on every exit path.
# Time:  O(files created by this test).
# Space: O(1).
cleanup() {
	rm -rf "$TESTROOT"
}
# EXIT always runs cleanup; HUP/QUIT/INT/TERM exit with the conventional
# 128+n status and let the EXIT trap clean up, instead of one combined
# trap that cleans up and RETURNS (the script would carry on after a
# signal, with its scratch already deleted).
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 131' QUIT
trap 'exit 130' INT
trap 'exit 143' TERM

ok() {
	PASSED=$((PASSED + 1))
	printf 'ok   %s\n' "$1"
}

fail() {
	FAILED=$((FAILED + 1))
	printf 'FAIL %s\n' "$1"
}

# The architecture must be one build-stubs.sh supports (aarch64, amd64):
# there is no fallback to aarch64, because a stub built for the wrong
# architecture would link onto the wrong core. The RM core object the
# build looks for is named here, so a failure can say which object was
# wanted instead of only repeating the build's own complaint.
case $ARCH in
aarch64|amd64)
	CORE_OBJ=$WORK/build/nv-kernel-$ARCH.o
	;;
*)
	fail "unsupported architecture: '${ARCH:-unknown}' (expected aarch64 or amd64)"
	printf 'passed: %s failed: %s\n' "$PASSED" "$FAILED"
	exit 1
	;;
esac

if [ ! -f "$SYMS" ]; then
	fail "missing-symbols list not found: $SYMS"
	printf 'passed: %s failed: %s\n' "$PASSED" "$FAILED"
	exit 1
fi

# (c) The real build: compile the stubs, partially link them onto the
# core, count what is still undefined against the OS layer.
if [ ! -f "$BUILD" ]; then
	fail "scripts/build-stubs.sh does not exist"
elif sh "$BUILD" > "$TESTROOT/build.out" 2>&1; then
	ok "build-stubs.sh exits 0"
else
	fail "build-stubs.sh exits non-zero (arch $ARCH, core object $CORE_OBJ)"
	sed -n '1,20p' "$TESTROOT/build.out"
fi
if [ -f "$TESTROOT/build.out" ] &&
	grep -qx 'still undefined vs OS layer: 0' "$TESTROOT/build.out"; then
	ok '(c) prints "still undefined vs OS layer: 0"'
else
	fail '(c) "still undefined vs OS layer: 0" not printed'
fi

# (a) The stubs object defines exactly the 67 listed symbols, nothing
# missing and nothing extra.
# Time:  O(S log S) to sort the S defined symbols, then O(S) for the two
#        comm scans; one nm(1) run.
# Space: O(S) lines in the scratch files.
if [ ! -f "$STUBS_OBJ" ]; then
	fail "(a) $STUBS_OBJ does not exist"
else
	nm -g --defined-only "$STUBS_OBJ" | awk '$2 == "T" { print $3 }' |
		sort > "$TESTROOT/found"
	sort "$SYMS" > "$TESTROOT/want"
	n=$(wc -l < "$TESTROOT/found" | tr -d '[:space:]')
	if [ "$n" -eq 67 ]; then
		ok "(a) exactly 67 global T symbols in nv-gb10-stubs.o"
	else
		fail "(a) $n global T symbols in nv-gb10-stubs.o, expected 67"
	fi
	comm -23 "$TESTROOT/want" "$TESTROOT/found" > "$TESTROOT/not-defined"
	comm -13 "$TESTROOT/want" "$TESTROOT/found" > "$TESTROOT/unexpected"
	if [ ! -s "$TESTROOT/not-defined" ]; then
		ok "(a) every listed symbol is defined (T)"
	else
		fail "(a) listed but not defined: $(head -3 "$TESTROOT/not-defined" | tr '\n' ' ')"
	fi
	if [ ! -s "$TESTROOT/unexpected" ]; then
		ok "(a) nothing else is defined (T) in the stubs object"
	else
		fail "(a) defined but not listed: $(head -3 "$TESTROOT/unexpected" | tr '\n' ' ')"
	fi
fi

# (b) Prototype fidelity, falsified: a scratch copy of the stubs whose
# first bool definition returns int instead must be rejected by the
# compile (conflicting types against the real header prototype).
if [ ! -f "$STUBS_SRC" ]; then
	fail "(b) $STUBS_SRC does not exist"
else
	awk '!done && /^bool libspdm_/ { sub(/^bool /, "int "); done = 1 }
		{ print }' "$STUBS_SRC" > "$TESTROOT/wrong.c"
	if cmp -s "$STUBS_SRC" "$TESTROOT/wrong.c"; then
		fail "(b) no /^bool libspdm_/ definition line to corrupt"
	elif STUBS_SRC="$TESTROOT/wrong.c" STUBS_OBJ="$TESTROOT/wrong.o" \
		LINKED_OBJ="$TESTROOT/wrong-linked.o" \
		sh "$BUILD" > "$TESTROOT/wrong.out" 2>&1; then
		fail "(b) wrong return type compiled - prototype check cannot fail"
	else
		ok "(b) wrong return type is rejected by the -Werror compile"
	fi
fi

# (d) A relative GB10_WORK is refused before anything is created.
rc=0
(
	CDPATH= cd -- "$TESTROOT" || exit 1
	GB10_WORK=relative-work sh "$BUILD" > "$TESTROOT/out-d" 2> "$TESTROOT/err-d"
) || rc=$?
if [ "$rc" -eq 1 ] && grep -q 'must be an absolute path' "$TESTROOT/err-d" \
    && [ ! -e "$TESTROOT/relative-work" ]; then
	ok "(d) relative GB10_WORK: refused, nothing created"
else
	fail "(d) relative GB10_WORK: rc=$rc err=$(tail -n 1 "$TESTROOT/err-d" 2>/dev/null) created=$([ -e "$TESTROOT/relative-work" ] && echo yes || echo no)"
fi

printf 'passed: %s failed: %s\n' "$PASSED" "$FAILED"
if [ "$FAILED" -ne 0 ]; then
	exit 1
fi
