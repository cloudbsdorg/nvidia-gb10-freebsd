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
# Every check prints "ok" or "FAIL".  Exit status: the number of failures
# (at most 96), 77 when LLVM 23 is missing (the checks that need it were
# skipped; the others ran), 99 when the setup failed (no fresh copy).
# Run: sh tests/cuda_native_toolchain_test.sh
# Env: LLVM (default /usr/local/llvm23), TMPDIR (scratch, default /tmp).

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$HERE/.." && pwd)
LLVM=${LLVM:-/usr/local/llvm23}
export LLVM
CXX=$LLVM/bin/clang++

W=$(mktemp -d "${TMPDIR:-/tmp}/cuda-native-test.XXXXXXXX") || exit 99
trap 'rm -rf "$W"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
# expect_rc NAME RC WANT: rc captured by the caller on its own line before.
expect_rc() {
	if [ "$2" -eq "$3" ]; then ok "$1"; else bad "$1 (rc=$2, want $3)"; fi
}
finish() {
	printf '%d passed, %d failed\n' "$PASS" "$FAIL"
	[ "$FAIL" -le 96 ] || FAIL=96
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
	printf '%d passed, %d failed\n' "$PASS" "$FAIL"
	exit 99
fi
CN=$SRC/lib/cuda-native
K=$SRC/tests/cuda-native

# ---- provenance (no LLVM needed) -----------------------------------------
# provenance DIR: print each file under DIR that lacks our BSD-2 header (all
# but this test's own fixtures), names NVIDIA Corporation, or carries a
# copyright line other than ours.  Exit 0 when nothing is printed, 1 when
# something is, 2 when a file could not be read.
# Time: O(total size of DIR).  Space: O(files).
provenance() {
	find "$1" -type f | sort >"$W/prov.files" || return 2
	: >"$W/prov.out"
	while IFS= read -r f; do
		[ -r "$f" ] || return 2
		grep -q 'SPDX-License-Identifier: BSD-2-Clause' "$f" &&
		    grep -q 'Copyright (c) 2026 REVYTECH, Inc\.' "$f" ||
		    echo "no REVYTECH BSD-2 header: ${f#$SRC/}" >>"$W/prov.out"
		grep -Eiq 'nvidia[[:space:]]+corp' "$f" &&
		    echo "names NVIDIA Corporation: ${f#$SRC/}" >>"$W/prov.out"
		grep -Ei 'copyright|\(c\)|©' "$f" |
		    grep -v 'Copyright (c) 2026 REVYTECH, Inc\.' >"$W/prov.line"
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
grep -q 'SPDX-License-Identifier: BSD-2-Clause' "$SRC/tests/cuda_native_toolchain_test.sh" &&
    grep -q 'Copyright (c) 2026 REVYTECH, Inc\.' "$SRC/tests/cuda_native_toolchain_test.sh"
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

# ---- man page (no LLVM needed) ---------------------------------------------
MAN=$CN/man/cuda-native-toolchain.7
mandoc -T lint -W warning "$MAN" >"$W/mandoc.out" 2>&1
rc=$?
[ $rc -eq 0 ] && [ ! -s "$W/mandoc.out" ]
expect_rc "cuda-native-toolchain.7 is mandoc -T lint -W warning clean" $? 0
[ -s "$W/mandoc.out" ] && sed -n 1,10p "$W/mandoc.out"

# ---- the rest needs LLVM 23 ------------------------------------------------
if [ ! -x "$CXX" ]; then
	echo "skip: no $CXX (pkg install llvm23); the checks below did not run"
	printf '%d passed, %d failed\n' "$PASS" "$FAIL"
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
LLVM=$W/nollvm sh "$CN/mksdk.sh" "$W/sdk-nollvm" >/dev/null 2>&1
expect_rc "mksdk.sh refuses when the LLVM tools are missing" $? 2
mkdir "$W/sdk-empty"
sh "$CN/mksdk.sh" "$W/sdk-empty" >/dev/null 2>&1
rc=$?
[ $rc -eq 0 ] && [ -f "$W/sdk-empty/include/cuda.h" ]
expect_rc "mksdk.sh fills an existing empty directory" $? 0

# Fake LLVM installs: an old clang, and a clang 23 that gives no data layout.
mkdir -p "$W/llvm19/bin" "$W/llvmbad/bin"
printf '#!/bin/sh\necho "clang version 19.1.7"\n' >"$W/llvm19/bin/clang"
printf '#!/bin/sh\ncase "$1" in --version) echo "clang version 23.1.5";; esac\nexit 0\n' \
    >"$W/llvmbad/bin/clang"
ln -s "$LLVM/bin/llvm-as" "$W/llvm19/bin/llvm-as"
ln -s "$LLVM/bin/llvm-as" "$W/llvmbad/bin/llvm-as"
chmod +x "$W/llvm19/bin/clang" "$W/llvmbad/bin/clang"
LLVM=$W/llvm19 sh "$CN/mksdk.sh" "$W/sdk-old" >/dev/null 2>&1
rc=$?
[ $rc -eq 2 ] && [ ! -e "$W/sdk-old" ]
expect_rc "mksdk.sh refuses a clang older than 23" $? 0
mkdir "$W/sdk-fail"
LLVM=$W/llvmbad sh "$CN/mksdk.sh" "$W/sdk-fail" >/dev/null 2>&1
rc=$?
[ $rc -eq 1 ] && [ -z "$(ls -A "$W/sdk-fail")" ] &&
    [ -z "$(find "$W" -maxdepth 1 -name '.mksdk.*')" ]
expect_rc "a failed mksdk.sh run leaves the output directory empty" $? 0
sh "$CN/mksdk.sh" "$W/sdk-fail" >/dev/null 2>&1
expect_rc "the same directory builds on the next run" $? 0

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

# Every header of the tree is one clang includes: no dead stub, none missing.
# Time: O(headers).  Space: O(headers).
(cd "$SDK/include" && find . -type f | sed 's#^\./##' | sort) >"$W/have.txt"
"$CXX" -x cuda --cuda-path="$SDK" --cuda-gpu-arch=sm_120 --cuda-device-only \
    -M "$K/builtins.cu" >"$W/dep-dev.txt" 2>&1
"$CXX" -x cuda --cuda-path="$SDK" --cuda-gpu-arch=sm_120 --cuda-host-only \
    -M "$K/builtins.cu" >"$W/dep-host.txt" 2>&1
tr ' \\' '\n\n' <"$W/dep-dev.txt" | cat - "$W/dep-host.txt" | tr ' \\' '\n\n' |
    sed -n "s#^$SDK/include/##p" | sort -u >"$W/used.txt"
cmp -s "$W/have.txt" "$W/used.txt"
rc=$?
expect_rc "clang includes exactly the headers of the tree" $rc 0
[ $rc -eq 0 ] || diff "$W/have.txt" "$W/used.txt" | sed -n 1,10p

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

# An empty __global__ makes vadd an ordinary function: no kernel entry.
M=$(mutant noglobal) || finish
sed -i '' 's/^#define __global__ .*/#define __global__/' "$M/include/host_defines.h"
devptx "$M" sm_120 "$K/vector_add.cu" "$W/m-noglobal.ptx"
rc=$?
if [ $rc -ne 0 ] || ! grep -q '\.entry _Z4vaddPKfS0_Pfi' "$W/m-noglobal.ptx"; then
	ok "mutant: an empty __global__ loses the vadd kernel"
else
	bad "mutant: an empty __global__ loses the vadd kernel"
fi

# A dead stub (a header clang never includes) must fail the include check.
M=$(mutant deadstub) || finish
cp "$M/include/host_config.h" "$M/include/never_included.h"
(cd "$M/include" && find . -type f | sed 's#^\./##' | sort) >"$W/have-m.txt"
cmp -s "$W/have-m.txt" "$W/used.txt"
rc=$?
[ $rc -ne 0 ]
expect_rc "mutant: an extra header that clang never includes is noticed" $? 0

finish
