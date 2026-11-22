#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# dma_window_test.sh - the DMA window RM reports for the GPU on arm64.
#
# nvidia-uvm logs "DMA window 0-0xffffffff" for the RTX 5060 Ti on amp001
# (RAM 98 GB).  The window is sc->dma_mask, handed to nvidia-uvm by
# nv-uvm-interface.c (dma_addressable_limit) and used by RM itself as the
# high bound of every system-memory allocation (nv_alloc_pages()).  RM
# sets it through osDmaSetAddressSize() -> nv_set_dma_address_size()
# with the GPU's physical address width; NVIDIA's FreeBSD layer honours
# that width only under NVCPU_X86_64 and pins every other architecture to
# 0xffffffff (nvidia_subr.c).
#
# Checks:
#   (a) the RM core calls nv_set_dma_address_size() with the GPU's width
#       (osinit.c), so the OS layer is where the width is lost;
#   (b) control: the pristine function, built as on arm64 (no NVCPU_X86_64),
#       returns 0xffffffff for 47 bits - the defect, so (c) is not vacuous;
#   (c) the prepared tree's function, built the same way, returns
#       (1<<bits)-1 for 47 and 40 bits, 0xffffffff for 32, the whole space
#       for 64, and keeps 0xffffffff for 0 and 16 (RED until the patch is
#       in the tree);
#   (d) patches/patch-nvidia_nvidia_subr.c applies to the pristine source and fixes it.
#
# Run: sh tests/dma_window_test.sh [TREE]
# nvidia.ko needs a rebuild and a boot for the runtime proof (the
# "DMA window" line in nvidia-uvm's registration message).

set -eu

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

TESTSDIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$TESTSDIR/.." && pwd)
WORK=${GB10_WORK:-$HOME/work/gb10}
TREE=${1:-$WORK/build/tree}
TOPDIR=NVIDIA-FreeBSD-x86_64-580.178.04
TARBALL=$WORK/sources/$TOPDIR.tar.xz
OGKM=$WORK/sources/open-gpu-kernel-modules-580.178.04
export TMPDIR=${TEST_TMPDIR:-$WORK/tmp}
mkdir -p "$TMPDIR"
T=$(mktemp -d "$TMPDIR/dma-window-test.XXXXXXXX") || exit 1

PASSED=0
FAILED=0
cleanup() { rm -rf "$T"; }
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 131' QUIT
trap 'exit 143' TERM
pass() { PASSED=$((PASSED + 1)); echo "PASS: $*"; }
fail() { FAILED=$((FAILED + 1)); echo "FAIL: $*"; }

if [ ! -f "$TARBALL" ]; then
	echo "dma_window_test: missing $TARBALL (run scripts/fetch-sources.sh)" >&2
	exit 2
fi
mkdir -p "$T/pristine/nvidia"
tar -xJf "$TARBALL" -C "$T/pristine/nvidia" --strip-components 3 \
    "$TOPDIR/src/nvidia/nvidia_subr.c" || exit 2

# ---- (a) RM passes the width ----
OSINIT=$OGKM/src/nvidia/arch/nvalloc/unix/src/osinit.c
if [ -f "$OSINIT" ] && grep -q 'nv_set_dma_address_size(pNv, dmaAddrWidth)' "$OSINIT"; then
	pass "(a) RM's osinit.c passes the GPU's DMA address width to nv_set_dma_address_size()"
else
	fail "(a) osinit.c does not call nv_set_dma_address_size(pNv, dmaAddrWidth) ($OSINIT)"
fi

# extract_fn <file> - print nv_set_dma_address_size() from a source file.
extract_fn() {
	awk '/^void NV_API_CALL nv_set_dma_address_size\(/ { f = 1 } f { print } f && /^}/ { exit }' "$1"
}

# run_fn <file> <tag> - build the function as arm64 builds it and print
# "bits mask" for each probe, one per line.
run_fn() {
	extract_fn "$1" > "$T/$2.fn"
	if [ ! -s "$T/$2.fn" ]; then
		return 1
	fi
	cat > "$T/$2.c" <<'HDR'
#include <stdint.h>
#include <stdio.h>
#define NV_API_CALL
typedef unsigned int NvU32;
struct nvidia_softc { uint64_t dma_mask; };
typedef struct { void *os_state; } nv_state_t;
HDR
	cat "$T/$2.fn" >> "$T/$2.c"
	cat >> "$T/$2.c" <<'MAIN'
int main(void)
{
	static const NvU32 probe[] = { 0, 16, 32, 40, 47, 64 };
	struct nvidia_softc sc;
	nv_state_t nv = { &sc };
	unsigned i;

	for (i = 0; i < sizeof(probe) / sizeof(probe[0]); i++) {
		sc.dma_mask = 0;
		nv_set_dma_address_size(&nv, probe[i]);
		printf("%u %#jx\n", probe[i], (uintmax_t)sc.dma_mask);
	}
	return 0;
}
MAIN
	cc -o "$T/$2.bin" "$T/$2.c" 2> "$T/$2.err" || return 1
	"$T/$2.bin" > "$T/$2.out"
}

# ---- (b) control: pristine is the defect ----
if run_fn "$T/pristine/nvidia/nvidia_subr.c" pristine &&
    grep -q '^47 0xffffffff$' "$T/pristine.out"; then
	pass "(b) control: the pristine function returns 0xffffffff for 47 bits on arm64"
else
	fail "(b) control: pristine function did not show the 32-bit clamp: $(cat "$T/pristine.out" 2>/dev/null | tr '\n' ' ')"
fi

# ---- (c) the prepared tree ----
SUBR=$TREE/nvidia/nvidia_subr.c
if [ ! -f "$SUBR" ]; then
	fail "(c) no prepared tree at $TREE (run scripts/prepare-tree.sh)"
elif run_fn "$SUBR" tree; then
	want="0 0xffffffff
16 0xffffffff
32 0xffffffff
40 0xffffffffff
47 0x7fffffffffff
64 0xffffffffffffffff"
	if [ "$(cat "$T/tree.out")" = "$want" ]; then
		pass "(c) the prepared tree honours the GPU's address width"
	else
		fail "(c) the prepared tree's nv_set_dma_address_size() is wrong: $(tr '\n' ';' < "$T/tree.out")"
	fi
else
	fail "(c) cannot build the prepared tree's nv_set_dma_address_size()"
fi

# ---- (d) the patch applies ----
P1=$REPO/patches/patch-nvidia_nvidia_subr.c
if [ ! -f "$P1" ]; then
	fail "(d) missing $P1"
elif patch -d "$T/pristine" -p0 -E -s -i "$P1" &&
    run_fn "$T/pristine/nvidia/nvidia_subr.c" patched &&
    grep -q '^47 0x7fffffffffff$' "$T/patched.out"; then
	pass "(d) the subr patch applies to the pristine source and yields (1<<47)-1 for 47 bits"
else
	fail "(d) the subr patch does not apply or does not fix the function"
fi

echo "dma_window_test: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
