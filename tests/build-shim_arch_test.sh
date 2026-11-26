#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# build-shim_arch_test.sh - scripts/build-shim.sh builds the OS layer for
# the running architecture (Track #2475). Offline: a fake prepared tree
# and a fake module Makefile, no kldload. Scratch under work/tmp, never
# /tmp.
#   (a) Hooked amd64 nvidia: make gets MACHINE=amd64 MACHINE_ARCH=amd64,
#       and the default RMOBJ is still $GB10_WORK/build/nv-kernel-gb10.o
#       (the arch-neutral stubs output).
#   (b) Hooked amd64 modeset: same MACHINE/MACHINE_ARCH, and the default
#       RMOBJ is $GB10_WORK/build/nv-modeset-kernel-amd64.o.
#   (c) Hooked aarch64: make still gets MACHINE=arm64 MACHINE_ARCH=aarch64;
#       nvidia default RMOBJ stays nv-kernel-gb10.o; modeset default RMOBJ
#       stays nv-modeset-kernel-aarch64.o (the arm64 path is unchanged).
#   (d) Live FreeBSD amd64 with no arch hook: same defaults as (a).
# Hooks: GB10_TEST_HOOKS=1 and GB10_TEST_ARCH=amd64|aarch64.

set -u
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

TESTSDIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo=$(CDPATH='' cd -- "$TESTSDIR/.." && pwd -P)
SCRIPT="$repo/scripts/build-shim.sh"
base=${GB10_WORK:-$repo/work}
mkdir -p -- "$base/tmp"
chmod 755 "$base/tmp" 2>/dev/null || true
TESTROOT=$(mktemp -d "$base/tmp/shim-arch.XXXXXX") || exit 1

