#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-2-Clause
#
# Native CUDA C1.4a (Track #2428).  Build and test a FRESH COPY OF THE INDEX,
# never the working tree.  Stage every new file and every edit before running.
# TMPDIR must name an existing scratch directory; never use the system /tmp.

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$HERE/.." && pwd)
: "${TMPDIR:?set TMPDIR to the assigned scratch directory}"
case $TMPDIR in
/*) ;;
*) echo "libcuda_test: TMPDIR must be absolute" >&2; exit 99 ;;
esac
W=$(mktemp -d "$TMPDIR/libcuda-test.XXXXXXXX") || exit 99
trap 'rm -rf "$W"' EXIT INT TERM
unset CUDA_NATIVE_BACKEND CUDA_NATIVE_FAKE_PROFILE CUDA_VISIBLE_DEVICES
unset CUDA_NATIVE_FAKE_ENUM_DELAY_MS CUDA_NATIVE_FAKE_UUID_ERROR
unset CUDA_NATIVE_FAKE_UNSUPPORTED_COOPERATIVE

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
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

# ---- fresh copy and base toolchain ---------------------------------------
SRC=$W/src
mkdir -p "$SRC"
git -C "$REPO" checkout-index -a --prefix="$SRC/" >"$W/checkout.log" 2>&1
rc=$?
expect_rc "fresh copy of the staged tree" "$rc" 0
[ -f "$SRC/lib/libcuda/cuda_core.c" ] && [ -f "$SRC/tests/libcuda/api_test.c" ] &&
    [ -f "$SRC/tests/libcuda_test.sh" ]
rc=$?
expect_rc "the staged copy contains the library, tests and runner" "$rc" 0
[ "$rc" -eq 0 ] || { cat "$W/checkout.log"; exit 98; }
L=$SRC/lib/libcuda
T=$SRC/tests/libcuda
SDK=$SRC/lib/cuda-native/sdk/include
SCHEMA=$L/schema/cuda-native-info-1.schema.json

ld --version 2>&1 | grep -q LLD
rc=$?
expect_rc "base linker is LLD" "$rc" 0
cc --version | head -1
c++ --version | head -1

# ---- BSD make builds ------------------------------------------------------
O=$W/obj
mkdir -p "$O/lib" "$O/info" "$W/bin"
(cd "$L" && MAKEOBJDIR="$O/lib" make CUDA_NATIVE_TESTING=yes) >"$W/build-lib.log" 2>&1
rc=$?
expect_rc "libcuda builds with BSD make and -Werror" "$rc" 0
[ "$rc" -eq 0 ] || sed -n '1,100p' "$W/build-lib.log"
(cd "$L/cuda-native-info" && MAKEOBJDIR="$O/info" LIBCUDA_OBJ="$O/lib" \
    make CUDA_NATIVE_TESTING=yes && MAKEOBJDIR="$O/info" LIBCUDA_OBJ="$O/lib" \
    make CUDA_NATIVE_TESTING=yes check) >"$W/build-info.log" 2>&1
rc=$?
expect_rc "cuda-native-info builds and its embedded schema matches" "$rc" 0
[ "$rc" -eq 0 ] || sed -n '1,100p' "$W/build-info.log"
LIB=$O/lib/libcuda.so.1
INFO=$O/info/cuda-native-info
export LD_LIBRARY_PATH=$O/lib

if [ -f "$LIB" ]; then
	readelf -p .comment "$LIB" >"$W/lib-comment.out" 2>"$W/lib-comment.err"
	rc=$?
else
	rc=1
fi
expect_rc "readelf can inspect libcuda.so.1" "$rc" 0
grep -q 'Linker: LLD' "$W/lib-comment.out" 2>/dev/null
rc=$?
expect_rc "libcuda.so.1 was linked by LLD" "$rc" 0
if [ -f "$LIB" ]; then
	nm -D --defined-only "$LIB" >"$W/nm.out" 2>"$W/nm.err"
	rc=$?
else
	rc=1
fi
expect_rc "nm can inspect libcuda.so.1 dynamic symbols" "$rc" 0
awk 'NF >= 3 { sub(/@@.*/, "", $3); print $3 }' "$W/nm.out" 2>/dev/null |
    sort >"$W/exports.actual"
awk '/^CUDA_1\.0 \{/{inside=1;next} /^\};/{inside=0}
    inside && $1 ~ /^[A-Za-z_][A-Za-z0-9_]*;$/ { sub(/;$/, "", $1); print $1 }' \
    "$L/Version.map" | sort >"$W/map-exports.sorted"
cp "$W/map-exports.sorted" "$W/exports.expected"
cp "$W/map-exports.sorted" "$W/exports.sorted"
awk '{ printf "\t\"%s\",\n", $0 }' "$W/map-exports.sorted" \
    >"$W/cuda_test_exports.inc"
[ -s "$W/map-exports.sorted" ] && [ -s "$W/cuda_test_exports.inc" ]
rc=$?
expect_rc "Version.map exports were extracted for documentation checks" "$rc" 0
python3 -I - "$SRC/README.md" "$W/map-exports.sorted" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
count = len(open(sys.argv[2]).read().splitlines())
match = re.search(r"libcuda\.so\.1[^\n]*\bwith ([0-9]+) [^\n]* calls", text)
assert match is not None, "README libcuda export count is missing"
assert int(match.group(1)) == count, (match.group(1), count)
PY
rc=$?
expect_rc "README call count is derived from Version.map" "$rc" 0
cmp -s "$W/exports.actual" "$W/exports.sorted"
rc=$?
expect_rc "dynamic exports match Version.map exactly" "$rc" 0
(cd "$L" && make -V CUDA_FUNCS) >"$W/make-funcs.raw" 2>"$W/make-funcs.err"
rc=$?
expect_rc "BSD make can evaluate the man-link export list" "$rc" 0
tr -s '[:space:]' '\n' <"$W/make-funcs.raw" | sed '/^$/d' | sort \
    >"$W/make-funcs.sorted"
cmp -s "$W/make-funcs.sorted" "$W/exports.sorted"
rc=$?
expect_rc "man-link exports match Version.map" "$rc" 0
EM=$W/export-map-mutant
mkdir -p "$EM"
cp "$L/Makefile" "$L/version_map.awk" "$EM/"
awk '{ print } $0 == "\t\tcuInit;" { print "\t\tcuCtxSynchronize;" }' \
    "$L/Version.map" >"$EM/Version.map"
grep -q '^		cuCtxSynchronize;$' "$EM/Version.map" &&
    ! cmp -s "$EM/Version.map" "$L/Version.map"
rc=$?
expect_rc "an added Version.map global was planted for the man-link check" "$rc" 0
(cd "$EM" && make -V CUDA_FUNCS) >"$EM/make-funcs.raw" 2>"$EM/make-funcs.err"
rc=$?
if [ "$rc" -eq 0 ]; then
	tr -s '[:space:]' '\n' <"$EM/make-funcs.raw" | sed '/^$/d' |
	    grep -Fxq cuCtxSynchronize
	rc=$?
