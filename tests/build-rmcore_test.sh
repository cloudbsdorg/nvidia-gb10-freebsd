#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# build-rmcore_test.sh - offline tests for scripts/build-rmcore.sh.
#
# Builds a tiny fake open-gpu-kernel-modules git checkout under an
# unpredictable mktemp(1) directory in $(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)/work/tmp, points GB10_WORK
# at the test root and
# SOURCES at a test pin file, and fakes gmake through the script's GMAKE
# override, so no network and no real RM build are involved. The fake
# checkout carries a src/nvidia/Makefile holding the exact pre-image of the
# repo's real required ogkm patch (patches/ogkm/patch-src_nvidia_Makefile),
# and OGKM_PATCHES is left unset in the success-path cases so that real
# patch is applied to the build copy. SOURCES, GMAKE and OGKM_PATCHES are
# test hooks, so GB10_TEST_HOOKS=1 is exported.
# The fake
# nv-kernel.o is a real ELF object (built with cc) with exactly one
# undefined symbol, and a fake prepared OS-layer tree holds one real
# object that does not define it, so the undefined-symbol report is
# exercised too. Eighteen cases:
#   (a) commit mismatch:  refused, exit 1, build dir not created
#   (b) foreign build dir: existing build/ogkm without the .gb10-ogkm
#                         marker is refused, exit 1, left intact
#   (c) gmake failure:    exit 1, gmake output kept in the log
#   (d) success:          OUT exists, "nv-kernel.o: <size> bytes, sha256
#                         <x>" printed, "undefined not in OS layer: 1"
#                         printed, gmake got the FreeBSD/aarch64 flags and
#                         the neutral build stamp, it ran in the
#                         copied tree's src/nvidia, the real required ogkm
#                         patch was applied to the copy, and the copy's
#                         .gb10-ogkm marker names this script and says
#                         "state done"
#   (e) relative OUT/LOG: run from a scratch cwd with relative OUT and
#                         LOG; both files must land in that cwd, not
#                         inside the build copy the script cd's into
#   (f) TERM during build: a fake gmake sends TERM to the script's own
#                         process and then sleeps; the script must exit
#                         143 and leave no OUT behind
#   (g) hooks disabled:   with GB10_TEST_HOOKS unset the SOURCES and GMAKE
#                         overrides are ignored, so the repo's own pin is
#                         used and the fake checkout fails it
#   (h) modified tree:    the pinned checkout with a dirty tracked file is
#                         refused with "tree modified"
#   (i) hook hygiene:     hooks in use are announced on stderr, and a hook
#                         value that is not one word is refused
#   (j) OGKM_PATCHES gated: with GB10_TEST_HOOKS unset an OGKM_PATCHES
#                         override is ignored entirely (no announcement,
#                         the repo's patches/ogkm is used, so the run
#                         reaches the commit check instead of a
#                         required-patch refusal)
#   (k) required patch:   with the hook on, an OGKM_PATCHES dir missing
#                         patch-src_nvidia_Makefile exits 1
#   (l) stray files:      a pinned checkout with an untracked file is
#                         refused, exit 1, no build dir
#   (q) relative GB10_WORK: refused, exit 1, 'must be an absolute path',
#                         nothing created (pass-3 u09 #1: a relative WORK
#                         breaks after the script cd's into the build copy)
#   (r) note-less core object: the built object must carry the AArch64
#                         BTI property note before the marker may say
#                         "state done" (pass-3 u09 #2); an object without
#                         the note is refused, exit 1, the marker stays
#                         "state building" and no OUT is written
#   (s) modeset core:     with --core=nvidia-modeset the core built is
#                         open-gpu-kernel-modules' src/nvidia-modeset,
#                         the object is nv-modeset-kernel.o, gmake runs in
#                         the copy's src/nvidia-modeset, and
#                         LD_TARGET_EMULATION_FLAG_FreeBSD_aarch64=aarch64elf
#                         is passed to gmake (utils.mk has no FreeBSD/aarch64
#                         entry, so ld.lld -r --format=binary for the shader
#                         blobs would fail with "target emulation unknown")
#   (t) modeset core:     the required ogkm Makefile patch applies to the
#                         nvidia core ONLY, so a modeset build with an
#                         OGKM_PATCHES dir that does not hold it must
#                         still succeed
#   (u) modeset core:     the default OUT of a modeset build is
#                         $GB10_WORK/build/nv-modeset-kernel-aarch64.o
#   (v) modeset core:     the core may also be named by its bare word as
#                         the first argument (nvidia-modeset), the form
#                         the README and the round brief use
#   (w) unknown core:     an unknown core name is refused, exit 1, and
#                         nothing is built
#
# Run: sh tests/build-rmcore_test.sh

set -eu

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

OGKMDIR=open-gpu-kernel-modules-580.178.04
TESTSDIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SCRIPT="$TESTSDIR/../scripts/build-rmcore.sh"
TESTROOT=$(mktemp -d "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)/work/tmp/rmcore-test.XXXXXXXX") || exit 1

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

# SOURCES and GMAKE are test hooks: build-rmcore.sh ignores them unless this
# is set (case (g) proves it).
GB10_TEST_HOOKS=1
export GB10_TEST_HOOKS
# Pin the aarch64 path so these cases stay valid on amd64 hosts (Track #2475).
GB10_TEST_ARCH=aarch64
export GB10_TEST_ARCH

ok() {
	PASSED=$((PASSED + 1))
	printf 'ok   %s\n' "$1"
}

fail() {
	FAILED=$((FAILED + 1))
	printf 'FAIL %s\n' "$1"
}

