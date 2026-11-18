#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# prepare-tree_test.sh - offline test for scripts/prepare-tree.sh.
#
# Builds a tiny fake tarball under an unpredictable mktemp(1) directory in
# ${GB10_WORK:-$HOME/work/gb10}/tmp (created if missing) with the
# NVIDIA top-directory layout (one file, src/nvidia/a.c), points GB10_WORK at
# the test dir, PATCHES at test patch dirs and SOURCES at a test SOURCES file
# holding the fake tarball's real sha256 (both are test hooks, so
# GB10_TEST_HOOKS=1 is exported), and checks fifteen cases. TREE must be a
# real directory strictly under $WORK/build (safe_build_dir, scripts/lib.sh),
# so every test tree lives under $TESTROOT/build/:
#   (a) no patches:        tree has nvidia/a.c, exit 0
#   (b) one good patch:    a.c is changed, patch listed in TREE/.prepared,
#                          which carries the gb10 marker line and says
#                          "state done"
#   (c) a bad patch:       exit 1 and stderr names the patch
#   (d) missing tarball:   exit 1 with "run scripts/fetch-sources.sh first"
#   (e) second run:        replaces the tree (a stale file in TREE is gone)
#   (f) foreign TREE:      existing dir without .prepared is refused, intact
#   (g) sha256 mismatch:   exit 1 before touching an existing prepared TREE
#   (h) firmware/:         tree has firmware/gsp_ga10x/gsp_ga10x.bin
#   (i) hooks disabled:    with GB10_TEST_HOOKS unset the SOURCES and
#                          PATCHES overrides are ignored, so the repo's own
#                          pin is used and the fake tarball fails it
#   (j) hook hygiene:      hooks in use are announced on stderr, and a hook
#                          value that is not one word is refused
#   (k) TREE is $WORK/build itself: refused, nothing built into it
#   (l) TREE is $WORK//build/x where x is a symlink pointing outside
#                          $WORK/build: refused, target and link untouched
#   (m) TREE/.prepared with the wrong first line: refused, tree survives
#   (n) a patch whose ---/+++ path holds a .. component: refused before
#                          applying, the file outside TREE is untouched
#   (o) PATCHES is a directory that does not exist: exit 1 naming it; the
#                          tree never reaches "state done" (before the fix
#                          the literal glob skipped every patch and the
#                          patch-less run reported success)
#
# Run: sh tests/prepare-tree_test.sh

set -eu

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

TOPDIR=NVIDIA-FreeBSD-x86_64-580.178.04
TESTSDIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SCRIPT="$TESTSDIR/../scripts/prepare-tree.sh"
# The scratch root honours GB10_WORK like the scripts do and is created if
# missing: mktemp -d fails when the parent directory does not exist, which
# would abort the suite before the first case on a fresh work root.
WORK=${GB10_WORK:-$HOME/work/gb10}
mkdir -p "$WORK/tmp"
TESTROOT=$(mktemp -d "$WORK/tmp/prep-test.XXXXXXXX") || exit 1

PASSED=0
FAILED=0

# cleanup - remove exactly this run's test root on every exit path.
# Time:  O(files created by this test).
# Space: O(1).
cleanup() {
	rm -rf "$TESTROOT"
}
# EXIT cleans up; INT/TERM exit with the conventional 128+n status, which
# then runs the EXIT trap. One combined trap list would run cleanup on INT
# without exiting and let the interrupted test carry on.
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# PATCHES and SOURCES are test hooks: prepare-tree.sh ignores them unless
# this is set (case (i) proves it).
GB10_TEST_HOOKS=1
export GB10_TEST_HOOKS

ok() {
	PASSED=$((PASSED + 1))
	printf 'ok   %s\n' "$1"
}

fail() {
	FAILED=$((FAILED + 1))
	printf 'FAIL %s\n' "$1"
}

