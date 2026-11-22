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
#   (c) getSystemMemoryHandleFromPageArray retains its offset and the new
#       member setConsoleOwner follows it as the last member; the table is
#       filled with both (nvKmsKapiGetFunctionsTableInternal).  Mixing an old
#       module with a new one is still unsafe: a new nvidia-modeset.ko fills
#       pointers beyond the table of an old nvidia-drm.ko, an old
#       nvidia-modeset.ko leaves the members NULL (nvidia-drm checks that).
#       Both modules ship together;
#   (d) controls: the pristine copies lack the members; a planted layout
#       mismatch (a member inserted before the others in one copy) makes
#       (a) and (b) fail;
#   (e) the pairing handshake, in both directions (docs/PRIME-IMPORT.md, the
#       review of a00964c): the two modules refuse each other unless they are
#       the same build.  Layer 1 is the kld version, MODULE_VERSION(
#       nvidia_modeset, N) against MODULE_DEPEND(nvidia_drm, nvidia_modeset,
#       N, N, N), which kldload checks before any code runs.  Layer 2 is the
#       table's version string, which carries NVKMS_KAPI_CBSD_LAYOUT on both
#       sides and which nvidia-modeset compares before it writes any member.
#       The real source expressions are extracted and evaluated: new/new
#       pairs, an old nvidia-modeset with a new nvidia-drm and a new
#       nvidia-modeset with an old nvidia-drm are refused at both layers;
#       planted mismatches in each module make the new/new check fail.
#
# Run: sh tests/kapi_table_test.sh      Exit 0 when every check passes.

set -u
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repo/scripts/lib.sh"
WORK=${GB10_WORK:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)/work}
ver=$(sources_get "$repo/SOURCES" ogkm_tag) || { echo "FAIL: no ogkm_tag in SOURCES"; exit 1; }
OGKMSRC=$WORK/sources/open-gpu-kernel-modules-$ver
PRISTINE=$WORK/sources/NVIDIA-FreeBSD-x86_64-$ver/src

mkdir -p "$repo/tmp"
TMPD=$(mktemp -d "$repo/tmp/kapi-table-test.XXXXXXXX") || exit 1
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
		previous=$(members "$TMPD/ogkm/$OGKM_H" | tail -2 | head -1)
		if [ "$previous" = getSystemMemoryHandleFromPageArray ] && [ "$last" = setConsoleOwner ]; then
			ok "setConsoleOwner is last, immediately after getSystemMemoryHandleFromPageArray"
		else
			bad "the last two members are '$previous' and '$last', not getSystemMemoryHandleFromPageArray and setConsoleOwner"
		fi
		want=$(members "$TMPD/ogkm/$OGKM_H" | grep -c '^getSystemMemoryHandleFromPageArray$')
		[ "$want" -eq 1 ] && ok "getSystemMemoryHandleFromPageArray is declared exactly once" || bad "getSystemMemoryHandleFromPageArray is declared $want times"
		want=$(members "$TMPD/ogkm/$OGKM_H" | grep -c '^setConsoleOwner$')
		[ "$want" -eq 1 ] && ok "setConsoleOwner is declared exactly once" || bad "setConsoleOwner is declared $want times"
	else
		bad "the layout probe does not compile: $(head -3 "$TMPD/pa.err" "$TMPD/pb.err" 2>/dev/null | tr '\n' ' ')"
	fi
	if tr '\n' ' ' < "$TMPD/ogkm/$OGKM_C" | grep -Eq 'funcsTable->getSystemMemoryHandleFromPageArray[[:space:]]*=[[:space:]]*GetSystemMemoryHandleFromPageArray;'; then
		ok "nvKmsKapiGetFunctionsTableInternal() fills getSystemMemoryHandleFromPageArray"
	else
		bad "nvKmsKapiGetFunctionsTableInternal() does not fill getSystemMemoryHandleFromPageArray"
	fi
	if tr '\n' ' ' < "$TMPD/ogkm/$OGKM_C" | grep -Eq 'funcsTable->setConsoleOwner[[:space:]]*=[[:space:]]*SetConsoleOwner;'; then
		ok "nvKmsKapiGetFunctionsTableInternal() fills setConsoleOwner"
	else
		bad "nvKmsKapiGetFunctionsTableInternal() does not fill setConsoleOwner"
	fi
fi

# --- (e) the pairing handshake -----------------------------------------------
DRM_C=nvidia-drm/nvidia-drm.c
LKPI_C=nvidia-drm/nvidia-drm-freebsd-lkpi.c
MS_C=nvidia-modeset/nvidia-modeset-freebsd.c
HS_PATCHES='patch-nvidia-drm_nvidia-drm-freebsd-lkpi.c
patch-nvidia-drm_nvidia-drm.c
patch-nvidia-modeset_nvidia-modeset-freebsd.c
patch-zz-2448-enumerate-gpus_nvidia-modeset-freebsd.c
patch-zz-nvidia_client_owner_version_drm.c
patch-zz-nvidia_client_owner_version_modeset.c'