mkdir -p "$TESTROOT/hooks-empty" "$TESTROOT/patches-empty"
if [ ! -f "$SCRIPT" ]; then
	fail "scripts/build-rmcore.sh does not exist"
	echo "passed: $PASSED failed: $FAILED"
	exit 1
fi

# Fake source checkout: a git repo shaped like ogkm (has src/nvidia), at a
# known commit. hooksPath is pointed at an empty dir and --no-verify is
# used so no host git hook (e.g. the commit review gate) fires in tests.
SRC="$TESTROOT/sources/$OGKMDIR"
mkdir -p "$SRC/src/nvidia" "$SRC/src/nvidia-modeset"
printf 'int dummy(void) { return 0; }\n' > "$SRC/src/nvidia/dummy.c"
printf 'int dummy(void) { return 0; }\n' > "$SRC/src/nvidia-modeset/dummy.c"
# The modeset core's Makefile is not patched by this repo (it does not strip
# .note.gnu.property), so it only has to exist and hold no objcopy step.
printf '.PHONY: clean\n' > "$SRC/src/nvidia-modeset/Makefile"
# src/nvidia/Makefile must hold the exact pre-image of the repo's real
# required patch (patches/ogkm/patch-src_nvidia_Makefile removes the
# --remove-section=.note.gnu.property line), so the success cases apply
# that real patch, not a stub. The hunk starts at line 220, and FreeBSD
# patch(1) IGNORES a hunk whose start lies past EOF (exit 0!), so 219
# filler lines put the pre-image at its real position. Tabs below are
# significant.
awk 'BEGIN { for (i = 1; i <= 219; i++) printf "# filler %d\n", i }' \
	> "$SRC/src/nvidia/Makefile"
cat >> "$SRC/src/nvidia/Makefile" <<'MKEOF'
	$(call quiet_cmd,OBJCOPY) \
	  --localize-symbol=memset \
	  --localize-symbol=memcpy \
	  --remove-section=.note.gnu.property \
	  $@

.PHONY: clean
MKEOF
# The repo's other ogkm patches (the cross-GPU import, Track #2228) patch
# source files that the fake checkout does not have.  Give it, for each, a
# pre-image rebuilt from the patch itself: the lines each hunk expects, at
# the line each hunk starts on (filler lines in between; patch(1) ignores a
# hunk that starts past the end of the file).  The success cases then apply
# every real patch in patches/ogkm, as they always did.
EXTRA=
for _p in "$TESTSDIR"/../patches/ogkm/patch-*; do
	case $_p in */patch-src_nvidia_Makefile) continue ;; esac
	_rel=$(sed -n '1s/^--- \([^[:space:]]*\)\.orig.*/\1/p' "$_p")
	[ -n "$_rel" ] || { echo "cannot read the target of $_p"; exit 1; }
	mkdir -p "$SRC/$(dirname "$_rel")"
	awk '
		/^@@ / {
			split($2, a, ","); start = substr(a[1], 2) + 0
			while (n < start - 1) { n++; printf "/* filler %d */\n", n }
			next
		}
		/^--- / || /^\+\+\+ / { next }
		/^-/ || /^ / { print substr($0, 2); n++ }
	' "$_p" > "$SRC/$_rel"
	EXTRA="$EXTRA $_rel"
done
git -C "$SRC" init -q
git -C "$SRC" add src/nvidia/dummy.c src/nvidia/Makefile \
	src/nvidia-modeset/dummy.c src/nvidia-modeset/Makefile
# shellcheck disable=SC2086
[ -z "$EXTRA" ] || (cd "$SRC" && git add $EXTRA)
git -C "$SRC" -c core.hooksPath="$TESTROOT/hooks-empty" \
	-c user.email=test@example.invalid -c user.name=test \
	commit -q --no-verify -m "fake ogkm"
HEAD_SHA=$(git -C "$SRC" rev-parse HEAD)

printf 'ogkm_commit %s\n' "$HEAD_SHA" > "$TESTROOT/SOURCES-good"
printf 'ogkm_commit %s\n' "0000000000000000000000000000000000000000" \
	> "$TESTROOT/SOURCES-bogus"

# Real ELF stand-ins: the fake nv-kernel.o has exactly one undefined
# symbol (rmcore_missing_1); the fake OS-layer object does not define it.
# The fake core object is compiled with -mbranch-protection=standard so it
# carries the AArch64 BTI/PAC property note that build-rmcore.sh now
# requires before "state done" (pass-3 u09 #2); the second copy, built
# WITHOUT the flag, is the note-less object case (r) must refuse.
# -target aarch64-unknown-freebsd is required so this compile succeeds on
# amd64 hosts too, where the aarch64 path is pinned (Track #2475).
printf 'extern int rmcore_missing_1(void);\nint f(void) { return rmcore_missing_1(); }\n' \
	> "$TESTROOT/fake-kernel.c"
cc -c -fno-stack-protector -target aarch64-unknown-freebsd \
	-mbranch-protection=standard \
	-o "$TESTROOT/fake-nv-kernel.o" "$TESTROOT/fake-kernel.c"
cc -c -fno-stack-protector \
	-o "$TESTROOT/fake-nv-kernel-nonote.o" "$TESTROOT/fake-kernel.c"
printf 'int rmcore_defined_here = 1;\nvoid osf(void) {}\n' > "$TESTROOT/fake-os.c"
cc -c -fno-stack-protector -o "$TESTROOT/fake-os.o" "$TESTROOT/fake-os.c"

