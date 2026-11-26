#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-2-Clause
#
# libnvrm_test.sh - the whole libnvrm suite (Track #2378, memory #2419), on a FRESH COPY
# of the STAGED content (checkout-index; after a commit that is the commit),
# built out of tree with base LLD.  Stage new files before running it.  No
# hardware and no loaded driver are needed: the fake backend and a scripted
# kernel stand in; the live proof is tests/libnvrm/boot_nvrm_info.sh in a test boot.
#
# Steps: toolchain; library and tool build (schema drift check in the build);
# core + fake unit tests at 100% line and branch coverage; RM backend tests
# against the scripted kernel; memory and VA (mem_test on the fake software
# GPU, rm_mem_test against a multi-session scripted kernel), each at 100%;
# Capsicum tests; JSON output of every mode
# validated against the schema; validator and gate mutants; frozen identifiers
# (reason ids, error codes, sources and capability names only grow); CLI behaviour;
# core lint and its plant; no Linux dependency; man pages; install layout.
#
# Every check prints "ok" or "FAIL"; the exit status is the number of failures.
# Run: sh tests/libnvrm_test.sh        (OGKM=... to point at the NVIDIA headers)

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$HERE/.." && pwd)
GB10=${GB10_WORK:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)/work}
TAG=$(awk '$1 == "ogkm_tag" { print $2 }' "$REPO/SOURCES")
OGKM=${OGKM:-$GB10/sources/open-gpu-kernel-modules-$TAG}
SYSDIR=${SYSDIR:-/usr/src/sys}
mkdir -p "$GB10/tmp" || exit 1
W=$(mktemp -d "$GB10/tmp/libnvrm-test.XXXXXXXX") || exit 1
trap 'rm -rf "$W"' EXIT INT TERM
unset NVRM_BACKEND NVRM_FAKE_PROFILE NVRM_FAKE_FAIL NVRM_TEST_SKIP NVRM_TEST_ONLY

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
# expect NAME RC WANT: rc captured by the caller on its own line before.
expect_rc() {
	if [ "$2" -eq "$3" ]; then ok "$1"; else bad "$1 (rc=$2, want $3)"; fi
}

[ -d "$OGKM/src/common/sdk/nvidia/inc" ] || {
	echo "libnvrm_test: NVIDIA headers not found at $OGKM (run scripts/fetch-sources.sh)" >&2
	exit 99
}
if [ ! -f "$SYSDIR/sys/param.h" ]; then
	bad "kernel header check: $SYSDIR is not a FreeBSD sys tree; set SYSDIR=..."
	exit 1
fi

# ---- fresh copy ----------------------------------------------------------
SRC=$W/src
mkdir -p "$SRC"
git -C "$REPO" checkout-index -a --prefix="$SRC/" >"$W/checkout.log" 2>&1
rc=$?
expect_rc "fresh copy of the staged tree" $rc 0
[ -f "$SRC/lib/libnvrm/nvrm.c" ] && [ -f "$SRC/tests/libnvrm/core_test.c" ]
rc=$?
expect_rc "the fresh copy holds the library and the tests" $rc 0
[ $rc -eq 0 ] || exit 98
L=$SRC/lib/libnvrm
T=$SRC/tests/libnvrm

# ---- toolchain -----------------------------------------------------------
ld --version 2>&1 | grep -q LLD
rc=$?
expect_rc "base ld is LLD" $rc 0

# ---- build ---------------------------------------------------------------
O=$W/obj
mkdir -p "$O/lib" "$O/info"
(cd "$L" && MAKEOBJDIR=$O/lib OGKM=$OGKM make >"$W/build-lib.log" 2>&1)
rc=$?
expect_rc "libnvrm builds (WARNS=3 -Werror)" $rc 0
(cd "$L/nvrm-info" && MAKEOBJDIR=$O/info LIBNVRM_OBJ=$O/lib make >"$W/build-info.log" 2>&1)
rc=$?
expect_rc "nvrm-info builds, schema matches the library (drift check)" $rc 0
[ $rc -eq 0 ] || sed -n 1,20p "$W/build-info.log"
readelf -p .comment "$O/lib/libnvrm.so.1" 2>/dev/null | grep -q 'Linker: LLD'
rc=$?
expect_rc "libnvrm.so.1 was linked by LLD" $rc 0
INFO=$O/info/nvrm-info
export LD_LIBRARY_PATH=$O/lib
SCHEMA=$L/schema/nvrm-info-1.schema.json
VAL="python3 -I $T/schema_validate.py $SCHEMA"

# drift mutant: change a field description in the table; the build must fail
M=$W/mut-drift
mkdir -p "$M" && cp -R "$SRC/lib" "$M/lib" && cp "$SRC/SOURCES" "$M/SOURCES"
sed -i '' 's/"PCI domain"/"PCI domain (changed)"/' "$M/lib/libnvrm/nvrm_fields.c"
grep -q "changed" "$M/lib/libnvrm/nvrm_fields.c"
rc=$?
expect_rc "drift mutant: the table edit is in place" $rc 0
mkdir -p "$W/mo-lib" "$W/mo-info"
(cd "$M/lib/libnvrm" && MAKEOBJDIR=$W/mo-lib OGKM=$OGKM make >/dev/null 2>&1)
(cd "$M/lib/libnvrm/nvrm-info" && MAKEOBJDIR=$W/mo-info LIBNVRM_OBJ=$W/mo-lib make >"$W/drift.log" 2>&1)
rc=$?
[ $rc -ne 0 ] && grep -q "schema drift" "$W/drift.log"
rc=$?
expect_rc "drift mutant: the build fails with 'schema drift'" $rc 0

# ---- unit tests with coverage ---------------------------------------------
CINC="-pthread -I$L -I$L/include -I$T -std=gnu11 -Wall -Wextra -Wno-unused-parameter -DNVRM_FAULT_INJECT -I$OGKM/src/common/sdk/nvidia/inc -I$OGKM/src/common/sdk/nvidia/inc/ctrl -I$OGKM/src/nvidia/arch/nvalloc/unix/include"
LIBSRC="$L/nvrm.c $L/nvrm_cap.c $L/nvrm_fake.c $L/nvrm_fields.c $L/nvrm_json.c $L/nvrm_names.c $L/nvrm_table.c $L/nvrm_rm.c $L/nvrm_va.c $L/nvrm_mem.c $L/nvrm_owner.c $L/nvrm_fake_mem.c $L/nvrm_rm_mem.c $L/nvrm_rm_chan.c $L/nvrm_chan.c $L/nvrm_fake_chan.c"
mkdir -p "$W/cov"
cc $CINC -fprofile-instr-generate -fcoverage-mapping -o "$W/cov/core_test" "$T/core_test.c" $LIBSRC >"$W/cc1.log" 2>&1
rc=$?
expect_rc "core_test compiles" $rc 0
cc $CINC -fprofile-instr-generate -fcoverage-mapping -o "$W/cov/rm_test" "$T/rm_test.c" $LIBSRC >"$W/cc2.log" 2>&1
rc=$?
expect_rc "rm_test compiles" $rc 0
cc $CINC -o "$W/cov/cap_test" "$T/cap_test.c" $LIBSRC >"$W/cc3.log" 2>&1
rc=$?
expect_rc "cap_test compiles" $rc 0
cc $CINC -o "$W/cov/version_test" "$T/version_test.c" >"$W/cc-version.log" 2>&1
rc=$?
expect_rc "version_test compiles" $rc 0
mkdir -p "$W/kernel-include"
ln -s "$SYSDIR/$(uname -m)/include" "$W/kernel-include/machine"
ln -s "$SYSDIR/x86/include" "$W/kernel-include/x86"
printf '%s\n' '#include <nvrm/nvrm_version.h>' | cc -D_KERNEL -nostdinc -I"$W/kernel-include" -I"$SYSDIR" -I"$L/include" -fsyntax-only -x c - >"$W/cc-version-kernel.log" 2>&1
rc=$?
expect_rc "version header compiles alone for the kernel" $rc 0
[ $rc -eq 0 ] || cat "$W/cc-version-kernel.log"
printf '%s\n' '#include <nvrm/nvrm_version.h>' | cc -I"$L/include" -fsyntax-only -x c - >"$W/cc-version-user.log" 2>&1
rc=$?
expect_rc "version header compiles alone for user space" $rc 0

# NVRM_1.0 callers: dlvsym on the built library; the 1.0 symbols return only
# the 1.0 rows, in 1.0 order (security: no row of a kind 1.0 does not know)
cc $CINC -o "$W/compat_test" "$T/compat_test.c" >"$W/cc-compat.log" 2>&1
rc=$?
expect_rc "compat_test compiles" $rc 0
"$W/compat_test" "$O/lib/libnvrm.so.1"
rc=$?
expect_rc "NVRM_1.0 field table: dlvsym returns the 1.0 rows in 1.0 order, no version rows" $rc 0
# mutant: the 1.0 accessor returns the whole table; the test must fail
M=$W/mut-compat
[ -n "$W" ] && rm -rf "$M" "$W/mo-compat"
mkdir -p "$M" && cp -R "$SRC/lib" "$M/lib" && cp "$SRC/SOURCES" "$M/SOURCES"
sed -i '' 's/^#define NVRM_NFIELDS_1_0.*/#define NVRM_NFIELDS_1_0	35/' "$M/lib/libnvrm/nvrm_internal.h"
grep -q 'NFIELDS_1_0	35' "$M/lib/libnvrm/nvrm_internal.h"
rc=$?
expect_rc "compat mutant: the edit is in place" $rc 0
mkdir -p "$W/mo-compat"
(cd "$M/lib/libnvrm" && MAKEOBJDIR=$W/mo-compat OGKM=${COMPAT_MUTANT_OGKM:-$OGKM} make >"$W/mo-compat.log" 2>&1)
rc=$?
expect_rc "compat mutant builds" $rc 0
[ -f "$W/mo-compat/libnvrm.so.1" ]
rc=$?
expect_rc "compat mutant: the library exists" $rc 0
if [ $rc -eq 0 ]; then
	"$W/compat_test" "$W/mo-compat/libnvrm.so.1" >/dev/null 2>&1
	rc=$?
	# exit 1 is a row check failing; 3 is "could not load" and is no kill
	if [ $rc -eq 1 ]; then ok "compat mutant killed: a 1.0 caller would meet the new rows"; else bad "compat mutant SURVIVED or was not run (rc=$rc)"; fi
fi
# the static archive carries no compat names
nm "$O/lib/libnvrm.a" 2>/dev/null | grep -q '_1_0'
rc=$?
expect_rc "static archive has no nvrm_info_*_1_0 symbol" $rc 1

(cd "$W/cov" && LLVM_PROFILE_FILE=core.%m.profraw ./core_test)
rc=$?
expect_rc "core_test (registry, enumeration, model, decorators, JSON, fake)" $rc 0
(cd "$W/cov" && LLVM_PROFILE_FILE=rm.%m.profraw ./rm_test)
rc=$?
expect_rc "rm_test (RM backend against the scripted kernel)" $rc 0
(cd "$W/cov" && ./cap_test)
rc=$?
expect_rc "cap_test (works in Capsicum capability mode, fake, rm and memory)" $rc 0
(cd "$W/cov" && ./version_test)
rc=$?
expect_rc "version_test (parser, banner finder and formatter)" $rc 0

cc $CINC -fprofile-instr-generate -fcoverage-mapping -o "$W/cov/mem_test" "$T/mem_test.c" $LIBSRC >"$W/cc4.log" 2>&1
rc=$?
expect_rc "mem_test compiles" $rc 0
cc $CINC -fprofile-instr-generate -fcoverage-mapping -o "$W/cov/rm_mem_test" "$T/rm_mem_test.c" $LIBSRC >"$W/cc5.log" 2>&1
rc=$?
expect_rc "rm_mem_test compiles" $rc 0
cc $CINC -Werror -fprofile-instr-generate -fcoverage-mapping -o "$W/cov/chan_test" "$T/chan_test.c" $LIBSRC >"$W/cc6.log" 2>&1
rc=$?
expect_rc "chan_test compiles" $rc 0
(cd "$W/cov" && HOME=$W TMPDIR=$W LLVM_PROFILE_FILE=mem.%p.profraw ./mem_test >"$W/mem_test.out" 2>&1)
rc=$?
expect_rc "mem_test (VA allocator, memory core, fake software GPU)" $rc 0
[ $rc -eq 0 ] || grep '^FAIL' "$W/mem_test.out" | head -20
(cd "$W/cov" && HOME=$W TMPDIR=$W LLVM_PROFILE_FILE=rmmem.%p.profraw ./rm_mem_test >"$W/rm_mem_test.out" 2>&1)
rc=$?
expect_rc "rm_mem_test (RM memory backend against the scripted kernel)" $rc 0
[ $rc -eq 0 ] || grep '^FAIL' "$W/rm_mem_test.out" | head -20
(cd "$W/cov" && HOME=$W TMPDIR=$W LLVM_PROFILE_FILE=chan.%m.profraw ./chan_test >"$W/chan_test.out" 2>&1)
rc=$?
expect_rc "chan_test (GPFIFO core, tickets, fake semaphores, copies and faults)" $rc 0
[ $rc -eq 0 ] || grep '^FAIL' "$W/chan_test.out" | head -20
# The client's message lock: two threads make failing waits and status queries
# on one client; ThreadSanitizer must report no race.
if echo 'int main(void) { return 0; }' | cc -fsanitize=thread -x c - -o "$W/tsan_probe" >/dev/null 2>&1; then
	cc $CINC -Werror -fsanitize=thread -g -o "$W/cov/chan_tsan" "$T/chan_test.c" $LIBSRC >"$W/cc7.log" 2>&1
	rc=$?
	expect_rc "chan_test compiles with ThreadSanitizer" $rc 0
	(cd "$W/cov" && NVRM_TEST_ONLY=errmsg_race HOME=$W TMPDIR=$W ./chan_tsan >"$W/tsan.out" 2>&1)
	rc=$?
	expect_rc "errmsg_race under ThreadSanitizer: the test passes" $rc 0
	! grep -q 'ThreadSanitizer' "$W/tsan.out"
	rc=$?
	expect_rc "errmsg_race under ThreadSanitizer: no data race is reported" $rc 0
else
	ok "ThreadSanitizer is not available with this compiler: the errmsg_race run is skipped"
fi

