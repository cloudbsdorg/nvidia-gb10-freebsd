#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# drm_fault_index_test.sh - the FreeBSD build of nvidia-drm's GEM fault
# handlers must map each page of a buffer to its own page and must not panic
# on a bad index (#2101).
#
# linuxkpi's pager passes vmf->pgoff = 0 and the page index in vmf->address
# (vma->vm_start = 0), and its vmf_insert_pfn() uses the pfn as given.
# NVIDIA's handlers derive the index from vmf->pgoff and add it to the
# video-memory pfn only on Linux: on FreeBSD every page of a buffer mapped
# the first page (amp001, 2026-11-18, DTrace), and the BUG_ON on the wrapped
# index panicked. What the compiler sees on FreeBSD is the source with
# NV_LINUX undefined, so unifdef(1) -UNV_LINUX gives exactly that code; each
# handler's FreeBSD body must then:
#   (a) compute the index from the fault address:
#       page_offset = (address - vma->vm_start) >> PAGE_SHIFT
#   (b) not read vmf->pgoff for it;
#   (c) have no BUG_ON on page_offset (a user-reachable panic);
#   (d) for the nvkms handler, add page_offset to the video-memory pfn;
#   (e) the nvkms mmap must set the video-memory mapping write-combining.
#
# The checks run against NVIDIA's pristine source (they MUST fail there: the
# test proves it can see the defect) and against the prepared tree (they
# must pass).
#
# Usage: sh tests/drm_fault_index_test.sh [TREE]
#   TREE defaults to ${GB10_WORK:-$HOME/work/gb10}/build/tree; the pristine
#   source is ${GB10_WORK}/sources/NVIDIA-FreeBSD-x86_64-<version>/src.
# Exit: 0 every case passes, 1 otherwise.

set -u
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repo/scripts/lib.sh"
WORK=${GB10_WORK:-$HOME/work/gb10}
TREE=${1:-$WORK/build/tree}
ver=$(sources_get "$repo/SOURCES" ogkm_tag) || { echo "FAIL: no ogkm_tag in SOURCES"; exit 1; }
PRISTINE=$WORK/sources/NVIDIA-FreeBSD-x86_64-$ver/src

TMPD=$(mktemp -d "$WORK/tmp/drm-fault-test.XXXXXXXX") || exit 1
trap 'rm -rf -- "$TMPD"' EXIT INT TERM

passed=0
failed=0
ok() { echo "PASS: $1"; passed=$((passed + 1)); }
bad() { echo "FAIL: $1"; failed=$((failed + 1)); }

# body <file> <function> <out>: the FreeBSD (NV_LINUX undefined) text of one
# function, from its name line to the first line that is just "}". A
# forward declaration of the function (its name line followed by a line
# ending in ";" before any "{") is skipped, so the definition is extracted
# even when a prototype precedes it (__nv_drm_gem_nvkms_map has one).
body() {
	unifdef -UNV_LINUX -o "$TMPD/unifdef.c" "$1"
	# unifdef exits 1 when it changed something, 0 when not, 2 on error.
	[ $? -le 1 ] || return 1
	awk -v f="$2" '
		!on && (index($0, f "(") == 1 || ($1 == "static" && index($0, " " f "(") > 0)) { on = 1; n = 0 }
		on { buf[n++] = $0 }
		on && !def && /;[[:space:]]*$/ { on = 0; n = 0; next }
		on && !def && /\{[[:space:]]*$/ { def = 1 }
		def && /^}$/ { for (i = 0; i < n; i++) print buf[i]; exit }
	' "$TMPD/unifdef.c" > "$3"
	[ -s "$3" ]
}

