#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-2-Clause
#
# cuda_native_toolchain_test.sh - the cuda-native SDK tree (Track #2380,
# stage C1.1 #2425), on a FRESH COPY of the STAGED content (checkout-index;
# after a commit that is the commit).  Stage new files before running it.
# No GPU and no driver are needed: it checks that clang 23 (ports llvm23)
# accepts our --cuda-path tree and emits PTX for sm_120 and sm_121.
#
# Steps:
# - provenance of every file and the man page lint; these need no LLVM;
# - mksdk.sh builds the tree, keeps a failed run from leaving anything, and
#   refuses bad output directories and an LLVM older than 23;
# - clang finds the installation and includes every header of the tree;
# - device PTX for sm_120, sm_121, sm_120a, sm_121a from two kernels, checked
#   for target, version, entry and instructions;
# - a host-only object that leaves the launch calls to libcudart;
# - mutants of the tree and of the sources that the checks must notice.
#
# Every check prints "ok", "FAIL" or "skip".  The summary counts all three.
# Exit status: the number of failures
# (at most 76, so it never reads as 77), 77 when LLVM 23 is missing and
# every check that ran passed (the checks that need LLVM were skipped), 99
# when the setup failed (no fresh copy).
# Run: sh tests/cuda_native_toolchain_test.sh
# Env: LLVM (default /usr/local/llvm23), TMPDIR (scratch, default /tmp).
# CUDA_NATIVE_TEST_CHILD=1 marks a child run, which never starts another.
# CUDA_NATIVE_TEST_REPO overrides REPO for a child run from the staged copy.

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=${CUDA_NATIVE_TEST_REPO:-$(CDPATH= cd -- "$HERE/.." && pwd)}
LLVM=${LLVM:-/usr/local/llvm23}
export LLVM
CXX=$LLVM/bin/clang++

W=$(mktemp -d "${TMPDIR:-/tmp}/cuda-native-test.XXXXXXXX") || exit 99
trap 'rm -rf "$W"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

PASS=0
FAIL=0
SKIP=0
ok() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
# skip_check NAME: record and print a skip without counting it as a pass.
# Time: O(1).  Space: O(1).
skip_check() { SKIP=$((SKIP + 1)); printf 'skip %s\n' "$1"; }
# expect_rc NAME RC WANT: rc captured by the caller on its own line before.
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
[ -f "$SRC/lib/cuda-native/mksdk.sh" ] && [ -f "$SRC/tests/cuda-native/vector_add.cu" ]
rc=$?
expect_rc "the fresh copy holds mksdk.sh and the test kernels" $rc 0
if [ $rc -ne 0 ]; then
	echo "The test runs on the staged tree: stage the files first" \
	    "(git add lib/cuda-native tests/cuda-native tests/cuda_native_toolchain_test.sh)." >&2
	printf '%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
	exit 99
fi
CN=$SRC/lib/cuda-native
K=$SRC/tests/cuda-native

# ---- provenance (no LLVM needed) -----------------------------------------
# provenance PATH: PATH is a file or a directory.  Record each file that
# lacks our BSD-2 header, names NVIDIA Corporation, or carries a copyright
# line other than ours, and each entry that is not a regular file or a
# directory (a symbolic link could point at a toolkit file).  Exit 0 when
# nothing is recorded, 1 when something is, 2 when a file could not be read.
# Time: O(total size under PATH).  Space: O(files).
provenance() {
	: >"$W/prov.out"
	find "$1" ! -type f ! -type d >"$W/prov.odd" || return 2
	[ -s "$W/prov.odd" ] &&
	    sed 's/^/not a regular file: /' "$W/prov.odd" >>"$W/prov.out"
	find "$1" -type f | sort >"$W/prov.files" || return 2
	while IFS= read -r f; do
		[ -r "$f" ] || return 2
		# grep: 0 found, 1 not found, anything else is an error.
		grep -q 'SPDX-License-Identifier: BSD-2-Clause' "$f"
		g1=$?
		grep -q 'Copyright (c) 2026 REVYTECH, Inc\.' "$f"
		g2=$?
		grep -Eiq 'nvidia[[:space:]]+corp' "$f"
		g3=$?
		grep -Ei 'copyright|\(c\)|©' "$f" >"$W/prov.all"
		g4=$?
		[ $g1 -le 1 ] && [ $g2 -le 1 ] && [ $g3 -le 1 ] && [ $g4 -le 1 ] || return 2
		[ $g1 -eq 0 ] && [ $g2 -eq 0 ] ||
		    echo "no REVYTECH BSD-2 header: ${f#$SRC/}" >>"$W/prov.out"
		[ $g3 -eq 0 ] &&
		    echo "names NVIDIA Corporation: ${f#$SRC/}" >>"$W/prov.out"
		grep -v 'Copyright (c) 2026 REVYTECH, Inc\.' "$W/prov.all" >"$W/prov.line"
		[ -s "$W/prov.line" ] &&
		    echo "other copyright line in ${f#$SRC/}: $(sed -n 1p "$W/prov.line")" >>"$W/prov.out"
	done <"$W/prov.files"
	[ ! -s "$W/prov.out" ]
}
provenance "$CN"
rc=$?
expect_rc "lib/cuda-native: our BSD-2 header everywhere, no NVIDIA or other copyright" $rc 0
[ $rc -eq 0 ] || sed -n 1,10p "$W/prov.out"
provenance "$K"
rc=$?
expect_rc "tests/cuda-native: the same" $rc 0
# This script names the patterns it looks for, so only its header (the first
# three lines) is checked.
sed -n 1,3p "$SRC/tests/cuda_native_toolchain_test.sh" >"$W/self.sh"
provenance "$W/self.sh"
expect_rc "this test carries our BSD-2 header" $? 0

