#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# prime_import_test.sh - the cross-GPU import (PRIME) glue is wired the way
# docs/PRIME-IMPORT.md says (Track #2228).  The pure logic is tested by
# tests/pageimport_test.sh and the KAPI table by tests/kapi_table_test.sh;
# this test reads the patched sources, because the kernel pieces cannot run
# without the GPU.  The repository's patches are applied to NVIDIA's
# pristine sources and the result is checked for:
#
#  RM core (patches/ogkm)
#   R1  a kernel RM client (NVKMS is one) may create a page-array
#       descriptor: the exception list of osCreateMemFromOsDescriptor()
#       names NVOS32_DESCRIPTOR_TYPE_OS_PAGE_ARRAY;
#  KAPI (patches/ogkm)
#   K1  GetSystemMemoryHandleFromPageArray() builds a page-array
#       descriptor, asks for write-back caching (never write-combining, never
#       a contiguous allocation), refuses a NULL array, and reports whether
#       the RM took the array, by looking at the descriptor the RM clears
#       (the rule RmCreateOsDescriptor() in the RM uses);
#  nvidia-drm (patches/patch-nvidia-drm_*)
#   D1  the import converts the scatter list (gb10_pi_fill) before it wires
#       (nv_import_pages) and before it calls the KAPI, tries the RM's own
#       dma-buf import first, gives the array back (nv_unimport_pages) when
#       the RM did not take it, refuses an nvidia-modeset.ko without the new
#       entry, and logs the reason for a refusal;
#   D2  the GEM object's destruction order stays: the RM handle is freed
#       before drm_prime_gem_destroy(), and the retained page array after;
#   D3  the export ioctl is served from the retained descriptor, not from
#       the Linux sg_table the OS layer cannot read, and refuses a buffer
#       that has none; whenever the pages were imported the export goes
#       through the SGT path (a reference on the GEM object), never straight
#       from the page-array handle (no reference on the exporter);
#   D4  the exporter's dma-buf is held (gb10_pi_life_take) when the pages
#       are imported and dropped last, after the RM handle, the attachment
#       and the page array; the KAPI is called with size - 1, not size
#       (the RM rounds the limit up: one page past the array);
#   D5  the screening and the OS layer's re-check are the same function,
#       gb10_pi_page_claimable (one place decides what may be imported);
#  OS layer (patches/patch-nvidia_*)
#   O1  nv_import_pages() (in src/gb10-pageimport/gb10_pageimport_os.c, our
#       BSD file, not in NVIDIA's proprietary nvidia_subr.c) allocates with
#       os_alloc_mem(), checks the count with gb10_pi_array_ok(), wires
#       through the core, and frees the array when the wiring fails;
#       nv_unimport_pages() unwires and frees;
#   O2  the unwire the OS layer does is the one the RM's teardown does
#       (vm_page_unwire(..., PQ_ACTIVE), as os_unlock_user_pages()), the
#       wire is vm_page_wire() with the page busied (vm_page_tryxbusy,
#       vm_page_xunbusy) and re-checked by gb10_pi_page_claimable(); the
#       dirty step of os_unlock_user_pages() is gb10_pi_os_dirty(), which
#       busies the page and dirties it only as gb10_pi_dirty_action() says
#       (vm_page_all_valid at the dirty site) and counts a refusal in a
#       read-only sysctl; no NVIDIA file carries our logic;
#   O3  nv_register_sgt() is not a stub that returns success: it registers
#       through the core, sets the private data the RM asserts on, and
#       nv_unregister_sgt() hands back the descriptor and the owner;
#       nv_dma_import_sgt() and nv_dma_release_sgt() take and drop the owner;
#   O4  nvidia.ko exports nv_import_pages and nv_unimport_pages, because
#       nvidia-drm.ko is a separate module;
#   R2  (pristine RM) the RM uses a kernel caller's allocation parameters in
#       place, which the KAPI's ownership report relies on;
#   O5  scripts/prepare-tree.sh installs the core header where both modules
#       find it.
#
# The same checks run on the pristine sources (they MUST fail there) and on
# mutants of the patched sources (they must fail as well): a check that
# cannot fail is not a check.
#
# Run: sh tests/prime_import_test.sh    Exit 0 when every check passes.

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
TMPD=$(mktemp -d "$WORK/tmp/prime-import-test.XXXXXXXX") || exit 1
trap 'rm -rf -- "$TMPD"' EXIT INT TERM
. "$repo/tests/csrc_lib.sh"

# The order in which a file's modules unload (sys/kern/kern_module.c module_register_init():
# each loaded module goes to the HEAD of the file's list; sys/kern/kern_linker.c
# linker_file_unload(): a refused quiesce is ignored when forced, then each module is unloaded
# in list order and a refused unload returns the error whatever the flags).  The sysinits load
# in (subsystem, order) order; a tie is not specified, so the model takes the worst case for the guard (it loads first).  This model is the two functions
# above in 40 lines; its input is the real order of the guard, read from the patched source.
SYSDIR=${SYSDIR:-$HOME/src/csrc-90dcf68/sys}
KERNELH=$SYSDIR/sys/kernel.h
[ -f "$KERNELH" ] || { echo "FAIL: no $KERNELH (set SYSDIR to the kernel source the modules are built against)"; exit 1; }
kval() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\(0x[0-9a-fA-F]*\).*/\1/p" "$KERNELH" | head -1; }
cat > "$TMPD/ordermodel.c" <<'MODEL'
#include <stdio.h>
#include <stdlib.h>
#define EBUSY_ 16
struct mod { int guard; unsigned long sub, ord; };
int main(int argc, char **argv)
{
	struct mod decl[2], list[2], t;
	int holds, force, i, n = 0, rc = 0, teardown = 0;

	if (argc != 7)
		return 2;
	/* declaration order in the file: the driver module, then the guard */
	decl[0] = (struct mod){ 0, strtoul(argv[3], 0, 0), strtoul(argv[4], 0, 0) };
	decl[1] = (struct mod){ 1, strtoul(argv[1], 0, 0), strtoul(argv[2], 0, 0) };
	holds = atoi(argv[5]);
	force = atoi(argv[6]);
	/* sysinit order: (subsystem, order); a tie is unspecified: the guard is taken to load first (the bad case) */
	if (decl[1].sub < decl[0].sub || (decl[1].sub == decl[0].sub && decl[1].ord <= decl[0].ord)) {
		t = decl[0]; decl[0] = decl[1]; decl[1] = t;
	}
	/* load: each module goes to the head of the list */
	for (i = 0; i < 2; i++) {
		list[1] = list[0];
		list[0] = decl[i];
		n++;
	}
	/* quiesce pass: a refusal aborts unless forced */
	for (i = 0; i < n; i++)
		if (list[i].guard && holds > 0 && !force) { printf("rc=%d teardown=%d\n", EBUSY_, teardown); return 0; }
	/* unload pass: a refusal aborts whatever the flags */
	for (i = 0; i < n; i++) {
		if (list[i].guard) {
			if (holds > 0) { rc = EBUSY_; break; }
		} else {
			teardown = 1;
		}
	}
	printf("rc=%d teardown=%d\n", rc, teardown);
	return 0;
}
MODEL
cc -o "$TMPD/ordermodel" "$TMPD/ordermodel.c" || { echo "FAIL: the unload-order model does not compile"; exit 1; }

