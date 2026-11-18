#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# build-firmware.sh - build the GSP firmware module for arm64:
# TREE/firmware/gsp_ga10x/Makefile (NVIDIA's) declares
# KMOD= nvidia_gsp_ga10x_fw and FIRMWS= gsp_ga10x.bin:${KMOD}, so
# bsd.kmod.mk assembles gsp_ga10x.bin into a firmware(9) module named
# nvidia_gsp_ga10x_fw - the name nvidia.ko requests via
# NV_FIRMWARE_FOR_NAME("gsp_ga10x") (nvidia/nvidia_subr.c:13).
#
# Usage: scripts/build-firmware.sh [TREE] [LOG]
#   TREE      prepared working tree (from scripts/prepare-tree.sh, which
#             extracts firmware/); defaults to
#             ${GB10_WORK:-$HOME/work/gb10}/build/tree
#   LOG       build log to write; defaults to
#             ${GB10_WORK:-$HOME/work/gb10}/logs/build-firmware-<UTC stamp>.log
#             The same rule build-shim.sh enforces applies (log_path_safe
#             in scripts/lib.sh): a symlink is refused, and so is any path
#             whose directory does not resolve under $WORK/logs.
#
# Environment:
#   GB10_WORK work root holding the default TREE and logs/
#   SYSDIR    kernel source sys/ directory; defaults to /usr/src/sys
#
# The build runs in place in TREE/firmware/gsp_ga10x (like build-shim.sh:
# the tree is disposable, prepare-tree.sh rebuilds it from scratch).
# This is a gate: it exits 1 when make fails, when the .ko is missing, or
# when LOG is unsafe (a symlink, or its directory does not resolve under
# $WORK/logs), 2 when TREE/firmware/gsp_ga10x is missing, 0 on success
# after printing "nvidia_gsp_ga10x_fw.ko: <size> bytes, sha256 <x>".
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
	echo "usage: build-firmware.sh [TREE] [LOG]" >&2
	exit 1
fi

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

if ! make -C "$TREE/firmware/gsp_ga10x" \
    MACHINE=arm64 MACHINE_ARCH=aarch64 \
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
