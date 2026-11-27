#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# cuda_native_atomics_test.sh - the device atomic family of the cuda-native
# SDK (Track #2380, stage C1.1 #2425; #2463): every atomic the SDK declares
# compiles, and every one of them lowers to the PTX instruction its
# operation and its scope call for.
#
# The test runs on a FRESH COPY of the STAGED content (checkout-index; after
# a commit that is the commit).  Stage new files before running it.  No GPU
# and no driver are needed: clang 23 (ports llvm23) reads our --cuda-path
# tree and writes PTX for sm_120.
#
# Cases:
# - a fresh copy of the staged tree and the SDK tree mksdk.sh builds from it;
# - one kernel per atomic and per scope, compiled to PTX, and the PTX of that
#   kernel checked for the instruction the operation and the scope call for
#   (a compare-and-swap loop for the float and double minimum and maximum,
#   which have no instruction of their own), and checked for a call to a
#   libdevice function: our libdevice holds none;
# - the header and the table below agree: every atomic the header declares
#   has a case here, and every case here is an atomic the header declares;
# - the man page and the README name every atomic of the family;
# - mutants of the built tree that the checks above must notice.
#
# Every check prints "ok", "FAIL" or "skip".  The summary counts all three.
# Exit status: the number of failures, 77 when LLVM 23 is missing and every
# check that ran passed (the checks that need LLVM were skipped), 99 when the
# setup failed (no fresh copy).
# Run: sh tests/cuda_native_atomics_test.sh
# Env: LLVM (default /usr/local/llvm23), TMPDIR (scratch, default /tmp).

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=${CUDA_NATIVE_TEST_REPO:-$(CDPATH= cd -- "$HERE/.." && pwd)}
LLVM=${LLVM:-/usr/local/llvm23}
export LLVM
CXX=$LLVM/bin/clang++

W=$(mktemp -d "${TMPDIR:-/tmp}/cuda-native-atomics.XXXXXXXX") || exit 99
trap 'rm -rf "$W"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

PASS=0
FAIL=0
SKIP=0
ok() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
skip_check() { SKIP=$((SKIP + 1)); printf 'skip %s\n' "$1"; }
expect_rc() {
	if [ "$2" -eq "$3" ]; then ok "$1"; else bad "$1 (rc=$2, want $3)"; fi
}
finish() {
	printf '%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
	[ "$FAIL" -le 76 ] || FAIL=76
	exit "$FAIL"
}

# ---- fresh copy ----------------------------------------------------------
SRC=$W/src
mkdir -p "$SRC"
git -C "$REPO" checkout-index -a --prefix="$SRC/" >"$W/checkout.log" 2>&1
rc=$?
expect_rc "fresh copy of the staged tree" $rc 0
[ -f "$SRC/lib/cuda-native/mksdk.sh" ] && [ -f "$SRC/tests/cuda_native_atomics_test.sh" ]
rc=$?
expect_rc "the fresh copy holds mksdk.sh and this test" $rc 0
if [ $rc -ne 0 ]; then
	echo "The test runs on the staged tree: stage the files first" \
	    "(git add lib/cuda-native tests/cuda-native tests/cuda_native_atomics_test.sh)." >&2
	printf '%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
	exit 99
fi
CN=$SRC/lib/cuda-native

