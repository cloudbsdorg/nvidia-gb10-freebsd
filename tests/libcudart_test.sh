#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# Native CUDA C1.5 (Track #2430): the runtime in lib/libcudart on the fake
# backend of libcuda.  Build and test a FRESH COPY OF THE INDEX, never the
# working tree.  Stage every new file and every edit before running.
# TMPDIR must name an existing scratch directory; never use the system /tmp.

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$HERE/.." && pwd)
: "${TMPDIR:?set TMPDIR to the assigned scratch directory}"
case $TMPDIR in
/*) ;;
*) echo "libcudart_test: TMPDIR must be absolute" >&2; exit 99 ;;
esac
W=$(mktemp -d "$TMPDIR/libcudart-test.XXXXXXXX") || exit 99
trap 'rm -rf "$W"' EXIT INT TERM
unset CUDA_NATIVE_BACKEND CUDA_NATIVE_FAKE_PROFILE CUDA_VISIBLE_DEVICES
unset CUDA_NATIVE_FAKE_ENUM_DELAY_MS CUDA_NATIVE_FAKE_UUID_ERROR
unset CUDA_NATIVE_FAKE_UNSUPPORTED_COOPERATIVE

PASS=0
FAIL=0
SKIP=0
ok() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
skip() { SKIP=$((SKIP + 1)); printf 'skip %s\n' "$1"; }
expect_rc() {
	if [ "$2" -eq "$3" ]; then ok "$1"; else bad "$1 (rc=$2, want $3)"; fi
}
run_case() {	# run_case NAME COMMAND [ARG ...]; retain output in the transcript
	_name=$1
	shift
	"$@" >"$W/case.out" 2>&1
	_rc=$?
	cat "$W/case.out"
	expect_rc "$_name" "$_rc" 0
}
map_exports() {	# map_exports VERSION_MAP; one exported symbol per line
	awk '/^CUDART_1\.0 \{/{inside=1;next} /^\};/{inside=0}
	    inside && $1 ~ /^[A-Za-z_][A-Za-z0-9_]*;$/ { sub(/;$/, "", $1); print $1 }' "$1"
}

# ---- fresh copy and base toolchain ---------------------------------------
SRC=$W/src
mkdir -p "$SRC"
git -C "$REPO" checkout-index -a --prefix="$SRC/" >"$W/checkout.log" 2>&1
rc=$?
expect_rc "fresh copy of the staged tree" "$rc" 0
[ -f "$SRC/lib/libcudart/cudart_device.c" ] && [ -f "$SRC/tests/libcudart/api_test.c" ] &&
    [ -f "$SRC/tests/libcudart_test.sh" ] && [ -f "$SRC/lib/libcudart/man/libcudart.3" ]
rc=$?
expect_rc "the staged copy contains the runtime, its tests and its manual" "$rc" 0
[ "$rc" -eq 0 ] || { cat "$W/checkout.log"; exit 98; }
L=$SRC/lib/libcudart
T=$SRC/tests/libcudart
SDKINC=$SRC/lib/cuda-native/sdk/include
CN=$SRC/lib/cuda-native

ld --version 2>&1 | grep -q LLD
rc=$?
expect_rc "base linker is LLD" "$rc" 0

# ---- the libraries build --------------------------------------------------
O=$W/obj
mkdir -p "$O/libcuda" "$O/libcudart" "$W/bin"
(cd "$SRC/lib/libcuda" && MAKEOBJDIR="$O/libcuda" make CUDA_NATIVE_TESTING=yes) \
    >"$W/build-libcuda.log" 2>&1
rc=$?
expect_rc "libcuda builds with BSD make and -Werror" "$rc" 0
[ "$rc" -eq 0 ] || sed -n '1,60p' "$W/build-libcuda.log"
(cd "$L" && MAKEOBJDIR="$O/libcudart" LIBCUDA_OBJ="$O/libcuda" make) \
    >"$W/build-libcudart.log" 2>&1
rc=$?
expect_rc "libcudart builds with BSD make and -Werror" "$rc" 0
[ "$rc" -eq 0 ] || sed -n '1,60p' "$W/build-libcudart.log"
LIB=$O/libcudart/libcudart-native.so.13
export LD_LIBRARY_PATH=$O/libcudart:$O/libcuda

if [ -f "$LIB" ]; then
	readelf -p .comment "$LIB" >"$W/cudart-comment.out" 2>"$W/cudart-comment.err"
	rc=$?
else
	rc=1
fi
expect_rc "readelf can inspect libcudart-native.so.13" "$rc" 0
grep -q 'Linker: LLD' "$W/cudart-comment.out" 2>/dev/null
rc=$?
expect_rc "libcudart-native.so.13 was linked by LLD" "$rc" 0
readelf -d "$LIB" >"$W/cudart-dynamic.out" 2>&1
awk '/NEEDED/ { gsub(/[][]/, "", $NF); print $NF }' "$W/cudart-dynamic.out" |
    sort >"$W/needed.actual"
printf '%s\n' libc.so.7 libcuda.so.1 libthr.so.3 | sort >"$W/needed.expected"
cmp -s "$W/needed.actual" "$W/needed.expected"
rc=$?
expect_rc "the runtime needs only libc, libcuda and libthr" "$rc" 0
readelf -d "$LIB" 2>/dev/null | grep -Eqi 'linux|nvidia' &&
    bad "the runtime has no Linux or NVIDIA binary dependency" ||
    ok "the runtime has no Linux or NVIDIA binary dependency"

# The soname of the runtime is not the soname of the SDK stub: a program
# that links against one must never load the other.
readelf -d "$LIB" 2>/dev/null | grep -q 'SONAME.*libcudart-native.so.13'
rc=$?
expect_rc "the runtime has the soname libcudart-native.so.13" "$rc" 0
[ -L "$O/libcudart/libcudart.so" ]
rc=$?
expect_rc "the runtime directory holds the libcudart.so link" "$rc" 0

# The exported names are the ones of the version map, and nothing else.
map_exports "$L/Version.map" | sort >"$W/exports.expected"
nm -D --defined-only "$LIB" 2>/dev/null |
    awk 'NF >= 3 { sub(/@@.*/, "", $3); print $3 }' | sort >"$W/exports.actual"
