#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# linux_cuda_test.sh - tests for scripts/build-linux-cuda.sh,
# scripts/run-linux-cuda.sh and tests/cuda/, without a GPU.
#
# Part 1 needs a Linux sysroot (LINUXROOT, default
# ${GB10_WORK:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)/work}/linuxroot, with rl9/ in it); when it is
# missing, part 1 is SKIPPED and only part 2 runs.
#   (a) build:           build-linux-cuda.sh builds shim.so and the four
#                        programs into a scratch BUILDDIR
#   (b) without the shim: test_shim_abstract run through the Linux ld.so
#                        records the kernel's answer (fails on a Linuxulator
#                        without abstract sockets, passes on one with them)
#   (c) with the shim:   the same program PASSES under run-linux-cuda.sh
#
# Part 2 needs nothing but sh; run-linux-cuda.sh runs against a fake work
# root whose ld-linux is a stub that prints its arguments and environment:
#   (d) --help exits 0 with the usage block; no argument exits 2
#   (e) a missing ld-linux, shim or program exits 1 and says "missing"
#   (f) a bare program name is looked up in BUILDDIR; a path is used as is
#   (g) --preload, --library-path and the program arguments reach the loader
#   (h) the SHIM_* environment is set, with a short SHIM_ABSTRACT_DIR
#   (i) HOME and GB10_WORK unset: use the script's repository-local work root
#   (j) both scripts parse (sh -n) and are executable
#   (k) SHIM_ABSTRACT=off makes the shim stand aside: the same answer as (b)
#
# Run: sh tests/linux_cuda_test.sh

set -eu

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

TESTSDIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$TESTSDIR/.." && pwd)
BUILD=$REPO/scripts/build-linux-cuda.sh
RUN=$REPO/scripts/run-linux-cuda.sh

PASSED=0
FAILED=0
SKIPPED=0

mkdir -p "$REPO/tmp"
TESTROOT=$(mktemp -d "$REPO/tmp/linux-cuda-test.XXXXXXXX") || exit 1
# The shim keeps abstract sockets in a file whose path must fit sun_path
# (103 bytes), so the abstract directory is short, outside the repository:
# under $HOME, never /tmp.  With no HOME there is nowhere short and private.
if [ -z "${HOME:-}" ]; then
	echo "linux_cuda_test: HOME is unset; refusing to fall back to /tmp" >&2
	exit 2
fi
SADIR=$(mktemp -d "$HOME/.cache-sa.XXXXXX") || exit 1

# cleanup - remove exactly this run's scratch files on every exit path.
# Time:  O(files created by this test).
# Space: O(1).
cleanup() {
	rm -rf "$TESTROOT" "$SADIR"
}
trap cleanup EXIT INT TERM

ok() {
	PASSED=$((PASSED + 1))
	printf 'ok   %s\n' "$1"
}

fail() {
	FAILED=$((FAILED + 1))
	printf 'FAIL %s\n' "$1"
}

skip() {
	SKIPPED=$((SKIPPED + 1))
	printf 'skip %s\n' "$1"
}

WORK=${GB10_WORK:-$REPO/work}
LINUXROOT=${LINUXROOT:-$WORK/linuxroot}

