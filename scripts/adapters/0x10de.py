#!/usr/bin/env python3
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# The probe adapter of one vendor.
#
# The decision core of the tool (scripts/gpu-check) names no vendor: it
# asks for an adapter by the vendor id of the card, and this file is the
# answer for the vendor whose id names it.  Everything this vendor needs
# to be opened, read and tested lives here and nowhere else.
#
# The adapter answers six questions, and every answer carries a status
# and the reason for it:
#
#   identity(device, prefixes)    is this card the device that opened, and
#                                 which device of the resource manager is it
#   device_open(device, prefixes) can a client be opened on this card
#   memory_steps(device, ...)     the memory probe: the steps, in order
#   channel_steps(device, ...)    the channel probe: the steps, in order
#   uvm / prime / display         the three paths that are not memory
#
# Every entry point takes the same arguments, so that the core calls a
# vendor the same way whichever vendor it is.  An argument this vendor
# does not need is named with a leading underscore: it is part of the
# interface, and not used here.
#
# The probes are library code, not programs that are run: the steps of
# the memory probe and of the channel probe are the steps of the C
# probes of the library, written against the same public API, so a run
# of this tool and a run of the C probes say the same thing.
#
# The names of this vendor live here: the decision core of the tool may
# not hold them, and the vendor-free lint of the test suite reads them
# from here.
"""The probe adapter: open a card, read its identity, test its memory."""
import ctypes
import glob
import hashlib
import json
import os
import subprocess
import time

PASS = "pass"
FAIL = "fail"
NOT_TESTED = "not_tested"
NOT_AVAILABLE = "not_available"

# The program and the library of this vendor.  They live under the prefix
# of the installed tool, so an installation under another prefix finds
# its own.
PROGRAM = "nvrm-info"
LIBRARY = "libnvrm.so.1"

# The environment variable that says where the library is, when the
# library is not under a prefix of the tool.  It is a way to run the
# probes against a library that is being built, without installing it.
LIBRARY_ENV = "GPU_CHECK_NVRM_LIBRARY"

# The names of this vendor.  The decision core of the tool may not hold
# them: the vendor-free lint of the test suite reads them from here.
VOCABULARY = ("nvrm-info", "libnvrm.so.1", "libnvrm.so", "nvidia-uvm",
              "nvidiactl", "nvidia-modeset", "nvidia-drm")

# The bytes of one memory test.
TEST_BYTES = 4096

# The buffer the library writes its error message into.
ERROR_BYTES = 256

# The reason a file of this vendor is not installed: the name of the
# file, and the paths that were looked in.
NOT_INSTALLED = "%s is not installed at %s"

# The size of a memory object, in the words the rows use.
MIB_TEXT = "%d MiB"

# The sizes of the memory probe.
MIB = 1024 * 1024
VA_BYTES = 64 * MIB
VA_ALIGN = 2 * MIB
OBJECT_BYTES = 2 * MIB
PATTERN_BYTES = 64 * 1024
PATTERN_OFFSET = 4096

# The sizes of the channel probe.
FRAME_BYTES = 4 * MIB
FRAME_DWORDS = 6
ISOLATION_VA_BYTES = 64 * 1024
ISOLATION_DWORDS = 8
SUBMIT_TIMEOUT_NS = 10 * 1000 * 1000 * 1000
WAIT_TIMEOUT_NS = 10 * 1000 * 1000 * 1000
RELEASE_PAYLOAD = 0x0000600D0000600D

# How many releases the latency step measures, and how many the stress
# step makes.  They are small enough to be a diagnostic and large
# enough to mean something; the environment may ask for more.
LATENCY_SAMPLES = 200
STRESS_DEFAULT = 2000
STRESS_SECONDS_DEFAULT = 10

# The wire format of the pushbuffer: the values of nvrm_methods.h, which
# is a private header of the library.  The adapter is built against the
# public headers alone, so it carries the few it needs.
MTHD_SEM_ADDR_LO = 0x5C
MTHD_OP_INC = 1
SEM_RELEASE = 1
SEM_WFI = 1 << 20
SEM_PAYLOAD_64 = 1 << 24

# The engine a channel of the probe uses.
ENG_COMPUTE = 0x02

# The values of the library the probe reads: the error codes and the
# states of a channel.  They are the numbers of the public header.
NVRM_OK = 0
NVRM_E_TIMEOUT = 15
NVRM_E_LOST = 16
NVRM_CHAN_ALIVE = 1
NVRM_CHAN_DEAD = 2


def _paths(prefixes, name, sub):
    """Every place the program or the library may be, prefix by prefix."""
    return [os.path.join(prefix, sub, name) for prefix in prefixes]


def _library_paths(prefixes):
    """Every place the library may be.

    The environment comes first: it is the way to point the probes at a
    library that is not installed yet.
    """
    paths = []
    chosen = os.environ.get(LIBRARY_ENV)
    if chosen:
        paths.append(chosen)
    paths.extend(_paths(prefixes, LIBRARY, "lib"))
    return paths


def _find(prefixes, name, sub, executable=False):
    """The first of the paths that is there, or None."""
    for path in _paths(prefixes, name, sub):
        if not os.path.isfile(path):
            continue
        if executable and not os.access(path, os.X_OK):
            continue
        return path
    return None


def _find_library(prefixes):
    """The library of this vendor, or None."""
    for path in _library_paths(prefixes):
        if os.path.isfile(path):
            return path
    return None


def _as_int(value):
    """The number of a JSON value that is a number or a hex string."""
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        try:
            return int(value, 0)
        except ValueError:
            return None
    return None


def _value(identity, name):
    """The value of one field of an identity, or None."""
    field = identity.get(name)
    if isinstance(field, dict):
        if not field.get("available"):
            return None
        return _as_int(field.get("value"))
    return _as_int(field)


def _location(selector):
    """The bus, the slot and the function of a pciconf selector.

    A pciconf selector reads "pci0:0:2:0": the name of the bus, the bus,
    the slot and the function.
    """
    parts = selector.split(":")
    if len(parts) < 4:
        return (None, None, None)
    try:
        return (int(parts[1]), int(parts[2]), int(parts[3]))
    except ValueError:
        return (None, None, None)


def _hashed_uuid(uuid):
    """The hash of a UUID: the UUID itself is never printed."""
    if not isinstance(uuid, str) or not uuid:
        return None
    return "sha256:" + hashlib.sha256(uuid.encode("utf-8")).hexdigest()[:16]


def _devices(document):
    """The device list of an nvrm-info document."""
    devices = document.get("devices") if isinstance(document, dict) else None
    if not isinstance(devices, list):
        return []
    return [entry for entry in devices if isinstance(entry, dict)]


def _matches(device, entry):
    """True when the resource manager device has the identity of the card."""
    identity = entry.get("identity")
    if not isinstance(identity, dict):
        return False
    vendor = _value(identity, "pci_vendor")
    devid = _value(identity, "pci_device")
    if vendor is None or devid is None:
        return False
    return (vendor == _as_int(device["vendor"])
            and devid == _as_int(device["device"]))


