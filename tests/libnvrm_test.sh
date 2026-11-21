#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-2-Clause
#
# libnvrm_test.sh - the whole libnvrm S1 suite (Track #2378), on a FRESH COPY
# of the STAGED content (checkout-index; after a commit that is the commit),
# built out of tree with base LLD.  Stage new files before running it.  No
# hardware and no loaded driver are needed: the fake backend and a scripted
# kernel stand in; the live proof is tests/libnvrm/boot_nvrm_info.sh in a test boot.
#
# Steps: toolchain; library and tool build (schema drift check in the build);
# core + fake unit tests at 100% line and branch coverage; RM backend tests
# against the scripted kernel; Capsicum tests; JSON output of every mode
# validated against the schema; validator and gate mutants; CLI behaviour;
# core lint and its plant; no Linux dependency; man pages; install layout.
#
# Every check prints "ok" or "FAIL"; the exit status is the number of failures.
# Run: sh tests/libnvrm_test.sh        (OGKM=... to point at the NVIDIA headers)

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$HERE/.." && pwd)
GB10=${GB10_WORK:-$HOME/work/gb10}
TAG=$(awk '$1 == "ogkm_tag" { print $2 }' "$REPO/SOURCES")
OGKM=${OGKM:-$GB10/sources/open-gpu-kernel-modules-$TAG}
mkdir -p "$GB10/tmp" || exit 1
W=$(mktemp -d "$GB10/tmp/libnvrm-test.XXXXXXXX") || exit 1
trap 'rm -rf "$W"' EXIT INT TERM
unset NVRM_BACKEND NVRM_FAKE_PROFILE NVRM_FAKE_FAIL NVRM_TEST_SKIP

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
CINC="-I$L -I$L/include -I$T -std=gnu11 -Wall -Wextra -Wno-unused-parameter -DNVRM_FAULT_INJECT -I$OGKM/src/common/sdk/nvidia/inc -I$OGKM/src/common/sdk/nvidia/inc/ctrl -I$OGKM/src/nvidia/arch/nvalloc/unix/include"
LIBSRC="$L/nvrm.c $L/nvrm_cap.c $L/nvrm_fake.c $L/nvrm_fields.c $L/nvrm_json.c $L/nvrm_names.c $L/nvrm_table.c $L/nvrm_rm.c"
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

(cd "$W/cov" && LLVM_PROFILE_FILE=core.%p.profraw ./core_test)
rc=$?
expect_rc "core_test (registry, enumeration, model, decorators, JSON, fake)" $rc 0
(cd "$W/cov" && LLVM_PROFILE_FILE=rm.profraw ./rm_test)
rc=$?
expect_rc "rm_test (RM backend against the scripted kernel)" $rc 0
(cd "$W/cov" && ./cap_test)
rc=$?
expect_rc "cap_test (works in Capsicum capability mode, fake and rm)" $rc 0

(cd "$W/cov" && llvm-profdata merge -o core.profdata core.*.profraw && llvm-profdata merge -o rm.profdata rm.profraw)
GATED="nvrm.c nvrm_cap.c nvrm_fake.c nvrm_fields.c nvrm_json.c nvrm_names.c"
(cd "$W/cov" && llvm-cov export ./core_test -instr-profile=core.profdata --summary-only $L/nvrm.c $L/nvrm_cap.c $L/nvrm_fake.c $L/nvrm_fields.c $L/nvrm_json.c $L/nvrm_names.c | python3 -I "$T/coverage_gate.py" $GATED)
rc=$?
expect_rc "core + fake backend: 100% line and branch coverage" $rc 0
(cd "$W/cov" && llvm-cov export ./rm_test -instr-profile=rm.profdata --summary-only $L/nvrm_rm.c | python3 -I "$T/coverage_gate.py" nvrm_rm.c)
rc=$?
expect_rc "RM backend: 100% line and branch coverage by the scripted kernel" $rc 0

# gate plant: a skipped test group must drop coverage and fail the gate
(cd "$W/cov" && NVRM_TEST_SKIP=decorators LLVM_PROFILE_FILE=skip.profraw ./core_test >/dev/null && llvm-profdata merge -o skip.profdata skip.profraw && llvm-cov export ./core_test -instr-profile=skip.profdata --summary-only $L/nvrm.c | python3 -I "$T/coverage_gate.py" nvrm.c >"$W/plant.out" 2>&1)
rc=$?
if [ $rc -eq 1 ] && grep -q 'BELOW 100%' "$W/plant.out"; then ok "coverage gate plant: skipping the decorator tests fails the gate (BELOW 100%)"; else bad "coverage gate plant: not the gate's verdict (rc=$rc): $(cat "$W/plant.out")"; fi