fi
expect_rc "man-link exports follow an added Version.map global" "$rc" 0

# One Version.map parser: the man-link name list and the proc-table include
# are two modes of it, so a space-indented entry must reach both of them.
FM=$W/version-map-spaces
mkdir -p "$FM"
cp "$L/Makefile" "$L/version_map.awk" "$FM/"
awk '{ if ($0 == "\t\tcuDeviceGetName;") print "        cuDeviceGetName;"; else print }' \
    "$L/Version.map" >"$FM/Version.map"
grep -q '^        cuDeviceGetName;$' "$FM/Version.map" &&
    ! cmp -s "$FM/Version.map" "$L/Version.map"
rc=$?
expect_rc "a space-indented Version.map entry was planted for the parser check" "$rc" 0
awk '/^CUDA_1\.0 \{/{inside=1;next} /^\};/{inside=0}
    inside && $1 ~ /^[A-Za-z_][A-Za-z0-9_]*;$/ { sub(/;$/, "", $1); print $1 }' \
    "$FM/Version.map" | sort >"$FM/oracle.sorted"
(cd "$FM" && make -V CUDA_FUNCS) >"$FM/names.raw" 2>"$FM/names.err"
rc=$?
expect_rc "the Makefile reads the space-indented Version.map fixture" "$rc" 0
tr -s '[:space:]' '\n' <"$FM/names.raw" | sed '/^$/d' | sort >"$FM/names.sorted"
cmp -s "$FM/names.sorted" "$FM/oracle.sorted"
rc=$?
expect_rc "the man-link name list and the field-based oracle agree on the fixture" "$rc" 0
(cd "$FM" && make -V CUDA_EXPORTS_INC) >"$FM/inc.raw" 2>"$FM/inc.err"
rc=$?
expect_rc "the Makefile reads the proc-table include of the fixture" "$rc" 0
grep -q 'PROC_ENTRY(cuDeviceGetName)' "$FM/inc.raw"
rc=$?
expect_rc "the proc-table include contains the space-indented entry too" "$rc" 0
(cd "$L" && MAKEOBJDIR="$O/lib" make -V CUDA_EXPORTS_INC) >"$W/inc.value" 2>&1
cmp -s "$W/inc.value" "$O/lib/cuda_exports.inc"
rc=$?
expect_rc "the generated proc-table include is the value the Makefile computes" "$rc" 0
awk '/^static const proc_export proc_exports\[\] = \{/{inside=1;next}
    inside && /^\};/{exit} inside { print }' "$L/cuda_core.c" \
    >"$W/proc-table.body"
printf '#include "cuda_exports.inc"\n' >"$W/proc-table.expected"
cmp -s "$W/proc-table.body" "$W/proc-table.expected"
rc=$?
expect_rc "proc lookup table is generated from Version.map" "$rc" 0
[ "$(awk 'NF >= 3 && $3 !~ /@@CUDA_1.0$/ { n++ } END { print n + 0 }' \
    "$W/nm.out" 2>/dev/null)" = 0 ]
rc=$?
expect_rc "every defined dynamic symbol carries CUDA_1.0" "$rc" 0
if [ -f "$LIB" ]; then
	readelf -d "$LIB" >"$W/lib-dynamic.out" 2>"$W/lib-dynamic.err"
	rc=$?
else
	rc=1
fi
expect_rc "readelf can inspect libcuda.so.1 dependencies" "$rc" 0
awk '/NEEDED/ { gsub(/[][]/, "", $NF); print $NF }' "$W/lib-dynamic.out" \
    2>/dev/null | sort >"$W/needed.actual"
printf '%s\n' libc.so.7 libthr.so.3 | sort >"$W/needed.expected"
cmp -s "$W/needed.actual" "$W/needed.expected"
rc=$?
expect_rc "libcuda needs only base libc and libthr (no Linux dependency)" "$rc" 0
if [ -x "$INFO" ]; then
	readelf -d "$INFO" >"$W/info-dynamic.out" 2>"$W/info-dynamic.err"
	rc=$?
else
	rc=1
fi
expect_rc "readelf can inspect cuda-native-info dependencies" "$rc" 0
awk '/NEEDED/ { print $NF }' "$W/info-dynamic.out" 2>/dev/null |
    grep -Ei 'linux|nvidia|cuda\.so\.[^1]' &&
    bad "cuda-native-info has an unexpected dependency" || ok "cuda-native-info has no Linux or NVIDIA binary dependency"

# ---- C, C++ and version oracles ------------------------------------------
CFLAGS="-std=gnu11 -Wall -Wextra -Werror"
cc $CFLAGS -pthread -I"$W" -I"$SDK" -I"$T" "$T/api_test.c" -L"$O/lib" -lcuda -lthr \
    -o "$W/bin/api_test" >"$W/build-api.log" 2>&1
rc=$?
expect_rc "api_test compiles against the shared library" "$rc" 0
cc $CFLAGS -I"$L" -I"$SDK" -I"$T" "$T/version_test.c" "$L/cuda_version.c" \
    -o "$W/bin/version_test" >"$W/build-version.log" 2>&1
rc=$?
expect_rc "version_test compiles against the one shared parser" "$rc" 0
c++ -std=c++11 -Wall -Wextra -Werror -I"$SDK" "$T/header_test.cpp" \
    -L"$O/lib" -lcuda -o "$W/bin/header_test" >"$W/build-header.log" 2>&1
rc=$?
expect_rc "cuda.h compiles as C++ and links with C linkage" "$rc" 0
API=$W/bin/api_test
run_case "version parser and formatter assertions" "$W/bin/version_test"
run_case "C++ header and pre-initialization context check" "$W/bin/header_test"
run_case "API core, errors and every proc export" env CUDA_NATIVE_BACKEND=fake "$API" core
env CUDA_NATIVE_BACKEND=fake "$API" proc-from-stdin <"$W/exports.actual" >"$W/proc-abi.out" 2>&1
rc=$?
cat "$W/proc-abi.out"
expect_rc "every dynamic export resolves to its proc-table address" "$rc" 0
run_case "proc lookup works before cuInit" env CUDA_NATIVE_BACKEND=fake \
    "$API" proc-preinit
run_case "fake GB206 and GB10 profiles" env CUDA_NATIVE_BACKEND=fake \
    CUDA_NATIVE_FAKE_PROFILE=gb206,gb10 "$API" profiles
run_case "primary and current contexts across two threads" env \
    CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE=gb206,gb10 "$API" threads
run_case "context state follows reordered physical devices" env \
    CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE=gb206,gb10 CUDA_VISIBLE_DEVICES=1,0 \
    "$API" threads