def _at_the_slot(device, entry):
    """True when the resource manager device sits at the slot of the card."""
    identity = entry.get("identity")
    if not isinstance(identity, dict):
        return False
    bus, slot, _ = _location(device["selector"])
    if bus is None or slot is None:
        return False
    return (_value(identity, "pci_bus") == bus
            and _value(identity, "pci_slot") == slot)


def _extra(entry):
    """What the core needs to know about the device that opened."""
    extra = {}
    index = entry.get("index")
    if isinstance(index, int) and not isinstance(index, bool):
        extra["rm_index"] = index
    identity = entry.get("identity")
    if isinstance(identity, dict):
        field = identity.get("uuid")
        if isinstance(field, dict) and field.get("available"):
            hashed = _hashed_uuid(field.get("value"))
            if hashed:
                extra["uuid_sha256"] = hashed
    return extra


def _run_program(prefixes):
    """The document of the program, or the reason there is none."""
    program = _find(prefixes, PROGRAM, "sbin", executable=True)
    if program is None:
        return None, (NOT_INSTALLED
                      % (PROGRAM, ", ".join(_paths(prefixes, PROGRAM, "sbin"))))
    try:
        done = subprocess.run([program, "--json"], stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, check=False)
    except OSError as exc:
        return None, "%s cannot be run: %s" % (PROGRAM, exc)
    if done.returncode != 0:
        return None, "%s failed with status %d" % (PROGRAM, done.returncode)
    try:
        return json.loads(done.stdout.decode("utf-8", "replace")), None
    except ValueError as exc:
        return None, "%s printed no JSON document: %s" % (PROGRAM, exc)


# --- the library ------------------------------------------------------------

class _EnumOpts(ctypes.Structure):
    """The options of the enumeration: the backend and the flags."""

    _fields_ = [
        ("backend", ctypes.c_char_p),
        ("flags", ctypes.c_uint),
        ("reserved", ctypes.c_uint32 * 4),
    ]


class _OpenOpts(ctypes.Structure):
    """The options of a client: the map and export slots."""

    _fields_ = [
        ("size", ctypes.c_uint32),
        ("flags", ctypes.c_uint32),
        ("map_slots", ctypes.c_uint32),
        ("export_slots", ctypes.c_uint32),
    ]


class _VaParams(ctypes.Structure):
    """The parameters of a reservation of virtual address space."""

    _fields_ = [
        ("size", ctypes.c_uint32),
        ("flags", ctypes.c_uint32),
        ("bytes", ctypes.c_uint64),
        ("alignment", ctypes.c_uint64),
        ("fixed", ctypes.c_uint64),
    ]


class _MemParams(ctypes.Structure):
    """The parameters of a memory object."""

    _fields_ = [
        ("size", ctypes.c_uint32),
        ("kind", ctypes.c_uint32),
        ("flags", ctypes.c_uint32),
        ("reserved", ctypes.c_uint32),
        ("bytes", ctypes.c_uint64),
        ("alignment", ctypes.c_uint64),
        ("page_size", ctypes.c_uint64),
    ]


class _GpuMapParams(ctypes.Structure):
    """The parameters of a mapping for the GPU."""

    _fields_ = [
        ("size", ctypes.c_uint32),
        ("flags", ctypes.c_uint32),
        ("va", ctypes.c_uint64),
        ("offset", ctypes.c_uint64),
        ("length", ctypes.c_uint64),
    ]


class _MemInfo(ctypes.Structure):
    """What the library says about a memory object."""

    _fields_ = [
        ("size", ctypes.c_uint32),
        ("kind", ctypes.c_uint32),
        ("place", ctypes.c_uint32),
        ("cpu_attr", ctypes.c_uint32),
        ("bytes", ctypes.c_uint64),
        ("page_size", ctypes.c_uint64),
        ("cpu_mapped", ctypes.c_uint32),
        ("gpu_maps", ctypes.c_uint32),
    ]


class _ClientStats(ctypes.Structure):
    """What the client holds now and what it has done."""

    _fields_ = [
        ("size", ctypes.c_uint32),
        ("reserved", ctypes.c_uint32),
        ("allocs", ctypes.c_uint64),
        ("frees", ctypes.c_uint64),
        ("live_mem", ctypes.c_uint64),
        ("live_bytes", ctypes.c_uint64),
        ("live_reservations", ctypes.c_uint64),
        ("live_gpu_maps", ctypes.c_uint64),
        ("live_cpu_maps", ctypes.c_uint64),
        ("spare_descriptors", ctypes.c_uint64),
        ("failed_releases", ctypes.c_uint64),
        ("live_channels", ctypes.c_uint64),
        ("channels_created", ctypes.c_uint64),
    ]


class _VaSpaceInfo(ctypes.Structure):
    """The virtual address space of a client."""

    _fields_ = [
        ("size", ctypes.c_uint32),
        ("base", ctypes.c_uint64),
        ("end", ctypes.c_uint64),
        ("free_bytes", ctypes.c_uint64),
    ]


class _ChanParams(ctypes.Structure):
    """The parameters of a channel."""

    _fields_ = [
        ("size", ctypes.c_uint32),
        ("engines", ctypes.c_uint32),
        ("entries", ctypes.c_uint32),
        ("flags", ctypes.c_uint32),
    ]


class _GpEntry(ctypes.Structure):
    """One element of the pushbuffer of a channel."""

    _fields_ = [
        ("va", ctypes.c_uint64),
        ("dwords", ctypes.c_uint32),
        ("flags", ctypes.c_uint32),
    ]


class _SubmitOpts(ctypes.Structure):
    """The options of a submission."""

    _fields_ = [
        ("size", ctypes.c_uint32),
        ("flags", ctypes.c_uint32),
        ("timeout_ns", ctypes.c_uint64),
    ]


class _SubmitResult(ctypes.Structure):
    """What a submission placed and what point it reached."""

    _fields_ = [
        ("size", ctypes.c_uint32),
        ("accepted", ctypes.c_uint32),
        ("point", ctypes.c_uint64),
    ]


class _ChanStatus(ctypes.Structure):
    """The state of a channel."""

    _fields_ = [
        ("size", ctypes.c_uint32),
        ("state", ctypes.c_uint32),
        ("error", ctypes.c_uint32),
        ("gp_get", ctypes.c_uint32),
        ("gp_put", ctypes.c_uint32),
        ("reserved", ctypes.c_uint32),
        ("submitted", ctypes.c_uint64),
        ("completed", ctypes.c_uint64),
    ]


class _ChanInfo(ctypes.Structure):
    """What a channel is."""

    _fields_ = [
        ("size", ctypes.c_uint32),
        ("engines", ctypes.c_uint32),
        ("entries", ctypes.c_uint32),
        ("runlist", ctypes.c_uint32),
        ("cls_gpfifo", ctypes.c_uint32),
        ("subch_class", ctypes.c_uint32 * 8),
        ("sem_va", ctypes.c_uint64),
    ]