# The check must catch a foreign copyright in any spelling.
cp -R "$CN" "$W/prov-m"
printf '/* COPYRIGHT 2024 NVIDIA Corp. */\n' >>"$W/prov-m/sdk/include/cuda.h"
provenance "$W/prov-m"
rc=$?
expect_rc "mutant: a planted NVIDIA copyright is caught" $rc 1
rm -rf "$W/prov-m"
cp -R "$CN" "$W/prov-m"
sed -i '' '/SPDX-License-Identifier/d' "$W/prov-m/mksdk.sh"
provenance "$W/prov-m"
rc=$?
expect_rc "mutant: mksdk.sh without its licence header is caught" $rc 1
rm -rf "$W/prov-m"
cp -R "$CN" "$W/prov-m"
ln -s /etc/passwd "$W/prov-m/sdk/include/linked.h"
provenance "$W/prov-m"
rc=$?
expect_rc "mutant: a symbolic link among the headers is caught" $rc 1

# ---- man page (no LLVM needed) ---------------------------------------------
MAN=$CN/man/cuda-native-toolchain.7
# The man page states the failure cap of finish(); keep them the same.
cap=$(sed -n 's/^	\[ "\$FAIL" -le \([0-9]*\) \] || FAIL=\1$/\1/p' "$SRC/tests/cuda_native_toolchain_test.sh")
[ -n "$cap" ] && [ "$cap" -lt 77 ] && grep -q "capped at $cap" "$MAN" &&
    grep -q "^# (at most $cap," "$SRC/tests/cuda_native_toolchain_test.sh"
expect_rc "the man page and test header state the failure cap of this test (${cap:-none})" $? 0
mandoc -T lint -W warning "$MAN" >"$W/mandoc.out" 2>&1
rc=$?
[ $rc -eq 0 ] && [ ! -s "$W/mandoc.out" ]
expect_rc "cuda-native-toolchain.7 is mandoc -T lint -W warning clean" $? 0
[ -s "$W/mandoc.out" ] && sed -n 1,10p "$W/mandoc.out"

# ---- the rest needs LLVM 23 ------------------------------------------------
# The minimum version is the one mksdk.sh enforces.
llvm_min=$(sed -n 's/^LLVM_MIN=\([0-9][0-9]*\)$/\1/p' "$CN/mksdk.sh")
if [ -z "$llvm_min" ]; then
	bad "mksdk.sh states LLVM_MIN"
	finish
fi
man_llvm_min=$(sed -n 's/^The compiler is clang from LLVM \([0-9][0-9]*\)$/\1/p' "$MAN")
[ -n "$man_llvm_min" ] && [ "$man_llvm_min" = "$llvm_min" ]
expect_rc "the man page LLVM minimum equals mksdk.sh LLVM_MIN ($llvm_min)" $? 0
man_status=$(mandoc -T ascii "$MAN" | col -b | sed -n '/^EXIT STATUS$/,/^EXAMPLES$/p' | tr '\n' ' ' | sed 's/  */ /g')
printf '%s\n' "$man_status" |
    grep -Fq 'With --check-llvm, mksdk.sh exits 0 when the LLVM install is usable and 2 otherwise, including a usage error.' &&
    ! printf '%s\n' "$man_status" | grep -Fq 'Both outcomes print'
expect_rc "the man page documents the --check-llvm outcome once" $? 0

# llvm_decision MKSDK OUTFILE: classify the --check-llvm answer as run, skip
# or broken; stdout goes to OUTFILE and stderr to OUTFILE.err.
# Time: O(check-llvm output).  Space: O(1) beyond its output files.
llvm_decision() {
	_llvm_mksdk=$1
	_llvm_out=$2
	sh "$_llvm_mksdk" --check-llvm >"$_llvm_out" 2>"$_llvm_out.err"
	_llvm_rc=$?
	_llvm_lines=$(wc -l <"$_llvm_out" 2>/dev/null)
	_llvm_shape=0
	[ "$_llvm_lines" -eq 1 ] &&
	    grep -Eq '^llvm: .* clang ([0-9]+|unknown)$' "$_llvm_out" && _llvm_shape=1
	if [ "$_llvm_rc" -eq 0 ] && [ "$_llvm_shape" -eq 1 ]; then
		printf 'run\n'
	elif [ "$_llvm_rc" -eq 2 ] && [ "$_llvm_shape" -eq 1 ] &&
	    grep -q '^mksdk: ' "$_llvm_out.err"; then
		printf 'skip\n'
	else
		printf 'broken\n'
	fi
}

