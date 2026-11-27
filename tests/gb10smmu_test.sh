#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# gb10smmu_test.sh - the module that programs the SMMU in front of the GB10
# GPU: it builds, it is in the list of files make stage lays out, its
# manual page says what it does, and its IORT parser does what the IORT
# says it does.
#
# Cases:
#   (a) the module builds on this host and the result is gb10smmu.ko,
#       linked by LLD (the module is arm64 only: on another architecture
#       the build is refused and the case is skipped)
#   (b) the checkout keeps no build output: the module is built in the work
#       root, not in the tree
#   (c) make stage lays out /boot/modules/gb10smmu.ko and its file list
#       names it -- on arm64.  On another architecture the module is not
#       installed, and the test says so
#   (d) the list the manifest is built from names gb10smmu.ko -- on arm64.
#       On another architecture it does not, and the test says so
#   (e) the manual page lints clean and says what the module reads, in
#       which order it is loaded and that it is never unloaded while the
#       driver is loaded
#   (f) the IORT parser: the unit test builds the same parser source the
#       module builds and runs it over hand-made IORT tables
#   (g) the boot configuration: the loader is told to load the module only
#       on a machine that has the GB10 GPU, and it does so before anything
#       of NVIDIA is loaded
#   (h) the build script: its help, the path it refuses, and the make
#       environment it does not take from the caller
#   (i) the rules that recognise the GB10 GPU: the unit test builds the
#       same header the module builds
#   (j) the module programs the SMMU of that GPU and of no other device:
#       it refuses to attach without it
#   (k) the check for the nvidia driver and the change of the SMMU happen
#       under one hold: there is no check-then-use
#   (l) the unload path: a refused unload keeps the module loaded, so the
#       lock the module holds is still in use and is not destroyed
#
# Run: sh tests/gb10smmu_test.sh

set -u

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

TESTSDIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$TESTSDIR/.." && pwd -P)

PASSED=0
FAILED=0

# Scratch inside the repository (tmp/ is git-ignored), not in the system
# temporary directory and not outside the repository.
mkdir -p "$REPO/tmp"
TESTROOT=$(mktemp -d "$REPO/tmp/gb10smmu-test.XXXXXXXX") || exit 1

cleanup() {
	rm -rf "$TESTROOT"
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

WORK=$TESTROOT/work
mkdir -p "$WORK"

# The architecture: the module of ours programs an arm64 SMMU, so it is
# built and installed on arm64 only.
_arm64=0
case $(uname -m) in
arm64|aarch64) _arm64=1 ;;
esac

# (a) the module builds.
if [ "$_arm64" -eq 0 ]; then
	printf 'skip (a) the module is arm64 only and this host is %s\n' "$(uname -m)"
else
	rc=0
	GB10_WORK="$WORK" sh "$REPO/scripts/build-gb10smmu.sh" > "$TESTROOT/build.log" 2>&1 || rc=$?
	if [ "$rc" -eq 0 ] && [ -s "$WORK/build/gb10smmu.ko" ]; then
		ok "(a) gb10smmu.ko builds"
	else
		fail "(a) the build failed (rc $rc): $(tail -n 3 "$TESTROOT/build.log" | tr '\n' ' ')"
	fi
	if [ -s "$WORK/build/gb10smmu.ko" ] && \
	    readelf -p .comment "$WORK/build/gb10smmu.ko" 2>/dev/null | grep -q 'Linker: LLD'; then
		ok "(a) gb10smmu.ko was linked by LLD"
	else
		fail "(a) gb10smmu.ko was not linked by LLD"
	fi
fi

# (b) the checkout keeps no build output.
_left=$(find "$REPO/src/gb10-smmu" \( -name '*.o' -o -name '*.ko' -o -name '*.kld' \
    -o -name obj -o -name 'opt_*.h' -o -name 'device_if.h' -o -name 'bus_if.h' \) 2>/dev/null | head -1)
if [ -z "$_left" ]; then
	ok "(b) the checkout keeps no build output"
