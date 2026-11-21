#!/usr/bin/env python3
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# ko_sysinit_order.py <module.ko> - run as python3 -I ko_sysinit_order.py FILE; print "<module name> <subsystem> <order>" (decimal) for
# every module a kernel module file declares with DECLARE_MODULE (SYSINIT of
# module_register_init), read from the built file: the sysinit structure holds the
# subsystem and the order, its udata points at the moduledata, whose first word
# points at the module name.  Used by tests/prime_import_test.sh to check the
# order of the unload guard in the file the kit really stages (not in the source).
# aarch64 ELF only (it reads R_AARCH64_ABS64 and the RELATIVE relocations of an arm64 module;
# an amd64 module uses other relocation types and is refused).  Usage: one argument, else exit 2;
# anything unexpected in the file ends the program with a message on stderr (exit 1).
import re
import struct
import subprocess
import sys


def run(*a):
    return subprocess.run(a, capture_output=True, text=True, check=True).stdout


def main(path):
    secs = {}
    for l in run("readelf", "-SW", path).splitlines():
        m = re.match(r"\s*\[\s*\d+\]\s+(\S+)\s+\S+\s+([0-9a-f]+)\s+([0-9a-f]+)\s+([0-9a-f]+)", l)
        if m:
            secs[m.group(1)] = (int(m.group(2), 16), int(m.group(3), 16), int(m.group(4), 16))
    data = open(path, "rb").read()

    def addr_to_off(a):
        for name, (va, off, size) in secs.items():
            if va and va <= a < va + size and not name.startswith(".bss"):
                return off + (a - va)
        raise SystemExit("ko_sysinit_order: address %#x is in no section" % a)

    relocs = {}   # offset -> (symbol or None, addend)
    for l in run("readelf", "-rW", path).splitlines():
        m = re.match(r"([0-9a-f]{8,16})\s+[0-9a-f]+\s+(R_\S+)\s+(?:([0-9a-f]+)\s+(\S+)\s+\+\s+([0-9a-f]+)|([0-9a-f]+))\s*$", l)
        if m:
            if not m.group(2).startswith("R_AARCH64_"):
                raise SystemExit("ko_sysinit_order: %s relocation: only arm64 modules are supported" % m.group(2))
            off = int(m.group(1), 16)
            if m.group(4):
                relocs[off] = (m.group(4), int(m.group(5), 16))
            else:
                relocs[off] = (None, int(m.group(6), 16))
    out = []
    for off, (sym, add) in sorted(relocs.items()):
        if sym != "module_register_init":
            continue
        start = off - 16                      # struct sysinit: subsystem, order, next, func, udata
        fo = addr_to_off(start)
        sub, order = struct.unpack_from("<II", data, fo)
        udata = relocs.get(start + 24)
        if not udata or udata[0] is not None:
            raise SystemExit("ko_sysinit_order: no udata relocation at %#x" % (start + 24))
        md = udata[1]                          # struct moduledata: name, evhand, priv
        nm = relocs.get(md)
        if not nm or nm[0] is not None:
            raise SystemExit("ko_sysinit_order: no name relocation at %#x" % md)
        no = addr_to_off(nm[1])
        end = data.index(b"\0", no)
        out.append((data[no:end].decode(), sub, order))
    if not out:
        raise SystemExit("ko_sysinit_order: no module sysinit found")
    for name, sub, order in out:
        print(name, sub, order)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(2)
    main(sys.argv[1])