# Fake gmakes. The good one records its cwd and arguments for case (d)
# and leaves a real ELF at the path the script copies from. It is core
# aware: the object it leaves is named after the core it was run in
# (nv-kernel.o in src/nvidia, nv-modeset-kernel.o in src/nvidia-modeset),
# because that is the name the script looks for.
cat > "$TESTROOT/fake-gmake-ok" <<EOF
#!/bin/sh
pwd > "$TESTROOT/gmake-cwd"
for a in "\$@"; do printf '%s\n' "\$a"; done > "$TESTROOT/gmake-args"
echo "fake gmake ran"
case \$(basename "\$PWD") in
nvidia-modeset) obj=nv-modeset-kernel.o ;;
*) obj=nv-kernel.o ;;
esac
mkdir -p _out/FreeBSD_aarch64
cp "$TESTROOT/fake-nv-kernel.o" "_out/FreeBSD_aarch64/\$obj"
exit 0
EOF
cat > "$TESTROOT/fake-gmake-fail" <<EOF
#!/bin/sh
echo "fake gmake failing" >&2
exit 1
EOF
# The TERM fake signals the script that invoked it ($PPID), then stays
# alive so the signal is certainly delivered while the script is still
# waiting for "gmake".
cat > "$TESTROOT/fake-gmake-term" <<EOF
#!/bin/sh
kill -TERM "\$PPID"
sleep 2
EOF
chmod +x "$TESTROOT/fake-gmake-ok" "$TESTROOT/fake-gmake-fail" \
	"$TESTROOT/fake-gmake-term"

# (a) commit mismatch: refused before any build dir is created.
rc=0
GB10_WORK="$TESTROOT" SOURCES="$TESTROOT/SOURCES-bogus" \
	GMAKE="$TESTROOT/fake-gmake-ok" \
	sh "$SCRIPT" >"$TESTROOT/out-a" 2>"$TESTROOT/err-a" || rc=$?
if [ "$rc" -eq 1 ] && grep -q 'commit mismatch' "$TESTROOT/err-a" \
    && [ ! -e "$TESTROOT/build/ogkm" ]; then
	ok "(a) commit mismatch: exit 1, no build dir created"
else
	fail "(a) commit mismatch: rc=$rc err=$(cat "$TESTROOT/err-a")"
fi

# (b) foreign build dir: refused and left intact.
mkdir -p "$TESTROOT/build/ogkm"
echo foreign > "$TESTROOT/build/ogkm/foreign.txt"
rc=0
GB10_WORK="$TESTROOT" SOURCES="$TESTROOT/SOURCES-good" \
	GMAKE="$TESTROOT/fake-gmake-ok" \
	sh "$SCRIPT" >"$TESTROOT/out-b" 2>"$TESTROOT/err-b" || rc=$?
if [ "$rc" -eq 1 ] && grep -q 'refusing to replace' "$TESTROOT/err-b" \
    && [ -f "$TESTROOT/build/ogkm/foreign.txt" ]; then
	ok "(b) foreign build dir: exit 1, dir intact"
else
	fail "(b) foreign build dir: rc=$rc err=$(cat "$TESTROOT/err-b")"
fi
rm -rf "$TESTROOT/build/ogkm"

# (c) gmake failure: exit 1, gmake output kept in the log.
rc=0
GB10_WORK="$TESTROOT" SOURCES="$TESTROOT/SOURCES-good" \
	GMAKE="$TESTROOT/fake-gmake-fail" \
	sh "$SCRIPT" "$TESTROOT/out-c.o" "$TESTROOT/log-c" \
	>"$TESTROOT/out-c" 2>"$TESTROOT/err-c" || rc=$?
if [ "$rc" -eq 1 ] && grep -q 'gmake failed' "$TESTROOT/err-c" \
    && grep -q 'fake gmake failing' "$TESTROOT/log-c" \
    && [ ! -e "$TESTROOT/out-c.o" ]; then
	ok "(c) gmake failure: exit 1, log kept, no OUT"
else
	fail "(c) gmake failure: rc=$rc err=$(cat "$TESTROOT/err-c")"
fi

# (d) success: replaces the marked dir from (c), copies OUT, prints the
# size/sha256 and undefined-count lines, and drives gmake correctly.
mkdir -p "$TESTROOT/build/tree/nvidia"
cp "$TESTROOT/fake-os.o" "$TESTROOT/build/tree/nvidia/freebsd_fake.o"
rc=0
GB10_WORK="$TESTROOT" SOURCES="$TESTROOT/SOURCES-good" \
	GMAKE="$TESTROOT/fake-gmake-ok" \
	sh "$SCRIPT" "$TESTROOT/build/nv-kernel-aarch64.o" "$TESTROOT/log-d" \
	>"$TESTROOT/out-d" 2>"$TESTROOT/err-d" || rc=$?
d_ok=1
[ "$rc" -eq 0 ] || d_ok=0
[ -f "$TESTROOT/build/nv-kernel-aarch64.o" ] || d_ok=0
[ -f "$TESTROOT/build/ogkm/.gb10-ogkm" ] || d_ok=0
grep -Eq '^nv-kernel\.o: [0-9]+ bytes, sha256 [0-9a-f]{64}$' \
	"$TESTROOT/out-d" || d_ok=0