# ---- the cases ------------------------------------------------------------
# One line per atomic: the id, the name of the atomic, the declaration of
# the arguments, the call and the PTX operation the call must lower to.  The
# scope is not in the table: every atomic exists in the device, the block
# and the system scope, and the scope word of the PTX instruction follows
# the scope of the call.
#
#   id | name | declaration | call | PTX operation
#
# The float and double minimum and maximum have no instruction of their
# own: they are a compare-and-swap loop, so the operation is the cas.
cat >"$W/table" <<'TABLE'
add_int|atomicAdd|int *p, int v|atomicAdd(p, v)|add.u32
add_uint|atomicAdd|unsigned int *p, unsigned int v|atomicAdd(p, v)|add.u32
add_ull|atomicAdd|unsigned long long *p, unsigned long long v|atomicAdd(p, v)|add.u64
add_float|atomicAdd|float *p, float v|atomicAdd(p, v)|add.f32
add_double|atomicAdd|double *p, double v|atomicAdd(p, v)|add.f64
sub_int|atomicSub|int *p, int v|atomicSub(p, v)|add.u32
sub_uint|atomicSub|unsigned int *p, unsigned int v|atomicSub(p, v)|add.u32
sub_ull|atomicSub|unsigned long long *p, unsigned long long v|atomicSub(p, v)|add.u64
sub_float|atomicSub|float *p, float v|atomicSub(p, v)|add.f32
sub_double|atomicSub|double *p, double v|atomicSub(p, v)|add.f64
exch_int|atomicExch|int *p, int v|atomicExch(p, v)|exch.b32
exch_uint|atomicExch|unsigned int *p, unsigned int v|atomicExch(p, v)|exch.b32
exch_ull|atomicExch|unsigned long long *p, unsigned long long v|atomicExch(p, v)|exch.b64
exch_float|atomicExch|float *p, float v|atomicExch(p, v)|exch.b32
min_int|atomicMin|int *p, int v|atomicMin(p, v)|min.s32
min_uint|atomicMin|unsigned int *p, unsigned int v|atomicMin(p, v)|min.u32
min_ll|atomicMin|long long *p, long long v|atomicMin(p, v)|min.s64
min_ull|atomicMin|unsigned long long *p, unsigned long long v|atomicMin(p, v)|min.u64
min_float|atomicMin|float *p, float v|atomicMin(p, v)|cas.b32
min_double|atomicMin|double *p, double v|atomicMin(p, v)|cas.b64
max_int|atomicMax|int *p, int v|atomicMax(p, v)|max.s32
max_uint|atomicMax|unsigned int *p, unsigned int v|atomicMax(p, v)|max.u32
max_ll|atomicMax|long long *p, long long v|atomicMax(p, v)|max.s64
max_ull|atomicMax|unsigned long long *p, unsigned long long v|atomicMax(p, v)|max.u64
max_float|atomicMax|float *p, float v|atomicMax(p, v)|cas.b32
max_double|atomicMax|double *p, double v|atomicMax(p, v)|cas.b64
inc_uint|atomicInc|unsigned int *p, unsigned int v|atomicInc(p, v)|inc.u32
dec_uint|atomicDec|unsigned int *p, unsigned int v|atomicDec(p, v)|dec.u32
cas_int|atomicCAS|int *p, int c, int v|atomicCAS(p, c, v)|cas.b32
cas_uint|atomicCAS|unsigned int *p, unsigned int c, unsigned int v|atomicCAS(p, c, v)|cas.b32
cas_ull|atomicCAS|unsigned long long *p, unsigned long long c, unsigned long long v|atomicCAS(p, c, v)|cas.b64
cas_ushort|atomicCAS|unsigned short *p, unsigned short c, unsigned short v|atomicCAS(p, c, v)|cas.b32
and_int|atomicAnd|int *p, int v|atomicAnd(p, v)|and.b32
and_uint|atomicAnd|unsigned int *p, unsigned int v|atomicAnd(p, v)|and.b32
and_ull|atomicAnd|unsigned long long *p, unsigned long long v|atomicAnd(p, v)|and.b64
or_int|atomicOr|int *p, int v|atomicOr(p, v)|or.b32
or_uint|atomicOr|unsigned int *p, unsigned int v|atomicOr(p, v)|or.b32
or_ull|atomicOr|unsigned long long *p, unsigned long long v|atomicOr(p, v)|or.b64
xor_int|atomicXor|int *p, int v|atomicXor(p, v)|xor.b32
xor_uint|atomicXor|unsigned int *p, unsigned int v|atomicXor(p, v)|xor.b32
xor_ull|atomicXor|unsigned long long *p, unsigned long long v|atomicXor(p, v)|xor.b64
TABLE

