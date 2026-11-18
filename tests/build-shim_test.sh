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
#   (g) unknown version:   an unreadable sys/param.h means "version
#                            unknown": every run cleans first
#   (h) symlinked stamp:   a symlinked .gb10-sysdir is refused before
#                            anything is read or written
#   (i) modeset module:    with --module=nvidia-modeset the module built
#                            is TREE/nvidia-modeset, the RM core object is
#                            copied over TREE/nvidia-modeset/
#                            nv-modeset-kernel.o and the module required
#                            is nvidia-modeset.ko
#   (j) modeset module:    the RMOBJ default of a modeset build is
#                            $GB10_WORK/build/nv-modeset-kernel-aarch64.o
#   (k) unknown module:    an unknown module name is refused, exit 1
#   (l) drm module:       with --module=nvidia-drm the module built is
#                            TREE/nvidia-drm and nvidia-drm.ko is required.
#                            It has NO RM core object: none is copied (not
#                            even the one RMOBJ names) and no "rm core:" line
#                            is printed. The make run must see DRMKMODDIR
#                            (the drm-kmod source tree) and BSDSRCTOP (the
#                            parent of SYSDIR), and the stamp must record the
#                            DRMKMODDIR as well.
#   (m) drm module:       DRMKMODDIR unset is refused (exit 1): the script
#                            must not guess one, and nothing is built
#   (n) drm module:       a DRMKMODDIR without linuxkpi_version.mk is
#                            refused (exit 1), and nothing is built
#   (o) drm module:       a DRMKMODDIR that is not an absolute path, or
#                            not a directory, is refused (exit 1)
#   (p) drm module:       BSDSRCTOP from the environment overrides the
#                            default (the parent of SYSDIR)
#   (q) drm module:       a changed DRMKMODDIR cleans the objects first
#                            (the stamp records it)
#   (r) drm module:       an unchanged DRMKMODDIR does NOT clean
#   (s) drm module:       an unchanged BSDSRCTOP does NOT clean either
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

# write_makefile <kind> [module-dir] [ko-name]: good - fake.o embeds
# ${SYSDIR}, the module is its copy, clean removes both; fail - "all"
# always fails; noko - "all" succeeds but produces no module; drm - like
# good, but fake.o also embeds ${BSDSRCTOP} and ${DRMKMODDIR}, so a test
# can see what the make run was given. Recipe lines need TABs.
write_makefile() {
	_wm_kind=$1
	_wm_dir=${2:-nvidia}
	_wm_ko=${3:-nvidia.ko}
	mkdir -p "$TREE/$_wm_dir"
	case $_wm_kind in
	good)
		printf 'all: %s\n\n%s: fake.o\n\tcat fake.o > %s\n\nfake.o:\n\techo "obj ${SYSDIR}" > fake.o\n\nclean:\n\trm -f fake.o %s\n' \
			"$_wm_ko" "$_wm_ko" "$_wm_ko" "$_wm_ko" \
			> "$TREE/$_wm_dir/Makefile"
		;;
	drm)
		printf 'all: %s\n\n%s: fake.o\n\tcat fake.o > %s\n\nfake.o:\n\techo "obj ${SYSDIR} bsdsrctop ${BSDSRCTOP} drmkmoddir ${DRMKMODDIR}" > fake.o\n\nclean:\n\trm -f fake.o %s\n' \
			"$_wm_ko" "$_wm_ko" "$_wm_ko" "$_wm_ko" \
			> "$TREE/$_wm_dir/Makefile"
		;;
	fail)
		printf 'all:\n\tfalse\n\nclean:\n\trm -f fake.o %s\n' "$_wm_ko" \
			> "$TREE/$_wm_dir/Makefile"
		;;
	noko)
		printf 'all:\n\t@echo built nothing\n\nclean:\n\t@true\n' \
			> "$TREE/$_wm_dir/Makefile"
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

