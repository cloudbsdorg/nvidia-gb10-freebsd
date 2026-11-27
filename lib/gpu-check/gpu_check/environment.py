# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# environment.py - the rules of the environment of a test boot.
#
# A native test boot loads no Linux compatibility module: the card is
# driven by the native modules only.  The rules live here, in the shared
# library, so the command and the kit read the same list.
#
# A module of the Linux layer is one whose name holds "linux", or one of
# whose parts (the parts are separated by a dot) starts with one of the
# prefixes below.  The kernel itself is not a module of the Linux layer.
"""The rules of the environment of a native run."""

# The name parts that make a module a module of the Linux layer.
LINUX_LAYER_PREFIXES = (
    "linux",
    "lkpi",
    "lindebugfs",
    "linsysfs",
    "linprocfs",
    "drm",
    "dmabuf",
    "ttm",
    "amdgpu",
    "radeonkms",
    "i915kms",
)

# The name of the kernel in a module listing: it is not a module.
KERNEL = "kernel"


def is_linux_layer(name):
    """True when this module name is a module of the Linux layer."""
    if not name:
        return False
    if name == KERNEL:
        return False
    lowered = name.lower()
    if "linux" in lowered:
        return True
    for part in lowered.split("."):
        for prefix in LINUX_LAYER_PREFIXES:
            if part.startswith(prefix):
                return True
    return False


def loaded_modules(listing):
    """The names of the loaded modules of a module listing.

    The listing is the output of "kldstat -v".  A list of names is taken
    as it is: the caller may already have read the listing.
    """
    if isinstance(listing, (list, tuple)):
        names = []
        for name in listing:
            if not isinstance(name, str) or not name:
                continue
            if name == KERNEL:
                continue
            if name not in names:
                names.append(name)
        return names
    return _names_of_listing(listing)


def _names_of_listing(listing):
    """The names of the modules of the text of a module listing.

    A module that was loaded on its own is one line with the address, the
    size and the name: "5 1 0xffff... 993000 amdgpu.ko (/boot/amdgpu.ko)".
    A module that came with another one is listed under it, indented, with
    its number and its name: "675 amdgpu", or "308 uhub/usb_linux" when
    the module belongs to a class (the name is the part after the slash).
    Both are modules; the header of the listing is not.
    The kernel is not a module and is not in the list.
    """
    names = []
    for line in listing.splitlines():
        _add_names_of_line(line, names)
    return names


def _add_names_of_line(line, names):
    """Add the names of the modules of one line of a listing."""
    fields = line.split()
    if not fields or fields[0] in ("Id", "Contains"):
        # the header of the listing (and of the list under it)
        return
    if line.startswith("\t"):
        # a module that came with another one: the line is indented,
        # and holds the number of the module and its name.  Two
        # modules may share a line.
        _add_child_names(fields, names)
        return
    if len(fields) < 5:
        return
    _add_module_name(fields[4], names)


def _add_child_names(fields, names):
    """Add the names of the modules that came with another one."""
    for one in fields[1::2]:
        name = one.rsplit("/", 1)[-1]
        if name and name != KERNEL and name not in names:
            names.append(name)


def _add_module_name(field, names):
    """Add the name of one module of a listing."""
    name = field[:-3] if field.endswith(".ko") else field
    if not name or name == KERNEL or name in names:
        return
    names.append(name)


def linux_layer_modules(modules):
    """The modules of the Linux layer among these modules."""
    return [name for name in modules if is_linux_layer(name)]


def environment_facts(listing):
    """The facts of a module listing: the modules, and the Linux ones."""
    modules = loaded_modules(listing)
    return {"modules": modules, "linux_layer": linux_layer_modules(modules)}