if [ ! -f "$SCRIPT" ]; then
	fail "scripts/prepare-tree.sh does not exist"
	echo "passed: $PASSED failed: $FAILED"
	exit 1
fi

# Fake source tarball: $TOPDIR/src/nvidia/a.c and
# $TOPDIR/firmware/gsp_ga10x/gsp_ga10x.bin, same layout as NVIDIA's.
STAGE="$TESTROOT/stage"
mkdir -p "$STAGE/$TOPDIR/src/nvidia" \
	"$STAGE/$TOPDIR/firmware/gsp_ga10x" "$TESTROOT/sources"
printf 'int a(void) { return 0; }\n' > "$STAGE/$TOPDIR/src/nvidia/a.c"
printf 'fake firmware image\n' > "$STAGE/$TOPDIR/firmware/gsp_ga10x/gsp_ga10x.bin"
tar -cJf "$TESTROOT/sources/$TOPDIR.tar.xz" -C "$STAGE" "$TOPDIR"

# Test SOURCES pinning the fake tarball's real sha256, so the script's
# checksum verification passes for cases (a)-(f); (g) overrides it.
printf 'nvidia_freebsd_sha256 %s\n' \
	"$(sha256 -q "$TESTROOT/sources/$TOPDIR.tar.xz")" \
	> "$TESTROOT/SOURCES-test"
export SOURCES="$TESTROOT/SOURCES-test"

# (a) no patches: tree has nvidia/a.c, exit 0.
mkdir -p "$TESTROOT/patches-empty"
rc=0
GB10_WORK="$TESTROOT" PATCHES="$TESTROOT/patches-empty" \
	sh "$SCRIPT" "$TESTROOT/build/tree-a" >"$TESTROOT/out-a" 2>&1 || rc=$?
if [ "$rc" -eq 0 ] && [ -f "$TESTROOT/build/tree-a/nvidia/a.c" ]; then
	ok "(a) no patches: nvidia/a.c present, exit 0"
else
	fail "(a) no patches: rc=$rc out=$(cat "$TESTROOT/out-a")"
fi

# (b) one good patch changes a.c and is recorded in .prepared.
mkdir -p "$TESTROOT/orig-b/nvidia" "$TESTROOT/new-b/nvidia" "$TESTROOT/patches-b"
cp "$STAGE/$TOPDIR/src/nvidia/a.c" "$TESTROOT/orig-b/nvidia/a.c"
printf 'int a(void) { return 1; }\n' > "$TESTROOT/new-b/nvidia/a.c"
drc=0
diff -u -L nvidia/a.c -L nvidia/a.c \
	"$TESTROOT/orig-b/nvidia/a.c" "$TESTROOT/new-b/nvidia/a.c" \
	> "$TESTROOT/patches-b/patch-nvidia-a.c" || drc=$?
if [ "$drc" -gt 1 ]; then
	fail "(b) test bug: diff -u exited $drc"
else
	rc=0
	GB10_WORK="$TESTROOT" PATCHES="$TESTROOT/patches-b" \
		sh "$SCRIPT" "$TESTROOT/build/tree-b" >"$TESTROOT/out-b" 2>&1 || rc=$?
	if [ "$rc" -eq 0 ] && grep -q 'return 1' "$TESTROOT/build/tree-b/nvidia/a.c" \
	    && grep -q 'patch-nvidia-a.c' "$TESTROOT/build/tree-b/.prepared" \
	    && grep -q '^state done$' "$TESTROOT/build/tree-b/.prepared" \
	    && grep -q "^gb10 prepare-tree.sh $(realpath "$TESTROOT/build/tree-b")\$" \
		"$TESTROOT/build/tree-b/.prepared"; then
		ok "(b) good patch: a.c changed, .prepared lists it and says gb10/state done"
	else
		fail "(b) good patch: rc=$rc out=$(cat "$TESTROOT/out-b")"
	fi
fi