# check <file> <function> <needs-pfn-add>: print the first defect, or nothing.
check() {
	body "$1" "$2" "$TMPD/fn.c" || { echo "cannot extract $2 from $1"; return; }
	grep -Fq 'page_offset = (address - vma->vm_start) >> PAGE_SHIFT' "$TMPD/fn.c" \
	    || { echo "$2: index not computed from the fault address"; return; }
	if grep -Eq 'page_offset[[:space:]]*=.*vmf->pgoff' "$TMPD/fn.c"; then
		echo "$2: index still taken from vmf->pgoff"
		return
	fi
	if grep -Eq 'BUG_ON\([^)]*page_offset' "$TMPD/fn.c"; then
		echo "$2: BUG_ON on page_offset (user-reachable panic)"
		return
	fi
	if [ "$3" = yes ] && ! grep -Eq 'pfn[[:space:]]*\+=[[:space:]]*page_offset' "$TMPD/fn.c"; then
		echo "$2: video-memory pfn does not add page_offset"
		return
	fi
}

NVKMS=nvidia-drm/nvidia-drm-gem-nvkms-memory.c
USERM=nvidia-drm/nvidia-drm-gem-user-memory.c

for f in "$PRISTINE/$NVKMS" "$PRISTINE/$USERM" "$TREE/$NVKMS" "$TREE/$USERM"; do
	[ -f "$f" ] || { echo "FAIL: missing $f (run scripts/fetch-sources.sh and scripts/prepare-tree.sh)"; exit 1; }
done

# Red controls: NVIDIA's pristine source has the defect; the check must see it.
r=$(check "$PRISTINE/$NVKMS" __nv_drm_gem_nvkms_handle_vma_fault yes)
case $r in *cannot\ extract*) bad "control: extractor broken: $r"; r=extractor-broken ;; esac
[ -n "$r" ] && ok "control: pristine nvkms handler is flagged ($r)" \
    || bad "control: pristine nvkms handler passed - the check cannot see the defect"
r=$(check "$PRISTINE/$USERM" __nv_drm_gem_user_memory_handle_vma_fault no)
case $r in *cannot\ extract*) bad "control: extractor broken: $r"; r=extractor-broken ;; esac
[ -n "$r" ] && ok "control: pristine user-memory handler is flagged ($r)" \
    || bad "control: pristine user-memory handler passed - the check cannot see the defect"

# The prepared tree (patches applied) must be clean.
r=$(check "$TREE/$NVKMS" __nv_drm_gem_nvkms_handle_vma_fault yes)
[ -z "$r" ] && ok "nvkms handler: index from the address, added to the pfn, no BUG_ON" \
    || bad "nvkms handler: $r"
r=$(check "$TREE/$USERM" __nv_drm_gem_user_memory_handle_vma_fault no)
[ -z "$r" ] && ok "user-memory handler: index from the address, no BUG_ON" \
    || bad "user-memory handler: $r"

# (e) the video-memory mmap must ask for write-combining on FreeBSD: a
# write-back attribute on a BAR is cached on arm64 (no MTRRs), so writes
# never reach video memory (amp001, 2026-11-18).
wc_check() {
	body "$1" __nv_drm_gem_nvkms_mmap "$TMPD/mmap.c" || { echo "cannot extract __nv_drm_gem_nvkms_mmap"; return; }
	grep -Eq 'vm_page_prot[[:space:]]*=[[:space:]]*pgprot_writecombine' "$TMPD/mmap.c" \
	    || echo "__nv_drm_gem_nvkms_mmap: video-memory mapping not write-combining"
}
r=$(wc_check "$PRISTINE/$NVKMS")
case $r in *cannot\ extract*) bad "control: extractor broken: $r"; r=extractor-broken ;; esac
[ -n "$r" ] && ok "control: pristine mmap is flagged ($r)" \
    || bad "control: pristine mmap passed - the check cannot see the defect"
r=$(wc_check "$TREE/$NVKMS")
[ -z "$r" ] && ok "nvkms mmap: video memory mapped write-combining" || bad "nvkms mmap: $r"