# The atomic names of the family, one per line.
cut -d'|' -f2 "$W/table" | sort -u >"$W/names"

# ---- the SDK tree --------------------------------------------------------
if [ ! -x "$CXX" ]; then
	echo "skip: no executable clang++ at $CXX; the checks below did not run"
	printf '%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
	[ "$FAIL" -eq 0 ] && exit 77
	finish
fi
SDK=$W/sdk
sh "$CN/mksdk.sh" "$SDK" >"$W/mksdk.log" 2>&1
rc=$?
expect_rc "mksdk.sh builds the SDK tree" $rc 0
[ $rc -eq 0 ] || { sed -n 1,10p "$W/mksdk.log"; finish; }

# devptx TREE SRC OUT: one device-only compile of SRC against TREE; the
# diagnostics go to OUT.log.
devptx() {
	"$CXX" -x cuda --cuda-path="$1" --offload-arch=sm_120 --cuda-device-only \
	    -S -O2 -Werror -o "$3" "$2" >"$3.log" 2>&1
}

# ptx_kernel FILE NAME: the PTX of the kernel NAME (an entry ends where the
# next one starts).
ptx_kernel() {
	awk -v want="$2" '
		/^\.visible \.entry / { inblock = ($3 ~ ("^" want "\\(")) }
		inblock { print }
	' "$1"
}

# case_source ID: the kernel file of one case: the three scopes of one
# atomic, each in its own kernel with a C name.
case_source() {
	_id=$1
	_row=$(awk -F'|' -v id="$_id" '$1 == id { print $2 "|" $3 "|" $4; exit }' "$W/table")
	_name=${_row%%|*}
	_rest=${_row#*|}
	_decl=${_rest%%|*}
	_call=${_rest#*|}
	# The arguments of the call, without the name and the parentheses.
	_args=${_call#*(}
	_args=${_args%)}
	{
		printf 'extern "C" __global__ void k_%s(%s) { %s; }\n' "$_id" "$_decl" "$_call"
		printf 'extern "C" __global__ void k_%s_block(%s) { %s_block(%s); }\n' \
		    "$_id" "$_decl" "$_name" "$_args"
		printf 'extern "C" __global__ void k_%s_system(%s) { %s_system(%s); }\n' \
		    "$_id" "$_decl" "$_name" "$_args"
	} >"$W/case-$_id.cu"
}

# ---- every atomic, in every scope ----------------------------------------
# Time: O(number of cases x PTX size).  Space: O(PTX of one case).
while IFS='|' read -r id name decl call op; do
	[ -n "$id" ] || continue
	case_source "$id"
	if ! devptx "$SDK" "$W/case-$id.cu" "$W/case-$id.ptx"; then
		bad "$name: the kernel does not compile"
		sed -n 1,5p "$W/case-$id.ptx.log"
		continue
	fi
	for scope in '' _block _system; do
		case $scope in
		'') ptxscope=sys ;;
		_block) ptxscope=cta ;;
		*) ptxscope=sys ;;
		esac
		pattern="atom.relaxed.$ptxscope.global.$op"
		if ptx_kernel "$W/case-$id.ptx" "k_$id$scope" | grep -q "$pattern"; then
			ok "$name$scope: $pattern"
		else
			bad "$name$scope: $pattern is not in the PTX"
			ptx_kernel "$W/case-$id.ptx" "k_$id$scope" | sed -n 1,8p
		fi
	done
	# Our libdevice holds no function: a kernel that needed one would link
	# to nothing, so no PTX of the family may call one.
	if grep -Eq '^[[:space:]]*call' "$W/case-$id.ptx"; then
		bad "$name: the PTX calls a function"
		grep -E '^[[:space:]]*call' "$W/case-$id.ptx" | sed -n 1,5p
	else
		ok "$name: the PTX calls no function"
	fi
