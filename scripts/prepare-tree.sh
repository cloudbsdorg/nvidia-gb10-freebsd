#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# prepare-tree.sh - build the port working tree: NVIDIA's pristine src/ plus
# ports-style patches (one unified diff per changed source file).
#
# Usage: scripts/prepare-tree.sh [TREE]
#   TREE      working tree to build; defaults to
#             ${GB10_WORK:-$HOME/work/gb10}/build/tree
#
# Environment:
#   GB10_WORK work root holding sources/ and the default TREE
#   GB10_TEST_HOOKS
#             set to 1 to let the two test hooks below be taken from the
#             environment; without it they are ignored and the repo's own
#             files are used
#   PATCHES   test hook: directory of patch-* files; defaults to <repo>/patches
#   SOURCES   test hook: pin file with nvidia_freebsd_sha256; defaults to
#             <repo>/SOURCES
#
# A hook in use must be one word of [A-Za-z0-9_./-] and is announced on
# stderr as "prepare-tree: test hook <NAME> in use".
#
# The source tarball is
# ${GB10_WORK}/sources/NVIDIA-FreeBSD-x86_64-580.178.04.tar.xz (fetched and
# checksum-verified by scripts/fetch-sources.sh); this script re-verifies its
# sha256 against SOURCES before extracting, and exits 1 on a mismatch without
# touching TREE. Only <topdir>/src/ and <topdir>/firmware/ are extracted:
# src/ with two leading components stripped, so the tree holds TREE/nvidia,
# TREE/common, ..., and firmware/ with one stripped, so the tree holds
# TREE/firmware/gsp_ga10x (the GSP firmware images and their firmware(9)
# kmod Makefiles). Every run rebuilds
# from scratch: TREE must be a real directory strictly under $WORK/build
# (never $WORK/build itself, never a symlink - safe_build_dir in
# scripts/lib.sh checks before anything is written or deleted), an existing
# TREE is replaced only when its .prepared marker's first line names this
# script and that exact resolved path, and patches are applied in lexical
# order after a header check refuses any patch whose ---/+++ paths are
# absolute or hold a .. component. A patch directory that does not exist is
# refused outright: the glob would stay literal, every patch would be
# silently skipped, and a patch-less tree would be reported complete.
# TREE/.prepared line 1 is
# "gb10 prepare-tree.sh <resolved path>" and line 2 "state building" while
# the run is in flight; at the very end it is rewritten via a temp file and
# mv(1) to "state done" followed by each
# applied patch's name and sha256, and after the patches the repo's own
# src/ additions are copied in and recorded the same way (copy_repo_src
# below): the arm64 PCIe BAR memory-attribute policy header to
# TREE/nvidia/gb10_memattr.h, so the patched nvidia_os.c and nvidia_subr.c
# can #include "gb10_memattr.h" with no Makefile change; the UVM interface
# glue (src/gb10-uvm) and the three MIT interface headers it needs from the
# open RM core checkout, all to TREE/nvidia/; and
# src/gb10-pageimport/gb10_pageimport.h (the
# cross-GPU import core) to TREE/common/inc/gb10_pageimport.h, which
# nvidia.ko and nvidia-drm.ko both find through -I../common/inc.
# Nothing is written outside TREE and /tmp is never used.

set -eu

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

TOPDIR=NVIDIA-FreeBSD-x86_64-580.178.04
WORK=${GB10_WORK:-$HOME/work/gb10}
TARBALL=$WORK/sources/$TOPDIR.tar.xz

SCRIPTDIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$SCRIPTDIR/.." && pwd)
. "$SCRIPTDIR/lib.sh"
# PATCHES and SOURCES decide what is applied and which pin the tarball is
# verified against, so they are test hooks: taken from the environment only
# with GB10_TEST_HOOKS=1, validated and announced by test_hook. Without it
# the repo's own files are used, whatever the environment says.
PATCHDIR=$(test_hook prepare-tree PATCHES "$REPO/patches") || exit 1
SOURCESFILE=$(test_hook prepare-tree SOURCES "$REPO/SOURCES") || exit 1