# A syntax error also exits 2; it must never turn into a no-LLVM skip.
cp -R "$CN" "$W/cn-broken"
fi_line=$(grep -n -m 1 '^[[:space:]]*fi[[:space:]]*$' "$W/cn-broken/mksdk.sh")
fi_line=${fi_line%%:*}
[ -n "$fi_line" ] && sed -i '' "${fi_line}d" "$W/cn-broken/mksdk.sh"
sh -n "$W/cn-broken/mksdk.sh" >"$W/broken-syntax.out" 2>&1
broken_syntax_rc=$?
broken_decision=$(llvm_decision "$W/cn-broken/mksdk.sh" "$W/broken-llvm.out")
[ -n "$fi_line" ] && [ "$broken_syntax_rc" -ne 0 ] && [ "$broken_decision" = broken ]
expect_rc "a syntactically broken mksdk.sh --check-llvm is a failure, not a skip" $? 0

decision=$(llvm_decision "$CN/mksdk.sh" "$W/llvm-check.out")
found_major=$(sed -n 's/^llvm: .* clang \([0-9][0-9]*\)$/\1/p' "$W/llvm-check.out")
case $decision in
skip)
	echo "skip: no clang $llvm_min or later at $CXX (found ${found_major:-unknown}; pkg install llvm$llvm_min, or set LLVM); the checks below did not run"
	printf '%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
	[ "$FAIL" -eq 0 ] && exit 77
	finish
	;;
broken)
	bad "mksdk.sh --check-llvm gives a usable answer"
	finish
	;;
run)
	;;
esac
if [ ! -x "$CXX" ]; then
	echo "skip: no executable clang++ at $CXX; the checks below did not run"
	printf '%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
	[ "$FAIL" -eq 0 ] && exit 77
	finish
fi

# ---- mksdk.sh ------------------------------------------------------------
SDK=$W/sdk
sh "$CN/mksdk.sh" "$SDK" >"$W/mksdk.log" 2>&1
rc=$?
expect_rc "mksdk.sh builds the tree" $rc 0
if [ $rc -ne 0 ]; then
	sed -n 1,20p "$W/mksdk.log"
	finish
fi
[ -d "$SDK/include" ] && [ -f "$SDK/include/cuda.h" ] && [ -d "$SDK/bin" ] &&
    [ -s "$SDK/nvvm/libdevice/libdevice.10.bc" ]
expect_rc "the tree has include/, bin/ and libdevice.10.bc" $? 0
grep -qx '{"cuda":{"name":"cuda-native","version":"13.0.0"},"cuda_native":{"version":"0.1.0","track":"2380"}}' \
    "$SDK/version.json"
expect_rc "version.json is generated from cuda.h (13.0.0, cuda-native 0.1.0)" $? 0
[ -z "$(find "$(dirname "$SDK")" -maxdepth 1 -name '.mksdk.*')" ]
expect_rc "mksdk.sh leaves no build directory behind" $? 0

sh "$CN/mksdk.sh" "$SDK" >/dev/null 2>&1
expect_rc "mksdk.sh refuses a non-empty output directory" $? 2
sh "$CN/mksdk.sh" >/dev/null 2>&1
expect_rc "mksdk.sh refuses a missing argument" $? 2
sh "$CN/mksdk.sh" -x >/dev/null 2>&1
expect_rc "mksdk.sh refuses an unknown option" $? 2
sh "$CN/mksdk.sh" -h 2>/dev/null | grep -q '^usage: '
expect_rc "mksdk.sh -h prints usage on stdout" $? 0
: >"$W/afile"
sh "$CN/mksdk.sh" "$W/afile" >/dev/null 2>&1
expect_rc "mksdk.sh refuses an output path that is a file" $? 2
ln -s "$W/elsewhere" "$W/sdk-link"
sh "$CN/mksdk.sh" "$W/sdk-link" >/dev/null 2>&1
rc=$?
[ $rc -eq 2 ] && [ ! -e "$W/elsewhere" ]
expect_rc "mksdk.sh refuses a symbolic link and writes nothing through it" $? 0
mkdir "$W/elsewhere2"
ln -s "$W/elsewhere2" "$W/sdk-link2"
sh "$CN/mksdk.sh" "$W/sdk-link2/" >/dev/null 2>&1
rc=$?
[ $rc -eq 2 ] && [ -z "$(ls -A "$W/elsewhere2")" ] && [ -L "$W/sdk-link2" ]
expect_rc "mksdk.sh refuses a symbolic link given with a trailing slash" $? 0
LLVM=$W/nollvm sh "$CN/mksdk.sh" "$W/sdk-nollvm" >/dev/null 2>&1
expect_rc "mksdk.sh refuses when the LLVM tools are missing" $? 2
mkdir "$W/sdk-empty"
sh "$CN/mksdk.sh" "$W/sdk-empty" >/dev/null 2>&1
rc=$?
[ $rc -eq 0 ] && [ -f "$W/sdk-empty/include/cuda.h" ]
expect_rc "mksdk.sh fills an existing empty directory" $? 0

