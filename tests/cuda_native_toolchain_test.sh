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
# - host objects, full compiles for one or two architectures, a linked launch
#   that returns cudaErrorNotSupported, and schema-validated tool traces;
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
# directory (a symbolic link could point at a toolkit file).  Only immediate
# schema/*.schema.json children of the cuda-native root passed as PATH are
# exempt from the comment header; those files must instead parse as JSON.
# Exit 0 when nothing is recorded, 1 when something is, 2 when unreadable.
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
		relative=${f#"$1"/}
		schema_file=0
		case $relative in
		schema/*.schema.json)
			case ${relative#schema/} in
			*/*) ;;
			*) schema_file=1 ;;
			esac
			;;
		esac
		if [ "$schema_file" -eq 1 ]; then
			python3 -I -c 'import json, sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$f" \
			    >/dev/null 2>&1 ||
			    echo "invalid JSON schema: ${f#$SRC/}" >>"$W/prov.out"
		else
			[ $g1 -eq 0 ] && [ $g2 -eq 0 ] ||
			    echo "no REVYTECH BSD-2 header: ${f#$SRC/}" >>"$W/prov.out"
		fi
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
rm -rf "$W/prov-m"
cp -R "$CN" "$W/prov-m"
printf '{not JSON}\n' >"$W/prov-m/schema/bad.schema.json"
provenance "$W/prov-m"
rc=$?
[ $rc -eq 1 ] && grep -q 'invalid JSON schema: .*schema/bad.schema.json' "$W/prov.out"
expect_rc "mutant: malformed JSON in the narrow schema exemption is caught" $? 0
rm -rf "$W/prov-m"
cp -R "$CN" "$W/prov-m"
printf '{}\n' >"$W/prov-m/sdk/include/not-a-schema.schema.json"
provenance "$W/prov-m"
rc=$?
[ $rc -eq 1 ] && grep -q 'no REVYTECH BSD-2 header: .*sdk/include/not-a-schema.schema.json' "$W/prov.out"
expect_rc "mutant: the schema suffix outside schema/ does not exempt a header" $? 0
rm -rf "$W/prov-m"

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
python3 -I - "$CN/man/libcudart-stub.3" <<'PY'
import sys
with open(sys.argv[1], encoding="utf-8") as f:
    text = f.read()
paragraph = text.split("For a kernel launch written", 1)[1].split(".Pp", 1)[0]
words = ("__cudaPushCallConfiguration", "device stub",
         "__cudaPopCallConfiguration", "cudaLaunchKernel")
positions = [paragraph.find(word) for word in words]
assert all(pos >= 0 for pos in positions)
assert positions == sorted(positions) and len(set(positions)) == len(positions)
PY
expect_rc "libcudart-stub.3 documents push, device stub, pop, then launch" $? 0
python3 -I - "$MAN" <<'PY'
import sys
with open(sys.argv[1], encoding="utf-8") as f:
    text = f.read()
synopsis = text.split(".Nm clang++", 2)[2].split(".Sh DESCRIPTION", 1)[0]
for option in (".Fl L Ns Ar outdir/lib64", ".Fl l Ns Cm cudart",
               ".Fl Wl,-rpath, Ns Qq $PWD/ Ns Ar outdir/lib64"):
    assert option in synopsis, option
PY
expect_rc "the full-link SYNOPSIS supplies library path, libcudart and rpath" $? 0
grep -q '^\.Op Fl m64$' "$CN/man/nvptxas.1"
expect_rc "nvptxas(1) marks -m64 as an optional compatibility flag" $? 0
grep -q '^\.Op Fl 64$' "$CN/man/nvfatbin.1"
expect_rc "nvfatbin(1) marks -64 as an optional compatibility flag" $? 0
! grep -q 'schema-checked' "$MAN" && grep -q 'events that conform to' "$MAN"
expect_rc "the runtime manual says trace events conform to, not are checked by, a schema" $? 0

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
# The device side stops at PTX (-S) to inspect its text without a fatbinary.
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

# ---- C1.1 round B: full compile, link and launch stubs ---------------------
SCHEMAS=$SDK/share/cuda-native/schema
native_rel=$(sed -n 's/^#define CUDA_NATIVE_VERSION \([0-9][0-9]*\)$/\1/p' "$CN/sdk/include/cuda.h")
native_version=$(printf '%d.%d.%d' \
    $((native_rel / 10000)) $((native_rel % 10000 / 100)) $((native_rel % 100)))
# The sources are POSIX sh even though the installed names have no suffix.
# Only the shared library has version placeholders; the tools are copied as-is.
# Time: O(number of tools).  Space: O(1).
# nvptxas is the shell tool; nvfatbin and cuda-objdump are C programs.
# Time: O(number of tools).  Space: O(1).
sh -n "$CN/tools/nvptxas.sh" >"$W/nvptxas-syntax.out" 2>&1
expect_rc "nvptxas.sh: POSIX shell syntax" $? 0
[ -x "$SDK/bin/nvptxas" ] && [ -x "$SDK/bin/ptxas" ]
expect_rc "mksdk.sh installs executable nvptxas and ptxas" $? 0
cmp -s "$SDK/bin/nvptxas" "$SDK/bin/ptxas"
expect_rc "nvptxas and ptxas are the same program" $? 0
# Time: O(number of C tools).  Space: O(1).
for tool in nvfatbin fatbinary cuda-objdump; do
	[ -x "$SDK/bin/$tool" ]
	expect_rc "mksdk.sh installs executable $tool" $? 0
done
cmp -s "$SDK/bin/nvfatbin" "$SDK/bin/fatbinary"
expect_rc "nvfatbin and fatbinary are the same program" $? 0
! grep -Fq '@CUDA_NATIVE_VERSION' "$SDK/bin/nvfatbin" &&
    ! grep -Fq '@CUDA_NATIVE_VERSION' "$SDK/bin/cuda-objdump"
expect_rc "the C tools carry no version placeholder" $? 0
# Time: O(number of installed tool names).  Space: O(1).
for tool in nvptxas ptxas nvfatbin fatbinary; do
	"$SDK/bin/$tool" -h >"$W/$tool-help.out" 2>"$W/$tool-help.err"
	rc=$?
	[ $rc -eq 0 ] && grep -q '^usage: ' "$W/$tool-help.out" && [ ! -s "$W/$tool-help.err" ]
	expect_rc "$tool -h prints usage on stdout" $? 0
done
python3 -I - "$CN/man" "$W/nvptxas-help.out" "$W/nvfatbin-help.out" \
    "$SDK" "$W" <<'PY'
import re
import subprocess
import sys
from pathlib import Path

accepted = {
    "nvptxas": ["-h", "--help", "-m64", "-O0", "-O1", "-O2", "-O3",
                "-g", "-lineinfo", "--dont-merge-basicblocks", "--return-at-end",
                "--gpu-name", "--output-file", "--version", "--json"],
    "nvfatbin": ["-h", "--help", "-64", "-g", "--create", "--image3",
                 "--version", "--json"],
}
usage_forms = {
    "nvptxas": ["[-m64]", "[-O0|-O1|-O2|-O3]", "[-g]", "[-lineinfo]",
                "[--dont-merge-basicblocks]", "[--return-at-end]",
                "--gpu-name ARCH", "--output-file FILE", "[--] INPUT.ptx",
                "--version [--json]", "-h|--help"],
    "nvfatbin": ["[-64]", "[-g]", "--create FILE",
                 "--image3=kind=elf|ptx,sm=NNN,file=INPUT",
                 "--version [--json]", "-h|--help"],
}
for tool, options in accepted.items():
    text = (Path(sys.argv[1]) / (tool + ".1")).read_text(encoding="utf-8")
    usage_path = Path(sys.argv[2 if tool == "nvptxas" else 3])
    usage = usage_path.read_text(encoding="utf-8")
    lines = usage.splitlines()
    assert lines and all(len(line) <= 80 for line in lines), (tool, "width", lines)
    joined = " ".join(line.strip() for line in lines)
    for option in options:
        macro = r"(?m)^\.Fl " + re.escape(option[1:]) + r"(?:\s*[,.])?$"
        assert re.search(macro, text), (tool, option, "manual")
    for form in usage_forms[tool]:
        assert form in joined, (tool, form, "usage")

# Drive real compiles from the same accepted-option table.  Help and version
# forms have their own checks; --json is valid only after --version.
work = Path(sys.argv[5]) / "accepted-options"
work.mkdir()
ptx = work / "input.ptx"
elf = work / "input.o"
ptx.write_text(".target sm_120\n.visible .entry accepted() { ret; }\n", encoding="ascii")
elf.write_bytes(b"CUDA-NATIVE-STUB-CUBIN 1\narch=sm_120\n---\n")
for tool, options in accepted.items():
    for index, option in enumerate(options):
        if option in ("-h", "--help", "--version", "--json"):
            continue
        output = work / ("%s-%d.out" % (tool, index))
        if tool == "nvptxas":
            extra = {
                "--gpu-name": ["--gpu-name", "sm_120"],
                "--output-file": ["--output-file", str(output)],
            }.get(option, [option])
            command = [str(Path(sys.argv[4]) / "bin" / tool)] + extra + [
                "--gpu-name", "sm_120", "--output-file", str(output), str(ptx)]
            magic = b"CUDA-NATIVE-STUB-CUBIN 1\n"
        else:
            image = "--image3=kind=elf,sm=120,file=" + str(elf)
            extra = {
                "--create": ["--create", str(output)],
                "--image3": ["--image3=kind=ptx,sm=120,file=" + str(ptx)],
            }.get(option, [option])
            command = [str(Path(sys.argv[4]) / "bin" / tool)] + extra + [
                "--create", str(output), image]
            magic = b"\x10\xff\x10\xad"
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        assert result.returncode == 0, (tool, option, result.stderr.decode("utf-8", "replace"))
        assert output.read_bytes().startswith(magic), (tool, option, "output")
PY
expect_rc "manuals, exact usage grammar, width and real accepted-option compiles agree" $? 0
python3 -I - "$W/nvptxas-help.out" "$W/ptxas-help.out" \
    "$W/nvfatbin-help.out" "$W/fatbinary-help.out" <<'PY'
import sys
from pathlib import Path
# The C tools name themselves the way they were invoked; the shell tool
# keeps its canonical name.
names = {"nvptxas-help.out": "nvptxas", "ptxas-help.out": "nvptxas",
         "nvfatbin-help.out": "nvfatbin", "fatbinary-help.out": "fatbinary"}
for path in sys.argv[1:]:
    first = Path(path).read_text(encoding="utf-8").splitlines()[0]
    assert first.startswith("usage: " + names[Path(path).name] + " "), (path, first)
fatbin = Path(sys.argv[3]).read_text(encoding="utf-8")
assert "--image3=kind=elf|ptx,sm=NNN,file=INPUT" in fatbin
PY
expect_rc "usage names the program the way it was invoked" $? 0
"$SDK/bin/fatbinary" -64 --create "$W/alias-name.fatbin" \
    >"$W/alias-name.out" 2>"$W/alias-name.err"
rc=$?
[ $rc -eq 2 ] && grep -q '^fatbinary: ' "$W/alias-name.err"
expect_rc "the fatbinary alias names itself in its diagnostics" $? 0