cc $CINC -o "$W/cov/info_test" "$T/info_test.c" $LIBSRC >"$W/cc-info.log" 2>&1
rc=$?
expect_rc "scripted nvrm-info test compiles" $rc 0
[ $rc -eq 0 ] || cat "$W/cc-info.log"
"$W/cov/info_test" query-fail >"$W/info-query-fail.txt"
rc=$?
expect_rc "scripted nvrm-info runs with a failed RM version query" $rc 0
grep -Fq 'RM API version unknown (the system call to the driver failed)' "$W/info-query-fail.txt"
rc=$?
expect_rc "text mode explains an unavailable RM API version" $rc 0
"$W/cov/info_test" inconsistent >"$W/info-inconsistent.txt"
rc=$?
expect_rc "scripted nvrm-info runs with inconsistent version sysctls" $rc 0
grep -Fq 'running RM unknown (the kernel module version sysctls disagree with its version string)' "$W/info-inconsistent.txt"
rc=$?
expect_rc "text mode explains the inconsistent running version" $rc 0
"$W/cov/info_test" sparse >"$W/info-sparse.txt"
rc=$?
expect_rc "scripted nvrm-info runs with unavailable per-GPU versions" $rc 0
grep -Eq 'vbios +unavailable: the RM control returned an error$' "$W/info-sparse.txt" && grep -Eq 'gsp_firmware +unavailable: the RM reports the control is not supported on this GPU$' "$W/info-sparse.txt" && ! grep -Eq '(vbios|gsp_firmware) +unknown' "$W/info-sparse.txt"
rc=$?
expect_rc "text mode explains unavailable per-GPU versions with reason text" $rc 0
"$W/cov/info_test" default --json >"$W/info-scripted.json"
"$W/cov/info_test" default >"$W/info-scripted.txt"
python3 -I - "$W/info-scripted.json" "$W/info-scripted.txt" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
line = "schema version " + doc["versions"]["schema"]["string"]
assert line in open(sys.argv[2]).read().splitlines(), line
PY
rc=$?
expect_rc "text schema version equals versions.schema.string" $rc 0
MD=$W/mutsrc.schema-text-source
mkdir -p "$MD"
cp "$L"/*.c "$L"/*.h "$MD"/
cp -R "$L/include" "$MD/include"
cp "$L/nvrm-info/nvrm-info.c" "$MD/nvrm-info.c"
sed -i '' 's/text_version(nvrm_schema_version());/printf("0.0");/' "$MD/nvrm-info.c"
if cmp -s "$MD/nvrm-info.c" "$L/nvrm-info/nvrm-info.c"; then
	bad "mutant schema-text-source: the edit did not apply"
else
	MUTSRC="$MD/nvrm.c $MD/nvrm_cap.c $MD/nvrm_fake.c $MD/nvrm_fields.c $MD/nvrm_json.c $MD/nvrm_names.c $MD/nvrm_table.c $MD/nvrm_rm.c $MD/nvrm_va.c $MD/nvrm_mem.c $MD/nvrm_owner.c $MD/nvrm_fake_mem.c $MD/nvrm_rm_mem.c $MD/nvrm_rm_chan.c $MD/nvrm_chan.c $MD/nvrm_fake_chan.c"
	cc -pthread -I"$MD" -I"$MD/include" -I"$T" -std=gnu11 -w -DNVRM_FAULT_INJECT "-DNVRM_INFO_SOURCE=\"$MD/nvrm-info.c\"" -I$OGKM/src/common/sdk/nvidia/inc -I$OGKM/src/common/sdk/nvidia/inc/ctrl -I$OGKM/src/nvidia/arch/nvalloc/unix/include -o "$MD/t" "$T/info_test.c" $MUTSRC >"$MD/cc.log" 2>&1
	rc=$?
	if [ $rc -ne 0 ]; then
		bad "mutant schema-text-source: does not compile"
	else
		"$MD/t" default --json >"$MD/out.json"
		"$MD/t" default >"$MD/out.txt"
		python3 -I - "$MD/out.json" "$MD/out.txt" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
line = "schema version " + doc["versions"]["schema"]["string"]
assert line in open(sys.argv[2]).read().splitlines(), line
PY
		rc=$?
		if [ $rc -ne 0 ]; then ok "mutant killed: schema-text-source"; else bad "mutant SURVIVED: schema-text-source"; fi
	fi
fi

SYSDIR="$W/no-such-sys" sh "$SRC/tests/libnvrm_test.sh" >"$W/invalid-sysdir.log" 2>&1
rc=$?
expect_rc "an invalid SYSDIR fails the kernel header check" $rc 1
grep -Fq "FAIL kernel header check: $W/no-such-sys is not a FreeBSD sys tree; set SYSDIR=..." "$W/invalid-sysdir.log"
rc=$?
expect_rc "an invalid SYSDIR diagnostic says how to set the sys tree" $rc 0

# The discovery files carry a few helpers of the memory calls (the Capsicum
# limit of a spare, the fake GPU's identity, the RM system call table), so
# their gate counts the discovery tests and the memory tests together.
(cd "$W/cov" && llvm-profdata merge -o core.profdata core.*.profraw mem.*.profraw && llvm-profdata merge -o rm.profdata rm.*.profraw rmmem.*.profraw)
GATED="nvrm.c nvrm_cap.c nvrm_fake.c nvrm_fields.c nvrm_json.c nvrm_names.c"
(cd "$W/cov" && llvm-cov export ./core_test -object ./mem_test -instr-profile=core.profdata --summary-only $L/nvrm.c $L/nvrm_cap.c $L/nvrm_fake.c $L/nvrm_fields.c $L/nvrm_json.c $L/nvrm_names.c | python3 -I "$T/coverage_gate.py" $GATED)
rc=$?
expect_rc "core + fake backend: 100% line and branch coverage" $rc 0
(cd "$W/cov" && llvm-cov export ./rm_test -object ./rm_mem_test -instr-profile=rm.profdata --summary-only $L/nvrm_rm.c | python3 -I "$T/coverage_gate.py" nvrm_rm.c)
rc=$?
expect_rc "RM backend: 100% line and branch coverage by the scripted kernel" $rc 0
# the memory gate counts mem_test alone: channel tests must not hide a gap
(cd "$W/cov" && llvm-profdata merge -o mem.profdata mem.*.profraw && llvm-profdata merge -o rmmem.profdata rmmem.*.profraw)
(cd "$W/cov" && llvm-cov export ./mem_test -instr-profile=mem.profdata --summary-only $L/nvrm_va.c $L/nvrm_mem.c $L/nvrm_owner.c $L/nvrm_fake_mem.c | python3 -I "$T/coverage_gate.py" nvrm_va.c nvrm_mem.c nvrm_owner.c nvrm_fake_mem.c)
rc=$?
expect_rc "memory core, VA allocator and fake memory model: 100% line and branch coverage" $rc 0
(cd "$W/cov" && llvm-cov export ./rm_mem_test -instr-profile=rmmem.profdata --summary-only $L/nvrm_rm_mem.c $L/nvrm_rm_chan.c | python3 -I "$T/coverage_gate.py" nvrm_rm_mem.c nvrm_rm_chan.c)
rc=$?
expect_rc "RM memory backend and RM channel backend: 100% line and branch coverage by the scripted kernel" $rc 0
(cd "$W/cov" && llvm-profdata merge -o chan.profdata chan.*.profraw && llvm-cov export ./chan_test -instr-profile=chan.profdata --summary-only $L/nvrm_chan.c $L/nvrm_fake_chan.c | python3 -I "$T/coverage_gate.py" nvrm_chan.c nvrm_fake_chan.c)
rc=$?
expect_rc "channel core and fake GPFIFO: 100% line and branch coverage" $rc 0
# gate plant: skipping the release tests must drop the memory core below 100%
(cd "$W/cov" && NVRM_TEST_SKIP=release HOME=$W TMPDIR=$W LLVM_PROFILE_FILE=mskip.profraw ./mem_test >/dev/null 2>&1; llvm-profdata merge -o mskip.profdata mskip.profraw && llvm-cov export ./mem_test -instr-profile=mskip.profdata --summary-only $L/nvrm_mem.c | python3 -I "$T/coverage_gate.py" nvrm_mem.c >"$W/mplant.out" 2>&1)
rc=$?
if [ $rc -eq 1 ] && grep -q 'BELOW 100%' "$W/mplant.out"; then ok "coverage gate plant: skipping the release tests fails the memory gate"; else bad "coverage gate plant (memory): not the gate's verdict (rc=$rc)"; fi

# gate plant: a skipped test group must drop coverage and fail the gate
(cd "$W/cov" && NVRM_TEST_SKIP=decorators LLVM_PROFILE_FILE=skip.%m.profraw ./core_test >/dev/null && llvm-profdata merge -o skip.profdata skip.*.profraw && llvm-cov export ./core_test -instr-profile=skip.profdata --summary-only $L/nvrm.c | python3 -I "$T/coverage_gate.py" nvrm.c >"$W/plant.out" 2>&1)
rc=$?
if [ $rc -eq 1 ] && grep -q 'BELOW 100%' "$W/plant.out"; then ok "coverage gate plant: skipping the decorator tests fails the gate (BELOW 100%)"; else bad "coverage gate plant: not the gate's verdict (rc=$rc): $(cat "$W/plant.out")"; fi

# test runner: a group that matches nothing fails the run (both binaries), and
# an entry that later ones depend on runs whatever is skipped
for t in mem_test core_test; do
	(cd "$W/cov" && NVRM_TEST_ONLY=nosuch HOME=$W TMPDIR=$W ./$t >"$W/only-$t.out" 2>&1)
	rc=$?
	if [ $rc -ne 0 ] && grep -q 'NVRM_TEST_ONLY=nosuch names no group; groups: ' "$W/only-$t.out"; then ok "$t: NVRM_TEST_ONLY with an unknown group fails and lists the groups"; else bad "$t: NVRM_TEST_ONLY=nosuch did not fail with the group list (rc=$rc)"; fi
	(cd "$W/cov" && NVRM_TEST_SKIP=nosuch HOME=$W TMPDIR=$W ./$t >"$W/skip-$t.out" 2>&1)
	rc=$?
	if [ $rc -ne 0 ] && grep -q 'NVRM_TEST_SKIP=nosuch names no group' "$W/skip-$t.out"; then ok "$t: NVRM_TEST_SKIP with an unknown group fails"; else bad "$t: NVRM_TEST_SKIP=nosuch did not fail (rc=$rc)"; fi
done
(cd "$W/cov" && ./core_test >"$W/core-all.out" 2>&1; NVRM_TEST_SKIP=boot ./core_test >"$W/core-skipboot.out" 2>&1)
rc=$?
if [ $rc -eq 0 ] && tail -2 "$W/core-skipboot.out" | head -1 | grep -Eq '^subset run: ([0-9]+) of \1 entries ran$' && [ "$(tail -1 "$W/core-skipboot.out")" = "$(tail -1 "$W/core-all.out")" ]; then ok "core_test: NVRM_TEST_SKIP=boot still runs boot (required) and says how many entries ran"; else bad "core_test: NVRM_TEST_SKIP=boot changed what ran: $(tail -2 "$W/core-skipboot.out")"; fi

# ---- source mutants: a wrong core must make a test fail ----------------------
mutant() {	# mutant NAME FILE SED-EXPR TEST(core_test|rm_test|version_test)
	MD=$W/mutsrc.$1
	rm -rf "$MD"; mkdir -p "$MD"; cp "$L"/*.c "$L"/*.h "$MD"/; cp -R "$L/include" "$MD/include"
	sed -i '' "$3" "$MD/$2"
	if cmp -s "$MD/$2" "$L/$2"; then bad "mutant $1: the edit did not apply"; return; fi
	MUTSRC="$MD/nvrm.c $MD/nvrm_cap.c $MD/nvrm_fake.c $MD/nvrm_fields.c $MD/nvrm_json.c $MD/nvrm_names.c $MD/nvrm_table.c $MD/nvrm_rm.c $MD/nvrm_va.c $MD/nvrm_mem.c $MD/nvrm_owner.c $MD/nvrm_fake_mem.c $MD/nvrm_rm_mem.c $MD/nvrm_rm_chan.c $MD/nvrm_chan.c $MD/nvrm_fake_chan.c"
	if [ "$4" = version_test ]; then MUTSRC=; fi
	cc -pthread -I"$MD" -I"$MD/include" -I"$T" -std=gnu11 -w -DNVRM_FAULT_INJECT -I$OGKM/src/common/sdk/nvidia/inc -I$OGKM/src/common/sdk/nvidia/inc/ctrl -I$OGKM/src/nvidia/arch/nvalloc/unix/include -o "$MD/t" "$T/$4.c" $MUTSRC >"$MD/cc.log" 2>&1 || { bad "mutant $1: does not compile"; return; }
	"$MD/t" >/dev/null 2>&1
	if [ $? -ne 0 ]; then ok "mutant killed: $1"; else bad "mutant SURVIVED: $1"; fi
}
mutant dup-appended-row nvrm_fields.c 's/F("versions", gsp_firmware, NVRM_K_VERSION, "GSP firmware version"),/&	F("versions", gsp_firmware, NVRM_K_VERSION, "GSP firmware version"),/' core_test
mutant nfields-1-0-low nvrm_internal.h 's/^#define NVRM_NFIELDS_1_0.*/#define NVRM_NFIELDS_1_0	29/' core_test
mutant sm-shift nvrm.c 's/>>= 8;/>>= 7;/' core_test
mutant sm-mask nvrm.c 's/&= 0xff;/\&= 0x7f;/' core_test
mutant compute-table-minor nvrm_table.c 's/{ 0x1b0, 0x06, 12, 0 }/{ 0x1b0, 0x06, 12, 1 }/' core_test
mutant compute-raw-fallback nvrm.c 's/unavail(&info->compute_capability_minor, reason, NVRM_S_DERIVED);/if (reason == NVRM_R_FAMILY_UNKNOWN) { avail(\&info->compute_capability_major, raw_sm.value >> 8, NVRM_S_DERIVED); avail(\&info->compute_capability_minor, raw_sm.value \& 0xff, NVRM_S_DERIVED); } else unavail(\&info->compute_capability_minor, reason, NVRM_S_DERIVED);/' core_test
mutant version-overflow include/nvrm/nvrm_version.h 's/value > (UINT32_MAX - (uint32_t)d) \/ base/0/' version_test
mutant version-width include/nvrm/nvrm_version.h 's/out->width\[out->nparts\] = (uint8_t)width/out->width[out->nparts] = 1/' version_test
mutant version-suffix include/nvrm/nvrm_version.h 's/if (\*p == .-. || \*p == .+.) {/if (0) {/' version_test
mutant version-banner-parts include/nvrm/nvrm_version.h 's/out->nparts >= 2/out->nparts >= 1/' version_test
mutant version-long-input include/nvrm/nvrm_version.h 's/if (s\[i\] != .\\0. || (base != 10/if (0 || (base != 10/' version_test
mutant vbios-byte-order nvrm_rm.c 's/(revision >> 24) & 0xff/revision \& 0xff/' rm_test
mutant vbios-base10 nvrm.c 's/NVRM_SP_VBIOS, 16/NVRM_SP_VBIOS, 10/' core_test
mutant gsp-bvalid nvrm_rm.c 's/if (!gsp.bValid)/if (0)/' rm_test
mutant vram-scale nvrm.c 's/NVRM_P_VRAM_KB, 0, 1024)/NVRM_P_VRAM_KB, 0, 1000)/' core_test
mutant chip-id nvrm.c 's/info->architecture.value +/info->architecture.value |/' core_test
mutant sm-count nvrm.c 's/tpcs \* per_tpc/tpcs + per_tpc/' core_test
mutant tpc-popcount nvrm.c 's/tpcs += __builtin_popcountll(tpc_mask)/tpcs += 1/' core_test
mutant family-order nvrm.c 's/if (gpfifo \&\& compute)/if (gpfifo || compute)/' core_test
mutant page-cap nvrm.c 's/fam->page_sizes\[i\] <= info->max_page_size.value/fam->page_sizes[i] >= info->max_page_size.value/' core_test
mutant decorator-source nvrm.c 's/d->caps\[i\].value != 0, NVRM_S_BOARD/d->caps[i].value != 0, NVRM_S_RM/' core_test
mutant decorator-vendor nvrm.c 's/d->subsystem_vendor != info->pci_subsystem_vendor.value ||/0 ||/' core_test
mutant unavail-value nvrm.c 's/f->value = 0;/f->value = 1;/' core_test
mutant unavail-reason nvrm.c 's/f->reason = reason;/f->reason = 0;/' core_test
mutant issetugid nvrm.c 's/if (!tainted)/if (1)/' core_test
mutant json-available nvrm_json.c 's/"available\\":true,\\"value\\":%ju/"available\\":false,\\"value\\":%ju/' core_test
mutant cap-rights nvrm_cap.c 's/CAP_IOCTL, CAP_EVENT/CAP_IOCTL, CAP_EVENT, CAP_MMAP_RW/' cap_test
mutant rm-subsys nvrm_rm.c 's/b.pciSubSystemId \& 0xffff;/b.pciSubSystemId >> 16;/' rm_test
mutant rm-bar1 nvrm_rm.c 's/NV2080_CTRL_FB_INFO_INDEX_BAR1_SIZE/NV2080_CTRL_FB_INFO_INDEX_RAM_SIZE/' rm_test
mutant rm-strict nvrm_rm.c 's/NV_RM_API_VERSION_CMD_STRICT/NV_RM_API_VERSION_CMD_RELAXED/' rm_test
mutant rm-order nvrm_rm_priv.h 's/NV_ESC_CHECK_VERSION_STR, \\/NV_ESC_CARD_INFO, \\/' rm_test
mutant rm-device nvrm_rm.c 's/rm_alloc(be, g->device, \&g->subdevice/rm_alloc(be, be->client, \&g->subdevice/' rm_test
mutant rm-reply nvrm_rm.c 's/v.reply != NV_RM_API_VERSION_REPLY_RECOGNIZED/0/' rm_test
mutant rm-pci-check nvrm_rm.c 's/(b.pciDeviceId \& 0xffff) != g->card.pci_info.vendor_id/0/' rm_test
mutant rm-classes-max nvrm_rm.c 's/lim = max < /lim = 1000 < /' rm_test
mutant json-comma nvrm_json.c 's/k++ != 0 ? "," : ""/i != 0 ? "," : ""/' core_test
mutant decorator-bound nvrm.c 's/if ((unsigned)d->caps\[i\].index >= NVRM_NCAPS)/if (0)/' core_test
mutant refresh-status nvrm.c 's/NVRM_E_IO : NVRM_OK/NVRM_OK : NVRM_OK/' core_test
mutant rm-least-privilege nvrm_rm.c 's/if (!allow_alloc)/if (0)/' cap_test
mutant opts-default nvrm.c 's/(opts->flags \& NVRM_ENUM_ALLOW_ALLOC) != 0);/1);/' cap_test
mutant opts-null nvrm.c 's/rc = ops->limit(ctx->be, opts != NULL \&\&$/rc = ops->limit(ctx->be, 1 ||/' cap_test
mutant struct-member include/nvrm/nvrm.h 's/nvrm_u64	vram_size, bar1_size/nvrm_u64	l2_size, vram_size, bar1_size/' core_test
mutant fake-str-swap nvrm_fake.c '/case NVRM_SP_VBIOS:/,/break;/s/g->p->vbios/g->p->gsp_firmware/' core_test
mutant fields-bound nvrm_fields.c 's/index < nvrm_nfields ?/1 ?/' core_test
mutant fields-abort nvrm_fields.c 's/abort();/return (NULL);/' core_test
mutant family-no-value nvrm.c 's/NVRM_R_FAMILY_NO_CLASS, NVRM_S_FAMILY/NVRM_R_FAMILY_UNKNOWN, NVRM_S_FAMILY/' core_test
mutant pci-unusable nvrm_rm.c 's/return (NVRM_R_VALUE_UNUSABLE);/return (NVRM_R_RM_FAILED);/' rm_test
mutant rm-pci-nocard nvrm_rm.c 's/if (!g->have_card)/if (0)/' rm_test
mutant gpc-width nvrm.c 's/(mask >> NVRM_MAX_GPCS) != 0/0/' core_test
mutant enumerate-call-failure nvrm.c 's/if (info_has_call_failure(&ctx->dev\[i\].info))/if (0)/' core_test
mutant rm-version-errno nvrm_rm.c 's/rc != 0 \&\& errno != EINVAL/0/' rm_test
# memory and VA: each rule has a mutant that one of the memory tests kills
mutant owner-core nvrm_mem.c '/^nvrm_mem_alloc/,/^}/s/	rc = owner_check(cl);/	rc = NVRM_OK;/' mem_test
mutant owner-skip-release nvrm_mem.c '/^nvrm_mem_free/,/^}/s/nvrm_owner_is_me(\&cl->owner)/1/' mem_test
mutant owner-flag-gmap nvrm_mem.c '/^gmap_drop/,/^}/s/nvrm_owner_is_me(\&cl->owner)/1/' mem_test
mutant owner-flag-cpu nvrm_mem.c '/^cpu_drop/,/^}/s/nvrm_owner_is_me(\&cl->owner)/1/' rm_mem_test
mutant owner-flag-va nvrm_mem.c '/^nvrm_va_release/,/^}/s/r->b, nvrm_owner_is_me(\&cl->owner)/r->b, 1/' rm_mem_test
mutant owner-flag-close nvrm_mem.c '/^nvrm_client_close/,/^}/s/nvrm_owner_is_me(\&cl->owner)/1/' rm_mem_test
mutant rm-free-owner nvrm_rm_mem.c '/^free_object/,/^}/s/if (!owner)/if (0)/' rm_mem_test
mutant rm-unmap-local nvrm_rm_mem.c '/^rmm_unmap_cpu/,/^}/s/munmap(addr, m->bytes);/if (owner) munmap(addr, m->bytes);/' rm_mem_test
mutant va-merge nvrm_va.c 's/prev->end == addr/0/' mem_test
mutant attr-uncached nvrm_mem.c 's/return (NVRM_ATTR_DEVICE);$/return (NVRM_ATTR_CACHED);/' mem_test
mutant attr-arm64 nvrm_mem.c 's/if (!host_arm64)/if (1)/' mem_test
mutant overlap nvrm_mem.c 's/if (overlaps(cl, p->va, len))/if (0)/' mem_test
mutant allow-map nvrm_mem.c 's/if (!cl->allow_map)/if (0)/' mem_test
mutant busy-reserve nvrm_mem.c 's/if (r->nmaps != 0)/if (0)/' mem_test
mutant release-retry nvrm_mem.c 's/	if (rc != NVRM_OK \&\& keep)/	if (0)/' mem_test
mutant release-orphan nvrm_mem.c 's/		g->mem = NULL;/		g->mem = g->mem;/' mem_test
mutant release-count nvrm_mem.c 's/cl->st.failed_releases++;/;/' mem_test
mutant default-page nvrm_mem.c 's/return (65536);/return (MIN_PAGE);/' mem_test
mutant device-width nvrm_mem.c 's/while (w > len || ((uintptr_t)p \& (w - 1)) != 0)/while (w > len)/' mem_test
mutant size-zero nvrm_mem.c 's/return (size == 0 || size == want);/return (size == want);/' mem_test
mutant fake-sparse nvrm_fake_mem.c 's/memset(p, 0, n);/(void)0;/' mem_test
mutant fake-exported nvrm_fake_mem.c 's/ || !o->exported//' mem_test
mutant fake-spare-limit nvrm_fake_mem.c 's/export_spare_limit(\*fd) :/NVRM_OK :/' mem_test
mutant fake-host-page nvrm_fake_mem.c 's/		align = host;/		;/' mem_test
mutant fake-obj-leak nvrm_fake_mem.c '/^fk_mem_free/,/^}/s/		obj_unref(m->o);//' mem_test
mutant rm-unmap-status nvrm_rm_mem.c 's/	return (p.status == NV_OK ? NVRM_OK : nvrm_rmm_status_fail(err, errlen,$/	return (1 ? NVRM_OK : nvrm_rmm_status_fail(err, errlen,/' rm_mem_test
mutant rm-page-writeback nvrm_rm_mem.c 's/out->page_size = got;/out->page_size = a->page_size;/' rm_mem_test
mutant wb-default nvrm_rm_mem.c 's/got = ps.bytes;/got = a->page_size;/' rm_mem_test
mutant rm-import-page nvrm_rm_mem.c 's/ps->bytes = p.pageSize;/ps->bytes = 0;/' rm_mem_test
mutant rm-import-no-query nvrm_rm_mem.c 's/if (st == NV_ERR_NOT_SUPPORTED)/if (0)/' rm_mem_test
mutant rm-import-page-known nvrm_rm_mem.c 's/if (!page_size_known(ps->bytes))/if (0)/' rm_mem_test
mutant chan-usermode-ctl nvrm_rm_chan.c 's/desc_open(c, NVRM_DESC_MAP, &c->usermode_fd/desc_open(c, NVRM_DESC_MAP_CTL, \&c->usermode_fd/' rm_mem_test
mutant chan-no-name nvrm_rm_chan.c 's/snprintf(err, errlen, "%s: %s", what, detail);/snprintf(err, errlen, "%s", detail);/' rm_mem_test
mutant chan-free-label nvrm_rm_chan.c 's/snprintf(what, sizeof(what), "free %s", name);/snprintf(what, sizeof(what), "unmap %s", name);/' rm_mem_test
mutant rm-huge-import nvrm_rm_mem.c 's/		\*ps = 2097152;/		*ps = 536870912;/' rm_mem_test
mutant rm-coherency nvrm_rm_mem.c 's/		return (NVRM_COH_WC);/		return (NVRM_COH_CACHED);/' rm_mem_test
mutant rm-va-end nvrm_rm_mem.c 's/va->end = vp.vaSize;/va->end = vp.vaBase + vp.vaSize;/' rm_mem_test
mutant rm-session-map nvrm_rm_mem.c 's/(allow_map ? 0 : SESSION_CPU_MAP)/0/' rm_mem_test
mutant rm-snoop nvrm_rm_mem.c 's/_CACHE_SNOOP, _ENABLE) : 0);/_CACHE_SNOOP, _ENABLE) : DRF_DEF(OS46, _FLAGS, _CACHE_SNOOP, _ENABLE));/' rm_mem_test
mutant rm-close-sweep nvrm_rm_mem.c '/^rmm_client_close/,/^}/s/		free(r);//' rm_mem_test
mutant rm-alloc-unknown-page nvrm_rm_mem.c 's/	if (ps.bytes == 0) {$/	if (0) {/' rm_mem_test
mutant rm-node nvrm_rm_mem.c 's/DEVICE_PATH_FMT, c->minor);/DEVICE_PATH_FMT, 0);/' rm_mem_test
mutant fake-orphan-mark nvrm_fake_mem.c 's/			m->o->orphans++;/			(void)0;/' mem_test
mutant fake-map-user nvrm_fake_mem.c 's/	return (g->wrapper == m->serial);/	return (g->o == m->o \&\& g->user == m->user);/' mem_test
mutant fake-leak-count nvrm_fake_mem.c 's/	leaked_objects += o->orphans < o->refs;/	(void)0;/' mem_test
mutant rm-give-back nvrm_rm_mem.c '/^give_back/,/^}/s/	(void)nvrm_rm_free(c->s, c->device, m->h);//' rm_mem_test
mutant rm-writeback-text nvrm_rm_mem.c 's/(uintmax_t)(a->page_size >> 10));/(uintmax_t)(a->page_size >> 11));/' rm_mem_test
mutant rm-leak nvrm_rm.c 's/		nvrm_rm_free(g->be, g->device, g->subdevice);//' rm_test
# merge-review fixes (Opus A R1 R6, Opus B 1-10): each has a mutant that must die
mutant ada-copy nvrm_table.c 's/0xC997, 0xC7B5,/0xC997, 0,/' core_test
mutant ada-copy-wrong nvrm_table.c 's/0xC997, 0xC7B5,/0xC997, 0xC6B5,/' core_test
mutant unknown-gpfifo nvrm.c 's/unavail(&info->cls_gpfifo, reason, NVRM_S_FAMILY);/unavail(\&info->cls_gpfifo, NVRM_R_INPUT_MISSING, NVRM_S_FAMILY);/' core_test
mutant unknown-compute nvrm.c 's/unavail(&info->cls_compute, reason, NVRM_S_FAMILY);/unavail(\&info->cls_compute, NVRM_R_INPUT_MISSING, NVRM_S_FAMILY);/' core_test
mutant unknown-eng3d nvrm.c 's/unavail(&info->cls_eng3d, reason, NVRM_S_FAMILY);/unavail(\&info->cls_eng3d, NVRM_R_INPUT_MISSING, NVRM_S_FAMILY);/' core_test
mutant unknown-copy nvrm.c 's/unavail(&info->cls_copy, reason, NVRM_S_FAMILY);/unavail(\&info->cls_copy, NVRM_R_INPUT_MISSING, NVRM_S_FAMILY);/' core_test
mutant unknown-family-reason nvrm.c 's/reason = NVRM_R_FAMILY_UNKNOWN;/reason = NVRM_R_INPUT_MISSING;/' core_test
mutant unknown-family-name nvrm.c 's/info->family.reason = reason;/info->family.reason = NVRM_R_INPUT_MISSING;/' core_test
mutant cap-name-1 nvrm_names.c 's/^	"ats",/	"ats_x",/' core_test
mutant cap-name-6 nvrm_names.c 's/^	"os_device_wc_active",/	"os_wc",/' core_test
mutant cap-dup-0 nvrm_names.c 's/^	"dmabuf_export",/	"ats",/' core_test
mutant member-after-caps include/nvrm/nvrm.h 's/^	unsigned	ndecorators;/	nvrm_u64	l2_size;\
	unsigned	ndecorators;/' core_test
