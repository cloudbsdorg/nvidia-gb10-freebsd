#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# render_uapi_layout_suite_test.sh - the behaviour of the render uAPI layout
# test itself (tests/render_uapi_layout_test.sh).
#
# This suite is about the render test and nothing else: the install-flow
# suite does not run it, so a change to the render test cannot break an
# install-only suite and an install-only suite needs no compiler.
#
# What it checks, by what the test does and not by what its source says:
#   1. a check that cannot run is a skip: the run ends with exit 0 and the
#      PASS line names the remedy of every skipped check, and only of those;
#   2. a skip is a failure when the caller says so: REQUIRE_INPUTS=yes and
#      CI=1 both exit 1;
#   3. RENDER_UAPI_ALLOW_SKIP=1 changes nothing: it is accepted and ignored;
#   4. the test itself cannot run: it exits 2 and says why (the render header
#      or the probe is missing, there is no temporary directory, or there is
#      no C compiler on PATH, and the message says how to get one);
#   5. the NVIDIA header of check 6 is looked for under the work root the
#      caller named; NVIDIA_IOCTL_H names it instead when it names a file
#      that exists, and when it names no file the skip says which path is
#      wrong instead of sending the user after the sources.
#
# Exit: 0 every check passed, 1 a check failed.

set -u
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
base=${GB10_WORK:-$repo/work}
mkdir -p -- "$base/tmp" || exit 2
S=$(mktemp -d "$base/tmp/render-layout-suite.XXXXXX") || exit 2
trap 'chmod -R u+w "$S" 2>/dev/null; rm -rf -- "$S"' EXIT
fail=0
ok() { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); }

render=$repo/tests/render_uapi_layout_test.sh
[ -f "$render" ] || { echo "render_uapi_layout_suite_test.sh: no render test to run" >&2; exit 2; }

# A work root with no fetched sources: the kernel compile and check 6 cannot
# run, so they are skips.
NOSRC=$S/no-sources
mkdir -p -- "$NOSRC"
SCRATCH=$S/scratch
mkdir -p -- "$SCRATCH"

# run_render [ENV...]: the render test in a scratch directory, with the
# caller's environment.  The output and the status are in $S/last.out and
# $S/last.rc.
run_render() {
	env "$@" TMPDIR="$SCRATCH" sh "$render" > "$S/last.out" 2>&1
	_rc=$?
	cat "$S/last.out" > "$S/last.saved"
	printf '%s' "$_rc" > "$S/last.rc"
	return 0
}

# 1. a skip is a skip: exit 0, and the PASS line names the remedy of every
# skipped check and of no other.
run_render -u SYSDIR -u CI -u REQUIRE_INPUTS -u NVIDIA_IOCTL_H -u RENDER_UAPI_ALLOW_SKIP \
    GB10_WORK="$NOSRC"
rc=$(cat "$S/last.rc")
pass=$(grep '^render_uapi_layout_test: PASS' "$S/last.saved" | tail -n 1)
if [ "$rc" = 0 ] \
    && printf '%s\n' "$pass" | grep -q 'kernel compile (set SYSDIR' \
    && printf '%s\n' "$pass" | grep -q "check 6 (run $repo/scripts/fetch-sources.sh"; then
	ok "the PASS line names the remedy of each skipped check"
else
	bad "the PASS line of the render layout test (rc $rc): [$pass]"
fi
if command -v c++ >/dev/null 2>&1; then
	if ! printf '%s\n' "$pass" | grep -qi 'c++'; then
		ok "the PASS line names no remedy for a check that ran"
	else
		bad "the PASS line names a remedy for the C++ check, which ran: [$pass]"
	fi
else
	if printf '%s\n' "$pass" | grep -q 'C++17 self-contained (install a c++ compiler'; then
		ok "the PASS line names the C++ remedy for the skipped C++ check"
	else
		bad "the PASS line names no remedy for the skipped C++ check: [$pass]"
	fi
fi
# 5. check 6 looks under the work root the caller named, and the skip says
# so: the path is the work root's sources directory, whatever the
# environment holds.
run_render -u SYSDIR -u CI -u REQUIRE_INPUTS -u NVIDIA_IOCTL_H -u RENDER_UAPI_ALLOW_SKIP \
    GB10_WORK="$NOSRC"
if grep -q "no NVIDIA nvidia-drm-ioctl.h under $NOSRC/sources" "$S/last.saved"; then
	ok "check 6 looks for the NVIDIA header under the work root it was given"
else
	bad "check 6 does not look under the work root: $(grep 'no NVIDIA' "$S/last.saved" | head -n 1)"
