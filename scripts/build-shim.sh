#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# build-shim.sh - measure the arm64 compile state of NVIDIA's FreeBSD OS
# layer: build TREE/nvidia for arm64 and summarise the compiler errors.
#
# Usage: scripts/build-shim.sh [TREE] [LOG]
#   TREE      prepared working tree (from scripts/prepare-tree.sh); defaults
#             to ${GB10_WORK:-$HOME/work/gb10}/build/tree
#   LOG       build log to write; defaults to
#             ${GB10_WORK:-$HOME/work/gb10}/logs/build-shim-<UTC stamp>.log
#
# Environment:
#   GB10_WORK work root holding the default TREE and logs/
#   SYSDIR    kernel source sys/ directory; defaults to /usr/src/sys
#   RMOBJ     aarch64 RM core object to link in place of NVIDIA's amd64
#             blob (scripts/build-rmcore.sh + build-stubs.sh produce
#             $WORK/build/nv-kernel-gb10.o); defaults to that path
#
# Exit codes: 0 build OK; 1 usage error, or an unsafe LOG (a symlink, or
# its directory does not resolve under $WORK/logs) or an unsafe $WORK/tmp
# (a symlink, not owned by the current user, or group/other writable);
# 2 TREE/nvidia missing, or TREE/.prepared does not say "state done" (an
# incomplete or interrupted prepare-tree.sh run must never be measured);
# 3 build failed: make's exit status was non-zero, the pre-build
# `make clean` (SYSDIR stamp change, see below) failed, or make returned 0
# but left no non-empty TREE/nvidia/nvidia.ko - "build: OK" prints only
# when this run's module exists, so an inherited MAKEFLAGS=-i/-n can never
# report a build that did not happen (pass-3 u04 #1). The summary
# ("errors: N" and the sorted unique error lines, file:line: error: ...)
# prints on the OK and FAILED paths alike; "build: OK" or
# "build: FAILED (...)" follows it, and the nvidia.ko size/sha256 prints
# only on the OK path. A stale nvidia.ko
# is removed before make so a failed build can never be summarised from
# an earlier run's artifact. make runs under
# `env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL -u MAKEOBJDIR
# -u MAKEOBJDIRPREFIX`, so flags or object-directory overrides leaked from
# a parent make or a CI wrapper cannot change what the build does or where
# its objects go.
#
# SYSDIR stamp: the objects in TREE/nvidia are compiled against one SYSDIR;
# silently reusing them after SYSDIR (or its sys/param.h
# __FreeBSD_version) changed once produced an identical nvidia.ko sha256
# across a SYSDIR change (2026-11-18). The SYSDIR path and version are
# recorded in TREE/nvidia/.gb10-sysdir; when the recorded stamp differs -
# or is absent while objects of unknown origin are present - `make clean`
# runs before the build.
# The log is never /tmp; scratch files stay under $WORK/tmp.

set -eu

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

WORK=${GB10_WORK:-$HOME/work/gb10}
SYSDIR=${SYSDIR:-/usr/src/sys}

SCRIPTDIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPTDIR/lib.sh"