# (c) a bad patch: exit 1 and stderr names it.
mkdir -p "$TESTROOT/patches-c"
cat > "$TESTROOT/patches-c/patch-broken.c" <<'EOF'
--- nvidia/a.c
+++ nvidia/a.c
@@ -1 +1 @@
-int a(void) { return 999; }
+int a(void) { return 2; }
EOF
rc=0
GB10_WORK="$TESTROOT" PATCHES="$TESTROOT/patches-c" \
	sh "$SCRIPT" "$TESTROOT/build/tree-c" >"$TESTROOT/out-c" 2>"$TESTROOT/err-c" || rc=$?
if [ "$rc" -eq 1 ] && grep -q 'patch-broken.c' "$TESTROOT/err-c"; then
	ok "(c) bad patch: exit 1, stderr names patch-broken.c"
else
	fail "(c) bad patch: rc=$rc err=$(cat "$TESTROOT/err-c" 2>/dev/null)"
fi

# (d) missing tarball: exit 1 with the fetch-sources message.
mkdir -p "$TESTROOT/work-d"
rc=0
GB10_WORK="$TESTROOT/work-d" PATCHES="$TESTROOT/patches-empty" \
	sh "$SCRIPT" "$TESTROOT/work-d/build/tree" >"$TESTROOT/out-d" 2>&1 || rc=$?
if [ "$rc" -eq 1 ] && grep -q 'run scripts/fetch-sources.sh first' "$TESTROOT/out-d"; then
	ok "(d) missing tarball: exit 1, message printed"
else
	fail "(d) missing tarball: rc=$rc out=$(cat "$TESTROOT/out-d")"
fi

# (e) a second run replaces the tree: a stale file in TREE is gone.
rc=0
GB10_WORK="$TESTROOT" PATCHES="$TESTROOT/patches-empty" \
	sh "$SCRIPT" "$TESTROOT/build/tree-e" >"$TESTROOT/out-e1" 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
	fail "(e) first run: rc=$rc out=$(cat "$TESTROOT/out-e1")"
else
	touch "$TESTROOT/build/tree-e/nvidia/stale.o"
	rc=0
	GB10_WORK="$TESTROOT" PATCHES="$TESTROOT/patches-empty" \
		sh "$SCRIPT" "$TESTROOT/build/tree-e" >"$TESTROOT/out-e2" 2>&1 || rc=$?
	if [ "$rc" -eq 0 ] && [ -f "$TESTROOT/build/tree-e/nvidia/a.c" ] \
	    && [ ! -e "$TESTROOT/build/tree-e/nvidia/stale.o" ]; then
		ok "(e) rerun replaces tree: a.c present, stale.o gone"
	else
		fail "(e) rerun: rc=$rc out=$(cat "$TESTROOT/out-e2")"
	fi
fi

# (f) a foreign TREE (no .prepared marker) is refused and left untouched.
mkdir -p "$TESTROOT/build/tree-f"
printf 'precious\n' > "$TESTROOT/build/tree-f/keep.txt"
rc=0
GB10_WORK="$TESTROOT" PATCHES="$TESTROOT/patches-empty" \
	sh "$SCRIPT" "$TESTROOT/build/tree-f" >"$TESTROOT/out-f" 2>"$TESTROOT/err-f" || rc=$?
if [ "$rc" -eq 1 ] && grep -q 'refusing to replace' "$TESTROOT/err-f" \
    && [ -f "$TESTROOT/build/tree-f/keep.txt" ]; then
	ok "(f) foreign TREE: exit 1, refusal on stderr, keep.txt intact"
else
	fail "(f) foreign TREE: rc=$rc err=$(cat "$TESTROOT/err-f" 2>/dev/null) keep.txt=$([ -f "$TESTROOT/build/tree-f/keep.txt" ] && echo yes || echo no)"
fi

