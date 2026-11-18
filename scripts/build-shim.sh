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
# 2 TREE/nvidia
# missing, or TREE/.prepared does not say "state done" (an incomplete or
# interrupted prepare-tree.sh run must never be measured); 3 build failed
# (make's exit status was non-zero). The summary
# ("errors: N" and the sorted unique error lines, file:line: error: ...)
# prints on the OK and FAILED paths alike; "build: OK" or
# "build: FAILED (make rc N)" follows it, and the nvidia.ko size/sha256
# prints only when make succeeded and the file exists. A stale nvidia.ko
# is removed before make so a failed build can never be summarised from
# an earlier run's artifact.
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
# exit status instead of discarding it with "|| true".
rm -f "$TREE/nvidia/nvidia.ko"
rc=0
make -C "$TREE/nvidia" -k \
    MACHINE=arm64 MACHINE_ARCH=aarch64 \
    SYSDIR="$SYSDIR" \
    all > "$LOG" 2>&1 || rc=$?

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
echo "build: OK"
if [ -f "$TREE/nvidia/nvidia.ko" ]; then
	echo "nvidia.ko: $(stat -f %z "$TREE/nvidia/nvidia.ko") bytes, sha256 $(sha256 -q "$TREE/nvidia/nvidia.ko")"
fi
exit 0