# Prove that the exact usage assertion is not satisfied by the -g substring in
# --gpu-name.  The old substring check accepts this mutant; the grammar check
# must reject it.  A removed parser case must also fail a real invocation.
cp -R "$SDK" "$W/sdk-usage-mutant"
sed -i '' 's/ \[-g\]//' "$W/sdk-usage-mutant/bin/nvptxas"
"$W/sdk-usage-mutant/bin/nvptxas" -h >"$W/usage-mutant.out" 2>"$W/usage-mutant.err"
rc=$?
[ $rc -eq 0 ] && grep -q -- '-g' "$W/usage-mutant.out"
expect_rc "usage mutation fixture retains the old misleading -g substring" $? 0
python3 -I - "$W/usage-mutant.out" <<'PY'
import sys
with open(sys.argv[1], encoding="utf-8") as f:
    joined = " ".join(line.strip() for line in f)
assert "[-g]" in joined, joined
PY
expect_rc "mutant: removing only [-g] from nvptxas usage is detected" $? 1
cp -R "$SDK" "$W/sdk-no-lineinfo"
sed -i '' 's/ | -lineinfo//' "$W/sdk-no-lineinfo/bin/nvptxas"
"$W/sdk-no-lineinfo/bin/nvptxas" -lineinfo --gpu-name sm_120 \
    --output-file "$W/no-lineinfo.o" "$W/accepted-options/input.ptx" \
    >"$W/no-lineinfo.out" 2>"$W/no-lineinfo.err"
rc=$?
[ $rc -eq 2 ] && grep -Fq 'unsupported option -lineinfo' "$W/no-lineinfo.err"
expect_rc "mutant: deleting the -lineinfo parser case breaks its real compile" $? 0
# Text and JSON versions have one source and one strict schema.
# Time: O(number of canonical tools).  Space: O(version JSON).
for tool in nvptxas nvfatbin; do
	"$SDK/bin/$tool" --version >"$W/$tool-version.out" 2>"$W/$tool-version.err"
	rc=$?
	[ $rc -eq 0 ] && grep -Fqx "$tool (cuda-native) $native_version stub" "$W/$tool-version.out" &&
	    [ ! -s "$W/$tool-version.err" ]
	expect_rc "$tool --version prints the cuda.h version" $? 0
	"$SDK/bin/$tool" --version --json >"$W/$tool-version.json" 2>"$W/$tool-version-json.err"
	rc=$?
	[ $rc -eq 0 ] && [ ! -s "$W/$tool-version-json.err" ]
	expect_rc "$tool --version --json exits 0 without diagnostics" $? 0
	python3 -I "$SRC/tests/libnvrm/schema_validate.py" \
	    "$SCHEMAS/cuda-native-tool-1.schema.json" "$W/$tool-version.json" \
	    >"$W/$tool-version.schema" 2>&1
	expect_rc "$tool --version --json validates against cuda-native-tool-1" $? 0
	python3 -I - "$W/$tool-version.json" "$tool" "$native_version" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    doc = json.load(f)
major, minor, patch = (int(part) for part in sys.argv[3].split("."))
assert doc == {"tool": sys.argv[2], "version": sys.argv[3],
               "version_major": major, "version_minor": minor,
               "version_patch": patch, "stub": True, "track": "2427"}
PY
	expect_rc "$tool JSON names its tool, four version fields, stub and track" $? 0
done

# The shell tool and the C tools carry their version data in their own
# sources; the installed copies hold no placeholder.
TOOL_LIB=$SDK/share/cuda-native/cuda-native-tool-lib.sh
! grep -Fq '@CUDA_NATIVE_' "$CN/tools/nvptxas.sh" &&
    ! grep -Fq '@CUDA_NATIVE_' "$TOOL_LIB" &&
    [ "$(grep -c 's/@CUDA_NATIVE_VERSION@/$rel_version/g' "$CN/mksdk.sh")" -eq 1 ]
expect_rc "one mksdk substitution serves every source file with placeholders" $? 0
[ -f "$TOOL_LIB" ] && sh -n "$TOOL_LIB" >"$W/tool-lib-syntax.out" 2>&1 &&
    grep -Fq '@CUDA_NATIVE_VERSION@' "$CN/tools/cuda-native-tool-lib.sh" &&
    grep -Fq '@CUDA_NATIVE_VERSION_MAJOR@' "$CN/tools/cuda-native-tool-lib.sh" &&
    ! grep -Fq '@CUDA_NATIVE_VERSION' "$TOOL_LIB" &&
    grep -Fq '../share/cuda-native/cuda-native-tool-lib.sh' "$CN/tools/nvptxas.sh"
expect_rc "the shell tool sources the installed shared library relative to bin" $? 0
grep -Fq '@CUDA_NATIVE_VERSION@' "$CN/fatbin/nvfatbin.c" &&
    grep -Fq '@CUDA_NATIVE_VERSION_MAJOR@' "$CN/fatbin/nvfatbin.c" &&
    grep -Fq '@CUDA_NATIVE_VERSION@' "$CN/fatbin/cuda-objdump.c" &&
    ! grep -Fq '@CUDA_NATIVE_VERSION' "$SDK/bin/nvfatbin" &&
    ! grep -Fq '@CUDA_NATIVE_VERSION' "$SDK/bin/cuda-objdump"
expect_rc "the C tools carry the substituted version data" $? 0
grep -Fq '2427' "$CN/tools/cuda-native-tool-lib.sh" 2>/dev/null &&
    ! grep -Fq '2427' "$CN/tools/nvptxas.sh" &&
    grep -Fq '2427' "$CN/fatbin/nvfatbin.c" &&
    ! grep -Fq '2427' "$CN/fatbin/cuda-objdump.c"
expect_rc "the 2427 literal lives in the version data, not in an option message" $? 0
python3 -I - "$CN/tools/nvptxas.sh" <<'PY'
import sys
for path in sys.argv[1:]:
    with open(path, encoding="utf-8") as f:
        lines = [line.strip() for line in f if "--version" in line and not line.lstrip().startswith("echo ")]
    assert lines == ['[ "${1:-}" = --version ] && handle_version "$@"'], (path, lines)
PY
expect_rc "the shell tool delegates every --version path to the shared helper" $? 0
grep -Fq 'CUDA_NATIVE_VERSION_TEXT' "$CN/fatbin/nvfatbin.c" &&
    grep -Fq 'show_version' "$CN/fatbin/nvfatbin.c" &&
    ! grep -Fq 'cuda-native-tool-lib.sh' "$CN/fatbin/nvfatbin.c"
expect_rc "the C tool carries its own version data and no shell helper" $? 0
cp -R "$SDK" "$W/sdk-tool-lib-relocated"
"$W/sdk-tool-lib-relocated/bin/ptxas" --version >"$W/relocated-ptxas.out" 2>"$W/relocated-ptxas.err"
rc=$?
[ $rc -eq 0 ] && grep -Fqx "nvptxas (cuda-native) $native_version stub" "$W/relocated-ptxas.out" &&
    [ ! -s "$W/relocated-ptxas.err" ]
expect_rc "a relocated ptxas still loads its shared tool library" $? 0
mkdir -p "$W/symlink-bin" "$W/share/cuda-native"
printf 'echo DECOY >&2\nexit 1\n' >"$W/share/cuda-native/cuda-native-tool-lib.sh"
# Time: O(number of canonical tools).  Space: O(one version line).
for tool in nvptxas nvfatbin; do
	ln -s "$SDK/bin/$tool" "$W/symlink-bin/$tool"
	"$W/symlink-bin/$tool" --version >"$W/symlink-$tool.out" 2>"$W/symlink-$tool.err"
	rc=$?
	[ $rc -eq 0 ] && grep -Fqx "$tool (cuda-native) $native_version stub" \
	    "$W/symlink-$tool.out" && [ ! -s "$W/symlink-$tool.err" ]
	expect_rc "$tool resolves its real installation when invoked through a symlink" $? 0
done

# Dropping the first major-version sed expression used to affect only the
# placeholder-free tools.  It must now damage the shared library and be seen.
# Dropping the major-version substitution must be caught: the C tools carry
# the same placeholders, so the build itself fails without it.
cp -R "$CN" "$W/cn-substitution"
awk '!done && /s\/@CUDA_NATIVE_VERSION_MAJOR@/ { done=1; next } { print }' \
    "$W/cn-substitution/mksdk.sh" >"$W/cn-substitution/mksdk.sh.new" &&
    mv "$W/cn-substitution/mksdk.sh.new" "$W/cn-substitution/mksdk.sh"
sh "$W/cn-substitution/mksdk.sh" "$W/sdk-substitution" >"$W/substitution-mutant.log" 2>&1
rc=$?
[ $rc -ne 0 ] && grep -q 'CUDA_NATIVE_VERSION_MAJOR' "$W/substitution-mutant.log"
expect_rc "mutant: dropping the major-version substitution is caught" $? 0

[ -f "$SDK/lib64/libcudart.so.13" ] && [ -L "$SDK/lib64/libcudart.so" ] &&
    [ "$(readlink "$SDK/lib64/libcudart.so")" = libcudart.so.13 ]
expect_rc "mksdk.sh builds libcudart.so.13 and its relative linker symlink" $? 0
grep -Fq -- '-fuse-ld=lld' "$CN/mksdk.sh"
expect_rc "mksdk.sh explicitly selects the LLD linker for libcudart" $? 0
"$LLVM/bin/llvm-readelf" -p .comment "$SDK/lib64/libcudart.so.13" >"$W/cudart.comment" 2>&1
rc=$?
[ $rc -eq 0 ] && grep -q 'LLD' "$W/cudart.comment"
expect_rc "libcudart's .comment identifies the LLD linker" $? 0
diff -r "$CN/schema" "$SCHEMAS" >"$W/schemas.diff" 2>&1
expect_rc "the complete schema directory is installed unchanged" $? 0

# A newly added schema must be checked and installed without editing a second
# list.  Recursive comparison notices both a missing and an extra installed file.
cp -R "$CN" "$W/cn-extra-schema"
cat >"$W/cn-extra-schema/schema/extra-1.schema.json" <<'JSON'
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "urn:cloudbsd:cuda-native:schema:extra/1",
  "type": "object"
}
JSON
sh "$W/cn-extra-schema/mksdk.sh" "$W/sdk-extra-schema" >"$W/extra-schema.log" 2>&1
build_rc=$?
diff -r "$W/cn-extra-schema/schema" "$W/sdk-extra-schema/share/cuda-native/schema" \
    >"$W/extra-schema.diff" 2>&1
rc=$?
[ "$build_rc" -eq 0 ] && [ "$rc" -eq 0 ]
expect_rc "mutant: an extra source schema is installed and recursively compared" $? 0
python3 -I - "$SDK/version.json" "$CN/sdk/include/cuda.h" <<'PY'
import json, re, sys
with open(sys.argv[1], encoding="utf-8") as f:
    doc = json.load(f)
with open(sys.argv[2], encoding="utf-8") as f:
    text = f.read()
def macro(name):
    return int(re.search(r"^#define %s ([0-9]+)$" % name, text, re.M).group(1))
