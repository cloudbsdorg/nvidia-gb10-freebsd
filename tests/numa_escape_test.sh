#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# numa_escape_test.sh - the NV_ESC_NUMA_INFO (0xd7) escape, the one Linux
# libcuda asks the driver for under the Linuxulator and the only ioctl the
# FreeBSD driver answers with EINVAL.
#
# Linux's libcuda (580.178.04) opens /dev/nvidia1 and asks the driver for
# the GPU's NUMA node with the Linux ioctl
#     _IOWR('F', NV_ESC_NUMA_INFO, nv_ioctl_numa_info_t) == 0xc23046d7
# (trace: .round/cuinit7-around-d7.txt, line 40).  NV_ESC_NUMA_INFO is
# NV_IOCTL_BASE + 15 == 0xd7 (nv-ioctl-numa.h).  The FreeBSD driver has no
# case for it: nvidia_handle_ioctl() (nvidia_subr.c) falls into its
# default: branch, rm_ioctl() hands the escape to the RM core's RmIoctl(),
# which does not know it either ("unknown NVRM ioctl command: 0xd7" in
# open-gpu-kernel-modules src/nvidia/arch/nvalloc/unix/src/escape.c), and
# the ioctl returns EINVAL.
#
# Checks:
#   (a) layout: nv_ioctl_numa_info_t is 560 bytes (0x230) on aarch64 LP64
#       and the Linux ioctl number built from it is exactly 0xc23046d7, so
#       the size in the trace is the right one and the escape is the right
#       one. Falsified by a mutant that asserts a wrong size, which the
#       compiler must reject;
#   (b) the OS layer answers the escape: nvidia_handle_ioctl() in the
#       prepared tree must have a "case NV_ESC_NUMA_INFO:" branch, ahead of
#       the default: branch that calls rm_ioctl(), and that branch must
#       check the size against sizeof(nv_ioctl_numa_info_t). RED today;
#   (c) control: the pristine NVIDIA source, extracted from the verified
#       tarball, has no such branch - so (b) can tell the two apart and is
#       not vacuously true;
#   (d) the RM core does not know the escape either: the pinned
#       open-gpu-kernel-modules checkout's escape.c has no
#       "case NV_ESC_NUMA_INFO", so the OS layer is the only place that can
#       answer it and the fix belongs there.
#
# Run: sh tests/numa_escape_test.sh [TREE]
#
# The fix needs a rebuilt nvidia.ko: nvidia_subr.c is compiled into the
# module, and nvidia.ko cannot be unloaded, so the runtime proof (the
# ioctl returning 0 instead of EINVAL) needs a boot with the new module.
# This test is the static half of that proof; it needs no loaded module.

set -eu

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

TESTSDIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$TESTSDIR/.." && pwd)
WORK=${GB10_WORK:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)/work}
TREE=${1:-$WORK/build/tree}
TOPDIR=NVIDIA-FreeBSD-x86_64-580.178.04
TARBALL=$WORK/sources/$TOPDIR.tar.xz
OGKM=$WORK/sources/open-gpu-kernel-modules-580.178.04
# TEST_TMPDIR overrides where the scratch goes; it defaults to the work
# root's tmp, like the other tests in this directory.
export TMPDIR=${TEST_TMPDIR:-$WORK/tmp}
mkdir -p "$TMPDIR"
T=$(mktemp -d "$TMPDIR/numa-escape-test.XXXXXXXX") || exit 1

PASSED=0
FAILED=0