mutant member-after-decorators include/nvrm/nvrm.h 's/^	const char	\*decorators\[NVRM_MAX_DECORATORS\];/&\
	nvrm_u64	l2_size;/' core_test
mutant source-rm-gpu-id nvrm.c 's/\[NVRM_P_RM_GPU_ID\] = NVRM_S_RM,/[NVRM_P_RM_GPU_ID] = NVRM_S_OS,/' core_test
mutant source-subsystem nvrm.c 's/\[NVRM_P_PCI_SUBSYSTEM_VENDOR\] = NVRM_S_RM,/[NVRM_P_PCI_SUBSYSTEM_VENDOR] = NVRM_S_OS,/' core_test
mutant source-cap-os nvrm.c 's/\[NVRM_P_CAP_OS_DEVICE_WC\] = NVRM_S_OS,/[NVRM_P_CAP_OS_DEVICE_WC] = NVRM_S_RM,/' core_test
mutant source-derived nvrm.c 's/info->implementation.value, NVRM_S_DERIVED);/info->implementation.value, NVRM_S_RM);/' core_test
mutant registry-once nvrm.c '/^nvrm_backend_select/,/^}/s/pthread_once(&builtins_once, register_builtins);/if (nregistered == 0) register_builtins();/' core_test
mutant fork-guard nvrm_owner.c 's/return (my_pid() == o->pid \&\& fork_generation == o->generation);/return (1);/' rm_test
mutant fork-generation nvrm_owner.c 's/fork_generation++;/;/' rm_test
mutant fork-pid-only nvrm_owner.c 's/ \&\& fork_generation == o->generation//' rm_test
mutant fork-generation-open nvrm_owner.c 's/o->generation = fork_generation;/o->generation = fork_generation + 1;/' rm_test
mutant fd-leak-version nvrm_rm.c '/NVRM_RM_VERSION, NVRM_RM_VERSION);/,/NVRM_E_VERSION/s/sys->close(be->fd);//' rm_test
mutant fork-guard-gpu nvrm_rm.c 's/	if (nvrm_rm_owner(g->be)) {/	if (1) {/' rm_test
mutant fork-guard-pid nvrm_owner.c 's/o->pid = my_pid();/o->pid = 0;/' rm_test
mutant nogpu-error nvrm.c 's|/\* No GPU is a result, not an error: the context holds zero devices. \*/|if (rc == NVRM_OK \&\& n == 0) rc = NVRM_E_NODEV;|' core_test
# channels: every rule has a focused mutant
mutant chan-capacity nvrm_chan.c 's/return (ch->entries - 2 - pending);/return (ch->entries - 1 - pending);/' chan_test
mutant chan-incomplete-split nvrm_chan.c 's/unit = unit_len(e, n, pos + len);/unit = 1;/' chan_test
mutant chan-ticket-order nvrm_chan.c 's/if (ch->q_head != \&sc->w) {/if (0) {/' chan_test
mutant chan-queued-deadline nvrm_chan.c '/^wait_turn/,/^}/s/if (deadline_reached(deadline))/if (0)/' chan_test
mutant chan-turn-broadcast nvrm_chan.c 's/(void)pthread_cond_broadcast(\&ch->turn);//' chan_test
mutant chan-flush-order nvrm_chan.c 's/nvrm_barrier_normal();/ch->cl->ops->chan->gp_put(ch->b, put);/' chan_test
mutant chan-release-wfi nvrm_methods.h 's/NVRM_SEM_RELEASE | NVRM_SEM_WFI | NVRM_SEM_PAYLOAD_64/NVRM_SEM_RELEASE | NVRM_SEM_PAYLOAD_64/' chan_test
mutant chan-payload-64 nvrm_methods.h 's/NVRM_SEM_RELEASE | NVRM_SEM_WFI | NVRM_SEM_PAYLOAD_64/NVRM_SEM_RELEASE | NVRM_SEM_WFI/' chan_test
mutant chan-dead-only-own nvrm_fake_chan.c 's/if (b->error == 0) {/for (b = channels; b != NULL; b = b->next) if (b->error == 0) {/' chan_test
mutant chan-acq-geq nvrm_fake_chan.c 's/(int64_t)(value - payload) < 0/(int64_t)(value - payload) <= 0/' chan_test
mutant chan-copy-on-graphics nvrm_chan.c 's/if (ch->runlist == NVRM_RUNLIST_GRAPHICS \&\&/if (0 \&\&/' chan_test
# review round 1: the wire encoding, the kick before a space wait, fork children,
# the semaphore sanity check, a refused destroy, wakeups, deadlines and grants
mutant chan-addr-lo-encoding nvrm_methods.h 's/seg\[1\] = (uint32_t)sem_va \& 0xfffffffcU;/seg[1] = (uint32_t)((sem_va >> 2) \& 0x3fffffffU);/' chan_test
mutant chan-no-kick-before-wait nvrm_chan.c '/^submit_step/,/^}/s/if (ch->kick_pending) {/if (0) {/' chan_test
mutant chan-fork-refresh nvrm_chan.c '/^refresh_all/,/^}/s/if (!nvrm_owner_is_me(\&ch->cl->owner))/if (0)/' chan_test
mutant chan-no-sem-check nvrm_chan.c '/^sem_update/,/^}/s/if (value > ch->submitted || value < ch->completed)/if (0)/' chan_test
mutant chan-free-on-destroy-failure nvrm_chan.c '/^nvrm_chan_destroy/,/^}/s/if (!held)/if (1)/' chan_test
mutant chan-lost-wakeup nvrm_fake_chan.c 's/if (progress_count == gen)/if (1)/' chan_test
mutant chan-sleep-past-deadline nvrm_chan.c 's/return (left < nvrm_chan_slice_ns ? left : nvrm_chan_slice_ns);/return (nvrm_chan_slice_ns);/' chan_test
mutant chan-set-object-any nvrm_fake_chan.c 's/if (data != 0 \&\& data != b->granted\[subch\]) {/if (0) {/' chan_test
mutant chan-ring-writable nvrm_chan.c 's/	    .flags = NVRM_MAP_READ_ONLY };/	    .flags = 0 };/' chan_test
mutant chan-stats-v11 nvrm_mem.c 's/if (want != sizeof(full) \&\& want != v11)/if (want != sizeof(full))/' mem_test
# the channel mutants pin: the ring space rule, the ordered submit queue, the
# release segment reuse, a refused destroy kept until close and forgotten at
# close, the fork child that makes no backend call, the fake engine running
# one process's channels only, a backend without forget refused, and the
# client stats size rule
mutant chan-segment-reuse nvrm_chan.c 's/if (ch->slot_point\[slot\] > ch->completed)/if (0)/' chan_test
mutant chan-held-forget nvrm_chan.c 's/cl->ops->chan->forget(ch->b);//' chan_test
mutant chan-foreign-run nvrm_fake_chan.c 's/if (!nvrm_owner_is_me(\&b->core->cl->owner))/if (0)/' chan_test
mutant chan-forget-required nvrm_chan.c 's/if (cl->ops->chan->destroy == NULL || cl->ops->chan->forget == NULL)/if (0)/' chan_test
mutant chan-stats-zero-size nvrm_mem.c 's/size_t want = st->size == 0 ? sizeof(full) : st->size;/size_t want = st->size == 0 ? v11 : st->size;/' mem_test

# ---- JSON modes against the schema --------------------------------------
export NVRM_BACKEND=fake
for p in discrete unified unknown sparse discrete,unified discrete,unified,unknown,sparse; do
	NVRM_FAKE_PROFILE=$p $INFO --json >"$W/out.json"
	rc=$?
	expect_rc "--json rc, profile $p" $rc 0
	$VAL "$W/out.json"
	rc=$?
	expect_rc "--json validates, profile $p" $rc 0
	NVRM_FAKE_PROFILE=$p $INFO --jsonl >"$W/out.jsonl"
	rc=$?
	expect_rc "--jsonl rc, profile $p" $rc 0
	$VAL "$W/out.jsonl"
	rc=$?
	expect_rc "--jsonl validates (header, devices, end), profile $p" $rc 0
done
# the gpu group is one JSON object per device (no duplicate key) holding the
# rows appended after 1.0, and each field is listed once per GPU in the text
NVRM_FAKE_PROFILE=discrete,unified $INFO --json >"$W/grp.json"
NVRM_FAKE_PROFILE=discrete,unified $INFO >"$W/grp.txt"
python3 -I - "$W/grp.json" "$W/grp.txt" <<'PY'
import json, sys
def no_dups(pairs):
    keys = [k for k, _ in pairs]
    assert len(keys) == len(set(keys)), keys
    return dict(pairs)
raw = open(sys.argv[1]).read()
doc = json.loads(raw, object_pairs_hook=no_dups)
assert raw.count('"gpu":{') == len(doc["devices"]) == 2, raw.count('"gpu":{')
for d in doc["devices"]:
    assert "rm_sm_version" in d["gpu"] and "compute_capability_major" in d["gpu"]
txt = open(sys.argv[2]).read().split("\n")
heads = [l for l in txt if l.startswith("GPU ")]
assert len(heads) == 2, heads
for name in ("rm_sm_version", "uuid"):
    assert sum(1 for l in txt if l.split()[:1] == [name]) == 2, name
PY
rc=$?
expect_rc "JSON: one gpu key per device with the appended rows; text: each field once per GPU" $rc 0
# --json is one line, one document
NVRM_FAKE_PROFILE=discrete,unified $INFO --json | wc -l | grep -qx ' *1'
rc=$?
expect_rc "--json is exactly one document on one line" $rc 0
NVRM_FAKE_PROFILE=discrete,unified $INFO --jsonl | wc -l | grep -qx ' *4'
rc=$?
expect_rc "--jsonl has header + 2 devices + end" $rc 0
# the schema output is valid JSON and is the committed file
$INFO --schema | cmp -s - "$SCHEMA"
rc=$?
expect_rc "--schema equals the committed schema" $rc 0
python3 -I -c 'import json,sys; json.load(open(sys.argv[1]))' "$SCHEMA"
rc=$?
expect_rc "the schema parses as JSON" $rc 0
# unavailable values are shaped, with a reason, never a fake number
NVRM_FAKE_PROFILE=sparse $INFO --json >"$W/sparse.json"
python3 -I - "$W/sparse.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))["devices"][0]
n_un = 0
for g in ("identity", "gpu", "memory"):
    for k, v in d[g].items():
        if v["available"] is False:
            n_un += 1
            assert v["reason_id"] and v["reason"], (g, k)
        else:
            assert "value" in v and "reason" not in v, (g, k)
assert n_un >= 20, n_un
assert all(not c["available"] and c["reason_id"] for c in d["capabilities"])
PY
rc=$?
expect_rc "sparse GPU: every missing value says available:false with a reason" $rc 0
NVRM_FAKE_PROFILE=unified $INFO --json | python3 -I -c "
import json,sys
d=json.load(sys.stdin)['devices'][0]
assert d['memory']['vram_size']=={'available':True,'value':0,'source':'rm'}, d['memory']['vram_size']
assert d['gpu']['chip_id']['value']==0x1bb
assert d['gpu']['sm_version_minor']['value']==1
assert [c['index'] for c in d['capabilities']]==list(range(len(d['capabilities']))) and len(d['capabilities'])>=7
"
rc=$?
expect_rc "unified GPU: VRAM is available and 0, chip 0x1bb, SM 12.1, caps indexed 0..6" $rc 0

# validator mutants: each broken document must be refused
NVRM_FAKE_PROFILE=discrete $INFO --json >"$W/good.json"
python3 -I - "$W/good.json" "$W" <<'PY'
import json, sys, copy
good = json.load(open(sys.argv[1]))
w = sys.argv[2]
def dump(name, d):
    open("%s/mut-%s.json" % (w, name), "w").write(json.dumps(d) + "\n")
m = copy.deepcopy(good); del m["devices"][0]["identity"]["uuid"]; dump("missing", m)
m = copy.deepcopy(good); m["devices"][0]["gpu"]["extra"] = 1; dump("extra", m)
m = copy.deepcopy(good); m["devices"][0]["gpu"]["sm_count"]["value"] = "36"; dump("type", m)
m = copy.deepcopy(good); m["devices"][0]["memory"]["numa_node"]["reason_id"] = "made_up"; dump("reason", m)
m = copy.deepcopy(good); m["schema"] = "nvrm-info/2"; dump("schema", m)
m = copy.deepcopy(good); m["devices"][0]["gpu"]["sm_count"]["value"] = -1; dump("negative", m)
m = copy.deepcopy(good); m["versions"]["driver"]["major"] = 4294967295; dump("max-boundary", m)
m = copy.deepcopy(good); m["versions"]["driver"]["major"] = 4294967296; dump("maximum", m)
m = copy.deepcopy(good); m["devices"][0]["capabilities"].pop(); dump("caps", m)
m = copy.deepcopy(good); m["devices"][0]["gpu"]["classes"]["value"] = ["x"]; dump("list", m)
m = copy.deepcopy(good); m["devices"][0]["memory"]["numa_node"] = {"available": True, "reason": "x"}; dump("both", m)
m = copy.deepcopy(good); m["kind"] = "bogus"; dump("kind", m)
ncap = len(good["devices"][0]["capabilities"])
for i in range(ncap):
    m = copy.deepcopy(good); m["devices"][0]["capabilities"][i]["name"] = "renamed"; dump("capname%d" % i, m)
    m = copy.deepcopy(good); m["devices"][0]["capabilities"][i]["index"] = (i + 1) % ncap; dump("capindex%d" % i, m)
m = copy.deepcopy(good); c = m["devices"][0]["capabilities"]; c[1], c[2] = c[2], c[1]; dump("capswap", m)
m = copy.deepcopy(good); m["devices"][0]["capabilities"].append(copy.deepcopy(m["devices"][0]["capabilities"][0])); dump("capmore", m)
PY
CAPMUT=
NCAP=$(python3 -I -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["devices"][0]["capabilities"]))' "$W/good.json")
i=0; while [ "$i" -lt "$NCAP" ]; do CAPMUT="$CAPMUT capname$i capindex$i"; i=$((i + 1)); done
[ "$NCAP" -ge 7 ]; rc=$?
expect_rc "validator mutants: one rename and one reindex for each of the $NCAP capability flags" $rc 0
for m in missing extra type reason schema negative maximum caps list both kind $CAPMUT capswap capmore; do
	$VAL "$W/mut-$m.json" >/dev/null
	rc=$?
	if [ $rc -eq 1 ]; then ok "validator mutant refused: $m"; else bad "validator accepted mutant $m (rc=$rc)"; fi
done
$VAL "$W/mut-max-boundary.json" >/dev/null
rc=$?
expect_rc "validator accepts the exact uint32 maximum" $rc 0

# ---- frozen identifiers: reason ids, error codes, sources, capability names ----
# The baseline file lists them; the schema may add but never remove, rename or
# renumber one.  The check also runs on the schema the BUILT tool prints, so a
# library change that the schema file does not show is still caught.
IDS=$L/schema/nvrm-info-1.ids
IDCHK="python3 -I $T/ids_check.py"
$IDCHK --strict "$SCHEMA" "$IDS"; rc=$?
expect_rc "identifiers: the schema file and the frozen baseline list the same identifiers" $rc 0
$INFO --schema >"$W/built-schema.json"
$IDCHK --strict "$W/built-schema.json" "$IDS"; rc=$?
expect_rc "identifiers: the schema the built tool prints and the frozen baseline list the same identifiers" $rc 0
# the schema minor is one number: SCHEMA_MINOR in the library, the constant in the
# schema file, the schema_minor of the output and the minor nvrm(7) names
minor_ok() {	# minor_ok DIR (nvrm_json.c, schema/, man/nvrm.7): 0 when they agree
	_m=$(sed -n 's/^#define SCHEMA_MINOR[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$1/nvrm_json.c")
	[ -n "$_m" ] || return 1
	_s=$(sed -n 's/.*"schema_minor": { "const": \([0-9]*\) }.*/\1/p' "$1/schema/nvrm-info-1.schema.json" | sort -u)
	[ "$_s" = "$_m" ] && grep -q "^minor $_m;\$" "$1/man/nvrm.7"
}
minor_ok "$L"; rc=$?
expect_rc "schema minor: SCHEMA_MINOR, the schema file and nvrm(7) agree" $rc 0
MINOR=$(sed -n 's/^#define SCHEMA_MINOR[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$L/nvrm_json.c")
NVRM_BACKEND=fake NVRM_FAKE_PROFILE=discrete $INFO --json | python3 -I -c "import json,sys; sys.exit(0 if json.load(sys.stdin)['schema_minor']==int(sys.argv[1]) else 1)" "$MINOR"; rc=$?
expect_rc "the output says schema_minor $MINOR (the library's SCHEMA_MINOR)" $rc 0
minor_plant() {	# minor_plant NAME WANT(ok|bad) [lib|schema|man]...: bump that file's minor
	_p=$W/minorplant.$1; _w=$2; shift 2; rm -rf "$_p"; mkdir -p "$_p"
	cp "$L/nvrm_json.c" "$_p/"; cp -R "$L/schema" "$L/man" "$_p/"
	_n=$((MINOR + 1))
	for _f in "$@"; do
		case $_f in
		lib) sed -i '' "s/^#define SCHEMA_MINOR\([[:space:]]*\)$MINOR/#define SCHEMA_MINOR\1$_n/" "$_p/nvrm_json.c" ;;
		schema) sed -i '' "s/\"schema_minor\": { \"const\": $MINOR }/\"schema_minor\": { \"const\": $_n }/" "$_p/schema/nvrm-info-1.schema.json" ;;
		man) sed -i '' "s/^minor $MINOR;\$/minor $_n;/" "$_p/man/nvrm.7" ;;
		esac
	done
	minor_ok "$_p"; _rc=$?
	if [ "$_w" = ok ] && [ $_rc -eq 0 ]; then ok "minor plant: $1 stays consistent"
	elif [ "$_w" = bad ] && [ $_rc -ne 0 ]; then ok "minor plant refused: $1"
	else bad "minor plant $1: wanted $_w, minor_ok gave $_rc"; fi
}
minor_plant all-three ok lib schema man
minor_plant library-only bad lib
minor_plant schema-only bad schema
minor_plant man-only bad man
minor_plant man-and-library bad lib man
# plants: each of these schemas, or baselines, must be refused
# (CUR is the schema minor now; NEXT the one an addition would raise it to)
python3 -I - "$SCHEMA" "$IDS" "$W" "$MINOR" <<'PY'
import json, sys, copy
schema = json.load(open(sys.argv[1]))
w = sys.argv[3]
CUR = int(sys.argv[4]); NEXT = CUR + 1
def dump(name, d):
    json.dump(d, open("%s/ids-%s.json" % (w, name), "w"))
