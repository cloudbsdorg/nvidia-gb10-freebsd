#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-2-Clause
#
# boot_nvrm_info.sh - the live proof of libnvrm (Track #2378; memory #2419), meant to run
# once in a one-shot test boot environment where the NVIDIA driver is loaded
# (rc one-shot, self-recording).  It runs nvrm-info in all its modes against the
# real driver and compares what libnvrm reports with what the loaded driver
# says by itself: the hw.nvidia.* sysctls, pciconf and the kernel log.  It
# does not use nvidia-smi or any Linux layer, and it never loads or unloads a
# module.
#
# What the board is, stated by the kit and not read back from the library
# (a value compared with itself proves nothing); all three are required, a
# missing or malformed one is a FAIL with an example, and each applies to every
# GPU the run reports (the test boards have one):
#   BOOT_EXPECT_VRAM_BYTES  the NOMINAL video memory of the board, in bytes
#                           (0 for a unified-memory part)
#   BOOT_EXPECT_VRAM_RESERVE_MAX_BYTES
#                           the most the driver may reserve of it, in bytes,
#                           below the nominal size (the RM reports the usable
#                           size); the reported vram_size must be nominal
#                           minus reserve or more and at most nominal; nominal
#                           0 wants exactly 0
#   BOOT_EXPECT_SM          the board's COMPUTE CAPABILITY, major.minor,
#                           compared with the integers
#                           compute_capability_major/minor; the RM's own SM
#                           numbering (sm_version_*) and the raw rm_sm_version
#                           are printed as INFO only.  A JSON without
#                           compute_capability_* is a FAIL
# The values of the amp001 board (RTX 5060 Ti) are in board-amp001.env next to
# this script; boot_compare.py describes the comparison.
# The comparison is boot_compare.py (python3 -I, arguments OUTDIR and the repo
# root).  What it checks beside the expectations, each from a source that does
# not go through libnvrm:
#   - GPU uuid: the sysctl unit is the one whose dev.nvidia.<unit>.pci_bus_id
#     (dddd:bb:ss.f, lowercase hex, e.g. 000d:01:00.0 on amp001; a present but
#     malformed one is its own FAIL and the dbsf of dev.nvidia.<unit>.%location
#     is tried) equals the device's domain/bus/slot/function (function 0, said
#     in the line, when nvrm-info has it unavailable); hw.nvidia.gpus.<unit>
#     is numbered by device unit, not by nvrm-info's index.  A unit found
#     through pci_bus_id (a module with the new sysctls) PASSes only when both
#     hw.nvidia.gpus.<unit>.uuid and dev.nvidia.<unit>.uuid equal the nvrm-info
#     uuid; a unit found only through %location (an older module) needs only
#     hw.nvidia.gpus.<unit>.uuid (dev.nvidia.<unit>.uuid, if present, must
#     still equal); no unit at that location is a FAIL
#   - versions.driver is available, its integers major/minor/patch equal
#     hw.nvidia.version_major/_minor/_patch, hw.nvidia.version_available is 1,
#     and its string equals the SOURCES ogkm_tag; running_rm_version is
#     available and equals versions.driver.string; the banner
#     hw.nvidia.version carries the tag as a whole version
#   - bar1_size is compared with BAR1 of the same device in `pciconf -lvb`:
#     BAR1 is the memory BAR at config offset 0x14 (BAR0, the registers, is at
#     0x10; BAR3 at 0x1c)
# sysctl.txt holds the whole hw.nvidia and dev.nvidia nodes.  The kernel log of
# FreeBSD does not report VRAM, so there is no log line to compare it with.  No
# GPU at all is a FAIL here: the board has one.
#
# The proof is that nvrm-info needs no Linux layer, so the test BE must not
# have one: set linux_enable="NO" in the test BE's rc.conf and keep the Linux
# modules out of kld_list (the Linux ABI modules linux.ko, linux64.ko and
# linux_common.ko must not be loaded, and the sysctl compat.linux.osrelease
# must not answer).  The check runs twice, before the first and after the last
# nvrm-info run, so a module loaded in between is seen; a sysctl that cannot
# be read is a FAIL, never "absent".  Modules of LinuxKPI (linuxkpi.ko,
# linuxkpi_video.ko, ...) are not a Linux layer and do not fail this check:
# another GPU's driver may be loaded.
#
# Memory (Track #2419): BOOT_MEM_PROBE names the kit's mem_probe binary
# (tests/libnvrm/mem_probe.c, linked to the libnvrm under test; default: a
# mem_probe next to this script).  It runs on
# every GPU the library finds, between the nvrm-info runs and the second Linux
# check: client open with CPU mapping, VA reservation, video and system memory,
# GPU and CPU mappings, a pattern written and read back, export and import into
# a second client, and nothing left after the frees.  Its PASS and FAIL lines
# join results.txt, and its whole output is OUTDIR/mem_probe.txt.  A missing
# probe is a FAIL; only BOOT_S1_ONLY=1 (a discovery-only kit) turns that into
# an INFO line, and the run records that it was set.
#
# Channels (Track #2437): BOOT_CHAN_PROBE names the kit's chan_probe binary
# (tests/libnvrm/chan_probe.c, linked to the libnvrm under test; default: a
# chan_probe next to this script).  It runs after the memory probe, on every
# GPU the library finds: a compute GPFIFO channel, a semaphore release the GPU
# writes into a memory object of the probe (the payload is read back), the
# latency of a thousand releases, a stress loop, a bad push that kills one
# channel while the other one keeps working, and the cleanup.  Its PASS, FAIL
# and INFO lines join results.txt, its whole output is OUTDIR/chan_probe.txt
# and its --json document is OUTDIR/chan_probe.json.  BOOT_CHAN_STRESS is how
# many releases the stress loop pushes (default: 100000) and
# BOOT_CHAN_STRESS_SECONDS how long it may run (default: 300); the probe
# stops early when the time is up.  A missing probe is a FAIL; only
# BOOT_S1_ONLY=1 (a discovery-only kit) turns that into an INFO line, and the
# run records that it was set.
#
# usage: BOOT_EXPECT_VRAM_BYTES=N BOOT_EXPECT_VRAM_RESERVE_MAX_BYTES=R \
#            BOOT_EXPECT_SM=M.m [BOOT_MEM_PROBE=path] [BOOT_CHAN_PROBE=path] \
#            [BOOT_CHAN_STRESS=N] [BOOT_CHAN_STRESS_SECONDS=S] \
#            boot_nvrm_info.sh OUTDIR [NVRM_INFO [SCHEMA]]
# Writes OUTDIR/results.txt (one PASS/FAIL/INFO line per check, last line
# "== done rc=N"), OUTDIR/nvrm-info.json, nvrm-info.jsonl, sysctl.txt,
# pciconf.txt, dmesg-nvrm.txt, kldstat.txt, kldstat-after.txt.  Exit status:
# number of FAILs.

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL
# The proof is of the real driver: the environment must not select the fake
# backend (only the suite's own test of this script sets BOOT_ALLOW_FAKE).
ALLOW_FAKE_NOTE=
[ -n "$BOOT_ALLOW_FAKE" ] || unset NVRM_BACKEND NVRM_FAKE_PROFILE NVRM_FAKE_FAIL BOOT_KLDSTAT BOOT_PCICONF BOOT_SYSCTL
[ -z "$BOOT_ALLOW_FAKE" ] || ALLOW_FAKE_NOTE=1

