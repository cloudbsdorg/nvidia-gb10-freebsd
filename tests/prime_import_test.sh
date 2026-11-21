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
#
# The gate-name check (D6) parses nvidia-drm-freebsd-lkpi.c and nvidia-drm-drv.c with clang and the module's own
# compile line (clang -Xclang -ast-dump=json): it needs clang in PATH and a prepared nvidia-drm build tree,
# PRIME_BUILD_TREE (default build/tree under GB10_WORK, which is ~/work/gb10 when unset; scripts/prepare-tree.sh and scripts/build-shim.sh
# --module=nvidia-drm make one).  It never skips: without them the suite fails.

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
SIDATA=$repo/tests/data/si_values.txt
kval() { awk -v n="$1" '$1 == n { print $2; exit }' "$SIDATA"; }
# the vendored values agree with the kernel source when one is at hand (SYSDIR, or the default tree)
SYSDIR=${SYSDIR:-$HOME/src/csrc-90dcf68/sys}
if [ -f "$SYSDIR/sys/kernel.h" ]; then
	_drift=$(sed -nE 's/^[[:space:]]*(SI_(SUB|ORDER)_[A-Z_0-9]*)[[:space:]]*=[[:space:]]*(0x[0-9a-fA-F]*).*/\1 \3/p' "$SYSDIR/sys/kernel.h" | awk '!seen[$1]++' | while read -r _n _v; do [ "$(kval "$_n")" = "$_v" ] || echo "$_n"; done)
	[ -z "$_drift" ] || { echo "FAIL: tests/data/si_values.txt differs from $SYSDIR/sys/kernel.h: $_drift"; exit 1; }
else
	echo "NOTE: no $SYSDIR/sys/kernel.h: the vendored sysinit values in tests/data/si_values.txt are not compared with a kernel source here"
fi
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
# the text of a C file as the preprocessor sees its lines: backslash-newline joined first, then comments removed
pp_lines() {
	awk '{ if (sub(/\\[ \t\r]*$/, "")) { acc = acc $0; next } print acc $0; acc = "" } END { if (acc != "") print acc }' "$1" > "$TMPD/pp-joined.c"
	strip_comments "$TMPD/pp-joined.c" "$TMPD/pp-nocomment.c"
	cat "$TMPD/pp-nocomment.c"
}

# The names of the three gate functions and their types: one file, read by the text scan below and by the AST check
GATE_NAMES=$repo/tests/data/gate_names.txt
# the trigraphs phase 1 would map: ??= is #, ??/ a backslash, and ??' ??( ??) ??! ??< ??> ??-
TRIGRAPH_RE="[?][?][=/'()!<>-]"

# gate_occurrences <file>: every statement (the text between two of ; { }) of the file, as the preprocessor sees it
# (spliced, comments gone, string literals emptied, white space folded), that holds a whole-token use of one of the
# gate names, with the number of uses in it.  Whole token: no identifier character on either side, so the guard's
# own nv_drm_pi_guard_handler is not one.  The list is compared with a pinned one: a new use, a lost use and a
# definition in any spelling all change it.
gate_occurrences() {
	_galt=$(grep -v '^#' "$GATE_NAMES" | cut -f1 | paste -s -d'|' -)
	[ -n "$_galt" ] || return 1
	pp_lines "$1" | tr '\n' ' ' | awk -v alt="$_galt" 'BEGIN { re = "(^|[^A-Za-z0-9_])(" alt ")([^A-Za-z0-9_]|$)" } {
		gsub(/"([^"\\]|\\.)*"/, "\"\"")
		gsub(/[;{}]/, "\n"); n = split($0, seg, "\n")
		for (i = 1; i <= n; i++) {
			s = seg[i]; gsub(/[ \t]+/, " ", s); sub(/^ /, "", s); sub(/ $/, "", s)
			t = s; c = 0
			while (match(t, re)) { c++; t = substr(t, RSTART + RLENGTH - 1) }
			if (c > 0) print c " " s
		}
	}'
}

# trigraph_added <pristine> <new>: the lines <new> adds to <pristine> that hold a trigraph.  With -std=gnu17 they are
# ignored, but that rests on build variables (CSTD, -trigraphs) that no reviewed patch pins, so the text is
# refused.  Prints the first such line; returns 2, printing nothing, when the diff itself fails (the caller says so).
trigraph_added() {
	diff "$1" "$2" > "$TMPD/tri-diff.txt"; [ $? -le 1 ] || return 2
	grep '^>' "$TMPD/tri-diff.txt" | grep -E "$TRIGRAPH_RE" | head -1
	return 0
}

# gate_line_safe <compile line>: the line make prints for one object is run by the shell (it carries quoted -D
# values), so it must be plain words: no command separator, pipe, redirection, substitution or newline.
gate_line_safe() {
	case $1 in
	*';'*|*'|'*|*'&'*|*'<'*|*'>'*|*'`'*|*'$('*|*'
'*) return 1 ;;
	esac
	case $1 in 'cc '*) return 0 ;; esac
	return 1
}