passed=0
failed=0
ok() { echo "PASS: $1"; passed=$((passed + 1)); }
bad() { echo "FAIL: $1"; failed=$((failed + 1)); }

DMABUF=nvidia-drm/nvidia-drm-gem-dma-buf.c
DMABUFH=nvidia-drm/nvidia-drm-gem-dma-buf.h
LKPI=nvidia-drm/nvidia-drm-freebsd-lkpi.c
DRV=nvidia-drm/nvidia-drm-drv.c
SUBR=nvidia/nvidia_subr.c
OSF=nvidia/gb10_pageimport_os.c
OSC=nvidia/nvidia_os.c
MKF=nvidia/Makefile
OSMEM=src/nvidia/arch/nvalloc/unix/src/osmemdesc.c
KAPIC=src/nvidia-modeset/kapi/src/nvkms-kapi.c

for f in "$PRISTINE/$DMABUF" "$PRISTINE/$DMABUFH" "$PRISTINE/$SUBR" "$PRISTINE/$OSC" "$PRISTINE/$MKF" \
    "$OGKMSRC/$OSMEM" "$OGKMSRC/$KAPIC"; do
	[ -f "$f" ] || { echo "FAIL: missing $f (run scripts/fetch-sources.sh)"; exit 1; }
done

# make_tree <dir> <patched>: copy the sources; apply the patches when asked.
make_tree() {
	_d=$1
	mkdir -p "$_d/nvidia-drm" "$_d/nvidia" "$_d/ogkm/$(dirname "$OSMEM")" "$_d/ogkm/$(dirname "$KAPIC")"
	for _f in $DMABUF $DMABUFH $LKPI $DRV $SUBR $OSC $MKF; do cp "$PRISTINE/$_f" "$_d/$_f" || return 1; done
	for _f in $OSMEM $KAPIC; do cp "$OGKMSRC/$_f" "$_d/ogkm/$_f" || return 1; done
	[ "$2" -eq 1 ] || return 0
	cp "$repo/src/gb10-pageimport/gb10_pageimport_os.c" "$_d/nvidia/gb10_pageimport_os.c" || return 1
	for _p in patch-nvidia-drm_nvidia-drm-gem-dma-buf.c patch-nvidia-drm_nvidia-drm-gem-dma-buf.h \
	    patch-nvidia-drm_nvidia-drm-freebsd-lkpi.c patch-nvidia-drm_nvidia-drm-drv.c patch-nvidia-drm_nvidia-drm-drv_prime.c \
	    patch-nvidia_nvidia_subr.c patch-nvidia_nvidia_subr_prime.c patch-nvidia_nvidia_os.c patch-nvidia_Makefile; do
		[ -f "$repo/patches/$_p" ] || { echo "missing patches/$_p"; return 1; }
		patch -d "$_d" -p0 -E -s -i "$repo/patches/$_p" || { echo "patches/$_p does not apply"; return 1; }
	done
	for _p in patch-src_nvidia_arch_nvalloc_unix_src_osmemdesc.c patch-src_nvidia-modeset_kapi_src_nvkms-kapi.c; do
		[ -f "$repo/patches/ogkm/$_p" ] || { echo "missing patches/ogkm/$_p"; return 1; }
		patch -d "$_d/ogkm" -p0 -E -s -i "$repo/patches/ogkm/$_p" || { echo "patches/ogkm/$_p does not apply"; return 1; }
	done
}