api = macro("CUDA_VERSION")
rel = macro("CUDA_NATIVE_VERSION")
api_version = "%d.%d.%d" % (api // 1000, api % 1000 // 10, 0)
rel_version = "%d.%d.%d" % (rel // 10000, rel % 10000 // 100, rel % 100)
assert doc == {"cuda": {"name": "cuda-native", "version": api_version},
               "cuda_native": {"version": rel_version, "track": "2380"}}
PY
expect_rc "version.json agrees with CUDA_VERSION and CUDA_NATIVE_VERSION" $? 0

# full_obj TAG [clang CUDA options...]: compile launch_main.cu completely and
# capture both tool stubs' JSONL records in TAG.trace.
full_obj()
{
	_full_tag=$1
	shift
	: >"$W/$_full_tag.trace"
	PATH="$SDK/bin:$PATH" CUDA_NATIVE_TRACE="$W/$_full_tag.trace" \
	    "$CXX" -O2 -Werror -x cuda --cuda-path="$SDK" "$@" \
	    -c "$K/launch_main.cu" -o "$W/$_full_tag.o" \
	    >"$W/$_full_tag.log" 2>&1
}

full_obj full120 --cuda-gpu-arch=sm_120
expect_rc "launch_main: full compile for sm_120" $? 0
full_obj fullg -g --cuda-gpu-arch=sm_120
expect_rc "launch_main: full -g compile for sm_120" $? 0
container_magic=$(printf '\020\377\020\255')
[ -f "$W/full120.o" ] && grep -q -a -F "$container_magic" "$W/full120.o" &&
    ! grep -q -a -F 'NVFATBIN-STUB-1' "$W/full120.o"
expect_rc "the full object embeds the cuda-native fatbin container, not the old NV-prefixed magic" $? 0
full_obj full121 --cuda-gpu-arch=sm_121
expect_rc "launch_main: full compile for sm_121" $? 0
full_obj fulltwo --cuda-gpu-arch=sm_120 --cuda-gpu-arch=sm_121
expect_rc "launch_main: one full compile for sm_120 and sm_121" $? 0
full_obj fulllegacy --no-offload-new-driver --cuda-gpu-arch=sm_120
expect_rc "launch_main: full compile with the old driver keeps ELF and PTX" $? 0

# check_trace TAG PT_COUNT ARCHES MEMBERS KINDS: split mixed JSONL by tool,
# prove the observed call/member/architecture sequence, then validate each
# record with the repository's deliberately small JSON Schema validator.
check_trace()
{
	_ct_tag=$1
	python3 -I - "$W/$_ct_tag.trace" "$W/$_ct_tag.ptxas" "$W/$_ct_tag.fatbin" \
	    "$2" "$3" "$4" "$5" <<'PY'
import json, sys
trace, pt_name, fb_name = sys.argv[1:4]
pt_count = int(sys.argv[4])
arches = sys.argv[5].split(",")
members = int(sys.argv[6])
kinds = sys.argv[7].split(",")
with open(trace, encoding="utf-8") as f:
    records = [json.loads(line) for line in f if line.strip()]
pt = [r for r in records if r.get("tool") == "nvptxas"]
fb = [r for r in records if r.get("tool") == "nvfatbin"]
assert len(records) == len(pt) + len(fb)
assert all(r.get("schema") == 1 and "version" not in r for r in records)
assert len(pt) == pt_count and len(fb) == 1
assert [r["arch"] for r in pt] == arches
assert len(fb[0]["images"]) == members
assert [i["sm"] for i in fb[0]["images"]] == [int(a[3:]) for a in arches for _ in kinds]
assert [i["kind"] for i in fb[0]["images"]] == kinds * len(arches)
assert [i["arch"] for i in fb[0]["images"]] == [a for a in arches for _ in kinds]
assert all(set(i) == {"kind", "sm", "arch", "file"} for i in fb[0]["images"])
for name, selected in ((pt_name, pt), (fb_name, fb)):
    with open(name, "w", encoding="utf-8") as f:
        for record in selected:
            f.write(json.dumps(record, separators=(",", ":")) + "\n")
PY
	rc=$?
	expect_rc "$_ct_tag trace has the expected tools, architectures and image members" $rc 0
	if [ $rc -eq 0 ]; then
		python3 -I "$SRC/tests/libnvrm/schema_validate.py" \
		    "$SCHEMAS/nvptxas-trace-1.schema.json" "$W/$_ct_tag.ptxas" >"$W/$_ct_tag.ptxas.schema" 2>&1
		expect_rc "$_ct_tag ptxas records validate against their schema" $? 0
		python3 -I "$SRC/tests/libnvrm/schema_validate.py" \
		    "$SCHEMAS/nvfatbin-trace-1.schema.json" "$W/$_ct_tag.fatbin" >"$W/$_ct_tag.fatbin.schema" 2>&1
		expect_rc "$_ct_tag fatbinary records validate against their schema" $? 0
	else
		bad "$_ct_tag trace schemas not run after a malformed trace"
		bad "$_ct_tag trace semantic failure also denies schema passes"
	fi
}
check_trace full120 1 sm_120 1 elf
check_trace full121 1 sm_121 1 elf
check_trace fulltwo 2 sm_120,sm_121 2 elf
check_trace fulllegacy 1 sm_120 2 elf,ptx

# Direct tool checks pin the placeholder headers, unchanged payload after the
# separator, both image payloads, exact member metadata and diagnostics.
printf '.target sm_120\n// PTX payload\n.visible .entry ptx_marker() { ret; }\n' >"$W/direct.ptx"
CUDA_NATIVE_TRACE="$W/direct-ptxas.trace" "$SDK/bin/ptxas" -m64 -O3 \
    --gpu-name sm_120 --output-file "$W/direct.o" "$W/direct.ptx" >"$W/direct-ptxas.out" 2>&1
rc=$?
direct_sha=$(/sbin/sha256 -q "$W/direct.ptx")
sed -n '1,4p' "$W/direct.o" >"$W/direct.header" 2>/dev/null
sed '1,4d' "$W/direct.o" >"$W/direct.payload" 2>/dev/null
printf 'CUDA-NATIVE-STUB-CUBIN 1\narch=sm_120\nptx-sha256=%s\n---\n' "$direct_sha" >"$W/direct.expected-header"
[ $rc -eq 0 ] && cmp -s "$W/direct.expected-header" "$W/direct.header" &&
    cmp -s "$W/direct.ptx" "$W/direct.payload" && ! cmp -s "$W/direct.ptx" "$W/direct.o"
expect_rc "ptxas writes its cubin placeholder and preserves the PTX after ---" $? 0
sed 's/^\.target sm_120$/.target sm_120, debug/' "$W/direct.ptx" >"$W/debug-target.ptx"
"$SDK/bin/ptxas" -m64 -g --dont-merge-basicblocks --return-at-end \
    --gpu-name sm_120 --output-file "$W/debug-target.o" "$W/debug-target.ptx" \
    >"$W/debug-target.out" 2>"$W/debug-target.err"
rc=$?
[ $rc -eq 0 ] && grep -qx 'arch=sm_120' "$W/debug-target.o"
expect_rc "ptxas accepts clang's debug options and a .target debug suffix" $? 0
{
	printf '.target sm_120, debug\n'
	printf '.target sm_120\n'
} >"$W/two-targets.ptx"
"$SDK/bin/ptxas" -m64 --gpu-name sm_120 --output-file "$W/two-targets.o" \
    "$W/two-targets.ptx" >"$W/two-targets.out" 2>"$W/two-targets.err"
rc=$?
[ $rc -eq 1 ] && grep -q 'multiple .target lines' "$W/two-targets.err" &&
    [ ! -e "$W/two-targets.o" ]
expect_rc "ptxas counts a suffixed .target when refusing multiple targets" $? 0
sed 's/^\.target sm_120$/.target sm_121/' "$W/direct.ptx" >"$W/mismatch.ptx"
"$SDK/bin/ptxas" -m64 --gpu-name sm_120 --output-file "$W/mismatch.o" "$W/mismatch.ptx" \
    >"$W/mismatch.out" 2>"$W/mismatch.err"
rc=$?
[ $rc -eq 1 ] && grep -q 'sm_120' "$W/mismatch.err" && grep -q 'sm_121' "$W/mismatch.err" &&
    [ ! -e "$W/mismatch.o" ]
expect_rc "ptxas refuses a .target that differs from --gpu-name and names both" $? 0
# A cubin member must be one of our own cubins: a foreign binary is refused
# and never bundled.
printf 'ELF_PAYLOAD\n' >"$W/direct.elf"
"$SDK/bin/fatbinary" -64 --create "$W/foreign.fatbin" \
    --image3=kind=elf,sm=120,file="$W/direct.elf" \
    >"$W/foreign.out" 2>"$W/foreign.err"
rc=$?
[ $rc -eq 1 ] && [ ! -e "$W/foreign.fatbin" ] &&
    grep -q 'not a cuda-native cubin' "$W/foreign.err"
expect_rc "fatbinary refuses a foreign binary instead of bundling it" $? 0
CUDA_NATIVE_TRACE="$W/direct-fatbin.trace" "$SDK/bin/fatbinary" -64 \
    --create "$W/direct.fatbin" --image3=kind=elf,sm=120,file="$W/direct.o" \
    --image3=kind=ptx,sm=120,file="$W/direct.ptx" >"$W/direct-fatbin.out" 2>&1
rc=$?
[ $rc -eq 0 ] && [ -s "$W/direct.fatbin" ]
expect_rc "fatbinary writes a container for the cubin and the PTX" $? 0
"$SDK/bin/cuda-objdump" --json "$W/direct.fatbin" >"$W/direct.json" 2>&1
rc=$?
[ $rc -eq 0 ]
expect_rc "cuda-objdump reads the container fatbinary wrote" $rc 0
python3 -I - "$W/direct.json" "$W/direct.o" "$W/direct.ptx" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    doc = json.load(f)
members = doc["members"]
assert len(members) == 2, members
assert [m["kind"] for m in members] == ["cubin", "ptx"], members
assert [m["arch"] for m in members] == ["sm_120", "sm_120"], members
assert [m["format"] for m in members] == ["nvcubin/1", "ptx"], members
sizes = [len(open(path, "rb").read()) for path in sys.argv[2:]]
assert [m["size"] for m in members] == sizes, (members, sizes)
assert all(len(m["sha256"]) == 64 for m in members), members
PY
expect_rc "the container keeps both members with their sizes and hashes" $? 0
# A trace that cannot be written is a failure after the container is in
# place: the container stays, and the run ends with a diagnostic.
CUDA_NATIVE_TRACE="$W/no-such-directory/trace" "$SDK/bin/nvfatbin" -64 \
    --create "$W/trace-failed.fatbin" \
    --image3=kind=ptx,sm=120,file="$W/direct.ptx" \
    >"$W/trace-failed.out" 2>"$W/trace-failed.err"
rc=$?
[ $rc -eq 1 ] && [ -s "$W/trace-failed.fatbin" ] &&
    grep -q 'cannot append trace' "$W/trace-failed.err"
expect_rc "a trace that cannot be written leaves the container in place" $? 0
"$SDK/bin/cuda-objdump" --extract 0 "$W/direct-extracted.o" "$W/direct.fatbin" \
    >"$W/direct-extract.out" 2>&1
rc=$?
[ $rc -eq 0 ] && cmp -s "$W/direct.o" "$W/direct-extracted.o"
expect_rc "the container gives the cubin member back byte for byte" $? 0
python3 -I - "$CN/fatbin/nvfatbin.c" "$CN/fatbin/cnfatbin.c" <<'PY'
import sys
nvfatbin = open(sys.argv[1], encoding="utf-8").read()
cnfatbin = open(sys.argv[2], encoding="utf-8").read()
# One read per image, and the hash is taken over the bytes that are stored.
assert nvfatbin.count("read_file(images[i].file") == 1, nvfatbin.count("read_file(images[i].file")
assert "cnfatbin_sha256_hex(inputs[i].data, inputs[i].size" in cnfatbin
assert "memcpy(out + members[i].image_offset, inputs[i].data" in cnfatbin
PY
expect_rc "fatbinary reads each image once and hashes the bytes it stores" $? 0
"$SDK/bin/ptxas" --version --json >"$W/ptxas-alias-version.json"
"$SDK/bin/fatbinary" --version --json >"$W/fatbinary-alias-version.json"
python3 -I - "$W/direct-ptxas.trace" "$W/direct-fatbin.trace" \
    "$W/ptxas-alias-version.json" "$W/fatbinary-alias-version.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    pt = [json.loads(line) for line in f if line.strip()]
with open(sys.argv[2], encoding="utf-8") as f:
    fb = [json.loads(line) for line in f if line.strip()]
with open(sys.argv[3], encoding="utf-8") as f:
    pt_version = json.load(f)
with open(sys.argv[4], encoding="utf-8") as f:
    fb_version = json.load(f)
assert len(pt) == 1 and len(fb) == 1
assert pt[0]["tool"] == pt_version["tool"] == "nvptxas"
assert fb[0]["tool"] == fb_version["tool"] == "nvfatbin"
assert pt[0]["schema"] == fb[0]["schema"] == 1
assert "version" not in pt[0] and "version" not in fb[0]
PY
expect_rc "each alias's trace tool matches its version JSON and uses schema 1" $? 0

mkdir "$W/ptxas-output-dir"
"$SDK/bin/ptxas" -m64 --gpu-name sm_120 --output-file "$W/ptxas-output-dir" \
    "$W/direct.ptx" >"$W/ptxas-output-dir.out" 2>"$W/ptxas-output-dir.err"
rc=$?
[ $rc -eq 1 ] && [ -d "$W/ptxas-output-dir" ] &&
    [ -z "$(ls -A "$W/ptxas-output-dir")" ] &&
    grep -q 'output is a directory' "$W/ptxas-output-dir.err"
expect_rc "ptxas refuses an existing-directory output before creating anything" $? 0
mkdir "$W/fatbin-output-dir"
"$SDK/bin/fatbinary" -64 --create "$W/fatbin-output-dir" \
    --image3=kind=elf,sm=120,file="$W/direct.elf" \
    >"$W/fatbin-output-dir.out" 2>"$W/fatbin-output-dir.err"
rc=$?
[ $rc -eq 1 ] && [ -d "$W/fatbin-output-dir" ] &&
    [ -z "$(ls -A "$W/fatbin-output-dir")" ] &&
    grep -q 'output is a directory' "$W/fatbin-output-dir.err"
expect_rc "fatbinary refuses an existing-directory output before creating anything" $? 0

cr_ptx=$W/$(printf 'input\r.ptx')
cp "$W/direct.ptx" "$cr_ptx"
: >"$W/control-ptxas.trace"
CUDA_NATIVE_TRACE="$W/control-ptxas.trace" "$SDK/bin/ptxas" -m64 \
    --gpu-name sm_120 --output-file "$W/control-ptxas.o" "$cr_ptx" \
    >"$W/control-ptxas.out" 2>"$W/control-ptxas.err"
rc=$?
[ $rc -eq 2 ] && [ ! -e "$W/control-ptxas.o" ] &&
    [ ! -s "$W/control-ptxas.trace" ] && grep -q 'control characters' "$W/control-ptxas.err"
expect_rc "ptxas refuses a CR in an input path without tracing it" $? 0
cr_elf=$W/$(printf 'image\r.o')
cp "$W/direct.elf" "$cr_elf"
: >"$W/control-fatbin.trace"
CUDA_NATIVE_TRACE="$W/control-fatbin.trace" "$SDK/bin/fatbinary" -64 \
    --create "$W/control.fatbin" --image3=kind=elf,sm=120,file="$cr_elf" \
    >"$W/control-fatbin.out" 2>"$W/control-fatbin.err"
rc=$?
[ $rc -eq 2 ] && [ ! -e "$W/control.fatbin" ] &&
    [ ! -s "$W/control-fatbin.trace" ] && grep -q 'control characters' "$W/control-fatbin.err"
expect_rc "fatbinary refuses a CR in an image path without tracing it" $? 0

utf8_ptx=$W/rené.ptx
utf8_ptx_output=$W/cubin-é.o
cp "$W/direct.ptx" "$utf8_ptx"
CUDA_NATIVE_TRACE="$W/utf8-ptxas.trace" "$SDK/bin/ptxas" -m64 \
    --gpu-name sm_120 --output-file "$utf8_ptx_output" "$utf8_ptx" \
    >"$W/utf8-ptxas.out" 2>"$W/utf8-ptxas.err"
rc=$?
[ $rc -eq 0 ] && [ -s "$utf8_ptx_output" ]
expect_rc "ptxas accepts valid UTF-8 input and output paths" $? 0
utf8_elf=$W/imagé.o
utf8_fatbin=$W/fatbin-é.fatbin
cp "$W/direct.o" "$utf8_elf"
CUDA_NATIVE_TRACE="$W/utf8-fatbin.trace" "$SDK/bin/fatbinary" -64 \
    --create "$utf8_fatbin" --image3=kind=elf,sm=120,file="$utf8_elf" \
    >"$W/utf8-fatbin.out" 2>"$W/utf8-fatbin.err"
rc=$?
[ $rc -eq 0 ] && [ -s "$utf8_fatbin" ] && [ ! -s "$W/utf8-fatbin.err" ]
expect_rc "fatbinary accepts valid UTF-8 image and output paths" $? 0
python3 -I - "$W/utf8-ptxas.trace" "$W/utf8-fatbin.trace" \
    "$utf8_ptx" "$utf8_ptx_output" "$utf8_elf" "$utf8_fatbin" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    pt = json.loads(f.read())
with open(sys.argv[2], encoding="utf-8") as f:
    fb = json.loads(f.read())
assert pt["input"] == sys.argv[3] and pt["output"] == sys.argv[4]
assert fb["images"][0]["file"] == sys.argv[5] and fb["output"] == sys.argv[6]
PY
expect_rc "JSON parsers recover the exact UTF-8 input and output paths" $? 0

invalid_ptx=$W/$(printf 'input\351.ptx')
cp "$W/direct.ptx" "$invalid_ptx"
: >"$W/invalid-ptxas.trace"
CUDA_NATIVE_TRACE="$W/invalid-ptxas.trace" "$SDK/bin/ptxas" -m64 \
    --gpu-name sm_120 --output-file "$W/invalid-ptxas.o" "$invalid_ptx" \
    >"$W/invalid-ptxas.out" 2>"$W/invalid-ptxas.err"
rc=$?
[ $rc -eq 2 ] && [ ! -e "$W/invalid-ptxas.o" ] &&
    [ ! -s "$W/invalid-ptxas.trace" ] && grep -q 'invalid UTF-8' "$W/invalid-ptxas.err"
expect_rc "ptxas refuses malformed UTF-8 without emitting output or a trace" $? 0
invalid_elf=$W/$(printf 'image\351.o')
cp "$W/direct.elf" "$invalid_elf"
: >"$W/invalid-fatbin.trace"
CUDA_NATIVE_TRACE="$W/invalid-fatbin.trace" "$SDK/bin/fatbinary" -64 \
    --create "$W/invalid.fatbin" --image3=kind=elf,sm=120,file="$invalid_elf" \
    >"$W/invalid-fatbin.out" 2>"$W/invalid-fatbin.err"
rc=$?
[ $rc -eq 2 ] && [ ! -e "$W/invalid.fatbin" ] &&
    [ ! -s "$W/invalid-fatbin.trace" ] && grep -q 'invalid UTF-8' "$W/invalid-fatbin.err"
expect_rc "fatbinary refuses malformed UTF-8 without emitting output or a trace" $? 0

printf 'CUDA-NATIVE-STUB-CUBIN 1\narch=sm_120\n---\n' >"$W/-sabc"
(cd "$W" && "$SDK/bin/fatbinary" -64 --create dash.fatbin \
    --image3=kind=elf,sm=120,file=-sabc) >"$W/dash-image.out" 2>"$W/dash-image.err"
rc=$?
dash_sha=$(cd "$W" && /sbin/sha256 -q -- ./-sabc)
dash_recorded=$("$SDK/bin/cuda-objdump" --json "$W/dash.fatbin" 2>/dev/null |
    python3 -I -c 'import json, sys; print(json.load(sys.stdin)["members"][0]["sha256"])')
[ $rc -eq 0 ] && [ "$dash_recorded" = "$dash_sha" ]
expect_rc "fatbinary hashes a dash-prefixed image as a file, not a sha256 option" $? 0

mkdir "$W/dash-ptx"
# Time: O(number of dash-prefixed fixtures).  Space: O(fixture count).
for dash_input in -sabc -g -O9 --verison --unsupported; do
	cp "$W/direct.ptx" "$W/dash-ptx/$dash_input"
done
dash_index=0
# Time: O(number of accepted dash-prefixed inputs).  Space: O(one output).
for dash_input in -sabc -g -O9; do
	(cd "$W/dash-ptx" && timeout 5 "$SDK/bin/ptxas" -m64 --gpu-name sm_120 \
	    --output-file "dash-$dash_index.o" -- "$dash_input") \
	    >"$W/dash-ptxas-$dash_index.out" 2>"$W/dash-ptxas-$dash_index.err"
	rc=$?
	dash_ptx_sha=$(/sbin/sha256 -q -- "$W/dash-ptx/$dash_input")
	dash_ptx_recorded=$(sed -n '3s/^ptx-sha256=//p' \
	    "$W/dash-ptx/dash-$dash_index.o" 2>/dev/null)
	# Compare bytes too, so an option-looking input cannot pass by name alone.
	sed '1,4d' "$W/dash-ptx/dash-$dash_index.o" \
	    >"$W/dash-ptx/dash-$dash_index.payload" 2>/dev/null
	[ $rc -eq 0 ] && [ "$dash_ptx_recorded" = "$dash_ptx_sha" ] &&
	    cmp -s "$W/direct.ptx" "$W/dash-ptx/dash-$dash_index.payload"
	expect_rc "ptxas -- $dash_input hashes and preserves the intended PTX" $? 0
	dash_index=$((dash_index + 1))
done
# Existing files must never turn unrecognised options into operands.
# Time: O(number of unsupported spellings).  Space: O(1).
for dash_input in -sabc -O9 --verison --unsupported; do
	(cd "$W/dash-ptx" && "$SDK/bin/ptxas" -m64 --gpu-name sm_120 \
	    --output-file refused.o "$dash_input") \
	    >"$W/dash-refused.out" 2>"$W/dash-refused.err"
	rc=$?
	[ $rc -eq 2 ] && [ ! -e "$W/dash-ptx/refused.o" ] &&
	    grep -Fq -- "unsupported option $dash_input" "$W/dash-refused.err"
	expect_rc "an existing $dash_input file does not legitimise an unsupported option" $? 0
done
(cd "$W/dash-ptx" && "$SDK/bin/ptxas" -m64 --gpu-name sm_120 \
    --output-file two-after-delimiter.o -- -g -sabc) \
    >"$W/two-after-delimiter.out" 2>"$W/two-after-delimiter.err"
rc=$?
[ $rc -eq 2 ] && grep -Fq 'only one PTX input is accepted' "$W/two-after-delimiter.err" &&
    [ ! -e "$W/dash-ptx/two-after-delimiter.o" ]
expect_rc "after -- every argument is positional and a second input is refused" $? 0

# An option added only to the validator must not leave a second parser spinning.
cp -R "$CN" "$W/cn-parse-once"
sed -i '' 's/strcmp(arg, "-64") == 0 || strcmp(arg, "-g") == 0/strcmp(arg, "-64") == 0 || strcmp(arg, "-g") == 0 || strcmp(arg, "-v") == 0/' \
    "$W/cn-parse-once/fatbin/nvfatbin.c"
sh "$W/cn-parse-once/mksdk.sh" "$W/sdk-parse-once" >"$W/parse-once-mksdk.log" 2>&1
build_rc=$?
timeout 5 "$W/sdk-parse-once/bin/fatbinary" -64 -v --create "$W/parse-once.fatbin" \
    --image3=kind=elf,sm=120,file="$W/direct.o" \
    >"$W/parse-once.out" 2>"$W/parse-once.err"
rc=$?
[ $build_rc -eq 0 ] && [ $rc -eq 0 ] && [ -s "$W/parse-once.fatbin" ]
expect_rc "fatbinary parses an accepted option once (mutant guarded by timeout 5)" $? 0

"$SDK/bin/ptxas" --unsupported >"$W/ptxas-refuse.out" 2>"$W/ptxas-refuse.err"
rc=$?
[ $rc -eq 2 ] && grep -Fqx 'nvptxas: unsupported option --unsupported; not supported by the cuda-native stub; see nvptxas(1); use -h for usage' "$W/ptxas-refuse.err"
expect_rc "ptxas rejects an unsupported option with rc 2 and its diagnostic" $? 0
"$SDK/bin/fatbinary" --unsupported >"$W/fatbin-refuse.out" 2>"$W/fatbin-refuse.err"
rc=$?
[ $rc -eq 2 ] && grep -Fqx 'fatbinary: unsupported option --unsupported; not supported by the cuda-native stub; see nvfatbin(1); use -h for usage' "$W/fatbin-refuse.err"
expect_rc "fatbinary rejects an unsupported option with rc 2 and its diagnostic" $? 0
"$SDK/bin/nvfatbin" --unsupported >"$W/nvfatbin-refuse.out" 2>"$W/nvfatbin-refuse.err"
rc=$?
[ $rc -eq 2 ] && grep -Fqx 'nvfatbin: unsupported option --unsupported; not supported by the cuda-native stub; see nvfatbin(1); use -h for usage' "$W/nvfatbin-refuse.err"
expect_rc "nvfatbin names itself in its diagnostics" $? 0
(
	CUDA_NATIVE_TOOL=x
	. "$CN/tools/cuda-native-tool-lib.sh"
	unsupported_option -q
) >"$W/third-tool.out" 2>"$W/third-tool.err"
rc=$?
[ $rc -eq 2 ] && [ ! -s "$W/third-tool.out" ] &&
    grep -Fqx 'x: unsupported option -q; not supported by the cuda-native stub; see x(1); use -h for usage' \
    "$W/third-tool.err"
expect_rc "the shared unsupported-option helper names any calling tool" $? 0
"$SDK/bin/ptxas" -m64 --gpu-name sm_120 --output-file "$W/two-inputs.o" \
    "$W/direct.ptx" "$W/direct.ptx" >"$W/two-inputs.out" 2>"$W/two-inputs.err"
rc=$?
[ $rc -eq 2 ] && grep -Fqx "nvptxas: unexpected argument $W/direct.ptx; only one PTX input is accepted" \
    "$W/two-inputs.err" && [ ! -e "$W/two-inputs.o" ]
expect_rc "ptxas reports a second input as an unexpected argument" $? 0
"$SDK/bin/fatbinary" -64 --create "$W/stray.fatbin" stray.o \
    --image3=kind=elf,sm=120,file="$W/direct.elf" >"$W/stray.out" 2>"$W/stray.err"
rc=$?
[ $rc -eq 2 ] && grep -Fqx 'fatbinary: unexpected argument stray.o; images are given with --image3=' \
    "$W/stray.err" && [ ! -e "$W/stray.fatbin" ]
expect_rc "fatbinary reports a stray operand as an unexpected argument" $? 0
grep -Fq 'real assembler is Track #2427' "$CN/man/nvptxas.1"
expect_rc "nvptxas(1), not an error diagnostic, carries the real-assembler track" $? 0
"$SDK/bin/ptxas" -m64 --gpu-name sm_120 "$W/direct.ptx" >/dev/null 2>&1
expect_rc "ptxas requires --output-file" $? 2
"$SDK/bin/fatbinary" -64 --create "$W/refused.fatbin" >/dev/null 2>&1
rc=$?
[ $rc -eq 2 ] && [ ! -e "$W/refused.fatbin" ]
expect_rc "fatbinary requires at least one image and leaves no output" $? 0
"$SDK/bin/fatbinary" -64 --create "$W/missing.fatbin" \
    --image3=kind=elf,sm=120,file="$W/does-not-exist" >/dev/null 2>&1
rc=$?
[ $rc -eq 1 ] && [ ! -e "$W/missing.fatbin" ]
expect_rc "fatbinary fails a missing image read without leaving output" $? 0

# Link through the unversioned symlink, run the host program, and inspect the
# runtime's exports.  The program itself fails if a launch ever claims success.
: >"$W/link.trace"
PATH="$SDK/bin:$PATH" CUDA_NATIVE_TRACE="$W/link.trace" \
    "$CXX" -O2 -Werror -x cuda --cuda-path="$SDK" --cuda-gpu-arch=sm_120 \
    "$K/launch_main.cu" -L"$SDK/lib64" -Wl,-rpath,"$SDK/lib64" -lcudart \
    -fuse-ld=lld -o "$W/launch_main" >"$W/link.log" 2>&1
expect_rc "launch_main: full CUDA compile and link against libcudart" $? 0
"$W/launch_main" >"$W/launch.out" 2>"$W/launch.err"
rc=$?
[ $rc -eq 0 ] && grep -qx 'launch=801' "$W/launch.out" && [ ! -s "$W/launch.err" ]
expect_rc "the linked program runs and every launch reports cudaErrorNotSupported (801)" $? 0
# The same options as the manual's full-link SYNOPSIS, with its placeholders
# replaced by this test's SDK, source and output.
"$CXX" -x cuda --cuda-path="$SDK" --cuda-gpu-arch=sm_120 \
    "$K/launch_main.cu" -L"$SDK/lib64" -lcudart -Wl,-rpath,"$SDK/lib64" \
    -o "$W/synopsis-main" >"$W/synopsis-link.log" 2>&1 &&
    "$W/synopsis-main" >"$W/synopsis-run.out" 2>"$W/synopsis-run.err"
rc=$?
[ $rc -eq 0 ] && grep -qx 'launch=801' "$W/synopsis-run.out" && [ ! -s "$W/synopsis-run.err" ]
expect_rc "a binary linked with the SYNOPSIS options starts and returns launch=801" $? 0
python3 -I - "$CN/man/libcudart-stub.3" "$CN/man/cuda-native-toolchain.7" "$SRC/README.md" <<'PY'
import sys
with open(sys.argv[1], encoding="utf-8") as f:
    runtime = f.read()
with open(sys.argv[2], encoding="utf-8") as f:
    toolchain = f.read()
with open(sys.argv[3], encoding="utf-8") as f:
    readme = f.read()
assert '-Wl,-rpath,"$PWD/obj/cuda-native/lib64"' in runtime
assert '.Fl Wl,-rpath, Ns Qq $PWD/ Ns Ar outdir/lib64' in toolchain
assert '-Wl,-rpath,obj/' not in runtime
assert '.Fl Wl,-rpath, Ns Ar outdir/lib64' not in toolchain
assert '-Wl,-rpath,obj/' not in readme
PY
expect_rc "every documented RUNPATH is absolute" $? 0
python3 -I - "$SRC/README.md" <<'PY'
import sys
from pathlib import Path
rows = [line for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
        if line.startswith("| CUDA, native |")]
assert len(rows) == 1, rows
row = rows[0]
assert "not started" not in row, row
for text in ("in progress", "full compile and link work with stubs",
             "`cudaErrorNotSupported` (801)", "no GPU execution yet", "Track #2362"):
    assert text in row, (text, row)
assert "in progress (" not in row, row
PY
expect_rc "README native CUDA status says in progress without a milestone code" $? 0
mkdir -p "$W/manual-example/obj" "$W/manual-example/elsewhere"
cp -R "$SDK" "$W/manual-example/obj/cuda-native"
(
    cd "$W/manual-example" && "$CXX" -x cuda --cuda-path=obj/cuda-native \
        --cuda-gpu-arch=sm_120 "$K/launch_main.cu" -Lobj/cuda-native/lib64 \
        -Wl,-rpath,"$PWD/obj/cuda-native/lib64" -lcudart -o manual-main
) >"$W/manual-example-link.log" 2>&1 &&
    (cd "$W/manual-example/elsewhere" && "$W/manual-example/manual-main") \
    >"$W/manual-example-run.out" 2>"$W/manual-example-run.err"
rc=$?
"$LLVM/bin/llvm-readelf" -d "$W/manual-example/manual-main" >"$W/manual-example.dynamic" 2>&1
python3 -I - "$W/manual-example.dynamic" <<'PY'
import sys
with open(sys.argv[1], encoding="utf-8") as f:
    lines = [line for line in f if "(RUNPATH)" in line or "(RPATH)" in line]
assert lines
for line in lines:
    path = line.rsplit("[", 1)[1].split("]", 1)[0]
    assert path.startswith("/") or path.startswith("$ORIGIN"), path
PY
check_rc=$?
[ $rc -eq 0 ] && grep -qx 'launch=801' "$W/manual-example-run.out" &&
    [ ! -s "$W/manual-example-run.err" ] && [ $check_rc -eq 0 ]
expect_rc "the absolute-RUNPATH example links and runs from another directory" $? 0
CUDA_NATIVE_STUB_TRACE=1 "$W/launch_main" >"$W/launch-trace.out" 2>"$W/launch-trace.jsonl"
rc=$?
[ $rc -eq 0 ] && grep -qx 'launch=801' "$W/launch-trace.out" && [ -s "$W/launch-trace.jsonl" ]
expect_rc "CUDA_NATIVE_STUB_TRACE=1 keeps the launch result and writes runtime JSONL" $? 0
python3 -I "$SRC/tests/libnvrm/schema_validate.py" \
    "$SCHEMAS/cuda-native-stub-trace-1.schema.json" "$W/launch-trace.jsonl" \
    >"$W/launch-trace.schema" 2>&1
expect_rc "every runtime trace line validates against cuda-native-stub-trace-1" $? 0
CUDA_NATIVE_STUB_TRACE="$W/runtime-path.jsonl" "$W/launch_main" \
    >"$W/runtime-path.out" 2>"$W/runtime-path.err"
rc=$?
[ $rc -eq 0 ] && grep -qx 'launch=801' "$W/runtime-path.out" &&
    [ ! -s "$W/runtime-path.err" ] && [ -s "$W/runtime-path.jsonl" ]
expect_rc "CUDA_NATIVE_STUB_TRACE accepts a path and leaves stderr clean" $? 0
python3 -I "$SRC/tests/libnvrm/schema_validate.py" \
    "$SCHEMAS/cuda-native-stub-trace-1.schema.json" "$W/runtime-path.jsonl" \
    >"$W/runtime-path.schema" 2>&1
expect_rc "runtime JSONL written to a path validates against the trace schema" $? 0
CUDA_NATIVE_STUB_TRACE="$W/no-such-trace-dir/trace.jsonl" "$W/launch_main" \
    >"$W/unwritable-trace.out" 2>"$W/unwritable-trace.err"
rc=$?
[ $rc -eq 0 ] && grep -qx 'launch=801' "$W/unwritable-trace.out" &&
    [ "$(wc -l <"$W/unwritable-trace.err")" -eq 1 ] &&
    grep -Fq 'libcudart-stub: cannot open trace file ' "$W/unwritable-trace.err" &&
    grep -Fq 'tracing is disabled' "$W/unwritable-trace.err" &&
    grep -Fq 'CUDA_NATIVE_STUB_TRACE' "$W/unwritable-trace.err" &&
    grep -Fq 'writable path or unset it' "$W/unwritable-trace.err" &&
    [ ! -e "$W/no-such-trace-dir/trace.jsonl" ]
expect_rc "an unwritable trace states its consequence, variable and recovery once" $? 0

# Interpose issetugid at compile time; no set-id executable or root is needed.
cat >"$W/trace_setid.c" <<'EOF'
/* Copyright (c) 2026 REVYTECH, Inc. */
/* SPDX-License-Identifier: BSD-2-Clause */
#include <unistd.h>
static int
fake_issetugid(void)
{
	return 1;
}
#define issetugid fake_issetugid
#include "cudart_stub.c"
int
main(int argc, char **argv)
{
	FILE *stream;

	if (argc != 2 || fake_issetugid() != 1)
		return 2;
	if (setenv("CUDA_NATIVE_STUB_TRACE", argv[1], 1) != 0)
		return 2;
	stream = trace_open();
	if (stream != NULL) {
		if (stream != stderr)
			fclose(stream);
		return 1;
	}
	return access(argv[1], F_OK) == -1 ? 0 : 1;
}
EOF
"$LLVM/bin/clang" -std=c11 -Wall -Wextra -Werror -I"$CN/libcudart-stub" \
    "$W/trace_setid.c" "$CN/fatbin/cnfatbin.c" -lmd \
    -o "$W/trace_setid" >"$W/trace-setid-build.log" 2>&1 &&
    "$W/trace_setid" "$W/setid-must-not-exist.jsonl" \
    >"$W/trace-setid.out" 2>"$W/trace-setid.err"
rc=$?
[ $rc -eq 0 ] && [ ! -e "$W/setid-must-not-exist.jsonl" ] &&
    [ ! -s "$W/trace-setid.out" ] && [ ! -s "$W/trace-setid.err" ]
expect_rc "an issetugid test hook suppresses CUDA_NATIVE_STUB_TRACE and creates no file" $? 0

# Force only the registration calloc to fail; no resource exhaustion is needed.
cat >"$W/register_oom.c" <<'EOF'
/* Copyright (c) 2026 REVYTECH, Inc. */
/* SPDX-License-Identifier: BSD-2-Clause */
#include <stdlib.h>
#include <string.h>
static void *
fake_calloc(size_t count, size_t size)
{
	(void)count;
	(void)size;
	return NULL;
}
#define calloc fake_calloc
#include "cudart_stub.c"
int
main(void)
{
	static const char ptx[] = ".target sm_120\n";
	struct cnfatbin_input input;
	struct cuda_native_fatbin_wrapper wrapper = {
		CUDA_NATIVE_FATBIN_WRAPPER_MAGIC, 1, NULL, NULL
	};
	uint8_t *buffer = NULL;
	size_t size = 0;

	memset(&input, 0, sizeof(input));
	input.kind = CNFATBIN_KIND_PTX;
	input.sm = 120;
	input.data = (const uint8_t *)ptx;
	input.size = sizeof(ptx) - 1;
	if (cnfatbin_write(&input, 1, &buffer, &size) != CNFATBIN_OK)
		return 1;
	wrapper.data = buffer;
#if defined(CNFATBIN_HAVE_MAPPING_HOOK)
	if (cnfatbin_register_mapping(buffer, size) != 0)
		return 1;
#endif
	return __cudaRegisterFatBinary(&wrapper) == NULL ? 0 : 1;
}
EOF
"$LLVM/bin/clang" -std=c11 -Wall -Wextra -Werror -I"$CN/libcudart-stub" \
    "$W/register_oom.c" "$CN/fatbin/cnfatbin.c" -lmd \
    -o "$W/register_oom" >"$W/register-oom-build.log" 2>&1 &&
    "$W/register_oom" >"$W/register-oom.out" 2>"$W/register-oom.err"
rc=$?
[ $rc -eq 0 ] && [ ! -s "$W/register-oom.out" ] &&
    grep -Fqx 'libcudart-stub: cannot allocate a fatbin registration: host memory exhausted' \
    "$W/register-oom.err" &&
    ! grep -Eq 'freeing|raising|rerunning|rebuild|--cuda-path' "$W/register-oom.err"
expect_rc "a registration allocation failure states only host-memory exhaustion" $? 0
python3 -I - "$W/launch-trace.jsonl" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    records = [json.loads(line) for line in f if line.strip()]
def events(name):
    return [r for r in records if r.get("event") == name]
registered = events("register_fatbin")
functions = events("register_function")
launches = events("launch")
assert len(registered) == 1 and registered[0]["members"] == 1
assert len(functions) == 1 and "vadd" in functions[0]["name"]
assert len(launches) == 2 and all(r["status"] == 801 for r in launches)
assert len(events("register_fatbin_end")) == 1
unregistered = events("unregister_function")
assert len(unregistered) == 1 and "vadd" in unregistered[0]["name"]
assert len(events("unregister_fatbin")) == 1
assert len(records) == 7
PY
expect_rc "runtime trace records one one-member fatbin, vadd, end/unregister and two 801 launches" $? 0
"$LLVM/bin/llvm-readelf" -d "$W/launch_main" >"$W/launch.dynamic" 2>&1
grep -q 'NEEDED.*libcudart.so.13' "$W/launch.dynamic"
expect_rc "the executable needs libcudart.so.13" $? 0
"$LLVM/bin/llvm-nm" -D --defined-only "$SDK/lib64/libcudart.so.13" >"$W/cudart.nm" 2>&1
rc=$?
# Time: O(number of required runtime symbols x nm output).  Space: O(nm output).
for sym in cudaLaunchKernel __cudaPushCallConfiguration __cudaPopCallConfiguration \
    __cudaRegisterFatBinary __cudaRegisterFatBinaryEnd __cudaUnregisterFatBinary \
    __cudaRegisterFunction __cudaRegisterVar __cudaRegisterManagedVar \
    __cudaRegisterSurface __cudaRegisterTexture; do
	grep -Eq "[[:space:]]$sym$" "$W/cudart.nm" || rc=1
done
expect_rc "libcudart exports every launch and registration symbol clang emits" $rc 0

# clang's device image for an -emit-llvm compile is an LLVM IR file, and
# only our own cubins are bundled, so the compile fails.  The real
# fatbinary runs here: a stub would hide the limitation the manual
# documents.
"$CXX" -O0 -g0 -x cuda --cuda-path="$SDK" --cuda-gpu-arch=sm_120 \
    -S -emit-llvm "$K/vector_add.cu" -o "$W/registered.ll" \
    >"$W/registered.log" 2>&1
rc=$?
[ $rc -ne 0 ] && [ ! -e "$W/registered.ll" ] &&
    grep -q 'not a cuda-native cubin' "$W/registered.log" &&
    grep -q 'fatbinary command failed' "$W/registered.log"
expect_rc "the -emit-llvm compile is refused with the named message" $? 0
sed -n 1,3p "$W/registered.log"

# Pin the call graph behind the manual: main calls push then the generated
# device stub; that stub pops the configuration before calling the runtime.
"$CXX" -O0 -g0 -x cuda --cuda-path="$SDK" --cuda-gpu-arch=sm_120 \
    --cuda-host-only -S -emit-llvm "$K/launch_main.cu" -o "$W/launch-order.ll" \
    >"$W/launch-order.log" 2>&1
rc=$?
[ $rc -eq 0 ] && python3 -I - "$W/launch-order.ll" <<'PY'
import re, sys
with open(sys.argv[1], encoding="utf-8") as f:
    ir = f.read()
def body(name):
    match = re.search(r"^define [^\n]*@" + re.escape(name) + r"\([^\n]*\).*?^}", ir, re.M | re.S)
    assert match is not None, name
    return match.group(0)
def calls(text):
    return [name for line in text.splitlines() if " call " in line or line.lstrip().startswith("call ")
            for name in re.findall(r"@([A-Za-z0-9_]+)\(", line)]
main = [name for name in calls(body("main"))
        if name in ("__cudaPushCallConfiguration", "__cudaPopCallConfiguration",
                    "cudaLaunchKernel") or "__device_stub__vadd" in name]
stub_name = next(name for name in main if "__device_stub__vadd" in name)
stub = [name for name in calls(body(stub_name))
        if name in ("__cudaPopCallConfiguration", "cudaLaunchKernel")]
assert main[:2] == ["__cudaPushCallConfiguration", stub_name], main
assert stub == ["__cudaPopCallConfiguration", "cudaLaunchKernel"], stub
PY
expect_rc "IR pins push, generated device stub, pop, then cudaLaunchKernel" $? 0

# A tiny host C program drives both rejected wrapper cases independently, so
# each run must produce exactly one diagnostic and a NULL registration handle.
cat >"$W/bad_fatbin.c" <<'EOF'
/* Copyright (c) 2026 REVYTECH, Inc. */
/* SPDX-License-Identifier: BSD-2-Clause */
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include "cnfatbin.h"
struct wrapper {
	int magic;
	int version;
	const void *data;
	void *unused;
};
extern void **__cudaRegisterFatBinary(void *);
extern int __cudaRegisterFunction(void **, const void *, const char *, const char *, int, void *, void *, void *, void *, void *);
extern void __cudaRegisterFatBinaryEnd(void **);
extern void __cudaUnregisterFatBinary(void **);
static void
put_le16(uint8_t *p, uint16_t value)
{
	int i;

	for (i = 0; i < 2; i++)
		p[i] = (uint8_t)((value >> (8 * i)) & 0xff);
}
static void
put_le32(uint8_t *p, uint32_t value)
{
	int i;

	for (i = 0; i < 4; i++)
		p[i] = (uint8_t)((value >> (8 * i)) & 0xff);
}
static void
put_le64(uint8_t *p, uint64_t value)
{
	int i;

	for (i = 0; i < 8; i++)
		p[i] = (uint8_t)((value >> (8 * i)) & 0xff);
}
/* One container with one PTX member, written by the writer the runtime uses. */
static uint8_t *
good_container(size_t *size)
{
	static const char ptx[] = ".target sm_120\n";
	struct cnfatbin_input input;
	uint8_t *buffer = NULL;

	memset(&input, 0, sizeof(input));
	input.kind = CNFATBIN_KIND_PTX;
	input.sm = 120;
	input.data = (const uint8_t *)ptx;
	input.size = sizeof(ptx) - 1;
	if (cnfatbin_write(&input, 1, &buffer, size) != CNFATBIN_OK)
		return NULL;
	return buffer;
}
/* The size of a page, or zero when the host will not say. */
static size_t
page_size(void)
{
	long value = sysconf(_SC_PAGESIZE);

	return value > 0 ? (size_t)value : 0;
}
/*
 * Two pages, the second one protected, so that a read past the first page
 * faults.  A container of "size" bytes goes at the end of the first page:
 * it ends exactly at the boundary between the pages.
 */
static char *
guarded_mapping(size_t page, size_t size, const void **data)
{
	char *mapping = mmap(NULL, page * 2, PROT_READ | PROT_WRITE,
	    MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);

	if (mapping == MAP_FAILED)
		return NULL;
	if (mprotect(mapping + page, page, PROT_NONE) != 0) {
		munmap(mapping, page * 2);
		return NULL;
	}
	*data = mapping + page - size;
	return mapping;
}
/*
 * Tell the reader where the mapping ends, so that it can bound the reads it
 * makes there.  A container in a mapping of a program's own is in no loaded
 * object, so without this the reader cannot know how far it may read.
 */
static int
register_mapping(void *base, size_t length)
{
#if defined(CNFATBIN_HAVE_MAPPING_HOOK)
	return cnfatbin_register_mapping(base, length);
#else
	(void)base;
	(void)length;
	return 0;
#endif
}
/* A complete container that ends at a protected page boundary. */
static const char *
guard_page_fatbin(void)
{
	size_t size = 0;
	uint8_t *container = good_container(&size);
	size_t page = page_size();
	const void *data;
	char *mapping;

	if (container == NULL || page == 0)
		return NULL;
	if (size > page)
		return NULL;
	mapping = guarded_mapping(page, size, &data);
	if (mapping == NULL)
		return NULL;
	memcpy((void *)data, container, size);
	free(container);
	if (register_mapping(mapping, page) != 0)
		return NULL;
	return data;
}
/*
 * A container header that lies about its length: it claims a megabyte over
 * a hundred bytes that end at a protected page.  A reader that trusts the
 * header reads the string table past the page; a reader that bounds its
 * reads refuses the container.
 */
static const char *
lying_header_fatbin(size_t page)
{
	uint8_t header[100];
	uint8_t *entry;
	const void *data;
	char *mapping;

	mapping = guarded_mapping(page, sizeof(header), &data);
	if (mapping == NULL)
		return NULL;
	memset(header, 0, sizeof(header));
	header[0] = 0x10;
	header[1] = 0xff;
	header[2] = 0x10;
	header[3] = 0xad;
	put_le32(header + 4, 2);		/* the version */
	put_le64(header + 8, 1024 * 1024);	/* the length it claims */
	put_le64(header + 16, 32);		/* the entries table */
	put_le64(header + 24, 1);		/* one entry */
	entry = header + 32;
	put_le16(entry, 5);			/* a PTX image */
	put_le16(entry + 2, 2);		/* a CUDA member */
	put_le64(entry + 8, 1024 * 1024 - 24);	/* the string table */
	put_le64(entry + 16, 1);		/* one string */
	put_le64(entry + 24, 0);		/* no image */
	put_le64(entry + 32, 0);
	memcpy((void *)data, header, sizeof(header));
	if (register_mapping(mapping, page) != 0)
		return NULL;
	return data;
}
/*
 * A header that ends at a protected page and claims sixteen megabytes with
 * one entry: the entry table is the first byte of the protected page.
 */
static const char *
page_header_fatbin(size_t page)
{
	uint8_t header[32];
	const void *data;
	char *mapping;

	mapping = guarded_mapping(page, sizeof(header), &data);
	if (mapping == NULL)
		return NULL;
	memset(header, 0, sizeof(header));
	header[0] = 0x10;
	header[1] = 0xff;
	header[2] = 0x10;
	header[3] = 0xad;
	put_le32(header + 4, 2);
	put_le64(header + 8, 16 * 1024 * 1024);
	put_le64(header + 16, 32);
	put_le64(header + 24, 1);
	memcpy((void *)data, header, sizeof(header));
	if (register_mapping(mapping, page) != 0)
		return NULL;
	return data;
}
/*
 * A container in a mapping of the program's own that the program never
 * registered: the pointer is in no loaded object, so the reader has no
 * bound for it and must refuse it rather than read it.
 */
static const char *
unregistered_fatbin(void)
{
	size_t size = 0;
	uint8_t *container = good_container(&size);
	size_t page = page_size();
	char *mapping;

	if (container == NULL || page == 0 || size > page) {
		free(container);
		return NULL;
	}
	mapping = mmap(NULL, page, PROT_READ | PROT_WRITE,
	    MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (mapping == MAP_FAILED) {
		free(container);
		return NULL;
	}
	memcpy(mapping, container, size);
	free(container);
	return mapping;
}
/*
 * Eight bytes before a protected page: not even a whole header fits there,
 * and the length in the header is not there to be read either.
 */
static const char *
short_mapping_fatbin(size_t page)
{
	uint8_t header[8];
	const void *data;
	char *mapping;

	mapping = guarded_mapping(page, sizeof(header), &data);
	if (mapping == NULL)
		return NULL;
	memset(header, 0, sizeof(header));
	header[0] = 0x10;
	header[1] = 0xff;
	header[2] = 0x10;
	header[3] = 0xad;
	memcpy((void *)data, header, sizeof(header));
	if (register_mapping(mapping, page) != 0)
		return NULL;
	return data;
}
int
main(int argc, char **argv)
{
	struct wrapper wrapper = { 0x466243b1, 1, NULL, NULL };
	uint8_t *container = NULL;
	size_t size = 0;
	void **handle;

	if (argc != 2)
		return 2;
	if (strcmp(argv[1], "null-data") == 0)
		wrapper.data = NULL;
	else if (strcmp(argv[1], "guard-page") == 0)
		wrapper.data = guard_page_fatbin();
	else if (strcmp(argv[1], "lying-header") == 0)
		wrapper.data = lying_header_fatbin(page_size());
	else if (strcmp(argv[1], "page-header") == 0)
		wrapper.data = page_header_fatbin(page_size());
	else if (strcmp(argv[1], "short-mapping") == 0)
		wrapper.data = short_mapping_fatbin(page_size());
	else if (strcmp(argv[1], "unregistered") == 0)
		wrapper.data = unregistered_fatbin();
	else if (strcmp(argv[1], "bad-magic") == 0 ||
	    strcmp(argv[1], "bad-data") == 0 ||
	    strcmp(argv[1], "bad-header") == 0 ||
	    strcmp(argv[1], "bad-member") == 0 ||
	    strcmp(argv[1], "too-many-members") == 0 ||
	    strcmp(argv[1], "oversized-header") == 0 ||
	    strcmp(argv[1], "short-size") == 0) {
		container = good_container(&size);
		if (container == NULL)
			return 2;
		if (strcmp(argv[1], "bad-magic") == 0)
			wrapper.magic = 0;
		else if (strcmp(argv[1], "bad-data") == 0)
			container[1] ^= 0xff;
		else if (strcmp(argv[1], "bad-header") == 0)
			put_le32(container + 4, 3);
		else if (strcmp(argv[1], "bad-member") == 0)
			container[32] = 1;
		else if (strcmp(argv[1], "too-many-members") == 0)
			put_le64(container + 24, 5000);
		else if (strcmp(argv[1], "oversized-header") == 0)
			put_le64(container + 8, UINT64_C(1) << 40);
		else
			put_le64(container + 8, 0);
		wrapper.data = container;
		if (register_mapping(container, size) != 0)
			return 2;
	} else
		return 2;
	if (wrapper.data == NULL && strcmp(argv[1], "null-data") != 0)
		return 2;
	handle = __cudaRegisterFatBinary(&wrapper);
	if (strcmp(argv[1], "guard-page") == 0) {
		if (handle == NULL)
			return 1;
		__cudaUnregisterFatBinary(handle);
		return 0;
	}
	if (handle == NULL && getenv("CUDA_NATIVE_STUB_TRACE") != NULL) {
		int refused = __cudaRegisterFunction(NULL, NULL, NULL, "orphan", 0,
		    NULL, NULL, NULL, NULL, NULL);
		__cudaRegisterFatBinaryEnd(NULL);
		__cudaUnregisterFatBinary(NULL);
		free(container);
		return refused != 0 ? 0 : 1;
	}
	free(container);
	return handle == NULL ? 0 : 1;
}
EOF
"$LLVM/bin/clang" -std=c11 -Wall -Wextra -Werror -I"$CN/fatbin" \
    "$W/bad_fatbin.c" \
    -L"$SDK/lib64" -Wl,-rpath,"$SDK/lib64" -lcudart -o "$W/bad_fatbin" \
    >"$W/bad-fatbin-build.out" 2>&1
expect_rc "the bad-fatbin refusal fixture links against libcudart-stub" $? 0
# Time: O(number of bad wrapper cases).  Space: O(one diagnostic).
for case_name in bad-magic bad-data bad-header bad-member null-data too-many-members oversized-header short-size lying-header page-header short-mapping unregistered; do
	expected_reason=
	case $case_name in
	bad-data) expected_reason='invalid cuda-native fatbin data magic' ;;
	bad-header) expected_reason='unknown container version' ;;
	bad-member) expected_reason='a member has an image kind other than PTX, cubin or none' ;;
	too-many-members) expected_reason='too many entries in the container' ;;
	oversized-header) expected_reason='cuda-native fatbin is larger than the limit' ;;
	short-size) expected_reason='cuda-native fatbin is shorter than its header' ;;
	lying-header) expected_reason='container size is larger than the input' ;;
	page-header) expected_reason='container size is larger than the input' ;;
	short-mapping) expected_reason='cuda-native fatbin is shorter than its header' ;;
	unregistered) expected_reason='cuda-native fatbin data is not inside a loaded object' ;;
	esac
	(ulimit -c 0; "$W/bad_fatbin" "$case_name") >"$W/$case_name.out" 2>"$W/$case_name.err"
	rc=$?
	[ $rc -eq 0 ] && [ ! -s "$W/$case_name.out" ] &&
	    [ "$(wc -l <"$W/$case_name.err")" -eq 1 ] &&
	    grep -q '^libcudart-stub: ' "$W/$case_name.err" &&
	    grep -q 'rebuild' "$W/$case_name.err" &&
	    grep -Fq -- '--cuda-path=' "$W/$case_name.err"
	check_rc=$?
	if [ -n "$expected_reason" ] && ! grep -Fq "$expected_reason" "$W/$case_name.err"; then
		check_rc=1
	fi
	expect_rc "__cudaRegisterFatBinary refuses $case_name with NULL and one stderr line" $check_rc 0