# gate_ast <tree> <file>: the AST of one patched nvidia-drm source (lkpi.c or drv.c), parsed by clang with the
# module's own compile line, so that macros, token pasting, typedefs and attributes are resolved before the
# names are looked at.  The flags are the ones make prints for that object in a prepared build tree
# (PRIME_BUILD_TREE, default $WORK/build/tree): the tree's generated headers and the kernel and drm-kmod trees it
# was configured against (its .gb10-sysdir stamp) are what the source includes.  The patched file replaces the
# one of the tree; the headers of the tree under test come first (a quoted include looks next to the file).
# tests/data/gate_ast_check.py then refuses every declaration named exactly one of the gate names that is not
# the external declaration.  Prints the first defect, or AST-OK as its only line when there is none: the caller
# demands that word, so a run that died before it (a failed expansion, an unset variable) is a defect and never
# reads as clean.  This never skips: no clang, no prepared tree, a source that does not parse is a defect.
gate_ast() {
	_gt=$1; _gb=$2
	command -v clang > /dev/null 2>&1 || { echo "D6: clang is not installed: the AST check of the gate names cannot run, and it does not skip"; return; }
	_gd=${PRIME_BUILD_TREE:-$WORK/build/tree}/nvidia-drm
	_gs=$_gd/.gb10-sysdir
	[ -f "$_gs" ] && [ -f "$_gd/Makefile" ] || { echo "D6: no prepared nvidia-drm build tree at $_gd (set PRIME_BUILD_TREE): the AST check of the gate names needs the compile line and the generated headers"; return; }
	_gsys=$(awk '$1 == "sysdir" { print $2 }' "$_gs"); _gtop=$(awk '$1 == "bsdsrctop" { print $2 }' "$_gs"); _gdrm=$(awk '$1 == "drmkmoddir" { print $2 }' "$_gs")
	[ -n "$_gsys" ] && [ -n "$_gtop" ] && [ -n "$_gdrm" ] || { echo "D6: $_gs does not name sysdir, bsdsrctop and drmkmoddir"; return; }
	_gname=${_gb%.c}
	( cd "$_gd" && env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL -u MAKEOBJDIR -u MAKEOBJDIRPREFIX make -n -B \
	    MACHINE=arm64 MACHINE_ARCH=aarch64 SYSDIR="$_gsys" BSDSRCTOP="$_gtop" DRMKMODDIR="$_gdrm" "$_gname.o" ) 2> "$TMPD/ast-make.err" | grep '^cc ' > "$TMPD/ast-cc.txt"
	[ -s "$TMPD/ast-cc.txt" ] || { echo "D6: make prints no compile line for $_gname.o in $_gd: $(head -1 "$TMPD/ast-make.err")"; return; }
	[ "$(wc -l < "$TMPD/ast-cc.txt" | tr -d ' ')" = 1 ] || { echo "D6: make prints more than one compile line for $_gname.o"; return; }
	_gline=$(cat "$TMPD/ast-cc.txt")
	gate_line_safe "$_gline" || { echo "D6: the compile line of $_gname.o is not plain words (a separator, pipe, redirection or substitution): it is not run"; return; }
	# the line is shell syntax (it carries quoted -D values): split it by the shell, then drop what makes an object
	eval "set -- $_gline"
	shift
	_gn=$#; _gskip=0
	for _ga in "$@"; do
		if [ "$_gskip" = 1 ]; then _gskip=0; continue; fi
		case $_ga in
		-MD|-c|-MF*|-MT*|*.c) ;;
		-o) _gskip=1 ;;
		*) set -- "$@" "$_ga" ;;
		esac
	done
	shift "$_gn"
	( cd "$_gd" && clang -I"$_gt/nvidia-drm" "$@" -fsyntax-only -Xclang -ast-dump=json -Xclang -ast-dump-filter=nv_drm_pi_ "$_gt/nvidia-drm/$_gb" ) > "$TMPD/ast-$_gname.json" 2> "$TMPD/ast-$_gname.err"
	_grc=$?
	[ "$_grc" -eq 0 ] || { echo "D6: clang does not parse $_gb with the module's flags (rc=$_grc): $(grep -m1 'error' "$TMPD/ast-$_gname.err")"; return; }
	python3 -I -B "$repo/tests/data/gate_ast_check.py" "$GATE_NAMES" < "$TMPD/ast-$_gname.json" > "$TMPD/ast-$_gname.out" 2>&1 || { echo "D6: the AST check of $_gb did not run: $(head -1 "$TMPD/ast-$_gname.out")"; return; }
	[ ! -s "$TMPD/ast-$_gname.out" ] || { echo "D6: $_gb: $(head -1 "$TMPD/ast-$_gname.out")"; return; }
	echo AST-OK
}