def mod(name, fn):
    d = copy.deepcopy(schema); fn(d); dump(name, d)
def rename_reason(x):
    e = x["$defs"]["reason_id"]["enum"]; e[e.index("family_unknown")] = "no_family_entry"
def renumber_reason(x):
    e = x["$defs"]["reason_id"]["enum"]; e[0], e[1] = e[1], e[0]
def drop_reason(x):
    x["$defs"]["reason_id"]["enum"].remove("class_absent")
def add_reason(x):
    x["$defs"]["reason_id"]["enum"].append("a_new_reason")
def rename_error(x):
    e = x["$defs"]["error"]["properties"]["error"]["properties"]["code"]["enum"]; e[e.index("no_gpu")] = "nogpu"
def rename_source(x):
    e = x["$defs"]["source"]["enum"]; e[e.index("board")] = "decorator"
def rename_cap(x):
    x["$defs"]["device"]["properties"]["capabilities"]["prefixItems"][1]["properties"]["name"]["const"] = "ats2"
def drop_cap(x):
    p = x["$defs"]["device"]["properties"]["capabilities"]["prefixItems"]; p.pop()
def add_cap(x):
    p = x["$defs"]["device"]["properties"]["capabilities"]["prefixItems"]
    q = copy.deepcopy(p[-1]); q["properties"]["index"]["const"] = 7; q["properties"]["name"]["const"] = "new_cap"; p.append(q)
mod("rename-reason", rename_reason)
mod("renumber-reason", renumber_reason)
mod("drop-reason", drop_reason)
mod("add-reason", add_reason)
mod("rename-error", rename_error)
mod("rename-source", rename_source)
mod("rename-cap", rename_cap)
mod("drop-cap", drop_cap)
mod("add-cap", add_cap)
mod("cap-unpinned", lambda x: x["$defs"]["device"]["properties"]["capabilities"].pop("prefixItems"))
base = open(sys.argv[2]).read().splitlines()
open(w + "/ids-empty.txt", "w").write("# nothing\n")
open(w + "/ids-nocap.txt", "w").write("\n".join(l for l in base if not l.startswith("capability ")) + "\n")
open(w + "/ids-extra.txt", "w").write("\n".join(base + ["reason 15 never_existed 0"]) + "\n")
open(w + "/ids-new-m0.txt", "w").write("\n".join(base + ["reason 15 a_new_reason %d" % CUR]) + "\n")
open(w + "/ids-new-m1.txt", "w").write("\n".join(base + ["reason 15 a_new_reason %d" % NEXT]) + "\n")
open(w + "/ids-renamed.txt", "w").write("\n".join(l.replace("family_unknown", "no_family_entry") for l in base) + "\n")
def bump(x):
    add_reason(x)
    def walk(o):
        if isinstance(o, dict):
            if "schema_minor" in o and isinstance(o["schema_minor"], dict):
                o["schema_minor"]["const"] = NEXT
            for v in o.values():
                walk(v)
        elif isinstance(o, list):
            for v in o:
                walk(v)
    walk(x)
mod("add-reason-m1", bump)
open(w + "/ids-garbage.txt", "w").write("\n".join(base + ["reason x"]) + "\n")
open(w + "/ids-gap.txt", "w").write("\n".join(l for l in base if not l.startswith("reason 5 ")) + "\n")
open(w + "/ids-dup.txt", "w").write("\n".join(base + ["reason 5 family_unknown 0"]) + "\n")
open(w + "/ids-trunc.txt", "w").write("\n".join(l for l in base if not (l.startswith("reason ") and int(l.split()[1]) >= 9)) + "\n")
PY
for m in rename-reason renumber-reason drop-reason rename-error rename-source rename-cap drop-cap cap-unpinned; do
	$IDCHK "$W/ids-$m.json" "$IDS" >"$W/ids-$m.out" 2>&1; rc=$?
	if [ $rc -eq 1 ] && [ -s "$W/ids-$m.out" ]; then ok "identifiers plant refused: $m"; else bad "identifiers plant NOT refused: $m (rc=$rc)"; fi
done
grep -q 'family_unknown (number 5) is gone' "$W/ids-rename-reason.out"; rc=$?
expect_rc "identifiers: the message names the removed id (family_unknown)" $rc 0
grep -q 'was number' "$W/ids-renumber-reason.out"; rc=$?
expect_rc "identifiers: the message says an id was renumbered" $rc 0
for m in add-reason add-cap; do
	$IDCHK "$W/ids-$m.json" "$IDS" >/dev/null 2>&1; rc=$?
	expect_rc "identifiers: an ADDED id is allowed ($m)" $rc 0
done
$IDCHK "$SCHEMA" "$W/no-such-baseline.ids" >"$W/ids-nobase.out" 2>&1; rc=$?
if [ $rc -eq 1 ] && grep -q 'no baseline' "$W/ids-nobase.out"; then ok "identifiers: a missing baseline FAILs (never a pass for having nothing to compare)"; else bad "identifiers: missing baseline gave rc=$rc"; fi
for b in empty nocap garbage gap dup; do
	$IDCHK "$SCHEMA" "$W/ids-$b.txt" >"$W/ids-$b.out" 2>&1; rc=$?
	if [ $rc -eq 1 ]; then ok "identifiers: an unusable baseline FAILs ($b)"; else bad "identifiers: baseline $b gave rc=$rc"; fi
done
# (the duplicate line has the fourth field, the minor, so that it parses and the
# "repeats" branch is the one that refuses it; a three-field line is refused as malformed)
grep -q 'repeats reason 5' "$W/ids-dup.out"; rc=$?
expect_rc "identifiers: a repeated number is refused as a repeat, not as a malformed line" $rc 0
# a baseline cut short passes the plain check (the cut ids are in the schema,
# which is all it asks) and fails the strict one the suite runs on the tree
$IDCHK "$SCHEMA" "$W/ids-trunc.txt" >/dev/null 2>&1; rc=$?
expect_rc "identifiers: a truncated baseline is a valid freeze for the plain check" $rc 0
$IDCHK --strict "$SCHEMA" "$W/ids-trunc.txt" >"$W/ids-trunc.out" 2>&1; rc=$?
if [ $rc -eq 1 ] && grep -q 'append it to the baseline' "$W/ids-trunc.out"; then ok "identifiers: a truncated baseline FAILs the strict check, naming the missing ids"; else bad "identifiers: truncated baseline under --strict gave rc=$rc"; fi
$IDCHK --strict "$W/ids-add-reason.json" "$IDS" >/dev/null 2>&1; rc=$?
if [ $rc -eq 1 ]; then ok "identifiers: an id added to the schema must be appended to the baseline (strict)"; else bad "identifiers: strict accepted an id missing from the baseline"; fi
$IDCHK 2>&1 >/dev/null | grep -q '^usage: ids_check.py'; rc=$?
expect_rc "identifiers: the usage message is printed (not None)" $rc 0
$IDCHK "$SCHEMA" "$W/ids-extra.txt" >"$W/ids-extra.out" 2>&1; rc=$?
if [ $rc -eq 1 ] && grep -q 'never_existed (number 15) is gone' "$W/ids-extra.out"; then ok "identifiers: a baseline id the schema lacks FAILs (and the check that says so is compare, not the gap check)"; else bad "identifiers: extra baseline id gave rc=$rc"; fi
# the minor of each id: a line cannot name a minor above the schema's, and an id
# added since the parent commit must raise it
$IDCHK --strict "$W/ids-add-reason.json" "$W/ids-new-m1.txt" >"$W/ids-m1.out" 2>&1; rc=$?
if [ $rc -eq 1 ] && grep -q "names minor $((MINOR + 1)), above the schema's $MINOR" "$W/ids-m1.out"; then ok "identifiers: a line naming a minor above the schema's is refused (strict)"; else bad "identifiers: minor above the schema gave rc=$rc"; fi
$IDCHK --strict "$W/ids-add-reason-m1.json" "$W/ids-new-m1.txt" >/dev/null 2>&1; rc=$?
expect_rc "identifiers: an id added with the minor raised everywhere is accepted (strict)" $rc 0
$IDCHK --frozen "$IDS" "$W/ids-new-m1.txt" "$W/ids-add-reason-m1.json" >/dev/null 2>&1; rc=$?
expect_rc "identifiers (frozen): an added id that raises the minor is accepted" $rc 0
$IDCHK --frozen "$IDS" "$W/ids-new-m0.txt" "$W/ids-add-reason-m1.json" >"$W/ids-fz0.out" 2>&1; rc=$?
if [ $rc -eq 1 ] && grep -q 'an added identifier raises the minor' "$W/ids-fz0.out"; then ok "identifiers (frozen): an id added without raising the minor is refused"; else bad "identifiers (frozen): add at the same minor gave rc=$rc"; fi
$IDCHK --frozen "$IDS" "$W/ids-new-m1.txt" "$SCHEMA" >/dev/null 2>&1; rc=$?
if [ $rc -eq 1 ]; then ok "identifiers (frozen): an added id with the schema minor unchanged is refused"; else bad "identifiers (frozen): add with the schema minor unchanged gave rc=$rc"; fi
$IDCHK --frozen "$IDS" "$W/ids-renamed.txt" "$SCHEMA" >"$W/ids-fzr.out" 2>&1; rc=$?
if [ $rc -eq 1 ] && grep -q 'a frozen line never changes' "$W/ids-fzr.out"; then ok "identifiers (frozen): a renamed line of the baseline itself is refused"; else bad "identifiers (frozen): renamed baseline line gave rc=$rc"; fi
$IDCHK --frozen "$IDS" "$IDS" "$SCHEMA" >/dev/null 2>&1; rc=$?
expect_rc "identifiers (frozen): a baseline equal to its parent is accepted" $rc 0
# The baseline of an earlier revision is the real freeze.  ids_base GITDIR PATH
# prints "STATE REF":
#   ok REF          the base revision has the file: compare with it
#   absent REF      it resolves and has no such file, or HEAD is a root commit
#                   (where the baseline first appears): the only case that skips
#   nohistory -     the repository has no commit yet: skip
#   unavailable REF the base cannot be fetched (shallow clone, wrong
#                   NVRM_IDS_BASE_REF, or an explicit ref without the file): FAIL
# The base is $NVRM_IDS_BASE_REF if set.  Else it is the merge base of HEAD with
# origin/agent/2088-build-host, which checks the whole branch; but a merge base
# that is HEAD itself (the branch was just pushed, or HEAD is behind it) would
# compare the baseline with itself, and a merge base that lacks the file (the
# baseline was born on this branch) would check nothing, so in both cases the
# local rule applies: HEAD while the baseline has uncommitted changes, else HEAD^
# (a clean checkout of a commit is checked against its parent).
MBREF=origin/agent/2088-build-host
ids_ref_local() {
	if git -C "$1" diff --quiet HEAD -- "$2" >/dev/null 2>&1; then echo 'HEAD^'; else echo HEAD; fi
}
ids_has() {	# ids_has GITDIR REF PATH: the tree of REF lists PATH
	[ -n "$(git -C "$1" ls-tree "$2" -- "$3" 2>/dev/null)" ]
}
ids_base() {
	_g=$1; _p=$2
	git -C "$_g" rev-parse -q --verify HEAD >/dev/null 2>&1 || { echo "nohistory -"; return 0; }
	if [ -n "$NVRM_IDS_BASE_REF" ]; then
		_ref=$NVRM_IDS_BASE_REF
		git -C "$_g" rev-parse -q --verify "$_ref^{commit}" >/dev/null 2>&1 || { echo "unavailable $_ref"; return 0; }
		if ids_has "$_g" "$_ref" "$_p"; then echo "ok $_ref"; else echo "unavailable $_ref"; fi
		return 0
	fi
	_mb=$(git -C "$_g" merge-base HEAD "$MBREF" 2>/dev/null)
	if [ -n "$_mb" ] && [ "$_mb" != "$(git -C "$_g" rev-parse HEAD)" ] && ids_has "$_g" "$_mb" "$_p"; then
		echo "ok $_mb"; return 0
	fi
	_ref=$(ids_ref_local "$_g" "$_p")
	if git -C "$_g" rev-parse -q --verify "$_ref^{commit}" >/dev/null 2>&1; then
		if ids_has "$_g" "$_ref" "$_p"; then echo "ok $_ref"; else echo "absent $_ref"; fi
	elif [ "$_ref" = 'HEAD^' ] && [ "$(git -C "$_g" rev-parse --is-shallow-repository 2>/dev/null)" = false ]; then
		echo "absent HEAD^"	# a root commit: nothing came before it
	else
		echo "unavailable $_ref"
	fi
}
base_state() { ids_base "$1" "$IDSREL" | cut -d' ' -f1; }
base_ref() { ids_base "$1" "$IDSREL" | cut -d' ' -f2; }
IDSREL=lib/libnvrm/schema/nvrm-info-1.ids
BSTATE=$(base_state "$REPO"); BASEREF=$(base_ref "$REPO")
# the throwaway-repository tests below set the base themselves
unset NVRM_IDS_BASE_REF
case $BSTATE in
ok)
	git -C "$REPO" show "$BASEREF:$IDSREL" >"$W/ids-head.ids"; rc=$?
	expect_rc "identifiers (frozen): the baseline of $BASEREF was read" $rc 0
	$IDCHK --frozen "$W/ids-head.ids" "$IDS" "$SCHEMA"; rc=$?
	expect_rc "identifiers (frozen): the baseline only adds to the one at $BASEREF, at a higher minor" $rc 0 ;;
unavailable)
	bad "identifiers (frozen): the base revision $BASEREF is not available (shallow clone, or a wrong NVRM_IDS_BASE_REF): fetch more history or set NVRM_IDS_BASE_REF" ;;
*)
	printf 'skip frozen baseline check (%s): there is no earlier baseline to compare with (this is where it first appears)\n' "$BSTATE" ;;
esac
# the selection itself, in throwaway repositories made with plumbing (no hooks)
GE="GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t"
commit_tree() {	# commit_tree DIR PARENT-or-"" MSG: commits the index, prints the id
	_t=$(git -C "$1" write-tree) || return 1
	if [ -n "$2" ]; then env $GE git -C "$1" -c commit.gpgsign=false commit-tree -p "$2" -m "$3" "$_t"
	else env $GE git -C "$1" -c commit.gpgsign=false commit-tree -m "$3" "$_t"; fi
}
advance() {	# advance DIR PARENT MSG: commit the index on PARENT, move HEAD, print the id
	_n=$(commit_tree "$1" "$2" "$3") || return 1
	git -C "$1" update-ref HEAD "$_n" || return 1
	echo "$_n"
}
rename_line() { sed -i '' 's/family_unknown/no_family_entry/' "$1/$IDSREL"; }
# mkgit DIR KIND:
#   yes          the rename is committed (HEAD^ has the old line)
#   no           nothing changes
#   uncommitted  the rename is in the tree only
#   mb           rename, then an unrelated commit; the origin ref is at the base
#   mbtip        rename committed; the origin ref is AT HEAD (just pushed)
#   born         the file is added on the branch (the origin ref predates it), then renamed
#   absent       the file first appears in the last commit
#   root         one commit that adds the file
mkgit() {
	rm -rf "$1"; mkdir -p "$1/lib/libnvrm/schema"
	git -C "$1" init -q || return 1
	case $2 in
	absent|born)
		echo x >"$1/other"; git -C "$1" add -A || return 1
		_c0=$(advance "$1" "" base) || return 1
		cp "$IDS" "$1/$IDSREL"; git -C "$1" add -A || return 1
		_c1=$(advance "$1" "$_c0" ids) || return 1
		if [ "$2" = born ]; then
			rename_line "$1"; git -C "$1" add -A || return 1
			advance "$1" "$_c1" rename >/dev/null || return 1
			git -C "$1" update-ref "refs/remotes/$MBREF" "$_c0" || return 1
		fi
		return 0 ;;
	root)
		cp "$IDS" "$1/$IDSREL"; git -C "$1" add -A || return 1
		advance "$1" "" base >/dev/null; return $? ;;
	esac
	cp "$IDS" "$1/$IDSREL"; git -C "$1" add -A || return 1
	_c0=$(advance "$1" "" base) || return 1
	case $2 in yes|uncommitted|mb|mbtip) rename_line "$1" ;; esac
	case $2 in yes|no|mb|mbtip)
		git -C "$1" add -A || return 1
		_c1=$(advance "$1" "$_c0" second) || return 1 ;;
	esac
	if [ "$2" = mb ]; then
		echo y >"$1/unrelated"; git -C "$1" add -A || return 1
		advance "$1" "$_c1" third >/dev/null || return 1
		git -C "$1" update-ref "refs/remotes/$MBREF" "$_c0" || return 1
	fi
	if [ "$2" = mbtip ]; then
		git -C "$1" update-ref "refs/remotes/$MBREF" "$_c1" || return 1
	fi
	return 0
}
for c in yes uncommitted no mb mbtip born; do
	mkgit "$W/gitcase-$c" $c; rc=$?
	expect_rc "frozen selection: the throwaway repository ($c) was built" $rc 0
	_st=$(base_state "$W/gitcase-$c"); _b=$(base_ref "$W/gitcase-$c")
	[ "$_st" = ok ]; rc=$?
	expect_rc "frozen selection ($c): the base resolves and has the baseline (base $_b)" $rc 0
	git -C "$W/gitcase-$c" show "$_b:$IDSREL" >"$W/gitcase-$c.old" 2>/dev/null
	$IDCHK --frozen "$W/gitcase-$c.old" "$W/gitcase-$c/$IDSREL" "$SCHEMA" >/dev/null 2>&1; rc=$?
	case $c in
	no) expect_rc "frozen selection: an unchanged baseline passes (base $_b)" $rc 0 ;;
	*) if [ $rc -eq 1 ]; then ok "frozen selection: a renamed baseline line is refused ($c, base $_b)"; else bad "frozen selection: rename ($c, base $_b) gave rc=$rc"; fi ;;
	esac