# check_tree <dir>: print the first defect found, nothing when there is none.
check_tree() {
	_t=$1
	# R1
	_ex=$(awk '/rmclientGetCachedPrivilege\(pClient\) >= RS_PRIV_LEVEL_KERNEL/ { on = 1 }
	           on { print; if (++n >= 8) exit }' "$_t/ogkm/$OSMEM")
	case $_ex in
	*NVOS32_DESCRIPTOR_TYPE_OS_PAGE_ARRAY*) ;;
	*) echo "R1: a kernel RM client may not create a page-array descriptor"; return ;;
	esac
	# K1
	body "$_t/ogkm/$KAPIC" GetSystemMemoryHandleFromPageArray "$TMPD/k.c" || {
		echo "K1: no GetSystemMemoryHandleFromPageArray in the KAPI"; return; }
	grep -q 'NVOS32_DESCRIPTOR_TYPE_OS_PAGE_ARRAY' "$TMPD/k.c" || { echo "K1: not a page-array descriptor"; return; }
	grep -q '_WRITE_BACK' "$TMPD/k.c" || { echo "K1: write-back caching is not requested"; return; }
	grep -q '_WRITE_COMBINE\|_UNCACHED' "$TMPD/k.c" && { echo "K1: asks for a cache mode the page-array path refuses"; return; }
	grep -q '_CONTIGUOUS' "$TMPD/k.c" && { echo "K1: asks for a contiguous allocation"; return; }
	grep -Eq 'pages[[:space:]]*==[[:space:]]*NvP64_NULL' "$TMPD/k.c" || { echo "K1: a NULL array is not refused"; return; }
	before "$TMPD/k.c" 'nvRmApiAlloc(' 'descriptor[[:space:]]*==[[:space:]]*NvP64_NULL' || {
		echo "K1: the caller is not told whether the RM took the array"; return; }
	grep -q 'pPagesTaken' "$TMPD/k.c" || { echo "K1: no out parameter for the ownership"; return; }
	# D1
	body "$_t/$DMABUF" nv_drm_gem_prime_import_sg_table "$TMPD/imp.c" || { echo "D1: no import function"; return; }
	before "$TMPD/imp.c" 'getSystemMemoryHandleFromDmaBuf(' '__nv_drm_gem_dma_buf_import_pages(' || {
		echo "D1: the page-array import does not follow the RM's own import"; return; }
	body "$_t/$DMABUF" __nv_drm_gem_dma_buf_import_pages "$TMPD/ip.c" || { echo "D1: no __nv_drm_gem_dma_buf_import_pages"; return; }
	before "$TMPD/ip.c" 'getSystemMemoryHandleFromPageArray[[:space:]]*==[[:space:]]*NULL' 'nv_import_pages(' || {
		echo "D1: an nvidia-modeset.ko without the page-array entry is not refused before the pages are wired"; return; }
	grep -Eq 'extern[^;]*nv_(un)?import_pages' "$_t/$DMABUF" && { echo "D1: nvidia-drm declares nv_import_pages itself instead of using the shared header"; return; }
	before "$TMPD/ip.c" 'gb10_pi_fill(' 'nv_import_pages(' || { echo "D1: the pages are wired before the scatter list is checked"; return; }
	before "$TMPD/ip.c" 'nv_import_pages(' 'getSystemMemoryHandleFromPageArray(' || { echo "D1: the KAPI is called before the pages are wired"; return; }
	grep -q 'GB10_PI_DESC_MAGIC' "$TMPD/ip.c" || { echo "D1: the descriptor for the export is not set up"; return; }
	grep -q 'gb10_pi_str(' "$TMPD/ip.c" || { echo "D1: a refusal does not say why"; return; }
	grep -q 'NV_DRM_DEV_LOG_ERR' "$TMPD/ip.c" || { echo "D1: a refusal is not logged"; return; }
	before "$TMPD/ip.c" 'getSystemMemoryHandleFromPageArray(' 'nv_unimport_pages(' || {
		echo "D1: the array is not given back when the RM did not take it"; return; }
	grep -Eq '!pages_taken|pages_taken[[:space:]]*==[[:space:]]*(NV_FALSE|0)' "$TMPD/ip.c" || {
		echo "D1: the array is given back without asking whether the RM took it"; return; }
	body "$_t/$DMABUF" __nv_drm_pi_page_at "$TMPD/dp.c" || { echo "D1: no __nv_drm_pi_page_at"; return; }
	grep -q 'vm_phys_paddr_to_vm_page(' "$TMPD/dp.c" && grep -q 'PG_FICTITIOUS' "$TMPD/dp.c" || {
		echo "D1: nvidia-drm does not check that a page is managed RAM"; return; }
	tr '\n' ' ' < "$TMPD/ip.c" > "$TMPD/ipflat.c"
	grep -Eq 'getSystemMemoryHandleFromPageArray\([^;]*[[:space:],]size[[:space:]]*-[[:space:]]*1[[:space:]]*,' "$TMPD/ipflat.c" || {
		echo "D4: the KAPI limit is not size - 1 (the RM would read one page past the array)"; return; }
	grep -q 'gb10_pi_life_take(' "$TMPD/ip.c" || { echo "D4: the exporter's dma-buf is not held when the pages are imported"; return; }
	grep -q 'gb10_pi_page_claimable(' "$TMPD/dp.c" || { echo "D5: nvidia-drm does not use the shared page check"; return; }
	# D2
	body "$_t/$DMABUF" __nv_drm_gem_dma_buf_free "$TMPD/fr.c" || { echo "D2: no free function"; return; }
	before "$TMPD/fr.c" 'nvKms->freeMemory(' 'drm_prime_gem_destroy(' || { echo "D2: the GEM object is destroyed before the RM handle is freed"; return; }
	before "$TMPD/fr.c" 'drm_prime_gem_destroy(' 'nv_drm_free(nv_dma_buf->pages)' || { echo "D2: the retained page array is not freed after the GEM object"; return; }
	before "$TMPD/fr.c" 'nv_drm_free(nv_dma_buf->pages)' 'gb10_pi_life_drop(' || { echo "D4: the exporter's dma-buf is dropped before the pages are released"; return; }
	before "$TMPD/fr.c" 'nvKms->freeMemory(' 'gb10_pi_life_drop(' || { echo "D4: the exporter's dma-buf is dropped before the RM handle is freed"; return; }
	before "$TMPD/fr.c" 'gb10_pi_life_drop(' 'nv_drm_free(nv_dma_buf);' || { echo "D4: the exporter's dma-buf is not dropped as the last step"; return; }
	# D3
	body "$_t/$DMABUF" nv_drm_gem_export_dmabuf_memory_ioctl "$TMPD/ex.c" || { echo "D3: no export ioctl"; return; }
	grep -Fq '&nv_dma_buf->pi_desc' "$TMPD/ex.c" || { echo "D3: the export is not served from the retained descriptor"; return; }
	grep -Fq 'nv_dma_buf->sgt' "$TMPD/ex.c" && { echo "D3: the export hands the OS layer a Linux sg_table"; return; }
	before "$TMPD/ex.c" 'nv_dma_buf->pages[[:space:]]*==[[:space:]]*NULL' 'getSystemMemoryHandleFromSgt(' || {
		echo "D3: a buffer without a retained descriptor is not refused"; return; }
	tr '\n' ' ' < "$TMPD/ex.c" > "$TMPD/exflat.c"
	grep -Eq 'if \(!nv_dma_buf->base\.pMemory[[:space:]]*\|\|[[:space:]]*nv_dma_buf->pages[[:space:]]*!=[[:space:]]*NULL\)' "$TMPD/exflat.c" || {
		echo "D3: a buffer whose pages were imported is exported straight from the page-array handle, which holds no reference on the exporter"; return; }
	grep -Eq 'exportMemory\([^;]*pTmpMemory[[:space:]]*\?[[:space:]]*pTmpMemory[[:space:]]*:[[:space:]]*nv_dma_buf->base\.pMemory' "$TMPD/exflat.c" || {
		echo "D3: the export prefers the page-array handle over the SGT one"; return; }
	# O1
	body "$_t/$OSF" nv_import_pages "$TMPD/ni.c" || { echo "O1: no nv_import_pages in $OSF"; return; }
	grep -q 'gb10_pi_array_ok(' "$TMPD/ni.c" || { echo "O1: nv_import_pages does not check the page count with gb10_pi_array_ok"; return; }
	before "$TMPD/ni.c" 'os_alloc_mem(' 'gb10_pi_wire(' || { echo "O1: the array is not allocated with os_alloc_mem before the wiring"; return; }
	before "$TMPD/ni.c" 'gb10_pi_wire(' 'os_free_mem(' || { echo "O1: a failed wiring does not free the array"; return; }
	grep -q 'nv_pi_status(' "$TMPD/ni.c" || { echo "O1: the wiring result is not mapped by the one status function"; return; }
	body "$_t/$OSF" nv_pi_status "$TMPD/st.c" && grep -q 'GB10_PI_PAGE_BUSY' "$TMPD/st.c" && grep -q 'NV_ERR_BUSY_RETRY' "$TMPD/st.c" || { echo "O1: a page the exporter holds busy is not reported as a retry"; return; }
	grep -q 'GB10_PI_PAGE_CHANGED' "$TMPD/st.c" && ! grep -A1 'GB10_PI_PAGE_CHANGED' "$TMPD/st.c" | grep -q 'BUSY_RETRY' || { echo "O1: a page that changed for good is reported as a retry"; return; }
	body "$_t/$OSF" nv_unimport_pages "$TMPD/nu.c" || { echo "O1: no nv_unimport_pages"; return; }
	before "$TMPD/nu.c" 'gb10_pi_unwire(' 'os_free_mem(' || { echo "O1: nv_unimport_pages does not unwire and free"; return; }
	# O2: the wire path, in the bodies of its own operations
	grep -Eq 'vm_page_unwire\(.*,[[:space:]]*PQ_ACTIVE\)' "$_t/$OSF" || { echo "O2: the unwire is not vm_page_unwire(..., PQ_ACTIVE)"; return; }
	grep -Eq 'vm_page_unwire\(.*,[[:space:]]*PQ_ACTIVE\)' "$_t/$OSC" || { echo "O2: the RM's own unwire changed; revisit the parity"; return; }
	body "$_t/$OSF" nv_pi_wire "$TMPD/w.c" && grep -q 'vm_page_wire(' "$TMPD/w.c" || { echo "O2: the wire is not vm_page_wire()"; return; }
	body "$_t/$OSF" nv_busy_try "$TMPD/tb.c" && grep -q 'vm_page_tryxbusy(' "$TMPD/tb.c" || { echo "O2: the busy operation does not busy the page (nv_busy_try)"; return; }
	body "$_t/$OSF" nv_busy_release "$TMPD/ub.c" && grep -q 'vm_page_xunbusy(' "$TMPD/ub.c" || { echo "O2: the busy operation does not unbusy the page (nv_busy_release)"; return; }
	grep -Eq '\.try_busy[[:space:]]*=[[:space:]]*nv_busy_try' "$_t/$OSF" && grep -Eq '\.unbusy[[:space:]]*=[[:space:]]*nv_busy_release' "$_t/$OSF" || { echo "O2: the wire or dirty operations do not use the busy operations"; return; }
	grep -c '\.try_busy[[:space:]]*=[[:space:]]*nv_busy_try' "$_t/$OSF" | grep -q '^2$' || { echo "O2: the wiring and the dirty step do not both busy through nv_busy_try"; return; }
	body "$_t/$OSF" nv_pi_claimable "$TMPD/pa.c" || { echo "O2: no nv_pi_claimable"; return; }
	grep -q 'gb10_pi_page_claimable(' "$TMPD/pa.c" && grep -q 'PG_FICTITIOUS' "$TMPD/pa.c" && grep -q 'object[[:space:]]*!=[[:space:]]*NULL' "$TMPD/pa.c" || {
		echo "O2: the OS layer's re-check of a page is not the shared check with the fictitious and object tests"; return; }
	grep -q 'object[[:space:]]*!=[[:space:]]*NULL\|gb10_pi_page_claimable' "$TMPD/dp.c" || {
		echo "O2: a page that belongs to a VM object is not refused in nvidia-drm"; return; }
	# the dirty step: in our file, decided by the core, every operation real
	body "$_t/$OSC" os_unlock_user_pages "$TMPD/ou.c" || { echo "O2: no os_unlock_user_pages"; return; }
	grep -q 'gb10_pi_os_dirty(' "$TMPD/ou.c" || { echo "O2: os_unlock_user_pages does not use the guarded dirty step (vm_page_dirty panics on a page that is not valid)"; return; }
	grep -q 'vm_page_dirty(' "$TMPD/ou.c" && { echo "O2: os_unlock_user_pages still calls vm_page_dirty() itself"; return; }
	body "$_t/$OSF" nv_dirty_delay "$TMPD/d2.c" && grep -q 'DELAY(GB10_PI_DIRTY_SPIN_US)' "$TMPD/d2.c" || { echo "O2: the dirty step does not spin for a busy page with DELAY(GB10_PI_DIRTY_SPIN_US)"; return; }
	grep -q 'vm_page_busy_acquire(\|pause(\|THREAD_CAN_SLEEP\|msleep(' "$TMPD/d2.c" && { echo "O2: the dirty step sleeps in the RM's teardown, which may hold locks the sleep check does not see"; return; }
	grep -Eq '\.delay[[:space:]]*=[[:space:]]*nv_dirty_delay' "$_t/$OSF" || { echo "O2: the dirty operations do not use nv_dirty_delay"; return; }
	grep -Eq '^[[:space:]]+int[[:space:]]+dirty_spin[[:space:]]*=[[:space:]]*GB10_PI_DIRTY_SPIN_BUDGET;' "$TMPD/ou.c" && grep -q 'gb10_pi_os_dirty(user_pages\[i\],[[:space:]]*&dirty_spin)' "$TMPD/ou.c" || { echo "O2: the spin budget is not one per os_unlock_user_pages call, shared by all its pages"; return; }
	body "$_t/$OSF" nv_dirty_all_valid "$TMPD/d4.c" && grep -q 'vm_page_all_valid(' "$TMPD/d4.c" || { echo "O2: the validity is not asked with vm_page_all_valid"; return; }
	body "$_t/$OSF" nv_dirty_dirty "$TMPD/d5.c" && grep -q 'vm_page_dirty(' "$TMPD/d5.c" || { echo "O2: the dirty step does not dirty"; return; }
	body "$_t/$OSF" gb10_pi_os_dirty "$TMPD/od.c" || { echo "O2: no gb10_pi_os_dirty"; return; }
	grep -q 'gb10_pi_dirty_page(' "$TMPD/od.c" || { echo "O2: the dirty decision is not the core's (gb10_pi_dirty_page)"; return; }
	grep -q 'atomic_add_long(&gb10_pi_dirty_refused' "$TMPD/od.c" && grep -q 'atomic_add_long(&gb10_pi_dirty_busy_fallback' "$TMPD/od.c" || { echo "O2: a refusal or a busy fallback is not counted"; return; }
	grep -q 'SYSCTL_ULONG(_hw, OID_AUTO, nvidia_unlock_dirty_refused, CTLFLAG_RD' "$_t/$OSF" && grep -q 'SYSCTL_ULONG(_hw, OID_AUTO, nvidia_unlock_dirty_busy_fallback, CTLFLAG_RD' "$_t/$OSF" || { echo "O2: the counters are not read-only sysctls"; return; }
	grep -Eq 'printf\([^;]*%p' "$TMPD/od.c" && { echo "O2: the tripwire prints a kernel pointer"; return; }
	grep -q 'VM_PAGE_TO_PHYS' "$TMPD/od.c" && { echo "O2: the tripwire log line prints a physical address to an unprivileged reader of dmesg"; return; }
	grep -q 'PRIME-IMPORT.md' "$TMPD/od.c" && grep -q 'Track #2228' "$TMPD/od.c" || { echo "O2: the tripwire log line does not say where to report it and what to read"; return; }
	grep -q 'imported = 1' "$TMPD/ip.c" || { echo "D1: the descriptor is not marked imported once the RM has the pages (the second-wiring rule needs it)"; return; }
	grep -q 'ppsratecheck(' "$TMPD/od.c" || { echo "O2: the tripwire log is not rate limited"; return; }
	# NVIDIA's proprietary files carry no logic of ours, only calls into our file
	# only the lines our patch adds count: the file itself is full of NVIDIA's vm_page_ calls
	diff "$PRISTINE/$SUBR" "$_t/$SUBR" | grep '^>' | grep -v 'gb10_pi_os_' | grep -Eq 'vm_page_|nv_pi_|gb10_pi_(import|release|register|unregister|wire|unwire)\(' && { echo "SRC: logic of ours sits in NVIDIA's proprietary nvidia_subr.c"; return; }
	head -20 "$repo/src/gb10-pageimport/gb10_pageimport_os.c" | grep -q 'SPDX-License-Identifier: BSD-3-Clause' || { echo "SRC: the OS file lacks its BSD SPDX line"; return; }
	# O3
	body "$_t/$SUBR" nv_register_sgt "$TMPD/rs.c" || { echo "O3: no nv_register_sgt"; return; }
	grep -q 'gb10_pi_os_register(' "$TMPD/rs.c" || { echo "O3: nv_register_sgt does not register (a stub that lies)"; return; }
	grep -q 'NV_ERR_' "$TMPD/rs.c" && { echo "SRC: nv_register_sgt decides refusals itself instead of calling gb10_pi_os_register"; return; }
	body "$_t/$OSF" gb10_pi_os_register "$TMPD/rg.c" || { echo "O3: no gb10_pi_os_register"; return; }
	grep -q 'gb10_pi_register(' "$TMPD/rg.c" && grep -Eq '\*priv_data[[:space:]]*=[[:space:]]*import_sgt' "$TMPD/rg.c" || { echo "O3: the registration does not go through the core or sets no private data (the RM asserts on it)"; return; }
	grep -q 'nv_pi_status(' "$TMPD/rg.c" || { echo "O3: the registration result is not mapped by the one status function"; return; }
	grep -q 'printf(' "$TMPD/rg.c" "$TMPD/ni.c" && { echo "O3: an unprivileged caller can drive an unlimited log line from the wiring"; return; }
	body "$_t/$OSF" nv_pi_rewire_ok "$TMPD/rw.c" && grep -q 'PG_FICTITIOUS' "$TMPD/rw.c" && grep -q 'vm_page_wired(' "$TMPD/rw.c" || { echo "O3: the second wiring of an imported buffer does not accept a wired page with an object (the exporter's mapping faults pages in)"; return; }
	grep -q 'is_peer_mmio' "$TMPD/rg.c" || { echo "O3: the peer MMIO refusal is gone"; return; }
	body "$_t/$SUBR" nv_unregister_sgt "$TMPD/us.c" || { echo "O3: no nv_unregister_sgt"; return; }
	grep -q 'gb10_pi_os_unregister(' "$TMPD/us.c" || { echo "O3: nv_unregister_sgt does not call gb10_pi_os_unregister"; return; }
	body "$_t/$OSF" gb10_pi_os_unregister "$TMPD/ug.c" || { echo "O3: no gb10_pi_os_unregister"; return; }
	grep -q 'gb10_pi_unregister(' "$TMPD/ug.c" && grep -Eq '\*import_sgt[[:space:]]*=' "$TMPD/ug.c" && grep -Eq '\*import_priv[[:space:]]*=' "$TMPD/ug.c" || { echo "O3: gb10_pi_os_unregister does not unwire and hand back the descriptor and the owner"; return; }
	body "$_t/$SUBR" nv_dma_import_sgt "$TMPD/is.c" || { echo "O3: no nv_dma_import_sgt"; return; }
	grep -q 'gb10_pi_os_import(' "$TMPD/is.c" || { echo "O3: nv_dma_import_sgt does not take the owner"; return; }
	body "$_t/$OSF" gb10_pi_os_import "$TMPD/oi.c" && grep -q 'GB10_PI_CLOSING' "$TMPD/oi.c" && grep -q 'ppsratecheck(&gb10_pi_closing_lasttime' "$TMPD/oi.c" && grep -q 'printf(' "$TMPD/oi.c" || { echo "O3: a refused export (closed gate) is not logged, rate limited on its own"; return; }
	grep -q 'gb10_pi_import(' "$TMPD/oi.c" || { echo "O3: gb10_pi_os_import does not take the owner through the core"; return; }
	body "$_t/$SUBR" nv_dma_release_sgt "$TMPD/rl.c" || { echo "O3: no nv_dma_release_sgt"; return; }
	grep -q 'gb10_pi_os_release(' "$TMPD/rl.c" || { echo "O3: nv_dma_release_sgt does not drop the owner"; return; }
	body "$_t/$OSF" gb10_pi_os_release "$TMPD/or.c" && grep -q 'gb10_pi_release(' "$TMPD/or.c" || { echo "O3: gb10_pi_os_release does not drop the owner through the core"; return; }
	# O4
	grep -Eq '(^|[[:space:]])nv_import_pages([[:space:]\\]|$)' "$_t/$MKF" && grep -Eq '(^|[[:space:]])nv_unimport_pages([[:space:]\\]|$)' "$_t/$MKF" || {
		echo "O4: nvidia.ko does not export nv_import_pages and nv_unimport_pages"; return; }
	grep -Eq '^SRCS\+=[[:space:]]*gb10_pageimport_os\.c' "$_t/$MKF" || { echo "O4: the nvidia/Makefile does not build gb10_pageimport_os.c"; return; }
	for _f in $SUBR $OSC $OSF; do
		grep -q '"gb10_pageimport.h"' "$_t/$_f" || { echo "O4: $_f does not include the core header"; return; }
	done
	grep -q 'gb10_pageimport.h' "$_t/$DMABUF" "$_t/$DMABUFH" || { echo "O4: nvidia-drm does not include the core header"; return; }
	# the exporter reference is held across the failure points: the caller creates the GEM object whatever the import returns
	body "$_t/$DMABUF" nv_drm_gem_prime_import_sg_table "$TMPD/imp2.c" || { echo "D4: no import function"; return; }
	_mid=$(awk '/__nv_drm_gem_dma_buf_import_pages\(/ { on = 1 } /nv_drm_gem_object_init\(/ { on = 0 } on' "$TMPD/imp2.c")
	case $_mid in *return*|*nv_drm_free\(nv_dma_buf\)*|*ERR_PTR*|*goto*) echo "D4: the GEM object is not created after every import result, so the exporter reference taken at import could leak"; return ;; esac
	# the exporter reference is dropped in exactly one place, the free of the GEM object (comments stripped)
	strip_comments "$_t/$DMABUF" "$TMPD/dmabuf-nocomment.c"
	[ "$(grep -c 'gb10_pi_life_drop(' "$TMPD/dmabuf-nocomment.c")" -eq 1 ] || { echo "D4: gb10_pi_life_drop( does not appear exactly once in nvidia-drm-gem-dma-buf.c"; return; }
	body "$_t/$DMABUF" __nv_drm_gem_dma_buf_free "$TMPD/fr2.c" && grep -q 'gb10_pi_life_drop(' "$TMPD/fr2.c" || { echo "D4: the one gb10_pi_life_drop( is not in the free of the GEM object"; return; }
	# D6: an RM file descriptor that holds an export calls back into this module: a gate refuses the unload while one is held
	body "$_t/$DMABUF" __nv_drm_gem_dma_buf_pi_hold "$TMPD/h6.c" && grep -q 'spin_lock(&__nv_drm_pi_gate_lock)' "$TMPD/h6.c" && grep -q 'gb10_pi_gate_hold(&__nv_drm_pi_gate)' "$TMPD/h6.c" || { echo "D6: the hold the RM takes on an export does not go through the closing gate under its lock"; return; }
	before "$TMPD/h6.c" 'gb10_pi_gate_hold(' 'drm_gem_object_get(' || { echo "D6: the GEM reference is taken before the gate agreed"; return; }
	body "$_t/$DMABUF" __nv_drm_gem_dma_buf_pi_release "$TMPD/r6.c" && grep -q 'nv_drm_gem_object_unreference_unlocked(' "$TMPD/r6.c" || { echo "D6: no release"; return; }
	grep -q 'gate_drop\|atomic_\|holds' "$TMPD/r6.c" && { echo "D6: this module counts the hold down itself: the core does it in nvidia.ko after the release has returned"; return; }
	grep -Eq 'pi_desc\.gate[[:space:]]*=[[:space:]]*&__nv_drm_pi_gate;' "$_t/$DMABUF" || { echo "D6: the descriptor does not carry the gate, so the release is never counted down"; return; }
	body "$_t/$DMABUF" nv_drm_pi_quiesce "$TMPD/q6.c" && grep -q 'spin_lock(' "$TMPD/q6.c" && grep -q 'gb10_pi_gate_quiesce(&__nv_drm_pi_gate)' "$TMPD/q6.c" && grep -q 'EBUSY' "$TMPD/q6.c" || { echo "D6: the quiesce is not the gate's, under the lock, answering EBUSY"; return; }
	strip_comments "$TMPD/h6.c" "$TMPD/h6s.c"; strip_comments "$TMPD/q6.c" "$TMPD/q6s.c"
	before "$TMPD/q6s.c" 'spin_lock(' 'gb10_pi_gate_quiesce(' && before "$TMPD/q6s.c" 'gb10_pi_gate_quiesce(' 'spin_unlock(' || { echo "D6: the quiesce does not decide between the lock and the unlock"; return; }
	before "$TMPD/h6s.c" 'spin_lock(' 'gb10_pi_gate_hold(' && before "$TMPD/h6s.c" 'gb10_pi_gate_hold(' 'spin_unlock(' || { echo "D6: the hold does not decide between the lock and the unlock"; return; }
	awk '/if \(rc != 0\) \{/ { on = 1; next } on && /\}/ { exit } on { gsub(/[[:space:]]/, ""); print }' "$TMPD/h6s.c" | tr -d '\n' | grep -qx 'returnrc;' || { echo "D6: a refused hold does more than return (a reference taken for an export that was refused leaks)"; return; }
	body "$_t/$DMABUF" nv_drm_pi_keep "$TMPD/k6.c" && grep -q 'spin_lock(' "$TMPD/k6.c" && grep -q 'gb10_pi_gate_keep(&__nv_drm_pi_gate)' "$TMPD/k6.c" || { echo "D6: no way to mark the devices as kept, so a later unload is not refused for good"; return; }
	grep -q 'nv_drm_pi_live_holds' "$_t/$DMABUFH" && grep -q 'nv_drm_pi_quiesce' "$_t/$DMABUFH" || { echo "D6: the gate functions are not declared for the other files of nvidia-drm"; return; }
	tr '\n' ' ' < "$_t/$LKPI" > "$TMPD/lkpi-flat.c"
	# the unload order: a file's modules unload in the reverse of their load order, so the guard must LOAD after the driver module
	_dm=$(grep -Eo 'DECLARE_MODULE\(nvidia_drm_pi_guard,[^)]*\)' "$TMPD/lkpi-flat.c" | head -1)
	[ -n "$_dm" ] || { echo "D6: there is no second module that can refuse the unload (LKPI_DRIVER_MODULE cannot)"; return; }
	_gsub=$(echo "$_dm" | sed -E 's/.*,[[:space:]]*(SI_SUB_[A-Z_]+)[[:space:]]*,.*/\1/')
	_gord=$(echo "$_dm" | sed -E 's/.*,[[:space:]]*(SI_ORDER_[A-Z_]+)[[:space:]]*\).*/\1/')
	_gsubv=$(kval "$_gsub"); _gordv=$(kval "$_gord")
	[ -n "$_gsubv" ] && [ -n "$_gordv" ] || { echo "D6: the guard's order $_gsub/$_gord is not a value of sys/kernel.h"; return; }
	grep -q 'LKPI_DRIVER_MODULE(nvidia_drm,' "$_t/$LKPI" || { echo "D6: the driver module is no longer LKPI_DRIVER_MODULE(nvidia_drm, ...)"; return; }
	# LKPI_DRIVER_MODULE registers at SI_SUB_DRIVERS, SI_ORDER_ANY
	_dsub=$(kval SI_SUB_DRIVERS); _dord=$(kval SI_ORDER_ANY)
	_r=$("$TMPD/ordermodel" "$_gsubv" "$_gordv" "$_dsub" "$_dord" 1 1)
	[ "$_r" = "rc=16 teardown=0" ] || { echo "D6: kldunload -f with an export held runs the driver teardown before the guard can refuse ($_r): the guard must load AFTER the driver module (unload order is the reverse of load order)"; return; }
	_r=$("$TMPD/ordermodel" "$_gsubv" "$_gordv" "$_dsub" "$_dord" 1 0)
	[ "$_r" = "rc=16 teardown=0" ] || { echo "D6: a plain kldunload with an export held runs the driver teardown ($_r)"; return; }
	_r=$("$TMPD/ordermodel" "$_gsubv" "$_gordv" "$_dsub" "$_dord" 0 1)
	[ "$_r" = "rc=0 teardown=1" ] || { echo "D6: an unload with no export held does not run the teardown ($_r)"; return; }
	body "$_t/$LKPI" nv_drm_pi_guard_handler "$TMPD/g6.c" || { echo "D6: no guard handler"; return; }
	tr '\n' ' ' < "$TMPD/g6.c" | grep -Eq 'case MOD_QUIESCE:[[:space:]]*if \(nv_drm_pi_quiesce\(\) != 0\) \{.*return EBUSY;[[:space:]]*\}[[:space:]]*return 0;[[:space:]]*case MOD_UNLOAD:.*if \(nv_drm_pi_quiesce\(\) != 0\) \{.*return EBUSY;' || { echo "D6: MOD_QUIESCE does not take the gate and MOD_UNLOAD does not refuse while an export is held"; return; }
	grep -q 'printf("nvidia_drm: unload refused' "$TMPD/g6.c" || { echo "D6: a refused unload is silent"; return; }
	# the real teardown path on FreeBSD: nv_bsd_drm_exit -> nv_drm_exit -> nv_drm_remove_devices
	body "$_t/$DRV" nv_drm_remove_devices "$TMPD/rm6.c" || { echo "D6: no nv_drm_remove_devices"; return; }
	awk '/nv_drm_pi_live_holds\(\) > 0\) \{/ { on = 1 } on { print } on && /^    \}/ { exit }' "$TMPD/rm6.c" > "$TMPD/rm6b.c"
	grep -Eq '^[[:space:]]+return;' "$TMPD/rm6b.c" || { echo "D6: nv_drm_remove_devices destroys the devices while an export is still open"; return; }
	strip_comments "$TMPD/rm6.c" "$TMPD/rm6s.c"
	[ "$(awk '/struct nv_drm_device \*nv_dev;/ { on = 1; next } on && NF { print; exit }' "$TMPD/rm6s.c" | sed -E 's/^[[:space:]]+//')" = 'if (nv_drm_pi_live_holds() > 0) {' ] || { echo "D6: the first statement of nv_drm_remove_devices is not the plain test of the live holds (a disabled form such as if (0) is refused)"; return; }
	grep -q 'nv_drm_pi_keep();' "$TMPD/rm6b.c" || { echo "D6: nv_drm_remove_devices does not mark the devices as kept"; return; }
	before "$TMPD/rm6.c" 'nv_drm_pi_live_holds() > 0' 'nv_drm_pop_device()' || { echo "D6: nv_drm_remove_devices pops devices before it asks about the exports"; return; }
	body "$_t/$LKPI" nv_bsd_drm_exit "$TMPD/ex6.c" || { echo "D6: no nv_bsd_drm_exit"; return; }
	before "$TMPD/ex6.c" 'nv_drm_exit()' 'nv_drm_pi_live_holds() > 0' || { echo "D6: nv_bsd_drm_exit does not ask about the exports after the common teardown"; return; }
	strip_comments "$TMPD/ex6.c" "$TMPD/ex6s.c"
	[ "$(awk '/nv_drm_exit\(\);/ { on = 1; next } on && NF { print; exit }' "$TMPD/ex6s.c" | sed -E 's/^[[:space:]]+//')" = 'if (nv_drm_pi_live_holds() > 0) {' ] || { echo "D6: the statement after nv_drm_exit() in nv_bsd_drm_exit is not the plain test of the live holds"; return; }
	awk '/nv_drm_pi_live_holds\(\) > 0\) \{/ { on = 1 } on { print } on && /^    \}/ { exit }' "$TMPD/ex6.c" | grep -q 'nv_drm_pi_keep();' || { echo "D6: nv_bsd_drm_exit does not mark the devices as kept"; return; }
	before "$TMPD/ex6.c" 'nv_drm_pi_live_holds() > 0' 'linux_pci_detach_device(' || { echo "D6: nv_bsd_drm_exit frees the pdevs the attachment uses without asking about the exports"; return; }
	awk '/nv_drm_pi_live_holds\(\) > 0\) \{/ { on = 1 } on { print } on && /^    \}/ { exit }' "$TMPD/ex6.c" | grep -Eq '^[[:space:]]+return;' || { echo "D6: nv_bsd_drm_exit frees the pdevs even with an export open"; return; }
}