# Fake LLVM installs: an old clang; a clang 23 without the NVPTX target; a
# real clang with an llvm-as that fails, so the run fails after the build
# directory exists and its cleanup is what the check sees.
mkdir -p "$W/llvm19/bin" "$W/llvmbad/bin" "$W/llvmas/bin"
printf '#!/bin/sh\necho "clang version 19.1.7"\n' >"$W/llvm19/bin/clang"
printf '#!/bin/sh\ncase "$1" in --version) echo "clang version 23.1.5"; exit 0;; esac\necho "unknown target triple nvptx64-nvidia-cuda" >&2\nexit 1\n' \
    >"$W/llvmbad/bin/clang"
printf '#!/bin/sh\necho "llvm-as: planted failure" >&2\nexit 1\n' >"$W/llvmas/bin/llvm-as"
ln -s "$LLVM/bin/llvm-as" "$W/llvm19/bin/llvm-as"
ln -s "$LLVM/bin/llvm-as" "$W/llvmbad/bin/llvm-as"
ln -s "$LLVM/bin/clang" "$W/llvmas/bin/clang"
chmod +x "$W/llvm19/bin/clang" "$W/llvmbad/bin/clang" "$W/llvmas/bin/llvm-as"
LLVM=$W/llvm19 sh "$CN/mksdk.sh" "$W/sdk-old" >/dev/null 2>"$W/old.err"
rc=$?
[ $rc -eq 2 ] && [ ! -e "$W/sdk-old" ] && grep -q 'set LLVM' "$W/old.err" &&
    grep -q 'now LLVM=' "$W/old.err" &&
    grep -Fq "install LLVM $llvm_min or later (pkg install llvm$llvm_min), or set LLVM to the prefix of another LLVM $llvm_min-or-later install (now LLVM=$W/llvm19)" "$W/old.err"
expect_rc "mksdk.sh refuses a clang older than 23 and names the prefix in its remedy" $? 0

# The test and other callers can ask mksdk.sh for the toolchain decision
# without parsing clang --version or creating an SDK tree.
mkdir "$W/checkllvm"
(cd "$W/checkllvm" && sh "$CN/mksdk.sh" --check-llvm) >"$W/checkllvm.out" 2>"$W/checkllvm.err"
rc=$?
check_major=$(sed -n 's/^llvm: .* clang \([0-9][0-9]*\)$/\1/p' "$W/checkllvm.out")
[ $rc -eq 0 ] && [ -n "$check_major" ] && [ "$check_major" -ge "$llvm_min" ] &&
    [ "$(wc -l <"$W/checkllvm.out")" -eq 1 ] &&
    grep -q "^llvm: $LLVM clang $check_major\$" "$W/checkllvm.out" &&
    [ -z "$(ls -A "$W/checkllvm")" ]
expect_rc "--check-llvm reports the real LLVM, succeeds and creates nothing" $? 0
mkdir "$W/checkllvm-old"
(cd "$W/checkllvm-old" && LLVM=$W/llvm19 sh "$CN/mksdk.sh" --check-llvm) \
    >"$W/checkllvm-old.out" 2>"$W/checkllvm-old.err"
rc=$?
[ $rc -eq 2 ] && grep -qx "llvm: $W/llvm19 clang 19" "$W/checkllvm-old.out" &&
    grep -q 'clang is version 19;' "$W/checkllvm-old.err" &&
    [ -z "$(ls -A "$W/checkllvm-old")" ]
expect_rc "--check-llvm refuses LLVM 19 with the build diagnostic and creates nothing" $? 0

# Run this test as a child with an old clang to pin the skip contract.  The
# child uses the same staged sources and returns 77 after its no-LLVM checks.
# A child never starts another child, including when --check-llvm regresses.
if [ "${CUDA_NATIVE_TEST_CHILD:-0}" = 1 ]; then
	ok "skip-contract children (child run: not repeated)"
else
	ln -s clang "$W/llvm19/bin/clang++"
	CUDA_NATIVE_TEST_CHILD=1 CUDA_NATIVE_TEST_REPO="$REPO" LLVM="$W/llvm19" sh "$SRC/tests/cuda_native_toolchain_test.sh" >"$W/skip.out" 2>&1
	rc=$?
	[ $rc -eq 77 ] &&
	    grep -q "^skip: no clang $llvm_min or later at $W/llvm19/bin/clang++ (found 19;" "$W/skip.out"
	expect_rc "the no-LLVM skip names the required and found versions" $? 0
	grep -Eq '^[[:space:]]*CUDA_NATIVE_TEST_CHILD=1 CUDA_NATIVE_TEST_REPO="\$REPO" LLVM="\$W/llvm19" sh "\$SRC/tests/cuda_native_toolchain_test\.sh"' \
	    "$SRC/tests/cuda_native_toolchain_test.sh"
	expect_rc "the old-LLVM child is explicitly marked as a child" $? 0
	grep -Eq '^[[:space:]]*CUDA_NATIVE_TEST_CHILD=1 CUDA_NATIVE_TEST_REPO="\$REPO" LLVM="\$W/llvm19" sh "\$SRC/tests/cuda_native_toolchain_test\.sh"' \
	    "$SRC/tests/cuda_native_toolchain_test.sh" &&
	    grep -Eq '^REPO=\$\{CUDA_NATIVE_TEST_REPO:-' "$SRC/tests/cuda_native_toolchain_test.sh"
	expect_rc "the child runs the staged test and receives its source repository" $? 0

	# A usable clang without its companion clang++ is also a named skip.
	mkdir -p "$W/llvm-nocxx/bin"
	ln -s "$LLVM/bin/clang" "$W/llvm-nocxx/bin/clang"
	ln -s "$LLVM/bin/llvm-as" "$W/llvm-nocxx/bin/llvm-as"
	CUDA_NATIVE_TEST_CHILD=1 CUDA_NATIVE_TEST_REPO="$REPO" LLVM="$W/llvm-nocxx" sh "$SRC/tests/cuda_native_toolchain_test.sh" >"$W/skip-cxx.out" 2>&1
	rc=$?
	[ $rc -eq 77 ] &&
	    grep -Fq "skip: no executable clang++ at $W/llvm-nocxx/bin/clang++" "$W/skip-cxx.out"
	expect_rc "a missing clang++ is a child skip, not a compile failure" $? 0