fi
# A NVIDIA_IOCTL_H that names no file: check 6 stays a skip, and the skip
# says which path is wrong.  Fetching the sources would not repair a path
# the caller chose, so the remedy is not "fetch the sources".
if env -u SYSDIR -u CI -u REQUIRE_INPUTS -u RENDER_UAPI_ALLOW_SKIP \
    NVIDIA_IOCTL_H="$NOSRC/not-there.h" GB10_WORK="$NOSRC" TMPDIR="$SCRATCH" \
    sh "$render" > "$S/ioctl.out" 2>&1; then
	ok "a NVIDIA_IOCTL_H that names no file leaves check 6 a skip"
else
	bad "a NVIDIA_IOCTL_H that names no file breaks the run: $(tail -n 2 "$S/ioctl.out" | tr '\n' ' ')"
fi
if grep -q 'SKIPPED: check 6' "$S/ioctl.out" \
    && grep -q "$NOSRC/not-there.h" "$S/ioctl.out" \
    && ! grep -q 'fetch-sources.sh' "$S/ioctl.out" \
    && grep -q 'NVIDIA_IOCTL_H' "$S/ioctl.out"; then
	ok "the skip of an override that names no file says which path, and does not send the user after the sources"
else
	bad "the skip of an override that names no file: $(grep 'SKIPPED: check 6' "$S/ioctl.out" | head -n 1)"
fi
_pass_ioctl=$(grep '^render_uapi_layout_test: PASS' "$S/ioctl.out" | tail -n 1)
if printf '%s\n' "$_pass_ioctl" | grep -q 'NVIDIA_IOCTL_H' \
    && printf '%s\n' "$_pass_ioctl" | grep -q 'set NVIDIA_IOCTL_H to an existing header'; then
	ok "the PASS summary names the remedy of the override that names no file"
else
	bad "the PASS summary of the override that names no file: [$_pass_ioctl]"
fi
# The converse: a NVIDIA_IOCTL_H that names a file that exists is the header
# check 6 reads, even when it is outside the work root.
OVR=$S/override.h
printf '#define DRM_NVIDIA_TEST 0x10\n' > "$OVR"
env -u SYSDIR -u CI -u REQUIRE_INPUTS -u RENDER_UAPI_ALLOW_SKIP \
    NVIDIA_IOCTL_H="$OVR" GB10_WORK="$NOSRC" TMPDIR="$SCRATCH" \
    sh "$render" > "$S/override.out" 2>&1
if ! grep -q 'SKIPPED: check 6' "$S/override.out" && grep -q "$OVR" "$S/override.out"; then
	ok "a NVIDIA_IOCTL_H that names a file that exists is the header check 6 reads"
else
	bad "the NVIDIA_IOCTL_H override was not used: $(grep -E 'SKIPPED: check 6|NVIDIA header|NVIDIA ioctl table' "$S/override.out" | head -n 2 | tr '\n' ' ')"
fi

# 2. a skip is a failure when the caller says so.
run_render -u SYSDIR -u CI -u REQUIRE_INPUTS -u NVIDIA_IOCTL_H -u RENDER_UAPI_ALLOW_SKIP \
    GB10_WORK="$NOSRC" REQUIRE_INPUTS=yes
rc=$(cat "$S/last.rc")
if [ "$rc" = 1 ]; then
	ok "a skip is a failure with REQUIRE_INPUTS=yes"
else
	bad "a skip with REQUIRE_INPUTS=yes exits $rc, not 1"
fi
run_render -u SYSDIR -u REQUIRE_INPUTS -u NVIDIA_IOCTL_H -u RENDER_UAPI_ALLOW_SKIP \
    GB10_WORK="$NOSRC" CI=1
rc=$(cat "$S/last.rc")
if [ "$rc" = 1 ]; then
	ok "a skip is a failure with CI=1"
else
	bad "a skip with CI=1 exits $rc, not 1"
fi

# 3. RENDER_UAPI_ALLOW_SKIP=1 is accepted and changes nothing: a skip is
# still a skip, and still a failure when the caller says so.
run_render -u SYSDIR -u CI -u REQUIRE_INPUTS -u NVIDIA_IOCTL_H \
    GB10_WORK="$NOSRC" RENDER_UAPI_ALLOW_SKIP=1 REQUIRE_INPUTS=yes
rc=$(cat "$S/last.rc")
if [ "$rc" = 1 ]; then
	ok "RENDER_UAPI_ALLOW_SKIP=1 is a no-op: a skip is still a failure"
else
	bad "RENDER_UAPI_ALLOW_SKIP=1 exits $rc, not 1"
fi
run_render -u SYSDIR -u CI -u REQUIRE_INPUTS -u NVIDIA_IOCTL_H \
    GB10_WORK="$NOSRC" RENDER_UAPI_ALLOW_SKIP=1
rc=$(cat "$S/last.rc")
if [ "$rc" = 0 ]; then
	ok "RENDER_UAPI_ALLOW_SKIP=1 is accepted and ignored"
