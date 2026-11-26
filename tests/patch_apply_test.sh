#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# patch_apply_test.sh - every patch in the repository applies to the
# pristine sources it names.
#
# The control device is a patch to NVIDIA's nvidia_ctl.c.  If its hunk
# header is wrong, or its context does not match the file it names, the
# tree that scripts/prepare-tree.sh builds is not the tree the journal
# describes, and nothing in the repository notices: the tests that read
# the patch read its text, and a text check cannot tell a patch that
# applies from one that does not.
#
# The test applies every patch, in the order the build applies them, to a
# scratch tree that holds the pristine files the patches touch.  A patch
# that does not apply is named and the test fails.  The test then runs
# the same check against a copy of the control device patch with a broken
# hunk header, which must fail: a check that cannot fail is not a check.
#
# Usage: sh tests/patch_apply_test.sh
#   The pristine sources are needed (scripts/fetch-sources.sh); the test
#   does not extract the tarball.
# Exit: 0 every patch applies, 1 otherwise.

set -u
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

TESTSDIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$TESTSDIR/.." && pwd)
. "$REPO/scripts/lib.sh"
WORK=${GB10_WORK:-$(CDPATH= cd -- "$TESTSDIR/.." && pwd -P)/work}
ver=$(sources_get "$REPO/SOURCES" nvidia_freebsd_sha256 >/dev/null 2>&1; \
    sources_get "$REPO/SOURCES" ogkm_tag) || {
	echo "FAIL: no ogkm_tag in SOURCES"; exit 1; }
PRISTINE=$WORK/sources/NVIDIA-FreeBSD-x86_64-$ver/src
OGKM=$WORK/sources/open-gpu-kernel-modules-$ver

mkdir -p "$WORK/tmp" || exit 1
TESTROOT=$(mktemp -d "$WORK/tmp/patch-apply-test.XXXXXXXX") || exit 1
cleanup() { rm -rf "$TESTROOT"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

PASSED=0
FAILED=0

ok() { PASSED=$((PASSED + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAILED=$((FAILED + 1)); printf 'FAIL %s\n' "$1"; }

if [ ! -d "$PRISTINE" ] || [ ! -d "$OGKM" ]; then
	echo "FAIL: the pristine sources are missing (run scripts/fetch-sources.sh)" >&2
	exit 1
fi

# patch_target PATCH: the file the patch writes, with the path the patch
# gives it (no timestamp, no .orig).
patch_target() {
	awk '
	/^\+\+\+ / {
		path = substr($0, 5)
		sub(/\t.*$/, "", path)
		sub(/ .*$/, "", path)
		print path
		exit
	}' "$1"
}

# copy_target ROOT TARGET SCRATCH: the file the patch writes, copied from
# the pristine tree.  A file the patch creates is not copied: there is
# none.  A file that is already in the scratch tree is left alone: it is
# the file an earlier patch wrote, and the patch that comes now must see
# that one, not the pristine one.
copy_target() {
	[ -f "$1/$2" ] || return 0
	[ -e "$3/$2" ] && return 0
	mkdir -p "$3/$(dirname -- "$2")" || return 1
	cp "$1/$2" "$3/$2" || return 1
	return 0
}

# apply_all PATCHDIR ROOT SCRATCH: every patch of PATCHDIR, in lexical
# order, applied to SCRATCH.  Prints the name of the patch that did not
# apply and returns 1; returns 0 when they all applied.
apply_all() {
	_patchdir=$1
	_root=$2
	_scratch=$3
	for _p in "$_patchdir"/patch-*; do
		[ -e "$_p" ] || continue
		_target=$(patch_target "$_p")
		if [ -z "$_target" ]; then
			echo "$(basename "$_p") (it names no file)"
			return 1
		fi
		copy_target "$_root" "$_target" "$_scratch" || {
			echo "$(basename "$_p") (the file could not be copied)"
			return 1
		}
		if ! (cd "$_scratch" && patch -p0 -E -s -i "$_p" \
		    > "$_scratch/.patch.out" 2>&1); then
			echo "$(basename "$_p")"
			sed 's/^/    /' "$_scratch/.patch.out" >&2
			return 1
		fi
	done
	return 0
}

# corrupt_header PATCH OUT: the patch with the new count of its first
# hunk header raised by two, so the header no longer matches the hunk it
# introduces.
corrupt_header() {
	awk '
	/^@@/ && !seen {
		seen = 1
		line = $0
		if (match(line, /\+[0-9]+,[0-9]+/)) {
			p = substr(line, RSTART + 1, RLENGTH - 1)
			split(p, na, ",")
			na[2] = na[2] + 2
			print substr(line, 1, RSTART - 1) "+" na[1] "," na[2] \
			    substr(line, RSTART + RLENGTH)
			next
		}
	}
	{ print }
	' "$1" > "$2"
}

# (a) every patch applies to the pristine sources.
SCRATCH=$TESTROOT/tree
mkdir -p "$SCRATCH"
if failed=$(apply_all "$REPO/patches" "$PRISTINE" "$SCRATCH"); then
	ok "every patch of patches/ applies to the pristine sources"
else
	bad "the patch $failed does not apply to the pristine sources"
fi

SCRATCH2=$TESTROOT/ogkm
mkdir -p "$SCRATCH2"
if failed=$(apply_all "$REPO/patches/ogkm" "$OGKM" "$SCRATCH2"); then
	ok "every patch of patches/ogkm/ applies to the pinned open core"
else
	bad "the ogkm patch $failed does not apply to the pinned open core"
fi

# (b) the control device patch really did what it says: the file it
# writes holds the control device.
CTL=$SCRATCH/nvidia/nvidia_ctl.c
if [ -f "$CTL" ] && grep -q 'nvidia_ctl_dev_create' "$CTL" && \
    grep -q 'nv_ctl_state_gpu_attach' "$CTL" && \
    grep -q 'make_dev_s' "$CTL"; then
	ok "the patched nvidia_ctl.c holds the control device and the state"
else
	bad "the patched nvidia_ctl.c does not hold the control device"
fi

# (c) the check can fail: a patch with a broken hunk header does not
# apply, and the test says so.
BROKEN=$TESTROOT/broken
mkdir -p "$BROKEN/patches"
cp "$REPO"/patches/patch-* "$BROKEN/patches/" 2>/dev/null
corrupt_header "$REPO/patches/patch-zzz-2464-no-gpu_ctl.c" \
    "$BROKEN/patches/patch-zzz-2464-no-gpu_ctl.c"
SCRATCH3=$TESTROOT/tree3
mkdir -p "$SCRATCH3"
if failed=$(apply_all "$BROKEN/patches" "$PRISTINE" "$SCRATCH3"); then
	bad "a patch with a broken hunk header was accepted"
else
	if [ "$failed" = "patch-zzz-2464-no-gpu_ctl.c" ]; then
		ok "a patch with a broken hunk header is named and refused"
	else
		ok "a patch with a broken hunk header is refused (it stopped at $failed)"
	fi
fi

echo "passed: $PASSED failed: $FAILED"
if [ "$FAILED" -gt 0 ]; then
	exit 1
fi
exit 0