fi

mkdir -p "$W/fail1/sdk"
LLVM=$W/llvmbad sh "$CN/mksdk.sh" "$W/fail1/sdk" >/dev/null 2>"$W/bad.err"
rc=$?
[ $rc -eq 1 ] && [ "$(ls -A "$W/fail1")" = sdk ] && [ -z "$(ls -A "$W/fail1/sdk")" ] &&
    grep -q 'unknown target triple' "$W/bad.err" && grep -q 'set LLVM' "$W/bad.err"
expect_rc "a clang without NVPTX: rc 1, the cause and the remedy shown, nothing left" $? 0
LLVM=$W/llvmbad sh "$CN/mksdk.sh" "$W/fail3/a/sdk" >/dev/null 2>&1
rc=$?
[ $rc -eq 1 ] && [ ! -e "$W/fail3" ]
expect_rc "a refused clang creates no parent directories" $? 0
mkdir "$W/fail2"
LLVM=$W/llvmas sh "$CN/mksdk.sh" "$W/fail2/sdk" >/dev/null 2>&1
rc=$?
[ $rc -eq 1 ] && [ ! -e "$W/fail2/sdk" ] && [ -z "$(ls -A "$W/fail2")" ]
expect_rc "a run that fails after the build directory exists leaves nothing behind" $? 0
sh "$CN/mksdk.sh" "$W/fail1/sdk" >/dev/null 2>&1
expect_rc "the same directory builds on the next run" $? 0

# OUT changes while the tree is built: an llvm-as that runs the real one and
# then plants a directory, or a symbolic link, where the tree is to go.
# Time: O(1) per case.  Space: O(tree).
mkdir -p "$W/llvmrace/bin" "$W/llvmlink/bin" "$W/llvmfile/bin"
ln -s "$LLVM/bin/clang" "$W/llvmrace/bin/clang"
ln -s "$LLVM/bin/clang" "$W/llvmlink/bin/clang"
ln -s "$LLVM/bin/clang" "$W/llvmfile/bin/clang"
printf '#!/bin/sh\n"%s/bin/llvm-as" "$@" || exit 1\n: >"%s/file/sdk"\n' \
    "$LLVM" "$W" >"$W/llvmfile/bin/llvm-as"
chmod +x "$W/llvmfile/bin/llvm-as"
printf '#!/bin/sh\n"%s/bin/llvm-as" "$@" || exit 1\nmkdir -p "%s/race/sdk/held"\n' \
    "$LLVM" "$W" >"$W/llvmrace/bin/llvm-as"
printf '#!/bin/sh\n"%s/bin/llvm-as" "$@" || exit 1\nmkdir -p "%s/linked"\nln -s "%s/linked" "%s/link/sdk"\n' \
    "$LLVM" "$W" "$W" "$W" >"$W/llvmlink/bin/llvm-as"
chmod +x "$W/llvmrace/bin/llvm-as" "$W/llvmlink/bin/llvm-as"
mkdir "$W/race" "$W/link"
LLVM=$W/llvmrace sh "$CN/mksdk.sh" "$W/race/sdk" >/dev/null 2>"$W/race.err"
rc=$?
[ $rc -eq 1 ] && [ "$(ls -A "$W/race/sdk")" = held ] &&
    [ -z "$(find "$W/race" -name '.mksdk.*')" ] && grep -q 'no longer empty' "$W/race.err"
expect_rc "a directory filled during the build: rc 1, the tree is not put into it" $? 0
LLVM=$W/llvmlink sh "$CN/mksdk.sh" "$W/link/sdk" >/dev/null 2>"$W/link.err"
rc=$?
[ $rc -eq 1 ] && [ -z "$(ls -A "$W/linked")" ] &&
    [ -z "$(find "$W/link" -name '.mksdk.*')" ] && grep -q 'symbolic link' "$W/link.err"
expect_rc "a symbolic link planted during the build: rc 1, nothing written through it" $? 0
# A file planted at OUT makes the rename fail: the failure is reported with
# the remedy, and the build directory is removed.
mkdir "$W/file"
LLVM=$W/llvmfile sh "$CN/mksdk.sh" "$W/file/sdk" >/dev/null 2>"$W/file.err"
rc=$?
[ $rc -eq 1 ] && [ -f "$W/file/sdk" ] && [ ! -s "$W/file/sdk" ] &&
    [ -z "$(find "$W/file" -name '.mksdk.*')" ] &&
    grep -q 'cannot put the tree at' "$W/file.err" && grep -q 'run mksdk.sh again' "$W/file.err" &&
    grep -q 'mv:' "$W/file.err"