# ---- source mutants: a wrong core must make a test fail ----------------------
mutant() {	# mutant NAME FILE SED-EXPR TEST(core_test|rm_test)
	MD=$W/mutsrc.$1
	rm -rf "$MD"; mkdir -p "$MD"; cp "$L"/*.c "$L"/*.h "$MD"/; cp -R "$L/include" "$MD/include"
	sed -i '' "$3" "$MD/$2"
	if cmp -s "$MD/$2" "$L/$2"; then bad "mutant $1: the edit did not apply"; return; fi
	cc -I"$MD" -I"$MD/include" -I"$T" -std=gnu11 -w -DNVRM_FAULT_INJECT -I$OGKM/src/common/sdk/nvidia/inc -I$OGKM/src/common/sdk/nvidia/inc/ctrl -I$OGKM/src/nvidia/arch/nvalloc/unix/include -o "$MD/t" "$T/$4.c" "$MD"/nvrm.c "$MD"/nvrm_cap.c "$MD"/nvrm_fake.c "$MD"/nvrm_fields.c "$MD"/nvrm_json.c "$MD"/nvrm_names.c "$MD"/nvrm_table.c "$MD"/nvrm_rm.c >"$MD/cc.log" 2>&1 || { bad "mutant $1: does not compile"; return; }
	"$MD/t" >/dev/null 2>&1
	if [ $? -ne 0 ]; then ok "mutant killed: $1"; else bad "mutant SURVIVED: $1"; fi
}
mutant sm-shift nvrm.c 's/>>= 8;/>>= 7;/' core_test
mutant sm-mask nvrm.c 's/&= 0xff;/\&= 0x7f;/' core_test
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
mutant cap-rights nvrm_cap.c 's/cap_rights_set(&rights, CAP_MMAP_RW)/cap_rights_set(\&rights, CAP_READ)/' cap_test
mutant rm-subsys nvrm_rm.c 's/b.pciSubSystemId \& 0xffff;/b.pciSubSystemId >> 16;/' rm_test
mutant rm-bar1 nvrm_rm.c 's/NV2080_CTRL_FB_INFO_INDEX_BAR1_SIZE/NV2080_CTRL_FB_INFO_INDEX_RAM_SIZE/' rm_test
mutant rm-strict nvrm_rm.c 's/NV_RM_API_VERSION_CMD_STRICT/NV_RM_API_VERSION_CMD_RELAXED/' rm_test
mutant rm-order nvrm_rm.c 's/NV_ESC_CHECK_VERSION_STR, \\/NV_ESC_CARD_INFO, \\/' rm_test
mutant rm-device nvrm_rm.c 's/rm_alloc(be, g->device, \&g->subdevice/rm_alloc(be, be->client, \&g->subdevice/' rm_test
mutant rm-reply nvrm_rm.c 's/v.reply != NV_RM_API_VERSION_REPLY_RECOGNIZED/0/' rm_test
mutant rm-pci-check nvrm_rm.c 's/(b.pciDeviceId \& 0xffff) != g->card.pci_info.vendor_id/0/' rm_test
mutant rm-classes-max nvrm_rm.c 's/lim = max < /lim = 1000 < /' rm_test
mutant json-comma nvrm_json.c 's/k++ != 0 ? "," : ""/i != 0 ? "," : ""/' core_test
mutant decorator-bound nvrm.c 's/if ((unsigned)d->caps\[i\].index >= NVRM_NCAPS)/if (0)/' core_test
mutant refresh-status nvrm.c 's/NVRM_E_IO : NVRM_OK/NVRM_OK : NVRM_OK/' core_test
mutant rm-least-privilege nvrm_rm.c 's/if (!allow_alloc_map)/if (0)/' cap_test
mutant opts-default nvrm.c 's/opts != NULL \&\& (opts->flags \& NVRM_ENUM_ALLOW_ALLOC_MAP) != 0/1/' cap_test
mutant struct-member include/nvrm/nvrm.h 's/nvrm_u64	vram_size, bar1_size/nvrm_u64	l2_size, vram_size, bar1_size/' core_test
mutant fields-bound nvrm_fields.c 's/index < nvrm_nfields ?/1 ?/' core_test
mutant fields-abort nvrm_fields.c 's/abort();/return (NULL);/' core_test
mutant family-no-value nvrm.c 's/NVRM_R_FAMILY_NO_CLASS, NVRM_S_FAMILY/NVRM_R_FAMILY_UNKNOWN, NVRM_S_FAMILY/' core_test
mutant pci-unusable nvrm_rm.c 's/return (NVRM_R_VALUE_UNUSABLE);/return (NVRM_R_RM_FAILED);/' rm_test
mutant rm-pci-nocard nvrm_rm.c 's/if (!g->have_card)/if (0)/' rm_test
mutant gpc-width nvrm.c 's/(mask >> NVRM_MAX_GPCS) != 0/0/' core_test
mutant enumerate-call-failure nvrm.c 's/if (info_has_call_failure(&ctx->dev\[i\].info))/if (0)/' core_test
mutant rm-version-errno nvrm_rm.c 's/rc != 0 \&\& errno != EINVAL/0/' rm_test
mutant rm-leak nvrm_rm.c 's/	rm_free(g->be, g->device, g->subdevice);//' rm_test

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
assert [c['index'] for c in d['capabilities']]==list(range(7))
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
m = copy.deepcopy(good); m["devices"][0]["capabilities"].pop(); dump("caps", m)
m = copy.deepcopy(good); m["devices"][0]["gpu"]["classes"]["value"] = ["x"]; dump("list", m)
m = copy.deepcopy(good); m["devices"][0]["memory"]["numa_node"] = {"available": True, "reason": "x"}; dump("both", m)
m = copy.deepcopy(good); m["kind"] = "bogus"; dump("kind", m)
PY
for m in missing extra type reason schema negative caps list both kind; do
	$VAL "$W/mut-$m.json" >/dev/null
	rc=$?
	if [ $rc -eq 1 ]; then ok "validator mutant refused: $m"; else bad "validator accepted mutant $m (rc=$rc)"; fi
done

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
grep -q 'pci_bus  *13 ' "$W/text.out"; rc=$?
expect_rc "text mode prints the PCI location in decimal like pciconf" $rc 0
# the text view lists every field of the table (it walks the same table)
python3 -I - "$W/out.json" "$W/text.out" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))["devices"][0]
text = open(sys.argv[2]).read()
names = [k for g in ("identity", "gpu", "memory") for k in doc[g]]
missing = [n for n in names if (" " + n + " ") not in text]
assert not missing, missing
PY
rc=$?
expect_rc "text mode names every field of the JSON device" $rc 0
for f in open version list nogpu gpu_open limit; do
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
grep -q '^FAIL a linux or linux64 kmod is loaded' "$W/boot3/results.txt"; rc=$?
expect_rc "boot script: a loaded linux kmod is a FAIL" $rc 0
# without BOOT_ALLOW_FAKE the stub is ignored: the record shows the real kldstat
mkdir -p "$W/boot4"
printf '#!/bin/sh\necho " 1 5 0x0 0x0 STUBMARK.ko"\n' >"$W/kldstub2.sh"
BOOT_KLDSTAT="sh $W/kldstub2.sh" sh "$T/boot_nvrm_info.sh" "$W/boot4" "$INFO" >/dev/null 2>&1
! grep -q STUBMARK "$W/boot4/kldstat.txt"; rc=$?
expect_rc "boot script: BOOT_KLDSTAT is ignored unless BOOT_ALLOW_FAKE is set" $rc 0
grep -q '^PASS nvrm-info was built for the SOURCES ogkm_tag' "$W/boot/results.txt"; rc=$?
expect_rc "boot script: the built-for version is checked against SOURCES" $rc 0
[ -s "$W/boot4/schema.json" ]; rc=$?
expect_rc "boot script: with no schema argument it takes the schema nvrm-info prints" $rc 0

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
needed "$O/lib/libnvrm.so.1" 'libc\.so'; rc=$?
expect_rc "libnvrm needs only libc" $rc 0
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
nm -D --defined-only "$O/lib/libnvrm.so.1" | awk '$2=="T"{sub(/@@.*/,"",$3); print $3}' | sort >"$W/exported.txt"
grep -oE '\bnvrm_[a-z_0-9]+\(' "$L/include/nvrm/nvrm.h" | tr -d '(' | sort -u >"$W/declared.txt"
cmp -s "$W/exported.txt" "$W/declared.txt"; rc=$?
expect_rc "the library exports exactly the functions nvrm.h declares" $rc 0
[ $rc -eq 0 ] || diff "$W/exported.txt" "$W/declared.txt"
objdump -T "$O/lib/libnvrm.so.1" 2>/dev/null | grep -q 'NVRM_1.0' || readelf -V "$O/lib/libnvrm.so.1" | grep -q NVRM_1.0
rc=$?
expect_rc "symbols carry the version NVRM_1.0" $rc 0

