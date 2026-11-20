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
#       that has none;
#  OS layer (patches/patch-nvidia_*)
#   O1  nv_import_pages() allocates with os_alloc_mem(), wires through the
#       core, and frees the array when the wiring fails; nv_unimport_pages()
#       unwires and frees;
#   O2  the unwire the OS layer does is the one the RM's teardown does
#       (vm_page_unwire(..., PQ_ACTIVE), as os_unlock_user_pages()), the
#       wire is vm_page_wire(), and a page counts as RAM only when
#       vm_phys_paddr_to_vm_page() finds it and it is not fictitious;
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

passed=0
failed=0
ok() { echo "PASS: $1"; passed=$((passed + 1)); }
bad() { echo "FAIL: $1"; failed=$((failed + 1)); }

DMABUF=nvidia-drm/nvidia-drm-gem-dma-buf.c
DMABUFH=nvidia-drm/nvidia-drm-gem-dma-buf.h
SUBR=nvidia/nvidia_subr.c
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
	for _f in $DMABUF $DMABUFH $SUBR $OSC $MKF; do cp "$PRISTINE/$_f" "$_d/$_f" || return 1; done
	for _f in $OSMEM $KAPIC; do cp "$OGKMSRC/$_f" "$_d/ogkm/$_f" || return 1; done
	[ "$2" -eq 1 ] || return 0
	for _p in patch-nvidia-drm_nvidia-drm-gem-dma-buf.c patch-nvidia-drm_nvidia-drm-gem-dma-buf.h \
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
	# D2
	body "$_t/$DMABUF" __nv_drm_gem_dma_buf_free "$TMPD/fr.c" || { echo "D2: no free function"; return; }
	before "$TMPD/fr.c" 'nvKms->freeMemory(' 'drm_prime_gem_destroy(' || { echo "D2: the GEM object is destroyed before the RM handle is freed"; return; }
	before "$TMPD/fr.c" 'drm_prime_gem_destroy(' 'nv_drm_free(nv_dma_buf->pages)' || { echo "D2: the retained page array is not freed after the GEM object"; return; }
	# D3
	body "$_t/$DMABUF" nv_drm_gem_export_dmabuf_memory_ioctl "$TMPD/ex.c" || { echo "D3: no export ioctl"; return; }
	grep -Fq '&nv_dma_buf->pi_desc' "$TMPD/ex.c" || { echo "D3: the export is not served from the retained descriptor"; return; }
	grep -Fq 'nv_dma_buf->sgt' "$TMPD/ex.c" && { echo "D3: the export hands the OS layer a Linux sg_table"; return; }
	before "$TMPD/ex.c" 'nv_dma_buf->pages[[:space:]]*==[[:space:]]*NULL' 'getSystemMemoryHandleFromSgt(' || {
		echo "D3: a buffer without a retained descriptor is not refused"; return; }
	# O1
	body "$_t/$SUBR" nv_import_pages "$TMPD/ni.c" || { echo "O1: no nv_import_pages"; return; }
	before "$TMPD/ni.c" 'os_alloc_mem(' 'gb10_pi_wire(' || { echo "O1: the array is not allocated with os_alloc_mem before the wiring"; return; }
	before "$TMPD/ni.c" 'gb10_pi_wire(' 'os_free_mem(' || { echo "O1: a failed wiring does not free the array"; return; }
	body "$_t/$SUBR" nv_unimport_pages "$TMPD/nu.c" || { echo "O1: no nv_unimport_pages"; return; }
	before "$TMPD/nu.c" 'gb10_pi_unwire(' 'os_free_mem(' || { echo "O1: nv_unimport_pages does not unwire and free"; return; }
	# O2
	grep -Eq 'vm_page_unwire\(.*,[[:space:]]*PQ_ACTIVE\)' "$_t/$SUBR" || { echo "O2: the unwire is not vm_page_unwire(..., PQ_ACTIVE)"; return; }
	grep -Eq 'vm_page_unwire\(.*,[[:space:]]*PQ_ACTIVE\)' "$_t/$OSC" || { echo "O2: the RM's own unwire changed; revisit the parity"; return; }
	grep -Eq 'vm_page_wire\(' "$_t/$SUBR" || { echo "O2: the wire is not vm_page_wire()"; return; }
	body "$_t/$SUBR" nv_pi_page_at "$TMPD/pa.c" || { echo "O2: no nv_pi_page_at"; return; }
	grep -q 'vm_phys_paddr_to_vm_page(' "$TMPD/pa.c" && grep -q 'PG_FICTITIOUS' "$TMPD/pa.c" || {
		echo "O2: a page is not checked to be managed RAM"; return; }
	grep -q 'object[[:space:]]*!=[[:space:]]*NULL' "$TMPD/pa.c" || {
		echo "O2: a page that belongs to a VM object is not refused in the OS layer"; return; }
	grep -q 'object[[:space:]]*!=[[:space:]]*NULL' "$TMPD/dp.c" || {
		echo "O2: a page that belongs to a VM object is not refused in nvidia-drm"; return; }
	# O3
	body "$_t/$SUBR" nv_register_sgt "$TMPD/rs.c" || { echo "O3: no nv_register_sgt"; return; }
	grep -q 'gb10_pi_register(' "$TMPD/rs.c" || { echo "O3: nv_register_sgt does not register (a stub that lies)"; return; }
	grep -Eq '\*priv_data[[:space:]]*=' "$TMPD/rs.c" || { echo "O3: nv_register_sgt sets no private data (the RM asserts on it)"; return; }
	body "$_t/$SUBR" nv_unregister_sgt "$TMPD/us.c" || { echo "O3: no nv_unregister_sgt"; return; }
	grep -q 'gb10_pi_unregister(' "$TMPD/us.c" && grep -Eq '\*import_sgt[[:space:]]*=' "$TMPD/us.c" \
	    && grep -Eq '\*import_priv[[:space:]]*=' "$TMPD/us.c" || { echo "O3: nv_unregister_sgt does not unwire and hand back the descriptor and the owner"; return; }
	body "$_t/$SUBR" nv_dma_import_sgt "$TMPD/is.c" || { echo "O3: no nv_dma_import_sgt"; return; }
	grep -q 'gb10_pi_import(' "$TMPD/is.c" || { echo "O3: nv_dma_import_sgt does not take the owner"; return; }
	body "$_t/$SUBR" nv_dma_release_sgt "$TMPD/rl.c" || { echo "O3: no nv_dma_release_sgt"; return; }
	grep -q 'gb10_pi_release(' "$TMPD/rl.c" || { echo "O3: nv_dma_release_sgt does not drop the owner"; return; }
	# O4
	grep -Eq '(^|[[:space:]])nv_import_pages([[:space:]\\]|$)' "$_t/$MKF" && grep -Eq '(^|[[:space:]])nv_unimport_pages([[:space:]\\]|$)' "$_t/$MKF" || {
		echo "O4: nvidia.ko does not export nv_import_pages and nv_unimport_pages"; return; }
	grep -q '"gb10_pageimport.h"' "$_t/$SUBR" || { echo "O4: nvidia_subr.c does not include the core header"; return; }
	grep -q 'gb10_pageimport.h' "$_t/$DMABUF" "$_t/$DMABUFH" || { echo "O4: nvidia-drm does not include the core header"; return; }
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
	mutant unwire-queue $SUBR 's/PQ_ACTIVE/PQ_INACTIVE/'
	mutant register-stub $SUBR 's/gb10_pi_register(/gb10_pi_registerX(/'
	mutant no-release $SUBR 's/gb10_pi_release(/gb10_pi_releaseX(/'
	mutant no-fictitious-check $SUBR 's/PG_FICTITIOUS/0/'
	mutant no-modeset-guard $DMABUF 's/getSystemMemoryHandleFromPageArray == NULL/getSystemMemoryHandleFromPageArray != NULL/'
	mutant no-object-check $SUBR 's/p->object != NULL/0/'
	mutant no-export $MKF 's/nv_unimport_pages/nv_unimport_pagesX/'
fi

echo "passed: $passed failed: $failed"
[ "$failed" -eq 0 ]