expect_rc "a file planted during the build: rc 1, remedy and mv's own error, nothing left" $? 0

# Exercise the rename into a directory that appeared after the rmdir check.
# Fail closed: keep the caller's entry and any nested copy, and name the copy.
cp -R "$CN" "$W/cn-nested"
sed -i '' '/^if ! .*mv -h /i\
mkdir -p "$OUT/held"
' "$W/cn-nested/mksdk.sh"
sh "$W/cn-nested/mksdk.sh" "$W/race2/sdk" >/dev/null 2>"$W/race2.err"
rc=$?
race2_name=$(find "$W/race2/sdk" -mindepth 1 -maxdepth 1 -type d -name '.mksdk.*' | sed -n 1p)
race2_count=$(find "$W/race2/sdk" -mindepth 1 -maxdepth 1 -type d -name '.mksdk.*' | wc -l)
[ $rc -eq 1 ] && [ -d "$W/race2/sdk/held" ] && [ "$race2_count" -eq 1 ] &&
    [ -n "$race2_name" ] && grep -Fq "a copy may be left at $race2_name" "$W/race2.err" &&
    [ -z "$(find "$W/race2" -mindepth 1 -maxdepth 1 -name '.mksdk.*')" ]
expect_rc "a nested post-mv tree is left in place and its path is named" $? 0

# If OUT becomes a link after mv, the post-mv cleanup must not follow it.
cp -R "$CN" "$W/cn-postlink"
sed -i '' "/^if \[ -L \"\$OUT\" \]/i\\
mv \"\$OUT\" \"\$OUT.moved\"; mkdir -p \"$W/victim/\${NEW##*/}\"; ln -s \"$W/victim\" \"\$OUT\"
" "$W/cn-postlink/mksdk.sh"
sh "$W/cn-postlink/mksdk.sh" "$W/postlink/sdk" >/dev/null 2>"$W/postlink.err"
rc=$?
victim_name=$(ls -A "$W/victim" 2>/dev/null)
[ $rc -eq 1 ] && [ -n "$victim_name" ] && [ -d "$W/victim/$victim_name" ] &&
    grep -q 'changed during the build' "$W/postlink.err"
expect_rc "post-mv cleanup never removes a tree through a symbolic link" $? 0

# An unreadable OUT makes ls fail; that is not proof that OUT is empty.
mkdir -p "$W/llvmperm/bin"
ln -s "$LLVM/bin/clang" "$W/llvmperm/bin/clang"
printf '#!/bin/sh\n"%s/bin/llvm-as" "$@" || exit 1\nmkdir -p "%s/perm/sdk/x"\nchmod 000 "%s/perm/sdk"\n' \
    "$LLVM" "$W" "$W" >"$W/llvmperm/bin/llvm-as"
chmod +x "$W/llvmperm/bin/llvm-as"
# A skip is not a pass: the helper counts it without changing PASS.
skip_pass=$PASS
skip_total=$SKIP
skip_check "skip counter self-test" >"$W/skip-check.out" 2>&1
skip_rc=$?
[ $skip_rc -eq 0 ] && [ "$PASS" -eq "$skip_pass" ] &&
    [ "$SKIP" -eq $((skip_total + 1)) ] && grep -qx 'skip skip counter self-test' "$W/skip-check.out" &&
    grep -Eq '^[[:space:]]*skip_check "an unreadable output directory is not called empty \(root\)"[[:space:]]*$' "$SRC/tests/cuda_native_toolchain_test.sh"
skip_test_rc=$?
SKIP=$skip_total
expect_rc "skip_check counts a skip, not a pass, and handles the root case" $skip_test_rc 0
if [ "$(id -u)" -eq 0 ]; then
	skip_check "an unreadable output directory is not called empty (root)"
else
	LLVM=$W/llvmperm sh "$CN/mksdk.sh" "$W/perm/sdk" >/dev/null 2>"$W/perm.err"
	rc=$?
	chmod 755 "$W/perm/sdk"
	[ $rc -eq 1 ] && grep -q 'cannot read' "$W/perm.err" &&
	    ! grep -q 'the empty' "$W/perm.err"
	expect_rc "an unreadable output directory is not called empty" $? 0
fi

# ---- compiles ----------------------------------------------------------------
# devptx TREE ARCH SRC OUT [FLAGS...]: one device-only compile; the
# diagnostics go to OUT.log.
devptx() {
	_t=$1 _a=$2 _s=$3 _o=$4
	shift 4
	"$CXX" "$@" -x cuda --cuda-path="$_t" --cuda-gpu-arch="$_a" \
	    --cuda-device-only -S -o "$_o" "$_s" >"$_o.log" 2>&1
}

devptx "$SDK" sm_120 "$K/vector_add.cu" "$W/v.ptx" -v
rc=$?
expect_rc "baseline: the plain device compile works (the command the mutants use)" $rc 0
grep -q "Found CUDA installation: $SDK, version 13.0" "$W/v.ptx.log"
expect_rc "clang finds the cuda-native installation, version 13.0" $? 0

