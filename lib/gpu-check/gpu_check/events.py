# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# events.py - the events of a run, and the document they make.
#
# A run is a stream of events.  Everything that comes out of the run --
# the table a person reads, the JSON document, the JSON Lines stream, the
# database -- is a subscriber of that stream.  They cannot disagree about
# what happened: they all saw the same events.
#
# An event carries a payload, and the payload is a document.  The
# database holds that document as rows: a key, and a value of a known
# kind.  A value that is not there is not the empty text: it is nothing
# at all, and the database says nothing where the document says null.
#
# The document of the run is built from the events as well, so the JSON
# the tool prints and the JSON the database gives back are the same
# document.
"""The events of a run."""

import time

from . import FAIL, NOT_AVAILABLE, NOT_TESTED, PASS

# The kinds of value a payload can hold.  The database knows these and
# nothing else: a whole number, a number that is not whole, and text.
INT = "int"
NUMBER = "number"
STRING = "string"

# The statuses a row may carry, in the order the summary counts them.
STATUSES = (PASS, FAIL, NOT_TESTED, NOT_AVAILABLE)


def timestamp():
    """The time now, in UTC, in the words the database uses.

    The same shape the core writes: the year, the month, the day, the
    time of day, and the milliseconds.  The time is UTC, so a run that
    is read in another timezone still says when it happened.
    """
    now = time.time()
    whole = int(now)
    millis = int((now - whole) * 1000.0)
    if millis > 999:
        whole += 1
        millis = 0
    return "%s.%03dZ" % (time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(whole)),
                         millis)


class Event(object):
    """One event: what happened, and the facts it carries."""

    __slots__ = ("kind", "name", "payload", "ts")

    def __init__(self, kind, name, payload=None, ts=None):
        self.kind = kind
        self.name = name
        self.payload = payload if payload is not None else {}
        self.ts = ts if ts is not None else timestamp()

    def __repr__(self):
        return "<event %s %s>" % (self.kind, self.name)


def flatten(payload, prefix=""):
    """The payload as the rows of a table: a key, and a value of a kind.

    A list is a row of its own for every item, and the key of the row
    says where the item was: the key "features.3.name" is the field
    "name" of the fourth feature.  A value that is not there is not
    written at all: a row that says nothing is not a row.
    """
    out = []
    _flatten(payload, prefix, out)
    return out


def _flatten(value, prefix, out):
    """The rows of a payload: a key, and a value of a kind."""
    if isinstance(value, dict):
        _flatten_items(value.items(), prefix, out)
        return
    if isinstance(value, (list, tuple)):
        _flatten_items(enumerate(value), prefix, out)
        return
    _flatten_value(value, prefix, out)


def _flatten_items(items, prefix, out):
    """The rows of the items of a payload.

    The key of the row says where the item was: the key "features.3.name"
    is the field "name" of the fourth feature.
    """
    for key, one in items:
        name = "%s.%s" % (prefix, str(key)) if prefix else str(key)
        _flatten(one, name, out)


def _flatten_value(value, prefix, out):
    """One row: the value, and the kind of the value."""
    if value is None:
        return
    if isinstance(value, bool):
        out.append((prefix, INT, 1 if value else 0))
        return
    if isinstance(value, int):
        out.append((prefix, INT, value))
        return
    if isinstance(value, float):
        out.append((prefix, NUMBER, value))
        return
    out.append((prefix, STRING, str(value)))


class Stream(object):
    """The events of a run, and everything that watches them.

    A subscriber is called with every event, in the order the events
    happened.  A subscriber that fails does not stop the run: the run is
    about the machine, not about the writing of the record of it.  The
    failure is kept, and the caller says so at the end.
    """

    def __init__(self, clock=None):
        self.events = []
        self.subscribers = []
        self.errors = []
        self.clock = clock

    def subscribe(self, subscriber):
        """Watch the stream.  The subscriber is called with each event."""
        self.subscribers.append(subscriber)
        return subscriber

    def emit(self, kind, name, payload=None):
        """One event.  Every subscriber sees it, in the order it happened."""
        event = Event(kind, name, payload, self.clock() if self.clock else None)
        self.events.append(event)
        for subscriber in self.subscribers:
            try:
                subscriber(event)
            except Exception as exc:  # a broken subscriber is not a broken run
                self.errors.append((kind, name, exc))
        return event

    def failed(self):
        """The failures of the subscribers, or an empty list."""
        return list(self.errors)