cmp -s "$W/exports.actual" "$W/exports.expected"
rc=$?
expect_rc "the dynamic exports match the version map exactly" "$rc" 0
if nm -D --defined-only "$LIB" 2>/dev/null |
    awk 'NF >= 3 && $3 !~ /@@CUDART_1.0$/ { n++ } END { exit n + 0 }'; then
	ok "every defined dynamic symbol carries CUDART_1.0"
else
	bad "every defined dynamic symbol carries CUDART_1.0"
fi
# The version map must name every entry point the header declares: a
# declaration without an export is a link error in a program that uses it.
grep -o '[A-Za-z_][A-Za-z0-9_]*(' "$SDKINC/cuda_runtime_api.h" |
    sed 's/(//' | grep -E '^(_*cuda[A-Za-z0-9_]*)$' | sort -u >"$W/header-all"
missing=
while read -r _name; do
	[ -n "$_name" ] || continue
	grep -qx "$_name" "$W/exports.expected" || missing="$missing $_name"
done <"$W/header-all"
[ -z "$missing" ]
rc=$?
expect_rc "every entry point the header declares is exported${missing:+ (missing:$missing)}" "$rc" 0

# Every entry point the library exports is called by the API test: an
# entry point nobody calls is an entry point nobody proved.
grep -o '[A-Za-z_][A-Za-z0-9_]*(' "$T/api_test.c" |
    sed 's/(//' | grep -E '^(_*cuda[A-Za-z0-9_]*)$' | sort -u >"$W/test-calls"
untested=
while read -r _name; do
	[ -n "$_name" ] || continue
	grep -qx "$_name" "$W/test-calls" || untested="$untested $_name"
done <"$W/exports.expected"
[ -z "$untested" ]
rc=$?
expect_rc "every entry point the library exports is called by the API test${untested:+ (not called:$untested)}" "$rc" 0

# ---- the API test ---------------------------------------------------------
CFLAGS="-std=gnu11 -Wall -Wextra -Werror"
cc $CFLAGS -pthread -I"$SDKINC" -I"$T" "$T/api_test.c" -L"$O/libcudart" \
    -L"$O/libcuda" -lcudart -lcuda -lthr -o "$W/bin/api_test" \
    >"$W/build-api.log" 2>&1
rc=$?
expect_rc "api_test compiles against the runtime" "$rc" 0
[ "$rc" -eq 0 ] || sed -n '1,60p' "$W/build-api.log"
API=$W/bin/api_test

run_case "the error codes, the versions and the error queries" \
    env CUDA_NATIVE_BACKEND=fake "$API" core
run_case "the devices, the primary context and the properties" \
    env CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE=gb206,gb10 \
    "$API" devices
run_case "every call the driver cannot make yet says so" \
    env CUDA_NATIVE_BACKEND=fake "$API" not-supported
run_case "a copy between two host addresses is the runtime's own work" \
    env CUDA_NATIVE_BACKEND=fake "$API" host-copy
run_case "the error state of a thread is the error state of that thread" \
    env CUDA_NATIVE_BACKEND=fake "$API" thread-errors
run_case "the registration contract of clang's CUDA mode" \
    env CUDA_NATIVE_BACKEND=fake "$API" registration