OUT=${1:?usage: BOOT_EXPECT_VRAM_BYTES=N BOOT_EXPECT_VRAM_RESERVE_MAX_BYTES=R BOOT_EXPECT_SM=M.m boot_nvrm_info.sh OUTDIR [NVRM_INFO [SCHEMA]]}
INFO=${2:-nvrm-info}
SCHEMA=${3:-}
mkdir -p "$OUT" || exit 99
R=$OUT/results.txt
HERE=$(dirname "$0")
: >"$R"
pass() { printf 'PASS %s\n' "$1" >>"$R"; }
fail() { printf 'FAIL %s\n' "$1" >>"$R"; }
info() { printf 'INFO %s\n' "$1" >>"$R"; }

# a test may stand a stub in for each of these (honoured only with BOOT_ALLOW_FAKE)
KLD=${BOOT_KLDSTAT:-kldstat}
PCICONF=${BOOT_PCICONF:-pciconf}
SYSCTL=${BOOT_SYSCTL:-sysctl}
[ -z "$ALLOW_FAKE_NOTE" ] || fail "BOOT_ALLOW_FAKE is set: this run is not a proof of the real driver"
info "start $(date -u +%Y-%m-%dT%H:%M:%SZ) host $(hostname) kernel $($SYSCTL -n kern.bootfile 2>&1)"
$KLD >"$OUT/kldstat.txt" 2>&1
grep -qE ' nvidia\.ko' "$OUT/kldstat.txt" && pass "nvidia.ko is loaded" || fail "nvidia.ko is not loaded"