# O5, a property of the script and not of a source file.
# R2: the ownership rule the KAPI relies on, in the pristine RM source.
check_rm_rule() {
	grep -Eq 'bUseParamsDirectly[[:space:]]*=[[:space:]]*\(pParamCopy->paramsSize == 0\) \|\| \(!bUserModeArgs\)' \
	    "$OGKMSRC/src/nvidia/src/kernel/rmapi/param_copy.c" || {
		echo "R2: rmapiParamsAcquire() no longer uses a kernel caller's parameters in place"; return; }
	grep -Eq 'bCopyInParams[[:space:]]*=[[:space:]]*pSecInfo->paramLocation == PARAM_LOCATION_USER' \
	    "$OGKMSRC/src/nvidia/src/kernel/rmapi/alloc_free.c" || {
		echo "R2: serverAllocApiCopyIn() copies a kernel caller's parameters"; return; }
}

check_script() {
	grep -q 'gb10_pageimport.h' "$repo/scripts/prepare-tree.sh" || {
		echo "O5: scripts/prepare-tree.sh does not install gb10_pageimport.h"; return; }
	grep -Eq 'common/inc/gb10_pageimport\.h' "$repo/scripts/prepare-tree.sh" || {
		echo "O5: the core header is not installed into common/inc, which both modules include"; return; }
}

