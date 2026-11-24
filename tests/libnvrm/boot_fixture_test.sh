#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-2-Clause
#
# boot_fixture_test.sh - boot_compare.py against the real boot capture of
# 2026-11-22 (tests/data/nvrm-info-boot-20261122T095018Z, Track #2362):
#   a. the capture as it was (before the library and OS fixes): the compute
#      capability, uuid, running-version and versions rows FAIL;
#   b. the derived "after" fixture (make-after.py): every comparison row of
#      boot_compare.py passes (rows that need a live system, such as kldstat,
#      compat.linux, the schema and the memory probe, are the shell script's
#      and are not covered here); the checked-in after files equal what
#      make-after.py makes;
#   c. mutations of the after fixture, each of which must FAIL its row.
# usage: sh boot_fixture_test.sh [SCRATCH_DIR]     (default: tmp/ in the checkout, made when missing)
# Prints ok/FAIL lines; the exit status is the number of failures (at most 98), or 99 when the
# scratch directory cannot be made (nothing ran).

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$HERE/../.." && pwd)
DATA=$REPO/tests/data/nvrm-info-boot-20261122T095018Z
SCRATCH=${1:-$REPO/tmp}
mkdir -p "$SCRATCH" && W=$(mktemp -d "$SCRATCH/boot-fixture.XXXXXX") || {
	printf 'boot_fixture_test: cannot create a scratch directory under %s\n' "$SCRATCH" >&2
	exit 99
}
. "$HERE/board-amp001.env"
FAILS=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; FAILS=$((FAILS + 1)); }
EXPECT="BOOT_EXPECT_VRAM_BYTES=$BOARD_VRAM_BYTES BOOT_EXPECT_VRAM_RESERVE_MAX_BYTES=$BOARD_VRAM_RESERVE_MAX_BYTES BOOT_EXPECT_SM=$BOARD_SM"
# nominal less the reserve, the lowest usable size
LOW=$((BOARD_VRAM_BYTES - BOARD_VRAM_RESERVE_MAX_BYTES))

# compare DIR [VAR=value ...]: boot_compare.py on DIR (nvrm-info.json, sysctl.txt, pciconf.txt) into DIR/out.txt
compare() {
	_d=$1; shift
	env $EXPECT "$@" python3 -I "$HERE/boot_compare.py" "$_d" "$REPO" >"$_d/out.txt" 2>&1
}
has() { grep -q "$2" "$1/out.txt"; }
want_fail() {	# want_fail DIR PATTERN WHAT
	if has "$1" "^FAIL $2"; then ok "$3"; else bad "$3 (no FAIL line matching $2)"; fi
}
want_pass() {
	if has "$1" "^PASS $2"; then ok "$3"; else bad "$3 (no PASS line matching $2)"; fi
}

# the derived fixture is what make-after.py makes from the capture
mkdir -p "$W/gen"
cp "$DATA/nvrm-info.json" "$DATA/sysctl.txt" "$W/gen/"
python3 -I "$DATA/make-after.py" "$W/gen"; rc=$?
if [ $rc -eq 0 ] && cmp -s "$W/gen/nvrm-info.after.json" "$DATA/nvrm-info.after.json" && cmp -s "$W/gen/sysctl.after.txt" "$DATA/sysctl.after.txt"; then
	ok "the checked-in after files equal what make-after.py makes from the capture"
else
	bad "the checked-in after files differ from make-after.py's output (rc=$rc)"
fi

