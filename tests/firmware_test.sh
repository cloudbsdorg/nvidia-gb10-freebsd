#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# firmware_test.sh - prove the arm64 GSP firmware module that
# scripts/build-firmware.sh builds from TREE/firmware/gsp_ga10x is what
# nvidia.ko asks firmware(9) for. No kldload(8), no root:
#   (a) the .ko is AArch64: readelf -h says "AArch64";
#   (b) the image embedded in the .ko is byte-identical to NVIDIA's
#       gsp_ga10x.bin. FIRMWS= gsp_ga10x.bin:nvidia_gsp_ga10x_fw is
#       assembled by sys/kern/firmw.S, which puts the file in .rodata
#       between the symbols _binary_gsp_ga10x_bin_start and
#       _binary_gsp_ga10x_bin_end (FIRMW_START/FIRMW_END over
#       FIRMW_SYMBOL; bsd.kmod.mk maps [-./@] in the file name to _).
#       The test does not hard-code that guess: it finds the single
#       _binary_*_start symbol with nm(1), maps its address to a file
#       offset through the readelf -SW section that contains it, cuts
#       start..end out of the .ko and compares sha256 against
#       gsp_ga10x.bin. Falsifiability control: the SAME
#       extraction-and-compare function, run on a scratch copy of the
#       .ko with one byte flipped inside the embedded image (file
#       offset image-start+1000), must report a MISMATCH;
#   (c) the registered firmware name equals the name the driver
#       requests: the exact string "nvidia_gsp_ga10x_fw" appears in
#       nvidia_gsp_ga10x_fw.ko (the FIRMWS short name the stub
#       registers with firmware(9)) and in TREE/nvidia/nvidia.ko,
#       whose NV_FIRMWARE_FOR_NAME("gsp_ga10x") expands to
#       "nvidia_" "gsp_ga10x" "_fw" (nvidia/nvidia_subr.c:13);
#   (d) build-firmware.sh's LOG rule (log_path_safe in scripts/lib.sh,
#       shared with build-shim.sh): a LOG whose directory is not under
#       $WORK/logs is refused with exit 1 and nothing is written there;
#   (e) a symlinked LOG inside $WORK/logs is refused before anything is
#       written through the link.
#   (f) an inherited MAKEFLAGS must not reach make (pass-3 u13 #1): with
#       MAKEFLAGS=-n exported, build-firmware.sh must still really build
#       the module. Before the fix make dry-ran (exit 0, nothing built)
#       and the script reported the size and sha256 of the EARLIER run's
#       .ko - an artifact this run did not produce. The .ko is removed
#       before the build, so a dry-run build leaves nothing to report and
#       must fail.
#
# Usage: tests/firmware_test.sh [TREE]
#   TREE  prepared working tree; defaults to
#         ${GB10_WORK:-$HOME/work/gb10}/build/tree
#
# Prerequisites: scripts/prepare-tree.sh has run on TREE (so
# TREE/firmware/gsp_ga10x/gsp_ga10x.bin exists) and scripts/build-shim.sh
# has produced TREE/nvidia/nvidia.ko. The test itself runs
# scripts/build-firmware.sh. Scratch stays under $WORK/tmp; the test's own
# build log is a mktemp file under $WORK/logs (build-firmware.sh's LOG
# rule requires that location), removed on exit.

set -eu

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

WORK=${GB10_WORK:-$HOME/work/gb10}
TREE=${1:-$WORK/build/tree}
FWDIR=$TREE/firmware/gsp_ga10x
KO=$FWDIR/nvidia_gsp_ga10x_fw.ko
BIN=$FWDIR/gsp_ga10x.bin
NKO=$TREE/nvidia/nvidia.ko
NAME=nvidia_gsp_ga10x_fw

TESTSDIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BUILD="$TESTSDIR/../scripts/build-firmware.sh"

PASSED=0
FAILED=0

ok() {
	PASSED=$((PASSED + 1))
	printf 'ok   %s\n' "$1"
}

fail() {
	FAILED=$((FAILED + 1))
	printf 'FAIL %s\n' "$1"
}