done
[ "$(base_ref "$W/gitcase-yes")" = 'HEAD^' ]; rc=$?
expect_rc "frozen selection: a clean tree without an upstream is compared with HEAD^" $rc 0
[ "$(base_ref "$W/gitcase-uncommitted")" = HEAD ]; rc=$?
expect_rc "frozen selection: a changed baseline is compared with HEAD" $rc 0
[ "$(base_ref "$W/gitcase-mb")" = "$(git -C "$W/gitcase-mb" rev-parse "refs/remotes/$MBREF")" ]; rc=$?
expect_rc "frozen selection: the merge base with $MBREF is preferred (a rename two commits back is still caught)" $rc 0
[ "$(base_ref "$W/gitcase-mbtip")" = 'HEAD^' ]; rc=$?
expect_rc "frozen selection: a merge base that is HEAD itself (just pushed) falls back to HEAD^, not to a self-comparison" $rc 0
[ "$(base_ref "$W/gitcase-born")" = 'HEAD^' ]; rc=$?
expect_rc "frozen selection: a merge base that lacks the file (born on the branch) falls back to HEAD^" $rc 0
mkgit "$W/gitcase-absent" absent; rc=$?
expect_rc "frozen selection: the throwaway repository (absent) was built" $rc 0
[ "$(base_state "$W/gitcase-absent")" = absent ]; rc=$?
expect_rc "frozen selection: a base without the file is a skip (absent)" $rc 0
mkgit "$W/gitcase-root" root; rc=$?
expect_rc "frozen selection: the throwaway repository (root) was built" $rc 0
[ "$(base_state "$W/gitcase-root")" = absent ]; rc=$?
expect_rc "frozen selection: a root commit that adds the file is a skip, not a shallow-clone failure" $rc 0
[ "$(NVRM_IDS_BASE_REF=HEAD^ base_state "$W/gitcase-absent")" = unavailable ]; rc=$?
expect_rc "frozen selection: an explicit base without the file is not a skip (unavailable)" $rc 0
[ "$(NVRM_IDS_BASE_REF=no/such base_state "$W/gitcase-yes")" = unavailable ]; rc=$?
expect_rc "frozen selection: a wrong NVRM_IDS_BASE_REF is unavailable, so the suite FAILs (it was a skip)" $rc 0
[ "$(NVRM_IDS_BASE_REF=origin/x base_state "$W/gitcase-no")" = unavailable ]; rc=$?
expect_rc "frozen selection: an explicit base that does not resolve is unavailable" $rc 0
[ "$(NVRM_IDS_BASE_REF=HEAD^ base_state "$W/gitcase-yes")" = ok ]; rc=$?
expect_rc "frozen selection: an explicit base that has the file is used" $rc 0
git clone -q --depth 1 "file://$W/gitcase-yes" "$W/gitcase-shallow" >/dev/null 2>&1; rc=$?
expect_rc "frozen selection: the shallow clone was made" $rc 0
[ "$(base_state "$W/gitcase-shallow")" = unavailable ]; rc=$?
expect_rc "frozen selection: a shallow clone (no HEAD^) is unavailable, so the suite FAILs (it was a skip)" $rc 0
mkdir -p "$W/nogit" && git -C "$W/nogit" init -q
[ "$(base_state "$W/nogit")" = nohistory ]; rc=$?
expect_rc "frozen selection: no commit yet means no base (the check is skipped, and says so)" $rc 0
# setting NVRM_IDS_BASE_REF, as the FAIL message advises, must not break the self-tests above
unset NVRM_IDS_BASE_REF
# --emit and the baseline agree: the baseline is what --emit writes from the
# baseline before it, so it is a fixed point of --emit
$IDCHK --emit "$SCHEMA" "$IDS" >"$W/emitted.ids"
grep -v '^#' "$IDS" | cmp -s - "$W/emitted.ids"; rc=$?
expect_rc "identifiers: --emit writes exactly the baseline (minors included)" $rc 0
$IDCHK --emit "$W/ids-add-reason-m1.json" "$IDS" >"$W/emitted-m1.ids"; rc=$?
expect_rc "identifiers: --emit with the old baseline runs" $rc 0
grep -q "^reason 15 a_new_reason $((MINOR + 1))\$" "$W/emitted-m1.ids" && grep -q '^reason 5 family_unknown 0$' "$W/emitted-m1.ids"; rc=$?
expect_rc "identifiers: --emit keeps the old lines at their minor and gives the new id the schema minor" $rc 0
$IDCHK --frozen "$IDS" "$W/emitted-m1.ids" "$W/ids-add-reason-m1.json" >/dev/null 2>&1; rc=$?
expect_rc "identifiers: a baseline regenerated with --emit and the old baseline passes --frozen" $rc 0
cut -d' ' -f1-3 "$W/emitted.ids" >"$W/ids-3field.txt"
$IDCHK "$SCHEMA" "$W/ids-3field.txt" >/dev/null 2>&1; rc=$?
if [ $rc -eq 1 ]; then ok "identifiers: a baseline line without its minor is refused"; else bad "identifiers: 3-field baseline gave rc=$rc"; fi
$IDCHK --strict "$SCHEMA" "$W/emitted.ids" >/dev/null 2>&1; rc=$?
expect_rc "identifiers: the --emit output is itself a valid baseline (round trip)" $rc 0
$IDCHK >/dev/null 2>&1; rc=$?
expect_rc "identifiers: usage error is rc 2" $rc 2
# the schema pins the capability flags by position (prefixItems with constants)
python3 -I - "$SCHEMA" "$IDS" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
p = s["$defs"]["device"]["properties"]["capabilities"]["prefixItems"]
want = [l.split()[2] for l in open(sys.argv[2]).read().splitlines() if l.startswith("capability ")]
assert len(want) >= 7 and len(p) >= len(want)
assert [x["properties"]["index"]["const"] for x in p] == list(range(len(p)))
assert [x["properties"]["name"]["const"] for x in p][:len(want)] == want
PY
rc=$?
expect_rc "schema: every flag is pinned by position with a constant index and name, and the released ones keep theirs" $rc 0

# ---- CLI ----------------------------------------------------------------
$INFO --help >/dev/null; rc=$?
expect_rc "--help rc 0" $rc 0
$INFO --help | grep -q -- '--jsonl'
rc=$?
expect_rc "--help describes --jsonl" $rc 0
$INFO --bogus >/dev/null 2>&1; rc=$?
expect_rc "unknown option: rc 2" $rc 2
$INFO extra >/dev/null 2>&1; rc=$?
expect_rc "extra argument: rc 2" $rc 2
$INFO --json --jsonl >/dev/null 2>"$W/u1.err"; rc=$?
expect_rc "two output modes: rc 2" $rc 2
grep -q 'exclude each other' "$W/u1.err"; rc=$?
expect_rc "two output modes: the message says why" $rc 0
$INFO --schema --backend fake >/dev/null 2>"$W/u2.err"; rc=$?
expect_rc "--schema with --backend: rc 2" $rc 2
grep -q 'takes no --backend' "$W/u2.err"; rc=$?
expect_rc "--schema with --backend: the message says why" $rc 0
NVRM_FAKE_PROFILE=discrete $INFO >"$W/text.out"; rc=$?
expect_rc "text mode rc" $rc 0
grep -q 'sm_count  *36' "$W/text.out" && grep -q 'family  *blackwell-b' "$W/text.out"
rc=$?
expect_rc "text mode shows the values" $rc 0
grep -q 'built for RM 580.178.04, running RM 580.178.04' "$W/text.out"; rc=$?
expect_rc "text mode shows the built-for and the running RM version" $rc 0
for v in 'RM API version 580.178.04' 'library version 1.3.0' 'library symbol version NVRM_1.3' 'schema version 1.3'; do
	grep -Fqx "$v" "$W/text.out"; rc=$?
	expect_rc "text mode shows the version string: $v" $rc 0
done
grep -q 'vbios  *96\.06\.1e\.00\.4a (rm)' "$W/text.out" && grep -q 'gsp_firmware  *580\.178\.04 (rm)' "$W/text.out"; rc=$?
expect_rc "text mode shows the VBIOS and GSP firmware version strings" $rc 0
$INFO --help >"$W/help.out"
grep -Fq '  --json      one JSON document (schema nvrm-info/1); versions are' "$W/help.out" && grep -Fqx '              strings plus integer parts' "$W/help.out" && grep -Fq '  --jsonl     JSON Lines: header, one record per GPU, end record;' "$W/help.out" && grep -Fqx '              versions are strings plus integer parts' "$W/help.out"
rc=$?
expect_rc "--help folds version strings and integer parts into both JSON descriptions" $rc 0
grep -q 'pci_bus  *13 ' "$W/text.out"; rc=$?
expect_rc "text mode prints the PCI location in decimal like pciconf" $rc 0
# the text view lists every field of the table (it walks the same table)
python3 -I - "$W/out.json" "$W/text.out" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))["devices"][0]
text = open(sys.argv[2]).read()
names = [k for g in ("identity", "gpu", "memory", "versions") for k in doc[g]]
missing = [n for n in names if (" " + n + " ") not in text]
assert not missing, missing
PY
rc=$?
expect_rc "text mode names every field of the JSON device" $rc 0
for f in open version list gpu_open limit; do
	NVRM_FAKE_FAIL=$f $INFO --json >"$W/err.json"; rc=$?
	expect_rc "failure '$f': --json exits 1" $rc 1
	$VAL "$W/err.json"; rc=$?
	expect_rc "failure '$f': the error record validates" $rc 0
	NVRM_FAKE_FAIL=$f $INFO --jsonl >"$W/err.jsonl"; rc=$?
	expect_rc "failure '$f': --jsonl exits 1" $rc 1
	grep -q '"kind":"error"' "$W/err.jsonl"; rc=$?
	expect_rc "failure '$f': --jsonl prints an error record" $rc 0
	NVRM_FAKE_FAIL=$f $INFO >"$W/err.txt" 2>"$W/err.stderr"; rc=$?
	expect_rc "failure '$f': text mode exits 1 with a message on stderr" $rc 1
	[ -s "$W/err.stderr" ]; rc=$?
	expect_rc "failure '$f': stderr is not empty" $rc 0
done
# no GPU is a result, not an error: exit 0, empty devices, valid against the schema
NVRM_FAKE_FAIL=nogpu $INFO --json >"$W/nogpu.json"; rc=$?
expect_rc "no GPU: --json exits 0" $rc 0
$VAL "$W/nogpu.json"; rc=$?
expect_rc "no GPU: --json validates (devices may be empty)" $rc 0
python3 -I -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert d['kind']=='document' and d['devices']==[], d
assert d['backend']=='fake'
" "$W/nogpu.json"; rc=$?
expect_rc "no GPU: the document says devices []" $rc 0
NVRM_FAKE_FAIL=nogpu $INFO --jsonl >"$W/nogpu.jsonl"; rc=$?
expect_rc "no GPU: --jsonl exits 0" $rc 0
$VAL "$W/nogpu.jsonl"; rc=$?
expect_rc "no GPU: --jsonl validates" $rc 0
[ "$(wc -l <"$W/nogpu.jsonl" | tr -d ' ')" = 2 ] && grep -q '"kind":"header"' "$W/nogpu.jsonl" && grep -q '"kind":"end","count":0' "$W/nogpu.jsonl"; rc=$?
expect_rc "no GPU: --jsonl is a header and an end record with count 0" $rc 0
NVRM_FAKE_FAIL=nogpu $INFO >"$W/nogpu.txt" 2>"$W/nogpu.err"; rc=$?
expect_rc "no GPU: text mode exits 0" $rc 0
grep -q 'no GPU is attached' "$W/nogpu.txt" && [ ! -s "$W/nogpu.err" ]; rc=$?
expect_rc "no GPU: text mode says so on standard output and not on standard error" $rc 0
# a no-backend failure is still an error (the driver is not there at all)
NVRM_FAKE_FAIL=open $INFO --json >"$W/nodrv.json"; rc=$?
expect_rc "no driver (open fails): still exit 1" $rc 1
unset NVRM_BACKEND
# without a backend (no rm device unless the driver is loaded)
if [ ! -e /dev/nvidiactl ]; then
	$INFO --json >"$W/nb.json"; rc=$?
	expect_rc "no /dev/nvidiactl and no backend named: exit 1" $rc 1
	$VAL "$W/nb.json"; rc=$?
	expect_rc "no backend: the error record validates" $rc 0
	grep -q 'no_backend' "$W/nb.json"; rc=$?
	expect_rc "no backend: the code is no_backend" $rc 0
	grep -q 'kernel module is not loaded' "$W/nb.json" && grep -q -- '--backend fake' "$W/nb.json"; rc=$?
	expect_rc "no backend: the tool names the real fix and its own flag" $rc 0
else
	printf 'skip no-backend check: /dev/nvidiactl exists on this host\n'
fi
$INFO --backend nope --json | grep -q 'no_backend'; rc=$?
expect_rc "--backend nope names the failure" $rc 0
# a failed run into a closed pipe is still a failure
(NVRM_BACKEND=fake NVRM_FAKE_FAIL=version $INFO --json; echo $? >"$W/epipe-fail.rc") | true
[ "$(cat "$W/epipe-fail.rc")" = 1 ]; rc=$?
expect_rc "a failed enumeration into a closed pipe still exits 1" $rc 0
# EPIPE: a reader that quits early is not an error
P32=discrete; i=1; while [ $i -lt 32 ]; do P32="$P32,discrete"; i=$((i+1)); done
(NVRM_BACKEND=fake NVRM_FAKE_PROFILE=$P32 $INFO --jsonl; echo $? >"$W/epipe.rc") | head -1 >/dev/null
[ "$(cat "$W/epipe.rc")" = 0 ]; rc=$?
expect_rc "--jsonl into a closed pipe exits 0, no crash" $rc 0
NVRM_BACKEND=fake NVRM_FAKE_PROFILE=$P32 $INFO --jsonl | $VAL /dev/stdin >/dev/null; rc=$?
expect_rc "32 GPUs stream validates" $rc 0
# the tool really runs in capability mode: ktrace is not needed, procstat is
# not available for a finished process, so the proof is cap_test; here the
# binary must reference cap_enter.
nm -D "$INFO" 2>/dev/null | grep -q cap_enter || nm "$INFO" | grep -q cap_enter
rc=$?
expect_rc "nvrm-info calls cap_enter" $rc 0

# ---- the test-boot proof script ------------------------------------------------
sh -n "$T/boot_nvrm_info.sh"; rc=$?
expect_rc "boot_nvrm_info.sh parses" $rc 0
# the memory probe of the boot kit, built against the library under test and
# run on the fake software GPU (on the test boot it runs on the driver)
cc -I"$L/include" -std=gnu11 -Wall -Wextra -Werror -o "$W/mem_probe" "$T/mem_probe.c" -L"$O/lib" -lnvrm -lthr >"$W/cc-probe.log" 2>&1
rc=$?
expect_rc "mem_probe builds against libnvrm (-Werror)" $rc 0
NVRM_BACKEND=fake NVRM_FAKE_PROFILE=discrete,unified "$W/mem_probe" >"$W/probe.out" 2>&1
rc=$?
expect_rc "mem_probe passes every step on two fake GPUs" $rc 0
_missing=
for g in 0 1; do for s in client_open vaspace va_reserve alloc_vram vram_info alloc_sysmem map_gpu_vram map_cpu_vram rw_vram map_gpu_sysmem map_cpu_sysmem rw_sysmem export second_client import read_import va_release nothing_left no_refused_release; do
	grep -q "^PASS gpu $g ([^)]*) $s: " "$W/probe.out" || _missing="$_missing gpu$g:$s"
done; done
[ -z "$_missing" ] && ! grep -q '^FAIL' "$W/probe.out"; rc=$?
expect_rc "mem_probe reports every step on each GPU as PASS${_missing:+ (missing:$_missing)}" $rc 0
[ $rc -eq 0 ] || sed -n 1,40p "$W/probe.out"
NVRM_BACKEND=fake NVRM_FAKE_FAIL=nogpu "$W/mem_probe" >"$W/probe-nogpu.out" 2>&1
rc=$?
if [ $rc -eq 101 ] && grep -q '^FAIL enumerate: no GPU' "$W/probe-nogpu.out"; then ok "mem_probe plant: no GPU is a FAIL (rc 101), never a pass"; else bad "mem_probe plant: no GPU gave rc=$rc"; fi

# the channel probe of the boot kit, built against the library under test and
# run on the fake software GPU (on the test boot it runs on the driver).  The
# RM backend of main has no channel backend yet, so this is the only place
# where the channel calls are exercised: the probe itself is the proof on the
# card.
cc -I"$L/include" -std=gnu11 -Wall -Wextra -Werror -o "$W/chan_probe" "$T/chan_probe.c" -L"$O/lib" -lnvrm -lthr >"$W/cc-chan.log" 2>&1
rc=$?
expect_rc "chan_probe builds against libnvrm (-Werror)" $rc 0
NVRM_BACKEND=fake NVRM_FAKE_PROFILE=discrete,unified "$W/chan_probe" >"$W/chan.out" 2>&1
rc=$?
expect_rc "chan_probe passes every step on two fake GPUs" $rc 0
_missing=
for g in 0 1; do for s in create release latency stress isolation cleanup; do
	grep -q "^PASS gpu $g ([^)]*) $s: " "$W/chan.out" || _missing="$_missing gpu$g:$s"
done; done
[ -z "$_missing" ] && ! grep -q '^FAIL' "$W/chan.out"; rc=$?
expect_rc "chan_probe reports every step on each GPU as PASS${_missing:+ (missing:$_missing)}" $rc 0
[ $rc -eq 0 ] || sed -n 1,40p "$W/chan.out"
grep -q '^INFO gpu 0 .* latency_ns: p50 .* ns, p99 .* ns, max .* ns' "$W/chan.out"; rc=$?
expect_rc "chan_probe reports the latency percentiles" $rc 0
grep -q '^PASS gpu 0 .* isolation: the second channel died' "$W/chan.out"; rc=$?
expect_rc "chan_probe kills the channel of the bad push" $rc 0
NVRM_BACKEND=fake NVRM_FAKE_FAIL=nogpu "$W/chan_probe" >"$W/chan-nogpu.out" 2>&1
rc=$?
if [ $rc -eq 101 ] && grep -q '^FAIL enumerate: no GPU' "$W/chan-nogpu.out"; then ok "chan_probe plant: no GPU is a FAIL (rc 101), never a pass"; else bad "chan_probe plant: no GPU gave rc=$rc"; fi
NVRM_BACKEND=fake NVRM_FAKE_PROFILE=discrete,unified "$W/chan_probe" --json >"$W/chan.json" 2>&1
rc=$?
expect_rc "chan_probe --json prints one document" $rc 0
python3 -I "$T/schema_validate.py" "$T/schema/chan-probe-1.schema.json" "$W/chan.json" >"$W/chan-schema.log" 2>&1
rc=$?
expect_rc "chan_probe --json validates against the schema" $rc 0
[ $rc -eq 0 ] || sed -n 1,20p "$W/chan-schema.log"
_gpus=$(python3 -I -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["gpus"]))' "$W/chan.json" 2>/dev/null)
[ "$_gpus" = 2 ]; rc=$?
expect_rc "chan_probe --json holds one entry per GPU" $rc 0
mkdir -p "$W/bootm"
BOOT_MEM_PROBE="$W/mem_probe" BOOT_CHAN_PROBE="$W/chan_probe" NVRM_FAKE_PROFILE=discrete BOOT_ALLOW_FAKE=1 NVRM_BACKEND=fake sh "$T/boot_nvrm_info.sh" "$W/bootm" "$INFO" "$SCHEMA" >/dev/null 2>&1
grep -q '^PASS mem_probe: every memory step passed on every GPU' "$W/bootm/results.txt" && grep -q '^PASS gpu 0 .* nothing_left' "$W/bootm/results.txt" && [ -s "$W/bootm/mem_probe.txt" ]; rc=$?
expect_rc "boot script: runs the memory probe and records its rows" $rc 0
grep -q '^PASS chan_probe: every channel step passed on every GPU' "$W/bootm/results.txt" && grep -q '^PASS gpu 0 .* isolation:' "$W/bootm/results.txt" && [ -s "$W/bootm/chan_probe.txt" ]; rc=$?
expect_rc "boot script: runs the channel probe and records its rows" $rc 0
python3 -I "$T/schema_validate.py" "$T/schema/chan-probe-1.schema.json" "$W/bootm/chan_probe.json" >"$W/bootm-chan-schema.log" 2>&1
rc=$?
expect_rc "boot script: the JSON document of the channel probe validates against the schema" $rc 0
mkdir -p "$W/boot"
BOOT_ALLOW_FAKE=1 NVRM_BACKEND=fake sh "$T/boot_nvrm_info.sh" "$W/boot" "$INFO" "$SCHEMA" >/dev/null 2>&1
rc=$?
# against the fake backend and without the driver it must report the missing
# driver (FAIL lines) while still running every nvrm-info mode and the schema
grep -q '^== done rc=' "$W/boot/results.txt" && grep -q '^FAIL nvidia.ko is not loaded' "$W/boot/results.txt"
rc2=$?
expect_rc "boot script: records a result and notices the missing driver" $rc2 0
grep -q '^PASS --json validates against the schema' "$W/boot/results.txt" && grep -q '^PASS --jsonl validates against the schema' "$W/boot/results.txt"
rc=$?
expect_rc "boot script: validates --json and --jsonl against the schema" $rc 0
grep -q '^FAIL memory probe missing' "$W/boot/results.txt"; rc=$?
expect_rc "boot script: a kit without the memory probe FAILs" $rc 0
grep -q '^FAIL channel probe missing' "$W/boot/results.txt"; rc=$?
expect_rc "boot script: a kit without the channel probe FAILs" $rc 0
mkdir -p "$W/boots1"
BOOT_S1_ONLY=1 BOOT_ALLOW_FAKE=1 NVRM_BACKEND=fake sh "$T/boot_nvrm_info.sh" "$W/boots1" "$INFO" "$SCHEMA" >/dev/null 2>&1
grep -q '^INFO memory probe not run: BOOT_S1_ONLY=1' "$W/boots1/results.txt" && ! grep -q '^FAIL memory probe' "$W/boots1/results.txt"; rc=$?
expect_rc "boot script: BOOT_S1_ONLY=1 records the opt-out instead" $rc 0
grep -q '^INFO channel probe not run: BOOT_S1_ONLY=1' "$W/boots1/results.txt" && ! grep -q '^FAIL channel probe' "$W/boots1/results.txt"; rc=$?
expect_rc "boot script: BOOT_S1_ONLY=1 records the opt-out of the channel probe too" $rc 0
mkdir -p "$W/bootf"
BOOT_MEM_PROBE=/usr/bin/false BOOT_ALLOW_FAKE=1 NVRM_BACKEND=fake sh "$T/boot_nvrm_info.sh" "$W/bootf" "$INFO" "$SCHEMA" >/dev/null 2>&1
grep -q "^FAIL mem_probe exited 1 ($W/bootf/mem_probe.txt)" "$W/bootf/results.txt"; rc=$?
expect_rc "boot script: a failing probe is a FAIL naming its output file" $rc 0
mkdir -p "$W/bootcf"
BOOT_CHAN_PROBE=/usr/bin/false BOOT_ALLOW_FAKE=1 NVRM_BACKEND=fake sh "$T/boot_nvrm_info.sh" "$W/bootcf" "$INFO" "$SCHEMA" >/dev/null 2>&1
grep -q "^FAIL chan_probe exited 1 ($W/bootcf/chan_probe.txt)" "$W/bootcf/results.txt"; rc=$?
expect_rc "boot script: a failing channel probe is a FAIL naming its output file" $rc 0
grep -q '^PASS GPU 0 sm_count' "$W/boot/results.txt"; rc=$?
expect_rc "boot script: compares GPU values" $rc 0


