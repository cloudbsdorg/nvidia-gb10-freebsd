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
# The one remedy every LLVM refusal names.
LLVM_FIX="install LLVM $LLVM_MIN or later (pkg install llvm$LLVM_MIN), or set LLVM to the prefix of another LLVM $LLVM_MIN-or-later install (now LLVM=$LLVM)"

# Time: O(1).  Space: O(1).
usage() {
	echo "usage: sh $0 OUTDIR    (env LLVM, default /usr/local/llvm23)"
	echo "       sh $0 --check-llvm"
}
die2() {
	echo "mksdk: $*" >&2
	exit 2
}

# Set major to the clang major version.  On refusal, print the build's
# diagnostic and return 2; the caller decides whether to print the result.
# Time: O(clang version output).  Space: O(1).
check_llvm() {
	major=
	# Time: O(1) (two tool lookups).  Space: O(1).
	for tool in llvm-as clang; do
		if [ ! -x "$LLVM/bin/$tool" ]; then
			echo "mksdk: $LLVM/bin/$tool not found; $LLVM_FIX" >&2
			return 2
		fi
	done
	major=$("$LLVM/bin/clang" --version 2>/dev/null |
	    sed -n 's/.*clang version \([0-9][0-9]*\)\..*/\1/p' | sed -n 1p)
	if [ -z "$major" ] || [ "$major" -lt "$LLVM_MIN" ]; then
		echo "mksdk: $LLVM/bin/clang is version ${major:-unknown}; LLVM $LLVM_MIN or later is needed; $LLVM_FIX" >&2
		return 2
	fi
}

case ${1:-} in
--check-llvm)
	[ $# -eq 1 ] || { usage >&2; exit 2; }
	check_llvm
	rc=$?
	printf 'llvm: %s clang %s\n' "$LLVM" "${major:-unknown}"
	exit "$rc"
	;;
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
# A trailing slash would make the symlink test below look through a link.
# Time: O(trailing slashes).  Space: O(1).
while :; do
	case $OUT in
	?*/) OUT=${OUT%/} ;;
	*) break ;;
	esac
done
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1

[ -L "$OUT" ] && die2 "$OUT is a symbolic link; give a real directory"
if [ -e "$OUT" ]; then
	[ -d "$OUT" ] || die2 "$OUT exists and is not a directory"
	# Time: O(entries in OUT); the directory is expected to be empty.
	# Space: O(entries).
	[ -z "$(ls -A -- "$OUT")" ] ||
	    die2 "$OUT is not empty; give a new or empty directory"
fi
check_llvm || exit 2

# Time: O(1).  Space: O(1).
for src in sdk/include/cuda.h libdevice/libdevice.ll; do
	[ -f "$HERE/$src" ] || {
		echo "mksdk: $HERE/$src is missing; the source tree is incomplete (check out lib/cuda-native again)" >&2
		exit 1
	}
done

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
# This runs before anything is created, so a refused clang leaves nothing.
probe=$("$LLVM/bin/clang" --target=nvptx64-nvidia-cuda -S -emit-llvm \
    -x c /dev/null -o - 2>&1)
layout=$(printf '%s\n' "$probe" | grep '^target datalayout') || layout=
[ -n "$layout" ] || {
	echo "mksdk: $LLVM/bin/clang cannot compile for nvptx64 (built without the NVPTX target?); $LLVM_FIX" >&2
	printf '%s\n' "$probe" | sed -n 1,5p >&2
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
# OUT may have changed while the tree was built: check it again, rename
# without following a link (mv -h), and verify the result.  A window remains
# between rmdir and mv: a directory that lands there is caught after mv,
# anything else makes mv fail.
RETRY="remove it or give another directory, then run mksdk.sh again"
[ -L "$OUT" ] && { echo "mksdk: $OUT became a symbolic link during the build; $RETRY" >&2; exit 1; }
removed=0
if [ -d "$OUT" ]; then
	if ! err=$(rmdir -- "$OUT" 2>&1); then
		if entries=$(ls -A -- "$OUT" 2>/dev/null); then
			if [ -n "$entries" ]; then
				echo "mksdk: $OUT is no longer empty; $RETRY" >&2
			else
				echo "mksdk: cannot remove the empty $OUT to put the tree there; $RETRY" >&2
			fi
		else
			echo "mksdk: cannot read $OUT; $RETRY" >&2
		fi
		[ -z "$err" ] || printf '%s\n' "$err" >&2
		exit 1
	fi
	removed=1
fi
if ! err=$(mv -h -- "$NEW" "$OUT" 2>&1); then
	echo "mksdk: cannot put the tree at $OUT (it changed during the build?); $RETRY" >&2
	[ -z "$err" ] || printf '%s\n' "$err" >&2
	# Put back the empty directory the caller gave.
	[ $removed -eq 1 ] && mkdir -- "$OUT" 2>/dev/null
	exit 1
fi
# mv moves NEW into OUT when a directory appeared there after rmdir: the
# tree then sits at OUT/<name of NEW>, not at OUT.
if [ -L "$OUT" ] || [ -e "$OUT/${NEW##*/}" ] || [ ! -f "$OUT/include/cuda.h" ]; then
	echo "mksdk: $OUT changed during the build; the tree is not in place (a copy may be left at $OUT/${NEW##*/}); $RETRY" >&2
	exit 1
fi
trap - EXIT
echo "sdk: $OUT"
