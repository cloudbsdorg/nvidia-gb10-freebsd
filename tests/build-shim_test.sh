#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# build-shim_test.sh - offline tests for scripts/build-shim.sh.
#
# Runs the real script against a fake prepared tree under an unpredictable
# mktemp(1) directory in ${GB10_WORK:-$HOME/work/gb10}/tmp: TREE/nvidia
# holds a tiny BSD-make Makefile whose "all" target writes a fake.o that
# EMBEDS THE SYSDIR IT WAS BUILT AGAINST and concatenates it into a fake
# nvidia.ko, so a reused stale object is visible in the module's bytes.
# Two fake SYSDIRs (sys/param.h with different __FreeBSD_version values)
# drive the stamp logic. No kernel sources, no compiler, no network.
# Cases:
#   (a) happy path:          exit 0, "build: OK", non-empty nvidia.ko with
#                            its sha256 printed, and the SYSDIR stamp file
#                            records the SYSDIR path and __FreeBSD_version
#   (b) MAKEFLAGS=-i leak:   with a failing "all" target and MAKEFLAGS=-i
#                            exported, the build must FAIL (exit 3): make
#                            runs under env -u MAKEFLAGS ..., so -i cannot
#                            reach it and turn the failure into a false
#                            "build: OK" (pass-3 u04 #1)
#   (c) make rc 0, no .ko:   "build: OK" requires a non-empty nvidia.ko;
#                            a make that succeeds without producing one
#                            exits 3 with "build: FAILED (no nvidia.ko)"
#   (d) SYSDIR changed:      objects built against SYSDIR A must not be
#                            reused for SYSDIR B - the stamp differs, so
#                            `make clean` runs and nvidia.ko embeds B
#                            (2026-11-18: an identical nvidia.ko sha256
#                            after changing SYSDIR)
#   (e) SYSDIR unchanged:    no clean - a hand-tampered fake.o survives
#                            into the rebuilt nvidia.ko (proves (d)'s
#                            clean is the stamp's decision, not always)
#   (f) version-only change: same SYSDIR path, new __FreeBSD_version in
#                            its sys/param.h: the stamp differs, the
#                            tampered object is cleaned away and rebuilt
#
# Run: sh tests/build-shim_test.sh

set -eu

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

TESTSDIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SCRIPT="$TESTSDIR/../scripts/build-shim.sh"
WORK=${GB10_WORK:-$HOME/work/gb10}
mkdir -p "$WORK/tmp"
TESTROOT=$(mktemp -d "$WORK/tmp/shim-test.XXXXXXXX") || exit 1

PASSED=0
FAILED=0

# cleanup - remove exactly this run's test root on every exit path.
# Time:  O(files created by this test).
# Space: O(1).
cleanup() {
	case $TESTROOT in
	"$WORK"/tmp/shim-test.?*) rm -rf -- "$TESTROOT" ;;
	esac
}
# EXIT cleans up; INT/TERM exit with the conventional 128+n status, which
# then runs the EXIT trap.
trap cleanup EXIT
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

if [ ! -f "$SCRIPT" ]; then
	fail "scripts/build-shim.sh does not exist"
	echo "passed: $PASSED failed: $FAILED"
	exit 1
fi

# Fake prepared tree: build-shim.sh requires TREE/nvidia and a .prepared
# whose line 2 says "state done".
TREE=$TESTROOT/build/tree
mkdir -p "$TREE/nvidia" "$TESTROOT/logs" || exit 1
printf 'gb10 prepare-tree.sh %s\nstate done\n' "$TREE" > "$TREE/.prepared"
LOG=$TESTROOT/logs/shim-test.log

# Two fake SYSDIRs with different __FreeBSD_version values.
SYSA=$TESTROOT/sys-a
SYSB=$TESTROOT/sys-b
mkdir -p "$SYSA/sys" "$SYSB/sys" || exit 1
printf '#define __FreeBSD_version 1600001\n' > "$SYSA/sys/param.h"
printf '#define __FreeBSD_version 1600002\n' > "$SYSB/sys/param.h"