# make-after.py derives from the capture: a capture whose GPU is unit 0 gives dev.nvidia.0.*, and a
# GPU at another PCI location gives that location; a chip the table does not know is an error
mkdir -p "$W/gen0"
sed 's/^hw\.nvidia\.gpus\.1\./hw.nvidia.gpus.0./' "$DATA/sysctl.txt" >"$W/gen0/sysctl.txt"
sed 's/"pci_bus":{"available":true,"value":1,/"pci_bus":{"available":true,"value":2,/' "$DATA/nvrm-info.json" >"$W/gen0/nvrm-info.json"
python3 -I "$DATA/make-after.py" "$W/gen0"; rc=$?
if [ $rc -eq 0 ] && grep -q '^dev.nvidia.0.uuid: GPU-17743da2' "$W/gen0/sysctl.after.txt" && ! grep -q '^dev.nvidia.1\.' "$W/gen0/sysctl.after.txt" &&
    grep -q '^dev.nvidia.0.pci_bus_id: 000d:02:00.0$' "$W/gen0/sysctl.after.txt" && grep -q '^dev.nvidia.0.%location: .*dbsf=pci13:2:0:0$' "$W/gen0/sysctl.after.txt"; then
	ok "make-after.py takes the unit and uuid from hw.nvidia.gpus and the location from nvrm-info"
else
	bad "make-after.py hard-codes the unit, uuid or location (rc=$rc): $(grep '^dev.nvidia' "$W/gen0/sysctl.after.txt" 2>/dev/null | head -3)"
fi
mkdir -p "$W/gen9"
cp "$DATA/sysctl.txt" "$W/gen9/"
sed 's/"implementation":{"available":true,"value":6,/"implementation":{"available":true,"value":99,/' "$DATA/nvrm-info.json" >"$W/gen9/nvrm-info.json"
python3 -I "$DATA/make-after.py" "$W/gen9" >/dev/null 2>&1; rc=$?
if [ $rc -ne 0 ]; then ok "make-after.py refuses a chip that is not in its compute capability table"; else bad "make-after.py invented a compute capability for an unknown chip"; fi

# a. the original capture
mkdir -p "$W/orig"
cp "$DATA/nvrm-info.json" "$DATA/sysctl.txt" "$DATA/pciconf.txt" "$W/orig/"
compare "$W/orig"
want_fail "$W/orig" 'GPU 0 nvrm-info has no compute_capability_major/minor' "original capture: the compute capability row FAILs (no compute_capability_*)"
want_fail "$W/orig" 'GPU 0 uuid' "original capture: the uuid row FAILs (no dev.nvidia unit)"
want_fail "$W/orig" 'nvrm-info running_rm_version' "original capture: the running-version row FAILs (unavailable)"
want_fail "$W/orig" 'nvrm-info has no top-level versions.driver' "original capture: the versions row FAILs (no versions object)"
want_pass "$W/orig" 'GPU 0 vram_size' "original capture: the usable VRAM $BOARD_USABLE_VRAM_BYTES is inside nominal less the reserve"
want_pass "$W/orig" 'GPU 0 bar1_size' "original capture: BAR1 still matches pciconf"

# b. the after fixture
mkdir -p "$W/after"
cp "$DATA/pciconf.txt" "$W/after/"
cp "$DATA/nvrm-info.after.json" "$W/after/nvrm-info.json"
cp "$DATA/sysctl.after.txt" "$W/after/sysctl.txt"
compare "$W/after"
if grep -q '^FAIL' "$W/after/out.txt"; then bad "after fixture: a row FAILs: $(grep '^FAIL' "$W/after/out.txt" | head -3)"; else ok "after fixture: no row FAILs"; fi
# the PASS rows that must be there: the version rows, the backend, the GPU count, the three expectations and the
# per-device rows (uuid, three pci, compute capability, sm_count, vram, bar1, wc)
for r in 'nvrm-info was built for the SOURCES ogkm_tag' 'hw.nvidia.version carries' 'nvrm-info running_rm_version is available' \
    'versions.driver 580.178.04 ' 'nvrm-info used the rm backend' 'nvrm-info reports 1 GPU' \
    'BOOT_EXPECT_VRAM_BYTES is' 'BOOT_EXPECT_VRAM_RESERVE_MAX_BYTES is' 'BOOT_EXPECT_SM is' \
    'GPU 0 uuid .*unit 1 found by pci_bus_id 000d:01:00.0 (pci_function is unavailable in nvrm-info: taken as 0)' \
    'GPU 0 pci vendor=' 'GPU 0 subsystem' 'GPU 0 domain/bus/slot' 'GPU 0 compute capability nvrm-info=12.0' 'GPU 0 sm_count' \
    "GPU 0 vram_size nvrm-info=$BOARD_USABLE_VRAM_BYTES expected $LOW\\.\\.$BOARD_VRAM_BYTES " 'GPU 0 bar1_size' 'GPU 0 os_device_wc_active'; do
	want_pass "$W/after" "$r" "after fixture: PASS row $r"
