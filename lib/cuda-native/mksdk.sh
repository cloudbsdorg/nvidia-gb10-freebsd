#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-2-Clause
#
# mksdk.sh - assemble the cuda-native SDK tree (Track #2380), the directory
# clang takes as --cuda-path: include/, bin/, nvvm/libdevice/libdevice.10.bc,
# and version.json (our identity, generated from include/cuda.h; clang
# ignores it).  See cuda-native-toolchain(7).
#
#   sh lib/cuda-native/mksdk.sh OUTDIR
#
# OUTDIR must not exist, or be an empty directory, and must not be a
# symbolic link.  LLVM names the LLVM install (default /usr/local/llvm23, the
# ports llvm23 package); its clang must be version 23 or later.  libdevice
# gets the NVPTX data layout of that clang, so the bitcode links into every
# device compile without a layout mismatch.
#
# The tree is built in a new directory next to OUTDIR and renamed into place
# only when every step worked: a failed run leaves OUTDIR as it was.
#
# Exit: 0 built (prints "sdk: OUTDIR"), 2 usage or refused, 1 a step failed.

PATH=/sbin:/bin:/usr/sbin:/usr/bin
export PATH
LLVM=${LLVM:-/usr/local/llvm23}
LLVM_MIN=23

usage() {
	echo "usage: sh $0 OUTDIR    (env LLVM, default /usr/local/llvm23)"
}
die2() {
	echo "mksdk: $*" >&2
	exit 2
}

case ${1:-} in
-h | --help)
	usage
	exit 0
	;;
"" | -*)
	usage >&2
	exit 2
	;;
esac
[ $# -eq 1 ] || { usage >&2; exit 2; }

OUT=$1
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1

[ -L "$OUT" ] && die2 "$OUT is a symbolic link; give a real directory"
if [ -e "$OUT" ]; then
	[ -d "$OUT" ] || die2 "$OUT exists and is not a directory"
	# Time: O(entries in OUT); the directory is expected to be empty.
	# Space: O(entries).
	[ -z "$(ls -A -- "$OUT")" ] ||
	    die2 "$OUT is not empty; give a new or empty directory"
fi
for tool in llvm-as clang; do
	[ -x "$LLVM/bin/$tool" ] ||
	    die2 "$LLVM/bin/$tool not found (pkg install llvm23, or set LLVM)"
done
major=$("$LLVM/bin/clang" --version 2>/dev/null |
    sed -n 's/.*clang version \([0-9][0-9]*\)\..*/\1/p' | sed -n 1p)
[ -n "$major" ] && [ "$major" -ge "$LLVM_MIN" ] ||
    die2 "$LLVM/bin/clang is version ${major:-unknown}; LLVM $LLVM_MIN or later is needed"

# The API level and our release, from the one place they are set: cuda.h.
macro() {
	sed -n "s/^#define $1 \\([0-9][0-9]*\\)\$/\\1/p" "$HERE/sdk/include/cuda.h"
}
api=$(macro CUDA_VERSION)
rel=$(macro CUDA_NATIVE_VERSION)
[ -n "$api" ] && [ -n "$rel" ] || {
	echo "mksdk: CUDA_VERSION or CUDA_NATIVE_VERSION missing in sdk/include/cuda.h" >&2
	exit 1
}

# The data layout clang uses for nvptx64; empty output means clang failed.
layout=$("$LLVM/bin/clang" --target=nvptx64-nvidia-cuda -S -emit-llvm \
    -x c /dev/null -o - 2>/dev/null | grep '^target datalayout') || layout=
[ -n "$layout" ] || {
	echo "mksdk: no nvptx64 data layout from $LLVM/bin/clang" >&2
	exit 1
}

parent=$(dirname -- "$OUT")
[ -d "$parent" ] || mkdir -p -- "$parent" || exit 1
NEW=$(mktemp -d "$parent/.mksdk.XXXXXXXX") || exit 1
trap 'rm -rf -- "$NEW"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir "$NEW/bin" "$NEW/nvvm" "$NEW/nvvm/libdevice" || exit 1
cp -R "$HERE/sdk/include" "$NEW/include" || exit 1
printf '{"cuda":{"name":"cuda-native","version":"%d.%d.%d"},"cuda_native":{"version":"%d.%d.%d","track":"2380"}}\n' \
    $((api / 1000)) $((api % 1000 / 10)) 0 \
    $((rel / 10000)) $((rel % 10000 / 100)) $((rel % 100)) \
    >"$NEW/version.json" || exit 1
{ printf '%s\n' "$layout"; cat "$HERE/libdevice/libdevice.ll"; } |
    "$LLVM/bin/llvm-as" -o "$NEW/nvvm/libdevice/libdevice.10.bc" || exit 1

# mktemp made NEW mode 0700; give the tree the usual directory mode.
chmod 755 "$NEW" || exit 1
if [ -d "$OUT" ]; then
	rmdir -- "$OUT" || exit 1
fi
mv -- "$NEW" "$OUT" || exit 1
trap - EXIT
echo "sdk: $OUT"