# ---- man pages ---------------------------------------------------------------
for m in "$L/man/nvrm.3" "$L/man/nvrm.7" "$L/nvrm-info/nvrm-info.8"; do
	mandoc -T lint -W warning "$m" >"$W/mandoc.out" 2>&1; rc=$?
	expect_rc "mandoc -T lint: $(basename "$m")" $rc 0
done
printf '.Dd November 21, 2026\n.Dt BAD 3\n.Os\n.Sh NAME\n.Nm bad\n.Xx nonsense\n' >"$W/bad.3"
mandoc -T lint -W warning "$W/bad.3" >/dev/null 2>&1; rc=$?
if [ $rc -ne 0 ]; then ok "man lint plant: a broken page fails mandoc"; else bad "man lint plant: broken page passed"; fi
for code in $(grep -oE 'NVRM_E_[A-Z]+' "$L/include/nvrm/nvrm.h" | sort -u | grep -v -e NVRM_E__COUNT); do
	grep -q "$code" "$L/man/nvrm.3"; rc=$?
	expect_rc "nvrm(3) documents $code" $rc 0
done
for r in not_queried rm_control_failed rm_not_supported os_not_reported family_unknown family_has_no_class input_unavailable no_numa_node backend_does_not_provide class_absent os_call_failed value_unusable; do
	grep -q "$r" "$L/man/nvrm.7"; rc=$?
	expect_rc "nvrm(7) documents reason $r" $rc 0