# ---- Part 1: real build and the shim test (needs the Linux sysroot) ----
RB=$TESTROOT/real
if [ -d "$LINUXROOT/rl9/usr/lib64" ] &&
    [ -e "$LINUXROOT/rl9/usr/lib/ld-linux-aarch64.so.1" ] &&
    command -v clang > /dev/null 2>&1; then
	rc=0
	LINUXROOT=$LINUXROOT BUILDDIR=$RB GB10_WORK=$WORK sh "$BUILD" \
	    > "$TESTROOT/a.out" 2> "$TESTROOT/a.err" || rc=$?
	missing=
	for p in shim.so cuinit cuda_smoke cuda_vecadd test_shim_abstract; do
		[ -s "$RB/$p" ] || missing="$missing $p"
	done
	if [ "$rc" -eq 0 ] && [ -z "$missing" ]; then
		ok "(a) build: shim.so and four programs built"
	else
		fail "(a) build: rc=$rc missing:$missing err=$(cat "$TESTROOT/a.err")"
	fi

	R=$LINUXROOT/rl9
	LDSO=$R/usr/lib/ld-linux-aarch64.so.1
	# (b) without the shim: the kernel's own answer.  A Linuxulator without
	# abstract sockets fails the bind; one with them (cloudbsd-src
	# agent/2101-linux-abstract-sockets) passes.  Either is recorded; (k)
	# checks that SHIM_ABSTRACT=off gives the same answer.
	brc=0
	"$LDSO" --library-path "$R/usr/lib64:$R/usr/lib" "$RB/test_shim_abstract" \
	    > "$TESTROOT/b.out" 2> "$TESTROOT/b.err" || brc=$?
	if [ "$brc" -eq 0 ] && grep -q '^PASS' "$TESTROOT/b.out"; then
		ok "(b) without the shim: the kernel has abstract sockets (test passes)"
	elif [ "$brc" -ne 0 ] && ! grep -q PASS "$TESTROOT/b.out"; then
		ok "(b) without the shim: the kernel has no abstract sockets (rc=$brc)"
	else
		fail "(b) without the shim: inconsistent rc=$brc out=$(cat "$TESTROOT/b.out")"
	fi

	# (c) with the shim it passes.
	rc=0
	LINUXROOT=$LINUXROOT BUILDDIR=$RB GB10_WORK=$WORK SHIM_ABSTRACT_DIR=$SADIR \
	    sh "$RUN" test_shim_abstract \
	    > "$TESTROOT/c.out" 2> "$TESTROOT/c.err" || rc=$?
	if [ "$rc" -eq 0 ] && grep -q '^PASS' "$TESTROOT/c.out"; then
		ok "(c) with the shim: test_shim_abstract passes"
	else
		fail "(c) with the shim: rc=$rc out=$(cat "$TESTROOT/c.out") err=$(cat "$TESTROOT/c.err")"
	fi

	# (k) SHIM_ABSTRACT=off: the shim stands aside for abstract names, so the
	# result is the kernel's, the same as (b).
	krc=0
	SHIM_ABSTRACT=off LINUXROOT=$LINUXROOT BUILDDIR=$RB GB10_WORK=$WORK \
	    SHIM_ABSTRACT_DIR=$SADIR sh "$RUN" test_shim_abstract \
	    > "$TESTROOT/k.out" 2> "$TESTROOT/k.err" || krc=$?
	if { [ "$brc" -eq 0 ] && [ "$krc" -eq 0 ]; } ||
	    { [ "$brc" -ne 0 ] && [ "$krc" -ne 0 ]; }; then
		ok "(k) SHIM_ABSTRACT=off gives the kernel's answer (rc=$krc, as (b))"
	else
		fail "(k) SHIM_ABSTRACT=off: rc=$krc but without the shim rc=$brc"
	fi
else
	skip "(a)(b)(c)(k) no Linux sysroot at $LINUXROOT/rl9 (or no clang): build and shim tests"
fi

# ---- Part 2: run-linux-cuda.sh against a stub loader ----
FAKE=$TESTROOT/work
FB=$FAKE/build/linux-cuda
mkdir -p "$FAKE/linuxroot/rl9/usr/lib" "$FAKE/linuxroot/nv" "$FB"
cat > "$FAKE/linuxroot/rl9/usr/lib/ld-linux-aarch64.so.1" <<'EOF2'
#!/bin/sh
# Stub for the Linux aarch64 dynamic loader: prints its arguments and the
# SHIM_* environment, exits 0.
for arg in "$@"; do
	printf 'ARG: %s\n' "$arg"
