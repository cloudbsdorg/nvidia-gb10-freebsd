#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# build-firmware.sh - build the GSP firmware module for the running
# architecture (aarch64 or amd64):
# TREE/firmware/gsp_ga10x/Makefile (NVIDIA's) declares
# KMOD= nvidia_gsp_ga10x_fw and FIRMWS= gsp_ga10x.bin:${KMOD}, so
# bsd.kmod.mk assembles gsp_ga10x.bin into a firmware(9) module named
# nvidia_gsp_ga10x_fw - the name nvidia.ko requests via
# NV_FIRMWARE_FOR_NAME("gsp_ga10x") (nvidia/nvidia_subr.c:13).
#
# The module is built for the RUNNING architecture, not for a fixed
# one: make is given the MACHINE and MACHINE_ARCH of the architecture
# the host compiler targets, so bsd.kmod.mk takes the CFLAGS of that
# architecture. A fixed MACHINE=arm64 on an amd64 host made bsd.kmod.mk
# use the CFLAGS of /usr/src/sys/arm64/include (including
# -mno-outline-atomics) while cc still targeted x86_64, and the compile
# died with "'x86_64' does not support '-mno-outline-atomics'; flag
# ignored [-Werror,-Woption-ignored]" (Track #2475).
#
# Usage: scripts/build-firmware.sh [TREE] [LOG]
#   TREE      prepared working tree (from scripts/prepare-tree.sh, which
#             extracts firmware/); defaults to
#             ${GB10_WORK:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)/work}/build/tree
#   LOG       build log to write; defaults to
#             ${GB10_WORK:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)/work}/logs/build-firmware-<UTC stamp>.log
#             The same rule build-shim.sh enforces applies (log_path_safe
#             in scripts/lib.sh): a symlink is refused, and so is any path
#             whose directory does not resolve under $WORK/logs.
#
# Environment:
#   GB10_WORK work root holding the default TREE and logs/
#   SYSDIR    kernel source sys/ directory; defaults to /usr/src/sys
#   GB10_TEST_HOOKS
#             set to 1 to let the test hook below be taken from the
#             environment; without it the hook is ignored and the host's
#             own architecture decides
#   GB10_TEST_ARCH
#             test hook: the architecture to build for, aarch64 or amd64;
#             honoured only with GB10_TEST_HOOKS=1, and when it is unset
#             (or the hooks are off) the host's `uname -p` decides. Any
#             other architecture is refused with exit 1, never a fallback
#             to aarch64
#
# The build runs in place in TREE/firmware/gsp_ga10x (like build-shim.sh:
# the tree is disposable, prepare-tree.sh rebuilds it from scratch).
# This is a gate: it exits 1 when make fails, when the .ko is missing, when
# LOG is unsafe (a symlink, or its directory does not resolve under
# $WORK/logs), or when the architecture is neither aarch64 nor amd64,
# 2 when TREE/firmware/gsp_ga10x is missing, 0 on success
# after printing "nvidia_gsp_ga10x_fw.ko: <size> bytes, sha256 <x>".
# A stale .ko is removed before the build and make runs under
# `env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL -u MAKEOBJDIR
# -u MAKEOBJDIRPREFIX`, so an inherited MAKEFLAGS=-i/-n cannot turn the
# build into a no-op that still reports an earlier run's artifact
# (pass-3 u13 #1).
# The log is never /tmp; scratch files stay under $WORK/tmp.

set -eu

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

WORK=${GB10_WORK:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)/work}
SYSDIR=${SYSDIR:-/usr/src/sys}

SCRIPTDIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPTDIR/lib.sh"

if [ $# -gt 2 ]; then
	echo "usage: build-firmware.sh [TREE] [LOG]" >&2
	exit 1
fi

# The architecture the module is built for: the RUNNING architecture.
# The module is compiled by the host compiler, so the make variables
# must describe the architecture that compiler targets - otherwise
# bsd.kmod.mk takes the CFLAGS of one architecture (the arm64 include
# directory, with -mno-outline-atomics) for a compiler of another and
# the compile dies (Track #2475).
#
# The host's own architecture decides - `uname -p` - unless the test
# hook GB10_TEST_ARCH says otherwise. The hook is read from the
# environment ONLY with GB10_TEST_HOOKS=1: test_hook (scripts/lib.sh)
# enforces that, validates the value and announces its use on stderr.
HOSTARCH=$(uname -p) || {
	echo "build-firmware: cannot read the host architecture with uname -p" >&2
	exit 1
}
ARCH=$(test_hook build-firmware GB10_TEST_ARCH "$HOSTARCH") || exit 1
# aarch64 and amd64 are the two architectures FreeBSD names this way (see
# uname -p). Anything else is refused outright: a silent fallback to
# aarch64 would build the wrong module and call it right.
case $ARCH in
aarch64|amd64) ;;
*)
	echo "build-firmware: unsupported architecture: $ARCH (aarch64 or amd64)" >&2
	exit 1
	;;
esac
# The make variables for the resolved architecture: MACHINE is FreeBSD's
# machine name and MACHINE_ARCH its C architecture name (arm64/aarch64 on
# aarch64, amd64/amd64 on amd64).
case $ARCH in
aarch64)
	MACHINE=arm64
	MACHINE_ARCH=aarch64
	;;
amd64)
	MACHINE=amd64
	MACHINE_ARCH=amd64
	;;
esac

TREE=${1:-$WORK/build/tree}
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
LOG=${2:-$WORK/logs/build-firmware-$STAMP.log}

if [ ! -d "$TREE/firmware/gsp_ga10x" ]; then
	echo "build-firmware: no $TREE/firmware/gsp_ga10x: run scripts/prepare-tree.sh first" >&2
	exit 2
fi

# The LOG rule shared with build-shim.sh (log_path_safe in lib.sh):
# refuse a symlink, and refuse anything whose directory does not resolve
# under $WORK/logs, so the build log can never be written through a
# symlink or outside the work root - in particular never /tmp.
log_path_safe build-firmware "$LOG" || exit 1

mkdir -p "$WORK/tmp"
TMPDIR=$WORK/tmp
export TMPDIR

KO=$TREE/firmware/gsp_ga10x/nvidia_gsp_ga10x_fw.ko

# Remove a stale .ko first (pass-3 u13 #1): the build runs in place in the
# tree, so without this an earlier run's module would still be there for
# the size and sha256 report below - even when this run built nothing.
rm -f -- "$KO"

# make runs under `env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL -u MAKEOBJDIR
# -u MAKEOBJDIRPREFIX` (pass-3 u13 #1): an inherited MAKEFLAGS=-i (errors
# ignored) or -n (dry run) from a parent make or a CI wrapper would
# otherwise turn this build into a no-op that still reports success, and
# MAKEOBJDIR(PREFIX) would move the objects out of the tree.
if ! env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL -u MAKEOBJDIR -u MAKEOBJDIRPREFIX \
    make -C "$TREE/firmware/gsp_ga10x" \
    MACHINE="$MACHINE" MACHINE_ARCH="$MACHINE_ARCH" \
    SYSDIR="$SYSDIR" \
    all > "$LOG" 2>&1; then
	echo "build-firmware: make failed; log: $LOG" >&2
	tail -n 20 "$LOG" >&2 || true
	exit 1
fi

echo "log: $LOG"
if [ ! -f "$KO" ]; then
	echo "build-firmware: make succeeded but no $KO" >&2
	exit 1
fi
echo "nvidia_gsp_ga10x_fw.ko: $(stat -f %z "$KO") bytes, sha256 $(sha256 -q "$KO")"