done

# c. mutations of the after fixture: mutate NAME 'sysctl|json' FROM TO PATTERN [VAR=value ...]
# edit NAME 'sysctl|json' FROM TO: the text FROM must be in the copy of the after fixture NAME; it becomes TO
edit() {
	_n=$1; _kind=$2; _from=$3; _to=$4
	mkdir -p "$W/m-$_n"
	for _x in nvrm-info.json sysctl.txt pciconf.txt; do [ -f "$W/m-$_n/$_x" ] || cp "$W/after/$_x" "$W/m-$_n/$_x"; done
	if [ "$_kind" = sysctl ]; then _f=$W/m-$_n/sysctl.txt; else _f=$W/m-$_n/nvrm-info.json; fi
	python3 -I -c '
import sys
f, a, b = sys.argv[1:4]
s = open(f).read()
if s.count(a) < 1:
    sys.exit(3)
open(f, "w").write(s.replace(a, b))' "$_f" "$_from" "$_to"
	if [ $? -ne 0 ]; then bad "mutation $_n: the text to change is not in the fixture: $_from"; return 1; fi
}
# mutate NAME 'sysctl|json' FROM TO PATTERN [VAR=value ...]: one edit, then the comparison must FAIL PATTERN
mutate() {
	_n=$1; _kind=$2; _from=$3; _to=$4; _pat=$5; shift 5
	edit "$_n" "$_kind" "$_from" "$_to" || return
	compare "$W/m-$_n" "$@"
	want_fail "$W/m-$_n" "$_pat" "mutation $_n FAILs its row"
}
mutate dev-uuid sysctl 'dev.nvidia.1.uuid: GPU-17743da2-61b3-ef41-e46e-5679f4ed15ec' 'dev.nvidia.1.uuid: GPU-17743da2-61b3-ef41-e46e-5679f4ed15ed' 'GPU 0 uuid'
mutate hw-uuid sysctl 'hw.nvidia.gpus.1.uuid: GPU-17743da2-61b3-ef41-e46e-5679f4ed15ec' 'hw.nvidia.gpus.1.uuid: GPU-00000000-0000-0000-0000-000000000000' 'GPU 0 uuid'
mutate bus-id sysctl 'dev.nvidia.1.pci_bus_id: 000d:01:00.0' 'dev.nvidia.1.pci_bus_id: 000d:02:00.0' 'GPU 0 uuid: no dev.nvidia.<unit> is at 000d:01:00.0'
mutate dev-uuid-gone sysctl 'dev.nvidia.1.uuid: GPU-17743da2-61b3-ef41-e46e-5679f4ed15ec' '' 'GPU 0 uuid .*wrong: dev.nvidia.1.uuid is missing (required: the unit was found through dev.nvidia.1.pci_bus_id)'
# the %location fallback: no pci_bus_id (an older module); only hw.nvidia.gpus.<unit>.uuid is required
edit no-bus-id sysctl 'dev.nvidia.1.pci_bus_id: 000d:01:00.0' '' && {
	compare "$W/m-no-bus-id"
	want_pass "$W/m-no-bus-id" 'GPU 0 uuid .*unit 1 found by %location 000d:01:00.0' "no pci_bus_id: the unit is found by %location and the uuid passes"
	if has "$W/m-no-bus-id" '^FAIL'; then bad "no pci_bus_id: a row FAILs: $(grep '^FAIL' "$W/m-no-bus-id/out.txt" | head -3)"; else ok "no pci_bus_id: no row FAILs"; fi
}
edit no-bus-id-dev-uuid sysctl 'dev.nvidia.1.uuid: GPU-17743da2-61b3-ef41-e46e-5679f4ed15ec' '' &&
edit no-bus-id-dev-uuid sysctl 'dev.nvidia.1.pci_bus_id: 000d:01:00.0' '' && {
	compare "$W/m-no-bus-id-dev-uuid"
	want_pass "$W/m-no-bus-id-dev-uuid" 'GPU 0 uuid .*found by %location' "found by %location only hw.nvidia.gpus.<unit>.uuid is required (no dev.nvidia.<unit>.uuid)"
}
# %location is parsed as decimal: pci19 is not pci13
edit loc-wrong sysctl 'dev.nvidia.1.pci_bus_id: 000d:01:00.0' '' &&
edit loc-wrong sysctl 'dbsf=pci13:1:0:0' 'dbsf=pci19:1:0:0' && {
	compare "$W/m-loc-wrong"
	want_fail "$W/m-loc-wrong" 'GPU 0 uuid: no dev.nvidia.<unit> is at 000d:01:00.0' "a wrong %location does not match the device"
}
# a present but malformed pci_bus_id is its own FAIL, then %location still finds the unit
edit bus-id-upper sysctl 'dev.nvidia.1.pci_bus_id: 000d:01:00.0' 'dev.nvidia.1.pci_bus_id: 000D:01:00.0' && {
	compare "$W/m-bus-id-upper"
	want_fail "$W/m-bus-id-upper" "GPU 0 uuid: dev.nvidia.1.pci_bus_id '000D:01:00.0' is malformed" "an uppercase pci_bus_id FAILs as malformed, naming the value"
	want_pass "$W/m-bus-id-upper" 'GPU 0 uuid .*unit 1 found by %location 000d:01:00.0' "a malformed pci_bus_id: the %location fallback still finds the unit"
}
mutate vram-high json "\"vram_size\":{\"available\":true,\"value\":$BOARD_USABLE_VRAM_BYTES" "\"vram_size\":{\"available\":true,\"value\":$((BOARD_VRAM_BYTES + 1))" 'GPU 0 vram_size'
mutate vram-below json "\"vram_size\":{\"available\":true,\"value\":$BOARD_USABLE_VRAM_BYTES" "\"vram_size\":{\"available\":true,\"value\":$((LOW - 1))" "GPU 0 vram_size nvrm-info=$((LOW - 1)) expected $LOW\\.\\.$BOARD_VRAM_BYTES "