# gate_ast_both <tree>: gate_ast over lkpi.c and drv.c; prints the first defect, or AST-OK when both are clean
gate_ast_both() {
	for _f in nvidia-drm-freebsd-lkpi.c nvidia-drm-drv.c; do
		_ast=$(gate_ast "$1" "$_f")
		[ "$_ast" = AST-OK ] || { echo "${_ast:-D6: the AST check of $_f printed nothing}"; return; }
	done
	echo AST-OK
}

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
	# no preprocessor line but #include may be added to the nvidia-drm sources by the patches: a #define of a name the
	# glue checks rely on (a macro for gb10_pi_gate_quiesce, SI_ORDER_LAST, nv_drm_pi_quiesce) or an #if 0 copy of a
	# function would defeat every check below, which read the text and compile the extracted functions
	for _f in $DMABUF $DMABUFH $LKPI $DRV; do
		[ -f "$PRISTINE/$_f" ] && [ -f "$_t/$_f" ] || { echo "D6: cannot compare $_f with the pristine source (a file is missing: $PRISTINE/$_f)"; return; }
		pp_lines "$PRISTINE/$_f" > "$TMPD/pp-a.c"; pp_lines "$_t/$_f" > "$TMPD/pp-b.c"
		diff "$TMPD/pp-a.c" "$TMPD/pp-b.c" > "$TMPD/pp-diff.txt"; [ $? -le 1 ] || { echo "D6: diff of $_f against the pristine source failed"; return; }
		_pp=$(grep '^>' "$TMPD/pp-diff.txt" | grep -E '^>[[:space:]]*(#|%:)' | grep -vE '^>[[:space:]]*(#|%:)[[:space:]]*include')
		[ -z "$_pp" ] || { echo "D6: the patches add a preprocessor line other than #include to $_f ($(echo "$_pp" | head -1)): a macro or an #if can change what the checked functions mean"; return; }
	done
	# the core header is part of what the checks read: its preprocessor lines are pinned to the list below, so a
	# #define of a gate function under an #ifdef _KERNEL (which no kernel-less test would see) is caught
	[ -f "$_t/_core/gb10_pageimport.h" ] || { echo "D6: no copy of the core header in the tree under test"; return; }
	pp_lines "$_t/_core/gb10_pageimport.h" | grep -E '^[[:space:]]*(#|%:)' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' > "$TMPD/core-pp.txt"
	cat > "$TMPD/core-pp.want" <<'CORE_PP_END'
#ifndef _GB10_PAGEIMPORT_H_
#define _GB10_PAGEIMPORT_H_
#ifndef NULL
#define NULL ((void *)0)
#endif
#define GB10_PI_MAX_BYTES (1ULL << 32)
#define GB10_PI_STATUS_RETRY 3U
#define GB10_PI_STATUS_REFUSED 0x56U
#define GB10_PI_DESC_MAGIC 0x0000474232305049ULL
#define GB10_PI_DIRTY_SPIN_BUDGET 100
#define GB10_PI_DIRTY_SPIN_US 10
#endif
CORE_PP_END
	cmp -s "$TMPD/core-pp.txt" "$TMPD/core-pp.want" || { echo "D6: the preprocessor lines of gb10_pageimport.h are not the pinned list: $(diff "$TMPD/core-pp.want" "$TMPD/core-pp.txt" | head -2 | tr '\n' ' ')"; return; }
	# no trigraph in anything the patches add, in the OS file or in the core header: phase 1 would turn ??= into a
	# # (a directive the checks above never saw) when the build asks for it.  The files built from the patches are
	# compared with the pristine ones (what a patch adds, whatever the patch file is called), and the patch files
	# themselves are read as well, because a hunk that does not end up in a compared file is still a defect.
	for _f in $DMABUF $DMABUFH $LKPI $DRV $SUBR $OSC $MKF; do
		_tri=$(trigraph_added "$PRISTINE/$_f" "$_t/$_f"); _rc=$?
		[ "$_rc" -eq 0 ] || { echo "D6: cannot compare $_f with the pristine source for trigraphs (diff failed)"; return; }
		[ -z "$_tri" ] || { echo "D6: the patches add a trigraph to $_f ($_tri)"; return; }
	done
	for _f in $OSMEM $KAPIC; do
		_tri=$(trigraph_added "$OGKMSRC/$_f" "$_t/ogkm/$_f"); _rc=$?
		[ "$_rc" -eq 0 ] || { echo "D6: cannot compare $_f with the pristine source for trigraphs (diff failed)"; return; }
		[ -z "$_tri" ] || { echo "D6: the patches add a trigraph to $_f ($_tri)"; return; }
	done
	for _f in nvidia/gb10_pageimport_os.c _core/gb10_pageimport.h; do
		_tri=$(trigraph_added /dev/null "$_t/$_f"); _rc=$?
		[ "$_rc" -eq 0 ] || { echo "D6: cannot read $_f for trigraphs (diff failed)"; return; }
		[ -z "$_tri" ] || { echo "D6: $_f holds a trigraph ($_tri)"; return; }
	done
	set -- "$repo"/patches/patch-*
	[ -f "$1" ] || { echo "D6: no patch files to read for trigraphs (patches/patch-* matched nothing)"; return; }
	_pl=$(cat "$@" | grep '^+')
	set -- "$repo"/patches/ogkm/patch-*
	[ -f "$1" ] || { echo "D6: no patch files to read for trigraphs (patches/ogkm/patch-* matched nothing)"; return; }
	_pl="$_pl
$(cat "$@" | grep '^+')"
	_tri=$(printf '%s\n' "$_pl" | grep -E "$TRIGRAPH_RE" | head -1)
	[ -z "$_tri" ] || { echo "D6: a patch adds a trigraph ($_tri)"; return; }
	# the three gate functions are declared once, as externs in the lkpi file, and defined nowhere else: a definition
	# of the same name before the extern (a static stub, which the extern then agrees with) would shadow the real
	# function for every call below it.  No declarator shapes are matched (style(9) puts the type on its own line, a
	# name may be parenthesised, a function pointer, an attribute, a typedef or a comment can all sit between the
	# type and the name): every whole-token occurrence of the gate names (tests/data/gate_names.txt) in lkpi.c and
	# drv.c, after splicing, comment removal, string emptying and flattening, must be one of the pinned ones below,
	# with the pinned count.  A new call shape goes into the list on purpose.  What this cannot see (a name made by
	# token pasting) gate_ast() reads in the AST.
	cat > "$TMPD/gate-occ-lkpi.want" <<'GATE_OCC_END'