run_case "pthread_once concurrent cuInit" env CUDA_NATIVE_BACKEND=fake \
    CUDA_NATIVE_FAKE_PROFILE=gb206,gb10 "$API" init-race
run_case "a concurrent observer never sees partial initialization" env \
    CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE=gb206,gb10 \
    CUDA_NATIVE_FAKE_ENUM_DELAY_MS=100 "$API" init-observer
run_case "an NVRM observer never sees false success during initialization" env \
    CUDA_NATIVE_BACKEND=nvrm "$API" init-observer
run_case "NVRM provider is a not-supported stub" env CUDA_NATIVE_BACKEND=nvrm "$API" nvrm
run_case "the backend name follows the calling process environment" env \
    CUDA_NATIVE_BACKEND=fake "$API" backend-name
run_case "unknown provider fails cuInit and later device calls" env \
    CUDA_NATIVE_BACKEND=not-a-provider "$API" bad-backend
run_case "unknown fake profile fails cuInit and later device calls" env \
    CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE=not-a-profile "$API" bad-profile
run_case "an empty fake profile fails cuInit permanently" env \
    CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE= "$API" bad-profile
run_case "attribute failures preserve every probed output" env \
    CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_UNSUPPORTED_COOPERATIVE=1 \
    "$API" attribute-error

run_case "visibility defaults to physical order" env CUDA_NATIVE_BACKEND=fake \
    CUDA_NATIVE_FAKE_PROFILE=gb206,gb10 "$API" order \
    "cuda-native fake GB206" "cuda-native fake GB10"
run_case "visibility filters and reorders indices" env CUDA_NATIVE_BACKEND=fake \
    CUDA_NATIVE_FAKE_PROFILE=gb206,gb10 CUDA_VISIBLE_DEVICES=1,0 "$API" order \
    "cuda-native fake GB10" "cuda-native fake GB206"
run_case "visibility truncates at an invalid positive index" env \
    CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE=gb206,gb10 CUDA_VISIBLE_DEVICES=0,999,1 \
    "$API" order "cuda-native fake GB206"
run_case "visibility stops at a repeated physical device" env \
    CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE=gb206,gb10 \
    CUDA_VISIBLE_DEVICES=0,0,1 "$API" order "cuda-native fake GB206"
run_case "visibility truncates at a negative index" env CUDA_NATIVE_BACKEND=fake \
    CUDA_NATIVE_FAKE_PROFILE=gb206,gb10 CUDA_VISIBLE_DEVICES=0,-1,1 "$API" order \
    "cuda-native fake GB206"
run_case "an empty visibility string hides every device" env CUDA_NATIVE_BACKEND=fake \
    CUDA_NATIVE_FAKE_PROFILE=gb206,gb10 CUDA_VISIBLE_DEVICES= "$API" order
run_case "full GPU UUIDs filter and reorder" env CUDA_NATIVE_BACKEND=fake \
    CUDA_NATIVE_FAKE_PROFILE=gb206,gb10 \
    CUDA_VISIBLE_DEVICES=GPU-cb14a000-0000-4000-8000-000000000002,GPU-cb14a000-0000-4000-8000-000000000001 \
    "$API" uuid-order cb14a000-0000-4000-8000-000000000002 \
    cb14a000-0000-4000-8000-000000000001
run_case "an unambiguous abbreviated GPU UUID selects its device" env \
    CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE=gb206 \
    CUDA_VISIBLE_DEVICES=GPU-cb14a000 \
    "$API" uuid-order cb14a000-0000-4000-8000-000000000001
run_case "an uppercase abbreviated GPU UUID selects its device" env \
    CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE=gb206 \
    CUDA_VISIBLE_DEVICES=GPU-CB14A000 \
    "$API" uuid-order cb14a000-0000-4000-8000-000000000001
run_case "an ambiguous UUID prefix hides all following entries" env \
    CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE=gb206,gb10 CUDA_VISIBLE_DEVICES=GPU-cb,0 \
    "$API" order
run_case "a UUID provider failure aborts initialization permanently" env \
    CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE=gb206,gb10 \
    CUDA_NATIVE_FAKE_UUID_ERROR=1 CUDA_VISIBLE_DEVICES=GPU-cb14a000 \
    "$API" uuid-error
profiles64=$(python3 -I -c 'print(",".join(["gb206"] * 64))')
profiles65=$(python3 -I -c 'print(",".join(["gb206"] * 65))')
visibility64=$(python3 -I -c 'print(",".join(str(i) for i in range(64)))')
visibility65=$(python3 -I -c 'print(",".join(str(i) for i in range(65)))')
run_case "visibility accepts exactly 64 distinct entries" env CUDA_NATIVE_BACKEND=fake \
    CUDA_NATIVE_FAKE_PROFILE="$profiles64" CUDA_VISIBLE_DEVICES="$visibility64" \
    "$API" visibility-cap
run_case "visibility stops at an invalid entry after 64 distinct devices" env \
    CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE="$profiles64" \
    CUDA_VISIBLE_DEVICES="$visibility65" "$API" visibility-cap
run_case "a 65th valid visible device exceeds the library device limit" env \
    CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE="$profiles65" \
    CUDA_VISIBLE_DEVICES="$visibility65" "$API" bad-visibility
env CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE="$profiles65" \
    CUDA_VISIBLE_DEVICES="$visibility65" "$INFO" >"$W/overflow.txt" \
    2>"$W/overflow.err"
rc=$?
expect_rc "a visibility list beyond the device limit returns 1" "$rc" 1
grep -q '^cuda-native-info: fake provider: CUDA_ERROR_INVALID_VALUE:' \
    "$W/overflow.err"
rc=$?
expect_rc "the overflow diagnostic names the invalid value error" "$rc" 0