def _library(path):
    """The library, with the types of its calls set."""
    library = ctypes.CDLL(path)
    library.nvrm_enumerate.restype = ctypes.c_int
    library.nvrm_enumerate.argtypes = [ctypes.POINTER(ctypes.c_void_p),
                                       ctypes.POINTER(_EnumOpts), ctypes.c_char_p,
                                       ctypes.c_size_t]
    library.nvrm_close.restype = None
    library.nvrm_close.argtypes = [ctypes.c_void_p]
    library.nvrm_device_count.restype = ctypes.c_uint
    library.nvrm_device_count.argtypes = [ctypes.c_void_p]
    library.nvrm_device_get.restype = ctypes.c_void_p
    library.nvrm_device_get.argtypes = [ctypes.c_void_p, ctypes.c_uint]
    library.nvrm_client_open.restype = ctypes.c_int
    library.nvrm_client_open.argtypes = [ctypes.c_void_p, ctypes.POINTER(_OpenOpts),
                                         ctypes.POINTER(ctypes.c_void_p), ctypes.c_char_p,
                                         ctypes.c_size_t]
    library.nvrm_client_close.restype = ctypes.c_int
    library.nvrm_client_close.argtypes = [ctypes.c_void_p]
    library.nvrm_client_errmsg.restype = ctypes.c_char_p
    library.nvrm_client_errmsg.argtypes = [ctypes.c_void_p]
    library.nvrm_client_stats_get.restype = ctypes.c_int
    library.nvrm_client_stats_get.argtypes = [ctypes.c_void_p,
                                              ctypes.POINTER(_ClientStats)]
    library.nvrm_vaspace_info_get.restype = ctypes.c_int
    library.nvrm_vaspace_info_get.argtypes = [ctypes.c_void_p,
                                               ctypes.POINTER(_VaSpaceInfo)]
    library.nvrm_va_reserve.restype = ctypes.c_int
    library.nvrm_va_reserve.argtypes = [ctypes.c_void_p, ctypes.POINTER(_VaParams),
                                         ctypes.POINTER(ctypes.c_uint64)]
    library.nvrm_va_release.restype = ctypes.c_int
    library.nvrm_va_release.argtypes = [ctypes.c_void_p, ctypes.c_uint64]
    library.nvrm_mem_alloc.restype = ctypes.c_int
    library.nvrm_mem_alloc.argtypes = [ctypes.c_void_p, ctypes.POINTER(_MemParams),
                                        ctypes.POINTER(ctypes.c_void_p)]
    library.nvrm_mem_free.restype = None
    library.nvrm_mem_free.argtypes = [ctypes.c_void_p]
    library.nvrm_mem_info_get.restype = ctypes.c_int
    library.nvrm_mem_info_get.argtypes = [ctypes.c_void_p, ctypes.POINTER(_MemInfo)]
    library.nvrm_mem_map_gpu.restype = ctypes.c_int
    library.nvrm_mem_map_gpu.argtypes = [ctypes.c_void_p, ctypes.POINTER(_GpuMapParams)]
    library.nvrm_mem_unmap_gpu.restype = ctypes.c_int
    library.nvrm_mem_unmap_gpu.argtypes = [ctypes.c_void_p, ctypes.c_uint64]
    library.nvrm_mem_map_cpu.restype = ctypes.c_int
    library.nvrm_mem_map_cpu.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_void_p]
    library.nvrm_mem_unmap_cpu.restype = ctypes.c_int
    library.nvrm_mem_unmap_cpu.argtypes = [ctypes.c_void_p]
    library.nvrm_mem_read.restype = ctypes.c_int
    library.nvrm_mem_read.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_void_p,
                                       ctypes.c_size_t]
    library.nvrm_mem_write.restype = ctypes.c_int
    library.nvrm_mem_write.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_void_p,
                                        ctypes.c_size_t]
    library.nvrm_mem_export_fd.restype = ctypes.c_int
    library.nvrm_mem_export_fd.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_int)]
    library.nvrm_mem_import_fd.restype = ctypes.c_int
    library.nvrm_mem_import_fd.argtypes = [ctypes.c_void_p, ctypes.c_int,
                                            ctypes.POINTER(ctypes.c_void_p)]
    library.nvrm_chan_create.restype = ctypes.c_int
    library.nvrm_chan_create.argtypes = [ctypes.c_void_p, ctypes.POINTER(_ChanParams),
                                          ctypes.POINTER(ctypes.c_void_p)]
    library.nvrm_chan_submit.restype = ctypes.c_int
    library.nvrm_chan_submit.argtypes = [ctypes.c_void_p, ctypes.POINTER(_GpEntry),
                                         ctypes.c_uint, ctypes.POINTER(_SubmitOpts),
                                         ctypes.POINTER(_SubmitResult)]
    library.nvrm_chan_wait.restype = ctypes.c_int
    library.nvrm_chan_wait.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_uint64]
    library.nvrm_chan_status_get.restype = ctypes.c_int
    library.nvrm_chan_status_get.argtypes = [ctypes.c_void_p,
                                              ctypes.POINTER(_ChanStatus)]
    library.nvrm_chan_info_get.restype = ctypes.c_int
    library.nvrm_chan_info_get.argtypes = [ctypes.c_void_p, ctypes.POINTER(_ChanInfo)]
    library.nvrm_chan_destroy.restype = None
    library.nvrm_chan_destroy.argtypes = [ctypes.c_void_p]
    library.nvrm_strerror.restype = ctypes.c_char_p
    library.nvrm_strerror.argtypes = [ctypes.c_int]
    library.nvrm_error_id.restype = ctypes.c_char_p
    library.nvrm_error_id.argtypes = [ctypes.c_int]
    library.nvrm_json_device.restype = ctypes.c_int
    library.nvrm_json_device.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
    return library


def _failed(library, call, code):
    """The message of a failed call of the library."""
    identifier = library.nvrm_error_id(code)
    text = library.nvrm_strerror(code)
    return "%s failed: %s (%s)" % (
        call,
        text.decode("utf-8", "replace") if text else "error %d" % code,
        identifier.decode("utf-8", "replace") if identifier else "unknown")


def _client_message(library, client):
    """The message the library holds for the client."""
    if client is None:
        return "there is no client"
    text = library.nvrm_client_errmsg(client)
    return text.decode("utf-8", "replace") if text else ""


# --- the steps --------------------------------------------------------------

class _Steps(object):
    """The steps of a probe, as the core asks for them.

    The core owns the order of the steps and what a failure means; this
    only says what each step found.
    """

    def __init__(self):
        self.steps = {}

    def ok(self, name, detail):
        """The step passed."""
        self.steps[name] = {"status": PASS, "detail": detail}
        return True

    def bad(self, name, detail):
        """The step failed."""
        self.steps[name] = {"status": FAIL, "detail": detail}
        return False

    def answer(self):
        """The steps, as the core wants them."""
        return {"steps": self.steps}