# includes_exactly TREE TAG: the entries under TREE/include (anything but
# directories) must be exactly the SDK headers clang includes for builtins.cu,
# device side and host side.  Lists in $W/have-TAG.txt and $W/used-TAG.txt.
# Time: O(headers).  Space: O(headers).
includes_exactly() {
	(cd "$1/include" && find . ! -type d | sed 's#^\./##' | sort) >"$W/have-$2.txt"
	"$CXX" -x cuda --cuda-path="$1" --cuda-gpu-arch=sm_120 --cuda-device-only \
	    -M "$K/builtins.cu" >"$W/dep-dev-$2.txt" 2>&1 || return 2
	"$CXX" -x cuda --cuda-path="$1" --cuda-gpu-arch=sm_120 --cuda-host-only \
	    -M "$K/builtins.cu" >"$W/dep-host-$2.txt" 2>&1 || return 2
	cat "$W/dep-dev-$2.txt" "$W/dep-host-$2.txt" | tr ' \\' '\n\n' |
	    sed -n "s#^$1/include/##p" | sort -u >"$W/used-$2.txt"
	[ -s "$W/used-$2.txt" ] || return 2
	cmp -s "$W/have-$2.txt" "$W/used-$2.txt"
}
includes_exactly "$SDK" sdk
rc=$?
expect_rc "clang includes exactly the headers of the tree" $rc 0
[ $rc -eq 0 ] || diff "$W/have-sdk.txt" "$W/used-sdk.txt" | sed -n 1,10p

# Time: O(arches x kernels x PTX size).  Space: O(1) beyond the PTX files.
for arch in sm_120 sm_121 sm_120a sm_121a; do
	for kern in vector_add builtins; do
		out=$W/$kern-$arch.ptx
		devptx "$SDK" "$arch" "$K/$kern.cu" "$out" -O2 -Werror
		rc=$?
		expect_rc "$kern: device PTX for $arch with -O2 -Werror" $rc 0
		[ $rc -eq 0 ] || { sed -n 1,10p "$out.log"; continue; }
		grep -qx ".target $arch" "$out"
		expect_rc "$kern $arch: .target $arch" $? 0
		grep -q '^\.version 9\.' "$out"
		expect_rc "$kern $arch: PTX ISA 9.x" $? 0
	done
	grep -q '^\.visible \.entry _Z4vaddPKfS0_Pfi' "$W/vector_add-$arch.ptx"
	expect_rc "vector_add $arch: .entry for vadd" $? 0
	b=$W/builtins-$arch.ptx
	grep -q '^\.visible \.entry _Z15builtins_kernel' "$b" &&
	    grep -q 'bar\.sync' "$b" &&
	    grep -Eq '(atom|red)\..*add\.(u32|s32)' "$b" &&
	    grep -Eq '(atom|red)\..*add\.f32' "$b" &&
	    grep -q 'shfl\.sync\.down\.b32' "$b"
	expect_rc "builtins $arch: entry, bar.sync, integer and float atomic add, shfl.sync.down" $? 0
done
# The man page states the scope of atomicAdd; this goes red when it changes.
grep -Eq 'atom\.(relaxed\.)?sys\.([a-z]+\.)?add\.f32' "$W/builtins-sm_120.ptx"
expect_rc "atomicAdd is a system-scope atomic (as the man page says)" $? 0

"$CXX" -O2 -Werror -x cuda --cuda-path="$SDK" --cuda-gpu-arch=sm_120 \
    --cuda-host-only -c -o "$W/host.o" "$K/vector_add.cu" >"$W/host.log" 2>&1
expect_rc "vector_add: host-only object" $? 0
"$LLVM/bin/llvm-nm" "$W/host.o" >"$W/host.nm" 2>&1
grep -Eq '^ +U cudaLaunchKernel$' "$W/host.nm" &&
    grep -Eq '^ +U __cudaPushCallConfiguration$' "$W/host.nm" &&
    grep -Eq '^ +U __cudaPopCallConfiguration$' "$W/host.nm"
expect_rc "host object leaves cudaLaunchKernel and the push/pop call configuration to libcudart" $? 0

# ---- mutants (each on a copy of the built tree) ----------------------------
# mutant NAME: copy the tree to $W/m-NAME and print its path.
mutant() {
	rm -rf "$W/m-$1"
	cp -R "$SDK" "$W/m-$1" && printf '%s\n' "$W/m-$1"
}

# The wrapper of clang stops with this #error when cuda.h has no CUDA_VERSION.
M=$(mutant noversion) || finish
sed -i '' '/^#define CUDA_VERSION /d' "$M/include/cuda.h"
devptx "$M" sm_120 "$K/vector_add.cu" "$W/m-noversion.ptx"
rc=$?
[ $rc -ne 0 ] && grep -q 'cuda.h did not define CUDA_VERSION' "$W/m-noversion.ptx.log"
expect_rc "mutant: cuda.h without CUDA_VERSION stops the compile with the wrapper's error" $? 0