else
	fail "(b) the build left $_left in the checkout"
fi

# plant_work: a work root with the modules, the libraries and the files
# make stage copies, so the staging step can run without a full build.
plant_work() {
	_w=$1
	_t=$_w/build/tree
	for _ko in $(sh "$REPO/scripts/make.sh" _module-list); do
		mkdir -p "$_t/$(dirname -- "$_ko")"
		printf 'planted %s\n' "$_ko" > "$_t/$_ko"
	done
	_l=$_w/build/libnvrm-obj
	_ogkm=$_w/sources/open-gpu-kernel-modules-$(awk '$1 == "ogkm_tag" { print $2 }' "$REPO/SOURCES")
	mkdir -p "$_l/lib" "$_l/info" "$_w/sources" "$_w/src/sys/sys" "$_ogkm/.git"
	printf 'so\n' > "$_l/lib/libnvrm.so.1"
	printf 'a\n' > "$_l/lib/libnvrm.a"
	printf 'prog\n' > "$_l/info/nvrm-info"
	printf 'drm\n' > "$_w/build/drm.ko"
	printf 'dmabuf\n' > "$_w/build/dmabuf.ko"
	# The module of ours: on a host that cannot build it (not arm64) the
	# staging step still needs a file to lay out.  The build of case (a)
	# left its own module here, and it is read-only: it goes first.
	rm -f "$_w/build/gb10smmu.ko"
	printf 'gb10smmu\n' > "$_w/build/gb10smmu.ko"
	printf 'licence\n' > "$_w/sources/nvidia-license.txt"
	printf '#define __FreeBSD_version %s\n' "$(sysctl -n kern.osreldate)" \
	    > "$_w/src/sys/sys/param.h"
}

plant_work "$WORK"
rc=0
MK_WORK="$WORK" MK_SYSDIR="$WORK/src/sys" MK_BSDSRCTOP="$WORK/src" \
    MK_DRMKMODDIR="$WORK/drm-kmod" \
    sh "$REPO/scripts/make.sh" _stage > "$TESTROOT/stage.log" 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
	fail "(c) the staging failed (rc $rc): $(tail -n 3 "$TESTROOT/stage.log" | tr '\n' ' ')"
elif [ "$_arm64" -eq 1 ]; then
	if [ -f "$WORK/stage/boot/modules/gb10smmu.ko" ]; then
		ok "(c) make stage lays out /boot/modules/gb10smmu.ko"
	else
		fail "(c) make stage does not lay out /boot/modules/gb10smmu.ko"
	fi
	if (cd "$WORK/stage" && find . -type f -name 'gb10smmu.ko' | grep -q .); then
		ok "(c) the staged file list names gb10smmu.ko"
	else
		fail "(c) the staged file list does not name gb10smmu.ko"
	fi
else
	if [ -f "$WORK/stage/boot/modules/gb10smmu.ko" ]; then
		fail "(c) make stage lays out gb10smmu.ko on $(uname -m): it is arm64 only"
	else
		ok "(c) make stage does not lay out gb10smmu.ko on $(uname -m)"
	fi
fi

# (d) the list the manifest is built from: the paths make install writes.
# The list holds install paths, not bare names, and the staged file list
# is what the manifest is written from.
if [ "$_arm64" -eq 1 ]; then
	if sh "$REPO/scripts/make.sh" _install-module-list | grep -qx '/boot/modules/gb10smmu.ko'; then
		ok "(d) the install module list names /boot/modules/gb10smmu.ko"
	else
		fail "(d) the install module list does not name /boot/modules/gb10smmu.ko"
	fi
	if (cd "$WORK/stage" && find . \( -type f -o -type l \) | sed 's|^\.||' | sort) \
	    | grep -qx '/boot/modules/gb10smmu.ko'; then
		ok "(d) the staged file list the manifest is built from names /boot/modules/gb10smmu.ko"
	else
		fail "(d) the staged file list does not name /boot/modules/gb10smmu.ko"
	fi