# Unpredictable scratch directories ($WORK/tmp is $HOME/work/gb10/tmp unless
# GB10_WORK says otherwise). All four names are initialised EMPTY and the
# trap is installed BEFORE the first mktemp, so no signal can orphan a
# scratch dir, a scratch log or the symlinked LOG of case (e) and the
# cleanup never runs rm on an unset name. HUP/QUIT/INT/TERM exit 128+signo
# (129/131/130/143) and let the EXIT trap clean up, instead of a combined
# trap that cleans up and RETURNS (the script would carry on after a
# signal).
TMPD=''
SCRATCHD=''
BUILDLOG=''
SYMLOG=''
# cleanup - remove exactly this run's scratch files on every exit path.
# Time:  O(F) cleanup for F scratch files, once per run.
# Space: O(1) in this shell.
cleanup() {
	if [ -n "$TMPD" ]; then
		rm -rf -- "$TMPD"
	fi
	if [ -n "$SCRATCHD" ]; then
		rm -rf -- "$SCRATCHD"
	fi
	if [ -n "$BUILDLOG" ]; then
		rm -f -- "$BUILDLOG"
	fi
	if [ -n "$SYMLOG" ]; then
		rm -f -- "$SYMLOG"
	fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 131' QUIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$WORK/tmp" "$WORK/logs"
TMPD=$(mktemp -d "$WORK/tmp/firmware_test.XXXXXXXX") || exit 1
SCRATCHD=$(mktemp -d "$WORK/tmp/fw-test.XXXXXXXX") || exit 1
# build-firmware.sh's LOG rule (log_path_safe in scripts/lib.sh) requires
# the build log under $WORK/logs, so the test's own log is a mktemp file
# there, removed by the cleanup above.
BUILDLOG=$(mktemp "$WORK/logs/firmware-test-build.XXXXXXXX") || exit 1

if [ ! -f "$BIN" ]; then
	fail "no $BIN: run scripts/prepare-tree.sh first"
	echo "passed: $PASSED failed: $FAILED"
	exit 1
fi
if [ ! -f "$NKO" ]; then
	fail "no $NKO: run scripts/build-shim.sh first"
	echo "passed: $PASSED failed: $FAILED"
	exit 1
fi

# Build the firmware module under test.
rc=0
sh "$BUILD" "$TREE" "$BUILDLOG" >"$TMPD/build.out" 2>&1 || rc=$?
if [ "$rc" -eq 0 ] && [ -f "$KO" ]; then
	ok "build-firmware.sh: exit 0, $NAME.ko produced"
	cat "$TMPD/build.out"
else
	fail "build-firmware.sh: rc=$rc out=$(cat "$TMPD/build.out" 2>/dev/null) log-tail=$(tail -n 5 "$BUILDLOG" 2>/dev/null)"
	echo "passed: $PASSED failed: $FAILED"
	exit 1
fi

# (a) AArch64 ELF.
if readelf -h "$KO" | grep -q 'AArch64'; then
	ok "(a) $NAME.ko is AArch64 (readelf -h)"
else
	fail "(a) readelf -h does not say AArch64: $(readelf -h "$KO" | grep -i machine)"
fi

# (b) Embedded image is byte-identical to gsp_ga10x.bin.
#
# sym_value <symbol> <ko>: print the symbol's address from nm(1)
# (BSD format: "<hexaddr> <type> <name>") as a decimal number.
# Time:  O(S) for S symbol-table entries (one nm run, one awk pass).
# Space: O(1).
sym_value() {
	_v=$(nm "$2" | awk -v s="$1" 'NF == 3 && $3 == s { print $1; exit }')
	[ -n "$_v" ] || return 1
	echo $((0x$_v))
}

# section_rows <ko> - print "<hexaddr> <hexoff> <hexsize>" for every
# PROGBITS section of the .ko, from the readelf -SW section table.
# Time:  O(N) for N section-header rows (one readelf run, one awk pass).
# Space: O(1) in this shell.
section_rows() {
	readelf -SW "$1" | awk '
	{
		for (i = 1; i <= NF; i++) {
			if ($i == "PROGBITS") {
				print $(i + 1), $(i + 2), $(i + 3)
				break
			}
		}
	}'
}

# file_offset_of <decaddr> <ko> - print the file offset of a virtual
# address (sh_offset + addr - sh_addr of the PROGBITS section that
# contains it), or nothing when no section contains it.
# Time:  O(N) for N PROGBITS sections (a few dozen), one shell pass.
# Space: O(1).
file_offset_of() {
	_a=$1
	section_rows "$2" | while read -r _haddr _hoff _hsize; do
		_saddr=$((0x$_haddr))
		_soff=$((0x$_hoff))
		_ssize=$((0x$_hsize))
		if [ "$_saddr" -le "$_a" ] && [ "$_a" -lt "$((_saddr + _ssize))" ]; then
			echo $((_soff + _a - _saddr))
			break
		fi
	done
}

# check_embedded_image <ko> - locate the firmware image embedded in <ko>
# (the single _binary_*_start symbol from nm(1), its _end partner, and
# the file offset of the PROGBITS section containing the start address),
# cut start..end out of <ko> and compare sha256 against gsp_ga10x.bin.
# Prints exactly one result line:
#   MATCH <sha256> <len> <fileoff> <start-sym>/<end-sym>
#   MISMATCH <reason>
# and returns 0 on MATCH, 1 on MISMATCH. Case (b) and its falsifiability
# control both call this same function - no copied code - so the control
# proves the real check can fail.
# Time:  O(S + N + L): S symbol entries, N section rows, one L-byte
#        image cut and hashed per call.
# Space: O(L) for the extracted scratch file; O(1) in this shell.
check_embedded_image() {
	_cko=$1
	_csyms=$(mktemp "$TMPD/syms.XXXXXX")
	nm "$_cko" | awk 'NF == 3 && $3 ~ /^_binary_.*_start$/ { print $3 }' \
		> "$_csyms"
	_cnstart=$(wc -l < "$_csyms" | tr -d ' ')
	if [ "$_cnstart" != "1" ]; then
		rm -f "$_csyms"
		echo "MISMATCH expected exactly one _binary_*_start symbol, found $_cnstart"
		return 1
	fi
	_cstart=$(cat "$_csyms")
	rm -f "$_csyms"
	_cend=${_cstart%_start}_end
	if ! _csa=$(sym_value "$_cstart" "$_cko"); then
		echo "MISMATCH start symbol $_cstart has no address"
		return 1
	fi
	if ! _cea=$(sym_value "$_cend" "$_cko"); then
		echo "MISMATCH end symbol $_cend not in $(basename "$_cko")"
		return 1
	fi
	_clen=$((_cea - _csa))
	_coff=$(file_offset_of "$_csa" "$_cko")
	if [ "$_clen" -ne "$(stat -f %z "$BIN")" ]; then
		echo "MISMATCH embedded length $_clen != gsp_ga10x.bin size $(stat -f %z "$BIN")"
		return 1
	fi
	if [ -z "$_coff" ]; then
		echo "MISMATCH no PROGBITS section contains address $_csa"
		return 1
	fi
	_cext=$(mktemp "$TMPD/embedded.XXXXXX")
	tail -c "+$((_coff + 1))" "$_cko" | head -c "$_clen" > "$_cext"
	_cemb=$(sha256 -q "$_cext")
	rm -f "$_cext"
	_cbin=$(sha256 -q "$BIN")
	if [ "$_cemb" = "$_cbin" ]; then
		echo "MATCH $_cemb $_clen $_coff $_cstart/$_cend"
		return 0
	fi
	echo "MISMATCH sha256: embedded $_cemb != gsp_ga10x.bin $_cbin"
	return 1
}

res_b=$(check_embedded_image "$KO") || true
case "$res_b" in
MATCH*)
	_bsha=$(printf '%s\n' "$res_b" | awk '{print $2}')
	_blen=$(printf '%s\n' "$res_b" | awk '{print $3}')
	_bsym=$(printf '%s\n' "$res_b" | awk '{print $5}')
	ok "(b) embedded image byte-identical to gsp_ga10x.bin (sha256 $_bsha, $_blen bytes, symbols $_bsym)"
	;;