# clang 23 takes the SDK version from CUDA_VERSION in include/cuda.h (it
# does not read version.json, which is cuda-native's own identity file).
M=$(mutant otherversion) || finish
sed -i '' 's/^#define CUDA_VERSION 13000$/#define CUDA_VERSION 12080/' "$M/include/cuda.h"
devptx "$M" sm_120 "$K/vector_add.cu" "$W/m-otherversion.ptx" -v
grep -q "Found CUDA installation: $M, version 12.8" "$W/m-otherversion.ptx.log"
expect_rc "mutant: clang takes the SDK version from our cuda.h" $? 0

# clang needs bin/ to accept the tree as an installation.
M=$(mutant nobin) || finish
rm -rf "$M/bin"
devptx "$M" sm_120 "$K/vector_add.cu" "$W/m-nobin.ptx"
rc=$?
[ $rc -ne 0 ] && grep -q 'cannot find CUDA installation' "$W/m-nobin.ptx.log"
expect_rc "mutant: a tree without bin/ is not a CUDA installation" $? 0

# An empty __global__ makes the kernel an ordinary function.  entry_only.cu
# uses plain C++ only, so it still compiles: the only change is the entry.
devptx "$SDK" sm_120 "$K/entry_only.cu" "$W/entry_only.ptx"
rc=$?
[ $rc -eq 0 ] && grep -q '\.entry _Z10entry_onlyPi' "$W/entry_only.ptx"
expect_rc "entry_only: the unmutated tree emits the kernel entry" $? 0
M=$(mutant noglobal) || finish
sed -i '' 's/^#define __global__ .*/#define __global__/' "$M/include/host_defines.h"
devptx "$M" sm_120 "$K/entry_only.cu" "$W/m-noglobal.ptx"
rc=$?
[ $rc -eq 0 ] && ! grep -q '\.entry _Z10entry_onlyPi' "$W/m-noglobal.ptx"
expect_rc "mutant: an empty __global__ compiles but loses the kernel entry" $? 0

# A source tree without libdevice.ll must not build.
cp -R "$CN" "$W/cn-nolibdevice"
rm -f "$W/cn-nolibdevice/libdevice/libdevice.ll"
sh "$W/cn-nolibdevice/mksdk.sh" "$W/sdk-nolibdevice" >/dev/null 2>"$W/nolibdevice.err"
rc=$?
[ $rc -eq 1 ] && [ ! -e "$W/sdk-nolibdevice" ] &&
    grep -q 'libdevice.ll is missing; the source tree is incomplete' "$W/nolibdevice.err"
expect_rc "mutant: mksdk.sh refuses a source tree without libdevice.ll" $? 0
cp -R "$CN" "$W/cn-nocudah"
rm -f "$W/cn-nocudah/sdk/include/cuda.h"
sh "$W/cn-nocudah/mksdk.sh" "$W/sdk-nocudah" >/dev/null 2>"$W/nocudah.err"
rc=$?
[ $rc -eq 1 ] && [ ! -e "$W/sdk-nocudah" ] &&
    grep -q 'cuda.h is missing; the source tree is incomplete' "$W/nocudah.err"
expect_rc "mutant: mksdk.sh refuses a source tree without cuda.h" $? 0

# __noinline__ must stay the clang keyword: a macro breaks the
# __attribute__((__noinline__)) spelling, which builtins.cu uses.
M=$(mutant noinline) || finish
sed -i '' 's|^#define __forceinline__ |#define __noinline__ __attribute__((noinline))\
#define __forceinline__ |' "$M/include/host_defines.h"
devptx "$M" sm_120 "$K/builtins.cu" "$W/m-noinline.ptx"
rc=$?
[ $rc -ne 0 ] && grep -q 'noinline' "$W/m-noinline.ptx.log"
expect_rc "mutant: a __noinline__ macro breaks __attribute__((__noinline__))" $? 0

# The vector types: sizes, alignments and constructors (host and device).
# The device side stops at PTX (-S): there is no ptxas in bin/ yet.
for side in --cuda-host-only --cuda-device-only; do
	"$CXX" -O2 -Werror -x cuda --cuda-path="$SDK" --cuda-gpu-arch=sm_120 \
	    "$side" -S -o "$W/vt$side.s" "$K/vector_types_check.cu" >"$W/vt$side.log" 2>&1
	rc=$?
	expect_rc "vector types: sizes, alignments and make_* compile ($side)" $rc 0
	[ $rc -eq 0 ] || sed -n 1,10p "$W/vt$side.log"
done
M=$(mutant badalign) || finish
sed -i '' 's/^struct __align__(16) float4 {$/struct __align__(8) float4 {/' "$M/include/vector_types.h"
"$CXX" -x cuda --cuda-path="$M" --cuda-gpu-arch=sm_120 --cuda-host-only -c \
    -o "$W/m-badalign.o" "$K/vector_types_check.cu" >"$W/m-badalign.log" 2>&1
rc=$?
[ $rc -ne 0 ] && grep -q 'static assertion failed' "$W/m-badalign.log"
expect_rc "mutant: a wrong float4 alignment fails the vector type check" $? 0

# A dead stub (a header clang never includes) must fail the include check,
# run by the same function on the mutated tree.
M=$(mutant deadstub) || finish
cp "$M/include/host_config.h" "$M/include/never_included.h"
includes_exactly "$M" deadstub
expect_rc "mutant: an extra header that clang never includes is noticed" $? 1

finish