# ---- assertion-level source mutants --------------------------------------
mutant() {	# mutant NAME FILE SED-EXPR VISIBILITY(- for unset) MODE [ARGS ...]
	_name=$1
	_file=$2
	_expr=$3
	_visibility=$4
	_mode=$5
	shift 5
	# MUTANT_PROFILE selects the provider device list of the mutant run.
	_profile=${MUTANT_PROFILE:-gb206,gb10}
	_md=$W/mutant.$_name
	mkdir -p "$_md"
	cp "$L"/*.c "$L"/*.h "$_md"/
	sed -i '' "$_expr" "$_md/$_file"
	if cmp -s "$_md/$_file" "$L/$_file"; then
		bad "mutant $_name: the source edit did not apply"
		return
	fi
	cc -std=gnu11 -w -pthread -I"$W" -I"$O/lib" -I"$_md" -I"$SDK" -I"$T" \
	    "$T/api_test.c" \
	    "$_md"/*.c -o "$_md/api_test" >"$_md/build.log" 2>&1
	if [ "$?" -ne 0 ]; then
		bad "mutant $_name: does not compile (not an assertion oracle)"
		return
	fi
	if [ "$_visibility" = - ]; then
		env CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE="$_profile" \
		    "$_md/api_test" "$_mode" "$@" >"$_md/run.log" 2>&1
	else
		env CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE="$_profile" \
		    CUDA_VISIBLE_DEVICES="$_visibility" "$_md/api_test" "$_mode" "$@" \
		    >"$_md/run.log" 2>&1
	fi
	_rc=$?
	if [ "$_rc" -ne 0 ] && grep -q '^FAIL ' "$_md/run.log"; then
		ok "mutant killed by assertions: $_name"
		tail -n 1 "$_md/run.log"
	else
		bad "mutant SURVIVED or did not fail by assertion: $_name (rc=$_rc)"
	fi
}
mutant fake-sm-count cuda_fake.c 's/\.multiprocessors = 36/.multiprocessors = 35/' \
    - profiles
mutant context-set-current cuda_core.c \
    's/return (cuda_registry_current_set(ctx));/return (CUDA_ERROR_INVALID_CONTEXT);/' \
    - threads
mutant visibility-invalid-index cuda_registry.c \
    's/if (value < registry\.physical_count)/if (1)/; s/\*physical_index = value;/*physical_index = value >= registry.physical_count ? 1 : value;/' \
    0,999,1 order "cuda-native fake GB206"
# The device limit is a real error: without the overflow return the 65th valid
# visible device would be accepted, and this mutant must be killed.
MUTANT_PROFILE="$profiles65"
mutant visibility-overflow cuda_registry.c \
    's/if (registry\.visible_count == CUDA_NATIVE_MAX_DEVICES)/if (0)/' \
    "$visibility65" bad-visibility
MUTANT_PROFILE="gb206,gb10"
if grep -n '"\$TMPDIR/mutant' "$SRC/tests/libcuda_test.sh" >"$W/mutant-paths.out"; then
	cat "$W/mutant-paths.out"
	bad "mutant logs stay inside the private per-mutant directory"
else
	ok "mutant logs stay inside the private per-mutant directory"
fi

# ---- CLI text, JSON, JSON Lines and schema --------------------------------
run_case "text output on the default fake device" env CUDA_NATIVE_BACKEND=fake "$INFO"
env CUDA_NATIVE_BACKEND=fake "$INFO" >"$W/text.out" 2>"$W/text.err"
rc=$?
expect_rc "text mode exit status" "$rc" 0
grep -q '^cuda_version 13.0 (13, 0, 0)$' "$W/text.out" &&
    grep -q '^cuda_native_version 0.1.0 (0, 1, 0)$' "$W/text.out" &&
    grep -q '^  name cuda-native fake GB206$' "$W/text.out" &&
    grep -q '^  total_memory_bytes 17179869184$' "$W/text.out" &&
    grep -q '^  multiprocessor_count 36$' "$W/text.out" && [ ! -s "$W/text.err" ]
rc=$?
expect_rc "text output contains versions, identity, memory and SM count" "$rc" 0

VAL="python3 -I $SRC/tests/libnvrm/schema_validate.py $SCHEMA"
for profile in gb206 gb206,gb10; do
	env CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE=$profile "$INFO" --json >"$W/$profile.json"
	rc=$?
	expect_rc "--json exits 0 for $profile" "$rc" 0
	$VAL "$W/$profile.json"
	rc=$?
	expect_rc "--json validates for $profile" "$rc" 0
	env CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE=$profile "$INFO" --jsonl >"$W/$profile.jsonl"
	rc=$?
	expect_rc "--jsonl exits 0 for $profile" "$rc" 0
	$VAL "$W/$profile.jsonl"
	rc=$?
	expect_rc "--jsonl validates each record for $profile" "$rc" 0
done
[ "$(wc -l <"$W/gb206,gb10.json" | tr -d ' ')" = 1 ]
rc=$?
expect_rc "--json is exactly one line" "$rc" 0
[ "$(wc -l <"$W/gb206,gb10.jsonl" | tr -d ' ')" = 4 ]
rc=$?
expect_rc "two-device --jsonl is header + 2 devices + end" "$rc" 0
python3 -I - "$W/gb206.json" "$W/gb206,gb10.json" "$W/gb206,gb10.jsonl" <<'PY'
import json, sys
one = json.load(open(sys.argv[1]))
two = json.load(open(sys.argv[2]))
stream = [json.loads(line) for line in open(sys.argv[3])]
assert one["cuda_version"] == {"string":"13.0", "major":13, "minor":0, "patch":0}
assert one["cuda_native_version"] == {"string":"0.1.0", "major":0, "minor":1, "patch":0}
a = one["devices"][0]
assert a["uuid"] == "GPU-cb14a000-0000-4000-8000-000000000001"
assert a["total_memory_bytes"] == 16 * 1024**3
assert a["attributes"]["compute_capability_major"] == 12
assert a["attributes"]["compute_capability_minor"] == 0
assert a["attributes"]["multiprocessor_count"] == 36
assert a["attributes"]["integrated"] == 0
assert a["attributes"]["max_threads_per_block"] == 1024
assert a["attributes"]["max_shared_memory_per_block"] == 48 * 1024
assert a["attributes"]["max_shared_memory_per_block_optin"] == 99 * 1024
assert a["attributes"]["warp_size"] == 32
assert a["attributes"]["virtual_memory_management_supported"] == 1
assert a["attributes"]["cooperative_launch"] == 0
b = two["devices"][1]
assert b["name"] == "cuda-native fake GB10"
assert b["uuid"] == "GPU-cb14a000-0000-4000-8000-000000000002"
assert b["total_memory_bytes"] == 128 * 1024**3
assert b["attributes"]["compute_capability_minor"] == 1
assert b["attributes"]["multiprocessor_count"] == 48
assert b["attributes"]["integrated"] == 1
assert b["attributes"]["pci_domain_id"] == 15
assert two["device_count"] == len(two["devices"]) == 2
assert [d["ordinal"] for d in two["devices"]] == [0, 1]
assert [r["kind"] for r in stream] == ["header", "device", "device", "end"]
assert stream[0]["device_count"] == stream[-1]["count"] == 2
PY
rc=$?
expect_rc "JSON semantics: all synthetic values, versions and stream counts" "$rc" 0

env CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_UNSUPPORTED_COOPERATIVE=1 \
    "$INFO" --json >"$W/unsupported-attribute.json" 2>"$W/unsupported-attribute.err"
rc=$?
expect_rc "an unsupported attribute does not abort --json" "$rc" 0
$VAL "$W/unsupported-attribute.json"
rc=$?
expect_rc "JSON null for an unsupported attribute validates" "$rc" 0
env CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_UNSUPPORTED_COOPERATIVE=1 \
    "$INFO" --jsonl >"$W/unsupported-attribute.jsonl" 2>>"$W/unsupported-attribute.err"
rc=$?
expect_rc "an unsupported attribute does not abort --jsonl" "$rc" 0
$VAL "$W/unsupported-attribute.jsonl"
rc=$?
expect_rc "JSON Lines null for an unsupported attribute validates" "$rc" 0
python3 -I - "$W/unsupported-attribute.json" "$W/unsupported-attribute.jsonl" <<'PY'
import json, sys
document = json.load(open(sys.argv[1]))
stream = [json.loads(line) for line in open(sys.argv[2])]
assert document["devices"][0]["attributes"]["cooperative_launch"] is None
assert stream[1]["attributes"]["cooperative_launch"] is None
assert document["devices"][0]["attributes"]["warp_size"] == 32
PY
rc=$?
expect_rc "unsupported attributes stay present as null" "$rc" 0

env CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE=utf8 "$INFO" --json \
    >"$W/utf8.json" 2>"$W/utf8.err"
rc=$?
expect_rc "UTF-8 fake profile produces JSON" "$rc" 0
python3 -I - "$W/utf8.json" <<'PY'
import json, sys
raw = open(sys.argv[1], "rb").read()
document = json.loads(raw)
expected = "cuda-native fake \u2122 \u00e9 \ufffd \x01\x7f"
assert document["devices"][0]["name"] == expected, repr(document["devices"][0]["name"])
assert "\u2122".encode("utf-8") in raw
assert "\u00e9".encode("utf-8") in raw
assert b"\\ufffd" in raw
assert b"\\u0001" in raw and b"\\u007f" in raw
PY
rc=$?
expect_rc "JSON preserves UTF-8, replaces invalid bytes and escapes controls" "$rc" 0

# A changed library default must change the CLI's reported backend too.
DB=$W/default-backend
mkdir -p "$DB"
cp "$L/cuda_backend.c" "$DB/cuda_backend.c"
sed -i '' 's/default_backend = "nvrm"/default_backend = "fake"/' \
    "$DB/cuda_backend.c"
! cmp -s "$DB/cuda_backend.c" "$L/cuda_backend.c"
rc=$?
expect_rc "the shared backend-default mutant changed the library default" "$rc" 0
(
    cc $CFLAGS -fPIC -shared -Wl,-Bsymbolic-functions \
        -Wl,--version-script="$L/Version.map" -I"$O/lib" -I"$L" -I"$SDK" \
        "$L/cuda_core.c" "$L/cuda_registry.c" "$L/cuda_fake.c" \
        "$L/cuda_nvrm.c" "$L/cuda_errors.c" "$DB/cuda_backend.c" \
        "$L/cuda_version.c" "$L/cuda_uuid.c" -lthr -o "$DB/libcuda.so.1" &&
    ln -s libcuda.so.1 "$DB/libcuda.so" &&
    cc $CFLAGS -I"$O/info" -I"$L" -I"$SDK" \
        "$L/cuda-native-info/cuda-native-info.c" "$L/cuda_version.c" \
        "$L/cuda_uuid.c" -L"$DB" -lcuda -lthr -o "$DB/cuda-native-info"
) >"$DB/build.log" 2>&1
rc=$?
expect_rc "shared backend-default mutant builds" "$rc" 0
if [ "$rc" -eq 0 ]; then
	env -u CUDA_NATIVE_BACKEND LD_LIBRARY_PATH="$DB" "$DB/cuda-native-info" \
	    --json >"$DB/output.json" 2>"$DB/error.log"
	rc=$?
	expect_rc "patched fake default produces a device report" "$rc" 0
	python3 -I - "$DB/output.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["backend"] == "fake", d["backend"]
assert d["device_count"] == 1
assert d["devices"][0]["name"] == "cuda-native fake GB206"
PY
	rc=$?
	expect_rc "CLI backend follows the patched library default" "$rc" 0
	env -u CUDA_NATIVE_BACKEND LD_LIBRARY_PATH="$DB" "$DB/cuda-native-info" \
	    --help >"$DB/help.out" 2>&1
	grep -q '(default fake)' "$DB/help.out" &&
	    ! grep -q '(default nvrm)' "$DB/help.out"
	rc=$?
	expect_rc "--help follows the patched library default backend" "$rc" 0
	env -u CUDA_NATIVE_BACKEND CUDA_NATIVE_FAKE_PROFILE=gb100 \
	    LD_LIBRARY_PATH="$DB" "$DB/cuda-native-info" >"$DB/bad-profile.out" \
	    2>"$DB/bad-profile.err"
	rc=$?
	expect_rc "CLI validates profiles against a patched fake default" "$rc" 1
	grep -q "CUDA_NATIVE_FAKE_PROFILE: unknown profile 'gb100'" \
	    "$DB/bad-profile.err"
	rc=$?
	expect_rc "patched fake default retains the named profile diagnostic" "$rc" 0
fi

# A provider profile added to the library must be known to an existing CLI.
PT=$W/profile-table
mkdir -p "$PT"
cp "$L"/*.c "$L"/*.h "$PT"/
python3 -I - "$PT/cuda_fake.c" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
start = text.index('\t{\n\t\t.profile = "gb206",')
end = text.index('\n\t},', start) + len('\n\t},')
entry = text[start:end]
entry = entry.replace('"gb206"', '"gb202"').replace(
    '"cuda-native fake GB206"', '"cuda-native fake GB202"')
entry = entry.replace('0x00, 0x00, 0x00, 0x01 }',
    '0x00, 0x00, 0x00, 0x04 }')
assert entry != text[start:end]
open(path, "w").write(text[:start] + entry + '\n' + text[start:])
PY
(
    cc $CFLAGS -fPIC -shared -Wl,-Bsymbolic-functions \
        -Wl,--version-script="$L/Version.map" -DCUDA_NATIVE_TESTING \
        -I"$O/lib" -I"$PT" -I"$SDK" "$PT"/*.c -lthr -o "$PT/libcuda.so.1" &&
    ln -s libcuda.so.1 "$PT/libcuda.so" &&
    cc $CFLAGS -I"$O/info" -I"$L" -I"$SDK" \
        "$L/cuda-native-info/cuda-native-info.c" "$L/cuda_version.c" \
        "$L/cuda_uuid.c" -L"$PT" -lcuda -lthr -o "$PT/cuda-native-info"
) >"$PT/build.log" 2>&1
rc=$?
expect_rc "added-profile library and unmodified CLI build" "$rc" 0
[ "$rc" -eq 0 ] || sed -n '1,80p' "$PT/build.log"
if [ "$rc" -eq 0 ]; then
	env CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE=gb202 \
	    LD_LIBRARY_PATH="$PT" "$PT/cuda-native-info" --json \
	    >"$PT/output.json" 2>"$PT/error.log"
	rc=$?
	expect_rc "CLI accepts a profile known only to the library table" "$rc" 0
	if [ -s "$PT/output.json" ]; then
		python3 -I - "$PT/output.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["devices"][0]["name"] == "cuda-native fake GB202"
PY
		rc=$?
	else
		rc=1
	fi
	expect_rc "added profile reaches the CLI device report" "$rc" 0
	env LD_LIBRARY_PATH="$PT" "$PT/cuda-native-info" --help >"$PT/help.out" 2>&1
	grep -q 'gb202' "$PT/help.out" &&
	    ! grep -q '^  gb206,gb10 (default gb206)\.$' "$PT/help.out"
	rc=$?
	expect_rc "--help names the profile the library added" "$rc" 0
fi

env CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE=gb206,gb10 CUDA_VISIBLE_DEVICES=1,0 \
    "$INFO" --json >"$W/reordered.json"
python3 -I - "$W/reordered.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert [x["name"] for x in d["devices"]] == ["cuda-native fake GB10", "cuda-native fake GB206"]
PY
rc=$?
expect_rc "CLI observes visibility reordering" "$rc" 0
env CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE=gb206,gb10 CUDA_VISIBLE_DEVICES= \
    "$INFO" --json >"$W/empty.json"
rc=$?
expect_rc "empty visibility is a successful JSON result" "$rc" 0
$VAL "$W/empty.json"
rc=$?
expect_rc "empty device document validates" "$rc" 0
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["device_count"] == 0 and d["devices"] == []' "$W/empty.json"
rc=$?
expect_rc "empty device document has count zero and devices []" "$rc" 0
env CUDA_NATIVE_BACKEND=fake CUDA_VISIBLE_DEVICES= "$INFO" --jsonl >"$W/empty.jsonl"
[ "$(wc -l <"$W/empty.jsonl" | tr -d ' ')" = 2 ]
rc=$?
expect_rc "empty JSON Lines output is header + end" "$rc" 0
$VAL "$W/empty.jsonl"
rc=$?
expect_rc "empty JSON Lines output validates" "$rc" 0
env CUDA_NATIVE_BACKEND=fake CUDA_VISIBLE_DEVICES= "$INFO" >"$W/empty.txt"
grep -q '^no CUDA devices are visible (filtered by CUDA_VISIBLE_DEVICES=""; see libcuda(3))$' \
    "$W/empty.txt"
rc=$?
expect_rc "filtered-empty text output names CUDA_VISIBLE_DEVICES" "$rc" 0
env CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE=gb206,gb10 \
    CUDA_VISIBLE_DEVICES=0,999,1 "$INFO" >"$W/truncated-visibility.txt"
rc=$?
expect_rc "partially visible text report succeeds" "$rc" 0
grep -q '^device_count 1$' "$W/truncated-visibility.txt" &&
    grep -q '^visibility_filter "0,999,1"$' "$W/truncated-visibility.txt"
rc=$?
expect_rc "text report shows the visibility filter before a partial result" "$rc" 0

# A visibility value with a quote, a backslash, a newline and an escape must
# not break the report, and no control byte may reach the terminal.
evil_vis=$(printf '0,"\\\n\033')
env CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE=gb206,gb10 \
    CUDA_VISIBLE_DEVICES="$evil_vis" "$INFO" >"$W/escaped.txt" 2>"$W/escaped.err"
rc=$?
expect_rc "a visibility value with control bytes still reports" "$rc" 0
[ "$(grep -c '^visibility_filter ' "$W/escaped.txt")" = 1 ]
rc=$?
expect_rc "the escaped visibility filter is exactly one report line" "$rc" 0
grep -q -F 'visibility_filter "0,\"\\\u000a\u001b"' "$W/escaped.txt"
rc=$?
expect_rc "the visibility filter escapes quotes, backslashes and control bytes" "$rc" 0
if grep -q "$(printf '\033')" "$W/escaped.txt"; then
	bad "no escape byte reaches the text report"
else
	ok "no escape byte reaches the text report"
fi
env CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE=gb206,gb10 \
    CUDA_VISIBLE_DEVICES="$evil_vis" "$INFO" --json >"$W/escaped.json"
rc=$?
expect_rc "the JSON document is written for a visibility value with control bytes" "$rc" 0
python3 -I - "$W/escaped.json" "$evil_vis" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["visibility_filter"] == sys.argv[2], repr(d["visibility_filter"])
PY
rc=$?
expect_rc "the JSON document carries the same escaped visibility filter" "$rc" 0

env CUDA_NATIVE_BACKEND=nvrm "$INFO" --schema >"$W/schema.out"
rc=$?
expect_rc "--schema does not need a working provider" "$rc" 0
cmp -s "$W/schema.out" "$SCHEMA"
rc=$?
expect_rc "--schema is byte-identical to the committed schema" "$rc" 0
python3 -I -c 'import json,sys; json.load(open(sys.argv[1]))' "$SCHEMA"
rc=$?
expect_rc "the committed schema parses as JSON" "$rc" 0
for backend in not-a-provider nvrm; do
	env CUDA_NATIVE_BACKEND=$backend "$INFO" --json >"$W/error-$backend.json"
	rc=$?
	expect_rc "provider failure $backend returns 1" "$rc" 1
	$VAL "$W/error-$backend.json"
	rc=$?
	expect_rc "provider failure $backend is a schema-valid error" "$rc" 0
done
python3 -I - "$W/error-not-a-provider.json" "$W/error-nvrm.json" <<'PY'
import json, sys
da = json.load(open(sys.argv[1]))
db = json.load(open(sys.argv[2]))
a = da["error"]
b = db["error"]
assert a["code"] == 1 and a["name"] == "CUDA_ERROR_INVALID_VALUE"
assert b["code"] == 801 and b["name"] == "CUDA_ERROR_NOT_SUPPORTED"
assert da["backend"] == "not-a-provider" and db["backend"] == "nvrm"
assert "CUDA_NATIVE_BACKEND=fake" in b["hint"]
PY
rc=$?
expect_rc "JSON errors carry codes, names, backend and NVRM guidance" "$rc" 0
env CUDA_NATIVE_BACKEND=nvrm "$INFO" >"$W/nvrm.out" 2>"$W/nvrm.err"
rc=$?
expect_rc "text provider failure returns 1" "$rc" 1
grep -q 'CUDA_ERROR_NOT_SUPPORTED' "$W/nvrm.err"
rc=$?
expect_rc "text provider failure explains the error on stderr" "$rc" 0
grep -q '^cuda-native-info: nvrm provider: CUDA_ERROR_NOT_SUPPORTED:' "$W/nvrm.err" &&
    grep -q 'native NVRM discovery is not implemented yet; set CUDA_NATIVE_BACKEND=fake for synthetic devices' \
    "$W/nvrm.err"
rc=$?
expect_rc "text provider failure names the backend and fake-provider remedy" "$rc" 0
env CUDA_NATIVE_BACKEND=not-a-provider "$INFO" >"$W/bad-backend.out" 2>"$W/bad-backend.err"
rc=$?
expect_rc "an invalid provider environment value returns 1" "$rc" 1
grep -q '^cuda-native-info: CUDA_NATIVE_BACKEND=not-a-provider is not a provider; use one of: fake, nvrm$' \
    "$W/bad-backend.err"
rc=$?
expect_rc "provider diagnostics name the variable and the library's providers" "$rc" 0
env CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE=gb100 "$INFO" \
    >"$W/bad-profile.out" 2>"$W/bad-profile.err"
rc=$?
expect_rc "an unknown fake profile environment value returns 1" "$rc" 1
grep -q "CUDA_NATIVE_FAKE_PROFILE: unknown profile 'gb100'; use gb206,gb10 or a comma-separated list" \
    "$W/bad-profile.err"
rc=$?
expect_rc "profile diagnostics name the variable, value and valid profiles" "$rc" 0
env CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE=gb100 "$INFO" --json \
    >"$W/error-bad-profile.json"
rc=$?
expect_rc "an invalid profile still produces a JSON error" "$rc" 1
$VAL "$W/error-bad-profile.json"
rc=$?
expect_rc "the invalid-profile JSON error validates" "$rc" 0
python3 -I - "$W/error-not-a-provider.json" "$W/error-bad-profile.json" <<'PY'
import json, sys
backend = json.load(open(sys.argv[1]))
profile = json.load(open(sys.argv[2]))
assert "CUDA_NATIVE_BACKEND=not-a-provider" in backend["error"]["message"]
assert "use one of: fake, nvrm" in backend["error"]["message"]
assert "unknown profile 'gb100'" in profile["error"]["message"]
assert "use gb206,gb10" in profile["error"]["message"]
PY
rc=$?
expect_rc "JSON environment diagnostics carry the same actionable messages" "$rc" 0

"$INFO" --help >"$W/help.out" 2>&1
rc=$?
expect_rc "--help exits 0" "$rc" 0
"$INFO" -h >"$W/help-short.out" 2>&1
rc=$?
expect_rc "-h exits 0" "$rc" 0
cmp -s "$W/help-short.out" "$W/help.out" &&
    grep -q -F -- '-h, --help' "$W/help.out"
rc=$?
expect_rc "-h matches --help and is advertised beside it" "$rc" 0
grep -q -- '--jsonl' "$W/help.out" && grep -q -- '--schema' "$W/help.out"
rc=$?
expect_rc "--help describes JSON Lines and schema modes" "$rc" 0
grep -q '^CUDA_NATIVE_FAKE_PROFILE takes a comma-separated list of fake profiles:$' \
    "$W/help.out" &&
    grep -q '^  gb206,gb10 (default gb206)\.$' "$W/help.out"
rc=$?
expect_rc "--help names both fake profiles on a split line" "$rc" 0
help_profiles=$(sed -n 's/^  \([A-Za-z0-9,]*\) (default [^)]*)\.$/\1/p' "$W/help.out")
[ -n "$help_profiles" ]
rc=$?
expect_rc "--help prints the fake profile list as one copyable value" "$rc" 0
case $help_profiles in
*" "*) rc=1 ;;
*) rc=0 ;;
esac
expect_rc "the printed fake profile list has no separator whitespace" "$rc" 0
env CUDA_NATIVE_BACKEND=fake CUDA_NATIVE_FAKE_PROFILE="$help_profiles" "$INFO" \
    >"$W/help-profiles.out" 2>&1
rc=$?
expect_rc "the profile list the help prints is accepted by the parser" "$rc" 0
if grep -nE 'gb206|gb10|fake or nvrm' "$L/cuda-native-info/cuda-native-info.c" \
    >"$W/cli-hardcoded.out"; then
	cat "$W/cli-hardcoded.out"
	bad "the CLI tool source holds no hard-coded backend or profile list"
else
	ok "the CLI tool source holds no hard-coded backend or profile list"
fi
grep -q 'comma-separated indices or GPU-<uuid> prefixes' "$W/help.out" &&
    grep -q 'stops at the first invalid entry (libcuda(3))' "$W/help.out" &&
    grep -q 'Repeated devices also stop parsing' "$W/help.out"
rc=$?
expect_rc "--help gives visibility syntax and truncation behavior" "$rc" 0
awk 'length($0) > 79 {
	print "help line exceeds 79 columns: " $0
	failed = 1
}
END { exit failed }' "$W/help.out"
rc=$?
expect_rc "--help fits an 80-column terminal" "$rc" 0
"$INFO" --not-an-option >/dev/null 2>&1
rc=$?
expect_rc "unknown CLI option exits 2" "$rc" 2
"$INFO" extra >/dev/null 2>&1
rc=$?
expect_rc "positional CLI argument exits 2" "$rc" 2
"$INFO" --json --jsonl >/dev/null 2>"$W/modes.err"
rc=$?
expect_rc "multiple output modes exit 2" "$rc" 2
grep -q 'exclude each other' "$W/modes.err"
rc=$?
expect_rc "multiple output modes explain the conflict" "$rc" 0

# ---- validator mutants: wrong data and unknown keywords must be refused ---
python3 -I - "$W/gb206.json" "$SCHEMA" "$W" <<'PY'
import copy, json, sys
good = json.load(open(sys.argv[1]))
schema = json.load(open(sys.argv[2]))
w = sys.argv[3]
def dump(name, value):
    open(w + "/invalid-" + name + ".json", "w").write(json.dumps(value) + "\n")
m = copy.deepcopy(good); del m["devices"][0]["name"]; dump("missing", m)
m = copy.deepcopy(good); m["devices"][0]["extra"] = 1; dump("extra", m)
m = copy.deepcopy(good); m["devices"][0]["attributes"]["warp_size"] = "32"; dump("type", m)
m = copy.deepcopy(good); m["devices"][0]["attributes"]["warp_size"] = -1; dump("negative", m)
m = copy.deepcopy(good); m["schema"] = "cuda-native-info/2"; dump("schema", m)
m = copy.deepcopy(good); m["kind"] = "not-a-kind"; dump("kind", m)
s = copy.deepcopy(schema); s["unsupportedKeyword"] = True
json.dump(s, open(w + "/unsupported.schema.json", "w"))
open(w + "/not-json.json", "w").write("{not JSON}\n")
open(w + "/no-values.json", "w").write("\n")
PY
for mutant in missing extra type negative schema kind; do
	$VAL "$W/invalid-$mutant.json" >/dev/null 2>&1
	rc=$?
	if [ "$rc" -eq 1 ]; then ok "validator refused data mutant: $mutant"; else bad "validator accepted data mutant: $mutant (rc=$rc)"; fi
done
python3 -I "$SRC/tests/libnvrm/schema_validate.py" "$W/unsupported.schema.json" "$W/gb206.json" >"$W/keyword.out" 2>&1
rc=$?
if [ "$rc" -eq 1 ] && grep -q 'does not support keyword unsupportedKeyword' "$W/keyword.out"; then
	ok "validator refuses an unsupported schema keyword"
else
	bad "validator accepted or crashed on an unsupported keyword (rc=$rc)"
fi
python3 -I "$SRC/tests/libnvrm/schema_validate.py" "$SCHEMA" "$W/not-json.json" >/dev/null 2>&1
rc=$?
expect_rc "validator refuses malformed JSON" "$rc" 1
python3 -I "$SRC/tests/libnvrm/schema_validate.py" "$SCHEMA" "$W/no-values.json" >/dev/null 2>&1
rc=$?
expect_rc "validator refuses an empty input stream" "$rc" 1
python3 -I "$SRC/tests/libnvrm/schema_validate.py" >/dev/null 2>&1
rc=$?
expect_rc "validator usage error is 2" "$rc" 2

# ---- manuals, source hygiene and licence provenance -----------------------
awk '
	/^struct thread_case \{/ { inside = 1; next }
	inside && /^};/ { exit }
	inside {
		sub(/;.*/, "")
		gsub(/^[ \t]+|[ \t]+$/, "")
		print $NF
	}