grep -q '^undefined not in OS layer: 1$' "$TESTROOT/out-d" || d_ok=0
grep -q 'fake gmake ran' "$TESTROOT/log-d" || d_ok=0
[ "$(cat "$TESTROOT/gmake-cwd")" = "$TESTROOT/build/ogkm/src/nvidia" ] || d_ok=0
for flag in TARGET_OS=FreeBSD TARGET_ARCH=aarch64 CC=cc CXX=c++ LD=ld.lld \
    OBJCOPY=llvm-objcopy NV_BUILD_USER=cloudbsd NV_BUILD_HOST=build \
    LD_TARGET_EMULATION_FLAG_FreeBSD_aarch64=aarch64elf; do
	grep -qx -- "$flag" "$TESTROOT/gmake-args" || d_ok=0
done
# The marker must say who wrote it and that the copy is complete.
grep -q '^state done$' "$TESTROOT/build/ogkm/.gb10-ogkm" || d_ok=0
grep -q "^gb10 build-rmcore.sh $(realpath "$TESTROOT/build/ogkm")\$" \
	"$TESTROOT/build/ogkm/.gb10-ogkm" || d_ok=0
# The real required ogkm patch was applied to the copy: the line it
# removes is gone while its neighbouring context lines remain.
if grep -q 'remove-section=.note.gnu.property' \
    "$TESTROOT/build/ogkm/src/nvidia/Makefile"; then d_ok=0; fi
grep -q 'localize-symbol=memset' \
	"$TESTROOT/build/ogkm/src/nvidia/Makefile" || d_ok=0
if [ "$d_ok" -eq 1 ]; then
	ok "(d) success: OUT exists, size/sha256 + undefined lines printed, gmake flags and cwd correct, real ogkm patch applied, marker says gb10/state done"
else
	fail "(d) success: rc=$rc out=$(cat "$TESTROOT/out-d") err=$(cat "$TESTROOT/err-d")"
fi

# (e) relative OUT/LOG: both must resolve against the caller's cwd, not
# against the build copy the script cd's into before writing them.
mkdir -p "$TESTROOT/cwd-e"
rc=0
(
	CDPATH= cd -- "$TESTROOT/cwd-e" || exit 1
	GB10_WORK="$TESTROOT" SOURCES="$TESTROOT/SOURCES-good" \
		GMAKE="$TESTROOT/fake-gmake-ok" \
		sh "$SCRIPT" out-e.o log-e >"$TESTROOT/out-e" 2>"$TESTROOT/err-e"
) || rc=$?
if [ "$rc" -eq 0 ] && [ -f "$TESTROOT/cwd-e/out-e.o" ] \
    && [ -f "$TESTROOT/cwd-e/log-e" ]; then
	ok "(e) relative OUT/LOG: both land in the caller's cwd"
else
	fail "(e) relative OUT/LOG: rc=$rc out-e.o-in-cwd=$([ -e "$TESTROOT/cwd-e/out-e.o" ] && echo yes || echo no) log-e-in-cwd=$([ -e "$TESTROOT/cwd-e/log-e" ] && echo yes || echo no)"
fi

# (f) TERM during the build: the TERM trap must exit 143 (the EXIT trap
# still cleans up); no OUT may appear.
rc=0
GB10_WORK="$TESTROOT" SOURCES="$TESTROOT/SOURCES-good" \
	GMAKE="$TESTROOT/fake-gmake-term" \
	sh "$SCRIPT" "$TESTROOT/out-f.o" "$TESTROOT/log-f" \
	>"$TESTROOT/out-f" 2>"$TESTROOT/err-f" || rc=$?
if [ "$rc" -eq 143 ] && [ ! -e "$TESTROOT/out-f.o" ]; then
	ok "(f) TERM during build: exit 143, no OUT"
else
	fail "(f) TERM during build: rc=$rc err=$(cat "$TESTROOT/err-f")"
fi

# (g) GB10_TEST_HOOKS unset: the SOURCES and GMAKE overrides in the
# environment are ignored.  The repo's own SOURCES pins NVIDIA's ogkm_commit,
# which this test's fake checkout is not at, so the run must stop at "commit
# mismatch" and the fake gmake must never run.
cat > "$TESTROOT/fake-gmake-g" <<EOF
#!/bin/sh
: > "$TESTROOT/gmake-ran-g"
exit 0
EOF
chmod +x "$TESTROOT/fake-gmake-g"
rc=0
env -u GB10_TEST_HOOKS GB10_WORK="$TESTROOT" SOURCES="$TESTROOT/SOURCES-good" \
	OGKM_PATCHES="$TESTROOT/patches-empty" \
	GMAKE="$TESTROOT/fake-gmake-g" \
	sh "$SCRIPT" "$TESTROOT/out-g.o" "$TESTROOT/log-g" \
	>"$TESTROOT/out-g" 2>"$TESTROOT/err-g" || rc=$?
if [ "$rc" -eq 1 ] && grep -q 'commit mismatch' "$TESTROOT/err-g" \
    && ! grep -q 'test hook' "$TESTROOT/err-g" \
    && [ ! -e "$TESTROOT/gmake-ran-g" ] && [ ! -e "$TESTROOT/out-g.o" ]; then
	ok "(g) hooks disabled: SOURCES/GMAKE overrides ignored, exit 1, gmake never ran"
else
	fail "(g) hooks disabled: rc=$rc err=$(cat "$TESTROOT/err-g") gmake-ran=$([ -e "$TESTROOT/gmake-ran-g" ] && echo yes || echo no)"
fi