*)
	fail "(b) $res_b"
	;;
esac

# (b-control) Falsifiability: the SAME extraction-and-compare function
# must report MISMATCH on a scratch copy of the .ko with one byte
# flipped inside the embedded image, at file offset image-start+1000
# (located through the symbol values and the section's file offset, the
# same way case (b) locates the image). This proves check (b) can fail
# on a real .ko, not merely that two different files hash differently.
SCRATCHKO=$SCRATCHD/nvidia_gsp_ga10x_fw.ko
cp "$KO" "$SCRATCHKO"
res_c=$(check_embedded_image "$SCRATCHKO") || true
case "$res_c" in
MATCH*)
	_coff=$(printf '%s\n' "$res_c" | awk '{print $4}')
	_clen=$(printf '%s\n' "$res_c" | awk '{print $3}')
	if [ "$_clen" -le 1000 ]; then
		fail "(b-control) embedded image is only $_clen bytes: no byte at start+1000 to flip"
	else
		_moff=$((_coff + 1000))
		_cur=$(od -An -tx1 -j "$_moff" -N1 "$SCRATCHKO" | tr -d ' \n')
		_flip=$((0x$_cur ^ 0xff))
		# /bin/sh's printf has no \xHH escape: printf "\\x41" prints
		# the literal "x41" (the backslash of an unknown escape is
		# dropped) and dd would write its first byte 'x' - a constant
		# unrelated to the requested flip, which the old info line
		# then reported as if the flip had happened. The octal
		# escape \ddd is POSIX and writes exactly the flipped byte.
		_esc=$(printf '%03o' "$_flip")
		printf "\\$_esc" | dd of="$SCRATCHKO" bs=1 seek="$_moff" \
			count=1 conv=notrunc 2>/dev/null
		# Verify the flip landed before reporting it: the info line
		# must never claim a flip that did not happen.
		_got=$(od -An -tx1 -j "$_moff" -N1 "$SCRATCHKO" | tr -d ' \n')
		if [ "$_got" != "$(printf '%02x' "$_flip")" ]; then
			fail "(b-control) byte at file offset $_moff reads 0x$_got after the flip, expected $(printf '%02x' "$_flip")"
		else
			echo "info: (b-control) flipped byte at file offset $_moff (image start+1000): 0x$_cur -> 0x$_got (verified)"
		fi
		if cmp -s "$KO" "$SCRATCHKO"; then
			fail "(b-control) dd wrote nothing: scratch .ko still identical to the original"
		else
			res_m=$(check_embedded_image "$SCRATCHKO") || true
			case "$res_m" in
			MISMATCH*)
				ok "(b-control) 1-byte-flipped .ko copy reports MISMATCH through the same extraction code: $res_m"
				;;
			*)
				fail "(b-control) mutated .ko still passes: $res_m: check (b) cannot fail"
				;;
			esac
		fi
	fi
	;;
