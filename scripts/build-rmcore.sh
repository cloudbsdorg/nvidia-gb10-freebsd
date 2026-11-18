#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# build-rmcore.sh - build NVIDIA's open RM core (src/nvidia of
# open-gpu-kernel-modules 580.178.04, MIT) as an aarch64 FreeBSD object, to
# replace the prebuilt amd64 nv-kernel.o in the OS-layer tree.
#
# Usage: scripts/build-rmcore.sh [OUT] [LOG]
#   OUT   where to copy the built nv-kernel.o; defaults to
#         ${GB10_WORK:-$HOME/work/gb10}/build/nv-kernel-aarch64.o
#   LOG   gmake output log; defaults to
#         ${GB10_WORK:-$HOME/work/gb10}/logs/build-rmcore-<UTC>.log
#
# Environment:
#   GB10_WORK work root holding sources/, build/, logs/ and tmp/
#   GB10_TEST_HOOKS
#             set to 1 to let the three test hooks below be taken from the
#             environment; without it they are ignored and the repo's own
#             SOURCES, ogkm patches and the fixed gmake are used
#   SOURCES   test hook: pin file with ogkm_commit; defaults to <repo>/SOURCES
#   GMAKE     test hook: gmake to run; defaults to /usr/local/bin/gmake
#   OGKM_PATCHES test hook: directory of ogkm patch-* files to apply to the
#               build copy; defaults to <repo>/patches/ogkm, whose required
#               patch-src_nvidia_Makefile must be present (a patch dir
#               without it exits 1)
#
# A hook in use must be one word of [A-Za-z0-9_./-] and is announced on
# stderr as "build-rmcore: test hook <NAME> in use".
#
# Copies the pinned source checkout
# $GB10_WORK/sources/open-gpu-kernel-modules-580.178.04 to
# $GB10_WORK/build/ogkm, first checking with git that the checkout is at
# SOURCES' ogkm_commit, that its tracked tree is clean at that commit, and
# that it holds no untracked or ignored file that would ride along in the
# copy (refusing otherwise). build/ogkm must resolve strictly under
# $GB10_WORK/build and must not be a symlink (safe_build_dir in
# scripts/lib.sh); an existing build/ogkm is
# replaced only when its .gb10-ogkm marker's first line names this script
# and that exact resolved path; any other directory is refused and left
# untouched. The marker's second line says "state building" until the
# object is built, then is rewritten to "state done" via a temp file and
# mv(1). Every
# $OGKM_PATCHES/patch-* is then applied to the copy in lexical order, after
# a header check refuses any patch whose ---/+++ paths are absolute or hold
# a .. component (on
# failure the patch name is printed and the script exits 1, exactly like
# prepare-tree.sh does). This run's scratch is an unpredictable mktemp(1)
# directory under $GB10_WORK/tmp and TMPDIR points at it. Then builds
# src/nvidia with TARGET_OS=FreeBSD
# TARGET_ARCH=aarch64 (the core's own aarch64 kernel flags), CFLAGS passed
# through the environment as '-Wall -mbranch-protection=standard' so every
# core object carries the BTI/PAC GNU property note (see the gmake call
# below for why it must be the environment), and a neutral build stamp,
# NV_BUILD_USER=cloudbsd and
# NV_BUILD_HOST=build (both `?=` in utils.mk), so no internal user or host
# name is embedded in the object, and copies _out/FreeBSD_aarch64/nv-kernel.o
# to OUT. Prints OUT's size and sha256, and — when a prepared OS-layer tree
# with objects exists ($GB10_WORK/build/tree/nvidia/*.o) — the number of
# symbols undefined in OUT that the OS layer does not define. Exits 1 if
# gmake fails or produces no object. Nothing is written outside $GB10_WORK
# (and an explicit OUT/LOG) and /tmp is never used.

set -eu

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

OGKMDIR=open-gpu-kernel-modules-580.178.04
WORK=${GB10_WORK:-$HOME/work/gb10}
SRC=$WORK/sources/$OGKMDIR
BUILDDIR=$WORK/build/ogkm
MARKER=.gb10-ogkm
OSOBJDIR=$WORK/build/tree/nvidia

SCRIPTDIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$SCRIPTDIR/.." && pwd)
. "$SCRIPTDIR/lib.sh"
# SOURCES decides which commit the build must be at and GMAKE is the program
# that compiles it, so both are test hooks: taken from the environment only
# with GB10_TEST_HOOKS=1, validated and announced by test_hook. Without it
# the repo's own SOURCES and the fixed gmake are used, whatever the
# environment says.
SOURCESFILE=$(test_hook build-rmcore SOURCES "$REPO/SOURCES") || exit 1
GMAKE=$(test_hook build-rmcore GMAKE /usr/local/bin/gmake) || exit 1
# OGKM_PATCHES decides which patches enter the build copy, so it is a test
# hook like SOURCES and GMAKE: taken from the environment only with
# GB10_TEST_HOOKS=1, validated and announced by test_hook. Without it the
# repo's own patches are used, whatever the environment says.
OGKMPATCHDIR=$(test_hook build-rmcore OGKM_PATCHES "$REPO/patches/ogkm") || exit 1
# The ogkm Makefile patch is load-bearing: it drops the objcopy step that
# removes .note.gnu.property, without which the BTI/PAC property notes this
# build exists to produce are stripped back out of the object. Require it
# to be present up front; that it applies is enforced by apply_patches
# below (exit 1 on failure).
if [ ! -f "$OGKMPATCHDIR/patch-src_nvidia_Makefile" ]; then
	echo "build-rmcore: required patch missing: $OGKMPATCHDIR/patch-src_nvidia_Makefile" >&2
	exit 1
