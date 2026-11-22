# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-2-Clause
#
# boot_compare.py - the comparison half of boot_nvrm_info.sh (Track #2362).
# It reads OUTDIR/nvrm-info.json, OUTDIR/sysctl.txt and OUTDIR/pciconf.txt
# and prints one PASS or FAIL line per check (plus INFO lines), comparing what
# libnvrm reports with sources that do not go through it: the OS layer's
# sysctls (hw.nvidia.*, dev.nvidia.<unit>.*), pciconf -lvb and the SOURCES
# file of REPO.  The board is stated by the environment:
#   BOOT_EXPECT_VRAM_BYTES              nominal board memory in bytes (0 for
#                                       a unified-memory part)
#   BOOT_EXPECT_VRAM_RESERVE_MAX_BYTES  most the driver may reserve of it
#   BOOT_EXPECT_SM                      the compute capability, major.minor
# Versions are compared as integers, never as parsed strings.
# usage: python3 -I boot_compare.py OUTDIR REPO
# Exit status 0; the caller counts the FAIL lines.
# The facts of the amp001 board (the numbers that are examples in the
# messages and docs) are in board-amp001.env next to this file.
import json
import os
import re
import sys

WHOLE = r"(?<![0-9.])%s(?![0-9.])"
UNAVAILABLE = "unavailable"
NO_FIELD = {"available": False}


def say(ok, msg):
    print(("PASS " if ok else "FAIL ") + msg)


def val(f):
    return f["value"] if f.get("available") else None


def read_tag(repo):
    """The ogkm_tag of SOURCES, or an empty string."""
    try:
        for line in open(os.path.join(repo, "SOURCES")):
            f = line.split()
            if len(f) == 2 and f[0] == "ogkm_tag":
                return f[1]
    except OSError:
        pass
    return ""


def parse_sysctl(text):
    """{name: value} from `sysctl` text output; the first line of a name wins."""
    found = {}
    for line in text.splitlines():
        name, sep, rest = line.partition(": ")
        if sep and name not in found:
            found[name] = rest
    return found


def bars(pci, header):
    """The memory BARs listed under a pciconf -lvb header line: {offset: size}."""
    lines = pci.splitlines()
    found = {}
    if header not in lines:
        return found
    for ln in lines[lines.index(header) + 1:]:
        if not ln[:1].isspace():
            break
        m = re.match(r"\s+bar\s+\[([0-9a-f]+)\] = type (Prefetchable Memory|Memory), .*size (\d+)", ln)
        if m:
            found[m.group(1)] = int(m.group(3))
    return found


def check_expectations():
    """Validate the three BOOT_EXPECT_* values; returns them parsed."""
    env = os.environ
    vram = env.get("BOOT_EXPECT_VRAM_BYTES", "")
    res = env.get("BOOT_EXPECT_VRAM_RESERVE_MAX_BYTES", "")
    sm = env.get("BOOT_EXPECT_SM", "")
    vram_ok = vram.isdigit()
    say(vram_ok, "BOOT_EXPECT_VRAM_BYTES is %s" % vram if vram_ok else
        "BOOT_EXPECT_VRAM_BYTES must be the board's nominal VRAM in bytes (e.g. 17179869184 for 16 GiB, 0 for a unified-memory part); "
        "set by make-be.sh -V (rc.conf nvidia_native_tools_testboot_vram); got %r" % vram)
    res_ok = res.isdigit() and (not vram_ok or int(vram) == 0 or int(res) < int(vram))
    say(res_ok, "BOOT_EXPECT_VRAM_RESERVE_MAX_BYTES is %s" % res if res_ok else
        "BOOT_EXPECT_VRAM_RESERVE_MAX_BYTES must be the most the driver may reserve, in bytes, below the nominal VRAM (e.g. 268435456 for 256 MiB); "
        "set by make-be.sh -R (rc.conf nvidia_native_tools_testboot_vram_reserve); got %r (nominal %r)" % (res, vram))
    sm_ok = re.fullmatch(r"[0-9]+\.[0-9]+", sm) is not None
    say(sm_ok, "BOOT_EXPECT_SM is %s" % sm if sm_ok else
        "BOOT_EXPECT_SM must be the board's compute capability as major.minor (e.g. 12.0); "
        "set by make-be.sh -S (rc.conf nvidia_native_tools_testboot_sm); got %r" % sm)
    return {"vram": int(vram) if vram_ok else None,
            "reserve": int(res) if res_ok else None,
            "sm": sm if sm_ok else None}


