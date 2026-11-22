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
# (a value compared with itself proves nothing):
#   BOOT_EXPECT_VRAM_BYTES  the video memory the board has, in bytes, exactly
#                           as the RM reports it (0 for a unified-memory part);
#                           e.g. 17179869184 for a 16 GiB card
#   BOOT_EXPECT_SM          the SM version, major.minor (12.0 for the RTX 5060
#                           Ti)
# Both are required, and both apply to every GPU the run reports (the test
# boards have one).  A missing or different value is a FAIL.  The kernel log of
# FreeBSD does not report VRAM, so there is no log line to compare it with.
# bar1_size is compared with BAR1 of the same device in `pciconf -lvb`, a
# source that does not go through the RM: BAR1 is the memory BAR at config
# offset 0x14 (BAR0, the registers, is at 0x10; BAR3 at 0x1c).  No GPU at all
# is a FAIL here: the board has one.
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
# usage: BOOT_EXPECT_VRAM_BYTES=N BOOT_EXPECT_SM=M.m [BOOT_MEM_PROBE=path] \
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

OUT=${1:?usage: BOOT_EXPECT_VRAM_BYTES=N BOOT_EXPECT_SM=M.m boot_nvrm_info.sh OUTDIR [NVRM_INFO [SCHEMA]]}
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
	$SYSCTL hw.nvidia.version
	$SYSCTL hw.nvidia.altra_device_wc_active
	$SYSCTL hw.nvidia.gpus
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

# the Linux layer again, after the last nvrm-info run (and the memory probe)
$KLD >"$OUT/kldstat-after.txt" 2>&1
linux_check "after nvrm-info ran" "$OUT/kldstat-after.txt"

# compare with the driver, GPU by GPU, using python only to read the JSON
python3 -I - "$OUT" "$HERE/../.." "${BOOT_EXPECT_VRAM_BYTES:-}" "${BOOT_EXPECT_SM:-}" >>"$R" 2>&1 <<'PY'
import json, os, re, subprocess, sys
out = sys.argv[1]
doc = json.load(open(out + "/nvrm-info.json"))
def say(ok, msg):
    print(("PASS " if ok else "FAIL ") + msg)
def val(f):
    return f["value"] if f["available"] else None
exp_vram, exp_sm = sys.argv[3], sys.argv[4]
sysctl = open(out + "/sysctl.txt").read()
pci = open(out + "/pciconf.txt").read()
built = doc["built_for_rm_version"]
tag = ""
try:
    for line in open(os.path.join(sys.argv[2], "SOURCES")):
        f = line.split()
        if len(f) == 2 and f[0] == "ogkm_tag":
            tag = f[1]
except OSError:
    pass
whole = r"(?<![0-9.])%s(?![0-9.])"
say(bool(tag) and built == tag,
    "nvrm-info was built for the SOURCES ogkm_tag (built=%r, SOURCES=%r)" % (built, tag))
say(bool(tag) and re.search(whole % re.escape(tag), sysctl) is not None,
    "hw.nvidia.version carries %s as a whole version" % tag)
run = doc["running_rm_version"]
say(run["available"] and bool(tag) and
    re.search(whole % re.escape(tag), run["value"]) is not None,
    "nvrm-info running_rm_version matches the sysctl: %s" % run)
say(doc["backend"] == "rm",
    "nvrm-info used the rm backend (the real driver), backend=%s" % doc["backend"])
devs = doc["devices"]
print("INFO nvrm-info reports %d GPU(s)" % len(devs))
say(len(devs) > 0, "nvrm-info reports %d GPU(s) (the board has one)" % len(devs) if devs else
    "nvrm-info reports at least one GPU: none reported; check hw.nvidia.gpus in sysctl.txt and dmesg-nvrm.txt, and that nvidia.ko attached to the board")
vram_ok = exp_vram.isdigit()
say(vram_ok, "BOOT_EXPECT_VRAM_BYTES is %s" % exp_vram if vram_ok else
    "BOOT_EXPECT_VRAM_BYTES must be the board's VRAM in bytes (e.g. 17179869184 for 16 GiB, 0 for a unified-memory part); got %r" % exp_vram)
sm_ok = re.fullmatch(r"[0-9]+\.[0-9]+", exp_sm) is not None
say(sm_ok, "BOOT_EXPECT_SM is %s" % exp_sm if sm_ok else
    "BOOT_EXPECT_SM must be the board's SM version as major.minor (e.g. 12.0); got %r" % exp_sm)


def bars(pci, header):
    """The memory BARs listed under a pciconf -lvb header line: {offset: size}."""
    lines = pci.splitlines()
    found = {}
    if header not in lines:
        return found
    for l in lines[lines.index(header) + 1:]:
        if not l[:1].isspace():
            break
        m = re.match(r"\s+bar\s+\[([0-9a-f]+)\] = type (Prefetchable Memory|Memory), .*size (\d+)", l)
        if m:
            found[m.group(1)] = int(m.group(3))
    return found