' "$T/api_test.c" >"$W/thread-fields"
[ -s "$W/thread-fields" ]
rc=$?
expect_rc "thread_case fields were extracted for the unused-member check" "$rc" 0
unused=
while IFS= read -r member; do
	if ! grep -Eq "(tc->|[ab]\\.)${member}([^[:alnum:]_]|$)" "$T/api_test.c"; then
		unused="$unused $member"
	fi
done <"$W/thread-fields"
[ -z "$unused" ]
rc=$?
expect_rc "every thread_case member is used${unused:+ (unused:$unused)}" "$rc" 0
for dead in active_only REGISTRY_RUNNING REGISTRY_DONE; do
	if grep -n "$dead" "$L/cuda_registry.c" >"$W/registry-dead.out"; then
		cat "$W/registry-dead.out"
		bad "registry omits dead state or parameter: $dead"
	else
		ok "registry omits dead state or parameter: $dead"
	fi
done
if grep -nE '(->|\.)primary([^_[:alnum:]]|$)' "$L/cuda_registry.c" \
    >"$W/registry-primary.out"; then
	cat "$W/registry-primary.out"
	bad "registry uses primary_state directly, without a redundant pointer"
else
	ok "registry uses primary_state directly, without a redundant pointer"
fi
! grep -q 'Track #' "$SDK/cuda.h"
rc=$?
expect_rc "public header has no internal tracker labels" "$rc" 0
if grep -R -n 'this round' "$L" >"$W/process-labels.out"; then
	cat "$W/process-labels.out"
	bad "library comments have no process-specific round labels"