cleanup() {
	rm -rf "$T"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 131' QUIT
trap 'exit 143' TERM

pass() { PASSED=$((PASSED + 1)); echo "PASS: $*"; }
fail() { FAILED=$((FAILED + 1)); echo "FAIL: $*"; }

if [ ! -f "$TARBALL" ]; then
	echo "numa_escape_test: missing $TARBALL (run scripts/fetch-sources.sh)" >&2
	exit 2
fi

# ---- (a) layout ----
# The two MIT headers NVIDIA ships for this escape, taken from the verified
# tarball, so the layout is checked against the version that is built and
# not against a copy in this repository.
mkdir -p "$T/hdr"
if ! tar -xJf "$TARBALL" -C "$T/hdr" --strip-components 3 \
    "$TOPDIR/src/nvidia/nv-ioctl-numa.h" \
    "$TOPDIR/src/nvidia/nv-ioctl-numbers.h" 2>/dev/null; then
	echo "numa_escape_test: cannot extract the NUMA headers from $TARBALL" >&2
	exit 2
fi
cat > "$T/layout.c" <<'EOF'
#include <stdint.h>
#include <stddef.h>
#include "nv-ioctl-numa.h"

#define SZ(t, n) _Static_assert(sizeof(t) == (n), #t)
#define OF(t, f, n) _Static_assert(__builtin_offsetof(t, f) == (n), #t "." #f)

SZ(nv_ioctl_numa_info_t, 560);
OF(nv_ioctl_numa_info_t, offline_addresses, 40);
SZ(nv_offline_addresses_t, 520);
SZ(nv_ioctl_set_numa_status_t, 4);
_Static_assert(NV_ESC_NUMA_INFO == 0xd7, "NV_ESC_NUMA_INFO must be 0xd7");
_Static_assert(NV_ESC_SET_NUMA_STATUS == 0xd8, "NV_ESC_SET_NUMA_STATUS must be 0xd8");
/* the ioctl number Linux's libcuda used: _IOWR('F', NV_ESC_NUMA_INFO, ...) */
_Static_assert(((3UL << 30) | ((unsigned long)sizeof(nv_ioctl_numa_info_t) << 16) |
    (('F' & 0xff) << 8) | (NV_ESC_NUMA_INFO & 0xff)) == 0xc23046d7UL,
    "Linux ioctl number for NV_ESC_NUMA_INFO");
MUTANT
EOF
sed 's/^MUTANT$//' "$T/layout.c" > "$T/layout_ok.c"
sed 's/^MUTANT$/SZ(nv_ioctl_numa_info_t, 561);/' "$T/layout.c" > "$T/layout_bad.c"
if cc -fsyntax-only -I"$T/hdr" "$T/layout_ok.c" > "$T/layout_ok.err" 2>&1; then
	pass "(a) nv_ioctl_numa_info_t is 560 bytes and the Linux ioctl is 0xc23046d7"
else
	fail "(a) layout assertions rejected: $(head -n 3 "$T/layout_ok.err" | tr '\n' ' ')"
fi
if cc -fsyntax-only -I"$T/hdr" "$T/layout_bad.c" > /dev/null 2>&1; then
	fail "(a-control) a wrong size assertion was accepted: the layout check cannot fail"
else
	pass "(a-control) a wrong size assertion is rejected"
fi

# ---- (b) the OS layer answers the escape ----
# handle_body - print the body of nvidia_handle_ioctl() from a source file.
# Time:  O(lines).  Space: O(body).
handle_body() {
	awk '/^int nvidia_handle_ioctl\(/ { f = 1 } f { print } f && /^}/ { exit }' "$1"
}
# check_numa_case <file> <label> <want 0|1>
check_numa_case() {
	_src=$1
	_tag=$2
	_want=$3
	handle_body "$_src" > "$T/body"
	_case=$(grep -n 'case NV_ESC_NUMA_INFO:' "$T/body" | head -n 1 | cut -d: -f1 || :)
	_rmioctl=$(grep -n 'rm_ioctl(sp, nv, &nvffp->nvfp, nr' "$T/body" | head -n 1 | cut -d: -f1 || :)
	_size=$(grep -c 'sizeof(nv_ioctl_numa_info_t)' "$T/body" || :)
	_ok=0
	if [ -n "$_case" ] && [ -n "$_rmioctl" ] && [ "$_case" -lt "$_rmioctl" ] && \
	    [ "$_size" -ge 1 ]; then
		_ok=1
	fi
	if [ "$_ok" -eq "$_want" ]; then
		pass "(b) $_tag: NV_ESC_NUMA_INFO handled in nvidia_handle_ioctl() = $_ok"
	else
		fail "(b) $_tag: NV_ESC_NUMA_INFO handled in nvidia_handle_ioctl() = $_ok (want $_want)"
	fi
}
SUBR=$TREE/nvidia/nvidia_subr.c
if [ -f "$SUBR" ]; then
	check_numa_case "$SUBR" "prepared tree" 1
else
	# No prepared tree: the pristine source is today's state, and it has
	# no such branch, so (b) is red either way.
	mkdir -p "$T/pristine"
	if tar -xJf "$TARBALL" -C "$T/pristine" --strip-components 3 \
	    "$TOPDIR/src/nvidia/nvidia_subr.c" 2>/dev/null; then
		check_numa_case "$T/pristine/nvidia_subr.c" "pristine source (no tree)" 0
	else
		fail "(b) cannot extract the pristine nvidia_subr.c from $TARBALL"
	fi
fi

# ---- (c) control: the pristine source has no such branch ----
mkdir -p "$T/pristine"
if tar -xJf "$TARBALL" -C "$T/pristine" --strip-components 3 \
    "$TOPDIR/src/nvidia/nvidia_subr.c" 2>/dev/null; then
	check_numa_case "$T/pristine/nvidia_subr.c" "pristine source (control)" 0
else
	fail "(c-control) cannot extract the pristine nvidia_subr.c from $TARBALL"
fi

# ---- (d) the RM core does not know the escape ----
ESCAPE=$OGKM/src/nvidia/arch/nvalloc/unix/src/escape.c
if [ ! -f "$ESCAPE" ]; then
	fail "(d) missing $ESCAPE (run scripts/fetch-sources.sh)"
else
	n=$(grep -c 'case NV_ESC_NUMA_INFO' "$ESCAPE" || :)
	if [ "$n" -eq 0 ]; then
		pass "(d) the RM core's RmIoctl() has no case for NV_ESC_NUMA_INFO: the OS layer must answer it"
	else
		fail "(d) the RM core's escape.c handles NV_ESC_NUMA_INFO $n times (want 0)"
	fi
fi

echo "numa_escape_test: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