for d in devs:
    i = d["index"]
    ident, gpu, mem = d["identity"], d["gpu"], d["memory"]
    # UUID: the sysctl of GPU i carries the same string
    m = re.search(r"hw\.nvidia\.gpus\.%d\.uuid: (\S+)" % i, sysctl)
    u = val(ident["uuid"])
    say(m is not None and u is not None and m.group(1) == u,
        "GPU %d uuid nvrm-info=%s sysctl=%s" % (i, u, m.group(1) if m else None))
    # PCI ids against pciconf: vendor and device
    ven, dev = val(ident["pci_vendor"]), val(ident["pci_device"])
    sub_v, sub_d = val(ident["pci_subsystem_vendor"]), val(ident["pci_subsystem_device"])
    want = "vendor=0x%04x device=0x%04x" % (ven or 0, dev or 0)
    hit = [l for l in pci.splitlines() if want in l]
    say(bool(hit), "GPU %d pci %s found in pciconf" % (i, want))
    say(sub_v is not None and sub_d is not None and bool(hit) and
        "subvendor=0x%04x subdevice=0x%04x" % (sub_v, sub_d) in hit[0],
        "GPU %d subsystem %s:%s is available and matches pciconf (checks the pciSubSystemId layout)" % (i, sub_v, sub_d))
    # bus location: pciconf line starts with name@pciD:B:S:F
    dom, b, s = val(ident["pci_domain"]), val(ident["pci_bus"]), val(ident["pci_slot"])
    # pciconf names a device name@pci<domain>:<bus>:<slot>:<function>
    say(bool(hit) and None not in (dom, b, s) and
        ("@pci%s:%s:%s:" % (dom, b, s)) in hit[0].split()[0],
        "GPU %d domain/bus/slot %s:%s:%s are available and match pciconf %s" % (i, dom, b, s, hit[0].split()[0] if hit else None))
    # model name of the sysctl names the chip; show it next to the family
    m = re.search(r"hw\.nvidia\.gpus\.%d\.model: (.*)" % i, sysctl)
    print("INFO GPU %d model (sysctl) %s; family (libnvrm) %s; chip_id %s; SM %s.%s" % (
        i, m.group(1) if m else None, val(d["gpu"]["family"]), val(gpu["chip_id"]),
        val(gpu["sm_version_major"]), val(gpu["sm_version_minor"])))
    sm = (val(gpu["sm_version_major"]), val(gpu["sm_version_minor"]))
    say(None not in sm and sm_ok and "%d.%d" % sm == exp_sm,
        "GPU %d SM version nvrm-info=%s expected BOOT_EXPECT_SM=%s" % (
            i, "%s.%s" % sm if None not in sm else None, exp_sm))
    say(val(gpu["sm_count"]) is not None and val(gpu["sm_count"]) > 0,
        "GPU %d sm_count available and nonzero: %s" % (i, val(gpu["sm_count"])))
    # VRAM against the board's stated size; BAR1 against a memory BAR of the
    # same device in pciconf -lvb (neither goes back through the RM)
    vram = val(mem["vram_size"])
    say(vram is not None and vram_ok and vram == int(exp_vram),
        "GPU %d vram_size nvrm-info=%s expected BOOT_EXPECT_VRAM_BYTES=%s" % (i, vram, exp_vram))
    bar1 = val(mem["bar1_size"])
    found = bars(pci, hit[0]) if hit else {}
    if not hit:
        say(False, "GPU %d bar1_size cannot be checked: no pciconf -lvb line has %s" % (i, want))
    elif not found:
        say(False, "GPU %d bar1_size cannot be checked: no memory BAR is listed under %s" % (i, hit[0].split()[0]))
    elif "14" not in found:
        say(False, "GPU %d bar1_size cannot be checked: %s has no memory BAR at config offset 0x14 (BAR1); it lists %s" % (i, hit[0].split()[0], sorted(found)))
    else:
        say(bar1 is not None and bar1 == found["14"],
            "GPU %d bar1_size nvrm-info=%s, BAR1 (config offset 0x14) in pciconf -lvb is %s" % (i, bar1, found["14"]))
    print("INFO GPU %d max_page_size %s numa %s" % (i, mem["max_page_size"], mem["numa_node"]))
    caps = {c["name"]: c for c in d["capabilities"]}
    wc = re.search(r"hw\.nvidia\.altra_device_wc_active: (\d+)", sysctl)
    if wc:
        c = caps["os_device_wc_active"]
        say(c["available"] and int(wc.group(1)) == int(c["value"]),
            "GPU %d os_device_wc_active is available and matches hw.nvidia.altra_device_wc_active=%s" % (i, wc.group(1)))
PY
rc=$?
[ $rc -eq 0 ] || fail "the comparison script exited $rc"
FAILS=$(grep -c '^FAIL' "$R")
info "== done rc=$FAILS"
printf '== done rc=%d\n' "$FAILS" >>"$R"
exit "$FAILS"