done
printf 'ENV: SHIM_ABSTRACT_DIR=%s\n' "${SHIM_ABSTRACT_DIR:-}"
printf 'ENV: SHIM_MMAP_MIN_ADDR=%s\n' "${SHIM_MMAP_MIN_ADDR:-}"
printf 'ENV: SHIM_COMM=%s\n' "${SHIM_COMM:-}"
exit 0
EOF2
chmod +x "$FAKE/linuxroot/rl9/usr/lib/ld-linux-aarch64.so.1"
: > "$FB/shim.so"
: > "$FB/cuda_smoke"
mkdir -p "$TESTROOT/home"

# runit - run the script against the fake root with a private HOME.
# Time:  O(1).
# Space: O(1).
runit() {
	env -u LINUXROOT -u BUILDDIR HOME="$TESTROOT/home" GB10_WORK="$FAKE" \
	    ${EXTRA_ENV:-} sh "$RUN" "$@"
}

# (d) --help and no arguments.
rc=0
runit --help > "$TESTROOT/d1.out" 2> "$TESTROOT/d1.err" || rc=$?
rc2=0
runit > "$TESTROOT/d2.out" 2> "$TESTROOT/d2.err" || rc2=$?
if [ "$rc" -eq 0 ] && grep -q 'Usage' "$TESTROOT/d1.out" && [ "$rc2" -eq 2 ] &&
    grep -q 'usage' "$TESTROOT/d2.err"; then
	ok "(d) --help exits 0 with usage; no argument exits 2"
else
	fail "(d) --help rc=$rc, no argument rc=$rc2"
fi

# (e) a missing ld-linux, shim and program.
mv "$FAKE/linuxroot/rl9/usr/lib/ld-linux-aarch64.so.1" "$TESTROOT/ld.keep"
rc=0
runit cuda_smoke > "$TESTROOT/e1.out" 2> "$TESTROOT/e1.err" || rc=$?
mv "$TESTROOT/ld.keep" "$FAKE/linuxroot/rl9/usr/lib/ld-linux-aarch64.so.1"
mv "$FB/shim.so" "$TESTROOT/shim.keep"
rc2=0
runit cuda_smoke > "$TESTROOT/e2.out" 2> "$TESTROOT/e2.err" || rc2=$?
mv "$TESTROOT/shim.keep" "$FB/shim.so"
rc3=0
runit nosuchprog > "$TESTROOT/e3.out" 2> "$TESTROOT/e3.err" || rc3=$?
if [ "$rc" -eq 1 ] && grep -q 'missing.*ld-linux' "$TESTROOT/e1.err" &&
    [ "$rc2" -eq 1 ] && grep -q 'missing.*shim.so' "$TESTROOT/e2.err" &&
    [ "$rc3" -eq 1 ] && grep -q 'missing.*nosuchprog' "$TESTROOT/e3.err" &&
    ! grep -q '^ARG:' "$TESTROOT/e1.out" "$TESTROOT/e2.out" "$TESTROOT/e3.out"; then
	ok "(e) missing ld-linux, shim, program: exit 1, nothing run"
else
	fail "(e) rc=$rc/$rc2/$rc3 err=$(cat "$TESTROOT/e1.err" "$TESTROOT/e2.err" "$TESTROOT/e3.err")"
fi

# (f) bare name looked up in BUILDDIR; a path used as is.
rc=0
runit cuda_smoke > "$TESTROOT/f1.out" 2> "$TESTROOT/f1.err" || rc=$?
: > "$TESTROOT/myprog"
rc2=0
runit "$TESTROOT/myprog" > "$TESTROOT/f2.out" 2> "$TESTROOT/f2.err" || rc2=$?
if [ "$rc" -eq 0 ] && grep -qx "ARG: $FB/cuda_smoke" "$TESTROOT/f1.out" &&
    [ "$rc2" -eq 0 ] && grep -qx "ARG: $TESTROOT/myprog" "$TESTROOT/f2.out"; then
	ok "(f) bare name from BUILDDIR, path as given"
else
	fail "(f) rc=$rc/$rc2 out=$(cat "$TESTROOT/f1.out" "$TESTROOT/f2.out")"
fi

