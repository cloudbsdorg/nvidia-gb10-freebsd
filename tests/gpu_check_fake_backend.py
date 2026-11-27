#!/usr/bin/env python3
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# gpu_check_fake_backend.py - drive the checks of a card against the fake
# backend of our own library (libnvrm).
#
# The library of this repository answers without a card: nvrm_fake.c is a
# software GPU with a memory model and a channel engine.  This driver points
# the vendor adapter at that library and runs the steps of the memory probe
# and of the channel probe over the fake card, so the checks are exercised
# against a card that behaves like one, without one.
#
# The environment says which backend the library uses (NVRM_BACKEND=fake) and
# which library the adapter opens (GPU_CHECK_NVRM_LIBRARY).
#
# Usage: gpu_check_fake_backend.py <adapter.py> <library dir>
# Prints one JSON document: the answer of the adapter and the answer of the
# library that runs the steps.

import importlib.machinery
import importlib.util
import json
import os
import sys

# The card of the fake backend: the first device of the fake profile is the
# GB10 of this repository (vendor 0x10de, device 0x2d04, at bus 13, slot 0).
CARD = {
    "name": "vgapci1",
    "selector": "pci0:13:0:0",
    "vendor": "0x10de",
    "device": "0x2d04",
    "subvendor": "0x1462",
    "subdevice": "0x5351",
    "class": "0x030000",
    "revision": "0xa1",
}


def load(name, path):
    """Load a module from a path, whatever its name is."""
    loader = importlib.machinery.SourceFileLoader(name, path)
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def main(argv):
    if len(argv) != 3:
        sys.stderr.write("usage: gpu_check_fake_backend.py <adapter.py> <library dir>\n")
        return 2
    adapter = load("gpu_check_adapter", argv[1])
    library_dir = argv[2]
    # The library is a package: it is imported as one, so its own imports
    # (the relative ones) resolve.
    sys.path.insert(0, library_dir)
    from gpu_check import probes

    identity = adapter.identity(CARD, [])
    index = (identity.get("extra") or {}).get("rm_index")
    # The tool puts the index of the card in the device when the identity
    # read it: the probes need it to find the card in the resource manager.
    if index is not None:
        CARD["rm_index"] = index
    document = {
        "identity": identity,
        "memory_steps": adapter.memory_steps(CARD, index, []),
        "channel_steps": adapter.channel_steps(CARD, index, []),
    }
    backend = probes.AdapterBackend(adapter, [])
    document["memory"] = backend.memory(CARD)
    document["channel"] = backend.channel(CARD)
    json.dump(document, sys.stdout, indent=1, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