# (f) the video memory a user maps must have vm_pages: linuxkpi's
# vmf_insert_pfn() looks the pfn up with PHYS_TO_VM_PAGE() and returns
# VM_FAULT_SIGBUS when there is none, which the VM turns into a zero-filled
# RAM page in the mapping (amp001, 2026-11-19, DTrace: every insert returned
# 2, every fault was satisfied with RAM; the monitor stayed black). A PCIe
# BAR has vm_pages only while a fictitious range is registered for it. The
# FreeBSD text must therefore:
#   (f1) register the mapped window when the object is physically mapped
#        (__nv_drm_gem_nvkms_map calls a helper that calls
#        vm_phys_fictitious_reg_range);
#   (f2) unregister it in __nv_drm_gem_nvkms_memory_free BEFORE the
#        nvKms->unmapMemory() call, through a helper that calls
#        vm_phys_fictitious_unreg_range;
#   (f3) never unregister pages another object still has in a VM object
#        (the helper checks m->object before unregistering);
#   (f4) probe the window for PG_FICTITIOUS pages BEFORE calling
#        vm_phys_fictitious_reg_range: the kernel does not report an
#        overlap (its tree comparator panics on one; on amd64 a window
#        inside vm_page_array is re-initialised in place), so the probe
#        is the only overlap check there is (review finding, 2026-11-19).
pages_check() {
	body "$1" __nv_drm_gem_nvkms_map "$TMPD/map.c" || { echo "cannot extract __nv_drm_gem_nvkms_map"; return; }
	body "$1" __nv_drm_gem_nvkms_memory_free "$TMPD/free.c" || { echo "cannot extract __nv_drm_gem_nvkms_memory_free"; return; }
	grep -Eq '__nv_drm_gem_nvkms_bsd_pages_register\(' "$TMPD/map.c" \
	    || { echo "__nv_drm_gem_nvkms_map: does not register vm_pages for the mapped video memory"; return; }
	body "$1" __nv_drm_gem_nvkms_bsd_pages_register "$TMPD/reg.c" || { echo "no __nv_drm_gem_nvkms_bsd_pages_register"; return; }
	grep -Eq 'vm_phys_fictitious_reg_range\(' "$TMPD/reg.c" \
	    || { echo "__nv_drm_gem_nvkms_bsd_pages_register: no vm_phys_fictitious_reg_range call"; return; }
	# (f4) the PG_FICTITIOUS probe comes before the registration, and it
	# also compares the page's physical address: an amd64 vm_page_array
	# entry for a hole is never initialised, so a flag bit alone is garbage
	probe=$(grep -n 'PG_FICTITIOUS' "$TMPD/reg.c" | head -1 | cut -d: -f1)
	regl=$(grep -n 'vm_phys_fictitious_reg_range(' "$TMPD/reg.c" | head -1 | cut -d: -f1)
	[ -n "$probe" ] && [ "$probe" -lt "$regl" ] \
	    || { echo "__nv_drm_gem_nvkms_bsd_pages_register: no PG_FICTITIOUS probe before registering (overlap would panic)"; return; }
	grep -Eq 'VM_PAGE_TO_PHYS\(m\) == pa' "$TMPD/reg.c" \
	    || { echo "__nv_drm_gem_nvkms_bsd_pages_register: probe does not compare the page's physical address (uninitialised amd64 array entries)"; return; }
	if grep -q 'EEXIST' "$TMPD/reg.c"; then
		echo "__nv_drm_gem_nvkms_bsd_pages_register: handles EEXIST, which vm_phys_fictitious_reg_range never returns"
		return
	fi
	# (f2) the unregister call comes before unmapMemory in free
	unreg=$(grep -n '__nv_drm_gem_nvkms_bsd_pages_unregister(' "$TMPD/free.c" | head -1 | cut -d: -f1)
	unmap=$(grep -n 'unmapMemory(' "$TMPD/free.c" | head -1 | cut -d: -f1)
	[ -n "$unreg" ] || { echo "__nv_drm_gem_nvkms_memory_free: does not unregister the vm_pages"; return; }
	[ -n "$unmap" ] || { echo "__nv_drm_gem_nvkms_memory_free: no unmapMemory call (extractor?)"; return; }
	[ "$unreg" -lt "$unmap" ] || { echo "__nv_drm_gem_nvkms_memory_free: unregisters after unmapMemory"; return; }
	body "$1" __nv_drm_gem_nvkms_bsd_pages_unregister "$TMPD/unreg.c" || { echo "no __nv_drm_gem_nvkms_bsd_pages_unregister"; return; }
	grep -Eq 'vm_phys_fictitious_unreg_range\(' "$TMPD/unreg.c" \
	    || { echo "__nv_drm_gem_nvkms_bsd_pages_unregister: no vm_phys_fictitious_unreg_range call"; return; }
	# (f3) the pages-in-use check precedes the unregistration
	inuse=$(grep -n 'object != NULL' "$TMPD/unreg.c" | head -1 | cut -d: -f1)
	unregl=$(grep -n 'vm_phys_fictitious_unreg_range(' "$TMPD/unreg.c" | head -1 | cut -d: -f1)
	[ -n "$inuse" ] && [ "$inuse" -lt "$unregl" ] \
	    || { echo "__nv_drm_gem_nvkms_bsd_pages_unregister: no in-use check before unregistering"; return; }
}
r=$(pages_check "$PRISTINE/$NVKMS")
case $r in *cannot\ extract*) bad "control: extractor broken: $r"; r=extractor-broken ;; esac
[ -n "$r" ] && ok "control: pristine source has no vm_pages for video memory ($r)" \
    || bad "control: pristine source passed - the check cannot see the defect"