# the version has one source: a header naming another version fails the build
M=$W/mut-version
mkdir -p "$M" && cp -R "$SRC/lib" "$M/lib" && cp "$SRC/SOURCES" "$M/SOURCES"
sed -i '' 's/NVRM_RM_VERSION		"[0-9.]*"/NVRM_RM_VERSION		"1.2.3"/' "$M/lib/libnvrm/include/nvrm/nvrm.h"
mkdir -p "$W/mv-lib"
(cd "$M/lib/libnvrm" && MAKEOBJDIR=$W/mv-lib OGKM=$OGKM make >"$W/mv.log" 2>&1); rc=$?
if [ $rc -ne 0 ] && grep -q 'NVRM_RM_VERSION 1.2.3' "$W/mv.log" && grep -q "ogkm_tag says $TAG" "$W/mv.log"; then ok "version plant: a header with another version fails the build"; else bad "version plant: build accepted it (rc=$rc)"; fi
M=$W/mut-nosources
mkdir -p "$M" && cp -R "$SRC/lib" "$M/lib"
mkdir -p "$W/mn-lib"
(cd "$M/lib/libnvrm" && MAKEOBJDIR=$W/mn-lib OGKM=$OGKM make >"$W/mn.log" 2>&1); rc=$?
if [ $rc -ne 0 ] && grep -q 'has no ogkm_tag line' "$W/mn.log"; then ok "version plant: a tree without SOURCES says so"; else bad "version plant: missing SOURCES not reported (rc=$rc)"; fi
# the unknown-flag guard and the old positional meaning are core_test cases
# boot script: a missing schema and a loaded linux kmod are FAILs, the fake backend is not a proof
mkdir -p "$W/boot2" "$W/boot3"
BOOT_ALLOW_FAKE=1 NVRM_BACKEND=fake sh "$T/boot_nvrm_info.sh" "$W/boot2" "$INFO" "$W/no-such-schema.json" >/dev/null 2>&1
grep -q "^FAIL schema $W/no-such-schema.json does not exist" "$W/boot2/results.txt"; rc=$?
expect_rc "boot script: a schema argument that does not exist is a FAIL naming it" $rc 0
grep -q '^FAIL BOOT_ALLOW_FAKE is set' "$W/boot2/results.txt" && ! grep -q '^PASS nvrm-info used the rm backend' "$W/boot2/results.txt"; rc=$?
expect_rc "boot script: the fake backend is a FAIL and never a PASS for rm" $rc 0
printf '#!/bin/sh\necho "Id Refs Address Size Name"\necho " 1 5 0x0 0x0 linux64.ko"\n' >"$W/kldstub.sh"
BOOT_KLDSTAT="sh $W/kldstub.sh" BOOT_ALLOW_FAKE=1 NVRM_BACKEND=fake sh "$T/boot_nvrm_info.sh" "$W/boot3" "$INFO" "$SCHEMA" >/dev/null 2>&1
grep -q '^FAIL a Linux ABI kmod' "$W/boot3/results.txt"; rc=$?
expect_rc "boot script: a loaded linux kmod is a FAIL" $rc 0
# without BOOT_ALLOW_FAKE the stub is ignored: the record shows the real kldstat
mkdir -p "$W/boot4"
printf '#!/bin/sh\necho " 1 5 0x0 0x0 STUBMARK.ko"\n' >"$W/kldstub2.sh"
BOOT_KLDSTAT="sh $W/kldstub2.sh" sh "$T/boot_nvrm_info.sh" "$W/boot4" "$INFO" >/dev/null 2>&1
# the record must EXIST, name the kernel, and not hold the stub: a negated grep
# alone also passes when the script never wrote the file
kld_ignored() { [ -s "$1/kldstat.txt" ] && awk '{print $5}' "$1/kldstat.txt" | grep -qx kernel && ! grep -q STUBMARK "$1/kldstat.txt"; }
kld_ignored "$W/boot4"; rc=$?
expect_rc "boot script: BOOT_KLDSTAT is ignored unless BOOT_ALLOW_FAKE is set (the record exists and is the real kldstat)" $rc 0
# plant: a script that writes kldstat.log instead of kldstat.txt must fail the same check
mkdir -p "$W/bootp" "$W/bootp-out"
cp "$T"/* "$W/bootp"/ 2>/dev/null
sed -i '' 's/kldstat\.txt/kldstat.log/g' "$W/bootp/boot_nvrm_info.sh"
grep -q 'kldstat\.log' "$W/bootp/boot_nvrm_info.sh"; rc=$?
expect_rc "kldstat plant: the edit is in place" $rc 0
BOOT_KLDSTAT="sh $W/kldstub2.sh" sh "$W/bootp/boot_nvrm_info.sh" "$W/bootp-out" "$INFO" >/dev/null 2>&1
kld_ignored "$W/bootp-out"; rc=$?
if [ $rc -ne 0 ]; then ok "kldstat plant: a script that never writes kldstat.txt fails the check"; else bad "kldstat plant: the check passed on a missing record"; fi
grep -q '^PASS nvrm-info was built for the SOURCES ogkm_tag' "$W/boot/results.txt"; rc=$?
expect_rc "boot script: the built-for version is checked against SOURCES" $rc 0
[ -s "$W/boot4/schema.json" ]; rc=$?
expect_rc "boot script: with no schema argument it takes the schema nvrm-info prints" $rc 0

# ---- the boot proof compares with the board, not with itself --------------------
# Stand-ins (honoured only under BOOT_ALLOW_FAKE): a pciconf -lvb whose BARs
# match the fake discrete GPU (16 GiB BAR1), a sysctl that has no compat.linux,
# one that has it, and kldstat lists.  The fake discrete GPU has 16 GiB of VRAM
# and SM 12.0.
printf 'vgapci0@pci0:13:0:0:\tclass=0x030000 rev=0xa1 hdr=0x00 vendor=0x10de device=0x2d04 subvendor=0x1462 subdevice=0x5351\n    bar   [10] = type Memory, range 32, base 0x40000000, size 16777216, enabled\n    bar   [14] = type Prefetchable Memory, range 64, base 0x300000000000, size 17179869184, enabled\n    bar   [20] = type I/O Port, range 32, base 0x4fffe000, size 128, enabled\n' >"$W/pciconf-good.txt"
printf 'vgapci0@pci0:13:0:0:\tclass=0x030000 rev=0xa1 hdr=0x00 vendor=0x10de device=0x2d04 subvendor=0x1462 subdevice=0x5351\n    bar   [10] = type Memory, range 32, base 0x40000000, size 16777216, enabled\n    bar   [14] = type Prefetchable Memory, range 64, base 0x300000000000, size 268435456, enabled\n    bar   [20] = type I/O Port, range 32, base 0x4fffe000, size 17179869184, enabled\n' >"$W/pciconf-badbar.txt"
printf '#!/bin/sh\ncat "%s"\n' "$W/pciconf-good.txt" >"$W/pciconf-good.sh"
printf '#!/bin/sh\ncat "%s"\n' "$W/pciconf-badbar.txt" >"$W/pciconf-badbar.sh"
# a sysctl with no compat.linux (the real one says "unknown oid", exit 1), a marker
# line for the hw.nvidia.gpus read, and the real sysctl for everything else
# The fake discrete GPU is at 0000:0d:00.0; the stand-in numbers its device unit
# 0 (the real board is unit 1).  The RM version comes from STUB_TAG.
# STUB_DEV_UUID, STUB_HW_UUID, STUB_BUS_ID and STUB_VERSION_AVAILABLE change
# what the OS layer says.  Every call is appended to STUB_LOG when set; the two
# nodes the script may read, hw.nvidia and dev.nvidia, each leave their own mark.
cat >"$W/sysctl-none.sh" <<'EOS'
#!/bin/sh
FAKE_UUID=GPU-00000000-0000-4000-8000-0000000000a1
MAJ=$(echo "$STUB_TAG" | awk -F. '{print $1 + 0}')
MIN=$(echo "$STUB_TAG" | awk -F. '{print $2 + 0}')
PAT=$(echo "$STUB_TAG" | awk -F. '{print $3 + 0}')
banner() { echo "hw.nvidia.version: NVIDIA UNIX Open Kernel Module for aarch64  $STUB_TAG  Release Build"; }
versions() {
	echo "hw.nvidia.version_string: $STUB_TAG"
	echo "hw.nvidia.version_major: $MAJ"
	echo "hw.nvidia.version_minor: $MIN"
	echo "hw.nvidia.version_patch: $PAT"
	echo "hw.nvidia.version_suffix: "
	echo "hw.nvidia.version_available: ${STUB_VERSION_AVAILABLE:-1}"
}
gpus() { echo "hw.nvidia.gpus.0.uuid: ${STUB_HW_UUID:-$FAKE_UUID}"; echo "hw.nvidia.gpus.0.model: SYSCTLMARK-HW"; }
dev() {
	echo "dev.nvidia.0.uuid: ${STUB_DEV_UUID:-$FAKE_UUID}"
	echo "dev.nvidia.0.pci_bus_id: ${STUB_BUS_ID:-0000:0d:00.0}"
	echo "dev.nvidia.0.%location: slot=0 function=0 dbsf=pci0:13:0:0"
	echo "dev.nvidia.0.%desc: SYSCTLMARK-DEV"
}
[ -z "$STUB_LOG" ] || echo "$*" >>"$STUB_LOG"
case "$*" in
*compat.linux.osrelease*) echo "sysctl: unknown oid 'compat.linux.osrelease'" >&2; exit 1 ;;
"hw.nvidia") banner; versions; gpus; exit 0 ;;
"dev.nvidia") dev; exit 0 ;;
esac
exec /sbin/sysctl "$@"
EOS
printf '#!/bin/sh\necho 5.15.0\n' >"$W/sysctl-linux.sh"
printf '#!/bin/sh\necho "sysctl: permission denied" >&2\nexit 1\n' >"$W/sysctl-broken.sh"
printf '#!/bin/sh\nexit 1\n' >"$W/sysctl-silent.sh"
# kldstat that shows a Linux module only from its second call on (loaded in between)
cat >"$W/kld-late.sh" <<EOF
#!/bin/sh
n=\$(cat "$W/kld-count" 2>/dev/null || echo 0); n=\$((n + 1)); echo \$n >"$W/kld-count"
echo "Id Refs Address Size Name"; echo " 1 40 0x0 0x0 kernel"; echo " 4 2 0x0 0x0 nvidia.ko"
[ \$n -ge 2 ] && echo " 5 1 0x0 0x0 linux64.ko"
exit 0
EOF
# kldstat that never names the kernel
printf '#!/bin/sh\necho "Id Refs Address Size Name"\necho " 4 2 0x0 0x0 nvidia.ko"\n' >"$W/kld-nokernel.sh"
# pciconf: BAR0 as large as the reported BAR1; and a device that is not the GPU
printf 'vgapci0@pci0:13:0:0:\tclass=0x030000 rev=0xa1 hdr=0x00 vendor=0x10de device=0x2d04 subvendor=0x1462 subdevice=0x5351\n    bar   [10] = type Memory, range 32, base 0x40000000, size 17179869184, enabled\n    bar   [14] = type Prefetchable Memory, range 64, base 0x300000000000, size 268435456, enabled\n' >"$W/pciconf-bar0.txt"
printf 'vgapci0@pci0:13:0:0:\tclass=0x030000 rev=0xa1 hdr=0x00 vendor=0x10de device=0x9999 subvendor=0x1462 subdevice=0x5351\n    bar   [14] = type Prefetchable Memory, range 64, base 0x300000000000, size 17179869184, enabled\n' >"$W/pciconf-other.txt"
printf 'vgapci0@pci0:13:0:0:\tclass=0x030000 rev=0xa1 hdr=0x00 vendor=0x10de device=0x2d04 subvendor=0x1462 subdevice=0x5351\n    bar   [10] = type Memory, range 32, base 0x40000000, size 16777216, enabled\n' >"$W/pciconf-nobar1.txt"
for n in bar0 other nobar1; do printf '#!/bin/sh\ncat "%s"\n' "$W/pciconf-$n.txt" >"$W/pciconf-$n.sh"; done
printf '#!/bin/sh\necho "Id Refs Address Size Name"\necho " 1 40 0x0 0x0 kernel"\necho " 2 1 0x0 0x0 linuxkpi.ko"\necho " 3 1 0x0 0x0 linuxkpi_video.ko"\necho " 4 2 0x0 0x0 nvidia.ko"\n' >"$W/kld-lkpi.sh"
for m in linux.ko linux64.ko linux_common.ko; do
	printf '#!/bin/sh\necho "Id Refs Address Size Name"\necho " 1 40 0x0 0x0 kernel"\necho " 2 1 0x0 0x0 %s"\necho " 4 2 0x0 0x0 nvidia.ko"\n' "$m" >"$W/kld-$m.sh"
done
# a nvrm-info whose JSON says VRAM 1 byte, SM and compute capability 99.7 and BAR1 3 bytes
cat >"$W/doctor.py" <<'PY'
import json, sys
fixed = 0
def fix(d):
    global fixed
    d["memory"]["vram_size"]["value"] = 1
    d["memory"]["bar1_size"]["value"] = 3
    d["gpu"]["sm_version_major"]["value"] = 99
    d["gpu"]["sm_version_minor"]["value"] = 7
    d["gpu"]["compute_capability_major"]["value"] = 99
    d["gpu"]["compute_capability_minor"]["value"] = 7
    fixed += 1
for line in sys.stdin:
    o = json.loads(line)
    for d in o.get("devices", []):
        fix(d)
    if o.get("kind") == "device":
        fix(o["device"])
    sys.stdout.write(json.dumps(o, separators=(",", ":")) + "\n")
sys.exit(0 if fixed else 3)
PY
cat >"$W/nvrm-info-doctored" <<EOF
#!/bin/sh
case "\$*" in
*--json*)
	"$INFO" "\$@" >"$W/doctor.in"; rc=\$?
	python3 -I "$W/doctor.py" <"$W/doctor.in" || exit 99
	exit \$rc ;;
*) exec "$INFO" "\$@" ;;
esac
EOF
chmod +x "$W/nvrm-info-doctored"
# bootrun DIR INFO [VAR=value ...]: the script under the fake backend and stand-ins
bootrun() {
	_d=$1; _i=$2; shift 2
	mkdir -p "$_d"
	env STUB_TAG="$TAG" BOOT_ALLOW_FAKE=1 NVRM_BACKEND=fake BOOT_PCICONF="sh $W/pciconf-good.sh" BOOT_SYSCTL="sh $W/sysctl-none.sh" "$@" \
	    sh "$T/boot_nvrm_info.sh" "$_d" "$_i" "$SCHEMA" >/dev/null 2>&1
}
line() { grep -q "$2" "$1/results.txt"; }
# BOOT_EXPECT_SM is the compute capability (12.0), not the RM numbering (10.4).
. "$T/board-amp001.env"
EXP="BOOT_EXPECT_VRAM_BYTES=$BOARD_VRAM_BYTES BOOT_EXPECT_VRAM_RESERVE_MAX_BYTES=$BOARD_VRAM_RESERVE_MAX_BYTES BOOT_EXPECT_SM=$BOARD_SM"
# the true values: each of VRAM, SM and BAR1 has a PASS and no FAIL
bootrun "$W/ba" "$INFO" $EXP STUB_LOG="$W/ba.calls"
line "$W/ba" '^PASS GPU 0 vram_size '; rc=$?
expect_rc "boot script, true values: VRAM is compared with the board and passes" $rc 0
line "$W/ba" '^PASS GPU 0 compute capability '; rc=$?
expect_rc "boot script, true values: the compute capability is compared with the board and passes" $rc 0
line "$W/ba" '^PASS GPU 0 bar1_size '; rc=$?
expect_rc "boot script, true values: BAR1 is compared with pciconf -lvb and passes" $rc 0
! grep -E '^FAIL GPU 0 (vram_size|compute capability|bar1_size|uuid)|^FAIL BOOT_EXPECT' "$W/ba/results.txt" >/dev/null; rc=$?
expect_rc "boot script, true values: no VRAM, SM, BAR1 or expectation FAIL" $rc 0
# a doctored report (VRAM 1, SM 99.7, BAR1 3) must FAIL each of the three
bootrun "$W/bb" "$W/nvrm-info-doctored" $EXP
python3 -I -c 'import json,sys
d=json.load(open(sys.argv[1]+"/nvrm-info.json"))["devices"][0]
assert d["memory"]["vram_size"]["value"]==1 and d["gpu"]["compute_capability_major"]["value"]==99 and d["memory"]["bar1_size"]["value"]==3' "$W/bb"; rc=$?
expect_rc "boot script, doctored report: the record says VRAM 1, SM and compute capability 99.7, BAR1 3 (parsed)" $rc 0
line "$W/bb" '^FAIL GPU 0 vram_size '; rc=$?
expect_rc "boot script, doctored report: wrong VRAM is a FAIL" $rc 0
line "$W/bb" '^FAIL GPU 0 compute capability '; rc=$?
expect_rc "boot script, doctored report: wrong compute capability is a FAIL" $rc 0
line "$W/bb" '^FAIL GPU 0 bar1_size '; rc=$?
expect_rc "boot script, doctored report: BAR1 unlike every pciconf BAR is a FAIL" $rc 0
# expectations missing or malformed: FAIL, never skipped
bootrun "$W/bc" "$INFO"
line "$W/bc" '^FAIL BOOT_EXPECT_VRAM_BYTES' && line "$W/bc" '^FAIL BOOT_EXPECT_SM' && line "$W/bc" '^FAIL GPU 0 vram_size ' && line "$W/bc" '^FAIL GPU 0 compute capability '; rc=$?
expect_rc "boot script: without BOOT_EXPECT_* the run FAILs (nothing is skipped)" $rc 0
line "$W/bc" '^FAIL BOOT_EXPECT_VRAM_BYTES must be the board.s nominal VRAM in bytes (e.g. 17179869184' && line "$W/bc" '^FAIL BOOT_EXPECT_VRAM_RESERVE_MAX_BYTES must be the most the driver may reserve, in bytes, below the nominal VRAM (e.g. 268435456' && line "$W/bc" '^FAIL BOOT_EXPECT_SM must be the board.s compute capability as major.minor (e.g. 12.0)'; rc=$?
expect_rc "boot script: a missing expectation FAILs with a sentence that says what to set, with an example" $rc 0
bootrun "$W/bc2" "$INFO" BOOT_EXPECT_VRAM_BYTES=16G BOOT_EXPECT_VRAM_RESERVE_MAX_BYTES=256M BOOT_EXPECT_SM=12
line "$W/bc2" '^FAIL BOOT_EXPECT_VRAM_BYTES' && line "$W/bc2" '^FAIL BOOT_EXPECT_VRAM_RESERVE_MAX_BYTES' && line "$W/bc2" '^FAIL BOOT_EXPECT_SM' && line "$W/bc2" "got '16G'" && line "$W/bc2" "got '256M'"; rc=$?
expect_rc "boot script: malformed BOOT_EXPECT_* values FAIL and are quoted back" $rc 0
line "$W/bc" '^FAIL BOOT_EXPECT_VRAM_BYTES .*make-be.sh -V' && line "$W/bc" '^FAIL BOOT_EXPECT_VRAM_RESERVE_MAX_BYTES .*make-be.sh -R .*nvidia_native_tools_testboot_vram_reserve' && line "$W/bc" '^FAIL BOOT_EXPECT_SM .*make-be.sh -S'; rc=$?
expect_rc "boot script: each expectation FAIL names the make-be.sh option and the rc.conf variable that sets it" $rc 0
bootrun "$W/bc3" "$INFO" BOOT_EXPECT_VRAM_BYTES=$BOARD_VRAM_BYTES BOOT_EXPECT_VRAM_RESERVE_MAX_BYTES=$BOARD_VRAM_BYTES BOOT_EXPECT_SM=$BOARD_SM
line "$W/bc3" '^FAIL BOOT_EXPECT_VRAM_RESERVE_MAX_BYTES must be .*below the nominal VRAM'; rc=$?
expect_rc "boot script: a reserve that is not below the nominal VRAM is a FAIL" $rc 0
bootrun "$W/bc4" "$INFO" BOOT_EXPECT_VRAM_BYTES=0 BOOT_EXPECT_VRAM_RESERVE_MAX_BYTES=$BOARD_VRAM_RESERVE_MAX_BYTES BOOT_EXPECT_SM=$BOARD_SM
line "$W/bc4" '^PASS BOOT_EXPECT_VRAM_RESERVE_MAX_BYTES is '; rc=$?
expect_rc "boot script: any reserve is accepted when the nominal VRAM is 0" $rc 0
sh "$T/boot_nvrm_info.sh" 2>&1 | grep -q 'usage: BOOT_EXPECT_VRAM_BYTES=N BOOT_EXPECT_VRAM_RESERVE_MAX_BYTES=R BOOT_EXPECT_SM=M.m'; rc=$?
expect_rc "boot script: the usage line names the three required variables" $rc 0
grep -q SYSCTLMARK-HW "$W/ba/sysctl.txt" && grep -q SYSCTLMARK-DEV "$W/ba/sysctl.txt"; rc=$?
expect_rc "boot script: the hw.nvidia and the dev.nvidia reads both go through the stand-in" $rc 0
grep -qx 'hw.nvidia' "$W/ba.calls" && grep -qx 'dev.nvidia' "$W/ba.calls" && ! grep -E '^hw\.nvidia\.' "$W/ba.calls" >/dev/null; rc=$?
expect_rc "boot script: one read of hw.nvidia and one of dev.nvidia, no narrower hw.nvidia.* call (they are in the node)" $rc 0
line "$W/ba" '^PASS GPU 0 uuid .*unit 0 found by pci_bus_id 0000:0d:00.0'; rc=$?
expect_rc "boot script, true values: the uuid is found through dev.nvidia.<unit>.pci_bus_id and passes" $rc 0
line "$W/ba" '^PASS versions.driver ' && line "$W/ba" '^PASS nvrm-info running_rm_version is available and equals versions.driver.string'; rc=$?
expect_rc "boot script, true values: the driver version integers and the running RM version pass" $rc 0
grep -q '^dev.nvidia.0.pci_bus_id: ' "$W/ba/sysctl.txt" && grep -q '^hw.nvidia.version_major: ' "$W/ba/sysctl.txt"; rc=$?
expect_rc "boot script: sysctl.txt captures the hw.nvidia and dev.nvidia nodes" $rc 0
bootrun "$W/bu1" "$INFO" $EXP STUB_DEV_UUID=GPU-00000000-0000-4000-8000-0000000000a2
line "$W/bu1" '^FAIL GPU 0 uuid '; rc=$?
expect_rc "boot script: a different dev.nvidia.<unit>.uuid is a FAIL" $rc 0
bootrun "$W/bu2" "$INFO" $EXP STUB_HW_UUID=GPU-00000000-0000-4000-8000-0000000000a2
line "$W/bu2" '^FAIL GPU 0 uuid '; rc=$?
expect_rc "boot script: a different hw.nvidia.gpus.<unit>.uuid is a FAIL" $rc 0
bootrun "$W/bu3" "$INFO" $EXP STUB_BUS_ID=0000:0e:00.0
line "$W/bu3" '^FAIL GPU 0 uuid: no dev.nvidia.<unit> is at 0000:0d:00.0'; rc=$?
expect_rc "boot script: no sysctl unit at the device location is a FAIL naming the location" $rc 0
bootrun "$W/bu4" "$INFO" $EXP STUB_VERSION_AVAILABLE=0
line "$W/bu4" '^FAIL versions.driver '; rc=$?
expect_rc "boot script: hw.nvidia.version_available 0 is a FAIL" $rc 0
bootrun "$W/bu5" "$INFO" BOOT_EXPECT_VRAM_BYTES=17179869184 BOOT_EXPECT_VRAM_RESERVE_MAX_BYTES=1 BOOT_EXPECT_SM=12.0
line "$W/bu5" '^PASS GPU 0 vram_size '; rc=$?
expect_rc "boot script: VRAM equal to the nominal size passes with a reserve of 1" $rc 0
bootrun "$W/bu6" "$INFO" BOOT_EXPECT_VRAM_BYTES=17179869183 BOOT_EXPECT_VRAM_RESERVE_MAX_BYTES=1 BOOT_EXPECT_SM=12.0
line "$W/bu6" '^FAIL GPU 0 vram_size '; rc=$?
expect_rc "boot script: VRAM above the nominal size is a FAIL" $rc 0
bootrun "$W/bu7" "$INFO" BOOT_EXPECT_VRAM_BYTES=17179869186 BOOT_EXPECT_VRAM_RESERVE_MAX_BYTES=1 BOOT_EXPECT_SM=12.0
line "$W/bu7" '^FAIL GPU 0 vram_size nvrm-info=17179869184 expected 17179869185\.\.17179869186 '; rc=$?
expect_rc "boot script: VRAM below nominal minus the largest reserve is a FAIL" $rc 0
# BAR1 is the BAR at config offset 0x14, and nothing else counts
bootrun "$W/bd" "$INFO" $EXP BOOT_PCICONF="sh $W/pciconf-badbar.sh"
line "$W/bd" '^FAIL GPU 0 bar1_size .*BAR1 (config offset 0x14)'; rc=$?
expect_rc "boot script: BAR1 unlike the BAR at 0x14 (an I/O window of that size does not count) FAILs" $rc 0
bootrun "$W/bd2" "$INFO" $EXP BOOT_PCICONF="sh $W/pciconf-bar0.sh"
line "$W/bd2" '^FAIL GPU 0 bar1_size .*BAR1 (config offset 0x14)'; rc=$?
expect_rc "boot script: a bar1_size equal to BAR0 (the registers) but not to BAR1 FAILs" $rc 0
bootrun "$W/bd3" "$INFO" $EXP BOOT_PCICONF="sh $W/pciconf-other.sh"
line "$W/bd3" '^FAIL GPU 0 bar1_size cannot be checked: no pciconf -lvb line has' && ! line "$W/bd3" 'BAR1 (config offset'; rc=$?
expect_rc "boot script: a GPU missing from pciconf says so, not 'mismatch'" $rc 0
bootrun "$W/bd4" "$INFO" $EXP BOOT_PCICONF="sh $W/pciconf-nobar1.sh"
line "$W/bd4" '^FAIL GPU 0 bar1_size cannot be checked: .*no memory BAR at config offset 0x14'; rc=$?
expect_rc "boot script: a device with no BAR at 0x14 says so" $rc 0
# no GPU on a board that has one
bootrun "$W/be" "$INFO" $EXP NVRM_FAKE_FAIL=nogpu
line "$W/be" '^FAIL nvrm-info reports at least one GPU: none reported; check hw.nvidia.gpus in sysctl.txt and dmesg-nvrm.txt'; rc=$?
expect_rc "boot script: zero GPUs on the test board is a FAIL" $rc 0
# the Linux layer: exact module names plus compat.linux, never linuxkpi
bootrun "$W/bk" "$INFO" $EXP BOOT_KLDSTAT="sh $W/kld-lkpi.sh"
grep -q 'linuxkpi\.ko' "$W/bk/kldstat.txt" && ! grep -q 'linux64\.ko' "$W/bk/kldstat.txt"; rc=$?
expect_rc "boot script, linuxkpi case: the stub kldstat was used" $rc 0
line "$W/bk" '^PASS no Linux ABI kmod loaded' && ! line "$W/bk" '^FAIL a Linux ABI kmod'; rc=$?
expect_rc "boot script: linuxkpi.ko and linuxkpi_video.ko are not a Linux layer (no FAIL)" $rc 0
line "$W/bk" '^PASS compat.linux.osrelease does not answer'; rc=$?
expect_rc "boot script: an absent compat.linux.osrelease (unknown oid) is a PASS" $rc 0
for m in linux.ko linux64.ko linux_common.ko; do
	bootrun "$W/bk-$m" "$INFO" $EXP BOOT_KLDSTAT="sh $W/kld-$m.sh"
	line "$W/bk-$m" "^FAIL a Linux ABI kmod ($m) is loaded .*linux_enable=NO.*kld_list"; rc=$?
	expect_rc "boot script: $m loaded is a FAIL that names it and says how to fix the test BE" $rc 0
done
bootrun "$W/bl" "$INFO" $EXP BOOT_KLDSTAT="sh $W/kld-lkpi.sh" BOOT_SYSCTL="sh $W/sysctl-linux.sh"
line "$W/bl" '^FAIL compat.linux.osrelease answers (5.15.0) .*built in (COMPAT_LINUX); boot a kernel without it' && line "$W/bl" '^PASS no Linux ABI kmod loaded' && ! line "$W/bl" 'linux_enable'; rc=$?
expect_rc "boot script: an answering compat.linux.osrelease with no Linux kmod says the ABI is built in (linux_enable would not help)" $rc 0
# a probe that could not look is not "absent": a broken or silent sysctl FAILs
for b in broken silent; do
	bootrun "$W/bm-$b" "$INFO" $EXP BOOT_KLDSTAT="sh $W/kld-lkpi.sh" BOOT_SYSCTL="sh $W/sysctl-$b.sh"
	line "$W/bm-$b" '^FAIL compat.linux.osrelease could not be read.*run as root and read' && ! line "$W/bm-$b" '^PASS compat.linux.osrelease does not answer'; rc=$?
	expect_rc "boot script: a $b sysctl is a FAIL (the probe proves nothing), never a PASS" $rc 0
done
# a module loaded between the first look and the end of the run is seen
rm -f "$W/kld-count"
bootrun "$W/bn" "$INFO" $EXP BOOT_KLDSTAT="sh $W/kld-late.sh"
line "$W/bn" '^PASS no Linux ABI kmod loaded before nvrm-info runs' && line "$W/bn" '^FAIL a Linux ABI kmod (linux64.ko) is loaded after nvrm-info ran'; rc=$?
expect_rc "boot script: a Linux module that appears while nvrm-info runs is a FAIL (before PASS, after FAIL)" $rc 0
# a module list that cannot be read is not an empty one
bootrun "$W/bo" "$INFO" $EXP BOOT_KLDSTAT="sh $W/kld-nokernel.sh"
line "$W/bo" '^FAIL kldstat output before nvrm-info runs does not name the kernel.*run as root and check kldstat' && ! line "$W/bo" '^PASS no Linux ABI kmod'; rc=$?
expect_rc "boot script: a kldstat that does not name the kernel is a FAIL, not 'no Linux module'" $rc 0
grep -q 'linux_enable' "$T/boot_nvrm_info.sh"; rc=$?
expect_rc "boot script: documents that the test BE must disable linux_enable" $rc 0

# ---- core lint and its plant --------------------------------------------
sh "$T/lint_core.sh" "$L" 2>"$W/lint.err"; rc=$?
expect_rc "core and build files name no chip and no Linux layer" $rc 0
M=$W/mut-lint
mkdir -p "$M" && cp -R "$L" "$M/libnvrm" && printf '/* plant */ int x = 0xcec0; /* Blackwell */\n' >>"$M/libnvrm/nvrm.c"
sh "$T/lint_core.sh" "$M/libnvrm" >/dev/null 2>&1; rc=$?
if [ $rc -ne 0 ]; then ok "lint plant: a chip name in nvrm.c is caught"; else bad "lint plant: not caught"; fi
M=$W/mut-newfile
mkdir -p "$M" && cp -R "$L" "$M/libnvrm" && printf 'int x = 0xcec0;\n' >"$M/libnvrm/nvrm_new.c"
sh "$T/lint_core.sh" "$M/libnvrm" >/dev/null 2>&1; rc=$?
if [ $rc -ne 0 ]; then ok "lint plant: a chip id in a NEW core file is caught"; else bad "lint plant: new file not caught"; fi
M=$W/mut-exempt
mkdir -p "$M" && cp -R "$L" "$M/libnvrm" && printf 'int x = 0xcec0; /* see nvrm_table */\n' >>"$M/libnvrm/nvrm.c"
sh "$T/lint_core.sh" "$M/libnvrm" >/dev/null 2>&1; rc=$?
if [ $rc -ne 0 ]; then ok "lint plant: a mention of the table does not exempt a line"; else bad "lint plant: exemption by comment"; fi
sh "$T/lint_core.sh" "$W/no-such-dir" >/dev/null 2>&1; rc=$?
if [ $rc -ne 0 ]; then ok "lint plant: a missing directory fails"; else bad "lint plant: missing directory passed"; fi
M=$W/mut-linux
mkdir -p "$M" && cp -R "$L" "$M/libnvrm" && printf '#include <linux/types.h>\n' >>"$M/libnvrm/nvrm_rm.c"
sh "$T/lint_core.sh" "$M/libnvrm" >/dev/null 2>&1; rc=$?
if [ $rc -ne 0 ]; then ok "lint plant: a Linux include is caught"; else bad "lint plant: Linux include not caught"; fi

