#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# uvm_glue_test.sh - tests for the UVM interface of the OS layer
# (src/gb10-uvm/nv-uvm-interface.[ch], patches/patch-nvidia_nvidia_subr.c,
# patches/patch-nvidia_Makefile, patches/patch-nvidia_nvidia-sources.mk),
# the glue that uvm-spec r1, 02-rm-interface.md section 6 asks for.
#
# Runs against a prepared and built tree (default ${GB10_WORK}/build/tree,
# or the TREE given as the first argument) and the pinned sources. Checks:
#   (a) exports: every nvUvmInterface* function the header declares is a
#       defined, exported (nm -D) symbol of TREE/nvidia/nvidia.ko, and the
#       three hooks RM calls (nv_schedule_uvm_isr, nv_schedule_uvm_drain_p2p,
#       nv_schedule_uvm_resume_p2p) are defined exactly once each - the
#       stubs NVIDIA's nvidia_subr.c carried are gone;
#   (b) layout: the RM core's own interface structures, compiled with the
#       tree's headers and flags, have the sizes and offsets the spec's
#       section 02 states (the UVM module hard-codes them on its side),
#       and this port's callback table is 56 bytes with isrTopHalf at byte
#       32. Falsified by a mutant that asserts a wrong size, which the
#       compiler must reject;
#   (c) ordering: in nvidia_intr() the UVM top half is called BEFORE
#       rm_isr(), and the OS layer's copy of MMU faults runs only when no
#       UVM callback table is installed. Red on NVIDIA's pristine source
#       (extracted from the verified tarball into scratch);
#   (d) power management: nv_uvm_suspend() precedes RM's standby and
#       nv_uvm_resume() follows RM's resume in nvidia_subr.c;
#   (e) manifest: TREE/.prepared records the three MIT headers as
#       ogkm:<path> entries whose sha256 still matches the pinned checkout.
#
# Run: sh tests/uvm_glue_test.sh [TREE]

set -eu

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

TESTSDIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$TESTSDIR/.." && pwd)
WORK=${GB10_WORK:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)/work}
TREE=${1:-$WORK/build/tree}
SYSDIR=${SYSDIR:-/usr/src/sys}
TOPDIR=NVIDIA-FreeBSD-x86_64-580.178.04
TARBALL=$WORK/sources/$TOPDIR.tar.xz
OGKM=$WORK/sources/open-gpu-kernel-modules-580.178.04
HDR=$REPO/src/gb10-uvm/nv-uvm-interface.h
KO=$TREE/nvidia/nvidia.ko
SUBR=$TREE/nvidia/nvidia_subr.c
export TMPDIR="$WORK/tmp"
mkdir -p "$WORK/tmp"
T=$(mktemp -d "$WORK/tmp/uvm-glue-test.XXXXXXXX") || exit 1

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

for f in "$KO" "$SUBR" "$HDR" "$TARBALL"; do
	if [ ! -f "$f" ]; then
		echo "uvm_glue_test: missing $f (prepare and build the tree first)" >&2
		exit 2
	fi
done

# ---- (a) exports ----
# the interface names the header declares, one per line
grep -o 'nvUvmInterface[A-Za-z0-9]*(' "$HDR" | sed 's/($//' | sort -u > "$T/declared"
if ! nm -D "$KO" > "$T/nmd" 2>/dev/null; then
	echo "uvm_glue_test: nm -D failed on $KO" >&2
	exit 2
fi
awk '$2 == "T" && $3 ~ /^nvUvmInterface/ { print $3 }' "$T/nmd" | sort -u > "$T/exported"
if [ ! -s "$T/declared" ]; then
	fail "(a) the header declares no nvUvmInterface function"
elif comm -23 "$T/declared" "$T/exported" > "$T/missing" && [ ! -s "$T/missing" ]; then
	pass "(a) every declared nvUvmInterface function ($(awk 'END { print NR }' < "$T/declared")) is exported by nvidia.ko"
else
	fail "(a) declared but not exported: $(tr '\n' ' ' < "$T/missing")"
fi
for h in nv_schedule_uvm_isr nv_schedule_uvm_drain_p2p nv_schedule_uvm_resume_p2p; do
	n=$(nm "$KO" | awk -v s="$h" '$3 == s && ($2 == "T" || $2 == "t") { c++ } END { print c + 0 }')
	if [ "$n" -eq 1 ]; then
		pass "(a) $h defined once"
	else
		fail "(a) $h defined $n times (want 1)"
	fi