# (h) the pinned checkout with a modified tracked file: exit 1 with "tree
# modified" before any build directory is made.  A private copy of the fake
# checkout is dirtied, so the shared SRC stays clean for the other cases.
WORKH="$TESTROOT/work-h"
mkdir -p "$WORKH/sources"
cp -R "$SRC" "$WORKH/sources/$OGKMDIR"
printf 'locally modified\n' > "$WORKH/sources/$OGKMDIR/src/nvidia/dummy.c"
rc=0
GB10_WORK="$WORKH" SOURCES="$TESTROOT/SOURCES-good" \
	GMAKE="$TESTROOT/fake-gmake-ok" \
	sh "$SCRIPT" "$TESTROOT/out-h.o" "$TESTROOT/log-h" \
	>"$TESTROOT/out-h" 2>"$TESTROOT/err-h" || rc=$?
if [ "$rc" -eq 1 ] && grep -q 'tree modified' "$TESTROOT/err-h" \
    && [ ! -e "$WORKH/build/ogkm" ] && [ ! -e "$TESTROOT/out-h.o" ]; then
	ok "(h) modified tracked file at the pinned commit: exit 1, 'tree modified', no build dir"
else
	fail "(h) dirty checkout: rc=$rc err=$(cat "$TESTROOT/err-h")"
fi

# (i) hook hygiene: with GB10_TEST_HOOKS=1 every hook in use is announced on
# stderr, and a hook value that is not one word of [A-Za-z0-9_./-] is refused
# instead of being run.
rc=0
GB10_WORK="$TESTROOT" SOURCES="$TESTROOT/SOURCES-bogus" \
	GMAKE="$TESTROOT/fake-gmake-ok" \
	sh "$SCRIPT" "$TESTROOT/out-i.o" "$TESTROOT/log-i" \
	>"$TESTROOT/out-i" 2>"$TESTROOT/err-i" || rc=$?
i_ok=1
[ "$rc" -eq 1 ] || i_ok=0
grep -q '^build-rmcore: test hook GMAKE in use$' "$TESTROOT/err-i" || i_ok=0
grep -q '^build-rmcore: test hook SOURCES in use$' "$TESTROOT/err-i" || i_ok=0
rc=0
env GMAKE="$TESTROOT/fake gmake" GB10_WORK="$TESTROOT" \
	SOURCES="$TESTROOT/SOURCES-good" \
	sh "$SCRIPT" "$TESTROOT/out-i2.o" "$TESTROOT/log-i2" \
	>"$TESTROOT/out-i2" 2>"$TESTROOT/err-i2" || rc=$?
[ "$rc" -eq 1 ] || i_ok=0
grep -q 'refusing test hook GMAKE' "$TESTROOT/err-i2" || i_ok=0
[ ! -e "$TESTROOT/out-i2.o" ] || i_ok=0
if [ "$i_ok" -eq 1 ]; then
	ok "(i) hook hygiene: hooks announced when enabled, GMAKE value with a space refused"
else
	fail "(i) hook hygiene: rc=$rc err-i=$(cat "$TESTROOT/err-i" 2>/dev/null) err-i2=$(cat "$TESTROOT/err-i2" 2>/dev/null)"
fi

# (j) OGKM_PATCHES is gated like SOURCES/GMAKE: with GB10_TEST_HOOKS unset
# the override is ignored entirely. Observable: no hook announcement, and no
# required-patch refusal either — the run got the repo's own patches/ogkm
# (which HAS patch-src_nvidia_Makefile) and died at the commit check, which
# the repo pin fails for the fake checkout.
rc=0
env -u GB10_TEST_HOOKS GB10_WORK="$TESTROOT" SOURCES="$TESTROOT/SOURCES-good" \
	OGKM_PATCHES="$TESTROOT/patches-empty" \
	GMAKE="$TESTROOT/fake-gmake-ok" \
	sh "$SCRIPT" "$TESTROOT/out-j.o" "$TESTROOT/log-j" \
	>"$TESTROOT/out-j" 2>"$TESTROOT/err-j" || rc=$?
if [ "$rc" -eq 1 ] && grep -q 'commit mismatch' "$TESTROOT/err-j" \
    && ! grep -q 'test hook' "$TESTROOT/err-j" \
    && ! grep -q 'required patch' "$TESTROOT/err-j" \
    && [ ! -e "$TESTROOT/out-j.o" ]; then
	ok "(j) OGKM_PATCHES gated: ignored without GB10_TEST_HOOKS, repo patches used, nothing announced"
else
	fail "(j) OGKM_PATCHES gating: rc=$rc err=$(cat "$TESTROOT/err-j" 2>/dev/null)"
fi

# (k) with the hook on, an OGKM_PATCHES directory missing the required
# patch-src_nvidia_Makefile exits 1 before any build directory is touched.
rc=0
GB10_WORK="$TESTROOT" SOURCES="$TESTROOT/SOURCES-good" \
	OGKM_PATCHES="$TESTROOT/patches-empty" \
	GMAKE="$TESTROOT/fake-gmake-ok" \
	sh "$SCRIPT" "$TESTROOT/out-k.o" "$TESTROOT/log-k" \
	>"$TESTROOT/out-k" 2>"$TESTROOT/err-k" || rc=$?
if [ "$rc" -eq 1 ] && grep -q 'required patch missing' "$TESTROOT/err-k" \
    && grep -q '^build-rmcore: test hook OGKM_PATCHES in use$' "$TESTROOT/err-k" \
    && [ ! -e "$TESTROOT/out-k.o" ]; then
	ok "(k) required ogkm patch missing from hook dir: exit 1"
else
	fail "(k) required patch missing: rc=$rc err=$(cat "$TESTROOT/err-k" 2>/dev/null)"
fi