else
	bad "RENDER_UAPI_ALLOW_SKIP=1 exits $rc, not 0"
fi

# 4. the test itself cannot run: it exits 2 and says why.
# A copy of the test without the header beside it: the header is missing.
NOREPO=$S/no-repo
mkdir -p -- "$NOREPO/tests"
cp "$render" "$NOREPO/tests/render_uapi_layout_test.sh"
env -u SYSDIR -u CI -u REQUIRE_INPUTS -u NVIDIA_IOCTL_H -u RENDER_UAPI_ALLOW_SKIP \
    GB10_WORK="$NOSRC" TMPDIR="$SCRATCH" sh "$NOREPO/tests/render_uapi_layout_test.sh" \
    > "$S/nohdr.out" 2>&1
rc=$?
if [ "$rc" = 2 ] && grep -q 'missing .*nvidia-drm-render.h' "$S/nohdr.out"; then
	ok "a missing render header is exit 2, and the message says so"
else
	bad "a missing render header (rc $rc): $(tail -n 2 "$S/nohdr.out" | tr '\n' ' ')"
fi
# A copy of the test with the header but without the probe: the probe is
# missing.
mkdir -p -- "$NOREPO/src/nvidia-drm-render"
cp "$repo/src/nvidia-drm-render/nvidia-drm-render.h" "$NOREPO/src/nvidia-drm-render/"
env -u SYSDIR -u CI -u REQUIRE_INPUTS -u NVIDIA_IOCTL_H -u RENDER_UAPI_ALLOW_SKIP \
    GB10_WORK="$NOSRC" TMPDIR="$SCRATCH" sh "$NOREPO/tests/render_uapi_layout_test.sh" \
    > "$S/noprobe.out" 2>&1
rc=$?
if [ "$rc" = 2 ] && grep -q 'missing .*render_uapi_layout.c' "$S/noprobe.out"; then
	ok "a missing probe is exit 2, and the message says so"
else
	bad "a missing probe (rc $rc): $(tail -n 2 "$S/noprobe.out" | tr '\n' ' ')"
fi
# A temporary directory that cannot be made: the test cannot run.
: > "$S/not-a-dir"
env -u SYSDIR -u CI -u REQUIRE_INPUTS -u NVIDIA_IOCTL_H -u RENDER_UAPI_ALLOW_SKIP \
    GB10_WORK="$NOSRC" TMPDIR="$S/not-a-dir/inside" sh "$render" > "$S/notmp.out" 2>&1
rc=$?
if [ "$rc" = 2 ] && grep -q 'cannot create' "$S/notmp.out"; then
	ok "a temporary directory that cannot be made is exit 2, and the message says so"
else
	bad "a temporary directory that cannot be made (rc $rc): $(tail -n 2 "$S/notmp.out" | tr '\n' ' ')"
fi
# No C compiler on PATH: the test cannot run, and the message says how to
# get one.  The copy of the test has no compiler on its PATH; it lives where
# its own REPO still resolves, so it finds its header and its probe.
NOCC=$S/no-cc
mkdir -p "$NOCC/tests" "$NOCC/src/nvidia-drm-render" "$NOCC/bin"
cp "$repo/src/nvidia-drm-render/nvidia-drm-render.h" "$NOCC/src/nvidia-drm-render/"
cp "$repo/tests/render_uapi_layout.c" "$NOCC/tests/"
# The copy keeps the one tool it needs to find its own directory; the
# compiler is what is missing.
_dirname=$(command -v dirname) || _dirname=/usr/bin/dirname
ln -s "$_dirname" "$NOCC/bin/dirname"
sed "s|^PATH=.*|PATH=$NOCC/bin|" "$render" > "$NOCC/tests/render_uapi_layout_test.sh"
env -u SYSDIR -u CI -u REQUIRE_INPUTS -u NVIDIA_IOCTL_H -u RENDER_UAPI_ALLOW_SKIP \
    GB10_WORK="$NOSRC" TMPDIR="$SCRATCH" sh "$NOCC/tests/render_uapi_layout_test.sh" \
    > "$S/nocc.out" 2>&1
rc=$?
if [ "$rc" = 2 ] && grep -qi 'install' "$S/nocc.out" && grep -q 'PATH' "$S/nocc.out"; then
	ok "no C compiler on PATH is exit 2, and the message says how to get one"
else
	bad "no C compiler on PATH (rc $rc): $(tail -n 2 "$S/nocc.out" | tr '\n' ' ')"
fi

if [ "$fail" = 0 ]; then
	echo "render_uapi_layout_suite_test: PASS"
	exit 0
fi
echo "render_uapi_layout_suite_test: FAIL ($fail check(s) failed)"
exit 1
