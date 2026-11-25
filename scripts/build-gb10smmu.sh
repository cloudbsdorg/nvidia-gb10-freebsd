#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# build-gb10smmu.sh - build gb10smmu.ko, the module that programs the SMMUv3
# in front of the GB10 GPU.
#
# Usage: scripts/build-gb10smmu.sh [-h|--help] [LOG]
#   LOG       build log to write; it must resolve under
#             ${GB10_WORK:-<repo>/work}/logs; defaults to
#             ${GB10_WORK:-<repo>/work}/logs/build-gb10smmu-<UTC stamp>.log
#
# Environment:
#   GB10_WORK work root holding the default build directory and logs/
#   SYSDIR    kernel source sys/ directory; defaults to /usr/src/sys
#
# The module is ours, not NVIDIA's: it lives in src/gb10-smmu and is built
# on its own with bsd.kmod.mk.  It programs an arm64 SMMU, so it is built
# on arm64 only; on another architecture this script says so and exits 1
# without building anything.
#
# The source is copied into the work root before it is built, so the
# checkout keeps no build output: bsd.kmod.mk writes its objects and its
# opt_*.h into the directory it runs in.
#
# Exit codes: 0 build OK; 1 usage error, not arm64, or an unsafe path;
# 3 build failed: make's exit status was non-zero, or make returned 0 but
# left no non-empty gb10smmu.ko.
#
# The module is only built, never loaded: loading it programs the SMMU of
# the running machine.

set -eu

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
LC_ALL=C
LD=/usr/bin/ld
OBJCOPY=/usr/bin/objcopy
export PATH LC_ALL LD OBJCOPY

WORK=${GB10_WORK:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)/work}
SYSDIR=${SYSDIR:-/usr/src/sys}

SCRIPTDIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$SCRIPTDIR/.." && pwd -P)
. "$SCRIPTDIR/lib.sh"

usage() {
	cat <<EOF
usage: build-gb10smmu.sh [-h|--help] [LOG]

  LOG   build log to write; it must resolve under
        ${WORK}/logs
        default: ${WORK}/logs/build-gb10smmu-<UTC stamp>.log

The module programs an arm64 SMMU, so it is built on arm64 only: on
another architecture this script says so and exits 1.
EOF
}

case ${1:-} in
-h|--help)
	usage
	exit 0
	;;
esac

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
LOG=${1:-$WORK/logs/build-gb10smmu-$STAMP.log}

case $(uname -m) in
arm64|aarch64) ;;
*)
	echo "build-gb10smmu: this module programs an arm64 SMMU: it is built on arm64 only, not on $(uname -m)" >&2
	exit 1
	;;
esac

if [ ! -d "$REPO/src/gb10-smmu" ]; then
	echo "build-gb10smmu: no $REPO/src/gb10-smmu" >&2
	exit 1
fi

# The log may be any path: refuse a symlink, and refuse anything whose
# directory does not resolve under $WORK/logs, so the build log can never
# be written through a symlink or outside the work root.
log_path_safe build-gb10smmu "$LOG" || exit 1

# $WORK/tmp must belong to the current user and must not be writable by
# group or other, or scratch files could be planted by someone else.
if [ -L "$WORK/tmp" ]; then
	echo "build-gb10smmu: refusing $WORK/tmp: symlink" >&2
	exit 1