1 extern int nv_drm_pi_live_holds(void)
1 extern int nv_drm_pi_quiesce(int *held, int *kept)
1 extern void nv_drm_pi_keep(void)
1 if (nv_drm_pi_live_holds() > 0)
1 nv_drm_pi_keep()
1 case MOD_QUIESCE: if (nv_drm_pi_quiesce(&held, &kept) != 0)
1 case MOD_UNLOAD: if (nv_drm_pi_quiesce(&held, &kept) != 0)
GATE_OCC_END
	cat > "$TMPD/gate-occ-drv.want" <<'GATE_OCC_END'
1 if (nv_drm_pi_live_holds() > 0)
1 NV_DRM_LOG_ERR("" "" "" "" "", nv_drm_pi_live_holds())
1 nv_drm_pi_keep()
GATE_OCC_END
	gate_occurrences "$_t/$LKPI" > "$TMPD/gate-occ-lkpi.txt" || { echo "D6: the gate names cannot be read from $GATE_NAMES"; return; }
	gate_occurrences "$_t/$DRV" > "$TMPD/gate-occ-drv.txt" || { echo "D6: the gate names cannot be read from $GATE_NAMES"; return; }
	cmp -s "$TMPD/gate-occ-lkpi.txt" "$TMPD/gate-occ-lkpi.want" || { echo "D6: the uses of the gate names in $LKPI are not the pinned list: $(diff "$TMPD/gate-occ-lkpi.want" "$TMPD/gate-occ-lkpi.txt" | head -3 | tr '\n' ' ')"; return; }
	cmp -s "$TMPD/gate-occ-drv.txt" "$TMPD/gate-occ-drv.want" || { echo "D6: the uses of the gate names in $DRV are not the pinned list: $(diff "$TMPD/gate-occ-drv.want" "$TMPD/gate-occ-drv.txt" | head -3 | tr '\n' ' ')"; return; }
	# D6 behaviour: the REAL functions of the patched sources, compiled against the core with stubs
	# (tests/data/nvidia_drm_glue_harness.c): the spin lock is a flag the gate decisions assert, the GEM
	# reference, the device destroy and the pdev detach are counters.
	_g="$TMPD/glue"; rm -rf "$_g"; mkdir -p "$_g"
	strip_comments "$_t/$DMABUF" "$_g/dma-nocomment.c"
	grep -E '^static (struct gb10_pi_gate __nv_drm_pi_gate;|DEFINE_SPINLOCK\(__nv_drm_pi_gate_lock\);)' "$_g/dma-nocomment.c" > "$_g/glue_decls.h"
	[ "$(wc -l < "$_g/glue_decls.h" | tr -d ' ')" = 2 ] || { echo "D6: the gate and its lock are not declared as the harness expects"; return; }
	: > "$_g/glue_funcs.h"
	# the list is "<file> <function>[|<return type line>]": the extractor starts at the line that holds the
	# function name, so a type written on the line before it is given after the bar
	for _fn in "$DMABUF nv_drm_pi_live_holds" "$DMABUF nv_drm_pi_quiesce" "$DMABUF nv_drm_pi_keep" "$DMABUF __nv_drm_gem_dma_buf_pi_hold" "$DMABUF __nv_drm_gem_dma_buf_pi_release" "$LKPI nv_drm_pi_guard_handler|static int" "$LKPI nv_bsd_drm_exit" "$DRV nv_drm_remove_devices"; do
		_pre=${_fn#*|}; [ "$_pre" = "$_fn" ] && _pre=
		_fn=${_fn%%|*}
		_file=${_fn% *}; _name=${_fn#* }
		body "$_t/$_file" "$_name" "$_g/one.c" || { echo "D6: the harness cannot extract $_name"; return; }
		if head -1 "$_g/one.c" | grep -Eq "^[[:space:]]*$_name[[:space:]]*\("; then printf '%s\n' "$_pre" >> "$_g/glue_funcs.h"; fi
		cat "$_g/one.c" >> "$_g/glue_funcs.h"
		echo >> "$_g/glue_funcs.h"
	done
	cc -std=gnu11 -w -I"$repo/src/gb10-pageimport" -I"$_g" -o "$_g/harness" "$repo/tests/data/nvidia_drm_glue_harness.c" 2> "$_g/cc.err" || { echo "D6: the glue harness does not compile against these sources: $(head -2 "$_g/cc.err" | tr '\n' ' ')"; return; }
	"$_g/harness" > "$_g/out.txt" 2>&1
	_gf=$(grep '^FAIL' "$_g/out.txt" | head -1)
	[ -z "$_gf" ] || { echo "D6 behaviour: ${_gf#FAIL }"; return; }
	grep -q '^glue ok' "$_g/out.txt" || { echo "D6: the glue harness did not finish: $(tail -1 "$_g/out.txt")"; return; }
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
	strip_comments "$_t/$LKPI" "$TMPD/lkpi-nocomment.c"
	tr '\n' ' ' < "$TMPD/lkpi-nocomment.c" > "$TMPD/lkpi-flat.c"
	[ "$(grep -o 'DECLARE_MODULE(nvidia_drm_pi_guard,' "$TMPD/lkpi-flat.c" | wc -l | tr -d ' ')" = 1 ] || { echo "D6: the guard module is not declared exactly once outside comments"; return; }
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
	tr '\n' ' ' < "$TMPD/g6.c" | grep -Eq 'case MOD_QUIESCE:[[:space:]]*if \(nv_drm_pi_quiesce\(&held, &kept\) != 0\) \{.*return EBUSY;[[:space:]]*\}[[:space:]]*return 0;[[:space:]]*case MOD_UNLOAD:.*if \(nv_drm_pi_quiesce\(&held, &kept\) != 0\) \{.*return EBUSY;' || { echo "D6: MOD_QUIESCE does not take the gate and MOD_UNLOAD does not refuse while an export is held"; return; }
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
	# the AST of the two sources, last because it parses them with the module's flags (about a second each); the
	# answer must be the word AST-OK, so a check that died before it is a defect and never reads as clean
	_ast=$(gate_ast_both "$_t")
	[ "$_ast" = AST-OK ] || { echo "${_ast:-D6: the AST check of the gate names printed nothing}"; return; }
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
	mkdir -p "$TMPD/good/_core"; cp "$repo/src/gb10-pageimport/gb10_pageimport.h" "$TMPD/good/_core/"
	r=$(check_tree "$TMPD/good")
	[ -z "$r" ] && ok "the patched sources pass every check" || bad "patched sources: $r"
else
	bad "the patches do not apply: $r"
fi
# The order of the guard in the module file the kit stages (PRIME_KO: the staged nvidia-drm.ko, not a build
# tree): the sysinit words are read from the file, for both modules it declares.  The unload order is the reverse of the load order, so the guard must have the
# same subsystem and a strictly greater order than the driver module.
check_ko_order() {
	[ -n "${PRIME_KO:-}" ] || { echo SKIP; return; }
	[ -f "$PRIME_KO" ] || { echo "PRIME_KO is set to $PRIME_KO, which is not a file"; return; }
	python3 -I -B "$repo/tests/prime-import-testboot/ko_sysinit_order.py" --check "$PRIME_KO" > "$TMPD/ko-order.txt" 2>&1 || { echo "the staged nvidia-drm.ko: $(head -2 "$TMPD/ko-order.txt" | tr '\n' ' ')"; return; }
}
_pyt=$(python3 -I -B - "$repo/tests/prime-import-testboot/ko_sysinit_order.py" <<'PYT'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("k", sys.argv[1])
k = importlib.util.module_from_spec(spec)
spec.loader.exec_module(k)
D, ANY, LAST = 0x3100000, 0xf000000, 0xfffffff
c = k.check
good = c([("nvidia_drm", D, ANY), ("nvidia_drm_pi_guard", D, LAST)]) is None
bad = [c([("nvidia_drm", D, ANY), ("nvidia_drm_pi_guard", D, ANY)]),
       c([("nvidia_drm", D, LAST), ("nvidia_drm_pi_guard", D, ANY)]),
       c([("nvidia_drm", D, ANY), ("nvidia_drm_pi_guard", D - 1, LAST)]),
       c([("nvidia_drm", D, ANY)]),
       c([("nvidia_drm_pi_guard", D, LAST)])]
print("ok" if good and all(bad) else "wrong: %r %r" % (good, bad))
PYT
)
[ "$_pyt" = ok ] && ok "the module order check accepts the guard after the driver and refuses an equal order, the reverse order, another subsystem and a missing module" || bad "the module order check: $_pyt"
r=$(check_ko_order)
case $r in
SKIP) echo "SKIP: PRIME_KO is not set: the unload order of the staged nvidia-drm.ko is not checked by this test (make-be.sh checks it before it clones, and the boot kit with kldstat -v). Set PRIME_KO=<staged nvidia-drm.ko> to run it." ;;
"") ok "the staged nvidia-drm.ko declares the guard in the same subsystem and with a greater order than the driver module (it loads last and unloads first)" ;;
*) bad "$r" ;;
esac
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
# mutant <name> <file under the tree> <sed script> [message]: with a message, the refusal must contain it (the
# layer that was meant to see the mutant is the one that does)
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
	if [ -z "$r" ]; then
		bad "control: mutant $1 passed"
	else
		case $r in
		*"${4:-}"*) ok "control: mutant $1 is flagged ($r)" ;;
		*) bad "control: mutant $1 is flagged by another check than the one meant to see it ($4): $r" ;;
		esac
	fi
}