done

# A complete fatbin ends at a protected page boundary.  No scan may look for a
# terminator in the NUL-free payload or beyond the final payload byte.
(ulimit -c 0; "$W/bad_fatbin" guard-page) \
    >"$W/guard-page.out" 2>"$W/guard-page.err"
rc=$?
[ $rc -eq 0 ] && [ ! -s "$W/guard-page.out" ] && [ ! -s "$W/guard-page.err" ]
expect_rc "a valid fatbin ending at a guard page registers without an overread" $? 0

# The bound is what keeps the stub from reading past the bytes the pointer
# names.  A stub that takes the length in the header for a bound reads the
# string table of the lying header out of the protected page and dies on the
# signal; the stub with the bound refuses it and lives.  Without this the
# guard-page case above would pass on a stub that reads out of bounds.
cp -R "$CN" "$W/cn-unbounded"
sed -i '' 's/bound = cnfatbin_bound(data);/bound = CNFATBIN_MAX_SIZE;/' \
    "$W/cn-unbounded/libcudart-stub/cudart_stub.c"
"$LLVM/bin/clang" -std=c11 -Wall -Wextra -Werror -I"$W/cn-unbounded/fatbin" \
    -I"$W/cn-unbounded/libcudart-stub" "$W/bad_fatbin.c" \
    "$W/cn-unbounded/libcudart-stub/cudart_stub.c" \
    "$W/cn-unbounded/fatbin/cnfatbin.c" -lmd \
    -o "$W/bad_fatbin-unbounded" >"$W/unbounded-build.log" 2>&1