fi
mkdir -p "$WORK/tmp"
tmpstat=$(stat -f '%u %Lp' "$WORK/tmp") || {
	echo "build-gb10smmu: cannot stat $WORK/tmp" >&2
	exit 1
}
tmpowner=${tmpstat%% *}
tmpmode=${tmpstat##* }
uid=$(id -u)
if [ "$tmpowner" != "$uid" ]; then
	echo "build-gb10smmu: refusing $WORK/tmp: owned by uid $tmpowner, not $uid" >&2
	exit 1
fi
if [ $((0$tmpmode & 022)) -ne 0 ]; then
	echo "build-gb10smmu: refusing $WORK/tmp: group or other writable (mode $tmpmode)" >&2
	exit 1
fi
# The scratch directory of this run is a fresh one of our own, so nothing
# someone else put in $WORK/tmp is used and nothing of ours is left there.
SCRATCH=$(mktemp -d "$WORK/tmp/build.XXXXXXXX") || {
	echo "build-gb10smmu: cannot make a scratch directory in $WORK/tmp" >&2
	exit 1
}
TMPDIR=$SCRATCH
export TMPDIR
trap 'rm -rf -- "$SCRATCH"' EXIT INT TERM

# The source is copied into the work root: bsd.kmod.mk builds in the
# directory it runs in, and the checkout must keep no build output.
SRC=$WORK/build/gb10-smmu
rm -rf -- "$SRC"
mkdir -p -- "$WORK/build"
cp -R -- "$REPO/src/gb10-smmu" "$SRC"

# The log is written to a name of our own in the directory of the log and
# renamed into place, so that a symbolic link put there in the meantime is
# replaced and not written through.
LOGDIR=$(dirname -- "$LOG")
LOGWORK=$LOGDIR/.build-gb10smmu.$$.log
( set -C; : > "$LOGWORK" ) 2>/dev/null || {
	echo "build-gb10smmu: cannot write $LOGWORK" >&2
	exit 1
}
rm -f -- "$SRC/gb10smmu.ko"
rc=0
# make runs with an empty environment: the variables of the caller cannot
# reach it, not MAKEFILES and not MAKEFLAGS, so nothing that is not named
# here can change what is built.
env -i \
    PATH="$PATH" \
    LC_ALL=C \
    TMPDIR="$TMPDIR" \
    SYSDIR="$SYSDIR" \
    LD="$LD" \
    OBJCOPY="$OBJCOPY" \
    /usr/bin/make -C "$SRC" \
    MACHINE=arm64 MACHINE_ARCH=aarch64 \
    SYSDIR="$SYSDIR" \
    all >> "$LOGWORK" 2>&1 || rc=$?
mv -f -- "$LOGWORK" "$LOG"

echo "log: $LOG"
if [ "$rc" -ne 0 ]; then
	echo "build: FAILED (make rc $rc)"
	exit 3
fi
# "build: OK" needs positive evidence: a non-empty module produced by THIS
# run (the stale one was removed before make).
if [ ! -s "$SRC/gb10smmu.ko" ]; then
	echo "build: FAILED (no gb10smmu.ko)"
	exit 3
fi
# The module must be linked by the base linker: /usr/local/bin may hold a
# GNU ld that links a .ko which builds but does not load.
readelf -p .comment "$SRC/gb10smmu.ko" 2>/dev/null | grep -q 'Linker: LLD' || {
	echo "build: FAILED ($SRC/gb10smmu.ko was not linked by LLD)"
	exit 3
}

# The module lands in $WORK/build/gb10smmu.ko.  It is written to a name of
# our own in the same directory and renamed into place, so a symbolic link
# that someone put there is replaced and not written through.
OUT=$WORK/build/gb10smmu.ko
OUTWORK=$WORK/build/.gb10smmu.$$.ko
( set -C; : > "$OUTWORK" ) 2>/dev/null || {
	echo "build: FAILED (cannot write $OUTWORK)"
	exit 3
}
if ! cp -- "$SRC/gb10smmu.ko" "$OUTWORK"; then
	rm -f -- "$OUTWORK"
	echo "build: FAILED (cannot copy the module)"
	exit 3
fi
chmod 555 "$OUTWORK"
mv -f -- "$OUTWORK" "$OUT"
echo "build: OK"
echo "gb10smmu.ko: $(stat -f %z "$WORK/build/gb10smmu.ko") bytes, sha256 $(sha256 -q "$WORK/build/gb10smmu.ko")"
exit 0