# Time: O(p), where p is the mandatory patch count.
# Space: O(1), besides the caller's patch path.
require_hs_patches() {
	_missing=0
	for _p in $HS_PATCHES; do
		if [ ! -f "$1/$_p" ]; then
			echo "FAIL: missing $_p"
			_missing=1
		fi
	done
	return "$_missing"
}

for f in "$PRISTINE/$DRM_C" "$PRISTINE/$LKPI_C" "$PRISTINE/$MS_C"; do
	[ -f "$f" ] || { echo "FAIL: missing $f"; exit 1; }
done
mkdir -p "$TMPD/hs/new/nvidia-drm" "$TMPD/hs/new/nvidia-modeset" "$TMPD/hs/old/nvidia-drm" "$TMPD/hs/old/nvidia-modeset"
for f in $DRM_C $LKPI_C $MS_C; do
	cp "$PRISTINE/$f" "$TMPD/hs/new/$f"
	cp "$PRISTINE/$f" "$TMPD/hs/old/$f"
done
require_hs_patches "$repo/patches" || {
	patched=0
	bad "the mandatory handshake patch set is incomplete"
}
for _p in "$repo"/patches/patch-*; do
	case ${_p##*/} in
	patch-nvidia-drm_nvidia-drm.c|\
	patch-nvidia-drm_nvidia-drm-freebsd-lkpi.c|\
	patch-nvidia-modeset_nvidia-modeset-freebsd.c|\
	patch-zz-2448-enumerate-gpus_nvidia-modeset-freebsd.c|\
	patch-zz-nvidia_client_owner_version_drm.c|\
	patch-zz-nvidia_client_owner_version_modeset.c)
		apply_one "$_p" "$TMPD/hs/new" "${_p##*/}" || {
			patched=0
			bad "the mandatory patch ${_p##*/} does not apply"
		}
		;;
	esac
done
cp "$TMPD/ogkm/$OGKM_C" "$TMPD/hs/new/ms-kapi.c"
cp "$OGKMSRC/$OGKM_C" "$TMPD/hs/old/ms-kapi.c"