else
	ok "library comments have no process-specific round labels"
fi
python3 -I - "$L/man/libcuda.3" <<'PY'
import re, sys
source = open(sys.argv[1]).read()
text = re.sub(r"(?m)^\.[A-Z][a-z]?\s*", " ", source)
text = " ".join(text.split())
required = ("When no devices remain visible, cuInit returns CUDA_SUCCESS and "
    "cuDeviceGetCount reports zero. CUDA_ERROR_NO_DEVICE is not returned for "
    "an empty device set.")
if required not in text:
    raise SystemExit("missing explicit empty-system success documentation")
if "matching the public CUDA environment-variable contract" in text:
    raise SystemExit("visibility documentation overclaims public compatibility")
PY
rc=$?
expect_rc "empty visibility success is documented without a compatibility overclaim" "$rc" 0
python3 -I - "$L/man/libcuda.3" <<'PY'
import re, sys
source = open(sys.argv[1]).read()
text = re.sub(r"(?m)^\.[A-Z][a-z]?\s*", " ", source)
text = " ".join(text.split())
if "process-independent" in text:
    raise SystemExit("the manual still calls the native queries process-independent")
required = (
    "These cuda-native extensions do not initialize a provider.",
    "reads the calling process's environment when it is called",
    "Provider and profile table membership is fixed by the loaded library")
