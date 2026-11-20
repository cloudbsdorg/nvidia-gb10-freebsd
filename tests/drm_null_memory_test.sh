#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# drm_null_memory_test.sh - nvidia-drm must never hand a NULL NVKMS memory
# handle to the KAPI (#2103).
#
# The NVKMS KAPI's isVidmem() dereferences the handle it is given
# (nvkms-kapi.c: IsVidmem() returns memory->isVidmem), so a NULL handle is
# a kernel panic there and not an error return.  A NULL handle is what a
# dma-buf import leaves behind when the RM cannot import the buffer: on
# FreeBSD the OS layer has no dma-buf import at all (nvidia_subr.c:
# nv_dma_import_dma_buf() returns NV_ERR_NOT_SUPPORTED), so
# getSystemMemoryHandleFromDmaBuf() returns NULL and the GEM object is
# created without a handle.  amp001, 2026-11-19: a Wayland login on a
# machine with an amdgpu and an NVIDIA card panicked the kernel in
# IsVidmem (x0=0, far 0x28) through drm_mode_addfb2.
#
# The invariant this test enforces:
#
#   (a) every nvKms->isVidmem() call in nvidia-drm is preceded, in the same
#       function, by a NULL check of the handle it is given;
#   (b) a framebuffer whose plane has no handle is refused with EINVAL,
#       and the refusal path frees everything it took (no GEM reference
#       and no DRM framebuffer object left behind);
#   (c) the dma-buf import does not panic on a size the exporter chose,
#       and says so when the RM could not import the buffer;
#   (d) the dma-buf mmap path does not dereference a NULL file;
#   (e) the dma-buf export path keeps its guards: the export refuses a
#       buffer with no memory handle, and the free path frees the RM
#       handle only when there is one.
#
# The test applies the repository's own patches to NVIDIA's pristine
# source and checks the result, so it is self-contained: it needs the
# pristine source (scripts/fetch-sources.sh) and the patches, not a
# prepared tree.  It also checks the prepared tree when there is one,
# because that tree is what gets built and loaded: a tree without the
# guard is a tree that still panics.
#
# The checks run against NVIDIA's pristine source too (they MUST fail
# there: the test proves it can see the defect) and against mutants of the
# patched source (they must fail as well).
#
# Usage: sh tests/drm_null_memory_test.sh [TREE]
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

TMPD=$(mktemp -d "$WORK/tmp/drm-null-memory-test.XXXXXXXX") || exit 1
trap 'rm -rf -- "$TMPD"' EXIT INT TERM

passed=0
failed=0
ok() { echo "PASS: $1"; passed=$((passed + 1)); }
bad() { echo "FAIL: $1"; failed=$((failed + 1)); }

# strip_comments <in> <out>: the C source without its comments, so a check
# for a construct is never confused by the word in a comment.  Both comment
# kinds are removed; the code around them is kept.
strip_comments() {
	awk '
	{
		line = $0
		out = ""
		while (length(line) > 0) {
			if (inblock) {
				p = index(line, "*/")
				if (p == 0) { line = ""; break }
				line = substr(line, p + 2)
				inblock = 0
				continue
			}
			p = index(line, "/*")
			q = index(line, "//")
			if (q > 0 && (p == 0 || q < p)) {
				out = out substr(line, 1, q - 1)
				line = ""
				break
			}
			if (p > 0) {
				out = out substr(line, 1, p - 1)
				line = substr(line, p + 2)
				inblock = 1
				continue
			}
			out = out line
			line = ""
		}
		print out
	}
	' "$1" > "$2"
}