unbounded_build=$?
unbounded_rc=99
if [ $unbounded_build -eq 0 ]; then
	(ulimit -c 0; "$W/bad_fatbin-unbounded" lying-header) \
	    >"$W/unbounded.out" 2>"$W/unbounded.err"
	unbounded_rc=$?
fi
# The unbounded stub reads past the mapping and dies on the signal; it never
# reaches the refusal.  A bound that is only advisory is not a bound.
[ $unbounded_build -eq 0 ] && [ $unbounded_rc -ge 128 ]
expect_rc "mutant: a stub that trusts the header length reads out of bounds and dies" $? 0

# The stub must find the bound in the loaded object that holds the pointer,
# not in the container's own header.  A stub that reads the bound out of the
# header accepts the lying header; the real one refuses it.
grep -q 'bound = cnfatbin_bound(data);' "$CN/libcudart-stub/cudart_stub.c" &&
    ! grep -q 'bound = cnfatbin_bound(data);' \
        "$W/cn-unbounded/libcudart-stub/cudart_stub.c"
expect_rc "the stub takes its bound from the object, not from the header" $? 0

# A reader that accepts a container it must refuse must be caught.  Change the
# reader's own limit check without changing its call site: the old default
# branch accepts it, while the reader refuses it.
cp -R "$CN" "$W/cn-extra-header-error"
awk '
/if \(entries_count > CNFATBIN_MAX_ENTRIES\)/ {
	print
	getline
	sub(/return .*;/, "return CNFATBIN_OK;")
	print
	next
}
{ print }
' "$W/cn-extra-header-error/fatbin/cnfatbin.c" \
    >"$W/cn-extra-header-error/cnfatbin.c.new" &&
    mv "$W/cn-extra-header-error/cnfatbin.c.new" \
    "$W/cn-extra-header-error/fatbin/cnfatbin.c"
