#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# build-linux-cuda.sh - build the Linux aarch64 CUDA test programs and the
# LD_PRELOAD shim in tests/cuda/ with FreeBSD clang against a Linux sysroot.
#
# Usage: scripts/build-linux-cuda.sh [-h|--help]
#
# Environment:
#   GB10_WORK  work root (default $HOME/work/gb10); not needed when LINUXROOT
#              and BUILDDIR are both set
#   LINUXROOT  Linux roots (default $GB10_WORK/linuxroot); the Rocky 9 tree
#              LINUXROOT/rl9 is the sysroot
#   BUILDDIR   output directory (default $GB10_WORK/build/linux-cuda); it is
#              never inside the repository
#   CLANG      the compiler (default clang)
#
# Output in BUILDDIR: shim.so, cuinit, cuda_smoke, cuda_vecadd,
# test_shim_abstract. Run them with scripts/run-linux-cuda.sh.
#
# Exit status: 0 built, 1 build failed or the sysroot is missing, 2 usage or
# no work root.

set -eu

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

case "${1:-}" in
-h | --help)
	sed -n '5,/^# Exit status/p' "$0" | sed 's/^# \{0,1\}//'
	exit 0
	;;
"") ;;
*)
	echo "usage: $0 [-h|--help]" >&2
	exit 2
	;;
esac

if [ -z "${GB10_WORK:-}" ] && { [ -z "${LINUXROOT:-}" ] || [ -z "${BUILDDIR:-}" ]; }; then
	if [ -z "${HOME:-}" ]; then
		echo "build-linux-cuda: HOME is not set and GB10_WORK is not set" >&2
		exit 2
	fi
fi
WORK=${GB10_WORK:-${HOME:-/nonexistent}/work/gb10}
LINUXROOT=${LINUXROOT:-$WORK/linuxroot}
BUILDDIR=${BUILDDIR:-$WORK/build/linux-cuda}
CLANG=${CLANG:-clang}
SRC=$(CDPATH= cd -- "$(dirname -- "$0")/../tests/cuda" && pwd)
R=$LINUXROOT/rl9

if [ ! -d "$R/usr/lib64" ]; then
	echo "build-linux-cuda: missing sysroot $R/usr/lib64 (set LINUXROOT)" >&2
	exit 1
fi
GCCINC=$(ls -d "$R"/usr/lib/gcc/aarch64-redhat-linux/*/include 2> /dev/null | tail -n 1)
if [ -z "$GCCINC" ]; then
	echo "build-linux-cuda: missing $R/usr/lib/gcc/aarch64-redhat-linux/*/include" >&2
	exit 1
fi
mkdir -p "$BUILDDIR"

# cc_linux ARGS... - FreeBSD clang for Linux aarch64 against the rl9 sysroot.
cc_linux() {
	"$CLANG" --target=aarch64-redhat-linux-gnu --sysroot="$R" \
	    -isystem "$GCCINC" -O2 -Wall -Werror -fuse-ld=lld \
	    -L"$R/usr/lib64" "$@"
}

cc_linux -shared -fPIC -o "$BUILDDIR/shim.so" "$SRC/shim.c" -ldl
for p in cuinit cuda_smoke test_shim_abstract; do
	cc_linux -o "$BUILDDIR/$p" "$SRC/$p.c" -ldl
done
cc_linux -o "$BUILDDIR/cuda_vecadd" "$SRC/cuda_vecadd.c" -ldl -lm
echo "build-linux-cuda: OK $BUILDDIR"