# ast_mutant <name> <file under the tree> <sed script> <message>: the AST check alone (the text checks are not
# run), on one mutated source; it must refuse with a message that contains <message>
ast_mutant() {
	_m="$TMPD/a-$1"
	rm -rf "$_m"
	cp -R "$TMPD/good" "$_m" || { bad "control ast $1: cannot copy the tree"; return; }
	sed -e "$3" "$TMPD/good/$2" > "$_m/$2"
	if cmp -s "$TMPD/good/$2" "$_m/$2"; then
		bad "control ast $1: the mutation changed nothing (stale test)"
		return
	fi
	r=$(gate_ast_both "$_m")
	case $r in
	*"$4"*) ok "control: the AST check refuses mutant $1 ($r)" ;;
	AST-OK) bad "control: the AST check passed mutant $1" ;;
	*) bad "control: the AST check refuses mutant $1 with another message than $4: $r" ;;
	esac
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
	mutant unload-unload-does-not-close $LKPI '/^    case MOD_UNLOAD:/,/^    default:/s/if (nv_drm_pi_quiesce(&held, &kept) != 0) {/if (nv_drm_pi_live_holds() > 0) {/'
	mutant unload-module-counts-down $DMABUF '/^static void __nv_drm_gem_dma_buf_pi_release/,/^}/s/nv_drm_gem_object_unreference_unlocked(nv_gem);/nv_drm_gem_object_unreference_unlocked(nv_gem); gb10_pi_gate_drop(\&__nv_drm_pi_gate);/'
	mutant unload-no-gate-on-desc $DMABUF 's/nv_dma_buf->pi_desc.gate = &__nv_drm_pi_gate;//'
	mutant unload-quiesce-ignores-gate $DMABUF 's/rc = gb10_pi_gate_quiesce(&__nv_drm_pi_gate);/rc = 0;/'
	mutant unload-quiesce-ok $LKPI 's/if (nv_drm_pi_quiesce(&held, &kept) != 0) {/if (0) {/'
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
	mutant remove-devices-keep-then-fall-through $DRV 's/^        nv_drm_pi_keep();/        nv_drm_pi_keep(); if (0)/'
	mutant exit-keep-then-fall-through $LKPI 's/^        nv_drm_pi_keep();/        nv_drm_pi_keep(); if (0)/'
	mutant quiesce-forgets-rc $DMABUF 's/^    rc = gb10_pi_gate_quiesce(&__nv_drm_pi_gate);/    rc = gb10_pi_gate_quiesce(\&__nv_drm_pi_gate); rc = 0;/'
	mutant quiesce-never-closes $DMABUF '/^int nv_drm_pi_quiesce/,/^}/s/rc = gb10_pi_gate_quiesce(&__nv_drm_pi_gate);/rc = 0;/'
	mutant hold-after-closing $DMABUF '/^static int __nv_drm_gem_dma_buf_pi_hold/,/^}/s/rc = gb10_pi_gate_hold(&__nv_drm_pi_gate);/rc = 0;/'
	mutant pp-define-gate-quiesce $DMABUF 's/^static struct gb10_pi_gate __nv_drm_pi_gate;/#define gb10_pi_gate_quiesce(g) (0)\
&/'
	mutant pp-define-si-order $LKPI 's/^extern int nv_drm_pi_live_holds(void);/#define SI_ORDER_LAST SI_ORDER_FIRST\
&/'
	mutant pp-define-quiesce $LKPI 's/^extern int nv_drm_pi_live_holds(void);/#define nv_drm_pi_quiesce(h, k) (*(h) = 0, *(k) = 0, 0)\
&/'
	mutant pp-digraph-define $LKPI 's/^extern int nv_drm_pi_live_holds(void);/%:define SI_ORDER_LAST SI_ORDER_FIRST\
&/'
	mutant pp-comment-then-define $LKPI 's/^extern int nv_drm_pi_live_holds(void);/\/* x *\/ #define SI_ORDER_LAST SI_ORDER_FIRST\
&/'
	mutant live-holds-forgets-kept $DMABUF 's/if (n == 0 \&\& __atomic_load_n(&__nv_drm_pi_gate.kept, __ATOMIC_SEQ_CST))/if (0)/'
	mutant pp-splice-digraph $LKPI '/^extern int nv_drm_pi_live_holds(void);/s/.*/%\\\
:define SI_ORDER_LAST SI_ORDER_FIRST\
&/'
	mutant gate-static-shadow $LKPI '/^extern int nv_drm_pi_live_holds(void);/s/.*/static int nv_drm_pi_quiesce(int *h, int *k) { *h = 0; *k = 0; return 0; }\
&/'
	mutant gate-static-shadow-indented $LKPI '/^extern int nv_drm_pi_live_holds(void);/s/.*/\	static int nv_drm_pi_quiesce(int *h, int *k) { *h = 0; *k = 0; return 0; }\
&/'
	mutant gate-static-shadow-spliced $LKPI '/^extern int nv_drm_pi_live_holds(void);/s/.*/static int nv_drm_pi_qui\\\
esce(int *h, int *k) { *h = 0; *k = 0; return 0; }\
&/'
	# shadows of a gate function in every shape the declarator can take (style(9) line break, parenthesised name,
	# function-pointer alias, attribute, typedef'd type, comment, a parameter, a trigraph, a name built by token
	# pasting).  Each is valid C that compiles, and each must be refused by the layer named in the last argument
	# (the message of that layer): the text scan of the occurrences, or the trigraph refusal.  The pasted name is
	# invisible to both and reaches the AST check, which is last.  The AST check is also run alone, below.
	mutant gate-static-shadow-style9 $LKPI '/^extern int nv_drm_pi_live_holds(void);/s/.*/static int\
nv_drm_pi_quiesce(int *h, int *k) { *h = 0; *k = 0; return 0; }\
&/' 'are not the pinned list'
	mutant gate-static-shadow-paren $LKPI '/^extern int nv_drm_pi_live_holds(void);/s/.*/static int (nv_drm_pi_quiesce)(int *h, int *k) { *h = 0; *k = 0; return 0; }\
&/' 'are not the pinned list'
	mutant gate-fnptr-alias $LKPI '/^extern int nv_drm_pi_quiesce(int \*held, int \*kept);/s/.*/static int gate_s(int *h, int *k) { *h = 0; *k = 0; return 0; }\
static int (*const nv_drm_pi_quiesce)(int *, int *) = gate_s;/' 'are not the pinned list'
	mutant gate-static-attr $LKPI '/^extern int nv_drm_pi_live_holds(void);/s/.*/static int __attribute__((__unused__))\
nv_drm_pi_quiesce(int *h, int *k) { *h = 0; *k = 0; return 0; }\
&/' 'are not the pinned list'
	mutant gate-typedef-ret $LKPI '/^extern int nv_drm_pi_live_holds(void);/s/.*/typedef int gate_rc_t;\
static gate_rc_t nv_drm_pi_quiesce(int *h, int *k) { *h = 0; *k = 0; return 0; }\
&/' 'are not the pinned list'
	mutant gate-comment-split $LKPI '/^extern int nv_drm_pi_live_holds(void);/s/.*/static int \/* x *\/ nv_drm_pi_quiesce(int *h, int *k) { *h = 0; *k = 0; return 0; }\
&/' 'are not the pinned list'
	mutant gate-name-as-parameter $LKPI '/^extern int nv_drm_pi_live_holds(void);/s/.*/static int gate_p(int nv_drm_pi_quiesce) { return nv_drm_pi_quiesce; }\
&/' 'are not the pinned list'
	mutant gate-name-as-parameter-drv $DRV '/^void nv_drm_remove_devices/s/.*/static int gate_dp(int nv_drm_pi_keep) { return nv_drm_pi_keep; }\
&/' 'are not the pinned list'
	mutant gate-pasted-name $LKPI '/^extern int nv_drm_pi_live_holds(void);/s/.*/static int __CONCAT(nv_drm_pi_, quiesce)(int *h, int *k) { *h = 0; *k = 0; return 0; }\
&/' 'is static, not an external declaration'
	mutant gate-second-use-in-log $DRV 's/^                       nv_drm_pi_live_holds());/                       nv_drm_pi_live_holds() + nv_drm_pi_live_holds());/' 'are not the pinned list'
	mutant pp-trigraph $LKPI '/^extern int nv_drm_pi_live_holds(void);/s/.*/??=define nv_drm_pi_quiesce(h, k) (*(h) = 0, *(k) = 0, 0)\
&/' 'add a trigraph'
	# the AST check alone, on the tree with the pinned list not consulted: each branch of tests/data/gate_ast_check.py
	# has a source that only it refuses (the last argument is its message)
	ast_mutant style9 $LKPI '/^extern int nv_drm_pi_live_holds(void);/s/.*/static int\
nv_drm_pi_quiesce(int *h, int *k) { *h = 0; *k = 0; return 0; }\
&/' 'is static, not an external declaration'
	ast_mutant paren $LKPI '/^extern int nv_drm_pi_live_holds(void);/s/.*/static int (nv_drm_pi_quiesce)(int *h, int *k) { *h = 0; *k = 0; return 0; }\
&/' 'is static, not an external declaration'
	ast_mutant attr $LKPI '/^extern int nv_drm_pi_live_holds(void);/s/.*/static int __attribute__((__unused__))\
nv_drm_pi_quiesce(int *h, int *k) { *h = 0; *k = 0; return 0; }\
&/' 'is static, not an external declaration'
	ast_mutant typedef-ret $LKPI '/^extern int nv_drm_pi_live_holds(void);/s/.*/typedef int gate_rc_t;\
static gate_rc_t nv_drm_pi_quiesce(int *h, int *k) { *h = 0; *k = 0; return 0; }\
&/' 'is static, not an external declaration'
	ast_mutant comment-split $LKPI '/^extern int nv_drm_pi_live_holds(void);/s/.*/static int \/* x *\/ nv_drm_pi_quiesce(int *h, int *k) { *h = 0; *k = 0; return 0; }\
&/' 'is static, not an external declaration'
	ast_mutant pasted-name $LKPI '/^extern int nv_drm_pi_live_holds(void);/s/.*/static int __CONCAT(nv_drm_pi_, quiesce)(int *h, int *k) { *h = 0; *k = 0; return 0; }\
&/' 'nvidia-drm-freebsd-lkpi.c:217 FunctionDecl nv_drm_pi_quiesce: is static'
	ast_mutant fnptr-alias $LKPI '/^extern int nv_drm_pi_quiesce(int \*held, int \*kept);/s/.*/static int gate_s(int *h, int *k) { *h = 0; *k = 0; return 0; }\
static int (*const nv_drm_pi_quiesce)(int *, int *) = gate_s;/' 'is not a function declaration'
	ast_mutant parameter $LKPI '/^extern int nv_drm_pi_live_holds(void);/s/.*/static int gate_p(int nv_drm_pi_quiesce) { return nv_drm_pi_quiesce; }\
&/' 'ParmVarDecl nv_drm_pi_quiesce: is not a function declaration'
	ast_mutant pasted-parameter $LKPI '/^extern int nv_drm_pi_live_holds(void);/s/.*/static int gate_p(int __CONCAT(nv_drm_pi_, quiesce)) { return 0; }\
&/' 'ParmVarDecl nv_drm_pi_quiesce: is not a function declaration'
	ast_mutant parameter-drv $DRV '/^void nv_drm_remove_devices/s/.*/static int gate_dp(int nv_drm_pi_keep) { return nv_drm_pi_keep; }\
&/' 'nvidia-drm-drv.c:2193 ParmVarDecl nv_drm_pi_keep'
	ast_mutant wrong-type $LKPI '/^extern int nv_drm_pi_live_holds(void);/s/int/long/' "has type 'long (void)', expected 'int (void)'"
	ast_mutant attributed-extern $LKPI '/^extern int nv_drm_pi_live_holds(void);/s/(void);/(void) __attribute__((__weak__));/' 'has a body or an attribute'
	ast_mutant extern-with-body $LKPI '/^extern void nv_drm_pi_keep(void);/s/.*/extern void nv_drm_pi_keep(void) { }/' 'has a body or an attribute'
	ast_mutant renamed-by-macro $LKPI '/^extern int nv_drm_pi_live_holds(void);/s/.*/#define nv_drm_pi_keep nv_drm_pi_keep_x\
&/' 'no external declaration of nv_drm_pi_keep'
	mutant pp-splice-digraph-ws $LKPI '/^extern int nv_drm_pi_live_holds(void);/s/.*/%\\ \
:define SI_ORDER_LAST SI_ORDER_FIRST\
&/'
	mutant core-define-under-kernel _core/gb10_pageimport.h '/^#endif \/\* _GB10_PAGEIMPORT_H_ \*\//s/.*/#ifdef _KERNEL\
#define gb10_pi_gate_quiesce(g) (0)\
#endif\
&/'
	mutant pp-if0-decoy $DMABUF 's/^int nv_drm_pi_quiesce(int \*held, int \*kept)$/#if 0\
int nv_drm_pi_quiesce(int *held, int *kept) { *held = 0; *kept = 0; return 0; }\
#endif\
&/'
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