# (l) a pinned checkout with an UNTRACKED file is refused: what would be
# copied is not exactly the pin. A private copy of the fake checkout gets
# the stray file, so the shared SRC stays clean for the other cases.
WORKL="$TESTROOT/work-l"
mkdir -p "$WORKL/sources"
cp -R "$SRC" "$WORKL/sources/$OGKMDIR"
printf 'stray\n' > "$WORKL/sources/$OGKMDIR/stray-untracked.txt"
rc=0
GB10_WORK="$WORKL" SOURCES="$TESTROOT/SOURCES-good" \
	GMAKE="$TESTROOT/fake-gmake-ok" \
	sh "$SCRIPT" "$TESTROOT/out-l.o" "$TESTROOT/log-l" \
	>"$TESTROOT/out-l" 2>"$TESTROOT/err-l" || rc=$?
if [ "$rc" -eq 1 ] && grep -q 'extra files' "$TESTROOT/err-l" \
    && [ ! -e "$WORKL/build/ogkm" ] && [ ! -e "$TESTROOT/out-l.o" ]; then
	ok "(l) untracked file in the pinned checkout: exit 1, 'extra files', no build dir"
else
	fail "(l) untracked file: rc=$rc err=$(cat "$TESTROOT/err-l" 2>/dev/null) builddir=$([ -e "$WORKL/build/ogkm" ] && echo yes || echo no)"
fi

# (m) a leaked GIT_DIR pointing at a decoy repository must not answer the
# pin check: the decoy's HEAD is what SOURCES pins, the real checkout is at
# another commit, so the run must stop at "commit mismatch".
DECOY="$TESTROOT/decoy"
mkdir -p "$DECOY"
git -C "$DECOY" init -q
printf 'decoy\n' > "$DECOY/f"
git -C "$DECOY" add f
git -C "$DECOY" -c core.hooksPath="$TESTROOT/hooks-empty" \
	-c user.email=test@example.invalid -c user.name=test \
	commit -q --no-verify -m decoy
printf 'ogkm_commit %s\n' "$(git -C "$DECOY" rev-parse HEAD)" > "$TESTROOT/SOURCES-decoy"
rc=0
GIT_DIR="$DECOY/.git" GB10_WORK="$TESTROOT" SOURCES="$TESTROOT/SOURCES-decoy" \
	GMAKE="$TESTROOT/fake-gmake-ok" \
	sh "$SCRIPT" "$TESTROOT/out-m.o" "$TESTROOT/log-m" \
	>"$TESTROOT/out-m" 2>"$TESTROOT/err-m" || rc=$?
if [ "$rc" -eq 1 ] && grep -q 'commit mismatch' "$TESTROOT/err-m" && [ ! -e "$TESTROOT/out-m.o" ]; then
	ok "(m) leaked GIT_DIR decoy: pin check reads the real checkout, commit mismatch"
else
	fail "(m) GIT_DIR decoy: rc=$rc err=$(cat "$TESTROOT/err-m" 2>/dev/null)"
fi

# (n) no OS-layer objects yet: the build succeeds and the script finishes,
# instead of set -e killing it after a good build.
WORKN="$TESTROOT/work-n"
mkdir -p "$WORKN/sources"
cp -R "$SRC" "$WORKN/sources/$OGKMDIR"
rc=0
GB10_WORK="$WORKN" SOURCES="$TESTROOT/SOURCES-good" \
	GMAKE="$TESTROOT/fake-gmake-ok" \
	sh "$SCRIPT" "$WORKN/out-n.o" "$WORKN/log-n" \
	>"$TESTROOT/out-n" 2>"$TESTROOT/err-n" || rc=$?
if [ "$rc" -eq 0 ] && [ -f "$WORKN/out-n.o" ] && grep -q 'ready' "$TESTROOT/out-n"; then
	ok "(n) no OS-layer objects: exit 0, OUT written, script finishes"
else
	fail "(n) no OS-layer objects: rc=$rc out=$(cat "$TESTROOT/out-n") err=$(cat "$TESTROOT/err-n" 2>/dev/null)"
fi

# (o) a required Makefile patch that leaves --remove-section in place is
# refused before gmake runs.
mkdir -p "$TESTROOT/patches-o"
printf '%s\n' '--- src/nvidia/Makefile.orig' '+++ src/nvidia/Makefile' \
	'@@ -1,3 +1,3 @@' '-# filler 1' '+# filler one' ' # filler 2' ' # filler 3' \
	> "$TESTROOT/patches-o/patch-src_nvidia_Makefile"
rm -f "$TESTROOT/gmake-cwd"
rc=0
GB10_WORK="$TESTROOT" SOURCES="$TESTROOT/SOURCES-good" \
	OGKM_PATCHES="$TESTROOT/patches-o" GMAKE="$TESTROOT/fake-gmake-ok" \
	sh "$SCRIPT" "$TESTROOT/out-o.o" "$TESTROOT/log-o" \
	>"$TESTROOT/out-o" 2>"$TESTROOT/err-o" || rc=$?
if [ "$rc" -eq 1 ] && grep -q 'still strips .note.gnu.property' "$TESTROOT/err-o" \
    && [ ! -e "$TESTROOT/gmake-cwd" ]; then
	ok "(o) Makefile still strips the property note: exit 1 before gmake"
else
	fail "(o) property note: rc=$rc err=$(cat "$TESTROOT/err-o" 2>/dev/null)"
fi