if [ $# -gt 1 ]; then
	echo "usage: prepare-tree.sh [TREE]" >&2
	exit 1
fi

TREE=${1:-$WORK/build/tree}
# Path safety first, before anything is read, written or deleted: TREE must
# resolve to a real directory strictly under $WORK/build (never equal to it),
# must not be a symlink, and must carry the .prepared marker if it already
# exists (scripts/lib.sh). A string match on "/" cannot tell $WORK/build
# itself, a '//' spelling or a symlinked escape from a real build tree;
# realpath can.
safe_build_dir "$TREE" .prepared || exit 1

if [ ! -f "$TARBALL" ]; then
	echo "run scripts/fetch-sources.sh first" >&2
	exit 1
fi

# Re-verify the tarball against SOURCES before touching TREE.
if [ ! -f "$SOURCESFILE" ]; then
	echo "prepare-tree: missing SOURCES file: $SOURCESFILE" >&2
	exit 1
fi
want_sha=$(sources_get "$SOURCESFILE" nvidia_freebsd_sha256) || {
	echo "prepare-tree: SOURCES: no nvidia_freebsd_sha256" >&2
	exit 1
}
got_sha=$(sha256 -q "$TARBALL")
if [ "$got_sha" != "$want_sha" ]; then
	echo "prepare-tree: sha256 mismatch for $TARBALL: expected $want_sha got $got_sha" >&2
	exit 1
fi

# apply_patches - for every $PATCHDIR/patch-* in lexical order (LC_ALL=C
# globbing): refuse a patch whose ---/+++ header paths are absolute or hold
# a .. component (patch -p0 would follow them out of TREE), apply it to
# TREE, and record its name and sha256 in the manifest temp file that
# finalize_marker folds into .prepared. On the first failure, name the
# patch and exit 1. A PATCHDIR that does not exist is refused before the
# loop: the glob would stay literal, `[ -e "$p" ]` would skip it, and the
# run would report a patch-less tree as complete (an empty but EXISTING
# PATCHDIR stays legal - zero patches is a valid configuration, a missing
# directory is a mistake).
# Time:  O(P) patch(1) + sha256(1) runs for P patch files; each header scan
#        is linear in the patch file's lines, each patch run linear in the
#        size of the file it patches (patch(1) internals).
# Space: O(P) lines accumulated in the manifest temp file.
apply_patches() {
	if [ ! -d "$PATCHDIR" ]; then
		echo "prepare-tree: PATCHDIR does not exist: $PATCHDIR" >&2
		exit 1
	fi
	: > "$TREE/.prepared.patches"
	for p in "$PATCHDIR"/patch-*; do
		[ -e "$p" ] || continue
		if ! patch_headers_safe "$p"; then
			echo "prepare-tree: refusing patch $(basename "$p"): ---/+++ path is absolute or holds a .. component" >&2
			exit 1
		fi
		if ! patch -d "$TREE" -p0 -E -s -i "$p"; then
			echo "prepare-tree: patch failed: $(basename "$p")" >&2
			exit 1
		fi
		printf '%s  %s\n' "$(basename "$p")" "$(sha256 -q "$p")" \
		    >> "$TREE/.prepared.patches"
	done
}

# copy_repo_src - copy the repo's own source additions into TREE and record
# each in the manifest temp file that finalize_marker folds into .prepared.
# The arm64 BAR memory-attribute policy header (src/gb10-memattr) and the
# UVM interface of the OS layer (src/gb10-uvm, built into nvidia.ko through
# patch-nvidia_nvidia-sources.mk) go to TREE/nvidia/ beside the sources that
# include them. The UVM glue also needs three of the open RM core's own
# MIT-licensed interface headers that NVIDIA's FreeBSD tarball does not ship
# (nv_uvm_types.h, nv_uvm_user_types.h, nvgputypes.h): they are copied from
# the pinned open-gpu-kernel-modules checkout that scripts/fetch-sources.sh
# verified, and recorded in the manifest as "ogkm:<path in that checkout>"
# so tests/kmod_symbols_test.sh can re-hash them. The cross-GPU import core
# header goes to TREE/common/inc/, and its FreeBSD side gb10_pageimport_os.c
# to TREE/nvidia/. A missing file fails the run loudly (set -e): silently
# skipping it would only break the build later in a less obvious way.
# Time:  O(F) copy and sha256 runs for F added files.
# Space: O(F) manifest lines.
copy_repo_src() {
	_ogkm=$WORK/sources/open-gpu-kernel-modules-580.178.04
	mkdir -p "$TREE/nvidia"
	for _f in src/gb10-memattr/gb10_memattr.h \
	    src/gb10-uvm/nv-uvm-interface.h src/gb10-uvm/nv-uvm-interface.c; do
		cp "$REPO/$_f" "$TREE/nvidia/$(basename "$_f")"
		printf '%s  %s\n' "$_f" "$(sha256 -q "$REPO/$_f")" \
		    >> "$TREE/.prepared.patches"
	done
	for _f in src/nvidia/interface/nv_uvm_types.h \
	    src/nvidia/interface/nv_uvm_user_types.h \
	    src/common/sdk/nvidia/inc/nvgputypes.h; do
		if [ ! -f "$_ogkm/$_f" ]; then
			echo "prepare-tree: missing $_ogkm/$_f (run scripts/fetch-sources.sh)" >&2
			exit 1
		fi
		cp "$_ogkm/$_f" "$TREE/nvidia/$(basename "$_f")"
		printf 'ogkm:%s  %s\n' "$_f" "$(sha256 -q "$_ogkm/$_f")" \
		    >> "$TREE/.prepared.patches"
	done
	# The cross-GPU import core (docs/PRIME-IMPORT.md): both nvidia.ko and
	# nvidia-drm.ko include it, and both are built with -I../common/inc.
	mkdir -p "$TREE/common/inc"
	cp "$REPO/src/gb10-pageimport/gb10_pageimport.h" \
	    "$TREE/common/inc/gb10_pageimport.h"
	printf '%s  %s\n' "src/gb10-pageimport/gb10_pageimport.h" \
	    "$(sha256 -q "$REPO/src/gb10-pageimport/gb10_pageimport.h")" \
	    >> "$TREE/.prepared.patches"
	# Its FreeBSD side, our own BSD-licensed file (not NVIDIA's); the
	# nvidia/Makefile patch adds it to SRCS.
	cp "$REPO/src/gb10-pageimport/gb10_pageimport_os.c" \
	    "$TREE/nvidia/gb10_pageimport_os.c"
	printf '%s  %s\n' "src/gb10-pageimport/gb10_pageimport_os.c" \
	    "$(sha256 -q "$REPO/src/gb10-pageimport/gb10_pageimport_os.c")" \
	    >> "$TREE/.prepared.patches"
}

# finalize_marker - rewrite TREE/.prepared at the very end: the gb10 marker
# line, "state done", then the applied-patch manifest, via a temp file and
# mv(1) in the same directory, so a concurrent reader (build-shim.sh) never
# sees a half-written marker and "state done" only ever appears on a
# complete tree.
# Time:  O(P) manifest lines copied once.
# Space: O(P) lines in the temp file.
finalize_marker() {
	{
		printf 'gb10 prepare-tree.sh %s\n' "$TREER"
		printf 'state done\n'
		cat "$TREE/.prepared.patches"
	} > "$TREE/.prepared.new"
	rm -f "$TREE/.prepared.patches"
	mv "$TREE/.prepared.new" "$TREE/.prepared"
}

# Replace an existing TREE only if this script made it: safe_build_dir
# verified the .prepared marker file is there; its first line must name
# this script and this exact resolved path, or the tree is left untouched.
if [ -e "$TREE" ]; then
	TREER=$(realpath "$TREE" 2>/dev/null) || TREER=
	first=$(head -n 1 "$TREE/.prepared" 2>/dev/null) || first=
	if [ "$first" != "gb10 prepare-tree.sh $TREER" ]; then
		echo "prepare-tree: refusing to replace $TREE: .prepared does not begin with 'gb10 prepare-tree.sh $TREER'" >&2
		exit 1
	fi
	rm -rf "$TREE"
fi
mkdir -p "$TREE"
TREER=$(realpath "$TREE") || {
	echo "prepare-tree: cannot resolve $TREE" >&2
	exit 1
}
# Mark the tree first, so an interrupted run can still be replaced: line 1
# says who wrote the marker and where it stands, line 2 says "state
# building". finalize_marker rewrites both, plus the patch manifest, via a
# temp file and mv(1) at the very end.
printf 'gb10 prepare-tree.sh %s\nstate building\n' "$TREER" > "$TREE/.prepared"
TMPDIR=$TREE # keep any patch(1) scratch inside TREE; never /tmp
export TMPDIR

tar -xJf "$TARBALL" -C "$TREE" --strip-components 2 "$TOPDIR/src/"
# firmware/ keeps its own directory name: strip only the top directory.
tar -xJf "$TARBALL" -C "$TREE" --strip-components 1 "$TOPDIR/firmware/"
apply_patches
copy_repo_src
finalize_marker

echo "prepare-tree: $TREE ready"
