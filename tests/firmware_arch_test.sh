#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# firmware_arch_test.sh - scripts/build-firmware.sh builds the GSP
# firmware module for the running architecture (Track #2475). Offline:
# a fake firmware tree and a fake Makefile, no kldload, no /tmp.
#   (a) Hooked amd64: make gets MACHINE=amd64 MACHINE_ARCH=amd64.
#   (b) Hooked aarch64: make still gets MACHINE=arm64 MACHINE_ARCH=aarch64
#       (the arm64 path is unchanged).
#   (c) Live FreeBSD amd64 with no arch hook: same as (a).
# Hooks: GB10_TEST_HOOKS=1 and GB10_TEST_ARCH=amd64|aarch64.

set -u
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

TESTSDIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo=$(CDPATH='' cd -- "$TESTSDIR/.." && pwd -P)
SCRIPT="$repo/scripts/build-firmware.sh"
base=${GB10_WORK:-$repo/work}
mkdir -p -- "$base/tmp"
chmod 755 "$base/tmp" 2>/dev/null || true
TESTROOT=$(mktemp -d "$base/tmp/firmware-arch.XXXXXX") || exit 1

PASSED=0
FAILED=0
ok() { PASSED=$((PASSED + 1)); printf 'ok    %s\n' "$1"; }
fail() { FAILED=$((FAILED + 1)); printf 'FAIL  %s\n' "$1"; }
cleanup() { rm -rf "$TESTROOT"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [ ! -f "$SCRIPT" ]; then
	fail "scripts/build-firmware.sh does not exist"
	echo "passed: $PASSED failed: $FAILED"
	exit 1
fi

TREE=$TESTROOT/build/tree
FWDIR=$TREE/firmware/gsp_ga10x
mkdir -p "$FWDIR" "$TESTROOT/logs" "$TESTROOT/tmp" "$TESTROOT/sys"
chmod 755 "$TESTROOT/tmp"

# Makefile records the MACHINE / MACHINE_ARCH make was given, inside the .ko.
cat > "$FWDIR/Makefile" <<'MAKE'
all: nvidia_gsp_ga10x_fw.ko

nvidia_gsp_ga10x_fw.ko:
	printf 'MACHINE=%s MACHINE_ARCH=%s\n' "${MACHINE}" "${MACHINE_ARCH}" > nvidia_gsp_ga10x_fw.ko

clean:
	rm -f nvidia_gsp_ga10x_fw.ko
MAKE

recorded() {
	# first line of the fake .ko
	if [ -f "$FWDIR/nvidia_gsp_ga10x_fw.ko" ]; then
		sed -n '1p' "$FWDIR/nvidia_gsp_ga10x_fw.ko"
	fi
}

run_fw() {
	_hooks=$1
	_arch=$2
	_tag=$3
	rm -f "$FWDIR/nvidia_gsp_ga10x_fw.ko"
	_log="$TESTROOT/logs/fw-$_tag.log"
	_rc=0
	if [ "$_hooks" = 1 ]; then
		GB10_WORK="$TESTROOT" SYSDIR="$TESTROOT/sys" \
			GB10_TEST_HOOKS=1 GB10_TEST_ARCH="$_arch" \
			sh "$SCRIPT" "$TREE" "$_log" \
			>"$TESTROOT/out-$_tag" 2>"$TESTROOT/err-$_tag" || _rc=$?
	else
		GB10_WORK="$TESTROOT" SYSDIR="$TESTROOT/sys" \
			sh "$SCRIPT" "$TREE" "$_log" \
			>"$TESTROOT/out-$_tag" 2>"$TESTROOT/err-$_tag" || _rc=$?
	fi
	echo "$_rc"
}

# (a) hooked amd64
rc=$(run_fw 1 amd64 a)
rec=$(recorded)
a_ok=1
[ "$rc" -eq 0 ] || a_ok=0
[ "$rec" = "MACHINE=amd64 MACHINE_ARCH=amd64" ] || a_ok=0
if [ "$a_ok" -eq 1 ]; then
	ok "(a) hooked amd64: make gets MACHINE=amd64 MACHINE_ARCH=amd64"
else
	fail "(a) hooked amd64: rc=$rc recorded='$rec' (want MACHINE=amd64 MACHINE_ARCH=amd64)"
	sed 's/^/  | /' "$TESTROOT/err-a" 2>/dev/null | sed -n '1,20p'
fi

# (b) hooked aarch64 — arm64 path unchanged
rc=$(run_fw 1 aarch64 b)
rec=$(recorded)
b_ok=1
[ "$rc" -eq 0 ] || b_ok=0
[ "$rec" = "MACHINE=arm64 MACHINE_ARCH=aarch64" ] || b_ok=0
if [ "$b_ok" -eq 1 ]; then
	ok "(b) hooked aarch64: make gets MACHINE=arm64 MACHINE_ARCH=aarch64"
else
	fail "(b) hooked aarch64: rc=$rc recorded='$rec' (want MACHINE=arm64 MACHINE_ARCH=aarch64)"
	sed 's/^/  | /' "$TESTROOT/err-b" 2>/dev/null | sed -n '1,20p'
fi

# (c) live FreeBSD amd64, no arch hook
os=$(uname -s)
arch=$(uname -p)
if [ "$os" = FreeBSD ] && [ "$arch" = amd64 ]; then
	rc=$(run_fw 0 '' c)
	rec=$(recorded)
	c_ok=1
	[ "$rc" -eq 0 ] || c_ok=0
	[ "$rec" = "MACHINE=amd64 MACHINE_ARCH=amd64" ] || c_ok=0
	if [ "$c_ok" -eq 1 ]; then
		ok "(c) live FreeBSD amd64, no arch hook: make gets MACHINE=amd64 MACHINE_ARCH=amd64"
	else
		fail "(c) live FreeBSD amd64, no arch hook: rc=$rc recorded='$rec' (want MACHINE=amd64 MACHINE_ARCH=amd64)"
		sed 's/^/  | /' "$TESTROOT/err-c" 2>/dev/null | sed -n '1,20p'
	fi
else
	printf 'skip  (c) live FreeBSD amd64 (this host is %s %s)\n' "$os" "$arch"
fi

echo "passed: $PASSED failed: $FAILED"
[ "$FAILED" -eq 0 ]