# The runtime on a provider whose discovery is not implemented: every call
# that needs the driver says so, and the reason names the provider.
env CUDA_NATIVE_BACKEND=nvrm "$API" driver-down >"$W/nvrm.out" 2>&1
rc=$?
expect_rc "the runtime on a provider without discovery fails" "$rc" 0
cat "$W/nvrm.out"
grep -q 'not implemented' "$W/nvrm.out"
rc=$?
expect_rc "the reason of an unimplemented provider names the discovery" "$rc" 0

# ---- the clang registration contract, end to end --------------------------
LLVM=${LLVM:-/usr/local/llvm23}
if [ -x "$LLVM/bin/clang" ]; then
	SDK=$W/sdk
	sh "$CN/mksdk.sh" "$SDK" >"$W/mksdk.log" 2>&1
	rc=$?
	expect_rc "mksdk.sh builds the SDK" "$rc" 0
	if [ "$rc" -eq 0 ]; then
		K=$SRC/tests/cuda-native
		PATH="$SDK/bin:$PATH" "$LLVM/bin/clang" -O2 -Werror -x cuda \
		    --cuda-path="$SDK" --cuda-gpu-arch=sm_120 \
		    "$K/launch_libcudart.cu" -L"$O/libcudart" -lcudart \
		    -Wl,-rpath,"$O/libcudart" -Wl,-rpath,"$O/libcuda" \
		    -o "$W/launch_libcudart" >"$W/link.log" 2>&1
		rc=$?
		expect_rc "the CUDA program links against the runtime" "$rc" 0
		[ "$rc" -eq 0 ] || sed -n '1,60p' "$W/link.log"
		if [ "$rc" -eq 0 ]; then
			env CUDA_NATIVE_BACKEND=fake "$W/launch_libcudart" \
			    >"$W/launch.out" 2>"$W/launch.err"
			rc=$?
			expect_rc "the CUDA program runs" "$rc" 0
			cat "$W/launch.out"
			grep -qx 'kernels=1' "$W/launch.out"
			rc=$?
			expect_rc "the fat binary registered its one kernel" "$rc" 0
			grep -qx 'found=1' "$W/launch.out"
			rc=$?
			expect_rc "the kernel is found by its host stub" "$rc" 0
			grep -q '^name=.*vadd' "$W/launch.out"
			rc=$?
			expect_rc "the registered kernel carries its name" "$rc" 0
			grep -qx 'launch=801' "$W/launch.out"
			rc=$?
			expect_rc "the launch stops at the limit of the driver" "$rc" 0
			grep -q '^reason=.*cuLaunchKernel' "$W/launch.out"
			rc=$?
			expect_rc "the launch names the driver call that is missing" "$rc" 0
			# The device code was offloaded, never run: the
			# program made no claim about a result.
			grep -q 'vadd' "$W/launch.out" &&
			    ! grep -qi 'the kernel ran' "$W/launch.out"
			rc=$?
			expect_rc "the program claims no result of a kernel" "$rc" 0
		fi
	fi
else
	skip "the clang registration contract: no clang in $LLVM/bin"
fi

# ---- the manual and the README -------------------------------------------
mandoc -T lint -W warning "$L/man/libcudart.3" >"$W/mandoc.out" 2>&1
rc=$?
[ "$rc" -eq 0 ] && [ ! -s "$W/mandoc.out" ]
rc=$?
expect_rc "libcudart.3 is mandoc -T lint -W warning clean" "$rc" 0
[ "$rc" -eq 0 ] || sed -n '1,20p' "$W/mandoc.out"
grep -q 'libcudart-native.so.13' "$L/man/libcudart.3"
rc=$?
expect_rc "the manual names the library it documents" "$rc" 0
grep -q 'cudaErrorNotSupported' "$L/man/libcudart.3" &&
    grep -q 'cudaNativeLastFailureReason' "$L/man/libcudart.3"
rc=$?
expect_rc "the manual names the refusal and the reason of it" "$rc" 0
grep -q 'libcudart' "$SRC/README.md"
rc=$?
expect_rc "the README names the runtime" "$rc" 0
sed -n '/^## libcudart (native CUDA Runtime API)$/,/^## /p' "$SRC/README.md" \
    >"$W/readme-libcudart.md"
grep -q 'libcudart' "$W/readme-libcudart.md"
rc=$?
expect_rc "the README has a section of its own for the runtime" "$rc" 0
! grep -Eq 'Track #[0-9]+' "$W/readme-libcudart.md"
rc=$?
expect_rc "the section of the README carries no Track number" "$rc" 0