if [ $# -gt 2 ]; then
	echo "usage: build-shim.sh [TREE] [LOG]" >&2
	exit 1
fi

TREE=${1:-$WORK/build/tree}
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
LOG=${2:-$WORK/logs/build-shim-$STAMP.log}

if [ ! -d "$TREE/nvidia" ]; then
	echo "build-shim: no $TREE/nvidia: run scripts/prepare-tree.sh first" >&2
	exit 2
fi

# The TREE must be a COMPLETED prepare-tree.sh run: line 2 of its .prepared
# marker must say "state done" (line 1 names the script and the resolved
# path that wrote it). A marker still saying "state building" belongs to a
# run in flight or an interrupted one; measuring that tree would report a
# half-built state as the real one. Fail closed: an unreadable or missing
# marker is refused too.
if [ ! -f "$TREE/.prepared" ] \
    || [ "$(sed -n '2p' "$TREE/.prepared" 2>/dev/null)" != "state done" ]; then
	echo "build-shim: refusing TREE $TREE: .prepared does not say 'state done': run scripts/prepare-tree.sh" >&2
	exit 2
fi

# LOG may be any path: refuse a symlink, and refuse anything whose
# directory does not resolve (realpath) under $WORK/logs, so the build
# log can never be written through a symlink or outside the work root.
# The rule is log_path_safe in lib.sh, shared with build-firmware.sh.
log_path_safe build-shim "$LOG" || exit 1

# $WORK/tmp must belong to the current user and must not be writable by
# group or other, or scratch files could be planted by someone else.
# stat(1) uses lstat(2) unless given -L, so a symlink to a directory would
# answer the owner/mode check from the LINK ITSELF (its own 0755 mode and
# this user's uid always pass) while TMPDIR then points at the arbitrary -
# possibly 0777, possibly /tmp - target: refuse a symlink before the stat
# (pass-2 u04 #2, same fix as fetch-sources.sh's DESTDIR).
if [ -L "$WORK/tmp" ]; then
	echo "build-shim: refusing $WORK/tmp: symlink" >&2
	exit 1
fi
mkdir -p "$WORK/tmp"
tmpstat=$(stat -f '%u %Lp' "$WORK/tmp") || {
	echo "build-shim: cannot stat $WORK/tmp" >&2
	exit 1
}
tmpowner=${tmpstat%% *}
tmpmode=${tmpstat##* }
uid=$(id -u)
if [ "$tmpowner" != "$uid" ]; then
	echo "build-shim: refusing $WORK/tmp: owned by uid $tmpowner, not $uid" >&2
	exit 1
fi
if [ $((0$tmpmode & 022)) -ne 0 ]; then
	echo "build-shim: refusing $WORK/tmp: group or other writable (mode $tmpmode)" >&2
	exit 1
fi
TMPDIR=$WORK/tmp
export TMPDIR

# SYSDIR stamp (see the header): record which SYSDIR - and which
# __FreeBSD_version from its sys/param.h - the objects in TREE/nvidia are
# built against, and clean them when that changes. Reusing objects built
# against an older SYSDIR silently links stale code: on 2026-11-18 a
# SYSDIR change produced a byte-identical nvidia.ko because only the .ko
# was removed, not the objects it was linked from. The stamp lives in
# TREE/nvidia; prepare-tree.sh rebuilds TREE from scratch, so a fresh tree
# starts unstamped (and object-free, so no clean is needed).
STAMPFILE=$TREE/nvidia/.gb10-sysdir
sysver=$(awk '$1 == "#define" && $2 == "__FreeBSD_version" { print $3; exit }' \
    "$SYSDIR/sys/param.h" 2>/dev/null) || sysver=
[ -n "$sysver" ] || sysver=unknown
sysstamp="sysdir $SYSDIR
version $sysver"
# A symlinked stamp would be read from, and written through to, somewhere
# else; refuse it like every other path this script writes.
if [ -L "$STAMPFILE" ]; then
	echo "build-shim: refusing $STAMPFILE: symlink" >&2
	exit 1
fi
oldstamp=$(cat "$STAMPFILE" 2>/dev/null) || oldstamp=
need_clean=0
if [ "$sysver" = unknown ]; then
	# An unreadable sys/param.h cannot prove the objects match: clean
	# always, even when an earlier run left the same "unknown" stamp.
	need_clean=1
elif [ -n "$oldstamp" ]; then
	[ "$oldstamp" = "$sysstamp" ] || need_clean=1
else
	# No stamp: any object already in the tree is of unknown origin.
	for _f in "$TREE"/nvidia/*.o "$TREE"/nvidia/*.kld "$TREE"/nvidia/*.ko; do
		if [ -e "$_f" ]; then
			need_clean=1
			break
		fi
	done
fi
: > "$LOG"
if [ "$need_clean" -eq 1 ]; then
	echo "build-shim: SYSDIR ($SYSDIR, __FreeBSD_version $sysver) differs from the stamp; running make clean first"
	crc=0
	env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL -u MAKEOBJDIR -u MAKEOBJDIRPREFIX \
	    make -C "$TREE/nvidia" \
	    MACHINE=arm64 MACHINE_ARCH=aarch64 \
	    SYSDIR="$SYSDIR" \
	    clean >> "$LOG" 2>&1 || crc=$?
	if [ "$crc" -ne 0 ]; then
		echo "build-shim: FAILED (make clean rc $crc)"
		exit 3
	fi
fi
# Written BEFORE the build: the stamp then always names the SYSDIR the
# objects in the tree - complete or partial - were compiled against.
printf '%s\n' "$sysstamp" > "$STAMPFILE"

# RM core swap - link against the open RM core for aarch64 (plus the
# fail-closed stubs) when it has been built; otherwise link whatever
# nv-kernel.o is already in TREE - and SAY which object that is by sha256,
# because an earlier run's swap may have replaced NVIDIA's blob and "as-is"
# would misreport what gets linked (pass-2 u04 #3). Only the disposable
# TREE copy of nv-kernel.o is ever touched; NVIDIA's own file under src/
# stays pristine.
RMOBJ=${RMOBJ:-$WORK/build/nv-kernel-gb10.o}
if [ -f "$RMOBJ" ]; then
	cp "$RMOBJ" "$TREE/nvidia/nv-kernel.o"
	echo "rm core: $RMOBJ -> $TREE/nvidia/nv-kernel.o sha256 $(sha256 -q "$TREE/nvidia/nv-kernel.o")"
elif [ -f "$TREE/nvidia/nv-kernel.o" ]; then
	echo "rm core: no $RMOBJ: linking the nv-kernel.o already in TREE, sha256 $(sha256 -q "$TREE/nvidia/nv-kernel.o")"
else
	echo "rm core: no $RMOBJ and no $TREE/nvidia/nv-kernel.o in TREE: the link will have no RM core object"
fi

# The build itself: cross-compile flags for arm64, -k so every file gets a
# verdict. Build in TREE/nvidia itself, not an object directory: with
# MAKEOBJDIR + the obj target, nvidia/Makefile's stdarg.h symlink and
# bsd.kmod.mk's machine link are made in the object directory, where the
# compiler does not find them (nv_stdarg.h:36: 'stdarg.h' file not found).
# The tree is disposable (prepare-tree.sh rebuilds it from scratch on every
# run), so in-tree objects are fine.
# Remove any stale nvidia.ko first: a failed make must never leave an
# earlier run's artifact behind for the summary to report. Keep make's
# exit status instead of discarding it with "|| true". env -u strips the
# inherited make variables (pass-3 u04 #1): a MAKEFLAGS=-i/-n leaked from
# a parent make or a CI wrapper would otherwise turn a failed or dry-run
# build into an exit 0, and MAKEOBJDIR(PREFIX) would move the objects
# away from the tree that gets summarised.
rm -f "$TREE/nvidia/nvidia.ko"
rc=0
env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL -u MAKEOBJDIR -u MAKEOBJDIRPREFIX \
    make -C "$TREE/nvidia" -k \
    MACHINE=arm64 MACHINE_ARCH=aarch64 \
    SYSDIR="$SYSDIR" \
    all >> "$LOG" 2>&1 || rc=$?

# summarise - print "errors: N" and the sorted unique ' error: ' lines of
# LOG with their file:line prefixes.
# Time:  O(L log L) for L log lines (grep pass, then sort -u).
# Space: O(E) for E error lines held by sort.
summarise() {
	_n=$(grep -c ' error: ' "$LOG" || true)
	printf 'errors: %s\n' "${_n:-0}"
	if [ "${_n:-0}" -gt 0 ]; then
		grep ' error: ' "$LOG" | sort -u
	fi
}

echo "log: $LOG"
summarise
if [ "$rc" -ne 0 ]; then
	echo "build: FAILED (make rc $rc)"
	exit 3
fi
# "build: OK" requires positive evidence: a non-empty nvidia.ko produced by
# THIS run (the stale one was removed before make). Without this gate a
# make that exits 0 while building nothing - an inherited MAKEFLAGS=-i/-n
# that reached it, or a Makefile regression - reports a build that did not
# happen (pass-3 u04 #1).
if [ ! -s "$TREE/nvidia/nvidia.ko" ]; then
	echo "build: FAILED (no nvidia.ko)"
	exit 3
fi
echo "build: OK"
echo "nvidia.ko: $(stat -f %z "$TREE/nvidia/nvidia.ko") bytes, sha256 $(sha256 -q "$TREE/nvidia/nvidia.ko")"
exit 0