else
	if sh "$REPO/scripts/make.sh" _install-module-list | grep -qx '/boot/modules/gb10smmu.ko'; then
		fail "(d) the install module list names gb10smmu.ko on $(uname -m): it is arm64 only"
	else
		ok "(d) the install module list does not name gb10smmu.ko on $(uname -m)"
	fi
fi

# (e) the manual page.
PAGE=$REPO/man/gb10smmu.4
if [ ! -f "$PAGE" ]; then
	fail "(e) man/gb10smmu.4 is missing"
else
	rc=0
	mandoc -T lint "$PAGE" > "$TESTROOT/lint.out" 2>&1 || rc=$?
	if [ "$rc" -eq 0 ] && [ ! -s "$TESTROOT/lint.out" ]; then
		ok "(e) man/gb10smmu.4: mandoc -T lint is clean"
	else
		fail "(e) man/gb10smmu.4: rc=$rc $(tr '\n' ' ' < "$TESTROOT/lint.out")"
	fi
	_miss=
	for _word in IORT nvidia "Never unload" SMMUv3 "gb10smmu.mode" \
	    "sysctl debug.gb10smmu.dump=1" "sysctl debug.gb10smmu.events" \
	    "sysctl debug.gb10smmu.mode" "refuses to load"; do
		grep -q -- "$_word" "$PAGE" 2>/dev/null || _miss="$_miss $_word"
	done
	if [ -z "$_miss" ]; then
		ok "(e) the page names the IORT, the load order, the never-unload rule and the controls"
	else
		fail "(e) the page does not say:$_miss"
	fi
	# The loader variable of the synopsis is the one the module reads.
	if grep -q 'gb10smmu_mode=' "$PAGE"; then
		fail "(e) the page still uses the loader variable the module does not read"
	else
		ok "(e) the page uses the loader variable the module reads"
	fi
fi

# (g) the boot configuration: on arm64 the loader configuration has to load
# the module and to give it the mode it needs, and it has to do that
# before anything of NVIDIA is loaded.  The module programs the SMMU in
# front of the GB10 GPU, so the loader is told to load it only on a
# machine that has that GPU.
CDIR=$TESTROOT/destdir
mkdir -p "$CDIR/boot" "$CDIR/etc" "$CDIR/var/db"
rc=0
MK_WORK="$WORK" MK_DESTDIR="$CDIR" MK_SYSDIR="$WORK/src/sys" \
    MK_BSDSRCTOP="$WORK/src" MK_DRMKMODDIR="$WORK/drm-kmod" MK_YES=1 \
    MK_GB10_PCI=1 \
    sh "$REPO/scripts/make.sh" configure > "$TESTROOT/configure.log" 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
	fail "(g) make configure failed (rc $rc): $(tail -n 3 "$TESTROOT/configure.log" | tr '\n' ' ')"
elif [ "$_arm64" -eq 1 ]; then
	if grep -q '^gb10smmu_load="YES"' "$CDIR/boot/loader.conf"; then
		ok "(g) the loader configuration loads gb10smmu.ko"
	else
		fail "(g) the loader configuration does not load gb10smmu.ko"
	fi
	if grep -q '^gb10smmu.mode="2"' "$CDIR/boot/loader.conf"; then
		ok "(g) the loader configuration gives the module its mode"
	else
		fail "(g) the loader configuration does not give the module its mode"
	fi
	_gb=$(grep -n '^gb10smmu_load=' "$CDIR/boot/loader.conf" | head -1 | cut -d: -f1)
	_nv=$(grep -n '^hw.nvidia' "$CDIR/boot/loader.conf" | head -1 | cut -d: -f1)
	if [ -n "$_gb" ] && [ -n "$_nv" ] && [ "$_gb" -lt "$_nv" ]; then
		ok "(g) the module is loaded before the NVIDIA settings"
	else
		fail "(g) the module is not loaded before the NVIDIA settings (gb10smmu line $_gb, nvidia line $_nv)"
	fi