# (g) sha256 mismatch: exit 1 before touching an existing prepared TREE.
rc=0
GB10_WORK="$TESTROOT" PATCHES="$TESTROOT/patches-empty" \
	sh "$SCRIPT" "$TESTROOT/build/tree-g" >"$TESTROOT/out-g1" 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
	fail "(g) setup run: rc=$rc out=$(cat "$TESTROOT/out-g1")"
else
	touch "$TESTROOT/build/tree-g/nvidia/canary.o"
	printf 'nvidia_freebsd_sha256 %s\n' \
		'0000000000000000000000000000000000000000000000000000000000000000' \
		> "$TESTROOT/SOURCES-bad"
	rc=0
	GB10_WORK="$TESTROOT" PATCHES="$TESTROOT/patches-empty" \
		SOURCES="$TESTROOT/SOURCES-bad" \
		sh "$SCRIPT" "$TESTROOT/build/tree-g" >"$TESTROOT/out-g2" 2>"$TESTROOT/err-g" || rc=$?
	if [ "$rc" -eq 1 ] && grep -q 'sha256 mismatch' "$TESTROOT/err-g" \
	    && [ -f "$TESTROOT/build/tree-g/nvidia/canary.o" ] \
	    && [ -f "$TESTROOT/build/tree-g/.prepared" ]; then
		ok "(g) sha256 mismatch: exit 1, stderr says so, prepared TREE untouched"
	else
		fail "(g) sha256 mismatch: rc=$rc err=$(cat "$TESTROOT/err-g" 2>/dev/null)"
	fi
fi

# (h) firmware/: the tree also holds firmware/gsp_ga10x/gsp_ga10x.bin.
rc=0
GB10_WORK="$TESTROOT" PATCHES="$TESTROOT/patches-empty" \
	sh "$SCRIPT" "$TESTROOT/build/tree-h" >"$TESTROOT/out-h" 2>&1 || rc=$?
if [ "$rc" -eq 0 ] && [ -f "$TESTROOT/build/tree-h/firmware/gsp_ga10x/gsp_ga10x.bin" ]; then
	ok "(h) firmware: firmware/gsp_ga10x/gsp_ga10x.bin present"
else
	fail "(h) firmware: rc=$rc out=$(cat "$TESTROOT/out-h")"
fi

# (i) GB10_TEST_HOOKS unset: the SOURCES and PATCHES overrides in the
# environment are ignored.  The repo's own SOURCES pins the real NVIDIA
# tarball's sha256, which this test's fake tarball does not match, so the run
# must fail the checksum instead of succeeding through SOURCES-test, and no
# hook may be announced.
rc=0
env -u GB10_TEST_HOOKS GB10_WORK="$TESTROOT" PATCHES="$TESTROOT/patches-empty" \
	sh "$SCRIPT" "$TESTROOT/build/tree-i" >"$TESTROOT/out-i" 2>"$TESTROOT/err-i" || rc=$?
if [ "$rc" -eq 1 ] && grep -q 'sha256 mismatch' "$TESTROOT/err-i" \
    && ! grep -q 'test hook' "$TESTROOT/err-i" \
    && [ ! -e "$TESTROOT/build/tree-i" ]; then
	ok "(i) hooks disabled: SOURCES/PATCHES overrides ignored, repo pin used, exit 1"
else
	fail "(i) hooks disabled: rc=$rc err=$(cat "$TESTROOT/err-i" 2>/dev/null)"
fi

# (j) hook hygiene: with GB10_TEST_HOOKS=1 every hook in use is announced on
# stderr, and a hook value that is not one word of [A-Za-z0-9_./-] is refused
# instead of being run.
rc=0
GB10_WORK="$TESTROOT" PATCHES="$TESTROOT/patches-empty" \
	sh "$SCRIPT" "$TESTROOT/build/tree-j" >"$TESTROOT/out-j" 2>"$TESTROOT/err-j" || rc=$?