fi

if [ $# -gt 2 ]; then
	echo "usage: build-rmcore.sh [OUT] [LOG]" >&2
	exit 1
fi

OUT=${1:-$WORK/build/nv-kernel-aarch64.o}
LOG=${2:-$WORK/logs/build-rmcore-$(date -u +%Y%m%dT%H%M%SZ).log}
# The build below cd's into the copied tree; a relative OUT/LOG must still
# resolve against the caller's directory, so make both absolute now.
case $OUT in /*) ;; *) OUT=$PWD/$OUT ;; esac
case $LOG in /*) ;; *) LOG=$PWD/$LOG ;; esac
# Scratch under an unpredictable mktemp(1) name: a fixed $$-suffixed path
# is guessable, and a symlink planted at it would redirect every scratch
# write. TMPDIR follows the scratch dir, so any child's temp files land
# there too and never in /tmp.
mkdir -p "$WORK/tmp"
SCRATCH=$(mktemp -d "$WORK/tmp/build-rmcore.XXXXXXXX") || {
	echo "build-rmcore: cannot create scratch dir under $WORK/tmp" >&2
	exit 1
}
TMPDIR=$SCRATCH
export TMPDIR

# cleanup - remove this run's scratch dir on exit. The case guard pins the
# rm -rf to the mktemp name shape under $WORK/tmp, so even a clobbered
# SCRATCH cannot reach anything else.
# Time:  O(1) (a handful of files).
# Space: O(1).
cleanup() {
	case $SCRATCH in
	"$WORK"/tmp/build-rmcore.????????)
		rm -rf "$SCRATCH"
		;;
	esac
}
# EXIT always runs cleanup; INT/TERM exit with the conventional 128+n
# status so the trap cannot clean up and then let the build carry on.
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# The source checkout must be at the commit SOURCES pins, before anything
# is copied or built.
if [ ! -f "$SOURCESFILE" ]; then
	echo "build-rmcore: missing SOURCES file: $SOURCESFILE" >&2
	exit 1
fi
want_commit=$(sources_get "$SOURCESFILE" ogkm_commit) || {
	echo "build-rmcore: SOURCES: no ogkm_commit" >&2
	exit 1
}
if [ ! -d "$SRC" ]; then
	echo "build-rmcore: run scripts/fetch-sources.sh first ($SRC missing)" >&2
	exit 1
fi
# git_safe, like every git call here: a leaked GIT_DIR must not answer for
# a decoy repository while the clean-tree checks look at the real one.
got_commit=$(git_safe git -C "$SRC" rev-parse HEAD 2>/dev/null) || {
	echo "build-rmcore: $SRC is not a git checkout" >&2
	exit 1
}
if [ "$got_commit" != "$want_commit" ]; then
	echo "build-rmcore: commit mismatch for $SRC: SOURCES pins $want_commit, checkout is at $got_commit" >&2
	exit 1
fi
# The pinned commit alone is not evidence: the tracked tree must also match
# HEAD, or what is copied and built is not the pin. Shared with
# fetch-sources.sh, which checks the same checkout (scripts/lib.sh).
git_tree_is_clean build-rmcore git "$SRC" || exit 1
# The copy must be exactly the pin: refuse untracked or ignored files too,
# which a recursive copy would silently carry into the build.
git_tree_has_no_extra_files build-rmcore git "$SRC" || exit 1

# Path safety before anything destructive: BUILDDIR must resolve strictly
# under $WORK/build, must not be a symlink, and must carry the $MARKER file
# if it already exists (safe_build_dir, scripts/lib.sh).
safe_build_dir "$BUILDDIR" "$MARKER" || exit 1
# Replace an existing BUILDDIR only if this script made it: the marker's
# first line must name this script and this exact resolved path; any other
# directory is refused and left untouched.
if [ -e "$BUILDDIR" ]; then
	BRES=$(realpath "$BUILDDIR" 2>/dev/null) || BRES=
	mfirst=$(head -n 1 "$BUILDDIR/$MARKER" 2>/dev/null) || mfirst=
	if [ "$mfirst" != "gb10 build-rmcore.sh $BRES" ]; then
		echo "build-rmcore: refusing to replace $BUILDDIR: $MARKER does not begin with 'gb10 build-rmcore.sh $BRES'" >&2
		exit 1
	fi
	rm -rf "$BUILDDIR"
fi
mkdir -p "$BUILDDIR" "$(dirname "$LOG")"
BRES=$(realpath "$BUILDDIR") || {
	echo "build-rmcore: cannot resolve $BUILDDIR" >&2
	exit 1
}
# Mark the copy first, so an interrupted run can still be replaced: line 1
# says who wrote the marker and where it stands, line 2 says "state
# building"; rewritten to "state done" via a temp file and mv(1) once the
# object is built.
printf 'gb10 build-rmcore.sh %s\nstate building\n' "$BRES" > "$BUILDDIR/$MARKER"
cp -R "$SRC"/. "$BUILDDIR"/

# apply_patches - apply every $OGKMPATCHDIR/patch-* to the build copy in
# lexical order (LC_ALL=C globbing), after refusing any patch whose ---/+++
# header paths are absolute or hold a .. component (patch -p0 would follow
# them out of the copy); on the first failure, name the patch
# and exit 1, exactly like prepare-tree.sh does.
# Time:  O(P) patch(1) runs for P patch files; each header scan is linear
#        in the patch file's lines, each run linear in the
#        size of the file it patches (patch(1) internals).
# Space: O(1) in this shell; patch(1) buffers one file at a time.
apply_patches() {
	for p in "$OGKMPATCHDIR"/patch-*; do
		[ -e "$p" ] || continue
		if ! patch_headers_safe "$p"; then
			echo "build-rmcore: refusing patch $(basename "$p"): ---/+++ path is absolute or holds a .. component" >&2
			exit 1
		fi
		if ! patch -d "$BUILDDIR" -p0 -E -s -i "$p"; then
			echo "build-rmcore: patch failed: $(basename "$p")" >&2
			exit 1
		fi
	done
}
apply_patches
# The BTI/PAC property notes are what -zbti-report=error checks, so a tree in
# which the Makefile still strips them would build an nvidia.ko that cannot
# link. Refuse it here rather than after a long build.
if grep -q -- '--remove-section=.note.gnu.property' "$BUILDDIR/src/nvidia/Makefile"; then
	echo "build-rmcore: src/nvidia/Makefile still strips .note.gnu.property after patching" >&2
	exit 1
fi

# Half the CPUs, at least one.
JOBS=$(sysctl -n hw.ncpu)
JOBS=$((JOBS / 2))
if [ "$JOBS" -lt 1 ]; then
	JOBS=1
fi

cd "$BUILDDIR/src/nvidia"
# CFLAGS goes through the environment, never the gmake command line:
# utils.mk is `CFLAGS ?= -Wall` with `+=` appends after it, so an
# environment CFLAGS keeps every core flag and adds
# -mbranch-protection=standard (BTI+PAC property notes in every object,
# which the -zbti-report=error kmod link on FreeBSD 16 arm64 requires),
# while a command-line CFLAGS would replace all of NVIDIA's flags.
if ! env -u MAKEFLAGS -u GNUMAKEFLAGS -u MFLAGS -u MAKELEVEL \
	CFLAGS='-Wall -mbranch-protection=standard' \
	nice -n 10 "$GMAKE" -j"$JOBS" \
	TARGET_OS=FreeBSD TARGET_ARCH=aarch64 \
	CC=cc CXX=c++ LD=ld.lld OBJCOPY=llvm-objcopy \
	NV_BUILD_USER=cloudbsd NV_BUILD_HOST=build > "$LOG" 2>&1; then
	echo "build-rmcore: gmake failed; see $LOG" >&2
	exit 1
fi

OBJ=_out/FreeBSD_aarch64/nv-kernel.o
if [ ! -f "$OBJ" ]; then
	echo "build-rmcore: gmake exited 0 but $BUILDDIR/src/nvidia/$OBJ is missing; see $LOG" >&2
	exit 1
fi

# The build copy is complete: rewrite the marker to "state done" via a temp
# file and mv(1), so no reader ever sees "done" on a half-built copy or a
# half-written marker.
{
	printf 'gb10 build-rmcore.sh %s\n' "$BRES"
	printf 'state done\n'
} > "$BUILDDIR/$MARKER.new"
mv "$BUILDDIR/$MARKER.new" "$BUILDDIR/$MARKER"

mkdir -p "$(dirname "$OUT")"
cp "$OBJ" "$OUT"
printf 'nv-kernel.o: %s bytes, sha256 %s\n' \
	"$(stat -f %z "$OUT")" "$(sha256 -q "$OUT")"
# Under set -e a failing command substitution would exit here, after a good
# build; report it instead (the symbol check is in kmod_symbols_test.sh).
if _n=$(count_missing "$OUT" "$OSOBJDIR" "$SCRATCH"); then
	[ -n "$_n" ] && printf 'undefined not in OS layer: %s\n' "$_n"
else
	echo "build-rmcore: note: could not count undefined symbols against the OS layer (no OS-layer objects yet?)"
fi
echo "build-rmcore: $OUT ready (log: $LOG)"