else
	if grep -q 'gb10smmu' "$CDIR/boot/loader.conf"; then
		fail "(g) the loader configuration loads gb10smmu.ko on $(uname -m): it is arm64 only"
	else
		ok "(g) the loader configuration does not load gb10smmu.ko on $(uname -m)"
	fi
fi

# (g) a machine without the GB10 GPU must not be told to load the module:
# it has nothing to program, and the SMMU of another device is not ours.
CDIR2=$TESTROOT/destdir-nogpu
mkdir -p "$CDIR2/boot" "$CDIR2/etc" "$CDIR2/var/db"
rc=0
MK_WORK="$WORK" MK_DESTDIR="$CDIR2" MK_SYSDIR="$WORK/src/sys" \
    MK_BSDSRCTOP="$WORK/src" MK_DRMKMODDIR="$WORK/drm-kmod" MK_YES=1 \
    MK_GB10_PCI=0 \
    sh "$REPO/scripts/make.sh" configure > "$TESTROOT/configure-nogpu.log" 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
	fail "(g) make configure failed (rc $rc): $(tail -n 3 "$TESTROOT/configure-nogpu.log" | tr '\n' ' ')"
elif grep -q 'gb10smmu' "$CDIR2/boot/loader.conf"; then
	fail "(g) the loader configuration loads gb10smmu.ko on a machine without the GPU"
else
	ok "(g) the loader configuration does not load gb10smmu.ko without the GPU"
fi

# (h) the build script: its help, the path it refuses, and the make
# environment it does not take from the caller.
rc=0
sh "$REPO/scripts/build-gb10smmu.sh" --help > "$TESTROOT/help.out" 2>&1 || rc=$?
if [ "$rc" -eq 0 ] && grep -q 'LOG' "$TESTROOT/help.out" && \
    grep -q 'logs' "$TESTROOT/help.out" && grep -qi 'arm64' "$TESTROOT/help.out"; then
	ok "(h) the build script has a help that says what it takes"
else
	fail "(h) the build script has no usable help (rc $rc)"
fi
rc=0
GB10_WORK="$WORK" sh "$REPO/scripts/build-gb10smmu.sh" \
    "$TESTROOT/outside.log" > "$TESTROOT/badlog.out" 2>&1 || rc=$?
if [ "$rc" -ne 0 ] && grep -q 'logs' "$TESTROOT/badlog.out"; then
	ok "(h) the build script refuses a log outside its logs directory"
else
	fail "(h) the build script took a log outside its logs directory (rc $rc)"
fi
# The environment of the caller must not reach make: MAKEFILES would make
# make run a rule of the caller's before anything of ours.
mkdir -p "$TESTROOT/evil"
cat > "$TESTROOT/evil/evil.mk" <<EOF
all:
	touch $TESTROOT/evil/marker
EOF
rm -f "$TESTROOT/evil/marker"
rc=0
MAKEFILES=$TESTROOT/evil/evil.mk GB10_WORK="$WORK" \
    sh "$REPO/scripts/build-gb10smmu.sh" > "$TESTROOT/evil.log" 2>&1 || rc=$?
if [ -e "$TESTROOT/evil/marker" ]; then
	fail "(h) the build ran a rule of the caller's MAKEFILES"
else
	ok "(h) the build does not run a rule of the caller's MAKEFILES"
fi

# (f) the IORT parser: the same source the module builds, over tables the
# test builds by hand.
SYSDIR=${SYSDIR:-/usr/src/sys}
ACPIHDR=$SYSDIR/contrib/dev/acpica/include/acpi.h
if [ ! -f "$ACPIHDR" ]; then
	printf 'skip (f) no ACPI headers at %s: the parser cannot be built\n' "$ACPIHDR"