# write_makefile <kind>: good - fake.o embeds ${SYSDIR}, nvidia.ko is its
# copy, clean removes both; fail - "all" always fails; noko - "all"
# succeeds but produces no nvidia.ko. Recipe lines need TABs.
write_makefile() {
	case $1 in
	good)
		printf 'all: nvidia.ko\n\nnvidia.ko: fake.o\n\tcat fake.o > nvidia.ko\n\nfake.o:\n\techo "obj ${SYSDIR}" > fake.o\n\nclean:\n\trm -f fake.o nvidia.ko\n' \
			> "$TREE/nvidia/Makefile"
		;;
	fail)
		printf 'all:\n\tfalse\n\nclean:\n\trm -f fake.o nvidia.ko\n' \
			> "$TREE/nvidia/Makefile"
		;;
	noko)
		printf 'all:\n\t@echo built nothing\n\nclean:\n\t@true\n' \
			> "$TREE/nvidia/Makefile"
		;;
	esac
}

# run_shim <sysdir>: run the script against the fake tree; rc/stdout/stderr
# land in $rc, $TESTROOT/out, $TESTROOT/err.
run_shim() {
	rc=0
	GB10_WORK="$TESTROOT" SYSDIR="$1" \
		sh "$SCRIPT" "$TREE" "$LOG" >"$TESTROOT/out" 2>"$TESTROOT/err" || rc=$?
}

KO=$TREE/nvidia/nvidia.ko
STAMP=$TREE/nvidia/.gb10-sysdir

# (a) happy path: build: OK, non-empty .ko embedding SYSA, stamp written.
write_makefile good
run_shim "$SYSA"
a_ok=1
[ "$rc" -eq 0 ] || a_ok=0
grep -q '^build: OK$' "$TESTROOT/out" || a_ok=0
[ -s "$KO" ] || a_ok=0
grep -q "^nvidia.ko: [0-9]* bytes, sha256 [0-9a-f]\{64\}$" "$TESTROOT/out" || a_ok=0
grep -q "^obj $SYSA$" "$KO" || a_ok=0
[ -f "$STAMP" ] || a_ok=0
grep -q "^sysdir $SYSA$" "$STAMP" 2>/dev/null || a_ok=0
grep -q '^version 1600001$' "$STAMP" 2>/dev/null || a_ok=0
if [ "$a_ok" -eq 1 ]; then
	ok "(a) happy path: build: OK, nvidia.ko embeds the SYSDIR, stamp records sysdir+version"
else
	fail "(a) happy path: rc=$rc out=$(cat "$TESTROOT/out" 2>/dev/null) ko=$(cat "$KO" 2>/dev/null) stamp=$(tr '\n' '|' < "$STAMP" 2>/dev/null)"
fi

# (b) MAKEFLAGS=-i inherited + a failing "all": make must NOT see the -i
# (env -u strips it), so the failure surfaces as exit 3 "build: FAILED".
# Before the fix, BSD make honoured MAKEFLAGS=-i ("Error code 1
# (ignored)", rc 0) and the script printed "build: OK" with no module.
write_makefile fail
rc=0
MAKEFLAGS=-i GB10_WORK="$TESTROOT" SYSDIR="$SYSA" \
	sh "$SCRIPT" "$TREE" "$LOG" >"$TESTROOT/out" 2>"$TESTROOT/err" || rc=$?
if [ "$rc" -eq 3 ] && grep -q '^build: FAILED' "$TESTROOT/out" \
    && ! grep -q '^build: OK$' "$TESTROOT/out"; then
	ok "(b) MAKEFLAGS=-i leak with a failing target: exit 3, build: FAILED (flags stripped)"
else
	fail "(b) MAKEFLAGS=-i: rc=$rc out=$(cat "$TESTROOT/out" 2>/dev/null)"
fi

# (c) make rc 0 but no nvidia.ko produced: "build: OK" requires positive
# evidence - a non-empty module from THIS run (the stale one is removed
# before make), so this exits 3 with "build: FAILED (no nvidia.ko)".
write_makefile noko
run_shim "$SYSA"
if [ "$rc" -eq 3 ] && grep -q 'build: FAILED (no nvidia.ko)' "$TESTROOT/out"; then
	ok "(c) make rc 0 without nvidia.ko: exit 3, 'build: FAILED (no nvidia.ko)'"
else
	fail "(c) no-ko build: rc=$rc out=$(cat "$TESTROOT/out" 2>/dev/null)"
fi