# The claim to prove: nvrm-info needs no Linux layer.  linux.ko, linux64.ko or
# linux_common.ko (exactly these names: never linuxkpi*) or an answering
# compat.linux.osrelease (a Linux ABI built into the kernel) mean this boot
# proves nothing about it: that is a FAIL.  Run before the first and after the
# last nvrm-info run: linux_check WHEN KLDSTAT-FILE.  A kldstat that does not
# even name the kernel, or a sysctl that fails for any reason but "unknown
# oid", is a FAIL: a probe that could not look has not found nothing.
linux_check() {
	_when=$1; _f=$2
	_mods=$(awk '{print $5}' "$_f" | grep -E '^(linux|linux64|linux_common)\.ko$' | tr '\n' ' ')
	if [ -n "$_mods" ]; then
		fail "a Linux ABI kmod (${_mods% }) is loaded $_when: this boot cannot prove nvrm-info runs without one; set linux_enable=NO in the test BE's rc.conf and take it out of kld_list"
	elif awk '{print $5}' "$_f" | grep -qx kernel; then
		pass "no Linux ABI kmod loaded $_when"
	else
		fail "kldstat output $_when does not name the kernel: the module list could not be read; run as root and check kldstat on the BE"
	fi
	_abi=$($SYSCTL -n compat.linux.osrelease 2>"$OUT/linux-sysctl.err"); _st=$?
	if [ $_st -eq 0 ] && [ -n "$_abi" ]; then
		if [ -n "$_mods" ]; then
			fail "compat.linux.osrelease answers ($_abi) $_when: the Linux ABI is present"
		else
			fail "compat.linux.osrelease answers ($_abi) $_when but no Linux kmod is loaded: the kernel has the Linux ABI built in (COMPAT_LINUX); boot a kernel without it"
		fi
	elif [ $_st -ne 0 ] && grep -q 'unknown oid' "$OUT/linux-sysctl.err"; then
		pass "compat.linux.osrelease does not answer $_when: no Linux ABI"
	else
		fail "compat.linux.osrelease could not be read $_when (exit $_st: $(head -c 200 "$OUT/linux-sysctl.err")): the probe proves nothing; run as root and read $OUT/linux-sysctl.err"
	fi
}
linux_check "before nvrm-info runs" "$OUT/kldstat.txt"
info "linuxkpi modules loaded (not a Linux layer): $(awk '{print $5}' "$OUT/kldstat.txt" | grep -ciE 'linuxkpi|lkpi|drm|dmabuf')"
[ -c /dev/nvidiactl ] && pass "/dev/nvidiactl exists" || fail "/dev/nvidiactl missing"

# what the driver says by itself
{
	$SYSCTL hw.nvidia
	$SYSCTL dev.nvidia
} >"$OUT/sysctl.txt" 2>&1
$PCICONF -lvb >"$OUT/pciconf.txt" 2>&1
dmesg | grep -iE 'nvrm|nvidia' >"$OUT/dmesg-nvrm.txt" 2>&1

# nvrm-info, every mode
"$INFO" --json >"$OUT/nvrm-info.json" 2>"$OUT/nvrm-info.json.err"
rc=$?
[ $rc -eq 0 ] && pass "nvrm-info --json exits 0" || fail "nvrm-info --json exit $rc: $(cat "$OUT/nvrm-info.json.err") $(head -c 300 "$OUT/nvrm-info.json")"
"$INFO" --jsonl >"$OUT/nvrm-info.jsonl" 2>"$OUT/nvrm-info.jsonl.err"
rc=$?
[ $rc -eq 0 ] && pass "nvrm-info --jsonl exits 0" || fail "nvrm-info --jsonl exit $rc"
"$INFO" >"$OUT/nvrm-info.txt" 2>&1
rc=$?
[ $rc -eq 0 ] && pass "nvrm-info (text) exits 0" || fail "nvrm-info (text) exit $rc"