done <"$W/table"

# The 16 bit compare and swap: the PTX ISA has no 16 bit cas instruction, so
# clang masks the 16 bits of an aligned 32 bit word and swaps that word.
if ptx_kernel "$W/case-cas_ushort.ptx" k_cas_ushort | grep -q '65535'; then
	ok "atomicCAS: the 16 bits are masked"
else
	bad "atomicCAS: the 16 bits are not masked"
fi

# ---- the header and the table agree --------------------------------------
# Every atomic the header declares has a case here, and every case here is
# an atomic the header declares.  A new atomic that nobody tests is a hole
# in the family, and a case for an atomic the header does not declare is a
# hole in the header.
HDR=$CN/sdk/include/device_atomic_functions.hpp
[ -f "$HDR" ] || HDR=$CN/sdk/include/device_atomic_functions.h
# Every name the header spells as a function, without the scope suffix.
grep -o 'atomic[A-Z][a-zA-Z]*' "$HDR" | sed 's/_block$//; s/_system$//' | sort -u >"$W/declared"
missing=
while IFS= read -r want; do
	grep -qx "$want" "$W/declared" || missing="$missing $want"
done <"$W/names"
[ -z "$missing" ]
expect_rc "every atomic of the table is declared by the header" $? 0
[ -z "$missing" ] || printf '   not declared:%s\n' "$missing"
extra=
while IFS= read -r want; do
	grep -qx "$want" "$W/names" || extra="$extra $want"
done <"$W/declared"
[ -z "$extra" ]
expect_rc "every atomic the header declares has a case here" $? 0
[ -z "$extra" ] || printf '   not tested:%s\n' "$extra"

# ---- the documentation ----------------------------------------------------
# The man page and the README name every atomic of the family.
MAN=$CN/man/cuda-native-toolchain.7
README=$SRC/README.md
missing=
while IFS= read -r want; do
	grep -q "$want" "$MAN" || missing="$missing $want"
done <"$W/names"
[ -z "$missing" ]
expect_rc "the man page names every atomic of the family" $? 0
[ -z "$missing" ] || printf '   not in the man page:%s\n' "$missing"
missing=
while IFS= read -r want; do
	grep -q "$want" "$README" || missing="$missing $want"
done <"$W/names"
[ -z "$missing" ]
expect_rc "the README names every atomic of the family" $? 0
[ -z "$missing" ] || printf '   not in the README:%s\n' "$missing"

# ---- mutants --------------------------------------------------------------
# The checks above must notice a tree that is wrong.
#
# A maximum that is a minimum: the maximum check must fail.
M=$W/m-max
rm -rf "$M"
cp -R "$SDK" "$M" || finish
sed -i '' 's/CN_DEFINE(atomicMax, int, int, max, i);/CN_DEFINE(atomicMax, int, int, min, i);/' \
    "$M/include/device_atomic_functions.hpp"
case_source max_int
if devptx "$M" "$W/case-max_int.cu" "$W/m-max.ptx"; then
	if ptx_kernel "$W/m-max.ptx" k_max_int | grep -q 'atom.relaxed.sys.global.max.s32'; then
		bad "mutant: a maximum that is a minimum is noticed"
	else
		ok "mutant: a maximum that is a minimum is noticed"
	fi
else
	ok "mutant: a maximum that is a minimum is noticed"
fi

# An atomic that is not there: the compile of the case must fail.
M=$W/m-gone
rm -rf "$M"
cp -R "$SDK" "$M" || finish
sed -i '' 's/atomicMax/atomicMaxGone/g' "$M/include/device_atomic_functions.hpp" \
    "$M/include/device_atomic_functions.h"
if devptx "$M" "$W/case-max_int.cu" "$W/m-gone.ptx"; then
	bad "mutant: an atomic that cannot be called is noticed"
else
	ok "mutant: an atomic that cannot be called is noticed"
fi

finish