# (d) SYSDIR changed: rebuild under SYSA (consistent state after b/c),
# then switch to SYSB. The stamp differs, so `make clean` must run and
# fake.o must be rebuilt against SYSB - the module's bytes prove which
# SYSDIR the objects came from.
write_makefile good
run_shim "$SYSA"
d_ok=1
[ "$rc" -eq 0 ] || d_ok=0
grep -q "^obj $SYSA$" "$KO" || d_ok=0
run_shim "$SYSB"
[ "$rc" -eq 0 ] || d_ok=0
grep -q "^obj $SYSB$" "$KO" || d_ok=0
grep -q "^sysdir $SYSB$" "$STAMP" 2>/dev/null || d_ok=0
grep -q '^version 1600002$' "$STAMP" 2>/dev/null || d_ok=0
if [ "$d_ok" -eq 1 ]; then
	ok "(d) SYSDIR changed: objects cleaned and rebuilt against the new SYSDIR"
else
	fail "(d) SYSDIR change: rc=$rc ko=$(cat "$KO" 2>/dev/null) stamp=$(tr '\n' '|' < "$STAMP" 2>/dev/null) out=$(tail -2 "$TESTROOT/out" 2>/dev/null)"
fi

# (e) SYSDIR unchanged: NO clean - a hand-tampered fake.o must survive
# into the rebuilt nvidia.ko (the stamp matches, so make reuses it).
printf 'tampered\n' > "$TREE/nvidia/fake.o"
run_shim "$SYSB"
if [ "$rc" -eq 0 ] && grep -q '^tampered$' "$KO"; then
	ok "(e) SYSDIR unchanged: no clean, the reused object survives into nvidia.ko"
else
	fail "(e) unchanged SYSDIR: rc=$rc ko=$(cat "$KO" 2>/dev/null)"
fi

# (f) same SYSDIR path but a new __FreeBSD_version in its sys/param.h:
# the stamp differs on the version line, so the tampered object must be
# cleaned away and rebuilt.
printf '#define __FreeBSD_version 1600003\n' > "$SYSB/sys/param.h"
printf 'tampered2\n' > "$TREE/nvidia/fake.o"
run_shim "$SYSB"
f_ok=1
[ "$rc" -eq 0 ] || f_ok=0
grep -q "^obj $SYSB$" "$KO" || f_ok=0
grep -q '^version 1600003$' "$STAMP" 2>/dev/null || f_ok=0
if [ "$f_ok" -eq 1 ]; then
	ok "(f) __FreeBSD_version changed under the same SYSDIR: cleaned and rebuilt"
else
	fail "(f) version change: rc=$rc ko=$(cat "$KO" 2>/dev/null) stamp=$(tr '\n' '|' < "$STAMP" 2>/dev/null)"
fi

# (g) an unreadable sys/param.h ("version unknown"): clean every time,
# even when the previous run left the same "unknown" stamp. Two runs; the
# second must still clean away a tampered object.
SYSU=$TESTROOT/sys-u
mkdir -p "$SYSU/sys" || exit 1
run_shim "$SYSU"
printf 'tampered3\n' > "$TREE/nvidia/fake.o"
run_shim "$SYSU"
if [ "$rc" -eq 0 ] && grep -q "^obj $SYSU$" "$KO" \
    && grep -q '^version unknown$' "$STAMP" 2>/dev/null; then
	ok "(g) unknown __FreeBSD_version: cleaned on every run, never trusted"
else
	fail "(g) unknown version: rc=$rc ko=$(cat "$KO" 2>/dev/null)"
fi

# (h) a symlinked stamp is refused before anything is read or written.
rm -f "$STAMP"
printf 'decoy\n' > "$TESTROOT/decoy-stamp"
ln -s "$TESTROOT/decoy-stamp" "$STAMP"
run_shim "$SYSA"
if [ "$rc" -eq 1 ] && grep -q 'refusing .*\.gb10-sysdir: symlink' "$TESTROOT/err" \
    && grep -qx decoy "$TESTROOT/decoy-stamp"; then
	ok "(h) symlinked stamp refused, its target untouched"
else
	fail "(h) symlinked stamp: rc=$rc err=$(cat "$TESTROOT/err") target=$(cat "$TESTROOT/decoy-stamp")"
fi
rm -f "$STAMP"

echo "passed: $PASSED failed: $FAILED"
if [ "$FAILED" -gt 0 ]; then
	exit 1
fi
exit 0