sh "$W/cn-extra-header-error/mksdk.sh" "$W/sdk-extra-header-error" \
    >"$W/extra-header-error-mksdk.log" 2>&1
build_rc=$?
if [ $build_rc -eq 0 ]; then
	"$LLVM/bin/clang" -std=c11 -Wall -Wextra -Werror -I"$CN/fatbin" \
	    "$W/bad_fatbin.c" \
	    -L"$W/sdk-extra-header-error/lib64" \
	    -Wl,-rpath,"$W/sdk-extra-header-error/lib64" -lcudart \
	    -o "$W/bad_fatbin-extra-error" >"$W/extra-header-error-build.log" 2>&1
	build_rc=$?
fi
if [ $build_rc -eq 0 ]; then
	"$W/bad_fatbin-extra-error" too-many-members \
	    >"$W/extra-header-error.out" 2>"$W/extra-header-error.err"
	rc=$?
else
	rc=99
fi
# The mutant accepts the container, so the case no longer refuses it.
[ $build_rc -eq 0 ] && [ $rc -ne 0 ] && [ ! -s "$W/extra-header-error.err" ]
expect_rc "mutant: a reader that accepts too many entries is caught" $? 0
# The two limits have distinct reasons in the machine-readable refusal too.
# Time: O(two traces).  Space: O(one trace).
for case_name in too-many-members oversized-header; do
	case $case_name in
	too-many-members) expected_reason='too many entries in the container' ;;
	oversized-header) expected_reason='cuda-native fatbin is larger than the limit' ;;
	esac
	CUDA_NATIVE_STUB_TRACE=1 "$W/bad_fatbin" "$case_name" \
	    >"$W/$case_name-trace.out" 2>"$W/$case_name-trace.err"
	rc=$?
	[ $rc -eq 0 ] && grep -Fq "\"reason\":\"$expected_reason\"" "$W/$case_name-trace.err"
	expect_rc "$case_name refusal trace names its specific limit" $? 0
