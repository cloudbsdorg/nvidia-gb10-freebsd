#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# run-linux-cuda.sh - run a Linux aarch64 CUDA program through the
# Linuxulator with the shim preloaded, against NVIDIA's Linux libcuda.
#
# Usage: scripts/run-linux-cuda.sh PROG [ARGS...]
#        PROG is a program built by scripts/build-linux-cuda.sh (a bare name
#        such as cuda_smoke is looked up in BUILDDIR) or a path to a Linux
#        aarch64 program.
#
# Environment:
#   GB10_WORK  work root (default <repo>/work)
#   LINUXROOT  Linux roots (default $GB10_WORK/linuxroot): nv/ holds NVIDIA's
#              libcuda, rl9/ the Rocky 9 libraries and ld-linux
#   BUILDDIR   build output (default $GB10_WORK/build/linux-cuda)
#   SHIM_ABSTRACT_DIR  where the shim keeps abstract unix sockets; keep it
#              short (default $HOME/.cache/sa)
#   SHIM_MMAP_MIN_ADDR, SHIM_COMM  files the shim substitutes for
#              /proc/sys/vm/mmap_min_addr and /proc/self/task/*/comm
#              (default: files the script creates in $HOME/.cache/sa)
#   SHIM_IOCTL_LOG  set to 1 to log ioctl argument blocks
#
# Exit status: that of PROG; 2 usage; 1 a path is missing.

set -eu

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

case "${1:-}" in
-h | --help)
	sed -n '5,/^# Exit status/p' "$0" | sed 's/^# \{0,1\}//'
	exit 0
	;;
"")
	echo "usage: $0 PROG [ARGS...]" >&2
	exit 2
	;;
esac

WORK=${GB10_WORK:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)/work}
LINUXROOT=${LINUXROOT:-$WORK/linuxroot}
BUILDDIR=${BUILDDIR:-$WORK/build/linux-cuda}
CACHE=${HOME:-$WORK}/.cache/sa
R=$LINUXROOT/rl9
LDSO=$R/usr/lib/ld-linux-aarch64.so.1

prog=$1
shift
case "$prog" in
*/*) ;;
*) prog=$BUILDDIR/$prog ;;
esac
for f in "$LDSO" "$BUILDDIR/shim.so" "$prog"; do
	if [ ! -e "$f" ]; then
		echo "run-linux-cuda: missing $f" >&2
		exit 1
	fi
done

mkdir -p "$CACHE"
if [ -z "${SHIM_MMAP_MIN_ADDR:-}" ]; then
	SHIM_MMAP_MIN_ADDR=$CACHE/mmap_min_addr.txt
	printf '65536\n' > "$SHIM_MMAP_MIN_ADDR"
fi
if [ -z "${SHIM_COMM:-}" ]; then
	SHIM_COMM=$CACHE/comm.txt
	printf 'cuda\n' > "$SHIM_COMM"
fi
SHIM_ABSTRACT_DIR=${SHIM_ABSTRACT_DIR:-$CACHE}
export SHIM_MMAP_MIN_ADDR SHIM_COMM SHIM_ABSTRACT_DIR

exec "$LDSO" --preload "$BUILDDIR/shim.so" \
    --library-path "$LINUXROOT/nv:$R/usr/lib64:$R/usr/lib" "$prog" "$@"