def summarize(entries):
    """The summary of a run: the cards, and the rows they carry.

    The summary is counted the same way everywhere: the document the
    tool prints, the document the database gives back and the summary
    of the run all say the same numbers.
    """
    summary = {"devices": len(entries), "supported": 0, "refused": 0,
               "no_provider": 0, "checks": {}}
    for status in STATUSES:
        summary["checks"][status] = 0
    for entry in entries:
        code = (entry.get("decision") or {}).get("code")
        if code == "supported":
            summary["supported"] += 1
        elif code == "no_provider":
            summary["no_provider"] += 1
        else:
            summary["refused"] += 1
        for row in entry.get("checks") or []:
            status = row.get("status")
            if status in summary["checks"]:
                summary["checks"][status] += 1
    return summary


class DocumentBuilder(object):
    """The document of a run, built from the events.

    The document is what the tool prints with --json, and what the
    database gives back when the run is read again.  Building it from the
    events is what makes the two the same: there is one run, and one
    account of it.
    """

    def __init__(self, tool, schema, schema_version):
        self.tool = tool
        self.schema = schema
        self.schema_version = schema_version
        self.host = {}
        self.mode = "detect"
        self.fake = False
        self.capture = False
        self.providers = []
        self.devices = {}
        self.summary = None
        self.exit = None

    def feed(self, event):
        """Take one event."""
        handler = getattr(self, "_on_" + event.kind, None)
        if handler is not None:
            handler(event)

    # --- the events --------------------------------------------------------

    def _on_run_start(self, event):
        payload = event.payload
        self.host = payload.get("host") or {}
        self.mode = payload.get("mode", "detect")
        self.fake = bool(payload.get("fake"))
        self.capture = bool(payload.get("capture"))
        self.providers = list(payload.get("providers") or [])

    def _on_device(self, event):
        payload = dict(event.payload)
        ordinal = payload.pop("ordinal", None)
        self.devices[ordinal] = {"head": payload, "rows": [], "loaded": [],
                                 "uuid": None}

    def _on_check(self, event):
        payload = event.payload
        ordinal = payload.get("device_ordinal")
        device = self.devices.get(ordinal)
        if device is None:
            return
        device["rows"].append(_row_of(payload))

    def _on_device_end(self, event):
        payload = event.payload
        ordinal = payload.get("ordinal")
        device = self.devices.get(ordinal)
        if device is None:
            return
        device["loaded"] = list(payload.get("loaded") or [])
        if payload.get("uuid_sha256"):
            device["uuid"] = payload["uuid_sha256"]

    def _on_run_end(self, event):
        payload = event.payload
        if payload.get("summary") is not None:
            self.summary = payload["summary"]
        if payload.get("exit") is not None:
            self.exit = payload["exit"]

    # --- the document ------------------------------------------------------

    def entries(self):
        """The cards of the run, in the order they were found."""
        out = []
        for ordinal in sorted(self.devices, key=lambda one: (one is None, one)):
            device = self.devices[ordinal]
            entry = dict(device["head"])
            entry["loaded"] = list(device["loaded"])
            rows = sorted(device["rows"], key=lambda row: row.get("index", 0))
            entry["checks"] = rows
            if device["uuid"]:
                entry["uuid_sha256"] = device["uuid"]
            out.append(entry)
        return out

    def counted(self):
        """The summary of the run: the cards, and the rows they carry."""
        return summarize(self.entries())

    def document(self):
        """The document of the run."""
        summary = self.summary if self.summary is not None else self.counted()
        return {
            "schema_version": self.schema_version,
            "tool": self.tool,
            "schema": self.schema,
            "host": self.host,
            "mode": self.mode,
            "fake": self.fake,
            "capture": self.capture,
            "registry": {"providers": list(self.providers)},
            "devices": self.entries(),
            "summary": summary,
            "exit": self.exit,
        }


def _row_of(payload):
    """The row of a check, as the document holds it."""
    row = {"index": payload.get("index"), "name": payload.get("name"),
           "title": payload.get("title"), "status": payload.get("status"),
           "reason": payload.get("reason")}
    if payload.get("steps"):
        row["steps"] = payload["steps"]
    if payload.get("rm_index") is not None:
        row["rm_index"] = payload["rm_index"]
    if payload.get("uuid_sha256"):
        row["uuid_sha256"] = payload["uuid_sha256"]
    return row