for part in required:
    if part not in text:
        raise SystemExit("missing native-query documentation: " + part)
PY
rc=$?
expect_rc "the native extension queries are documented as environment-dependent" "$rc" 0
MANWIDTH=80 man -l "$L/cuda-native-info/cuda-native-info.1" \
    >"$W/info-man.raw" 2>"$W/info-man.err" &&
    col -b <"$W/info-man.raw" >"$W/info-man.txt"
rc=$?
expect_rc "cuda-native-info manual renders as printable 80-column text" "$rc" 0
grep -q -F -- '-h, --help' "$W/info-man.txt"
rc=$?
expect_rc "cuda-native-info manual documents -h beside --help" "$rc" 0
grep -q 'env CUDA_NATIVE_BACKEND=fake \\$' "$W/info-man.txt" &&
    grep -q 'python3 tests/libnvrm/schema_validate.py \\$' "$W/info-man.txt"
rc=$?
expect_rc "rendered manual examples retain their shell continuations" "$rc" 0
awk 'length($0) > 80 {
	print "manual line exceeds 80 columns: " $0
	failed = 1
}
END { exit failed }' "$W/info-man.txt"
rc=$?
expect_rc "rendered cuda-native-info manual fits 80 columns" "$rc" 0
for man in "$L/man/libcuda.3" "$L/cuda-native-info/cuda-native-info.1"; do
	mandoc -T lint -W warning "$man" >"$W/mandoc.log" 2>&1
	rc=$?
	if [ "$rc" -eq 0 ] && [ ! -s "$W/mandoc.log" ]; then
		ok "mandoc -T lint -W warning is silent: $(basename "$man")"
	else
		bad "mandoc is not silent: $(basename "$man")"
		cat "$W/mandoc.log"
	fi
done
sh -n "$SRC/tests/libcuda_test.sh"
rc=$?
expect_rc "the test runner passes sh -n" "$rc" 0
python3 -I - "$L" "$T" "$SDK/cuda.h" "$SRC/tests/libcuda_test.sh" <<'PY'
import os, sys
roots = sys.argv[1:3]
files = []
for root in roots:
    for base, dirs, names in os.walk(root):
        for name in names:
            if not name.endswith(".json"):
                files.append(os.path.join(base, name))
files.extend(sys.argv[3:])
bad = []
for path in files:
    with open(path, errors="replace") as f:
        head = "".join(f.readline() for _ in range(12))
    if "SPDX-License-Identifier: BSD-2-Clause" not in head:
        bad.append(path)
assert not bad, bad
PY
rc=$?
expect_rc "every new source, script, Makefile and man page has BSD-2-Clause provenance" "$rc" 0

printf 'SUMMARY: %d checks passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