# (g) loader arguments, program arguments after the program, in order.
rc=0
runit cuda_smoke -x "two words" > "$TESTROOT/g.out" 2> "$TESTROOT/g.err" || rc=$?
args=$(sed -n 's/^ARG: //p' "$TESTROOT/g.out" | tr '\n' '|')
want="--preload|$FB/shim.so|--library-path|$FAKE/linuxroot/nv:$FAKE/linuxroot/rl9/usr/lib64:$FAKE/linuxroot/rl9/usr/lib|$FB/cuda_smoke|-x|two words|"
if [ "$rc" -eq 0 ] && [ "$args" = "$want" ]; then
	ok "(g) --preload, --library-path and the program arguments"
else
	fail "(g) rc=$rc args=[$args] want=[$want]"
fi

# (h) the shim environment, with a short abstract directory under HOME.
sa=$(sed -n 's/^ENV: SHIM_ABSTRACT_DIR=//p' "$TESTROOT/g.out")
mm=$(sed -n 's/^ENV: SHIM_MMAP_MIN_ADDR=//p' "$TESTROOT/g.out")
cm=$(sed -n 's/^ENV: SHIM_COMM=//p' "$TESTROOT/g.out")
case "$sa" in "$TESTROOT/$(printf 'home')/.cache/"*) sa_ok=1 ;; *) sa_ok=0 ;; esac
if [ "$sa_ok" -eq 1 ] && [ "$(cat "$mm")" = "65536" ] && [ -s "$cm" ]; then
	ok "(h) SHIM_ABSTRACT_DIR=$sa, mmap_min_addr 65536, comm file"
else
	fail "(h) sa=$sa mm=$mm cm=$cm"
fi
rc=0
EXTRA_ENV=SHIM_ABSTRACT_DIR=/x/y
runit cuda_smoke > "$TESTROOT/h2.out" 2> "$TESTROOT/h2.err" || rc=$?
EXTRA_ENV=
if [ "$rc" -eq 0 ] && grep -qx 'ENV: SHIM_ABSTRACT_DIR=/x/y' "$TESTROOT/h2.out"; then
	ok "(h2) a SHIM_ABSTRACT_DIR given by the caller is kept"
else
	fail "(h2) rc=$rc out=$(cat "$TESTROOT/h2.out")"
fi

# (i) HOME and GB10_WORK unset: the script uses <repo>/work.  The copy under
# TESTROOT/scripts makes the existing fake tree that repository-local default.
mkdir -p "$TESTROOT/scripts"
cp "$RUN" "$TESTROOT/scripts/run-linux-cuda.sh"
rc=0
env -u HOME -u GB10_WORK -u LINUXROOT -u BUILDDIR \
    sh "$TESTROOT/scripts/run-linux-cuda.sh" cuda_smoke \
    > "$TESTROOT/i.out" 2> "$TESTROOT/i.err" || rc=$?
if [ "$rc" -eq 0 ] && grep -qx "ARG: $FB/cuda_smoke" "$TESTROOT/i.out" &&
    grep -qx "ENV: SHIM_ABSTRACT_DIR=$FAKE/.cache/sa" "$TESTROOT/i.out"; then
	ok "(i) HOME and GB10_WORK unset: repository-local work root"
else
	fail "(i) rc=$rc err=$(cat "$TESTROOT/i.err")"
fi

# (j) both scripts parse and are executable; build --help works.
rc=0
sh -n "$BUILD" || rc=1
sh -n "$RUN" || rc=1
rc2=0
sh "$BUILD" --help > "$TESTROOT/j.out" 2>&1 || rc2=$?
if [ "$rc" -eq 0 ] && [ -x "$BUILD" ] && [ -x "$RUN" ] && [ "$rc2" -eq 0 ] &&
    grep -q 'Usage' "$TESTROOT/j.out"; then
	ok "(j) both scripts parse and are executable; build --help works"
else
	fail "(j) parse rc=$rc help rc=$rc2"
fi

printf 'passed: %s failed: %s skipped: %s\n' "$PASSED" "$FAILED" "$SKIPPED"
[ "$FAILED" -eq 0 ]