done
for cap in dmabuf_export ats self_hosted display_enabled soc coherent_gpu_memory os_device_wc_active; do
	grep -q "$cap" "$L/man/nvrm.7"; rc=$?
	expect_rc "nvrm(7) documents capability $cap" $rc 0
done
for f in NVRM_ENUM_ALLOW_ALLOC_MAP; do
	grep -qi "$f" "$L/man/nvrm.3" && grep -qi "$f" "$L/man/nvrm.7"; rc=$?
	expect_rc "nvrm(3) and nvrm(7) document $f" $rc 0
done
grep -qi "zero-initialize" "$L/man/nvrm.3"; rc=$?
expect_rc "nvrm(3) tells callers to zero-initialize the options" $rc 0
sed -n '/^\.Sh SYNOPSIS/,/^\.Sh DESCRIPTION/p' "$L/man/nvrm.3" | grep -oE '^\.Fn nvrm_[a-z_0-9]+' | awk '{print $2}' | sort -u >"$W/man-fn.txt"
grep -oE '^\.Nm nvrm_[a-z_0-9]+' "$L/man/nvrm.3" | awk '{print $2}' | sort -u >"$W/man-nm.txt"
sed -n '/^NVRM_FUNCS=/,/^\.for/p' "$L/Makefile" | tr -d '\\' | tr ' \t' '\n\n' | grep '^nvrm_' | sort -u >"$W/mk-funcs.txt"
cmp -s "$W/exported.txt" "$W/man-fn.txt"; rc=$?
expect_rc "nvrm(3) SYNOPSIS has every exported function" $rc 0
cmp -s "$W/exported.txt" "$W/man-nm.txt"; rc=$?
expect_rc "nvrm(3) NAME has every exported function" $rc 0
cmp -s "$W/exported.txt" "$W/mk-funcs.txt"; rc=$?
expect_rc "the Makefile man links cover every exported function" $rc 0
grep -q 'nvrm_enumerate' "$L/man/nvrm.3" && grep -q 'nvrm_json_schema' "$L/man/nvrm.3" && grep -q -- '--jsonl' "$L/nvrm-info/nvrm-info.8"
rc=$?
expect_rc "man pages cover the calls and every nvrm-info option" $rc 0

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
for f in usr/lib/libnvrm.so.1 usr/lib/libnvrm.a usr/sbin/nvrm-info usr/include/nvrm/nvrm.h usr/share/nvrm/schema/nvrm-info-1.schema.json usr/share/man/man3/nvrm.3.gz usr/share/man/man7/nvrm.7.gz usr/share/man/man8/nvrm-info.8.gz; do
	[ -f "$D/$f" ]; rc=$?
	expect_rc "installed: $f" $rc 0
done
cmp -s "$D/usr/share/nvrm/schema/nvrm-info-1.schema.json" "$SCHEMA"; rc=$?
expect_rc "installed schema is the checked-in schema" $rc 0

printf '\nlibnvrm_test: %d ok, %d FAILED\n' "$PASS" "$FAIL"
exit $FAIL
