# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# metrics.py - the metrics the tool measures, and what they mean.
#
# A metric is a number with a name, a unit and a kind.  The catalogue
# is curated: it is here, in one place, and a value that names a metric
# that is not in it is refused by the database.  Nothing is invented
# after the fact: a number that nobody defined cannot be stored, and so
# cannot be counted.
#
# The catalogue is the definition of the metrics: the unit says how the
# number is to be read, and the kind says whether it is a gauge (a
# value that is read), a counter (a value that only rises) or a
# boolean.
"""The metrics of the tool."""

# The catalogue.  Each entry is the key of the metric, its unit, its
# kind and what it is.
DEFINITIONS = (
    {"key": "pci.vendor_id", "unit": "none", "kind": "gauge",
     "description": "the vendor id of the card, as a number"},
    {"key": "pci.device_id", "unit": "none", "kind": "gauge",
     "description": "the device id of the card, as a number"},
    {"key": "pci.rm_index", "unit": "none", "kind": "gauge",
     "description": "the index of the card in the resource manager of the"
                    " driver"},
    {"key": "generation.arch", "unit": "none", "kind": "gauge",
     "description": "the architecture the generation of the card is for"},
)


def definitions():
    """The catalogue: the metrics the tool knows."""
    return [dict(definition) for definition in DEFINITIONS]


def _number(text):
    """The number a hexadecimal id holds, or None when it holds none."""
    if not text:
        return None
    try:
        return int(str(text), 16)
    except ValueError:
        return None


def values_of(entry):
    """The metrics of one card: the values the run measured.

    The ids of the card and the architecture of its generation are
    facts of the card, so they are read from the card itself.  The
    index in the resource manager of the driver is not: it is known
    only when the driver says so, and the run adds it when it does.
    """
    identity = entry.get("identity") or {}
    generation = entry.get("generation") or {}
    out = []
    vendor = _number(identity.get("vendor"))
    if vendor is not None:
        out.append(("pci.vendor_id", vendor))
    device = _number(identity.get("device"))
    if device is not None:
        out.append(("pci.device_id", device))
    arch_values = generation.get("arch_values") or []
    if arch_values:
        out.append(("generation.arch", arch_values[0]))
    return out
