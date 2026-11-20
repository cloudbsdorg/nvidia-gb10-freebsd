#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# kapi_table_test.sh - the NVKMS KAPI function table has one layout on both
# sides of the module boundary (Track #2228, docs/PRIME-IMPORT.md).
#
# nvidia-modeset.ko fills struct NvKmsKapiFunctionsTable and nvidia-drm.ko
# calls through it.  Each module is built from its own copy of the header
# that declares the table: the open source's
# src/nvidia-modeset/kapi/interface/nvkms-kapi.h (build/ogkm, patched by
# patches/ogkm) and the FreeBSD package's src/common/inc/nvkms-kapi.h
# (build/tree, patched by patches/).  The driver's version-string check does
# not notice a layout change, so a mismatch between the copies is a call
# through the wrong pointer.  This test applies the repository's patches to
# the pristine sources and checks:
#
#   (a) the two patched copies are byte-identical;
#   (b) a probe compiled against each copy prints the same sizeof of the
#       table and the same offsetof of every member;
#   (c) the new member getSystemMemoryHandleFromPageArray is there, is the
#       last member (every existing offset is unchanged) and the table is
#       filled with it (nvKmsKapiGetFunctionsTableInternal).  Mixing an old
#       module with a new one is still unsafe: a new nvidia-modeset.ko fills
#       one pointer beyond the table of an old nvidia-drm.ko, an old
#       nvidia-modeset.ko leaves the member NULL (nvidia-drm checks that).
#       Both modules ship together;
#   (d) controls: the pristine copies lack the member; a planted layout
#       mismatch (a member inserted before the others in one copy) makes
#       (a) and (b) fail.
#
# Run: sh tests/kapi_table_test.sh      Exit 0 when every check passes.

set -u
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repo/scripts/lib.sh"
WORK=${GB10_WORK:-$HOME/work/gb10}
ver=$(sources_get "$repo/SOURCES" ogkm_tag) || { echo "FAIL: no ogkm_tag in SOURCES"; exit 1; }
OGKMSRC=$WORK/sources/open-gpu-kernel-modules-$ver
PRISTINE=$WORK/sources/NVIDIA-FreeBSD-x86_64-$ver/src

mkdir -p "$WORK/tmp"
TMPD=$(mktemp -d "$WORK/tmp/kapi-table-test.XXXXXXXX") || exit 1
trap 'rm -rf -- "$TMPD"' EXIT INT TERM

passed=0
failed=0
ok() { echo "PASS: $1"; passed=$((passed + 1)); }
bad() { echo "FAIL: $1"; failed=$((failed + 1)); }

OGKM_H=src/nvidia-modeset/kapi/interface/nvkms-kapi.h
OGKM_C=src/nvidia-modeset/kapi/src/nvkms-kapi.c
TREE_H=common/inc/nvkms-kapi.h
for f in "$OGKMSRC/$OGKM_H" "$OGKMSRC/$OGKM_C" "$PRISTINE/$TREE_H"; do
	[ -f "$f" ] || { echo "FAIL: missing $f (run scripts/fetch-sources.sh)"; exit 1; }
done

# apply_one <patch> <dir> <what>: apply one patch; "" when there is none.
apply_one() {
	if [ ! -f "$1" ]; then
		echo "missing $1"
		return 1
	fi
	patch -d "$2" -p0 -E -s -i "$1" || { echo "$1 does not apply to $3"; return 1; }
}

mkdir -p "$TMPD/ogkm/$(dirname "$OGKM_H")" "$TMPD/ogkm/$(dirname "$OGKM_C")" "$TMPD/tree/common/inc"
cp "$OGKMSRC/$OGKM_H" "$TMPD/ogkm/$OGKM_H"
cp "$OGKMSRC/$OGKM_C" "$TMPD/ogkm/$OGKM_C"
cp "$PRISTINE/$TREE_H" "$TMPD/tree/$TREE_H"
mkdir -p "$TMPD/pristine"
cp "$OGKMSRC/$OGKM_H" "$TMPD/pristine/ogkm.h"
cp "$PRISTINE/$TREE_H" "$TMPD/pristine/tree.h"

patched=1
apply_one "$repo/patches/ogkm/patch-src_nvidia-modeset_kapi_interface_nvkms-kapi.h" "$TMPD/ogkm" ogkm-header || patched=0
apply_one "$repo/patches/ogkm/patch-src_nvidia-modeset_kapi_src_nvkms-kapi.c" "$TMPD/ogkm" ogkm-kapi || patched=0
apply_one "$repo/patches/patch-common_inc_nvkms-kapi.h" "$TMPD/tree" tree-header || patched=0
[ "$patched" -eq 1 ] && ok "the KAPI patches apply to the pristine sources" \
    || bad "the KAPI patches do not apply (see above)"

