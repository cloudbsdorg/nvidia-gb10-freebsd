#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-2-Clause
#
# enumerate_gpus_patch_test.sh - the native KAPI GPU enumerator is split from
# the console-owner patch and walks only attached FreeBSD nvidia devices.

set -u
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repo/scripts/lib.sh"
WORK=${GB10_WORK:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)/work}
ver=$(sources_get "$repo/SOURCES" ogkm_tag) || { echo "FAIL: no ogkm_tag in SOURCES"; exit 1; }
PRISTINE=$WORK/sources/NVIDIA-FreeBSD-x86_64-$ver/src

mkdir -p "$repo/tmp"
TMPD=$(mktemp -d "$repo/tmp/enumerate-gpus-patch-test.XXXXXXXX") || exit 1
trap 'rm -rf -- "$TMPD"' EXIT INT TERM
SRC=$TMPD/src
C=nvidia-modeset/nvidia-modeset-freebsd.c
MAKEFILE=nvidia-modeset/Makefile

passed=0
failed=0
ok() { echo "PASS: $1"; passed=$((passed + 1)); }
bad() { echo "FAIL: $1"; failed=$((failed + 1)); }

for p in \
    patch-nvidia-modeset_nvidia-modeset-freebsd.c \
    patch-zz-2448-enumerate-gpus_nvidia-modeset-freebsd.c \
    patch-zz-2448-enumerate-gpus_nvidia-modeset_Makefile; do
	[ -f "$repo/patches/$p" ] || bad "missing $p"
done
for p in \
    patch-zz-2448-console-owner_nvidia-drm-freebsd-lkpi.c \
    patch-zz-2448-console-owner_nvidia-modeset-freebsd.c \
    patch-zz-2448-console-owner_nvidia-modeset_Makefile; do
	[ ! -e "$repo/patches/$p" ] || bad "superseded patch still exists: $p"
done

mkdir -p "$SRC/nvidia-modeset"
cp "$PRISTINE/$C" "$SRC/$C"
cp "$PRISTINE/$MAKEFILE" "$SRC/$MAKEFILE"
patched=1
for p in \
    patch-nvidia-modeset_nvidia-modeset-freebsd.c \
    patch-zz-2448-enumerate-gpus_nvidia-modeset-freebsd.c \
    patch-zz-2448-enumerate-gpus_nvidia-modeset_Makefile; do
	if [ ! -f "$repo/patches/$p" ] || \
	    ! patch -d "$SRC" -p0 -E -s -i "$repo/patches/$p"; then
		patched=0
	fi
done
[ "$patched" -eq 1 ] && ok "the enumeration patches apply" \
    || bad "the enumeration patches do not apply"

function_text() {
	sed -n '/^nvkms_enumerate_gpus(/,/^}/p' "$1" | tr '\n' ' '
}

check_enumerator() {
	[ -f "$1/$C" ] && [ -f "$1/$MAKEFILE" ] || return 2
	_t=$(function_text "$1/$C")
	printf '%s\n' "$_t" | grep -Eq 'bus_topo_lock\(\);.*devclass_find\("nvidia"\)' || return 1
	printf '%s\n' "$_t" | grep -Eq 'device_is_attached\(sc->dev\).*continue;' || return 1
	printf '%s\n' "$_t" | grep -Eq 'sc->nv_state|nv = sc->nv_state' || return 1
	printf '%s\n' "$_t" | grep -Eq 'nv[[:space:]]*=[[:space:]]*sc->nv_state;.*nv[[:space:]]*==[[:space:]]*NULL' || return 1
	printf '%s\n' "$_t" | grep -Eq 'bus_topo_unlock\(\);.*return count;' || return 1
	! printf '%s\n' "$_t" | grep -Eq 'nvkms_enumerate_gpus\(nv_gpu_info_t \*gpu_info\)[[:space:]]*\{[[:space:]]*return 0;[[:space:]]*\}' || return 1
	_h=$(tr '\n' ' ' < "$1/$C")
	printf '%s\n' "$_h" | grep -Eq '#include "nv.h"[[:space:]]*#include "nv-freebsd.h"[[:space:]]*#undef NVRM' || return 1
	! printf '%s\n' "$_h" | grep -q '\.\./nvidia/' || return 1
	printf '%s\n' "$_h" | grep -q 'native kernel client' || return 1
	printf '%s\n' "$_h" | grep -q 'NV_LINUX' || return 1
	grep -q '^CFLAGS += -I\.\./nvidia$' "$1/$MAKEFILE" || return 1
	grep -Eq '^SRCS \+= .*device_if\.h.*bus_if\.h' "$1/$MAKEFILE"
}

plant() {
	_t=$TMPD/plant-$1
	rm -rf "$_t"
	mkdir -p "$_t/nvidia-modeset"
	cp "$SRC/$C" "$_t/$C"
	cp "$SRC/$MAKEFILE" "$_t/$MAKEFILE"
	sed -e "$3" "$SRC/$2" > "$_t/$2"
	if cmp -s "$SRC/$2" "$_t/$2"; then
		bad "control $1: the planted change changed nothing (stale test)"
		return
	fi
	check_enumerator "$_t"
	_r=$?
	[ "$_r" -eq 1 ] && ok "control: $1 is detected" \
	    || bad "control: $1 was not detected cleanly (status $_r)"
}

if [ "$patched" -eq 1 ]; then
	check_enumerator "$SRC" && ok "the enumerator locks the topology and skips unattached or uninitialized units" \
	    || bad "the enumerator does not implement the safe native KAPI walk"

	mkdir -p "$TMPD/plant-stub/nvidia-modeset"
	cp "$SRC/$MAKEFILE" "$TMPD/plant-stub/$MAKEFILE"
	awk '
	/^nvkms_enumerate_gpus\(/ {
		print
		print "{"
		print "    return 0;"
		print "}"
		stub = 1
		next
	}
	stub && /^}/ { stub = 0; next }
	!stub { print }
	' "$SRC/$C" > "$TMPD/plant-stub/$C"
	if cmp -s "$SRC/$C" "$TMPD/plant-stub/$C"; then
		bad "control bare-stub: the planted change changed nothing (stale test)"
	elif check_enumerator "$TMPD/plant-stub"; then
		bad "control: the bare return-0 enumeration stub passed"
	else
		ok "control: planting back the bare return-0 enumeration stub fails"
	fi

	plant enumeration-without-attached-check "$C" \
	    's/ || !device_is_attached(sc->dev)//' 
	plant enumeration-without-topology-lock "$C" \
	    's/bus_topo_lock();/ /'
fi

echo "passed: $passed failed: $failed"
[ "$failed" -eq 0 ]