# ---- no Linux, no LinuxKPI -------------------------------------------------
needed() {	# needed BINARY ALLOWED-REGEX: fail closed when the binary cannot be read
	readelf -d "$1" >"$W/dyn.txt" 2>&1 || return 2
	grep -q 'NEEDED' "$W/dyn.txt" || return 3
	grep NEEDED "$W/dyn.txt" | grep -viE "$2" >"$W/needed.txt"
	[ ! -s "$W/needed.txt" ]
}
needed "$INFO" 'libnvrm|libc\.so|libthr'; rc=$?
expect_rc "nvrm-info needs only libnvrm and libc" $rc 0
needed "$O/lib/libnvrm.so.1" 'libc\.so|libthr\.so'; rc=$?
expect_rc "libnvrm needs only libc and libthr (pthread_once for the registry)" $rc 0
readelf -d "$O/lib/libnvrm.so.1" | grep NEEDED | grep -q libthr; rc=$?
expect_rc "libnvrm links libthr: without it the libc stub of pthread_once does nothing" $rc 0
needed "$W/no-such-binary" 'libc'; rc=$?
if [ $rc -ne 0 ]; then ok "needed-libraries check plant: an unreadable binary fails"; else bad "needed-libraries check passes on a missing binary"; fi
nm -D "$O/lib/libnvrm.so.1" >"$W/nm.txt" 2>&1 && [ -s "$W/nm.txt" ]; rc=$?
expect_rc "the library symbols can be read" $rc 0
grep -iE ' U .*(linux|lkpi)' "$W/nm.txt" >/dev/null; rc=$?
expect_rc "libnvrm imports no Linux or LinuxKPI symbol" $rc 1
printf 'info loaded kernel modules named linux*: '
kldstat | awk '{print $5}' | grep -ciE '^linux' | tr -d '\n'
printf ' (nvrm-info with the fake backend never touches a kernel module; the live run\n'
printf 'on the RM backend with no linux kmod loaded is shown by boot_nvrm_info.sh in a test boot once the driver loads without LinuxKPI)\n'

# ---- header version vs SOURCES, exported symbols --------------------------
want=$(awk '$1=="ogkm_tag"{print $2}' "$SRC/SOURCES")
grep -q "#define NVRM_RM_VERSION		\"$want\"" "$L/include/nvrm/nvrm.h"; rc=$?
expect_rc "NVRM_RM_VERSION equals SOURCES ogkm_tag ($want)" $rc 0
nm -D --defined-only "$O/lib/libnvrm.so.1" | awk '$2=="T"{sub(/@.*/,"",$3); print $3}' | sort -u >"$W/exported.txt"
# declarations only: a comment line (one that starts with "/*" or " *") may
# name a manual page, nvrm_mem(3), which is not a function
grep -vE '^[[:space:]]*/?\*' "$L/include/nvrm/nvrm.h" "$L/include/nvrm/nvrm_chan.h" | grep -oE '\bnvrm_[a-z_0-9]+\(' | tr -d '(' | sort -u >"$W/declared.txt"
cmp -s "$W/exported.txt" "$W/declared.txt"; rc=$?
expect_rc "the library exports exactly the functions its public headers declare" $rc 0
[ $rc -eq 0 ] || diff "$W/exported.txt" "$W/declared.txt"
# symbol versions: discovery is NVRM_1.0, memory and VA NVRM_1.1, version
# numbers NVRM_1.2, channels NVRM_1.3, and each version's calls are the ones its
# man page documents
nm -D --defined-only "$O/lib/libnvrm.so.1" | awk '$2=="T" && $3 ~ /@@NVRM_1\.0$/ {sub(/@@.*/,"",$3); print $3}' | sort >"$W/exported10.txt"
nm -D --defined-only "$O/lib/libnvrm.so.1" | awk '$2=="T" && $3 ~ /@@NVRM_1\.1$/ {sub(/@@.*/,"",$3); print $3}' | sort >"$W/exported11.txt"
nm -D --defined-only "$O/lib/libnvrm.so.1" | awk '$2=="T" && $3 ~ /@@NVRM_1\.2$/ {sub(/@@.*/,"",$3); print $3}' | sort >"$W/exported12.txt"
nm -D --defined-only "$O/lib/libnvrm.so.1" | awk '$2=="T" && $3 ~ /@@NVRM_1\.3$/ {sub(/@@.*/,"",$3); print $3}' | sort >"$W/exported13.txt"
[ -s "$W/exported10.txt" ] && [ -s "$W/exported11.txt" ] && [ -s "$W/exported12.txt" ] && [ -s "$W/exported13.txt" ] && [ $(cat "$W/exported10.txt" "$W/exported11.txt" "$W/exported12.txt" "$W/exported13.txt" | wc -l) -eq $(wc -l <"$W/exported.txt") ]; rc=$?
expect_rc "every export is in NVRM_1.0, NVRM_1.1, NVRM_1.2 or NVRM_1.3, and all are used" $rc 0
readelf --dyn-syms -W "$O/lib/libnvrm.so.1" | grep -q 'nvrm_client_open@@NVRM_1\.1' && readelf --dyn-syms -W "$O/lib/libnvrm.so.1" | grep -q 'nvrm_enumerate@@NVRM_1\.0' && readelf --dyn-syms -W "$O/lib/libnvrm.so.1" | grep -q 'nvrm_chan_create@@NVRM_1\.3'; rc=$?
expect_rc "readelf: discovery, memory and channel symbol versions" $rc 0
# (LLD does not write the parent of a version node into the object, so the
# inheritance is checked where it is declared)
grep -q '^} NVRM_1\.0;$' "$L/Version.map" && grep -q '^} NVRM_1\.1;$' "$L/Version.map" && grep -q '^} NVRM_1\.2;$' "$L/Version.map"; rc=$?
expect_rc "Version.map: NVRM_1.1 inherits NVRM_1.0, NVRM_1.2 NVRM_1.1 and NVRM_1.3 NVRM_1.2" $rc 0
for v in NVRM_1.0 NVRM_1.1 NVRM_1.2 NVRM_1.3; do
	objdump -T "$O/lib/libnvrm.so.1" 2>/dev/null | grep -q "$v" || readelf -V "$O/lib/libnvrm.so.1" | grep -q "$v"
	rc=$?
	expect_rc "symbols carry the version $v" $rc 0