done
CUDA_NATIVE_STUB_TRACE=1 "$W/bad_fatbin" bad-data >"$W/refused-trace.out" 2>"$W/refused-trace.err"
rc=$?
grep '^{' "$W/refused-trace.err" >"$W/refused-trace.jsonl"
[ $rc -eq 0 ] && grep -q '^libcudart-stub: ' "$W/refused-trace.err" &&
    python3 -I - "$W/refused-trace.jsonl" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    records = [json.loads(line) for line in f if line.strip()]
assert len(records) == 4
assert records[0]["event"] == "register_fatbin"
assert records[0]["refused"] is True and records[0]["reason"]
assert "members" not in records[0]
assert records[1]["event"] == "register_function" and records[1]["handle"] is None
assert records[1]["name"] == "orphan"
assert records[2] == {"event": "register_fatbin_end", "handle": None}
assert records[3] == {"event": "unregister_fatbin", "handle": None}
PY
expect_rc "a refused fatbin and its later NULL-handle calls have distinct trace records" $? 0
python3 -I "$SRC/tests/libnvrm/schema_validate.py" \
    "$SCHEMAS/cuda-native-stub-trace-1.schema.json" "$W/refused-trace.jsonl" \
    >"$W/refused-trace.schema" 2>&1
expect_rc "refused and NULL-handle runtime records validate against the trace schema" $? 0