else
	rc=0
	cc -O2 -Wall -Wextra -Wno-unused-parameter -I"$SYSDIR" \
	    -I"$REPO/src/gb10-smmu" -o "$TESTROOT/iort_test" \
	    "$REPO/tests/gb10smmu_iort_test.c" \
	    "$REPO/src/gb10-smmu/gb10smmu_iort.c" > "$TESTROOT/iort_build.log" 2>&1 || rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "(f) the IORT parser test does not build: $(tail -n 3 "$TESTROOT/iort_build.log" | tr '\n' ' ')"
	else
		ok "(f) the IORT parser test builds"
		rc=0
		"$TESTROOT/iort_test" > "$TESTROOT/iort_test.log" 2>&1 || rc=$?
		if [ "$rc" -eq 0 ]; then
			ok "(f) the IORT parser test passes: $(tail -n 1 "$TESTROOT/iort_test.log")"
		else
			fail "(f) the IORT parser test fails: $(grep '^FAIL' "$TESTROOT/iort_test.log" | tr '\n' ' ')"
		fi
	fi
fi

# (i) the rules that recognise the GB10 GPU: the unit test builds the
# same header the module builds.
rc=0
cc -O2 -Wall -Wextra -I"$REPO/src/gb10-smmu" -o "$TESTROOT/gpu_test" \
    "$REPO/tests/gb10smmu_gpu_test.c" > "$TESTROOT/gpu_build.log" 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
	fail "(i) the GPU rules test does not build: $(tail -n 3 "$TESTROOT/gpu_build.log" | tr '\n' ' ')"
else
	ok "(i) the GPU rules test builds"
	rc=0
	"$TESTROOT/gpu_test" > "$TESTROOT/gpu_test.log" 2>&1 || rc=$?
	if [ "$rc" -eq 0 ]; then
		ok "(i) the GPU rules test passes: $(tail -n 1 "$TESTROOT/gpu_test.log")"
	else
		fail "(i) the GPU rules test fails: $(grep '^FAIL' "$TESTROOT/gpu_test.log" | tr '\n' ' ')"
	fi
fi

# (j) the module programs the SMMU of the GB10 GPU and of no other
# device: it looks for that GPU in the device tree and refuses to attach
# without it.
MODULE=$REPO/src/gb10-smmu/gb10smmu.c
if grep -q 'gb10smmu_is_gb10' "$MODULE" && \
    grep -q 'refusing to attach: this machine has no' "$MODULE"; then
	ok "(j) the module looks for the GB10 GPU and refuses without it"
else
	fail "(j) the module does not look for the GB10 GPU in the device tree"
fi

# (k) the check for the nvidia driver and the change of the SMMU happen
# under one hold: there is no check-then-use.
_body() {
	sed -n "/^$1(void)\$/,/^}/p" "$MODULE"
}
_ln() {
	printf '%s\n' "$1" | grep -n "$2" | head -1 | cut -d: -f1
}
_start_body=$(_body gb10smmu_start)
_stop_body=$(_body gb10smmu_stop)
_held_body=$(_body gb10smmu_start_held)
_sheld_body=$(_body gb10smmu_stop_held)
_hold=$(_ln "$_start_body" 'gb10smmu_hold();')
_call=$(_ln "$_start_body" 'gb10smmu_start_held();')
_unhold=$(_ln "$_start_body" 'gb10smmu_unhold();')
if [ -n "$_hold" ] && [ -n "$_call" ] && [ -n "$_unhold" ] && \
    [ "$_hold" -lt "$_call" ] && [ "$_call" -lt "$_unhold" ]; then
	ok "(k) the load path holds the lock across the check and the change"
else
	fail "(k) the load path does not hold the lock across the check and the change"
fi
_hold=$(_ln "$_stop_body" 'gb10smmu_hold();')
_call=$(_ln "$_stop_body" 'gb10smmu_stop_held();')
_unhold=$(_ln "$_stop_body" 'gb10smmu_unhold();')
if [ -n "$_hold" ] && [ -n "$_call" ] && [ -n "$_unhold" ] && \
    [ "$_hold" -lt "$_call" ] && [ "$_call" -lt "$_unhold" ]; then
	ok "(k) the unload path holds the lock across the check and the change"
else
	fail "(k) the unload path does not hold the lock across the check and the change"