mutate cc-104 json '"compute_capability_major":{"available":true,"value":12,"source":"derived"},"compute_capability_minor":{"available":true,"value":0' '"compute_capability_major":{"available":true,"value":10,"source":"derived"},"compute_capability_minor":{"available":true,"value":4' 'GPU 0 compute capability nvrm-info=10.4'
mutate cc-minor json '"compute_capability_minor":{"available":true,"value":0' '"compute_capability_minor":{"available":true,"value":4' 'GPU 0 compute capability'
mutate ver-minor sysctl 'hw.nvidia.version_minor: 178' 'hw.nvidia.version_minor: 177' 'versions.driver .*wrong: versions.driver minor is 178 but hw.nvidia.version_minor is 177'
mutate ver-avail sysctl 'hw.nvidia.version_available: 1' 'hw.nvidia.version_available: 0' 'versions.driver .*wrong: hw.nvidia.version_available is 0, want 1'
mutate run-ver json '"running_rm_version":{"available":true,"value":"580.178.04"' '"running_rm_version":{"available":true,"value":"580.177.00"' 'nvrm-info running_rm_version'
mutate drv-str json '"driver":{"available":true,"string":"580.178.04"' '"driver":{"available":true,"string":"580.178.05"' 'versions.driver'
[ "$FAILS" -le 98 ] || FAILS=98
if [ "$FAILS" -eq 0 ]; then printf '== boot_fixture_test: 0 failures\n'; else printf '== boot_fixture_test: %d failure(s)\n' "$FAILS"; fi
rm -rf "$W"
exit "$FAILS"