def tag_note(tag, repo):
    return tag if tag else "<none: no ogkm_tag in %s>" % os.path.join(repo, "SOURCES")


def check_versions(doc, sysd, tag, repo):
    """The driver version: tag, integers against the sysctls, and the running RM."""
    built = doc["built_for_rm_version"]
    say(bool(tag) and built == tag,
        "nvrm-info was built for the SOURCES ogkm_tag (built=%r, SOURCES=%s)" % (built, tag_note(tag, repo)))
    banner = sysd.get("hw.nvidia.version", "")
    say(bool(tag) and re.search(WHOLE % re.escape(tag), banner) is not None,
        "hw.nvidia.version carries %s as a whole version" % tag)
    run = doc["running_rm_version"]
    drv = doc.get("versions", {}).get("driver")
    say(drv is not None and drv.get("available") is True and run.get("available") is True and
        run.get("value") == drv.get("string"),
        "nvrm-info running_rm_version is available and equals versions.driver.string: running=%s versions.driver=%s" % (
            json.dumps(run, sort_keys=True), json.dumps(drv, sort_keys=True)))
    check_driver_row(drv, sysd, tag, repo)


def check_driver_row(drv, sysd, tag, repo):
    if drv is None:
        say(False, "nvrm-info has no top-level versions.driver (a JSON from before the versions object)")
        return
    sysint = {}
    for part in ("major", "minor", "patch", "available"):
        raw = sysd.get("hw.nvidia.version_" + part, "")
        sysint[part] = int(raw) if raw.isdigit() else None
    wrong = []
    if drv.get("available") is not True:
        wrong.append("versions.driver is not available")
    if sysint["available"] != 1:
        wrong.append("hw.nvidia.version_available is %s, want 1" % sysint["available"])
    for p in ("major", "minor", "patch"):
        if sysint[p] is None:
            wrong.append("hw.nvidia.version_%s is missing or not a number" % p)
        elif drv.get(p) != sysint[p]:
            wrong.append("versions.driver %s is %s but hw.nvidia.version_%s is %s" % (p, drv.get(p), p, sysint[p]))
    if not tag:
        wrong.append("SOURCES ogkm_tag not found in %s" % os.path.join(repo, "SOURCES"))
    elif drv.get("string") != tag:
        wrong.append("versions.driver string %r is not the SOURCES ogkm_tag %s" % (drv.get("string"), tag))
    say(not wrong, "versions.driver %s major/minor/patch %s/%s/%s, hw.nvidia.version_major/_minor/_patch %s/%s/%s, "
        "hw.nvidia.version_available=%s, SOURCES ogkm_tag %s%s" % (
            drv.get("string"), drv.get("major"), drv.get("minor"), drv.get("patch"),
            sysint["major"], sysint["minor"], sysint["patch"], sysint["available"], tag_note(tag, repo),
            "; wrong: " + "; ".join(wrong) if wrong else ""))


def location_of(sysd, unit):
    """(location or None, source, malformed pci_bus_id or None) of a dev.nvidia unit.

    pci_bus_id is read first; one that is present but not dddd:bb:ss.f in
    lowercase hex is reported as malformed and the %location dbsf is tried."""
    malformed = None
    raw = sysd.get("dev.nvidia.%s.pci_bus_id" % unit)
    if raw is not None:
        m = re.fullmatch(r"([0-9a-f]{4}):([0-9a-f]{2}):([0-9a-f]{2})\.([0-9a-f])", raw)
        if m:
            return tuple(int(x, 16) for x in m.groups()), "pci_bus_id", None
        malformed = raw
    m = re.search(r"dbsf=pci(\d+):(\d+):(\d+):(\d+)", sysd.get("dev.nvidia.%s.%%location" % unit, ""))
    return (tuple(int(x) for x in m.groups()) if m else None), "%location", malformed


def find_unit(sysd, want):
    """(unit or None, source, units seen, [(unit, malformed pci_bus_id)])."""
    found = set()
    for k in sysd:
        m = re.match(r"dev\.nvidia\.(\d+)\.", k)
        if m:
            found.add(m.group(1))
    units = sorted(found, key=int)
    unit, how, bad = None, None, []
    for u in units:
        loc, src, malformed = location_of(sysd, u)
        if malformed is not None:
            bad.append((u, malformed))
        if unit is None and loc == want:
            unit, how = u, src
    return unit, how, units, bad


