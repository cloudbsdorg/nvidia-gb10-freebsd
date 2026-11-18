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
#   (d) for the nvkms handler, add page_offset to the video-memory pfn.
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
# function, from its name line to the first line that is just "}".
body() {
	unifdef -UNV_LINUX -o "$TMPD/unifdef.c" "$1"
	# unifdef exits 1 when it changed something, 0 when not, 2 on error.
	[ $? -le 1 ] || return 1
	awk -v f="$2" '
		index($0, f) == 1 || index($0, "static vm_fault_t " f) == 1 { on = 1 }
		on { print }
		on && /^}$/ { exit }
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
[ -n "$r" ] && ok "control: pristine nvkms handler is flagged ($r)" \
    || bad "control: pristine nvkms handler passed - the check cannot see the defect"
r=$(check "$PRISTINE/$USERM" __nv_drm_gem_user_memory_handle_vma_fault no)
[ -n "$r" ] && ok "control: pristine user-memory handler is flagged ($r)" \
    || bad "control: pristine user-memory handler passed - the check cannot see the defect"

# The prepared tree (patches applied) must be clean.
r=$(check "$TREE/$NVKMS" __nv_drm_gem_nvkms_handle_vma_fault yes)
[ -z "$r" ] && ok "nvkms handler: index from the address, added to the pfn, no BUG_ON" \
    || bad "nvkms handler: $r"
r=$(check "$TREE/$USERM" __nv_drm_gem_user_memory_handle_vma_fault no)
[ -z "$r" ] && ok "user-memory handler: index from the address, no BUG_ON" \
    || bad "user-memory handler: $r"

echo "passed: $passed failed: $failed"
[ "$failed" -eq 0 ]