# run_shim_mod <sysdir> <args...>: the same, with the module option and
# anything else in front of the TREE and LOG.
run_shim_mod() {
	rc=0
	_rsm_sys=$1
	shift
	GB10_WORK="$TESTROOT" SYSDIR="$_rsm_sys" \
		sh "$SCRIPT" "$@" "$TREE" "$LOG" >"$TESTROOT/out" 2>"$TESTROOT/err" || rc=$?
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

# (i) the modeset module: with --module=nvidia-modeset the script builds
# TREE/nvidia-modeset, copies the RM core object over
# TREE/nvidia-modeset/nv-modeset-kernel.o and requires nvidia-modeset.ko.
write_makefile good nvidia-modeset nvidia-modeset.ko
printf 'fake modeset core\n' > "$TESTROOT/build/nv-modeset-kernel-aarch64.o"
run_shim_mod "$SYSA" --module=nvidia-modeset
i_ok=1
[ "$rc" -eq 0 ] || i_ok=0
grep -q '^build: OK$' "$TESTROOT/out" || i_ok=0
[ -s "$TREE/nvidia-modeset/nvidia-modeset.ko" ] || i_ok=0
grep -q "^nvidia-modeset.ko: [0-9]* bytes, sha256 [0-9a-f]\{64\}$" "$TESTROOT/out" \
	|| i_ok=0
# The RM core object must have been copied over the modeset core file.
grep -q '^fake modeset core$' "$TREE/nvidia-modeset/nv-modeset-kernel.o" \
	|| i_ok=0
# The SYSDIR stamp lives in the module's own directory.
[ -f "$TREE/nvidia-modeset/.gb10-sysdir" ] || i_ok=0
grep -q "^sysdir $SYSA$" "$TREE/nvidia-modeset/.gb10-sysdir" 2>/dev/null || i_ok=0
if [ "$i_ok" -eq 1 ]; then
	ok "(i) modeset module: TREE/nvidia-modeset built, core object swapped, nvidia-modeset.ko required"
else
	fail "(i) modeset module: rc=$rc out=$(cat "$TESTROOT/out" 2>/dev/null) err=$(cat "$TESTROOT/err" 2>/dev/null)"
fi

# (j) the RMOBJ default of a modeset build is
# $GB10_WORK/build/nv-modeset-kernel-aarch64.o - the object the
# build-rmcore.sh modeset run writes. Without RMOBJ in the environment the
# script must name that path.
run_shim_mod "$SYSA" --module=nvidia-modeset
if grep -q "^rm core: $TESTROOT/build/nv-modeset-kernel-aarch64.o -> " \
    "$TESTROOT/out"; then
	ok "(j) modeset module: RMOBJ defaults to build/nv-modeset-kernel-aarch64.o"
else
	fail "(j) modeset RMOBJ default: rc=$rc out=$(cat "$TESTROOT/out" 2>/dev/null)"
fi

# (k) an unknown module name is refused, and nothing is built.
rc=0
run_shim_mod "$SYSA" --module=nvidia-bogus
if [ "$rc" -eq 1 ] && grep -q 'usage:' "$TESTROOT/err" \
    && grep -q 'unknown module' "$TESTROOT/err" \
    && [ ! -e "$TREE/nvidia-bogus/nvidia-bogus.ko" ]; then
	ok "(k) unknown module name: exit 1 with a usage message"
else
	fail "(k) unknown module: rc=$rc err=$(cat "$TESTROOT/err" 2>/dev/null)"
fi

# --------------------------------------------------------------------------
# The nvidia-drm module. It is built against the drm-kmod source tree
# (DRMKMODDIR) and the FreeBSD source tree (BSDSRCTOP), and it has no RM
# core object of its own.
DRMKMOD=$TESTROOT/drm-kmod
mkdir -p "$DRMKMOD" || exit 1
printf 'LINUXKPI_VERSION_NUMBER=\t610000\n' > "$DRMKMOD/linuxkpi_version.mk"
DRMKO=$TREE/nvidia-drm/nvidia-drm.ko

# run_shim_drm <sysdir> [VAR=VALUE ...]: run the script with
# --module=nvidia-drm. DRMKMODDIR and BSDSRCTOP are removed from the
# environment first, so a case sees only what it sets itself.
run_shim_drm() {
	_rsd_sys=$1
	shift
	rc=0
	env -u DRMKMODDIR -u BSDSRCTOP "$@" \
	    GB10_WORK="$TESTROOT" SYSDIR="$_rsd_sys" \
	    sh "$SCRIPT" --module=nvidia-drm "$TREE" "$LOG" \
	    >"$TESTROOT/out" 2>"$TESTROOT/err" || rc=$?
}

# (l) the drm module: TREE/nvidia-drm is built and nvidia-drm.ko is
# required. NO RM core object is copied - not even the one RMOBJ names,
# and the build prints no "rm core:" line. The make run sees DRMKMODDIR
# and BSDSRCTOP, whose default is the parent of SYSDIR, and the stamp
# records the DRMKMODDIR next to the SYSDIR and the version.
write_makefile drm nvidia-drm nvidia-drm.ko
printf 'fake core object\n' > "$TESTROOT/build/fake-core.o"
run_shim_drm "$SYSA" DRMKMODDIR="$DRMKMOD" RMOBJ="$TESTROOT/build/fake-core.o"
l_ok=1
[ "$rc" -eq 0 ] || l_ok=0
grep -q '^build: OK$' "$TESTROOT/out" || l_ok=0
[ -s "$DRMKO" ] || l_ok=0
grep -q "^nvidia-drm.ko: [0-9]* bytes, sha256 [0-9a-f]\{64\}$" "$TESTROOT/out" \
	|| l_ok=0
# No RM core object is copied into the module directory, and none is
# announced.
[ ! -e "$TREE/nvidia-drm/nv-kernel.o" ] || l_ok=0
if grep -q '^rm core:' "$TESTROOT/out"; then
	l_ok=0
fi
# make was given the DRMKMODDIR and the BSDSRCTOP (the parent of SYSDIR).
grep -q "^obj $SYSA bsdsrctop $TESTROOT drmkmoddir $DRMKMOD$" "$DRMKO" \
	|| l_ok=0
# The stamp records the DRMKMODDIR and the BSDSRCTOP too.
grep -q "^sysdir $SYSA$" "$TREE/nvidia-drm/.gb10-sysdir" 2>/dev/null || l_ok=0
grep -q "^bsdsrctop $TESTROOT$" "$TREE/nvidia-drm/.gb10-sysdir" 2>/dev/null || l_ok=0
grep -q "^drmkmoddir $DRMKMOD$" "$TREE/nvidia-drm/.gb10-sysdir" 2>/dev/null \
	|| l_ok=0
if [ "$l_ok" -eq 1 ]; then
	ok "(l) drm module: nvidia-drm.ko built, no RM core object, DRMKMODDIR+BSDSRCTOP passed, stamp records them"
else
	fail "(l) drm module: rc=$rc out=$(cat "$TESTROOT/out" 2>/dev/null) err=$(cat "$TESTROOT/err" 2>/dev/null) ko=$(cat "$DRMKO" 2>/dev/null) stamp=$(tr '\n' '|' < "$TREE/nvidia-drm/.gb10-sysdir" 2>/dev/null)"
fi

# (m) DRMKMODDIR unset: the script must not guess one (the Makefile's own
# default is a guess: ${HOME}/git/drm-kmod). It refuses, exit 1, and
# nothing is built: the module keeps the bytes the last run left.
ko_before=$(sha256 -q "$DRMKO" 2>/dev/null || echo none)
run_shim_drm "$SYSA"
ko_after=$(sha256 -q "$DRMKO" 2>/dev/null || echo none)
if [ "$rc" -eq 1 ] && grep -q 'DRMKMODDIR' "$TESTROOT/err" \
    && [ "$ko_before" = "$ko_after" ]; then
	ok "(m) drm module: DRMKMODDIR unset is refused, nothing is built"
else
	fail "(m) drm module without DRMKMODDIR: rc=$rc err=$(cat "$TESTROOT/err" 2>/dev/null)"
fi

# (n) a DRMKMODDIR without linuxkpi_version.mk: the Makefile includes it,
# so without it the build cannot even be parsed. Refused, exit 1, nothing
# is built.
DRMKMOD_NOV=$TESTROOT/drm-kmod-nov
mkdir -p "$DRMKMOD_NOV" || exit 1
ko_before=$(sha256 -q "$DRMKO" 2>/dev/null || echo none)
run_shim_drm "$SYSA" DRMKMODDIR="$DRMKMOD_NOV"
ko_after=$(sha256 -q "$DRMKO" 2>/dev/null || echo none)
if [ "$rc" -eq 1 ] && grep -q 'linuxkpi_version.mk' "$TESTROOT/err" \
    && [ "$ko_before" = "$ko_after" ]; then
	ok "(n) drm module: a DRMKMODDIR without linuxkpi_version.mk is refused"
else
	fail "(n) drm module, DRMKMODDIR without linuxkpi_version.mk: rc=$rc err=$(cat "$TESTROOT/err" 2>/dev/null)"
fi

# (o) a DRMKMODDIR that is not an absolute path, or not a directory, is
# refused: a relative one would be resolved against the module directory
# by make, which is never what the operator meant.
ko_before=$(sha256 -q "$DRMKO" 2>/dev/null || echo none)
run_shim_drm "$SYSA" DRMKMODDIR="relative/drm-kmod"
ko_after=$(sha256 -q "$DRMKO" 2>/dev/null || echo none)
if [ "$rc" -eq 1 ] && grep -q 'DRMKMODDIR' "$TESTROOT/err" \
    && [ "$ko_before" = "$ko_after" ]; then
	ok "(o) drm module: a relative DRMKMODDIR is refused"
else
	fail "(o) drm module, relative DRMKMODDIR: rc=$rc err=$(cat "$TESTROOT/err" 2>/dev/null)"
fi
ko_before=$(sha256 -q "$DRMKO" 2>/dev/null || echo none)
run_shim_drm "$SYSA" DRMKMODDIR="$TESTROOT/no-such-drm-kmod"
ko_after=$(sha256 -q "$DRMKO" 2>/dev/null || echo none)
if [ "$rc" -eq 1 ] && grep -q 'DRMKMODDIR' "$TESTROOT/err" \
    && [ "$ko_before" = "$ko_after" ]; then
	ok "(o) drm module: a DRMKMODDIR that is not a directory is refused"
else
	fail "(o) drm module, missing DRMKMODDIR directory: rc=$rc err=$(cat "$TESTROOT/err" 2>/dev/null)"
fi

# (p) BSDSRCTOP from the environment overrides the default (the parent of
# SYSDIR). The objects are compiled against that tree's headers, so a
# changed BSDSRCTOP is in the stamp and the objects are cleaned first:
# the tampered object below is gone and the module shows the new value.
BSDTOP=$TESTROOT/bsdsrctop
mkdir -p "$BSDTOP" || exit 1
printf 'tampered3\n' > "$TREE/nvidia-drm/fake.o"
run_shim_drm "$SYSA" DRMKMODDIR="$DRMKMOD" BSDSRCTOP="$BSDTOP"
p_ok=1
[ "$rc" -eq 0 ] || p_ok=0
grep -q "^obj $SYSA bsdsrctop $BSDTOP drmkmoddir $DRMKMOD$" "$DRMKO" || p_ok=0
if grep -q '^tampered3$' "$DRMKO"; then
	p_ok=0
fi
grep -q "^bsdsrctop $BSDTOP$" "$TREE/nvidia-drm/.gb10-sysdir" 2>/dev/null || p_ok=0
if [ "$p_ok" -eq 1 ]; then
	ok "(p) drm module: BSDSRCTOP overrides the default and a changed one cleans"
else
	fail "(p) drm module, BSDSRCTOP override: rc=$rc ko=$(cat "$DRMKO" 2>/dev/null) stamp=$(tr '\n' '|' < "$TREE/nvidia-drm/.gb10-sysdir" 2>/dev/null) err=$(cat "$TESTROOT/err" 2>/dev/null)"
fi

# (q) a changed DRMKMODDIR cleans the objects first: the stamp records
# it, so the objects built against the old tree must not be reused.
DRMKMOD2=$TESTROOT/drm-kmod-2
mkdir -p "$DRMKMOD2" || exit 1
printf 'LINUXKPI_VERSION_NUMBER=\t610000\n' > "$DRMKMOD2/linuxkpi_version.mk"
printf 'tampered\n' > "$TREE/nvidia-drm/fake.o"
run_shim_drm "$SYSA" DRMKMODDIR="$DRMKMOD2"
q_ok=1
[ "$rc" -eq 0 ] || q_ok=0
grep -q "^obj $SYSA bsdsrctop $TESTROOT drmkmoddir $DRMKMOD2$" "$DRMKO" \
	|| q_ok=0
if grep -q '^tampered$' "$DRMKO"; then
	q_ok=0
fi
if [ "$q_ok" -eq 1 ]; then
	ok "(q) drm module: a changed DRMKMODDIR cleans and rebuilds the objects"
else
	fail "(q) drm module, changed DRMKMODDIR: rc=$rc ko=$(cat "$DRMKO" 2>/dev/null) stamp=$(tr '\n' '|' < "$TREE/nvidia-drm/.gb10-sysdir" 2>/dev/null)"
fi

# (r) an unchanged DRMKMODDIR does NOT clean: the tampered object
# survives into the rebuilt module (the stamp's decision, not always).
printf 'tampered2\n' > "$TREE/nvidia-drm/fake.o"
run_shim_drm "$SYSA" DRMKMODDIR="$DRMKMOD2"
if [ "$rc" -eq 0 ] && grep -q '^tampered2$' "$DRMKO"; then
	ok "(r) drm module: an unchanged DRMKMODDIR does not clean"
else
	fail "(r) drm module, unchanged DRMKMODDIR: rc=$rc ko=$(cat "$DRMKO" 2>/dev/null)"
fi

# (s) an unchanged BSDSRCTOP does NOT clean either.
printf 'tampered4\n' > "$TREE/nvidia-drm/fake.o"
run_shim_drm "$SYSA" DRMKMODDIR="$DRMKMOD2"
if [ "$rc" -eq 0 ] && grep -q '^tampered4$' "$DRMKO"; then
	ok "(s) drm module: an unchanged BSDSRCTOP does not clean"
else
	fail "(s) drm module, unchanged BSDSRCTOP: rc=$rc ko=$(cat "$DRMKO" 2>/dev/null)"
fi

echo "passed: $PASSED failed: $FAILED"
if [ "$FAILED" -gt 0 ]; then
	exit 1
fi
exit 0