# --- the patched sources must pass ---------------------------------------
mkdir -p "$TMPD/good" "$TMPD/pristine"
if r=$(make_tree "$TMPD/good" 1) && [ -z "$r" ]; then
	r=$(check_tree "$TMPD/good")
	[ -z "$r" ] && ok "the patched sources pass every check" || bad "patched sources: $r"
else
	bad "the patches do not apply: $r"
fi
r=$(check_script)
[ -z "$r" ] && ok "prepare-tree.sh installs the core header" || bad "$r"
r=$(check_rm_rule)
[ -z "$r" ] && ok "the RM uses a kernel caller's allocation parameters in place (what pPagesTaken relies on)" || bad "$r"

# --- the control: the pristine sources must be flagged -------------------
make_tree "$TMPD/pristine" 0
r=$(check_tree "$TMPD/pristine")
[ -n "$r" ] && ok "control: the pristine sources are flagged ($r)" \
    || bad "control: the pristine sources passed - the checks cannot see the defect"

# --- mutants: each must be flagged ---------------------------------------
# mutant <name> <file under the tree> <sed script>
mutant() {
	_m="$TMPD/m-$1"
	rm -rf "$_m"
	cp -R "$TMPD/good" "$_m" || { bad "control $1: cannot copy the tree"; return; }
	sed -e "$3" "$TMPD/good/$2" > "$_m/$2"
	if cmp -s "$TMPD/good/$2" "$_m/$2"; then
		bad "control $1: the mutation changed nothing (stale test)"
		return
	fi
	r=$(check_tree "$_m")
	[ -n "$r" ] && ok "control: mutant $1 is flagged ($r)" || bad "control: mutant $1 passed"
}