# body <file> <function> <out>: the code of one function, comments
# removed, from its definition line to the closing brace of that function.
# A prototype (a statement ending in ";") is skipped, so the definition is
# found even when one precedes it, and a call is skipped the same way.  The
# braces are counted, so a "}" that closes an inner block does not end the
# function early.  The extractor fails (no output) when it does not find a
# definition: a function that cannot be extracted is a defect the caller
# must report, never an empty body that reads as "nothing wrong".
body() {
	awk -v f="$2" '
		!on && $0 ~ ("(^|[^A-Za-z0-9_])" f "[ \t]*\\(") { on = 1 }
		on {
			if (!opened && $0 ~ /;[ \t]*$/) { on = 0; n = 0; next }
			buf[n++] = $0
			t = $0
			no = gsub(/\{/, "", t)
			t = $0
			nc = gsub(/\}/, "", t)
			if (no > 0) { opened = 1 }
			depth += no - nc
			if (opened && depth <= 0) {
				for (i = 0; i < n; i++) print buf[i]
				exit
			}
		}
	' "$1" > "$TMPD/raw.c"
	[ -s "$TMPD/raw.c" ] || return 1
	strip_comments "$TMPD/raw.c" "$3"
	[ -s "$3" ]
}

# lineno <file> <pattern>: the line number of the first line matching
# <pattern>, or nothing when there is none.  The patterns are basic
# regular expressions, in which a parenthesis is written [(] and [)]: a
# backslash-parenthesis is a GROUP in BSD grep, not a literal.
lineno() {
	grep -n -- "$2" "$1" | head -1 | cut -d: -f1
}

# --- the invariant, per file -------------------------------------------