# mutant: the prepared source without the unregistration in free
sed '/__nv_drm_gem_nvkms_bsd_pages_unregister(nv_nvkms_memory);/d' "$TREE/$NVKMS" > "$TMPD/mutant.c"
r=$(pages_check "$TMPD/mutant.c")
case $r in *cannot\ extract*) bad "control: extractor broken: $r"; r=extractor-broken ;; esac
[ -n "$r" ] && ok "control: mutant without the unregistration is flagged ($r)" \
    || bad "control: mutant without the unregistration passed"
# mutant: the prepared source without the overlap probe (registers blind)
sed '/(m->flags & PG_FICTITIOUS) != 0/d; /VM_PAGE_TO_PHYS(m) == pa/d' "$TREE/$NVKMS" > "$TMPD/mutant2.c"
r=$(pages_check "$TMPD/mutant2.c")
case $r in *cannot\ extract*) bad "control: extractor broken: $r"; r=extractor-broken ;; esac
[ -n "$r" ] && ok "control: mutant without the overlap probe is flagged ($r)" \
    || bad "control: mutant without the overlap probe passed"
# mutant: the probe trusts the flag bit alone (no physical-address check)
sed '/(m->flags & PG_FICTITIOUS) != 0 &&$/{N;s/ &&\n            VM_PAGE_TO_PHYS(m) == pa) {/) {/;}' "$TREE/$NVKMS" > "$TMPD/mutant3.c"
r=$(pages_check "$TMPD/mutant3.c")
case $r in *cannot\ extract*) bad "control: extractor broken: $r"; r=extractor-broken ;; esac
[ -n "$r" ] && ok "control: mutant trusting PG_FICTITIOUS alone is flagged ($r)" \
    || bad "control: mutant trusting PG_FICTITIOUS alone passed"
r=$(pages_check "$TREE/$NVKMS")
[ -z "$r" ] && ok "nvkms map/free: video memory registered as vm_pages, unregistered before unmap, in-use check" \
    || bad "nvkms map/free: $r"

echo "passed: $passed failed: $failed"
[ "$failed" -eq 0 ]