if [ -z "$(check_tree "$TMPD/good")" ]; then
	mutant no-kernel-page-array ogkm/$OSMEM 's/NVOS32_DESCRIPTOR_TYPE_OS_PAGE_ARRAY/NVOS32_DESCRIPTOR_TYPE_OS_PHYS_ADDR/'
	mutant write-combine ogkm/$KAPIC '/GetSystemMemoryHandleFromPageArray/,/^}/s/_WRITE_BACK/_WRITE_COMBINE/'
	mutant no-ownership-check ogkm/$KAPIC '/GetSystemMemoryHandleFromPageArray/,/^}/s/descriptor == NvP64_NULL/descriptor != NvP64_NULL/'
	mutant no-give-back $DMABUF 's/nv_unimport_pages(/nv_unimport_pagesX(/'
	mutant wire-before-check $DMABUF 's/gb10_pi_fill(/gb10_pi_fillX(/'
	mutant no-rm-free $DMABUF 's/nvKms->freeMemory(/nvKms->freeMemoryX(/'
	mutant export-from-sgt $DMABUF 's/&nv_dma_buf->pi_desc/nv_dma_buf->sgt/'
	mutant unwire-queue $OSF 's/PQ_ACTIVE/PQ_INACTIVE/'
	mutant register-stub $OSF 's/gb10_pi_register(/gb10_pi_registerX(/'
	mutant no-release $SUBR 's/gb10_pi_os_release(/gb10_pi_os_releaseX(/'
	mutant no-fictitious-check $OSF 's/PG_FICTITIOUS/0/'
	mutant no-modeset-guard $DMABUF 's/getSystemMemoryHandleFromPageArray == NULL/getSystemMemoryHandleFromPageArray != NULL/'
	mutant no-object-check $OSF 's/m->object != NULL))/0))/'
	mutant kapi-limit-size $DMABUF 's/array, size - 1,/array, size,/'
	mutant export-direct-handle $DMABUF 's/if (!nv_dma_buf->base.pMemory || nv_dma_buf->pages != NULL)/if (!nv_dma_buf->base.pMemory)/'
	mutant export-prefers-page-array $DMABUF 's/pTmpMemory ?/nv_dma_buf->base.pMemory ?/'
	mutant no-life-take $DMABUF 's/gb10_pi_life_take(/gb10_pi_life_takeX(/'
	mutant life-dropped-first $DMABUF 's/gb10_pi_life_drop(&nv_dma_buf->life);/;/;s/nvKms->freeMemory(nv_dev->pDevice, nv_dma_buf->base.pMemory);/gb10_pi_life_drop(\&nv_dma_buf->life); nvKms->freeMemory(nv_dev->pDevice, nv_dma_buf->base.pMemory);/'
	mutant unload-no-gate-in-hold $DMABUF 's/rc = gb10_pi_gate_hold(&__nv_drm_pi_gate);/rc = 0;/'
	mutant unload-hold-without-lock $DMABUF '/^static int __nv_drm_gem_dma_buf_pi_hold/,/^}/s/spin_lock(&__nv_drm_pi_gate_lock);//'
	mutant unload-unload-does-not-close $LKPI '/^    case MOD_UNLOAD:/,/^    default:/s/if (nv_drm_pi_quiesce() != 0) {/if (nv_drm_pi_live_holds() > 0) {/'
	mutant unload-module-counts-down $DMABUF '/^static void __nv_drm_gem_dma_buf_pi_release/,/^}/s/nv_drm_gem_object_unreference_unlocked(nv_gem);/nv_drm_gem_object_unreference_unlocked(nv_gem); gb10_pi_gate_drop(\&__nv_drm_pi_gate);/'
	mutant unload-no-gate-on-desc $DMABUF 's/nv_dma_buf->pi_desc.gate = &__nv_drm_pi_gate;//'
	mutant unload-quiesce-ignores-gate $DMABUF 's/rc = gb10_pi_gate_quiesce(&__nv_drm_pi_gate);/rc = 0;/'
	mutant unload-quiesce-ok $LKPI 's/if (nv_drm_pi_quiesce() != 0) {/if (0) {/'
	mutant unload-only-on-unload $LKPI 's/    case MOD_QUIESCE:/    case MOD_QUIESCE + 1000:/'
	mutant unload-unload-ok $LKPI '/^    case MOD_UNLOAD:/,/^    default:/s/return EBUSY;/return 0;/'
	mutant closing-export-silent $OSF '/^gb10_pi_os_import/,/^}/s/printf("nvidia: cross-GPU export refused/(void)("nvidia: cross-GPU export refused/'
	mutant unload-guard-silent $LKPI 's/printf("nvidia_drm: unload refused/(void)("nvidia_drm: unload refused/'
	mutant unload-no-guard-module $LKPI 's/DECLARE_MODULE(nvidia_drm_pi_guard,/DECLARE_MODULE(nvidia_drm_pi_guardX,/'
	mutant unload-guard-loads-first $LKPI 's/SI_ORDER_LAST);/SI_ORDER_FIRST);/'
	mutant unload-guard-same-order $LKPI 's/SI_ORDER_LAST);/SI_ORDER_ANY);/'
	mutant unload-guard-before-sub $LKPI 's/SI_SUB_DRIVERS, SI_ORDER_LAST);/SI_SUB_KLD, SI_ORDER_LAST);/'
	mutant quiesce-outside-lock $DMABUF '/^int nv_drm_pi_quiesce/,/^}/{s/    spin_lock(&__nv_drm_pi_gate_lock);//;s/    rc = gb10_pi_gate_quiesce(&__nv_drm_pi_gate);/    rc = gb10_pi_gate_quiesce(\&__nv_drm_pi_gate);\n    spin_lock(\&__nv_drm_pi_gate_lock);/;}'
	mutant refused-hold-takes-a-reference $DMABUF 's/^        return rc;/        drm_gem_object_get(\&nv_gem->base); return rc;/'
	mutant remove-devices-disabled $DRV '/^void nv_drm_remove_devices/,/^}/s/^    if (nv_drm_pi_live_holds() > 0) {/    if (0 \&\& nv_drm_pi_live_holds() > 0) {/'
	mutant exit-disabled $LKPI '/^static void nv_bsd_drm_exit/,/^}/s/^    if (nv_drm_pi_live_holds() > 0) {/    if (0 \&\& nv_drm_pi_live_holds() > 0) {/'
	mutant remove-devices-not-kept $DRV 's/^        nv_drm_pi_keep();//'
	mutant exit-not-kept $LKPI 's/^        nv_drm_pi_keep();//'
	mutant keep-sets-nothing $DMABUF '/^void nv_drm_pi_keep/,/^}/s/gb10_pi_gate_keep(&__nv_drm_pi_gate);//'
	mutant remove-devices-ignores-holds $DRV '/^void nv_drm_remove_devices/,/^}/s/if (nv_drm_pi_live_holds() > 0) {/if (0) {/'
	mutant remove-devices-falls-through $DRV '/nv_drm_pi_live_holds() > 0) {/,/^    }/s/^        return;/        ;/'
	mutant exit-frees-pdevs $LKPI '/^static void nv_bsd_drm_exit/,/^}/s/if (nv_drm_pi_live_holds() > 0) {/if (0) {/'
	mutant life-dropped-twice $DMABUF 's/    nv_drm_free(nv_dma_buf->pages);/    gb10_pi_life_drop(\&nv_dma_buf->life); nv_drm_free(nv_dma_buf->pages);/'
	mutant spin-budget-static $OSC 's/    int dirty_spin = GB10_PI_DIRTY_SPIN_BUDGET;/    static int dirty_spin = GB10_PI_DIRTY_SPIN_BUDGET;/'
	mutant spin-budget-per-page $OSC 's/gb10_pi_os_dirty(user_pages\[i\], \&dirty_spin)/gb10_pi_os_dirty(user_pages[i], NULL)/'
	mutant dirty-in-nvidia-file $OSC 's/gb10_pi_os_dirty(user_pages\[i\], &dirty_spin);/vm_page_dirty(user_pages[i]);/'
	mutant busy-try-always-ok $OSF '/^nv_busy_try/,/^}/s/return (vm_page_tryxbusy((vm_page_t)page) != 0 ? 0 : -1);/return (0);/'
	mutant busy-never-released $OSF '/^nv_busy_release/,/^}/s/vm_page_xunbusy((vm_page_t)page);/(void)page;/'
	mutant dirty-never-waits $OSF '/^nv_dirty_delay/,/^}/s/DELAY(GB10_PI_DIRTY_SPIN_US);/pause("x", 1);/'
	mutant dirty-prints-address $OSF 's/not marked dirty.  Expected "/not marked dirty (VM_PAGE_TO_PHYS).  Expected "/'
	mutant dirty-not-core $OSF 's/gb10_pi_dirty_page(/gb10_pi_dirty_pageX(/'
	mutant no-refuse-count $OSF 's/atomic_add_long(&gb10_pi_dirty_refused, 1);//'
	mutant no-fallback-count $OSF 's/atomic_add_long(&gb10_pi_dirty_busy_fallback, 1);//'
	mutant logic-in-nvidia-file $SUBR 's/return gb10_pi_os_register(import_sgt, page_count, phys_addr, priv_data,/if (is_peer_mmio) return NV_ERR_NOT_SUPPORTED; return gb10_pi_os_register(import_sgt, page_count, phys_addr, priv_data,/'
	mutant busy-reported-as-oom $OSF '/^nv_pi_status/,/^}/s/return (NV_ERR_BUSY_RETRY);/return (NV_ERR_INSUFFICIENT_RESOURCES);/'
	mutant changed-reported-as-retry $OSF '/^nv_pi_status/,/^}/s/return (NV_ERR_NOT_SUPPORTED);/return (NV_ERR_BUSY_RETRY);/'
	mutant rewire-refuses-objects $OSF '/^nv_pi_rewire_ok/,/^}/s/ && vm_page_wired(m)/ \&\& m->object == NULL/'
	mutant wiring-logs-unlimited $OSF '/^gb10_pi_os_register/,/^}/s/return (nv_pi_status(rc));/{ printf("x"); return (nv_pi_status(rc)); }/'
	mutant no-srcs $MKF 's/gb10_pageimport_os.c/gb10_pageimport_osX.c/'
	mutant drm-own-check $DMABUF 's/gb10_pi_page_claimable(/gb10_pi_page_claimableX(/'
	mutant no-export $MKF 's/nv_unimport_pages/nv_unimport_pagesX/'
fi

echo "passed: $passed failed: $failed"
[ "$failed" -eq 0 ]