done

# ---- (b) layout ----
# Compile with the tree's own include paths: TREE/nvidia carries the
# machine symlink bsd.kmod.mk made, the copied MIT headers and the glue
# header; TREE/common/inc the NVIDIA common headers.
CFLAGS="-fsyntax-only -ffreestanding -fno-builtin -D__printf__=__freebsd_kprintf__ -Wno-pointer-sign -D__KERNEL__ -DNVRM -DNV_KERNEL_INTERFACE_LAYER -D_KERNEL -DKLD_MODULE \
-nostdinc -I$TREE/nvidia -I$TREE/common/inc -I$SYSDIR -I$SYSDIR/contrib/ck/include \
-include $TREE/nvidia/opt_global.h -Wall -Werror"
cat > "$T/layout.c" <<'EOF'
#include <sys/param.h>
#include <sys/systm.h>
#include "os-interface.h"
#include "nv.h"
#include "nv-freebsd.h"
#include "nv-uvm-interface.h"
#define SZ(t, n) _Static_assert(sizeof(t) == (n), #t)
#define OF(t, f, n) _Static_assert(__builtin_offsetof(t, f) == (n), #t "." #f)
SZ(UvmGpuInfo, 240); OF(UvmGpuInfo, gpuArch, 80); OF(UvmGpuInfo, hostClass, 88);
OF(UvmGpuInfo, ceClass, 92); OF(UvmGpuInfo, accessCntrBufferCount, 132);
OF(UvmGpuInfo, sysmemLink, 156); OF(UvmGpuInfo, nvlDirectConnectMemoryWindowStart, 232);
SZ(UvmGpuCaps, 8); SZ(UvmGpuAddressSpaceInfo, 48); SZ(UvmGpuAllocInfo, 40);
SZ(UvmGpuFbInfo, 64); SZ(UvmGpuEccInfo, 32); SZ(UvmGpuNvlinkInfo, 32);
SZ(UvmGpuCopyEngineCaps, 8); SZ(UvmGpuCopyEnginesCaps, 512); SZ(UvmGpuChannelInfo, 120);
OF(UvmGpuChannelInfo, workSubmissionOffset, 64); OF(UvmGpuChannelInfo, workSubmissionToken, 72);
SZ(UvmGpuTsgAllocParams, 8); SZ(UvmGpuChannelAllocParams, 12); SZ(UvmGpuMemoryInfo, 56);
SZ(UvmGpuChannelResourceInfo, 80); SZ(UvmGpuChannelInstanceInfo, 1120);
OF(UvmGpuChannelInstanceInfo, resourceCount, 1080);
OF(UvmGpuChannelInstanceInfo, pChramChannelRegister, 1096);
SZ(UvmGpuChannelResourceBindParams, 16); SZ(UvmGpuExternalMappingInfo, 72);
SZ(UvmGpuFaultInfo, 184); OF(UvmGpuFaultInfo, nonReplayable, 104);
OF(UvmGpuFaultInfo, nonReplayable.isr_sp, 128); OF(UvmGpuFaultInfo, nonReplayable.isr_bh_sp, 136);
OF(UvmGpuFaultInfo, faultBufferHandle, 168);
SZ(UvmPmaAllocationOptions, 56); SZ(UvmPmaStatistics, 48); SZ(UvmPlatformInfo, 2);
SZ(UvmGpuP2PCapsParams, 64); SZ(UvmGpuAccessCntrInfo, 72); SZ(UvmGpuAccessCntrConfig, 8);
SZ(nv_uvm_events_t, 56); OF(nv_uvm_events_t, isrTopHalf, 32); OF(nv_uvm_events_t, resumeP2P, 48);
SZ(nv_uvm_gpu_platform_info_t, 24); OF(nv_uvm_gpu_platform_info_t, dma_addressable_limit, 16);
MUTANT
EOF
sed 's/^MUTANT$//' "$T/layout.c" > "$T/layout_ok.c"
sed 's/^MUTANT$/SZ(UvmGpuInfo, 241);/' "$T/layout.c" > "$T/layout_bad.c"
# shellcheck disable=SC2086
if cc $CFLAGS "$T/layout_ok.c" > "$T/layout_ok.err" 2>&1; then
	pass "(b) the RM interface structures have the spec's layout with the tree's headers"
