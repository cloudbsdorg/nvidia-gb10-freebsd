# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-2-Clause
#
# make-after.py - derive the "after" fixture from the real boot capture of
# 2026-11-22 (Track #2362).  It reads nvrm-info.json and sysctl.txt next to
# this script and writes nvrm-info.after.json and sysctl.after.txt, adding ONLY
# what the fixed library and OS layer add for this boot's raw values.
# Derived from the capture:
#   JSON    gpu.rm_sm_version from sm_version_major/minor (the raw code is
#           major << 8 | minor); gpu.compute_capability_major/minor from the
#           raw architecture and implementation codes through CC_TABLE; the
#           versions object and running_rm_version from built_for_rm_version
#   sysctl  the unit number and uuid from hw.nvidia.gpus.<unit>.uuid, the PCI
#           location from identity.pci_domain/bus/slot (the function is not in
#           the capture and is stated as 0 below)
# Stated facts of the fixed code, not read from the capture (each commented at
# its use): schema_minor 2, CC_TABLE, the sysctl names, the empty version
# suffix, the source labels.
# usage: python3 -I make-after.py [DIR]     (DIR defaults to this script's)
import json
import os
import re
import sys

# The fixed libnvrm table (architecture, implementation) -> compute capability.
# A stated fact of the library: GB206 (architecture 0x1b0 = 432, implementation
# 6) is compute capability 12.0.  An unknown pair is an error, not a guess.
CC_TABLE = {(432, 6): (12, 0)}
# The capture has no pci_function (the old OS layer did not report it); the
# fixed OS layer reports the device's function, 0 for this single-function board.
PCI_FUNCTION = 0


def version(string, source):
    major, minor, patch = (int(x) for x in string.split("."))
    return {"available": True, "string": string, "major": major, "minor": minor,
            "patch": patch, "parts": [major, minor, patch], "source": source}


def after_json(doc):
    out = {}
    for key, value in doc.items():
        if key == "schema_minor":
            value = 2  # stated: the schema minor that adds versions and compute_capability_*
        if key == "running_rm_version":
            # stated: the fixed OS layer reports the running RM version, source "os"
            value = {"available": True, "value": doc["built_for_rm_version"], "source": "os"}
        out[key] = value
        if key == "running_rm_version":
            out["versions"] = {"driver": version(doc["built_for_rm_version"], "os"),
                               "built_for": version(doc["built_for_rm_version"], "derived")}
    for dev in out["devices"]:
        gpu = {}
        for key, value in dev["gpu"].items():
            gpu[key] = value
            if key == "sm_version_minor":
                major, minor = dev["gpu"]["sm_version_major"]["value"], value["value"]
                cc = CC_TABLE[(dev["gpu"]["architecture"]["value"], dev["gpu"]["implementation"]["value"])]
                gpu["rm_sm_version"] = {"available": True, "value": major << 8 | minor, "source": "rm"}
                gpu["compute_capability_major"] = {"available": True, "value": cc[0], "source": "derived"}
                gpu["compute_capability_minor"] = {"available": True, "value": cc[1], "source": "derived"}
        dev["gpu"] = gpu
    return out


def unit_and_uuid(text):
    """(unit, uuid) of the one GPU in hw.nvidia.gpus.<unit>.uuid."""
    found = re.findall(r"^hw\.nvidia\.gpus\.(\d+)\.uuid: (\S+)$", text, re.M)
    if len(found) != 1:
        raise SystemExit("make-after.py: want exactly one hw.nvidia.gpus.<unit>.uuid line, found %d" % len(found))
    return found[0]


def after_sysctl(text, doc):
    lines = text.splitlines()
    v = version(doc["built_for_rm_version"], "os")
    # stated: the names the fixed OS layer gives the version sysctls; the suffix is empty for a release build
    parts = [("string", v["string"]), ("major", v["major"]), ("minor", v["minor"]),
             ("patch", v["patch"]), ("suffix", ""), ("available", 1)]
    added = ["hw.nvidia.version_%s: %s" % kv for kv in parts]
    unit, uuid = unit_and_uuid(text)
    ident = doc["devices"][0]["identity"]
    dom, bus, slot = (ident[k]["value"] for k in ("pci_domain", "pci_bus", "pci_slot"))
    fn = PCI_FUNCTION
    # stated: dev.nvidia.<unit>.uuid, .pci_bus_id (dddd:bb:ss.f lowercase hex) and
    # .%location (newbus form, decimal dbsf) are what the fixed OS layer adds
    dev = ["dev.nvidia.%s.uuid: %s" % (unit, uuid),
           "dev.nvidia.%s.pci_bus_id: %04x:%02x:%02x.%x" % (unit, dom, bus, slot, fn),
           "dev.nvidia.%s.%%location: slot=%d function=%d dbsf=pci%d:%d:%d:%d" % (unit, slot, fn, dom, bus, slot, fn)]
    return "\n".join(lines[:1] + added + lines[1:] + dev) + "\n"


def main(argv):
    here = argv[1] if len(argv) > 1 else os.path.dirname(os.path.abspath(__file__))
    doc = json.load(open(os.path.join(here, "nvrm-info.json")))
    text = open(os.path.join(here, "sysctl.txt")).read()
    out_json = after_json(doc)
    out_sysctl = after_sysctl(text, doc)
    with open(os.path.join(here, "nvrm-info.after.json"), "w") as f:
        json.dump(out_json, f, separators=(",", ":"))
        f.write("\n")
    with open(os.path.join(here, "sysctl.after.txt"), "w") as f:
        f.write(out_sysctl)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