# isvidmem_checks <dir>: every nvKms->isVidmem() call in <dir>/nvidia-drm
# must be preceded, in the same function, by a NULL check of the handle it
# is given.  The call sites are listed explicitly: a new one must be added
# here (and guarded) rather than silently accepted.
isvidmem_checks() {
	_dir=$1
	_n=$(cat "$_dir"/nvidia-drm/*.c | grep -c 'nvKms->isVidmem(')
	if [ "$_n" -ne 3 ]; then
		echo "the tree has $_n nvKms->isVidmem() calls, not the 3 this test knows about"
		return
	fi
	# site 1: the framebuffer plane (the panic site)
	body "$_dir/nvidia-drm/nvidia-drm-fb.c" nv_drm_framebuffer_init "$TMPD/fb.c" || {
		echo "cannot extract nv_drm_framebuffer_init"; return; }
	_g=$(lineno "$TMPD/fb.c" 'pMemory[[:space:]]*==[[:space:]]*NULL')
	_v=$(lineno "$TMPD/fb.c" 'nvKms->isVidmem(')
	_u=$(lineno "$TMPD/fb.c" 'params\.planes\[i\]\.memory[[:space:]]*=')
	[ -n "$_g" ] || { echo "nv_drm_framebuffer_init: no NULL check on the plane's memory handle"; return; }
	[ -n "$_v" ] || { echo "nv_drm_framebuffer_init: no isVidmem() call (extractor?)"; return; }
	[ "$_g" -lt "$_v" ] || { echo "nv_drm_framebuffer_init: the NULL check comes after isVidmem()"; return; }
	[ -n "$_u" ] && [ "$_g" -lt "$_u" ] || {
		echo "nv_drm_framebuffer_init: the NULL check comes after the handle is used"; return; }
	# the refusal must be an error return, and the failure path must clean
	# up: the DRM framebuffer object and the GEM references.
	_f=$(lineno "$TMPD/fb.c" '^fail:')
	[ -n "$_f" ] || { echo "nv_drm_framebuffer_init: no failure path"; return; }
	tail -n +"$_f" "$TMPD/fb.c" > "$TMPD/fail.c"
	grep -Eq 'return[[:space:]]+-EINVAL' "$TMPD/fail.c" || {
		echo "nv_drm_framebuffer_init: the failure path does not return -EINVAL"; return; }
	grep -Fq 'drm_framebuffer_cleanup(fb)' "$TMPD/fail.c" || {
		echo "nv_drm_framebuffer_init: the failure path does not clean up the DRM framebuffer object"; return; }
	body "$_dir/nvidia-drm/nvidia-drm-fb.c" nv_drm_framebuffer_create "$TMPD/fbc.c" || {
		echo "cannot extract nv_drm_framebuffer_create"; return; }
	grep -Fq '__nv_drm_framebuffer_free(nv_fb)' "$TMPD/fbc.c" || {
		echo "nv_drm_framebuffer_create: the failure path does not drop the GEM references"; return; }
	# site 2: the video-memory map
	body "$_dir/nvidia-drm/nvidia-drm-gem-nvkms-memory.c" __nv_drm_gem_nvkms_map "$TMPD/map.c" || {
		echo "cannot extract __nv_drm_gem_nvkms_map"; return; }
	_g=$(lineno "$TMPD/map.c" 'pMemory[[:space:]]*==[[:space:]]*NULL')
	_v=$(lineno "$TMPD/map.c" 'nvKms->isVidmem(')
	[ -n "$_g" ] || { echo "__nv_drm_gem_nvkms_map: no NULL check on the memory handle"; return; }
	[ -n "$_v" ] && [ "$_g" -lt "$_v" ] || {
		echo "__nv_drm_gem_nvkms_map: the NULL check comes after isVidmem()"; return; }
	# site 3: the creation of the GEM object
	body "$_dir/nvidia-drm/nvidia-drm-gem-nvkms-memory.c" __nv_drm_nvkms_gem_obj_init "$TMPD/obj.c" || {
		echo "cannot extract __nv_drm_nvkms_gem_obj_init"; return; }
	_g=$(lineno "$TMPD/obj.c" 'pMemory[[:space:]]*==[[:space:]]*NULL')
	_v=$(lineno "$TMPD/obj.c" 'nvKms->isVidmem(')
	[ -n "$_g" ] || { echo "__nv_drm_nvkms_gem_obj_init: no NULL check on the memory handle"; return; }
	[ -n "$_v" ] && [ "$_g" -lt "$_v" ] || {
		echo "__nv_drm_nvkms_gem_obj_init: the NULL check comes after isVidmem()"; return; }
}

# dmabuf_checks <dir>: the dma-buf import, mmap and export paths.
dmabuf_checks() {
	_dir=$1
	# the import: no panic on a size the exporter chose, and the RM's
	# refusal to import the buffer is reported.
	body "$_dir/nvidia-drm/nvidia-drm-gem-dma-buf.c" nv_drm_gem_prime_import_sg_table "$TMPD/imp.c" || {
		echo "cannot extract nv_drm_gem_prime_import_sg_table"; return; }
	if grep -Eq 'BUG_ON[[:space:]]*[(]' "$TMPD/imp.c"; then
		echo "nv_drm_gem_prime_import_sg_table: a BUG_ON (a user-reachable panic)"
		return
	fi
	grep -Eq 'dma_buf->size[[:space:]]*==[[:space:]]*0' "$TMPD/imp.c" \
	    || grep -Eq 'dma_buf->size[[:space:]]*%[[:space:]]*PAGE_SIZE' "$TMPD/imp.c" || {
		echo "nv_drm_gem_prime_import_sg_table: the dma-buf size is not checked"; return; }
	grep -Eq 'return[[:space:]]+ERR_PTR[(]-EINVAL[)]' "$TMPD/imp.c" || {
		echo "nv_drm_gem_prime_import_sg_table: a bad dma-buf size is not refused with an error"; return; }
	grep -Eq 'pMemory[[:space:]]*==[[:space:]]*NULL' "$TMPD/imp.c" || {
		echo "nv_drm_gem_prime_import_sg_table: the RM's refusal to import the buffer is not noticed"; return; }
	# the mmap path: no NULL file
	body "$_dir/nvidia-drm/nvidia-drm-gem-dma-buf.c" __nv_drm_gem_dma_buf_mmap "$TMPD/mmap.c" || {
		echo "cannot extract __nv_drm_gem_dma_buf_mmap"; return; }
	_g=$(lineno "$TMPD/mmap.c" 'filp[[:space:]]*==[[:space:]]*NULL')
	_u=$(lineno "$TMPD/mmap.c" 'filp->f_op->mmap')
	[ -n "$_g" ] || { echo "__nv_drm_gem_dma_buf_mmap: no NULL check on the file"; return; }
	[ -n "$_u" ] && [ "$_g" -lt "$_u" ] || {
		echo "__nv_drm_gem_dma_buf_mmap: the NULL check comes after the file is dereferenced"; return; }
	# the export path: no export without a memory handle
	body "$_dir/nvidia-drm/nvidia-drm-gem-dma-buf.c" nv_drm_gem_export_dmabuf_memory_ioctl "$TMPD/exp.c" || {
		echo "cannot extract nv_drm_gem_export_dmabuf_memory_ioctl"; return; }
	_g=$(lineno "$TMPD/exp.c" '!nv_dma_buf->base\.pMemory && !pTmpMemory')
	_e=$(lineno "$TMPD/exp.c" 'nvKms->exportMemory(')
	[ -n "$_g" ] || { echo "nv_drm_gem_export_dmabuf_memory_ioctl: the export has no guard"; return; }
	[ -n "$_e" ] && [ "$_g" -lt "$_e" ] || {
		echo "nv_drm_gem_export_dmabuf_memory_ioctl: the guard comes after the export"; return; }
	# the free path: the RM handle is freed only when there is one
	body "$_dir/nvidia-drm/nvidia-drm-gem-dma-buf.c" __nv_drm_gem_dma_buf_free "$TMPD/free.c" || {
		echo "cannot extract __nv_drm_gem_dma_buf_free"; return; }
	_g=$(lineno "$TMPD/free.c" 'if [(]nv_dma_buf->base\.pMemory[)]')
	_f=$(lineno "$TMPD/free.c" 'nvKms->freeMemory(')
	[ -n "$_g" ] || { echo "__nv_drm_gem_dma_buf_free: the RM handle is freed unconditionally"; return; }
	[ -n "$_f" ] && [ "$_g" -lt "$_f" ] || {
		echo "__nv_drm_gem_dma_buf_free: the guard comes after the free"; return; }
}

# --- the sources ------------------------------------------------------

FB=nvidia-drm/nvidia-drm-fb.c
DMABUF=nvidia-drm/nvidia-drm-gem-dma-buf.c
NVKMS=nvidia-drm/nvidia-drm-gem-nvkms-memory.c

for f in "$PRISTINE/$FB" "$PRISTINE/$DMABUF" "$PRISTINE/$NVKMS"; do
	[ -f "$f" ] || { echo "FAIL: missing $f (run scripts/fetch-sources.sh)"; exit 1; }
done

# The patches of this repository, applied to the pristine source.
PATCHES="patch-nvidia-drm_nvidia-drm-fb.c
patch-nvidia-drm_nvidia-drm-gem-dma-buf.c
patch-nvidia-drm_nvidia-drm-gem-nvkms-memory.c"

mkdir -p "$TMPD/tree/nvidia-drm"
cp "$PRISTINE/$FB" "$PRISTINE/$DMABUF" "$PRISTINE/$NVKMS" "$TMPD/tree/nvidia-drm/" || exit 1
for p in $PATCHES; do
	[ -f "$repo/patches/$p" ] || { echo "FAIL: missing patches/$p"; exit 1; }
	if ! patch -d "$TMPD/tree" -p0 -E -s -i "$repo/patches/$p"; then
		echo "FAIL: patches/$p does not apply to the pristine source"
		exit 1
	fi
done

# The pristine source, for the control.
mkdir -p "$TMPD/pristine/nvidia-drm"
cp "$PRISTINE/$FB" "$PRISTINE/$DMABUF" "$PRISTINE/$NVKMS" "$TMPD/pristine/nvidia-drm/" || exit 1

# --- the patched source must pass --------------------------------------

r=$(isvidmem_checks "$TMPD/tree")
[ -z "$r" ] && ok "every isVidmem() call is preceded by a NULL check of its handle" \
    || bad "isVidmem() calls: $r"
r=$(dmabuf_checks "$TMPD/tree")
[ -z "$r" ] && ok "dma-buf import, mmap and export paths are guarded" \
    || bad "dma-buf paths: $r"

# --- the control: the pristine source must be flagged ------------------

r=$(isvidmem_checks "$TMPD/pristine")
[ -n "$r" ] && ok "control: the pristine source is flagged ($r)" \
    || bad "control: the pristine source passed - the check cannot see the defect"
r=$(dmabuf_checks "$TMPD/pristine")
[ -n "$r" ] && ok "control: the pristine dma-buf paths are flagged ($r)" \
    || bad "control: the pristine dma-buf paths passed - the check cannot see the defect"

# --- the mutants: a guard that is gone must be seen --------------------

# mutant 1: the framebuffer guard removed
mkdir -p "$TMPD/m1/nvidia-drm"
cp "$TMPD/tree/$DMABUF" "$TMPD/tree/$NVKMS" "$TMPD/m1/nvidia-drm/"
sed '/if (nv_gem->pMemory == NULL) {/,/^            }$/d' "$TMPD/tree/$FB" \
    > "$TMPD/m1/nvidia-drm/nvidia-drm-fb.c"
r=$(isvidmem_checks "$TMPD/m1")
[ -n "$r" ] && ok "control: mutant without the framebuffer guard is flagged ($r)" \
    || bad "control: mutant without the framebuffer guard passed"

# mutant 2: the guard kept but never taken
mkdir -p "$TMPD/m2/nvidia-drm"
cp "$TMPD/tree/$DMABUF" "$TMPD/tree/$NVKMS" "$TMPD/m2/nvidia-drm/"
sed 's/if (nv_gem->pMemory == NULL) {/if (0) {/' "$TMPD/tree/$FB" \
    > "$TMPD/m2/nvidia-drm/nvidia-drm-fb.c"
r=$(isvidmem_checks "$TMPD/m2")
[ -n "$r" ] && ok "control: mutant with the guard disabled is flagged ($r)" \
    || bad "control: mutant with the guard disabled passed"

# mutant 3: the dma-buf size check disabled
mkdir -p "$TMPD/m3/nvidia-drm"
cp "$TMPD/tree/$FB" "$TMPD/tree/$NVKMS" "$TMPD/m3/nvidia-drm/"
sed 's/if (dma_buf->size == 0 || (dma_buf->size % PAGE_SIZE) != 0) {/if (0) {/' \
    "$TMPD/tree/$DMABUF" > "$TMPD/m3/nvidia-drm/nvidia-drm-gem-dma-buf.c"
r=$(dmabuf_checks "$TMPD/m3")
[ -n "$r" ] && ok "control: mutant with the dma-buf size check disabled is flagged ($r)" \
    || bad "control: mutant with the dma-buf size check disabled passed"

# mutant 4: the guard after the handle is used
mkdir -p "$TMPD/m4/nvidia-drm"
cp "$TMPD/tree/$DMABUF" "$TMPD/tree/$NVKMS" "$TMPD/m4/nvidia-drm/"
awk '
	/if \(nv_gem->pMemory == NULL\) \{/ { guard = 1; next }
	guard && /^            \}$/ { guard = 0; next }
	guard { next }
	{ print }
	/params\.planes\[i\]\.memory =/ && !done { print; print "            if (nv_gem->pMemory == NULL) { goto fail; }"; done = 1 }
' "$TMPD/tree/$FB" > "$TMPD/m4/nvidia-drm/nvidia-drm-fb.c"
r=$(isvidmem_checks "$TMPD/m4")
[ -n "$r" ] && ok "control: mutant with the guard after the use is flagged ($r)" \
    || bad "control: mutant with the guard after the use passed"

# --- the prepared tree -------------------------------------------------

if [ -f "$TREE/$FB" ]; then
	r=$(isvidmem_checks "$TREE")
	[ -z "$r" ] && ok "the prepared tree: every isVidmem() call is guarded" \
	    || bad "the prepared tree: $r (run scripts/prepare-tree.sh)"
	r=$(dmabuf_checks "$TREE")
	[ -z "$r" ] && ok "the prepared tree: the dma-buf paths are guarded" \
	    || bad "the prepared tree: $r (run scripts/prepare-tree.sh)"
else
	echo "NOTE: no prepared tree at $TREE: only the patched source was checked"
fi

echo "passed: $passed failed: $failed"
[ "$failed" -eq 0 ]
