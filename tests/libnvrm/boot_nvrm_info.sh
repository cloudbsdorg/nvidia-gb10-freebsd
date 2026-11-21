#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-2-Clause
#
# boot_nvrm_info.sh - the live proof of libnvrm S1 (Track #2378), meant to run
# once in a one-shot test boot environment where the NVIDIA driver is loaded
# (rc one-shot, self-recording).  It runs nvrm-info in all its modes against the
# real driver and compares what libnvrm reports with what the loaded driver
# says by itself: the hw.nvidia.* sysctls, pciconf and the kernel log.  It
# does not use nvidia-smi or any Linux layer, and it never loads or unloads a
# module.
#
# usage: boot_nvrm_info.sh OUTDIR [NVRM_INFO [SCHEMA]]
# Writes OUTDIR/results.txt (one PASS/FAIL/INFO line per check, last line
# "== done rc=N"), OUTDIR/nvrm-info.json, nvrm-info.jsonl, sysctl.txt,
# pciconf.txt, dmesg-nvrm.txt, kldstat.txt.  Exit status: number of FAILs.

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL
# The proof is of the real driver: the environment must not select the fake
# backend (only the suite's own test of this script sets BOOT_ALLOW_FAKE).
ALLOW_FAKE_NOTE=
[ -n "$BOOT_ALLOW_FAKE" ] || unset NVRM_BACKEND NVRM_FAKE_PROFILE NVRM_FAKE_FAIL BOOT_KLDSTAT
[ -z "$BOOT_ALLOW_FAKE" ] || ALLOW_FAKE_NOTE=1

OUT=${1:?usage: boot_nvrm_info.sh OUTDIR [NVRM_INFO [SCHEMA]]}
INFO=${2:-nvrm-info}
SCHEMA=${3:-}
mkdir -p "$OUT" || exit 99
R=$OUT/results.txt
HERE=$(dirname "$0")
: >"$R"
pass() { printf 'PASS %s\n' "$1" >>"$R"; }
fail() { printf 'FAIL %s\n' "$1" >>"$R"; }
info() { printf 'INFO %s\n' "$1" >>"$R"; }

[ -z "$ALLOW_FAKE_NOTE" ] || fail "BOOT_ALLOW_FAKE is set: this run is not a proof of the real driver"
info "start $(date -u +%Y-%m-%dT%H:%M:%SZ) host $(hostname) kernel $(sysctl -n kern.bootfile 2>&1)"
KLD=${BOOT_KLDSTAT:-kldstat}	# a test may stand a stub in
$KLD >"$OUT/kldstat.txt" 2>&1
grep -qE ' nvidia\.ko' "$OUT/kldstat.txt" && pass "nvidia.ko is loaded" || fail "nvidia.ko is not loaded"
# the claim to prove: nvrm-info needs no Linux kmod.  A loaded linux or
# linux64 module means this boot proves nothing about it: that is a FAIL.
if $KLD | awk '{print $5}' | grep -qE '^(linux|linux64)'; then
	fail "a linux or linux64 kmod is loaded: this boot cannot prove nvrm-info runs without one"
else
	pass "no linux or linux64 kmod loaded while nvrm-info runs"
fi
info "linuxkpi modules loaded: $($KLD | awk '{print $5}' | grep -ciE 'linuxkpi|lkpi|drm|dmabuf')"
[ -c /dev/nvidiactl ] && pass "/dev/nvidiactl exists" || fail "/dev/nvidiactl missing"

# what the driver says by itself
{
	sysctl hw.nvidia.version
	sysctl hw.nvidia.altra_device_wc_active
	sysctl hw.nvidia.gpus
} >"$OUT/sysctl.txt" 2>&1
pciconf -lv >"$OUT/pciconf.txt" 2>&1
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

# compare with the driver, GPU by GPU, using python only to read the JSON
python3 -I - "$OUT" "$HERE/../.." >>"$R" 2>&1 <<'PY'
import json, os, re, subprocess, sys
out = sys.argv[1]
doc = json.load(open(out + "/nvrm-info.json"))
def say(ok, msg):
    print(("PASS " if ok else "FAIL ") + msg)
def val(f):
    return f["value"] if f["available"] else None
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
    say(val(gpu["sm_version_major"]) is not None, "GPU %d SM version is available" % i)
    say(val(gpu["sm_count"]) is not None and val(gpu["sm_count"]) > 0,
        "GPU %d sm_count available and nonzero: %s" % (i, val(gpu["sm_count"])))
    # VRAM: pciconf memory regions are not a size source; compare with the
    # kernel log line that reports the framebuffer when there is one
    print("INFO GPU %d vram_size %s bar1_size %s max_page_size %s numa %s" % (
        i, mem["vram_size"], mem["bar1_size"], mem["max_page_size"], mem["numa_node"]))
    log = open(out + "/dmesg-nvrm.txt").read()
    print("INFO GPU %d kernel log lines mentioning nvrm/nvidia: %d (read dmesg-nvrm.txt for VRAM, compare by hand with vram_size)" % (i, len(log.splitlines())))
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