# Reordering the handle away from offset zero must break the stub build.
cp -R "$CN" "$W/cn-handle-order"
sed -i '' '/^[[:space:]]*void \*handle;$/d' "$W/cn-handle-order/libcudart-stub/cudart_stub.c"
sed -i '' '/^[[:space:]]*char \*\*kernel_names;$/i\
	void *handle;
' "$W/cn-handle-order/libcudart-stub/cudart_stub.c"
sh "$W/cn-handle-order/mksdk.sh" "$W/sdk-handle-order" >"$W/handle-order.log" 2>&1
rc=$?
[ $rc -ne 0 ] && grep -q 'handle must be first' "$W/handle-order.log"
expect_rc "mutant: moving the fatbin handle away from offset zero fails the build" $? 0

# Registration storage must be observable or needed to release other storage;
# fields that are only assigned give callers and tests a false impression.
python3 -I - "$CN/libcudart-stub/cudart_stub.c" <<'PY'
import sys
with open(sys.argv[1], encoding="utf-8") as f:
    source = f.read()
record = source.split("struct cuda_native_fatbin_record {", 1)[1].split("};", 1)[0]
assert "size_t members;" not in record
for dead in ("wrapper_version", "variables", "managed_variables", "surfaces",
             "textures", "ended", "last_error"):
    assert dead not in source, dead
PY
expect_rc "the runtime retains no write-only registration or last-error state" $? 0
! grep -Eq 'retained as the last error|per-fatbin counts|wrapper version|marks the record complete' \
    "$CN/man/libcudart-stub.3"
expect_rc "the runtime manual does not promise write-only state" $? 0

# Required mutants: a tool that silently produces no output must stop clang;
# a runtime that claims a successful launch must make launch_main fail.
M=$(mutant nooutput) || finish
printf '#!/bin/sh\nexit 0\n' >"$M/bin/ptxas"
chmod +x "$M/bin/ptxas"
PATH="$M/bin:$PATH" "$CXX" -x cuda --cuda-path="$M" --cuda-gpu-arch=sm_120 \
    -c "$K/vector_add.cu" -o "$W/m-nooutput.o" >"$W/m-nooutput.log" 2>&1
rc=$?
[ $rc -ne 0 ] && [ ! -e "$W/m-nooutput.o" ]
expect_rc "mutant: ptxas exiting 0 without output cannot produce a host object" $? 0

cp -R "$CN" "$W/cn-launch0"
sed -i '' 's/return CUDA_NATIVE_ERROR_NOT_SUPPORTED;/return 0;/' "$W/cn-launch0/libcudart-stub/cudart_stub.c"
launch0_run=99
if sh "$W/cn-launch0/mksdk.sh" "$W/sdk-launch0" >"$W/launch0-mksdk.log" 2>&1; then
	if PATH="$W/sdk-launch0/bin:$PATH" "$CXX" -x cuda --cuda-path="$W/sdk-launch0" \
	    --cuda-gpu-arch=sm_120 "$K/launch_main.cu" -L"$W/sdk-launch0/lib64" \
	    -Wl,-rpath,"$W/sdk-launch0/lib64" -lcudart -fuse-ld=lld \
	    -o "$W/launch0" >"$W/launch0.log" 2>&1; then
		"$W/launch0" >"$W/launch0.out" 2>&1
		launch0_run=$?
	fi
fi
[ $launch0_run -eq 1 ] && grep -qx 'launch=0' "$W/launch0.out"
expect_rc "mutant: changing the launch result to success is caught by the run test" $? 0

# All three new manual pages, including the runtime ABI caveats, stay clean.
# Time: O(number of new man pages).  Space: O(lint output).
for man in nvptxas.1 nvfatbin.1 nvfatbin.5 cuda-objdump.1 libcudart-stub.3; do
	mandoc -T lint -W warning "$CN/man/$man" >"$W/$man.mandoc" 2>&1
	rc=$?
	[ $rc -eq 0 ] && [ ! -s "$W/$man.mandoc" ]
	expect_rc "$man is mandoc -T lint -W warning clean" $? 0
done
! grep -Eq '^\.(Dt CUDART-STUB|Nm cudart-stub|Xr cudart-stub)' "$CN"/man/*.1 \
    "$CN"/man/*.3 "$CN"/man/cuda-native-toolchain.7
expect_rc "manual names and SEE ALSO references use libcudart-stub, never cudart-stub" $? 0

finish