else
	fail "(b) layout assertions rejected: $(head -n 3 "$T/layout_ok.err" | tr '\n' ' ')"
fi
# shellcheck disable=SC2086
if cc $CFLAGS "$T/layout_bad.c" > /dev/null 2>&1; then
	fail "(b-control) a wrong size assertion was accepted: the layout check cannot fail"
else
	pass "(b-control) a wrong size assertion is rejected"
fi

# ---- (c) ordering in nvidia_intr(), (d) power management ----
# intr_body - print the body of nvidia_intr() from a source file.
# Time:  O(lines).  Space: O(body).
intr_body() {
	awk '/^void nvidia_intr\(void \*xsc\)/ { f = 1 } f { print } f && /^}/ { exit }' "$1"
}
check_order() {
	_src=$1
	_tag=$2
	_want=$3
	intr_body "$_src" > "$T/body"
	# a grep that finds nothing exits 1: never let set -e read that as a failure
	_top=$(grep -n 'nv_uvm_isr_top_half(nv)' "$T/body" | head -n 1 | cut -d: -f1 || :)
	_isr=$(grep -n 'rm_isr(sp, nv, &run_bottom_half)' "$T/body" | head -n 1 | cut -d: -f1 || :)
	_guard=$(grep -c 'if (!nv_uvm_callbacks_installed())' "$T/body" || :)
	_ok=0
	if [ -n "$_top" ] && [ -n "$_isr" ] && [ "$_top" -lt "$_isr" ] && [ "$_guard" -eq 1 ]; then
		_ok=1
	fi
	if [ "$_ok" -eq "$_want" ]; then
		pass "(c) $_tag: UVM top half before rm_isr and guarded fault copy = $_ok"
	else
		fail "(c) $_tag: ordering check gave $_ok, want $_want"
	fi
}
check_order "$SUBR" "prepared tree" 1
mkdir -p "$T/pristine"
if tar -xJf "$TARBALL" -C "$T/pristine" --strip-components 3 "$TOPDIR/src/nvidia/nvidia_subr.c" 2>/dev/null; then
	check_order "$T/pristine/nvidia_subr.c" "pristine source (control)" 0
else
	fail "(c-control) cannot extract the pristine nvidia_subr.c from $TARBALL"
fi

susp=$(grep -n 'status = nv_uvm_suspend();' "$SUBR" | head -n 1 | cut -d: -f1 || :)
stby=$(grep -n 'rm_power_management(sp, nv, NV_PM_ACTION_STANDBY)' "$SUBR" | head -n 1 | cut -d: -f1 || :)
resm=$(grep -n 'rm_power_management(sp, nv, NV_PM_ACTION_RESUME)' "$SUBR" | head -n 1 | cut -d: -f1 || :)
uresm=$(grep -n '(void)nv_uvm_resume();' "$SUBR" | head -n 1 | cut -d: -f1 || :)
if [ -n "$susp" ] && [ -n "$stby" ] && [ "$susp" -lt "$stby" ] && \
    [ -n "$resm" ] && [ -n "$uresm" ] && [ "$resm" -lt "$uresm" ]; then
	pass "(d) UVM suspend precedes RM standby; UVM resume follows RM resume"
else
	fail "(d) suspend/resume hook order (suspend $susp standby $stby resume $resm uvm-resume $uresm)"
fi

# ---- (e) manifest ----
if [ -f "$TREE/.prepared" ]; then
	n=0
	bad=0
	while read -r name sha; do
		case $name in
		ogkm:*)
			n=$((n + 1))
			f=$OGKM/${name#ogkm:}
			if [ ! -f "$f" ] || [ "$(sha256 -q "$f")" != "$sha" ]; then
				bad=$((bad + 1))
			fi
			;;
		esac
	done < "$TREE/.prepared"
	if [ "$n" -eq 3 ] && [ "$bad" -eq 0 ]; then
		pass "(e) the manifest records the 3 MIT interface headers and they match the pinned checkout"
	else
		fail "(e) manifest: $n ogkm entries, $bad mismatched (want 3, 0)"
	fi
else
	fail "(e) $TREE/.prepared is missing"
fi

echo "uvm_glue_test: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