# ---- the checks can fail --------------------------------------------------
# A runtime that reports a success it did not achieve is caught by the API
# test: the mutant answers cudaMalloc with cudaSuccess.
MM=$W/m-fake-success
rm -rf "$MM"
mkdir -p "$MM"
cp "$L"/*.c "$L"/*.h "$L/Version.map" "$L/Makefile" "$MM/"
cp -R "$L/man" "$MM/"
python3 -I - "$MM/cudart_memory.c" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
old = """	return (cudart_fail(cudaErrorNotSupported,
	    "libcuda has no cuMemAlloc yet; the runtime cannot allocate "
	    "memory on the device"));"""
new = """	return (cudaSuccess);"""
assert old in text, "the memory module does not hold the refusal"
open(path, "w").write(text.replace(old, new, 1))
PY
rc=$?
expect_rc "the runtime that claims a fake success was written" "$rc" 0
if [ "$rc" -eq 0 ]; then
	(cd "$MM" && MAKEOBJDIR="$MM/obj" LIBCUDA_OBJ="$O/libcuda" \
	    SDKINC="$SDKINC" make) \
	    >"$MM/build.log" 2>&1
	rc=$?
	expect_rc "the runtime that claims a fake success builds" "$rc" 0
	if [ "$rc" -eq 0 ]; then
		env LD_LIBRARY_PATH="$MM/obj:$O/libcuda" CUDA_NATIVE_BACKEND=fake \
		    "$API" not-supported >"$MM/out" 2>&1
		rc=$?
		if [ "$rc" -ne 0 ]; then
			ok "the API test catches a runtime that claims a fake success"
		else
			bad "the API test catches a runtime that claims a fake success"
			sed -n '1,20p' "$MM/out"
		fi
	fi
fi

# A runtime whose error state is shared by every thread is caught: the
# error of one thread is the error of the other.
MT=$W/m-shared-error
rm -rf "$MT"
mkdir -p "$MT"
cp "$L"/*.c "$L"/*.h "$L/Version.map" "$L/Makefile" "$MT/"
cp -R "$L/man" "$MT/"
python3 -I - "$MT/cudart_error.c" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
old = "static _Thread_local cudaError_t thread_error = cudaSuccess;"
new = "static cudaError_t thread_error = cudaSuccess;"
assert old in text, "the error module does not hold the thread-local error"
open(path, "w").write(text.replace(old, new, 1))
PY
rc=$?
expect_rc "the runtime with a shared error state was written" "$rc" 0
if [ "$rc" -eq 0 ]; then
	(cd "$MT" && MAKEOBJDIR="$MT/obj" LIBCUDA_OBJ="$O/libcuda" \
	    SDKINC="$SDKINC" make) \
	    >"$MT/build.log" 2>&1
	rc=$?
	expect_rc "the runtime with a shared error state builds" "$rc" 0
	if [ "$rc" -eq 0 ]; then
		env LD_LIBRARY_PATH="$MT/obj:$O/libcuda" CUDA_NATIVE_BACKEND=fake \
		    "$API" thread-errors >"$MT/out" 2>&1
		rc=$?
		if [ "$rc" -ne 0 ]; then
			ok "the API test catches a runtime with a shared error state"
		else
			bad "the API test catches a runtime with a shared error state"
			sed -n '1,20p' "$MT/out"
		fi
	fi
fi

# A runtime that looks a launch up by nothing is caught: the launch of a
# registered kernel must find its kernel.
ML=$W/m-no-lookup
rm -rf "$ML"
mkdir -p "$ML"
cp "$L"/*.c "$L"/*.h "$L/Version.map" "$L/Makefile" "$ML/"
cp -R "$L/man" "$ML/"
python3 -I - "$ML/cudart_register.c" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
old = "		if (kernel->host_stub == host_stub) {"
new = "		if (0) {"
assert old in text, "the registration module does not look the host stub up"
open(path, "w").write(text.replace(old, new, 1))
PY
rc=$?
expect_rc "the runtime that looks no launch up was written" "$rc" 0
if [ "$rc" -eq 0 ]; then
	(cd "$ML" && MAKEOBJDIR="$ML/obj" LIBCUDA_OBJ="$O/libcuda" \
	    SDKINC="$SDKINC" make) \
	    >"$ML/build.log" 2>&1
	rc=$?
	expect_rc "the runtime that looks no launch up builds" "$rc" 0
	if [ "$rc" -eq 0 ]; then
		env LD_LIBRARY_PATH="$ML/obj:$O/libcuda" CUDA_NATIVE_BACKEND=fake \
		    "$API" registration >"$ML/out" 2>&1
		rc=$?
		if [ "$rc" -ne 0 ]; then
			ok "the API test catches a runtime that looks no launch up"
		else
			bad "the API test catches a runtime that looks no launch up"
			sed -n '1,20p' "$ML/out"
		fi
	fi
fi

printf 'passed: %d failed: %d skipped: %d\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