# (p) inherited make flags do not reach gmake.
{
	echo '#!/bin/sh'
	echo "env | grep -E '^(MAKEFLAGS|GNUMAKEFLAGS|MFLAGS|MAKELEVEL)=' > \"$TESTROOT/gmake-env\""
	echo 'mkdir -p _out/FreeBSD_aarch64'
	echo "cp \"$TESTROOT/fake-nv-kernel.o\" _out/FreeBSD_aarch64/nv-kernel.o"
	echo 'exit 0'
} > "$TESTROOT/fake-gmake-env"
chmod +x "$TESTROOT/fake-gmake-env"
rm -f "$TESTROOT/gmake-env"
rc=0
MAKEFLAGS='CFLAGS=-O0' GNUMAKEFLAGS='CFLAGS=-O0' MFLAGS=-k MAKELEVEL=3 \
	GB10_WORK="$TESTROOT" SOURCES="$TESTROOT/SOURCES-good" \
	GMAKE="$TESTROOT/fake-gmake-env" \
	sh "$SCRIPT" "$TESTROOT/out-p.o" "$TESTROOT/log-p" \
	>"$TESTROOT/out-p" 2>"$TESTROOT/err-p" || rc=$?
if [ "$rc" -eq 0 ] && [ -f "$TESTROOT/gmake-env" ] && [ ! -s "$TESTROOT/gmake-env" ]; then
	ok "(p) MAKEFLAGS/GNUMAKEFLAGS/MFLAGS/MAKELEVEL do not reach gmake"
else
	fail "(p) make flags: rc=$rc gmake-env=$(cat "$TESTROOT/gmake-env" 2>/dev/null) err=$(cat "$TESTROOT/err-p" 2>/dev/null)"
fi

# (q) a relative GB10_WORK must be refused: the script cd's into the
# build copy before it writes the marker and the OUT, so a relative WORK
# turns a good build into a failure at the redirect (and leaks the
# scratch). Refusing beats absolutising, and it also closes the
# leading-'-' case. Run from a scratch cwd so a stray relative directory
# would be visible.
mkdir -p "$TESTROOT/cwd-q"
rc=0
(
	CDPATH= cd -- "$TESTROOT/cwd-q" || exit 1
	GB10_WORK=work-q SOURCES="$TESTROOT/SOURCES-good" \
		GMAKE="$TESTROOT/fake-gmake-ok" \
		sh "$SCRIPT" >"$TESTROOT/out-q" 2>"$TESTROOT/err-q"
) || rc=$?
if [ "$rc" -eq 1 ] && grep -q 'must be an absolute path' "$TESTROOT/err-q" \
    && [ ! -e "$TESTROOT/cwd-q/work-q" ]; then
	ok "(q) relative GB10_WORK: exit 1, 'must be an absolute path', nothing created"
else
	fail "(q) relative GB10_WORK: rc=$rc err=$(cat "$TESTROOT/err-q" 2>/dev/null) created=$([ -e "$TESTROOT/cwd-q/work-q" ] && echo yes || echo no)"
fi

# (r) the built core object must carry the AArch64 BTI property note
# before the marker may say "state done" (pass-3 u09 #2): FreeBSD 16
# arm64 links every kmod with -zbti-report=error, so an object without
# the note cannot link into nvidia.ko later - and a toolchain regression
# must fail HERE, not in another script. The fake gmake leaves behind an
# object built WITHOUT -mbranch-protection=standard.
cat > "$TESTROOT/fake-gmake-nonote" <<EOF
#!/bin/sh
mkdir -p _out/FreeBSD_aarch64
cp "$TESTROOT/fake-nv-kernel-nonote.o" _out/FreeBSD_aarch64/nv-kernel.o
exit 0
EOF
chmod +x "$TESTROOT/fake-gmake-nonote"
rc=0
GB10_WORK="$TESTROOT" SOURCES="$TESTROOT/SOURCES-good" \
	GMAKE="$TESTROOT/fake-gmake-nonote" \
	sh "$SCRIPT" "$TESTROOT/out-r.o" "$TESTROOT/log-r" \
	>"$TESTROOT/out-r" 2>"$TESTROOT/err-r" || rc=$?
r_ok=1
[ "$rc" -eq 1 ] || r_ok=0
grep -qi 'BTI' "$TESTROOT/err-r" || r_ok=0
[ ! -e "$TESTROOT/out-r.o" ] || r_ok=0
grep -q '^state done$' "$TESTROOT/build/ogkm/.gb10-ogkm" 2>/dev/null && r_ok=0
if [ "$r_ok" -eq 1 ]; then
	ok "(r) core object without the BTI property note: exit 1, marker not 'state done', no OUT"
else
	fail "(r) note-less object: rc=$rc err=$(cat "$TESTROOT/err-r" 2>/dev/null) out-r=$([ -e "$TESTROOT/out-r.o" ] && echo yes || echo no) marker=$(sed -n 2p "$TESTROOT/build/ogkm/.gb10-ogkm" 2>/dev/null)"
fi

# (s) the modeset core: the same script builds open-gpu-kernel-modules'
# src/nvidia-modeset, the object is nv-modeset-kernel.o, gmake runs in the
# copy's src/nvidia-modeset, and the LD emulation flag for FreeBSD/aarch64
# is passed to gmake - utils.mk has no FreeBSD/aarch64 entry, so ld.lld -r
# --format=binary (the shader blobs) would fail with "target emulation
# unknown" without it.
rc=0
GB10_WORK="$TESTROOT" SOURCES="$TESTROOT/SOURCES-good" \
	GMAKE="$TESTROOT/fake-gmake-ok" \
	sh "$SCRIPT" --core=nvidia-modeset "$TESTROOT/out-s.o" "$TESTROOT/log-s" \
	>"$TESTROOT/out-s" 2>"$TESTROOT/err-s" || rc=$?