j_ok=1
[ "$rc" -eq 0 ] || j_ok=0
grep -q '^prepare-tree: test hook SOURCES in use$' "$TESTROOT/err-j" || j_ok=0
grep -q '^prepare-tree: test hook PATCHES in use$' "$TESTROOT/err-j" || j_ok=0
rc=0
env PATCHES="$TESTROOT/patches empty" GB10_WORK="$TESTROOT" \
	sh "$SCRIPT" "$TESTROOT/build/tree-j2" >"$TESTROOT/out-j2" 2>"$TESTROOT/err-j2" || rc=$?
[ "$rc" -eq 1 ] || j_ok=0
grep -q 'refusing test hook PATCHES' "$TESTROOT/err-j2" || j_ok=0
[ ! -e "$TESTROOT/build/tree-j2" ] || j_ok=0
if [ "$j_ok" -eq 1 ]; then
	ok "(j) hook hygiene: hooks announced when enabled, value with a space refused"
else
	fail "(j) hook hygiene: rc=$rc err-j=$(cat "$TESTROOT/err-j" 2>/dev/null) err-j2=$(cat "$TESTROOT/err-j2" 2>/dev/null)"
fi

# (k) TREE is $WORK/build itself: safe_build_dir must refuse it (resolved
# path equal to the build root, not strictly under it) and nothing may be
# built into it. The work root gets its own copy of the fake tarball so the
# run cannot stop earlier at the tarball check.
mkdir -p "$TESTROOT/work-k/sources"
cp "$TESTROOT/sources/$TOPDIR.tar.xz" "$TESTROOT/work-k/sources/"
rc=0
GB10_WORK="$TESTROOT/work-k" PATCHES="$TESTROOT/patches-empty" \
	sh "$SCRIPT" "$TESTROOT/work-k/build" >"$TESTROOT/out-k" 2>"$TESTROOT/err-k" || rc=$?
if [ "$rc" -eq 1 ] && grep -q 'refusing to replace' "$TESTROOT/err-k" \
    && [ ! -e "$TESTROOT/work-k/build/nvidia" ]; then
	ok "(k) TREE is \$WORK/build itself: refused, nothing built into it"
else
	fail "(k) TREE=\$WORK/build: rc=$rc err=$(cat "$TESTROOT/err-k" 2>/dev/null) nvidia-in-build=$([ -e "$TESTROOT/work-k/build/nvidia" ] && echo yes || echo no)"
fi

# (l) TREE given as $WORK//build/evil-l where evil-l is a symlink to a
# directory OUTSIDE $WORK/build holding a valid-looking .prepared: the
# symlink must be refused (the double slash must not smuggle it past the
# guard), the link must survive unreplaced, and the target's contents must
# be untouched.
mkdir -p "$TESTROOT/outside-l"
printf 'precious\n' > "$TESTROOT/outside-l/canary.txt"
printf 'gb10 prepare-tree.sh /bogus/path\nstate done\n' > "$TESTROOT/outside-l/.prepared"
ln -s "$TESTROOT/outside-l" "$TESTROOT/build/evil-l"
rc=0
GB10_WORK="$TESTROOT" PATCHES="$TESTROOT/patches-empty" \
	sh "$SCRIPT" "$TESTROOT//build/evil-l" >"$TESTROOT/out-l" 2>"$TESTROOT/err-l" || rc=$?
if [ "$rc" -eq 1 ] && grep -q 'refusing to replace' "$TESTROOT/err-l" \
    && [ -L "$TESTROOT/build/evil-l" ] \
    && [ "$(cat "$TESTROOT/outside-l/canary.txt" 2>/dev/null)" = "precious" ]; then
	ok "(l) symlink TREE resolving outside \$WORK/build: refused, link and target intact"
else
	fail "(l) symlink TREE: rc=$rc err=$(cat "$TESTROOT/err-l" 2>/dev/null) still-symlink=$([ -L "$TESTROOT/build/evil-l" ] && echo yes || echo no) canary=$(cat "$TESTROOT/outside-l/canary.txt" 2>/dev/null)"