def device_location(d):
    """([domain, bus, slot, function] with function 0 when unavailable, note)."""
    ident = d["identity"]
    loc = [val(ident[k]) for k in ("pci_domain", "pci_bus", "pci_slot", "pci_function")]
    note = ""
    if loc[3] is None:
        loc[3] = 0
        note = " (pci_function is unavailable in nvrm-info: taken as 0)"
    return loc, note


def check_uuid(d, sysd):
    """Returns the sysctl unit of the device, or None."""
    i = d["index"]
    u = val(d["identity"]["uuid"])
    loc, note = device_location(d)
    if None in loc:
        say(False, "GPU %d uuid: nvrm-info has no domain/bus/slot, cannot find its dev.nvidia unit" % i)
        return None
    want = "%04x:%02x:%02x.%x" % tuple(loc)
    unit, how, units, bad = find_unit(sysd, tuple(loc))
    for bu, raw in bad:
        say(False, "GPU %d uuid: dev.nvidia.%s.pci_bus_id %r is malformed (want dddd:bb:ss.f in lowercase hex, e.g. %s); "
            "the %%location fallback is tried" % (i, bu, raw, want))
    if unit is None:
        say(False, "GPU %d uuid: no dev.nvidia.<unit> is at %s%s (units seen: %s); sysctl.txt needs dev.nvidia.<unit>.pci_bus_id or .%%location" % (
            i, want, note, ",".join(units) or "none"))
        return None
    dev_u = sysd.get("dev.nvidia.%s.uuid" % unit)
    hw_u = sysd.get("hw.nvidia.gpus.%s.uuid" % unit)
    wrong = []
    if u is None:
        wrong.append("the nvrm-info uuid is unavailable")
    if hw_u is None:
        wrong.append("hw.nvidia.gpus.%s.uuid is missing" % unit)
    elif u is not None and hw_u != u:
        wrong.append("hw.nvidia.gpus.%s.uuid differs from nvrm-info" % unit)
    if dev_u is None:
        # a module that has the new sysctls says pci_bus_id and uuid together
        if how == "pci_bus_id":
            wrong.append("dev.nvidia.%s.uuid is missing (required: the unit was found through dev.nvidia.%s.pci_bus_id)" % (unit, unit))
    elif u is not None and dev_u != u:
        wrong.append("dev.nvidia.%s.uuid differs from nvrm-info" % unit)
    say(not wrong,
        "GPU %d uuid nvrm-info=%s dev.nvidia.%s.uuid=%s hw.nvidia.gpus.%s.uuid=%s (unit %s found by %s %s%s)%s" % (
            i, u, unit, dev_u, unit, hw_u, unit, how, want, note,
            "; wrong: " + "; ".join(wrong) if wrong else ""))
    return unit


def check_pci(d, pci):
    """PCI ids against pciconf; returns (pciconf header line or None, wanted ids)."""
    i, ident = d["index"], d["identity"]
    ven, dev = val(ident["pci_vendor"]), val(ident["pci_device"])
    sub_v, sub_d = val(ident["pci_subsystem_vendor"]), val(ident["pci_subsystem_device"])
    want = "vendor=0x%04x device=0x%04x" % (ven or 0, dev or 0)
    hit = [ln for ln in pci.splitlines() if want in ln]
    say(bool(hit), "GPU %d pci %s found in pciconf" % (i, want))
    say(sub_v is not None and sub_d is not None and bool(hit) and
        "subvendor=0x%04x subdevice=0x%04x" % (sub_v, sub_d) in hit[0],
        "GPU %d subsystem %s:%s is available and matches pciconf (checks the pciSubSystemId layout)" % (i, sub_v, sub_d))
    dom, b, s = val(ident["pci_domain"]), val(ident["pci_bus"]), val(ident["pci_slot"])
    say(bool(hit) and None not in (dom, b, s) and ("@pci%s:%s:%s:" % (dom, b, s)) in hit[0].split()[0],
        "GPU %d domain/bus/slot %s:%s:%s are available and match pciconf %s" % (i, dom, b, s, hit[0].split()[0] if hit else None))
    return (hit[0] if hit else None), want