def _open_client(library, device):
    """Open a client on one device.  Returns (client, error)."""
    opts = _OpenOpts()
    opts.size = 0
    opts.flags = 0x1  # NVRM_OPEN_ALLOW_MAP
    opts.map_slots = 4
    opts.export_slots = 4
    client = ctypes.c_void_p()
    error = ctypes.create_string_buffer(ERROR_BYTES)
    code = library.nvrm_client_open(device, ctypes.byref(opts), ctypes.byref(client),
                                    error, ERROR_BYTES)
    if code != 0:
        return None, error.value.decode("utf-8", "replace") or _failed(
            library, "nvrm_client_open", code)
    return client, None


def _find_device(library, device):
    """The device of the resource manager that is this card, or None."""
    ctx = ctypes.c_void_p()
    error = ctypes.create_string_buffer(ERROR_BYTES)
    code = library.nvrm_enumerate(ctypes.byref(ctx), None, error, ERROR_BYTES)
    if code != 0:
        return None, None, error.value.decode("utf-8", "replace") or _failed(
            library, "nvrm_enumerate", code)
    count = library.nvrm_device_count(ctx)
    for index in range(count):
        one = library.nvrm_device_get(ctx, index)
        info = _device_identity(library, one)
        if info is None:
            continue
        if _matches(device, info) and _at_the_slot(device, info):
            return ctx, one, None
    library.nvrm_close(ctx)
    return None, None, ("no device of the resource manager is the card %s:%s at %s"
                        % (device["vendor"], device["device"], device["selector"]))


def _device_entry(document):
    """The device of a JSON document of the library.

    The library writes one device as {"kind": "device", "device":
    {...}}; the program of this vendor writes the devices in a list.
    Both hold the same fields, under the same names.
    """
    if not isinstance(document, dict):
        return None
    entry = document.get("device")
    if isinstance(entry, dict):
        return entry
    return document


def _device_identity(library, one):
    """The identity of one device of the resource manager, or None.

    The library writes the identity of a device as JSON; the adapter
    reads it from there, so it never has to know the layout of the
    structure of the library.
    """
    document = _device_json(library, one)
    entry = _device_entry(document)
    if entry is None:
        return None
    return {"identity": entry.get("identity") or {},
            "index": entry.get("index")}


def _device_json(library, one):
    """The JSON document of one device, or None."""
    libc = ctypes.CDLL(None)
    libc.open_memstream.restype = ctypes.c_void_p
    libc.open_memstream.argtypes = [ctypes.POINTER(ctypes.c_char_p),
                                    ctypes.POINTER(ctypes.c_size_t)]
    libc.fclose.restype = ctypes.c_int
    libc.fclose.argtypes = [ctypes.c_void_p]
    libc.free.restype = None
    libc.free.argtypes = [ctypes.c_void_p]
    buffer = ctypes.c_char_p()
    size = ctypes.c_size_t()
    stream = libc.open_memstream(ctypes.byref(buffer), ctypes.byref(size))
    if not stream:
        return None
    try:
        code = library.nvrm_json_device(one, stream)
    finally:
        libc.fclose(stream)
    if code != 0:
        libc.free(buffer)
        return None
    try:
        data = ctypes.string_at(buffer, size.value)
    finally:
        libc.free(buffer)
    try:
        return json.loads(data.decode("utf-8", "replace"))
    except ValueError:
        return None


# --- the identity -----------------------------------------------------------

def identity(device, prefixes):
    """Is the device that opened the card of this selector?"""
    document, error = _library_devices(prefixes)
    if document is None:
        return {"status": FAIL, "reason": error, "extra": {}}
    devices = _devices(document)
    if not devices:
        return {"status": FAIL, "reason": "%s named no device" % PROGRAM, "extra": {}}
    same = [entry for entry in devices if _matches(device, entry)]
    exact = [entry for entry in same if _at_the_slot(device, entry)]
    if exact:
        return {"status": PASS,
                "reason": "the device opened and its identity matches the card",
                "extra": _extra(exact[0])}
    if len(same) == 1:
        return {"status": PASS,
                "reason": "the device opened and its identity matches the card",
                "extra": _extra(same[0])}
    if len(same) > 1:
        return {"status": NOT_TESTED,
                "reason": ("the resource manager holds %d devices with this identity and "
                           "does not say which one is this card" % len(same)),
                "extra": {}}
    return {"status": FAIL,
            "reason": "no device of %s is the card %s:%s"
                      % (PROGRAM, device["vendor"], device["device"]),
            "extra": {}}


def _library_devices(prefixes):
    """The devices of the resource manager, read by the library.

    The library is asked first: it is the library the probes use.  The
    program of this vendor is the fallback, for a machine where the
    library is not installed.
    """
    path = _find_library(prefixes)
    if path is not None:
        try:
            library = _library(path)
            ctx = ctypes.c_void_p()
            error = ctypes.create_string_buffer(ERROR_BYTES)
            code = library.nvrm_enumerate(ctypes.byref(ctx), None, error, ERROR_BYTES)
            if code == 0:
                count = library.nvrm_device_count(ctx)
                devices = []
                for index in range(count):
                    document = _device_json(library, library.nvrm_device_get(ctx, index))
                    entry = _device_entry(document)
                    if isinstance(entry, dict):
                        entry.setdefault("index", index)
                        devices.append(entry)
                library.nvrm_close(ctx)
                return {"devices": devices}, None
        except Exception as exc:  # never a traceback: the row says what failed
            return None, "the library could not be read: %s: %s" % (type(exc).__name__, exc)
    return _run_program(prefixes)


def device_open(device, prefixes):
    """Can a client be opened on this card?"""
    path = _find_library(prefixes)
    if path is None:
        return {"status": NOT_AVAILABLE,
                "reason": NOT_INSTALLED
                          % (LIBRARY, ", ".join(_library_paths(prefixes)))}
    library = None
    ctx = None
    try:
        library = _library(path)
        ctx, one, error = _find_device(library, device)
        if one is None:
            return {"status": FAIL, "reason": error}
        client, problem = _open_client(library, one)
        if client is None:
            return {"status": FAIL, "reason": problem}
        try:
            return {"status": PASS,
                    "reason": "a client opened on the card %s" % device["selector"]}
        finally:
            library.nvrm_client_close(client)
    except Exception as exc:  # never a traceback: the row says what failed
        return {"status": FAIL,
                "reason": "the device could not be opened: %s: %s"
                          % (type(exc).__name__, exc)}
    finally:
        if ctx is not None and library is not None:
            library.nvrm_close(ctx)


# --- the memory probe -------------------------------------------------------