fi

# (m) an existing TREE whose .prepared has the WRONG first line (here: the
# pre-marker-format content "building") must be refused and survive: only a
# marker naming this script and this exact resolved path authorises the
# rm -rf.
mkdir -p "$TESTROOT/build/tree-m/nvidia"
printf 'precious\n' > "$TESTROOT/build/tree-m/nvidia/canary.txt"
printf 'building\n' > "$TESTROOT/build/tree-m/.prepared"
rc=0
GB10_WORK="$TESTROOT" PATCHES="$TESTROOT/patches-empty" \
	sh "$SCRIPT" "$TESTROOT/build/tree-m" >"$TESTROOT/out-m" 2>"$TESTROOT/err-m" || rc=$?
if [ "$rc" -eq 1 ] && grep -q 'refusing to replace' "$TESTROOT/err-m" \
    && [ "$(cat "$TESTROOT/build/tree-m/nvidia/canary.txt" 2>/dev/null)" = "precious" ]; then
	ok "(m) .prepared with wrong first line: refused, tree survives"
else
	fail "(m) wrong first line: rc=$rc err=$(cat "$TESTROOT/err-m" 2>/dev/null) canary=$(cat "$TESTROOT/build/tree-m/nvidia/canary.txt" 2>/dev/null)"
fi

# (n) a patch whose ---/+++ header path holds a .. component must be
# refused BEFORE applying: the file it would reach outside TREE survives
# unmodified.
mkdir -p "$TESTROOT/patches-n"
printf 'orig\n' > "$TESTROOT/build/escape-me.txt"
cat > "$TESTROOT/patches-n/patch-escape.txt" <<'EOF'
--- ../escape-me.txt
+++ ../escape-me.txt
@@ -1 +1 @@
-orig
+escaped
EOF
rc=0
GB10_WORK="$TESTROOT" PATCHES="$TESTROOT/patches-n" \
	sh "$SCRIPT" "$TESTROOT/build/tree-n" >"$TESTROOT/out-n" 2>"$TESTROOT/err-n" || rc=$?
if [ "$rc" -eq 1 ] && grep -q 'refusing patch patch-escape.txt' "$TESTROOT/err-n" \
    && [ "$(cat "$TESTROOT/build/escape-me.txt" 2>/dev/null)" = "orig" ]; then
	ok "(n) patch with a ../ header path: refused, file outside TREE untouched"
else
	fail "(n) ../ patch: rc=$rc err=$(cat "$TESTROOT/err-n" 2>/dev/null) escape-me=$(cat "$TESTROOT/build/escape-me.txt" 2>/dev/null)"
fi

# (o) PATCHES naming a directory that does not exist: exit 1 with the
# directory named on stderr, and the tree must never reach "state done".
# Before the fix the glob over the missing directory stayed literal,
# `[ -e "$p" ] || continue` skipped it, and the run reported a patch-less
# tree as complete.
rc=0
GB10_WORK="$TESTROOT" PATCHES="$TESTROOT/no-such-dir" \
	sh "$SCRIPT" "$TESTROOT/build/tree-o" >"$TESTROOT/out-o" 2>"$TESTROOT/err-o" || rc=$?
if [ "$rc" -eq 1 ] && grep -q 'no-such-dir' "$TESTROOT/err-o" \
    && ! grep -q '^state done$' "$TESTROOT/build/tree-o/.prepared" 2>/dev/null; then
	ok "(o) PATCHES dir does not exist: exit 1, tree never reports state done"
else
	fail "(o) missing PATCHDIR: rc=$rc err=$(cat "$TESTROOT/err-o" 2>/dev/null) state=$(sed -n 2p "$TESTROOT/build/tree-o/.prepared" 2>/dev/null)"
fi

echo "passed: $PASSED failed: $FAILED"
if [ "$FAILED" -gt 0 ]; then
	exit 1
fi
exit 0