*)
	fail "(b-control) pristine copy of $NAME.ko does not match: $res_c"
	;;
esac

# (c) The registered name equals the requested name, on both sides.
if strings "$KO" | grep -qx "$NAME"; then
	ok "(c) firmware module registers the name $NAME"
else
	fail "(c) name $NAME not in strings of $NAME.ko"
fi
if strings "$NKO" | grep -qx "$NAME"; then
	ok "(c) nvidia.ko requests the name $NAME (NV_FIRMWARE_FOR_NAME expansion)"
else
	fail "(c) name $NAME not in strings of nvidia.ko"
fi

# (d) The LOG rule (log_path_safe in scripts/lib.sh, shared with
# build-shim.sh): a LOG whose directory is not under $WORK/logs is
# refused with exit 1 before anything is written. $TMPD is under
# $WORK/tmp, which is NOT under $WORK/logs.
rc=0
sh "$BUILD" "$TREE" "$TMPD/not-allowed.log" >"$TMPD/d.out" 2>&1 || rc=$?
if [ "$rc" -eq 1 ] && grep -q 'refusing LOG' "$TMPD/d.out" &&
    [ ! -f "$TMPD/not-allowed.log" ]; then
	ok "(d) LOG outside \$WORK/logs refused: rc=1, 'refusing LOG', nothing written"
else
	fail "(d) LOG under \$WORK/tmp: rc=$rc created=$([ -f "$TMPD/not-allowed.log" ] && echo yes || echo no) out=$(tail -1 "$TMPD/d.out" 2>/dev/null)"
fi

# (e) A symlinked LOG inside $WORK/logs is refused before anything is
# written through the link.
SYMLOG="$WORK/logs/firmware-test-sym.$$.log"
rm -f -- "$SYMLOG" "$TMPD/sym-target.log"
ln -s "$TMPD/sym-target.log" "$SYMLOG"
rc=0
sh "$BUILD" "$TREE" "$SYMLOG" >"$TMPD/e.out" 2>&1 || rc=$?
rm -f -- "$SYMLOG"
if [ "$rc" -eq 1 ] && grep -q 'refusing LOG.*symlink' "$TMPD/e.out" &&
    [ ! -f "$TMPD/sym-target.log" ]; then
	ok "(e) symlinked LOG refused: rc=1, 'symlink', target untouched"
else
	fail "(e) symlinked LOG: rc=$rc target=$([ -f "$TMPD/sym-target.log" ] && echo written || echo untouched) out=$(tail -1 "$TMPD/e.out" 2>/dev/null)"
fi

# (f) An inherited MAKEFLAGS must not reach make (pass-3 u13 #1): with
# MAKEFLAGS=-n exported, build-firmware.sh must still really build the
# module. Before the fix make dry-ran (exit 0, nothing built) and the
# script reported the EARLIER run's .ko - an artifact this run did not
# produce. The .ko is removed before the build, so a dry-run build leaves
# nothing to report and must fail instead.
rm -f -- "$KO"
rc=0
MAKEFLAGS=-n sh "$BUILD" "$TREE" "$BUILDLOG" >"$TMPD/f.out" 2>&1 || rc=$?
if [ "$rc" -eq 0 ] && [ -s "$KO" ] && grep -q 'sha256' "$TMPD/f.out"; then
	ok "(f) MAKEFLAGS=-n inherited: the module is really rebuilt (flags stripped, stale .ko removed first)"
else
	fail "(f) MAKEFLAGS=-n: rc=$rc ko=$([ -s "$KO" ] && echo present || echo missing) out=$(tail -n 1 "$TMPD/f.out" 2>/dev/null)"
fi

echo "passed: $PASSED failed: $FAILED"
if [ "$FAILED" -ne 0 ]; then
	exit 1
fi
exit 0