# the gate check never skips and never reads a failure as clean
r=$(PATH=/nonexistent gate_ast "$TMPD/good" nvidia-drm-drv.c)
case $r in *"clang is not installed"*) ok "the AST check fails when clang is missing (it does not skip)" ;; *) bad "no clang: $r" ;; esac
r=$(PRIME_BUILD_TREE=/nonexistent gate_ast "$TMPD/good" nvidia-drm-drv.c)
case $r in *"no prepared nvidia-drm build tree"*) ok "the AST check fails when there is no prepared build tree (it does not skip)" ;; *) bad "no build tree: $r" ;; esac
r=$(PRIME_BUILD_TREE= WORK= gate_ast "$TMPD/good" nvidia-drm-drv.c)
case $r in AST-OK) bad "an empty build tree path passed the AST check" ;; *"D6:"*) ok "the AST check fails when the build tree path is empty" ;; *) bad "empty build tree: $r" ;; esac
_gl='cc  -O2 -DNV_VERSION_STRING=\"580.178.04\" -DKBUILD_MODNAME='"'"'"nvidia-drm"'"'"' -Imachine -I../common/inc -std=gnu17 -c nvidia-drm-drv.c -o nvidia-drm-drv.o'
_gok=1
gate_line_safe "$_gl" || _gok=0
for _gbad in "$_gl; rm -rf x" "$_gl | tee y" "$_gl > z" "$_gl \`id\`" "$_gl \$(id)" "$_gl & id" "ld -o x" "$_gl
rm -rf x"; do
	gate_line_safe "$_gbad" && _gok=0