def check_sm(d, exp):
    i, gpu = d["index"], d["gpu"]
    rm = (val(gpu["sm_version_major"]), val(gpu["sm_version_minor"]))
    raw = val(gpu.get("rm_sm_version", NO_FIELD))
    print("INFO GPU %d SM (RM numbering) %s.%s; rm_sm_version %s; family (libnvrm) %s; chip_id %s" % (
        i, rm[0], rm[1], "0x%04x" % raw if raw is not None else None, val(gpu["family"]), val(gpu["chip_id"])))
    if "compute_capability_major" not in gpu or "compute_capability_minor" not in gpu:
        say(False, "GPU %d nvrm-info has no compute_capability_major/minor (a JSON from before the library reported them); expected BOOT_EXPECT_SM=%s" % (i, exp["sm"]))
        return
    cc = (val(gpu["compute_capability_major"]), val(gpu["compute_capability_minor"]))
    say(None not in cc and exp["sm"] is not None and "%d.%d" % cc == exp["sm"],
        "GPU %d compute capability nvrm-info=%s expected BOOT_EXPECT_SM=%s" % (
            i, "%s.%s" % cc if None not in cc else UNAVAILABLE, exp["sm"]))


def check_vram(d, exp):
    i = d["index"]
    vram = val(d["memory"]["vram_size"])
    nominal, reserve = exp["vram"], exp["reserve"]
    if nominal is None or reserve is None:
        ok, want = False, "a valid range (the BOOT_EXPECT_VRAM values above FAILed)"
    elif nominal == 0:
        ok, want = vram == 0, "0 (unified memory)"
    else:
        ok, want = vram is not None and nominal - reserve <= vram <= nominal, "%d..%d" % (nominal - reserve, nominal)
    say(ok, "GPU %d vram_size nvrm-info=%s expected %s (BOOT_EXPECT_VRAM_BYTES=%s less at most BOOT_EXPECT_VRAM_RESERVE_MAX_BYTES=%s)" % (
        i, vram, want, nominal, reserve))


def check_bar1(d, pci, hit):
    i = d["index"]
    bar1 = val(d["memory"]["bar1_size"])
    line, want = hit
    found = bars(pci, line) if line else {}
    name = line.split()[0] if line else None
    if not line:
        say(False, "GPU %d bar1_size cannot be checked: no pciconf -lvb line has %s" % (i, want))
    elif not found:
        say(False, "GPU %d bar1_size cannot be checked: no memory BAR is listed under %s" % (i, name))
    elif "14" not in found:
        say(False, "GPU %d bar1_size cannot be checked: %s has no memory BAR at config offset 0x14 (BAR1); it lists %s" % (i, name, sorted(found)))
    else:
        say(bar1 is not None and bar1 == found["14"],
            "GPU %d bar1_size nvrm-info=%s, BAR1 (config offset 0x14) in pciconf -lvb is %s" % (i, bar1, found["14"]))


def check_device(d, sysd, pci, exp):
    i, gpu, mem = d["index"], d["gpu"], d["memory"]
    unit = check_uuid(d, sysd)
    hit = check_pci(d, pci)
    model = sysd.get("hw.nvidia.gpus.%s.model" % unit) if unit is not None else None
    print("INFO GPU %d sysctl unit %s model (sysctl) %s" % (i, unit, model))
    check_sm(d, exp)
    say(val(gpu["sm_count"]) is not None and val(gpu["sm_count"]) > 0,
        "GPU %d sm_count available and nonzero: %s" % (i, val(gpu["sm_count"])))
    check_vram(d, exp)
    check_bar1(d, pci, hit)
    print("INFO GPU %d max_page_size %s numa %s" % (i, mem["max_page_size"], mem["numa_node"]))
    caps = {c["name"]: c for c in d["capabilities"]}
    wc = sysd.get("hw.nvidia.altra_device_wc_active", "")
    if wc.isdigit():
        c = caps["os_device_wc_active"]
        say(c["available"] and int(wc) == int(c["value"]),
            "GPU %d os_device_wc_active is available and matches hw.nvidia.altra_device_wc_active=%s" % (i, wc))


def main(argv):
    out, repo = argv[1], argv[2]
    doc = json.load(open(out + "/nvrm-info.json"))
    sysd = parse_sysctl(open(out + "/sysctl.txt").read())
    pci = open(out + "/pciconf.txt").read()
    check_versions(doc, sysd, read_tag(repo), repo)
    say(doc["backend"] == "rm", "nvrm-info used the rm backend (the real driver), backend=%s" % doc["backend"])
    devs = doc["devices"]
    print("INFO nvrm-info reports %d GPU(s)" % len(devs))
    say(len(devs) > 0, "nvrm-info reports %d GPU(s) (the board has one)" % len(devs) if devs else
        "nvrm-info reports at least one GPU: none reported; check hw.nvidia.gpus in sysctl.txt and dmesg-nvrm.txt, and that nvidia.ko attached to the board")
    exp = check_expectations()
    for d in devs:
        check_device(d, sysd, pci, exp)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