# the schema: the argument if given, else the one nvrm-info itself prints (the
# binary under test, tied to the checked-in file by the build); a proof that
# could not validate the output is a FAIL, not a skip
if [ -n "$SCHEMA" ] && [ ! -f "$SCHEMA" ]; then
	fail "schema $SCHEMA does not exist: the output was not validated"
	SCHEMA=
elif [ -z "$SCHEMA" ]; then
	if "$INFO" --schema >"$OUT/schema.json" 2>/dev/null && [ -s "$OUT/schema.json" ]; then
		SCHEMA=$OUT/schema.json
	else
		fail "no schema given and $INFO --schema printed none: the output was not validated"
	fi
fi
if [ -n "$SCHEMA" ] && [ -f "$SCHEMA" ]; then
	V=$HERE/schema_validate.py
	python3 -I "$V" "$SCHEMA" "$OUT/nvrm-info.json" >>"$R" 2>&1 && pass "--json validates against the schema" || fail "--json does not validate"
	python3 -I "$V" "$SCHEMA" "$OUT/nvrm-info.jsonl" >>"$R" 2>&1 && pass "--jsonl validates against the schema" || fail "--jsonl does not validate"
fi

# the memory calls on the real driver
PROBE=${BOOT_MEM_PROBE:-$HERE/mem_probe}
if [ -x "$PROBE" ]; then
	"$PROBE" >"$OUT/mem_probe.txt" 2>&1
	rc=$?
	grep -E '^(PASS|FAIL|INFO) ' "$OUT/mem_probe.txt" >>"$R"
	if [ $rc -eq 0 ]; then pass "mem_probe: every memory step passed on every GPU"
	else fail "mem_probe exited $rc ($OUT/mem_probe.txt)"; fi
elif [ "${BOOT_S1_ONLY:-}" = 1 ]; then
	info "memory probe not run: BOOT_S1_ONLY=1 (a discovery-only kit)"
else
	fail "memory probe missing: $PROBE is not an executable (set BOOT_MEM_PROBE, or BOOT_S1_ONLY=1 for a discovery-only kit)"
fi

# the channel calls on the real driver
BOOT_CHAN_STRESS=${BOOT_CHAN_STRESS:-100000}
BOOT_CHAN_STRESS_SECONDS=${BOOT_CHAN_STRESS_SECONDS:-300}
export BOOT_CHAN_STRESS BOOT_CHAN_STRESS_SECONDS
CPROBE=${BOOT_CHAN_PROBE:-$HERE/chan_probe}
if [ -x "$CPROBE" ]; then
	"$CPROBE" >"$OUT/chan_probe.txt" 2>&1
	rc=$?
	grep -E '^(PASS|FAIL|INFO) ' "$OUT/chan_probe.txt" >>"$R"
	"$CPROBE" --json >"$OUT/chan_probe.json" 2>&1
	if [ $rc -eq 0 ]; then pass "chan_probe: every channel step passed on every GPU"
	else fail "chan_probe exited $rc ($OUT/chan_probe.txt)"; fi
elif [ "${BOOT_S1_ONLY:-}" = 1 ]; then
	info "channel probe not run: BOOT_S1_ONLY=1 (a discovery-only kit)"
else
	fail "channel probe missing: $CPROBE is not an executable (set BOOT_CHAN_PROBE, or BOOT_S1_ONLY=1 for a discovery-only kit)"
fi

# the Linux layer again, after the last nvrm-info run (and the memory probe)
$KLD >"$OUT/kldstat-after.txt" 2>&1
linux_check "after nvrm-info ran" "$OUT/kldstat-after.txt"

# compare with the driver, GPU by GPU (boot_compare.py)
python3 -I "$HERE/boot_compare.py" "$OUT" "$HERE/../.." >>"$R" 2>&1
rc=$?
[ $rc -eq 0 ] || fail "the comparison script exited $rc"
FAILS=$(grep -c '^FAIL' "$R")
info "== done rc=$FAILS"
printf '== done rc=%d\n' "$FAILS" >>"$R"
exit "$FAILS"