s_ok=1
[ "$rc" -eq 0 ] || s_ok=0
[ -f "$TESTROOT/out-s.o" ] || s_ok=0
grep -Eq '^nv-modeset-kernel\.o: [0-9]+ bytes, sha256 [0-9a-f]{64}$' \
	"$TESTROOT/out-s" || s_ok=0
[ "$(cat "$TESTROOT/gmake-cwd")" = "$TESTROOT/build/ogkm/src/nvidia-modeset" ] \
	|| s_ok=0
grep -qx -- 'LD_TARGET_EMULATION_FLAG_FreeBSD_aarch64=aarch64elf' \
	"$TESTROOT/gmake-args" || s_ok=0
grep -qx -- 'TARGET_ARCH=aarch64' "$TESTROOT/gmake-args" || s_ok=0
# The BTI note check applies to the modeset core too: the object is the
# same note-carrying stand-in, and the marker must say the copy is done.
grep -q '^state done$' "$TESTROOT/build/ogkm/.gb10-ogkm" || s_ok=0
if [ "$s_ok" -eq 1 ]; then
	ok "(s) modeset core: src/nvidia-modeset built, nv-modeset-kernel.o copied, LD emulation flag passed"
else
	fail "(s) modeset core: rc=$rc out=$(cat "$TESTROOT/out-s" 2>/dev/null) err=$(cat "$TESTROOT/err-s" 2>/dev/null) cwd=$(cat "$TESTROOT/gmake-cwd" 2>/dev/null)"
fi

# (t) the required ogkm Makefile patch applies to the nvidia core only: a
# modeset build with an OGKM_PATCHES dir that does not hold it must still
# succeed (case (k) proves the nvidia core refuses such a dir).
rc=0
GB10_WORK="$TESTROOT" SOURCES="$TESTROOT/SOURCES-good" \
	OGKM_PATCHES="$TESTROOT/patches-empty" \
	GMAKE="$TESTROOT/fake-gmake-ok" \
	sh "$SCRIPT" --core=nvidia-modeset "$TESTROOT/out-t.o" "$TESTROOT/log-t" \
	>"$TESTROOT/out-t" 2>"$TESTROOT/err-t" || rc=$?
if [ "$rc" -eq 0 ] && [ -f "$TESTROOT/out-t.o" ] \
    && ! grep -q 'required patch missing' "$TESTROOT/err-t"; then
	ok "(t) modeset core: the nvidia-core Makefile patch is not required"
else
	fail "(t) modeset core without the ogkm patch: rc=$rc err=$(cat "$TESTROOT/err-t" 2>/dev/null)"
fi

# (u) the default OUT of a modeset build is
# $GB10_WORK/build/nv-modeset-kernel-aarch64.o.
rm -f "$TESTROOT/build/nv-modeset-kernel-aarch64.o"
rc=0
GB10_WORK="$TESTROOT" SOURCES="$TESTROOT/SOURCES-good" \
	GMAKE="$TESTROOT/fake-gmake-ok" \
	sh "$SCRIPT" --core=nvidia-modeset >"$TESTROOT/out-u" 2>"$TESTROOT/err-u" || rc=$?
if [ "$rc" -eq 0 ] && [ -f "$TESTROOT/build/nv-modeset-kernel-aarch64.o" ]; then
	ok "(u) modeset core: default OUT is build/nv-modeset-kernel-aarch64.o"
else
	fail "(u) modeset default OUT: rc=$rc err=$(cat "$TESTROOT/err-u" 2>/dev/null)"
fi

# (v) the core may also be named by its bare word as the first argument.
rc=0
GB10_WORK="$TESTROOT" SOURCES="$TESTROOT/SOURCES-good" \
	GMAKE="$TESTROOT/fake-gmake-ok" \
	sh "$SCRIPT" nvidia-modeset "$TESTROOT/out-v.o" "$TESTROOT/log-v" \
	>"$TESTROOT/out-v" 2>"$TESTROOT/err-v" || rc=$?
if [ "$rc" -eq 0 ] && [ -f "$TESTROOT/out-v.o" ] \
    && [ "$(cat "$TESTROOT/gmake-cwd")" = "$TESTROOT/build/ogkm/src/nvidia-modeset" ]; then
	ok "(v) modeset core: named by its bare word as the first argument"
else
	fail "(v) bare-word core: rc=$rc err=$(cat "$TESTROOT/err-v" 2>/dev/null)"
fi

# (w) an unknown core name is refused, and nothing is built.
rc=0
GB10_WORK="$TESTROOT" SOURCES="$TESTROOT/SOURCES-good" \
	GMAKE="$TESTROOT/fake-gmake-ok" \
	sh "$SCRIPT" --core=nvidia-drm "$TESTROOT/out-w.o" "$TESTROOT/log-w" \
	>"$TESTROOT/out-w" 2>"$TESTROOT/err-w" || rc=$?
if [ "$rc" -eq 1 ] && grep -q 'usage:' "$TESTROOT/err-w" \
    && grep -q 'unknown core' "$TESTROOT/err-w" \
    && [ ! -e "$TESTROOT/out-w.o" ]; then
	ok "(w) unknown core name: exit 1 with a usage message, nothing built"
else
	fail "(w) unknown core: rc=$rc err=$(cat "$TESTROOT/err-w" 2>/dev/null)"
fi

echo "passed: $PASSED failed: $FAILED"
if [ "$FAILED" -gt 0 ]; then
	exit 1
fi
exit 0
