# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# redact.py - what may not leave the machine in a report.
#
# The report of a run is read by people who are not the person who made
# it, and it is attached to things that travel.  It therefore holds no
# name of a person, no name of the host, no path into the home of
# somebody, and no serial number.  A UUID is hashed: the same UUID gives
# the same hash on every run, so two reports can be compared, and the
# UUID itself is not in the report.
"""The redaction of the report."""

import hashlib
import os
import re

# The keys whose value is a serial number.
SERIAL_KEYS = ("serial", "serial_number", "serialnumber", "sn")

# A serial number in a line of text: a label, then the number.
SERIAL_TEXT = re.compile(r"\b(s/n|serial|serial number|sn)\b\s*[:#=]?\s*"
                         r"[A-Za-z0-9][A-Za-z0-9_-]{3,}", re.IGNORECASE)

# What a serial number becomes.
REDACTED = "redacted"


def hashed_uuid(uuid):
    """The hash of a UUID: the UUID itself is never printed.

    The hash is the first sixteen hex digits of the SHA-256 of the UUID.
    It is the same on every run, so two reports of the same card can be
    compared, and it says nothing about the card to a reader who does not
    have the UUID.
    """
    if not isinstance(uuid, str) or not uuid:
        return None
    return "sha256:" + hashlib.sha256(uuid.encode("utf-8")).hexdigest()[:16]


def _home():
    """The home directory of the user, or None."""
    home = os.path.expanduser("~")
    if not home or home == "/" or not os.path.isabs(home):
        return None
    return home


def _hostname():
    """The name of the host, or None."""
    try:
        import socket

        name = socket.gethostname()
    except Exception:
        return None
    if not name or len(name) < 3:
        return None
    return name


def _username():
    """The name of the user, or None."""
    try:
        import getpass

        name = getpass.getuser()
    except Exception:
        return None
    if not name or len(name) < 2 or name == "root":
        return None
    return name


def scrub(text):
    """The text without the personal data of this machine.

    The home path becomes a tilde, the name of the host and the name of
    the user become words, and a serial number is redacted.
    """
    if not isinstance(text, str) or not text:
        return text
    home = _home()
    if home:
        text = text.replace(home, "~")
    host = _hostname()
    if host:
        text = re.sub(r"\b%s\b" % re.escape(host), "the host", text)
    user = _username()
    if user:
        text = re.sub(r"\b%s\b" % re.escape(user), "the user", text)
    text = SERIAL_TEXT.sub(lambda match: "%s: %s" % (match.group(1), REDACTED), text)
    return text


def redact(value, key=None):
    """The value without the personal data of this machine.

    A dictionary is walked: the keys that name a serial lose their
    value, and the key that names a UUID holds the hash of the UUID
    instead of the UUID.  Every other string is scrubbed.
    """
    if isinstance(value, dict):
        return _redact_dict(value)
    if isinstance(value, list):
        return [redact(one, key) for one in value]
    if isinstance(value, str):
        return scrub(value)
    return value


def _redact_dict(value):
    """A dictionary without the personal data of this machine."""
    out = {}
    for name, one in value.items():
        out[name] = _redact_entry(name, one)
    return out


def _redact_entry(name, one):
    """One entry of a dictionary: the value without its personal data."""
    if isinstance(name, str) and name.lower() in SERIAL_KEYS:
        return REDACTED
    if name == "uuid":
        hashed = hashed_uuid(one)
        return hashed if hashed else REDACTED
    return redact(one, name)