# members <header>: the function-pointer members of the table, in order
# (declared at four spaces of indent; the parameters are indented deeper).
members() {
	awk '/^struct NvKmsKapiFunctionsTable \{/ { on = 1; next }
	     on && /^\};/ { exit }
	     on { print }' "$1" | grep -E '^    [^ ]' | grep -Eo '\(\*[A-Za-z0-9_]+\)' | tr -d '(*)'
}

# probe <header> <out-prefix>: compile and run a program that prints the
# size of the table and the offset of every member.
probe() {
	_h=$1
	_p=$2
	mkdir -p "$_p.inc"
	cp "$_h" "$_p.inc/nvkms-kapi.h"
	{
		echo '#include <stddef.h>'
		echo '#include <stdio.h>'
		echo '#include "nvkms-kapi.h"'
		echo 'int main(void) {'
		echo '	printf("sizeof %zu\n", sizeof(struct NvKmsKapiFunctionsTable));'
		members "$_h" | while read -r _m; do
			echo "	printf(\"$_m %zu\\n\", offsetof(struct NvKmsKapiFunctionsTable, $_m));"
		done
		echo '	return 0; }'
	} > "$_p.c"
	cc -std=gnu11 -w -I"$_p.inc" -I"$PRISTINE/common/inc" -o "$_p.bin" "$_p.c" 2> "$_p.err" || return 1
	"$_p.bin" > "$_p.out"
}

if [ "$patched" -eq 1 ]; then
	if cmp -s "$TMPD/ogkm/$OGKM_H" "$TMPD/tree/$TREE_H"; then
		ok "the two copies of the table header are byte-identical"
	else
		bad "the two copies of the table header differ"
	fi
	if probe "$TMPD/ogkm/$OGKM_H" "$TMPD/pa" && probe "$TMPD/tree/$TREE_H" "$TMPD/pb"; then
		if cmp -s "$TMPD/pa.out" "$TMPD/pb.out"; then
			ok "both copies give the same sizeof and offsetof of every member ($(wc -l < "$TMPD/pa.out" | tr -d ' ') lines)"
		else
			bad "the copies disagree on the table layout"
		fi
		last=$(members "$TMPD/ogkm/$OGKM_H" | tail -1)
		if [ "$last" = getSystemMemoryHandleFromPageArray ]; then
			ok "getSystemMemoryHandleFromPageArray is the last member of the table"
		else
			bad "the last member of the table is '$last', not getSystemMemoryHandleFromPageArray"
		fi
		want=$(members "$TMPD/ogkm/$OGKM_H" | grep -c '^getSystemMemoryHandleFromPageArray$')
		[ "$want" -eq 1 ] && ok "the member is declared exactly once" || bad "the member is declared $want times"
	else
		bad "the layout probe does not compile: $(head -3 "$TMPD/pa.err" "$TMPD/pb.err" 2>/dev/null | tr '\n' ' ')"
	fi
	if tr '\n' ' ' < "$TMPD/ogkm/$OGKM_C" | grep -Eq 'funcsTable->getSystemMemoryHandleFromPageArray[[:space:]]*=[[:space:]]*GetSystemMemoryHandleFromPageArray;'; then
		ok "nvKmsKapiGetFunctionsTableInternal() fills the member"
	else
		bad "nvKmsKapiGetFunctionsTableInternal() does not fill getSystemMemoryHandleFromPageArray"
	fi
fi

# --- controls ------------------------------------------------------------
if [ "$(members "$TMPD/pristine/ogkm.h" | grep -c '^getSystemMemoryHandleFromPageArray$')" -eq 0 ] \
    && [ "$(members "$TMPD/pristine/tree.h" | grep -c '^getSystemMemoryHandleFromPageArray$')" -eq 0 ]; then
	ok "control: the pristine copies lack the member (the test can see the defect)"
else
	bad "control: a pristine copy already has the member"
fi

# planted mismatch: a member inserted at the start of one copy.
if [ "$patched" -eq 1 ]; then
	awk '{ print }
	     /^struct NvKmsKapiFunctionsTable \{/ { print "    void (*plantedMismatch)(void);" }' \
	    "$TMPD/tree/$TREE_H" > "$TMPD/planted.h"
	if cmp -s "$TMPD/ogkm/$OGKM_H" "$TMPD/planted.h"; then
		bad "control: the planted header equals the original (stale test)"
	else
		ok "control: a planted mismatch is seen by the byte comparison"
	fi
	if probe "$TMPD/planted.h" "$TMPD/pc" && ! cmp -s "$TMPD/pa.out" "$TMPD/pc.out"; then
		ok "control: a planted layout mismatch is seen by the probe"
	else
		bad "control: a planted layout mismatch passed the probe"
	fi
fi

echo "passed: $passed failed: $failed"
[ "$failed" -eq 0 ]