done
for f in nvrm_driver_version nvrm_rm_api_version nvrm_built_for_version nvrm_library_version nvrm_symbol_version nvrm_schema_version; do
	readelf -Ws "$O/lib/libnvrm.so.1" | grep -Eq "$f@+NVRM_1[.]2([[:space:]]|$)"; rc=$?
	expect_rc "$f is exported at NVRM_1.2" $rc 0
done

# ---- man pages ---------------------------------------------------------------
for m in "$L/man/nvrm.3" "$L/man/nvrm_chan.3" "$L/man/nvrm.7" "$L/nvrm-info/nvrm-info.8"; do
	mandoc -T lint -W warning "$m" >"$W/mandoc.out" 2>&1; rc=$?
	expect_rc "mandoc -T lint: $(basename "$m")" $rc 0
done
printf '.Dd November 21, 2026\n.Dt BAD 3\n.Os\n.Sh NAME\n.Nm bad\n.Xx nonsense\n' >"$W/bad.3"
mandoc -T lint -W warning "$W/bad.3" >/dev/null 2>&1; rc=$?
if [ $rc -ne 0 ]; then ok "man lint plant: a broken page fails mandoc"; else bad "man lint plant: broken page passed"; fi
for code in $(grep -oE 'NVRM_E_[A-Z]+' "$L/include/nvrm/nvrm.h" | sort -u | grep -v -e NVRM_E__COUNT); do
	grep -q "$code" "$L/man/nvrm.3" "$L/man/nvrm_chan.3"; rc=$?
	expect_rc "nvrm(3) or nvrm_chan(3) documents $code" $rc 0
done
for r in not_queried rm_control_failed rm_not_supported os_not_reported family_unknown family_has_no_class input_unavailable no_numa_node backend_does_not_provide class_absent os_call_failed value_unusable version_unparsed version_inconsistent; do
	grep -q "$r" "$L/man/nvrm.7"; rc=$?
	expect_rc "nvrm(7) documents reason $r" $rc 0
done
for cap in $(awk '$1 == "capability" { print $3 }' "$IDS"); do
	grep -q "$cap" "$L/man/nvrm.7"; rc=$?
	expect_rc "nvrm(7) documents capability $cap" $rc 0
done
for f in NVRM_ENUM_ALLOW_ALLOC; do
	grep -qi "$f" "$L/man/nvrm.3" && grep -qi "$f" "$L/man/nvrm.7" && grep -qi "$f" "$SRC/README.md"; rc=$?
	expect_rc "nvrm(3), nvrm(7) and the README document $f" $rc 0
done
grep -qi "zero-initialize" "$L/man/nvrm.3"; rc=$?
expect_rc "nvrm(3) tells callers to zero-initialize the options" $rc 0
cat "$W/exported10.txt" "$W/exported12.txt" | sort >"$W/exported10_12.txt"
for pg in nvrm:10_12:NVRM_FUNCS nvrm_mem:11:NVRM_MEM_FUNCS nvrm_chan:13:NVRM_CHAN_FUNCS; do
	_page=${pg%%:*}; _rest=${pg#*:}; _v=${_rest%%:*}; _var=${_rest#*:}
	case $_v in 10_12) _lbl="NVRM_1.0 and NVRM_1.2" ;; *) _lbl="NVRM_1.${_v#1}" ;; esac
	sed -n '/^\.Sh SYNOPSIS/,/^\.Sh DESCRIPTION/p' "$L/man/$_page.3" | grep -oE '^\.Fn nvrm_[a-z_0-9]+' | awk '{print $2}' | sort -u >"$W/man-fn-$_page.txt"
	grep -oE '^\.Nm nvrm_[a-z_0-9]+' "$L/man/$_page.3" | awk '{print $2}' | sort -u >"$W/man-nm-$_page.txt"
	(cd "$L" && make -V "$_var" OGKM=$OGKM) | tr ' ' '\n' | grep '^nvrm_' | sort -u >"$W/mk-$_page.txt"
	cmp -s "$W/exported$_v.txt" "$W/man-fn-$_page.txt"; rc=$?
	expect_rc "$_page(3) SYNOPSIS has every $_lbl function" $rc 0
	cmp -s "$W/exported$_v.txt" "$W/man-nm-$_page.txt"; rc=$?
	expect_rc "$_page(3) NAME has every $_lbl function" $rc 0
	cmp -s "$W/exported$_v.txt" "$W/mk-$_page.txt"; rc=$?
	expect_rc "the Makefile man links to $_page(3) cover every $_lbl function" $rc 0
done
mandoc -T lint -W warning "$L/man/nvrm_mem.3" >"$W/lint-mem.out" 2>&1; rc=$?
expect_rc "nvrm_mem(3) passes mandoc -T lint" $rc 0
! grep -qx 'placeholder' "$L/man/nvrm_mem.3"; rc=$?
expect_rc "nvrm_mem(3) is a real page, not a placeholder" $rc 0
grep -q 'nvrm_enumerate' "$L/man/nvrm.3" && grep -q 'nvrm_json_schema' "$L/man/nvrm.3" && grep -q -- '--jsonl' "$L/nvrm-info/nvrm-info.8"
rc=$?
expect_rc "man pages cover the calls and every nvrm-info option" $rc 0
for f in nvrm_version nvrm_version_parse nvrm_version_find nvrm_version_format; do
	grep -q "$f" "$L/man/nvrm.3"; rc=$?
	expect_rc "nvrm(3) documents $f" $rc 0
done
grep -q 'versions' "$L/man/nvrm.3" && grep -q 'parts' "$L/man/nvrm.3" && grep -q 'source' "$L/man/nvrm.3"; rc=$?
expect_rc "nvrm(3) documents the JSON version object and its integer parts" $rc 0
grep -q 'compute_capability_major' "$L/man/nvrm.7" && grep -q 'rm_sm_version' "$L/man/nvrm.7" && grep -q 'minor 3;' "$L/man/nvrm.7"; rc=$?
expect_rc "nvrm(7) distinguishes compute capability from RM SM numbering and names schema minor 3" $rc 0
for s in version_string version_major version_minor version_patch version_suffix version_available; do
	grep -q "hw.nvidia.$s" "$L/nvrm-info/nvrm-info.8"; rc=$?
	expect_rc "nvrm-info(8) documents hw.nvidia.$s" $rc 0
done
grep -q 'versions' "$L/nvrm-info/nvrm-info.8" && grep -q 'compute_capability' "$L/nvrm-info/nvrm-info.8" && grep -q 'sm_version' "$L/nvrm-info/nvrm-info.8"; rc=$?
expect_rc "nvrm-info(8) documents the versions object and compute versus RM SM versions" $rc 0

# ---- what the docs promise is what the code does ---------------------------------
# doc_checks LIBDIR README: prints one line per broken promise, returns their count.
doc_checks() {
	_l=$1; _readme=$2; _bad=0
	_chk() { if ! "$@"; then _bad=$((_bad + 1)); fi; }
	# mapping: the enumeration descriptors never map; mapping is a client
	# opened with NVRM_OPEN_ALLOW_MAP, and the pages say so
	for f in "$_l/man/nvrm.3" "$_l/man/nvrm.7"; do
		_chk sh -c '! grep -qiE "map memory after|and the mapping right|ALLOW_ALLOC_MAP|in capability mode is not available" "$1" || { echo "docs: $1 promises or hedges mapping"; false; }' sh "$f"
		_chk sh -c 'grep -q "enumeration descriptors never carry a mapping right" "$1" || { echo "docs: $1 omits that the enumeration descriptors never map"; false; }' sh "$f"
		_chk sh -c 'grep -q "NVRM_OPEN_ALLOW_MAP" "$1" && grep -q "nvrm_mem 3" "$1" || { echo "docs: $1 does not say where mapping is (nvrm_mem(3), NVRM_OPEN_ALLOW_MAP)"; false; }' sh "$f"
	done
	_chk sh -c 'grep -q "NVRM_OPEN_ALLOW_MAP" "$1" && grep -q "nvrm_mem_map_cpu() is refused with NVRM_E_DENIED" "$1" || { echo "docs: nvrm.h does not state the mapping opt-in"; false; }' sh "$_l/include/nvrm/nvrm.h"
	_chk sh -c 'grep -q "^.Sh ERRORS" "$1" && grep -q "NVRM_E_NOSLOT" "$1" && grep -q "failed_releases" "$1" && grep -q "Device" "$1" || { echo "docs: nvrm_mem(3) lacks errors, slots, refused releases or the Device rule"; false; }' sh "$_l/man/nvrm_mem.3"
	_chk sh -c 'grep -q "^.Ss Memory attributes" "$1" || { echo "docs: nvrm(7) lacks the memory attribute rule"; false; }' sh "$_l/man/nvrm.7"
	_chk sh -c '! grep -q "nvrm_mem(7)" "$1" || { echo "docs: $1 names a page that does not exist"; false; }' sh "$_l/include/nvrm/nvrm.h"
	# the fork rule as the code has it, the arm64 rule with both constants,
	# and the memory page in plain words
	_chk sh -c '! grep -q "every other call is refused" "$1" && grep -q "a release (unmap, free, VA release, close) succeeds" "$1" && grep -q "INHERIT_NONE" "$1" || { echo "docs: nvrm.h states a fork rule the code does not have"; false; }' sh "$_l/include/nvrm/nvrm.h"
	_chk sh -c 'grep -q "Releases succeed and release only what the child holds" "$1" && grep -q "GPU mappings only" "$1" && ! grep -q "(0: " "$1" && ! grep -q "card list" "$1" || { echo "docs: nvrm_mem(3) fork rule, NOTSUP wording, (0: N) notation or card list"; false; }' sh "$_l/man/nvrm_mem.3"
	_chk sh -c 'sed -n "/^.It video memory, arm64/,/^.El/p" "$1" | grep -q "NVRM_ATTR_WC" && sed -n "/^.It video memory, arm64/,/^.El/p" "$1" | grep -q "is 0" || { echo "docs: nvrm(7) arm64 rule lacks NVRM_ATTR_WC or the flag value"; false; }' sh "$_l/man/nvrm.7"
	# installed docs say "this version", never a planning label
	for f in "$_l/man/nvrm.3" "$_l/man/nvrm_mem.3" "$_l/man/nvrm.7" "$_l/include/nvrm/nvrm.h" "$_readme"; do
		_chk sh -c '! grep -nE "\\bS[12]\\b|later step|future version provides" "$1" || { echo "docs: $1 uses a planning label (S1, S2, later step)"; false; }' sh "$f"
	done
	_chk sh -c '! grep -nE "Track #" "$1" || { echo "docs: the installed header names a ticket"; false; }' sh "$_l/include/nvrm/nvrm.h"
	_chk sh -c 'grep -q "^.Xr rfork 2" "$1" && grep -q "^.Xr vfork 2" "$1" || { echo "docs: nvrm(3) does not name the calls that run no fork handler"; false; }' sh "$_l/man/nvrm.3"
	_chk sh -c 'grep -q "NVRM_ENUM_ALLOW_ALLOC" "$1" || { echo "docs: the README does not name the flag that allows allocation"; false; }' sh "$_readme"
	# threads and fork
	_chk sh -c 'grep -q "^.Sh THREADS AND FORK" "$1" && grep -q "not safe for concurrent use" "$1" && grep -q "must not use a context except to call" "$1" || { echo "docs: nvrm(3) lacks the threads and fork rules"; false; }' sh "$_l/man/nvrm.3"
	_chk sh -c 'grep -q "not safe for concurrent" "$1" && grep -q "nvrm_close" "$1" || { echo "docs: nvrm.h lacks the threads and fork rules"; false; }' sh "$_l/include/nvrm/nvrm.h"
	_chk sh -c 'grep -q "The fake backend keeps process-wide test state" "$1" && grep -q "use it from one thread" "$1" || { echo "docs: nvrm.h does not limit the fake backend to one thread"; false; }' sh "$_l/include/nvrm/nvrm.h"
	_chk sh -c 'grep -q "^The fake backend keeps process-wide test state: use it from one thread" "$1" || { echo "docs: nvrm(3) does not limit the fake backend to one thread"; false; }' sh "$_l/man/nvrm.3"
	# provisional until the first package release
	_chk sh -c 'grep -qi "provisional" "$1" && grep -q "first package release" "$1" || { echo "docs: nvrm(3) does not say the interface is provisional"; false; }' sh "$_l/man/nvrm.3"
	_chk sh -c 'grep -q "PROVISIONAL" "$1" && grep -q "first package release" "$1" || { echo "docs: Version.map does not say NVRM_1.0 is provisional"; false; }' sh "$_l/Version.map"
	_chk sh -c 'grep -q "PROVISIONAL" "$1" || { echo "docs: nvrm.h does not say the interface is provisional"; false; }' sh "$_l/include/nvrm/nvrm.h"
	# no GPU is a success
	_chk sh -c 'grep -q "NVRM_E_NODEV$" "$1" && grep -q "is no longer returned" "$1" || { echo "docs: nvrm(3) does not say NVRM_E_NODEV is no longer returned"; false; }' sh "$_l/man/nvrm.3"
	_chk sh -c 'grep -q "^Text mode prints" "$1" && grep -q "empty list of devices" "$1" || { echo "docs: nvrm-info(8) does not say what no GPU prints in each mode"; false; }' sh "$_l/nvrm-info/nvrm-info.8"
	return $_bad
}
doc_checks "$L" "$SRC/README.md" >"$W/docs.out" 2>&1; rc=$?
[ $rc -eq 0 ] || cat "$W/docs.out"
expect_rc "docs: mapping, threads and fork, provisional ABI and no-GPU promises all hold" $rc 0
doc_plant() {	# doc_plant NAME FILE(relative to the lib dir) SED
	_p=$W/docplant.$1; rm -rf "$_p"; mkdir -p "$_p"; cp -R "$L"/man "$L"/include "$L"/nvrm-info "$L"/Version.map "$SRC/README.md" "$_p"/
	cp "$_p/$2" "$_p/orig"
	sed -i '' "$3" "$_p/$2"
	if cmp -s "$_p/$2" "$_p/orig"; then bad "docs plant $1: the edit did not apply"; return; fi
	doc_checks "$_p" "$_p/README.md" >/dev/null 2>&1; _rc=$?
	if [ $_rc -ne 0 ]; then ok "docs plant refused: $1"; else bad "docs plant NOT refused: $1"; fi
}
doc_plant mapping-promise man/nvrm.3 's/^A caller that will allocate RM objects after/A caller that will allocate RM objects or map memory after/'
doc_plant mapping-flag man/nvrm.7 's/NVRM_ENUM_ALLOW_ALLOC$/NVRM_ENUM_ALLOW_ALLOC_MAP/'
doc_plant mapping-limit-gone man/nvrm.3 's/enumeration descriptors never carry a mapping right/enumeration descriptors may map/'
doc_plant header-mapping include/nvrm/nvrm.h 's/nvrm_mem_map_cpu() is refused with NVRM_E_DENIED/nvrm_mem_map_cpu() works/'
doc_plant mapping-hedge man/nvrm.7 's/one for each CPU mapping it can make there\./CPU mapping in capability mode is not available./'
doc_plant mem-errors man/nvrm_mem.3 's/^\.Sh ERRORS/.Sh DIAGNOSTICS/'
doc_plant fork-claim include/nvrm/nvrm.h 's/a release (unmap, free, VA release, close) succeeds/every other call is refused/'
doc_plant notsup-backwards man/nvrm_mem.3 's/GPU mappings only/CPU mappings/'
doc_plant zero-notation man/nvrm_mem.3 's/(0 means 4) spare/(0: 4) spare/'
doc_plant arm64-wc man/nvrm.7 's/^is 0;$/is clear;/'
doc_plant mem-attr-rule man/nvrm.7 's/^\.Ss Memory attributes/.Ss Memory/'
doc_plant mem-page-name include/nvrm/nvrm.h 's/nvrm(7), Memory attributes/nvrm_mem(7)/'
doc_plant label-s2 man/nvrm_mem.3 's/^These calls allocate GPU memory/These S2 calls allocate GPU memory/'
doc_plant label-track include/nvrm/nvrm.h 's/^ \* ---- Memory and virtual address space (nvrm_mem(3))/ * ---- Memory (Track #2419)/'
doc_plant rfork-gone man/nvrm.3 's/^\.Xr rfork 2/.Xr setsid 2/'
doc_plant readme-flag README.md 's/NVRM_ENUM_ALLOW_ALLOC/NVRM_ENUM_ALLOW/'
doc_plant threads-gone man/nvrm.3 's/^\.Sh THREADS AND FORK/.Sh CAVEATS/'
doc_plant fork-gone man/nvrm.3 's/must not use a context except to call/may use a context, and call/'
doc_plant provisional-gone man/nvrm.3 's/This interface is provisional\./This interface is stable./'
doc_plant versionmap-provisional Version.map 's/PROVISIONAL/FIXED/'
doc_plant nodev-doc man/nvrm.3 's/is no longer returned/is returned/'
doc_plant nogpu-doc nvrm-info/nvrm-info.8 's/^Text mode prints/Text mode shows/'
doc_plant label-header include/nvrm/nvrm.h 's/this version of libnvrm$/S1/'
doc_plant label-man3 man/nvrm.3 's/a future version may still reshape them\./a later step may still reshape them./'
doc_plant label-readme README.md 's/^GPU memory (`nvrm_mem(3)`/S2 GPU memory (`nvrm_mem(3)`/'
doc_plant label-future man/nvrm.3 's/a future version may still reshape them\./a future version provides them./'
doc_plant fake-threads-man man/nvrm.3 's/^The fake backend keeps process-wide test state/The fake backend is thread-safe/'
doc_plant fake-threads-header include/nvrm/nvrm.h 's/The fake backend keeps process-wide test state/The fake backend is thread-safe/'
$INFO --help | grep -q 'including no GPU attached' && ! $INFO --help | grep -q 'devices is empty'; rc=$?
expect_rc "nvrm-info --help says no GPU attached is a success, without naming a JSON member" $rc 0

# ---- install layout -------------------------------------------------------------
D=$W/dest
U=$(id -un); G=$(id -gn)
OWN="LIBOWN=$U LIBGRP=$G SHLIBOWN=$U SHLIBGRP=$G SHAREOWN=$U SHAREGRP=$G MANOWN=$U MANGRP=$G BINOWN=$U BINGRP=$G INCOWN=$U INCGRP=$G FILESOWN=$U FILESGRP=$G DIROWN=$U DIRGRP=$G"
mkdir -p "$D/usr/include/nvrm" "$D/usr/lib" "$D/usr/sbin" "$D/usr/share/nvrm/schema" "$D/usr/share/man/man3" "$D/usr/share/man/man7" "$D/usr/share/man/man8"
(cd "$L" && MAKEOBJDIR=$O/lib make install DESTDIR=$D $OWN >"$W/inst1.log" 2>&1)
rc=$?
expect_rc "libnvrm installs" $rc 0
(cd "$L/nvrm-info" && MAKEOBJDIR=$O/info LIBNVRM_OBJ=$O/lib make install DESTDIR=$D $OWN >"$W/inst2.log" 2>&1)
rc=$?
expect_rc "nvrm-info installs" $rc 0
for f in usr/lib/libnvrm.so.1 usr/lib/libnvrm.a usr/sbin/nvrm-info usr/include/nvrm/nvrm.h usr/include/nvrm/nvrm_version.h usr/include/nvrm/nvrm_chan.h usr/share/nvrm/schema/nvrm-info-1.schema.json usr/share/man/man3/nvrm.3.gz usr/share/man/man3/nvrm_chan.3.gz usr/share/man/man7/nvrm.7.gz usr/share/man/man8/nvrm-info.8.gz; do
	[ -f "$D/$f" ]; rc=$?
	expect_rc "installed: $f" $rc 0
done
cmp -s "$D/usr/share/nvrm/schema/nvrm-info-1.schema.json" "$SCHEMA"; rc=$?
expect_rc "installed schema is the checked-in schema" $rc 0

printf '\nlibnvrm_test: %d ok, %d FAILED\n' "$PASS" "$FAIL"
exit $FAIL