def _pattern(library, client, mem, what):
    """Write a pattern through the memory and read it back."""
    want = bytearray((index * 131 + 7) & 0xFF for index in range(PATTERN_BYTES))
    got = bytearray(PATTERN_BYTES)
    source = (ctypes.c_ubyte * PATTERN_BYTES).from_buffer(want)
    code = library.nvrm_mem_write(mem, PATTERN_OFFSET, source, PATTERN_BYTES)
    if code != 0:
        return False, "%s: the write failed: %s" % (what, _client_message(library, client))
    target = (ctypes.c_ubyte * PATTERN_BYTES).from_buffer(got)
    code = library.nvrm_mem_read(mem, PATTERN_OFFSET, target, PATTERN_BYTES)
    if code != 0:
        return False, "%s: the read failed: %s" % (what, _client_message(library, client))
    if bytes(want) != bytes(got):
        return False, "%s: the bytes read back differ" % what
    return True, "%s: %d KiB written and read back equal" % (what, PATTERN_BYTES // 1024)


def _attr_name(value):
    """The name of a CPU attribute."""
    return {1: "cached", 2: "write-combined", 3: "device"}.get(value, "unknown")


class _MemoryState(object):
    """What is open while the memory probe runs."""

    def __init__(self):
        self.client = None
        self.second = None
        self.vram = None
        self.sysmem = None
        self.imported = None
        self.exported = -1
        self.va = 0


def _memory_steps(library, device):
    """The steps of the memory probe, on one device."""
    steps = _Steps()
    state = _MemoryState()
    try:
        client, problem = _open_client(library, device)
        if client is None:
            steps.bad("client_open", problem)
            return steps
        state.client = client
        steps.ok("client_open", "own RM session, VA space and spares (ALLOW_MAP)")
        _memory_space(library, client, steps, state)
        _memory_objects(library, client, steps, state)
        _memory_mappings(library, client, steps, state)
        _memory_export(library, client, device, steps, state)
        return steps
    finally:
        _release(library, state, steps)


def _memory_space(library, client, steps, state):
    """The address space of the card, and the reservation of the probe."""
    info = _VaSpaceInfo()
    code = library.nvrm_vaspace_info_get(client, ctypes.byref(info))
    if code != 0:
        steps.bad("vaspace", _client_message(library, client))
    else:
        steps.ok("vaspace", "base 0x%x end 0x%x" % (info.base, info.end))

    params = _VaParams()
    params.size = 0
    params.flags = 0
    params.bytes = VA_BYTES
    params.alignment = VA_ALIGN
    params.fixed = 0
    address = ctypes.c_uint64()
    code = library.nvrm_va_reserve(client, ctypes.byref(params),
                                   ctypes.byref(address))
    if code != 0:
        steps.bad("va_reserve", _client_message(library, client))
    else:
        state.va = address.value
        steps.ok("va_reserve", MIB_TEXT % (VA_BYTES // MIB))


def _memory_objects(library, client, steps, state):
    """The two objects of the probe: the video memory and the system memory."""
    state.vram = _alloc(library, client, 1)
    if state.vram is None:
        steps.bad("alloc_vram", _client_message(library, client))
    else:
        steps.ok("alloc_vram", MIB_TEXT % (OBJECT_BYTES // MIB))
        mem_info = _MemInfo()
        code = library.nvrm_mem_info_get(state.vram, ctypes.byref(mem_info))
        if code != 0:
            steps.bad("vram_info", _client_message(library, client))
        else:
            steps.ok("vram_info", "place %s, page %d, cpu attribute %s"
                     % ("video" if mem_info.place == 1 else "system",
                        mem_info.page_size, _attr_name(mem_info.cpu_attr)))

    state.sysmem = _alloc(library, client, 2)
    if state.sysmem is None:
        steps.bad("alloc_sysmem", _client_message(library, client))
    else:
        steps.ok("alloc_sysmem", MIB_TEXT % (OBJECT_BYTES // MIB))


def _memory_mappings(library, client, steps, state):
    """The mappings of the two objects, and the pattern through them."""
    if state.vram is not None:
        _map_object(library, client, steps, state.vram, state.va,
                    "map_gpu_vram", "map_cpu_vram", "rw_vram")
    if state.sysmem is not None:
        _map_object(library, client, steps, state.sysmem, state.va + 32 * MIB,
                    "map_gpu_sysmem", "map_cpu_sysmem", "rw_sysmem")


def _map_object(library, client, steps, mem, va, gpu_name, cpu_name, pattern_name):
    """The mappings of one object, and the pattern through it."""
    ok, detail = _map_gpu(library, client, mem, va)
    (steps.ok if ok else steps.bad)(gpu_name, detail)
    ok, detail = _map_cpu(library, client, mem)
    if ok:
        steps.ok(cpu_name, detail)
        ok, detail = _pattern(library, client, mem, pattern_name)
        (steps.ok if ok else steps.bad)(pattern_name, detail)
    else:
        steps.bad(cpu_name, detail)


def _memory_export(library, client, device, steps, state):
    """The export of the video memory, and the import of it by a second client."""
    if state.vram is None:
        return
    descriptor = ctypes.c_int(-1)
    code = library.nvrm_mem_export_fd(state.vram, ctypes.byref(descriptor))
    if code != 0:
        steps.bad("export", _client_message(library, client))
        return
    state.exported = descriptor.value
    steps.ok("export", "descriptor")
    second, problem = _open_client(library, device)
    if second is None:
        steps.bad("second_client", problem)
        return
    state.second = second
    steps.ok("second_client", "opened")
    handle = ctypes.c_void_p()
    code = library.nvrm_mem_import_fd(second, state.exported,
                                      ctypes.byref(handle))
    if code != 0:
        steps.bad("import", _client_message(library, second))
        return
    state.imported = handle
    steps.ok("import", "the exported video memory")
    ok, detail = _read_import(library, second, state.imported)
    (steps.ok if ok else steps.bad)("read_import", detail)


def _alloc(library, client, kind):
    """Allocate one memory object, or None."""
    params = _MemParams()
    params.size = 0
    params.kind = kind
    params.flags = 0
    params.reserved = 0
    params.bytes = OBJECT_BYTES
    params.alignment = 0
    params.page_size = 0
    mem = ctypes.c_void_p()
    code = library.nvrm_mem_alloc(client, ctypes.byref(params), ctypes.byref(mem))
    if code != 0:
        return None
    return mem


def _map_gpu(library, client, mem, va):
    """Map one object for the GPU."""
    params = _GpuMapParams()
    params.size = 0
    params.flags = 0
    params.va = va
    params.offset = 0
    params.length = 0
    code = library.nvrm_mem_map_gpu(mem, ctypes.byref(params))
    if code != 0:
        return False, _client_message(library, client)
    return True, "mapped at the reservation"


def _map_cpu(library, client, mem):
    """Map one object for the CPU."""
    address = ctypes.c_void_p()
    code = library.nvrm_mem_map_cpu(mem, 0x3, ctypes.byref(address))
    if code != 0:
        return False, _client_message(library, client)
    return True, "read-write"


def _read_import(library, client, imported):
    """Read the pattern through the import."""
    address = ctypes.c_void_p()
    code = library.nvrm_mem_map_cpu(imported, 0x1, ctypes.byref(address))
    if code != 0:
        return False, _client_message(library, client)
    want = bytearray((index * 131 + 7) & 0xFF for index in range(4096))
    got = bytearray(4096)
    target = (ctypes.c_ubyte * 4096).from_buffer(got)
    code = library.nvrm_mem_read(imported, PATTERN_OFFSET, target, 4096)
    if code != 0:
        return False, _client_message(library, client)
    if bytes(want) != bytes(got):
        return False, "the import reads other bytes"
    return True, "the import reads the pattern"


def _release(library, state, steps):
    """Give everything back, and say what was left behind.

    The three steps of the end always answer: a probe that failed before
    it opened a client still says what it left behind, and the driver
    never has to guess what a missing step means.
    """
    _release_objects(library, state)
    client = state.client
    if client is None:
        _release_without_client(steps)
    else:
        _release_with_client(library, client, state, steps)
    if state.second is not None:
        library.nvrm_client_close(state.second)
    if client is not None:
        library.nvrm_client_close(client)


def _release_objects(library, state):
    """Give the memory objects back."""
    if state.imported is not None:
        library.nvrm_mem_free(state.imported)
    if state.exported >= 0:
        os.close(state.exported)
    if state.vram is not None:
        library.nvrm_mem_free(state.vram)
    if state.sysmem is not None:
        library.nvrm_mem_free(state.sysmem)


def _release_without_client(steps):
    """The end of a probe that never opened a client."""
    steps.ok("va_release", "no client was open, so no reservation was left")
    steps.ok("nothing_left", "no client was open, so nothing was left behind")
    steps.ok("no_refused_release", "no client was open, so no release was refused")


def _release_with_client(library, client, state, steps):
    """The end of a probe that opened a client."""
    _release_reservation(library, client, state, steps)
    _release_stats(library, client, steps)


def _release_reservation(library, client, state, steps):
    """Give the reservation of the address space back."""
    if not state.va:
        steps.ok("va_release", "no reservation was made, so none was left")
        return
    code = library.nvrm_va_release(client, state.va)
    if code != 0:
        steps.bad("va_release", _client_message(library, client))
    else:
        steps.ok("va_release", "released")


def _release_stats(library, client, steps):
    """Say what the client of the card left behind."""
    stats = _ClientStats()
    code = library.nvrm_client_stats_get(client, ctypes.byref(stats))
    if code != 0:
        steps.bad("nothing_left", _client_message(library, client))
        return
    clean = (stats.live_mem == 0 and stats.live_bytes == 0 and
             stats.live_reservations == 0 and stats.live_gpu_maps == 0 and
             stats.live_cpu_maps == 0)
    (steps.ok if clean else steps.bad)(
        "nothing_left",
        "live objects %d, reservations %d, GPU maps %d, CPU maps %d"
        % (stats.live_mem, stats.live_reservations, stats.live_gpu_maps,
           stats.live_cpu_maps))
    (steps.ok if stats.failed_releases == 0 else steps.bad)(
        "no_refused_release", "failed_releases %d" % stats.failed_releases)


def memory_steps(device, index, prefixes):
    """The steps of the memory probe, on the card of this selector."""
    path = _find_library(prefixes)
    if path is None:
        return {"steps": {}, "reason": NOT_INSTALLED
                % (LIBRARY, ", ".join(_library_paths(prefixes)))}
    if index is None:
        return {"steps": {}, "reason": ("the identity probe did not say which device of "
                                        "the resource manager is this card, so no memory "
                                        "was allocated")}
    try:
        library = _library(path)
        ctx, one, error = _find_device(library, device)
        if one is None:
            return {"steps": {}, "reason": error}
        try:
            steps = _memory_steps(library, one)
        finally:
            library.nvrm_close(ctx)
        return steps.answer()
    except Exception as exc:  # never a traceback: the row says what failed
        return {"steps": {}, "reason": "the memory probe failed: %s: %s"
                % (type(exc).__name__, exc)}


# --- the channel probe ------------------------------------------------------

def _method_header(subchannel, method, count, op):
    """The header of a method of the pushbuffer."""
    return (((method >> 2) & 0xFFF) | ((subchannel & 7) << 13) |
            ((count & 0x1FFF) << 16) | ((op & 7) << 29))


def _write_frame(library, client, mem, sem_va, payload):
    """Write one semaphore release into the pushbuffer."""
    words = (ctypes.c_uint32 * FRAME_DWORDS)()
    words[0] = _method_header(0, MTHD_SEM_ADDR_LO, FRAME_DWORDS - 1, MTHD_OP_INC)
    words[1] = sem_va & 0xFFFFFFFC
    words[2] = (sem_va >> 32) & 0xFFFFFFFF
    words[3] = payload & 0xFFFFFFFF
    words[4] = (payload >> 32) & 0xFFFFFFFF
    words[5] = SEM_RELEASE | SEM_WFI | SEM_PAYLOAD_64
    code = library.nvrm_mem_write(mem, 0, words, ctypes.sizeof(words))
    if code != 0:
        return False, _client_message(library, client)
    return True, ""


class _ChannelState(object):
    """What is open while the channel probe runs."""

    def __init__(self):
        self.client = None
        self.channels = []
        self.sem = None
        self.push = None
        self.sem_va = 0
        self.push_va = 0
        self.bad_va = 0


def _free_object(library, state, name):
    """Free one object of the probe, and release its address space."""
    mem = getattr(state, name)
    va = getattr(state, name + "_va")
    if mem is not None:
        library.nvrm_mem_free(mem)
        setattr(state, name, None)
    if va:
        library.nvrm_va_release(state.client, va)
        setattr(state, name + "_va", 0)


def _object(library, client, bytes_, flags):
    """Reserve, allocate and map one object of the probe."""
    va_params = _VaParams()
    va_params.size = 0
    va_params.flags = 0
    va_params.bytes = bytes_
    va_params.alignment = 0
    va_params.fixed = 0
    va = ctypes.c_uint64()
    code = library.nvrm_va_reserve(client, ctypes.byref(va_params), ctypes.byref(va))
    if code != 0:
        return None, 0, _client_message(library, client)
    mem = _alloc_bytes(library, client, bytes_)
    if mem is None:
        library.nvrm_va_release(client, va.value)
        return None, 0, _client_message(library, client)
    params = _GpuMapParams()
    params.size = 0
    params.flags = flags
    params.va = va.value
    params.offset = 0
    params.length = 0
    code = library.nvrm_mem_map_gpu(mem, ctypes.byref(params))
    if code != 0:
        library.nvrm_mem_free(mem)
        library.nvrm_va_release(client, va.value)
        return None, 0, _client_message(library, client)
    address = ctypes.c_void_p()
    code = library.nvrm_mem_map_cpu(mem, 0x3, ctypes.byref(address))
    if code != 0:
        library.nvrm_mem_free(mem)
        library.nvrm_va_release(client, va.value)
        return None, 0, _client_message(library, client)
    return mem, va.value, ""


def _alloc_bytes(library, client, bytes_):
    """Allocate one system memory object of the given size."""
    params = _MemParams()
    params.size = 0
    params.kind = 2
    params.flags = 0
    params.reserved = 0
    params.bytes = bytes_
    params.alignment = 0
    params.page_size = 0
    mem = ctypes.c_void_p()
    code = library.nvrm_mem_alloc(client, ctypes.byref(params), ctypes.byref(mem))
    if code != 0:
        return None
    return mem


def _push_wait(library, state, entry, opts, result):
    """Push one entry and wait for it."""
    code = library.nvrm_chan_submit(state.channels[0], ctypes.byref(entry), 1,
                                    ctypes.byref(opts), ctypes.byref(result))
    if code != 0:
        return code, _client_message(library, state.client)
    code = library.nvrm_chan_wait(state.channels[0], result.point, WAIT_TIMEOUT_NS)
    if code != 0:
        return code, _client_message(library, state.client)
    return 0, ""


def _release_once(library, state, payload):
    """One semaphore release through the channel of the state."""
    ok, problem = _write_frame(library, state.client, state.push, state.sem_va, payload)
    if not ok:
        return False, "the frame: %s" % problem
    entry = _GpEntry()
    entry.va = state.push_va
    entry.dwords = FRAME_DWORDS
    entry.flags = 0
    opts = _SubmitOpts()
    opts.size = ctypes.sizeof(opts)
    opts.flags = 0
    opts.timeout_ns = SUBMIT_TIMEOUT_NS
    result = _SubmitResult()
    result.size = ctypes.sizeof(result)
    code, problem = _push_wait(library, state, entry, opts, result)
    if code != 0:
        return False, "the push: %s" % problem
    value = ctypes.c_uint64()
    code = library.nvrm_mem_read(state.sem, 0, ctypes.byref(value), ctypes.sizeof(value))
    if code != 0:
        return False, "the read back: %s" % _client_message(library, state.client)
    if value.value != payload:
        return False, ("the semaphore holds 0x%016x, not 0x%016x"
                       % (value.value, payload))
    return True, ""


def _channel_steps(library, device):
    """The steps of the channel probe, on one device."""
    steps = _Steps()
    state = _ChannelState()
    try:
        state.client, problem = _open_client(library, device)
        if state.client is None:
            steps.bad("create", problem)
            return steps

        params = _ChanParams()
        params.size = 0
        params.engines = ENG_COMPUTE
        params.entries = 0
        params.flags = 0
        channel = ctypes.c_void_p()
        code = library.nvrm_chan_create(state.client, ctypes.byref(params),
                                        ctypes.byref(channel))
        if code != 0:
            steps.bad("create", _client_message(library, state.client))
            return steps
        state.channels.append(channel)
        info = _ChanInfo()
        code = library.nvrm_chan_info_get(channel, ctypes.byref(info))
        if code == 0:
            steps.ok("create", "a compute GPFIFO channel with %d entries"
                     % info.entries)
        else:
            steps.ok("create", "a compute GPFIFO channel with the default entry count")

        state.sem, state.sem_va, problem = _object(library, state.client, FRAME_BYTES, 0)
        if state.sem is None:
            steps.bad("release", "the objects of the release: %s" % problem)
            return steps
        state.push, state.push_va, problem = _object(library, state.client, FRAME_BYTES, 0x1)
        if state.push is None:
            steps.bad("release", "the objects of the release: %s" % problem)
            return steps

        zeros = (ctypes.c_uint64 * 2)()
        code = library.nvrm_mem_write(state.sem, 0, zeros, ctypes.sizeof(zeros))
        if code != 0:
            steps.bad("release", "the semaphore is not zeroed: %s"
                      % _client_message(library, state.client))
            return steps

        ok, problem = _release_once(library, state, RELEASE_PAYLOAD)
        if not ok:
            steps.bad("release", problem)
            return steps
        steps.ok("release", "the GPU wrote the payload 0x%016x into the semaphore "
                 "and the wait returned" % RELEASE_PAYLOAD)

        ok, detail = _latency(library, state)
        (steps.ok if ok else steps.bad)("latency", detail)
        if not ok:
            return steps

        ok, detail = _stress(library, state)
        (steps.ok if ok else steps.bad)("stress", detail)
        if not ok:
            return steps

        ok, detail = _isolation(library, state)
        (steps.ok if ok else steps.bad)("isolation", detail)
        return steps
    finally:
        _channel_cleanup(library, state, steps)


def _env_number(name, default):
    """A number from the environment, or the default when it is not one."""
    text = os.environ.get(name)
    if not text:
        return default
    try:
        number = int(text)
    except ValueError:
        return default
    return number if number > 0 else default


def _latency(library, state):
    """A number of releases, and the time each of them took."""
    samples = _env_number("GPU_CHECK_CHAN_LATENCY", LATENCY_SAMPLES)
    entry = _GpEntry()
    entry.va = state.push_va
    entry.dwords = FRAME_DWORDS
    entry.flags = 0
    opts = _SubmitOpts()
    opts.size = ctypes.sizeof(opts)
    opts.flags = 0
    opts.timeout_ns = SUBMIT_TIMEOUT_NS
    result = _SubmitResult()
    result.size = ctypes.sizeof(result)
    times = []
    failed = 0
    problem = ""
    for index in range(samples):
        ok, why = _write_frame(library, state.client, state.push, state.sem_va,
                                index + 1)
        start = time.monotonic_ns()
        code = 0
        if ok:
            code, problem = _push_wait(library, state, entry, opts, result)
        times.append(time.monotonic_ns() - start)
        if not ok or code != 0:
            failed += 1
            if failed == 1:
                problem = why or problem
    if failed:
        return False, "%d of %d waits failed: %s" % (failed, samples, problem)
    times.sort()
    return True, ("%d waits returned 0, p50 %d ns, p99 %d ns, max %d ns"
                   % (samples, times[(samples - 1) // 2], times[(samples * 99) // 100],
                      times[-1]))


def _stress(library, state):
    """A loop of releases, as long as the environment asks for."""
    planned = _env_number("GPU_CHECK_CHAN_STRESS", STRESS_DEFAULT)
    seconds = _env_number("GPU_CHECK_CHAN_STRESS_SECONDS", STRESS_SECONDS_DEFAULT)
    entry = _GpEntry()
    entry.va = state.push_va
    entry.dwords = FRAME_DWORDS
    entry.flags = 0
    opts = _SubmitOpts()
    opts.size = ctypes.sizeof(opts)
    opts.flags = 0
    opts.timeout_ns = SUBMIT_TIMEOUT_NS
    result = _SubmitResult()
    result.size = ctypes.sizeof(result)
    start = time.monotonic_ns()
    deadline = start + seconds * 1000000000
    done = 0
    failed = 0
    while done < planned and time.monotonic_ns() < deadline:
        ok, _ = _write_frame(library, state.client, state.push, state.sem_va,
                             RELEASE_PAYLOAD)
        code = 0
        if ok:
            code, _ = _push_wait(library, state, entry, opts, result)
        done += 1
        if not ok or code != 0:
            failed += 1
    elapsed = (time.monotonic_ns() - start) // 1000000000
    if failed:
        return False, "%d of %d waits failed, done %d/%d in %d s" % (
            failed, done, done, planned, elapsed)
    return True, "done %d/%d in %d s, every wait returned 0" % (done, planned, elapsed)


def _isolation(library, state):
    """A bad push kills one channel, the other one keeps working."""
    params = _ChanParams()
    params.size = 0
    params.engines = ENG_COMPUTE
    params.entries = 0
    params.flags = 0
    second = ctypes.c_void_p()
    code = library.nvrm_chan_create(state.client, ctypes.byref(params),
                                    ctypes.byref(second))
    if code != 0:
        return False, "the second channel: %s" % _client_message(library, state.client)
    state.channels.append(second)

    va_params = _VaParams()
    va_params.size = 0
    va_params.flags = 0
    va_params.bytes = ISOLATION_VA_BYTES
    va_params.alignment = 0
    va_params.fixed = 0
    bad_va = ctypes.c_uint64()
    code = library.nvrm_va_reserve(state.client, ctypes.byref(va_params),
                                    ctypes.byref(bad_va))
    if code != 0:
        return False, "the reservation: %s" % _client_message(library, state.client)
    state.bad_va = bad_va.value

    entry = _GpEntry()
    entry.va = bad_va.value
    entry.dwords = ISOLATION_DWORDS
    entry.flags = 0
    opts = _SubmitOpts()
    opts.size = ctypes.sizeof(opts)
    opts.flags = 0
    opts.timeout_ns = SUBMIT_TIMEOUT_NS
    result = _SubmitResult()
    result.size = ctypes.sizeof(result)
    code = library.nvrm_chan_submit(second, ctypes.byref(entry), 1, ctypes.byref(opts),
                                    ctypes.byref(result))
    wait = library.nvrm_chan_wait(second, result.point, WAIT_TIMEOUT_NS)
    status = _ChanStatus()
    library.nvrm_chan_status_get(second, ctypes.byref(status))
    dead = (wait == NVRM_E_LOST or
            (wait == NVRM_E_TIMEOUT and status.state == NVRM_CHAN_DEAD and
             status.error != 0) or
            (code == NVRM_E_LOST and status.state == NVRM_CHAN_DEAD and
             status.error != 0))
    dead_text = "the second channel died" if dead else "the second channel is alive"
    ok, problem = _release_once(library, state, RELEASE_PAYLOAD)
    live_text = ("the first channel still released the payload" if ok
                 else "the first channel failed: %s" % problem)
    third = ctypes.c_void_p()
    if library.nvrm_chan_create(state.client, ctypes.byref(params),
                                ctypes.byref(third)) == 0:
        library.nvrm_chan_destroy(third)
        third_text = "a third channel was created and destroyed"
    else:
        third_text = "the third channel was refused"
    return (dead and ok), "%s; %s; %s" % (dead_text, live_text, third_text)


def _channel_cleanup(library, state, steps):
    """Destroy everything, and say what was left behind."""
    for channel in state.channels:
        if channel is not None:
            library.nvrm_chan_destroy(channel)
    state.channels = []
    _free_object(library, state, "sem")
    _free_object(library, state, "push")
    if state.client is not None and state.bad_va:
        library.nvrm_va_release(state.client, state.bad_va)
        state.bad_va = 0
    if state.client is None:
        steps.ok("cleanup", "no client was open, so nothing was left behind")
        return
    stats = _ClientStats()
    code = library.nvrm_client_stats_get(state.client, ctypes.byref(stats))
    if code != 0:
        steps.bad("cleanup", _client_message(library, state.client))
    else:
        clean = (stats.live_channels == 0 and stats.live_mem == 0 and
                 stats.live_bytes == 0 and stats.live_reservations == 0 and
                 stats.live_gpu_maps == 0 and stats.live_cpu_maps == 0 and
                 stats.failed_releases == 0)
        (steps.ok if clean else steps.bad)(
            "cleanup",
            "live_channels %d, live_mem %d, live_bytes %d, live_reservations %d, "
            "live_gpu_maps %d, live_cpu_maps %d, failed_releases %d"
            % (stats.live_channels, stats.live_mem, stats.live_bytes,
               stats.live_reservations, stats.live_gpu_maps, stats.live_cpu_maps,
               stats.failed_releases))
    library.nvrm_client_close(state.client)
    state.client = None


def channel_steps(device, _index, prefixes):
    """The steps of the channel probe, on the card of this selector.

    The index of the card in the resource manager is part of the
    interface every vendor answers: this probe finds the card by its
    identity and needs no index, and the leading underscore says so.
    """
    path = _find_library(prefixes)
    if path is None:
        return {"steps": {}, "reason": NOT_INSTALLED
                % (LIBRARY, ", ".join(_library_paths(prefixes)))}
    try:
        library = _library(path)
        ctx, one, error = _find_device(library, device)
        if one is None:
            return {"steps": {}, "reason": error}
        try:
            steps = _channel_steps(library, one)
        finally:
            library.nvrm_close(ctx)
        return steps.answer()
    except Exception as exc:  # never a traceback: the row says what failed
        return {"steps": {}, "reason": "the channel probe failed: %s: %s"
                % (type(exc).__name__, exc)}


# --- the other paths --------------------------------------------------------

def _nodes(pattern):
    """The device nodes that match a pattern."""
    return sorted(glob.glob(pattern))


def uvm(_device, _prefixes):
    """The unified memory interface of this card.

    The arguments are part of the interface every vendor answers: this
    path needs neither of them, and the leading underscore says so.
    """
    nodes = _nodes("/dev/nvidia-uvm")
    if not nodes:
        return {"status": NOT_AVAILABLE,
                "reason": "the driver has no unified memory node: "
                          "the unified memory interface cannot be used"}
    return {"status": NOT_TESTED,
            "reason": ("the unified memory node is there (%s); the interface needs a "
                       "client of its own" % ", ".join(nodes))}


def prime(_device, _prefixes):
    """The path that imports the display of another card.

    The arguments are part of the interface every vendor answers: this
    path needs neither of them, and the leading underscore says so.
    """
    control = _nodes("/dev/nvidiactl")
    cards = _nodes("/dev/nvidia[0-9]*")
    if not control or not cards:
        return {"status": NOT_AVAILABLE,
                "reason": "the driver has no control node: another card's display "
                          "cannot be imported"}
    return {"status": NOT_TESTED,
            "reason": ("the control node and %d card node(s) are there; the import "
                       "needs a second card" % len(cards))}


def display(_device, _prefixes):
    """Is there a device node for the display of this card?

    The arguments are part of the interface every vendor answers: this
    path needs neither of them, and the leading underscore says so.
    """
    nodes = []
    for pattern in ("/dev/nvidia[0-9]*", "/dev/dri/card[0-9]*"):
        nodes.extend(_nodes(pattern))
    if not nodes:
        return {"status": NOT_AVAILABLE,
                "reason": "the driver has no device node: the display path cannot be used"}
    return {"status": NOT_TESTED,
            "reason": ("the display device is there (%s); the console path needs a seat"
                       % ", ".join(nodes))}