# versions <tree>: "<MODULE_VERSION> <dep vmin> <dep vpref> <dep vmax>" (the
# nvidia_modeset version, and what nvidia-drm depends on).
mod_version() {
	tr '\n' ' ' < "$1/$MS_C" | grep -Eo 'MODULE_VERSION\(nvidia_modeset,[[:space:]]*[0-9]+\)' | grep -Eo '[0-9]+' | tail -1
}
mod_dep() {
	tr '\n' ' ' < "$1/$LKPI_C" | grep -Eo 'MODULE_DEPEND\(nvidia_drm,[[:space:]]*nvidia_modeset,[[:space:]]*[0-9]+,[[:space:]]*[0-9]+,[[:space:]]*[0-9]+\)' | grep -Eo '[0-9]+' | tr '\n' ' '
}
# kld_loads <modeset tree> <drm tree>: 0 when kldload would accept the pair.
kld_loads() {
	_v=$(mod_version "$1")
	set -- $(mod_dep "$2")
	[ -n "${_v:-}" ] && [ $# -eq 3 ] && [ "$_v" -ge "$1" ] && [ "$_v" -le "$3" ]
}
# dep_exact <tree>: nvidia-drm asks for exactly one nvidia-modeset version
dep_exact() {
	set -- $(mod_dep "$1")
	[ $# -eq 3 ] && [ "$1" -eq "$2" ] && [ "$2" -eq "$3" ]
}
# the two string expressions the table handshake compares
drm_expr() {
	sed -n 's/^[[:space:]]*\.versionString[[:space:]]*=[[:space:]]*\(.*\),[[:space:]]*$/\1/p' "$1/$DRM_C"
}
ms_expr() {
	# grep, not a greedy sed over the whole file as one line: that is quadratic
	tr '\n' ' ' < "$1" | grep -Eo 'nvkms_strcmp\(funcsTable->versionString,[^)]*\)[[:space:]]*!=[[:space:]]*0' | head -1 | sed -e 's/^nvkms_strcmp(funcsTable->versionString,[[:space:]]*//' -e 's/)[[:space:]]*!=[[:space:]]*0$//'
}
# table_accepts <drm tree> <modeset kapi.c> <header>: does nvidia-modeset
# accept the table nvidia-drm presents?  The two expressions are compiled
# against the header and compared with strcmp, as nvkms_strcmp does.
table_accepts() {
	_d=$(drm_expr "$1")
	_m=$(ms_expr "$2")
	[ -n "$_d" ] && [ -n "$_m" ] || return 2
	mkdir -p "$TMPD/hs/inc"
	cp "$3" "$TMPD/hs/inc/nvkms-kapi.h"
	cat > "$TMPD/hs/probe.c" <<PROBE
#include <string.h>
#include "nvkms-kapi.h"
#define NV_VERSION_STRING "580.178.04"
int main(void) { return strcmp($_d, $_m) == 0 ? 0 : 1; }
PROBE
	cc -std=gnu11 -w -I"$TMPD/hs/inc" -I"$PRISTINE/common/inc" -o "$TMPD/hs/probe" "$TMPD/hs/probe.c" 2> "$TMPD/hs/probe.err" || return 2
	"$TMPD/hs/probe"
}

if [ "$patched" -eq 1 ]; then
	NEWH=$TMPD/tree/$TREE_H
	table_accepts "$TMPD/hs/new" "$TMPD/hs/new/ms-kapi.c" "$NEWH"; r=$?
	[ "$r" -eq 0 ] && ok "table handshake: a new nvidia-modeset accepts a new nvidia-drm" || bad "table handshake: new/new refused (rc $r: $(head -2 "$TMPD/hs/probe.err" 2>/dev/null | tr '\n' ' '))"
	table_accepts "$TMPD/hs/old" "$TMPD/hs/new/ms-kapi.c" "$NEWH"; r=$?
	[ "$r" -eq 1 ] && ok "table handshake: a new nvidia-modeset refuses an old nvidia-drm, before it writes a member" || bad "table handshake: new modeset / old drm not refused (rc $r)"
	table_accepts "$TMPD/hs/new" "$TMPD/hs/old/ms-kapi.c" "$NEWH"; r=$?
	[ "$r" -eq 1 ] && ok "table handshake: an old nvidia-modeset refuses a new nvidia-drm" || bad "table handshake: old modeset / new drm not refused (rc $r)"
	kld_loads "$TMPD/hs/new" "$TMPD/hs/new" && ok "kld versions: the new pair loads ($(mod_version "$TMPD/hs/new"), depends $(mod_dep "$TMPD/hs/new"))" || bad "kld versions: the new pair does not load"
	kld_loads "$TMPD/hs/new" "$TMPD/hs/old" && bad "kld versions: a new nvidia-modeset loads under an old nvidia-drm" || ok "kld versions: a new nvidia-modeset is refused by an old nvidia-drm"
	kld_loads "$TMPD/hs/old" "$TMPD/hs/new" && bad "kld versions: an old nvidia-modeset loads under a new nvidia-drm" || ok "kld versions: an old nvidia-modeset is refused by a new nvidia-drm"
	_tagn=$(grep -o 'NVKMS_KAPI_CBSD_LAYOUT "+cbsd-kapi\.[0-9]*"' "$NEWH" | grep -o '[0-9]*"$' | tr -d '"')
	[ -n "$_tagn" ] && [ "$_tagn" = "$(mod_version "$TMPD/hs/new")" ] && ok "the layout tag number ($_tagn) is the nvidia_modeset kld version" || bad "the layout tag number '$_tagn' and the nvidia_modeset kld version '$(mod_version "$TMPD/hs/new")' do not move together"
	dep_exact "$TMPD/hs/new" && ok "kld versions: nvidia-drm asks for exactly one nvidia-modeset version" || bad "kld versions: nvidia-drm accepts a range of nvidia-modeset versions ($(mod_dep "$TMPD/hs/new"))"
	[ "$(mod_version "$TMPD/hs/new")" = 3 ] && [ "$(mod_dep "$TMPD/hs/new")" = "3 3 3 " ] \
	    && ok "the console-owner layout uses nvidia_modeset version 3 and dependency 3, 3, 3" \
	    || bad "the console-owner layout does not use version 3 throughout (found MODULE_VERSION $(mod_version "$TMPD/hs/new"), MODULE_DEPEND $(mod_dep "$TMPD/hs/new"))"
	mkdir -p "$TMPD/hs/reverse/nvidia-drm" "$TMPD/hs/reverse/nvidia-modeset"
	for f in $DRM_C $LKPI_C $MS_C; do
		cp "$PRISTINE/$f" "$TMPD/hs/reverse/$f"
	done
	_reverse_ok=1
	for _p in \
	    patch-zz-nvidia_client_owner_version_modeset.c \
	    patch-zz-nvidia_client_owner_version_drm.c \
	    patch-zz-2448-enumerate-gpus_nvidia-modeset-freebsd.c \
	    patch-nvidia-modeset_nvidia-modeset-freebsd.c \
	    patch-nvidia-drm_nvidia-drm.c \
	    patch-nvidia-drm_nvidia-drm-freebsd-lkpi.c; do
		apply_one "$repo/patches/$_p" "$TMPD/hs/reverse" "$_p (reverse)" || _reverse_ok=0
	done
	if [ "$_reverse_ok" -eq 1 ] && [ "$(mod_version "$TMPD/hs/reverse")" = 3 ] \
	    && [ "$(mod_dep "$TMPD/hs/reverse")" = "3 3 3 " ]; then
		ok "reverse lexical patch application still produces nvidia_modeset version 3"
	else
		bad "reverse lexical patch application does not produce version 3 throughout"
	fi
	tr '\n' ' ' < "$TMPD/hs/new/$DRM_C" | grep -Eq 'Version mismatch.*cbsd-kapi.*same build' \
	    && ok "the version-mismatch message explains the layout suffix and the fix" \
	    || bad "the version-mismatch message of nvidia-drm does not explain the +cbsd-kapi suffix and say to install the three modules from one build"

	# planted mismatches: each must make the new/new pairing fail
	planted() {
		# planted <name> <file in hs/new> <sed> <kind: table|kld>
		_t="$TMPD/hs/p-$1"
		rm -rf "$_t"; cp -R "$TMPD/hs/new" "$_t"
		sed -e "$3" "$TMPD/hs/new/$2" > "$_t/$2"
		if cmp -s "$TMPD/hs/new/$2" "$_t/$2"; then bad "control $1: the planted change changed nothing (stale test)"; return; fi
		case $4 in
		table) table_accepts "$_t" "$_t/ms-kapi.c" "$NEWH"; _r=$? ;;
		kld) if kld_loads "$_t" "$_t" && dep_exact "$_t"; then _r=0; else _r=1; fi ;;
		fill) if tr '\n' ' ' < "$_t/ms-kapi.c" | grep -Eq 'funcsTable->setConsoleOwner[[:space:]]*=[[:space:]]*SetConsoleOwner;'; then _r=0; else _r=1; fi ;;
		esac
		[ "$_r" -ne 0 ] && ok "control: planted mismatch $1 breaks the pairing" || bad "control: planted mismatch $1 passed"
	}
	planted drm-without-tag nvidia-drm/nvidia-drm.c 's/NV_VERSION_STRING NVKMS_KAPI_CBSD_LAYOUT,/NV_VERSION_STRING,/' table
	planted modeset-without-tag ms-kapi.c 's/NV_VERSION_STRING NVKMS_KAPI_CBSD_LAYOUT) != 0/NV_VERSION_STRING) != 0/' table
	planted modeset-version-1 nvidia-modeset/nvidia-modeset-freebsd.c 's/MODULE_VERSION(nvidia_modeset, 3)/MODULE_VERSION(nvidia_modeset, 1)/' kld
	planted modeset-version-2 nvidia-modeset/nvidia-modeset-freebsd.c 's/MODULE_VERSION(nvidia_modeset, 3)/MODULE_VERSION(nvidia_modeset, 2)/' kld
	planted drm-depends-on-1 nvidia-drm/nvidia-drm-freebsd-lkpi.c 's/nvidia_modeset, 3, 3, 3/nvidia_modeset, 1, 1, 1/' kld
	planted drm-depends-on-range nvidia-drm/nvidia-drm-freebsd-lkpi.c 's/nvidia_modeset, 3, 3, 3/nvidia_modeset, 1, 3, 3/' kld
	planted modeset-without-console-owner-fill ms-kapi.c '/funcsTable->setConsoleOwner = SetConsoleOwner;/d' fill
fi

# --- controls ------------------------------------------------------------
if [ "$(members "$TMPD/pristine/ogkm.h" | grep -c '^getSystemMemoryHandleFromPageArray$')" -eq 0 ] \
    && [ "$(members "$TMPD/pristine/tree.h" | grep -c '^getSystemMemoryHandleFromPageArray$')" -eq 0 ] \
    && [ "$(members "$TMPD/pristine/ogkm.h" | grep -c '^setConsoleOwner$')" -eq 0 ] \
    && [ "$(members "$TMPD/pristine/tree.h" | grep -c '^setConsoleOwner$')" -eq 0 ]; then
	ok "control: the pristine copies lack both added members (the test can see the defects)"
else
	bad "control: a pristine copy already has an added member"
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

cp -R "$repo/patches" "$TMPD/patches-missing-control"
rm "$TMPD/patches-missing-control/patch-nvidia-drm_nvidia-drm.c"
if require_hs_patches "$TMPD/patches-missing-control"; then
	bad "control: removing patch-nvidia-drm_nvidia-drm.c was not detected"
else
	ok "control: removing patch-nvidia-drm_nvidia-drm.c fails the mandatory-patch check"
fi

echo "passed: $passed failed: $failed"
[ "$failed" -eq 0 ]