done
[ "$_gok" -eq 1 ] && ok "a compile line of plain words is run; one with a separator, pipe, redirection, substitution, a newline or another command is not" || bad "the compile line filter accepts or refuses the wrong lines"
# a reworded log message is not a gate change (the pin holds the shape of the statement, not its strings)
sed 's/an earlier teardown already kept the devices/an earlier teardown kept the devices/' "$TMPD/good/$DRV" > "$TMPD/reworded-drv.c"
gate_occurrences "$TMPD/reworded-drv.c" > "$TMPD/reworded-occ.txt"; gate_occurrences "$TMPD/good/$DRV" > "$TMPD/good-occ.txt"
if ! cmp -s "$TMPD/reworded-drv.c" "$TMPD/good/$DRV" && cmp -s "$TMPD/reworded-occ.txt" "$TMPD/good-occ.txt"; then ok "rewording the log message that carries a gate call changes no pinned occurrence"; else bad "a reworded log message changes the pinned occurrences"; fi
# a bad name in the names file is refused, not read as no names
r=$(GATE_NAMES=/nonexistent/names gate_occurrences "$TMPD/good/$LKPI") && bad "gate_occurrences accepted a missing names file" || ok "a missing gate names file is an error, not an empty list"


echo "passed: $passed failed: $failed"
[ "$failed" -eq 0 ]