PASSED=0
FAILED=0
ok() { PASSED=$((PASSED + 1)); printf 'ok    %s\n' "$1"; }
fail() { FAILED=$((FAILED + 1)); printf 'FAIL  %s\n' "$1"; }
cleanup() { rm -rf "$TESTROOT"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [ ! -f "$SCRIPT" ]; then
	fail "scripts/build-shim.sh does not exist"
	echo "passed: $PASSED failed: $FAILED"
	exit 1
fi

TREE=$TESTROOT/build/tree
SYSA=$TESTROOT/sys-a
mkdir -p "$TREE/nvidia" "$TREE/nvidia-modeset" "$TESTROOT/logs" "$TESTROOT/tmp" "$TESTROOT/build" "$SYSA/sys"
chmod 755 "$TESTROOT/tmp"
printf 'gb10 prepare-tree.sh %s\nstate done\n' "$TREE" > "$TREE/.prepared"
printf '#define __FreeBSD_version 1600001\n' > "$SYSA/sys/param.h"
# Dummy RM objects so the default RMOBJ path is visible in "rm core:" lines.
printf 'gb10-core\n' > "$TESTROOT/build/nv-kernel-gb10.o"
printf 'modeset-amd64\n' > "$TESTROOT/build/nv-modeset-kernel-amd64.o"
printf 'modeset-aarch64\n' > "$TESTROOT/build/nv-modeset-kernel-aarch64.o"

# Makefile records the MACHINE / MACHINE_ARCH make was given, inside the .ko.
write_makefile() {
	_dir=$1
	_ko=$2
	mkdir -p "$TREE/$_dir"
	printf 'all: %s\n\n%s: fake.o\n\tcat fake.o > %s\n\nfake.o:\n\tprintf "MACHINE=%%s MACHINE_ARCH=%%s\\n" "${MACHINE}" "${MACHINE_ARCH}" > fake.o\n\nclean:\n\trm -f fake.o %s\n' \
		"$_ko" "$_ko" "$_ko" "$_ko" \
		> "$TREE/$_dir/Makefile"
}

write_makefile nvidia nvidia.ko
write_makefile nvidia-modeset nvidia-modeset.ko

reset_mod() {
	_dir=$1
	rm -f "$TREE/$_dir"/*.o "$TREE/$_dir"/*.ko "$TREE/$_dir"/.gb10-sysdir
}

run_shim() {
	_arch=$1
	_mod=$2
	_tag=$3
	_hooked=$4
	reset_mod nvidia
	reset_mod nvidia-modeset
	rc=0
	if [ "$_hooked" = hook ]; then
		GB10_WORK="$TESTROOT" SYSDIR="$SYSA" GB10_TEST_HOOKS=1 \
			GB10_TEST_ARCH="$_arch" \
			sh "$SCRIPT" --module="$_mod" "$TREE" "$TESTROOT/logs/shim-$_tag.log" \
			>"$TESTROOT/out-$_tag" 2>"$TESTROOT/err-$_tag" || rc=$?
	else
		GB10_WORK="$TESTROOT" SYSDIR="$SYSA" GB10_TEST_HOOKS=1 \
			sh "$SCRIPT" --module="$_mod" "$TREE" "$TESTROOT/logs/shim-$_tag.log" \
			>"$TESTROOT/out-$_tag" 2>"$TESTROOT/err-$_tag" || rc=$?
	fi
	echo "$rc"
}

# (a) hooked amd64 nvidia
rc=$(run_shim amd64 nvidia a hook)
a_ok=1
[ "$rc" -eq 0 ] || a_ok=0
grep -q '^build: OK$' "$TESTROOT/out-a" || a_ok=0
grep -q '^MACHINE=amd64 MACHINE_ARCH=amd64$' "$TREE/nvidia/nvidia.ko" || a_ok=0
grep -q "^rm core: $TESTROOT/build/nv-kernel-gb10.o -> " "$TESTROOT/out-a" || a_ok=0
if grep -q 'MACHINE=arm64\|MACHINE_ARCH=aarch64' "$TREE/nvidia/nvidia.ko" 2>/dev/null; then a_ok=0; fi
if [ "$a_ok" -eq 1 ]; then
	ok "(a) hooked amd64 nvidia: MACHINE=amd64 MACHINE_ARCH=amd64, default RMOBJ nv-kernel-gb10.o"
else
	fail "(a) hooked amd64 nvidia: rc=$rc ko=$(cat "$TREE/nvidia/nvidia.ko" 2>/dev/null) out=$(cat "$TESTROOT/out-a") err=$(cat "$TESTROOT/err-a")"
fi

# (b) hooked amd64 modeset
rc=$(run_shim amd64 nvidia-modeset b hook)
b_ok=1
[ "$rc" -eq 0 ] || b_ok=0
grep -q '^build: OK$' "$TESTROOT/out-b" || b_ok=0
grep -q '^MACHINE=amd64 MACHINE_ARCH=amd64$' "$TREE/nvidia-modeset/nvidia-modeset.ko" || b_ok=0
grep -q "^rm core: $TESTROOT/build/nv-modeset-kernel-amd64.o -> " "$TESTROOT/out-b" || b_ok=0
if grep -q 'nv-modeset-kernel-aarch64' "$TESTROOT/out-b"; then b_ok=0; fi
if [ "$b_ok" -eq 1 ]; then
	ok "(b) hooked amd64 modeset: MACHINE=amd64, default RMOBJ nv-modeset-kernel-amd64.o"
else
	fail "(b) hooked amd64 modeset: rc=$rc ko=$(cat "$TREE/nvidia-modeset/nvidia-modeset.ko" 2>/dev/null) out=$(cat "$TESTROOT/out-b") err=$(cat "$TESTROOT/err-b")"
fi

# (c) hooked aarch64: flags and defaults unchanged
rc=$(run_shim aarch64 nvidia c hook)
c_ok=1
[ "$rc" -eq 0 ] || c_ok=0
grep -q '^MACHINE=arm64 MACHINE_ARCH=aarch64$' "$TREE/nvidia/nvidia.ko" || c_ok=0
grep -q "^rm core: $TESTROOT/build/nv-kernel-gb10.o -> " "$TESTROOT/out-c" || c_ok=0
rc2=$(run_shim aarch64 nvidia-modeset c2 hook)
[ "$rc2" -eq 0 ] || c_ok=0
grep -q '^MACHINE=arm64 MACHINE_ARCH=aarch64$' "$TREE/nvidia-modeset/nvidia-modeset.ko" || c_ok=0
grep -q "^rm core: $TESTROOT/build/nv-modeset-kernel-aarch64.o -> " "$TESTROOT/out-c2" || c_ok=0
if grep -q 'nv-modeset-kernel-amd64' "$TESTROOT/out-c2"; then c_ok=0; fi
if [ "$c_ok" -eq 1 ]; then
	ok "(c) hooked aarch64: MACHINE=arm64 MACHINE_ARCH=aarch64, defaults unchanged"
else
	fail "(c) hooked aarch64: rc=$rc/$rc2 ko-n=$(cat "$TREE/nvidia/nvidia.ko" 2>/dev/null) ko-m=$(cat "$TREE/nvidia-modeset/nvidia-modeset.ko" 2>/dev/null) out-c=$(cat "$TESTROOT/out-c") out-c2=$(cat "$TESTROOT/out-c2") err-c=$(cat "$TESTROOT/err-c") err-c2=$(cat "$TESTROOT/err-c2")"
fi

# (d) live amd64 host, no arch hook
arch=$(uname -p 2>/dev/null || uname -m)
if [ "$(uname -s)" = FreeBSD ] && [ "$arch" = amd64 ]; then
	rc=$(run_shim "" nvidia d live)
	if [ "$rc" -eq 0 ] \
	    && grep -q '^MACHINE=amd64 MACHINE_ARCH=amd64$' "$TREE/nvidia/nvidia.ko" \
	    && grep -q "^rm core: $TESTROOT/build/nv-kernel-gb10.o -> " "$TESTROOT/out-d"; then
		ok "(d) live FreeBSD amd64, no arch hook: MACHINE=amd64, default RMOBJ nv-kernel-gb10.o"
	else
		fail "(d) live FreeBSD amd64: rc=$rc ko=$(cat "$TREE/nvidia/nvidia.ko" 2>/dev/null) out=$(cat "$TESTROOT/out-d") err=$(cat "$TESTROOT/err-d")"
	fi
else
	ok "(d) live amd64 check skipped (host is $(uname -s) $arch)"
fi

if [ "$FAILED" -ne 0 ]; then
	printf 'FAILED %s checks (%s passed)\n' "$FAILED" "$PASSED"
	exit 1
fi
printf 'all ok (%s passed)\n' "$PASSED"
exit 0