fi
if printf '%s\n' "$_held_body" | grep -q 'gb10smmu_before_nvidia();' && \
    printf '%s\n' "$_held_body" | grep -q 'gb10smmu_enable();' && \
    printf '%s\n' "$_sheld_body" | grep -q 'nvidia_attached()'; then
	ok "(k) the check and the change are in the held part of the paths"
else
	fail "(k) the check and the change are not both in the held part"
fi

# (l) the unload path: a refused unload keeps the module loaded, so the
# lock the module holds is still in use and must not be destroyed.
# The code under test is the module's own gb10smmu_stop(), taken out of the
# module source and compiled with fakes.
UNLOAD=$TESTROOT/unload
mkdir -p "$UNLOAD"
_extract_func() {	# _extract_func <name> <out>: the function, with its
			# return type, out of the module source
	_sig=$(grep -n "^$1(" "$MODULE" | head -1 | cut -d: -f1)
	[ -n "$_sig" ] || return 1
	_end=$(awk -v s="$_sig" 'NR > s && /^}$/ { print NR; exit }' "$MODULE")
	[ -n "$_end" ] || return 1
	sed -n "$((_sig - 1)),${_end}p" "$MODULE" > "$2"
}
if ! _extract_func gb10smmu_stop "$UNLOAD/gb10smmu_stop_case.inc"; then
	fail "(l) the module has no gb10smmu_stop() to test"
else
	ok "(l) the module's own gb10smmu_stop() is the code under test"
	rc=0
	cc -O2 -Wall -Wextra -I"$UNLOAD" -o "$UNLOAD/unload_test" \
	    "$REPO/tests/gb10smmu_unload_test.c" > "$TESTROOT/unload_build.log" 2>&1 || rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "(l) the unload test does not build: $(tail -n 3 "$TESTROOT/unload_build.log" | tr '\n' ' ')"
	else
		ok "(l) the unload test builds"
		rc=0
		"$UNLOAD/unload_test" > "$TESTROOT/unload_test.log" 2>&1 || rc=$?
		if [ "$rc" -eq 0 ]; then
			ok "(l) a refused unload keeps the lock: $(tail -n 1 "$TESTROOT/unload_test.log")"
		else
			fail "(l) a refused unload destroys the lock: $(grep '^FAIL' "$TESTROOT/unload_test.log" | tr '\n' ' ')"
		fi
		# The control: the same test against a module whose unload path
		# ignores the refusal has to fail, or the test sees nothing.
		mkdir -p "$UNLOAD/mutant"
		sed 's/if (error != 0)/if (1)/' "$UNLOAD/gb10smmu_stop_case.inc" \
		    > "$UNLOAD/mutant/gb10smmu_stop_case.inc"
		if cmp -s "$UNLOAD/gb10smmu_stop_case.inc" \
		    "$UNLOAD/mutant/gb10smmu_stop_case.inc"; then
			fail "(l) the control did not change the module's unload path"
		else
			rc=0
			cc -O2 -Wall -Wextra -I"$UNLOAD/mutant" -I"$UNLOAD" \
			    -o "$UNLOAD/unload_test_mutant" \
			    "$REPO/tests/gb10smmu_unload_test.c" \
			    > "$TESTROOT/unload_mutant_build.log" 2>&1 || rc=$?
			if [ "$rc" -ne 0 ]; then
				fail "(l) the control does not build: $(tail -n 3 "$TESTROOT/unload_mutant_build.log" | tr '\n' ' ')"
			else
				rc=0
				"$UNLOAD/unload_test_mutant" > "$TESTROOT/unload_mutant.log" 2>&1 || rc=$?
				if [ "$rc" -eq 0 ]; then
					fail "(l) the control passes: the test cannot see a refused unload that destroys the lock"
				else
					ok "(l) the control fails: the test sees a refused unload that destroys the lock"
				fi
			fi
		fi
	fi
fi

printf 'passed: %s failed: %s\n' "$PASSED" "$FAILED"
if [ "$FAILED" -gt 0 ]; then
	exit 1
fi
exit 0
