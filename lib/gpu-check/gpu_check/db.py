# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# db.py - the database of the runs, and the way the command reaches it.
#
# The database itself is a small C library (lib/gpu-check-db): it opens
# the file, applies the migrations, appends the events, writes the state
# that is derived from them and answers the questions a person asks
# afterwards.  This module is the glue: it finds the library, finds the
# migrations, and gives the command one object to hold.
#
# The core of the library knows nothing of an operating system.  What a
# machine can be asked is the work of a platform provider, and the
# provider is chosen by the library that is loaded: the ordinary one
# knows FreeBSD, the fake one knows a machine that is not there.  The
# name of the platform comes from GPU_CHECK_DB_PLATFORM, and the library
# from GPU_CHECK_DB_LIB.
#
# No SQL is written here, and none is built from a string: the library
# holds every statement, and every value that comes from outside is
# bound.
"""The database of the runs."""

import ctypes
import json
import os

from . import events


class DatabaseError(Exception):
    """The database cannot be used."""


# The kinds of value the library holds.
INT = events.INT
NUMBER = events.NUMBER
STRING = events.STRING

# The libraries: the ordinary one, and the fake one that proves the core
# of the library needs no operating system of its own.
MAIN_LIBRARY = "libgpubcheckdb.so.1"
FAKE_LIBRARY = "libgpubcheckdb_fake.so"

# The name of the file in a directory of databases.
DATABASE_NAME = "gpu-check.db"

# The size of the buffer the library writes its error into.
ERROR_MAX = 512

# The message of a database that cannot be used: it is closed.
DB_CLOSED = "the database is closed"


class GdbValue(ctypes.Structure):
    """One value of the library: its kind, and what it holds."""

    _fields_ = [("kind", ctypes.c_char_p),
                ("ivalue", ctypes.c_longlong),
                ("nvalue", ctypes.c_double),
                ("text", ctypes.c_char_p)]


def _source_root():
    """The root of the tree this module is in, or None.

    In the source tree it is the root of the repository; in the
    installed tree it is the directory the library and the schema were
    installed in.
    """
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(os.path.dirname(os.path.dirname(here)))
    if root and os.path.isdir(root):
        return root
    return None


def _prefix():
    """The prefix the tool was installed under."""
    return os.environ.get("GPU_CHECK_DB_PREFIX", "/usr/local")


def library_candidates(platform=None):
    """Where the library may be, in the order it is looked for."""
    name = FAKE_LIBRARY if platform == "fake" else MAIN_LIBRARY
    out = []
    override = os.environ.get("GPU_CHECK_DB_LIB")
    if override:
        out.append(override)
    out.append(os.path.join(_prefix(), "lib", name))
    root = _source_root()
    if root:
        base = os.path.join(root, "lib", "gpu-check-db")
        out.append(os.path.join(base, name))
        if platform == "fake":
            # The library with only the fake provider lives in its own
            # directory: it is the proof that the core needs no system.
            out.append(os.path.join(base, "fake", name))
    return out


def schema_candidates():
    """Where the migrations may be, in the order they are looked for."""
    out = []
    override = os.environ.get("GPU_CHECK_DB_SCHEMA")
    if override:
        out.append(override)
    out.append(os.path.join(_prefix(), "share", "gpu-check", "schema"))
    root = _source_root()
    if root:
        out.append(os.path.join(root, "schema"))
    return out


def default_path():
    """The database of this user, when none is named.

    A run that is made as root belongs to the machine: it is kept in
    /var/db/gpu-check.  A run that is made by a person belongs to that
    person: it is kept in the state directory of the user.
    """
    if os.geteuid() == 0:
        return os.path.join("/var/db/gpu-check", DATABASE_NAME)
    state = os.environ.get("XDG_STATE_HOME")
    if not state:
        state = os.path.join(os.path.expanduser("~"), ".local", "state")
    return os.path.join(state, "gpu-check", DATABASE_NAME)


def resolve_path(path=None):
    """The file of the database.

    A path that names a directory holds the database inside it, so the
    default directory and an explicit one behave the same way.
    """
    if not path:
        path = default_path()
    if path.endswith(os.sep) or os.path.isdir(path):
        return os.path.join(path, DATABASE_NAME)
    return path


def find_schema_dir():
    """The directory of the migrations, or None."""
    for path in schema_candidates():
        if os.path.isfile(os.path.join(path, "gpu-check-db-1.sql")):
            return path
    return None


def load_library(platform=None):
    """The library of the database, or None."""
    for path in library_candidates(platform):
        try:
            return ctypes.CDLL(path)
        except OSError:
            continue
    return None


class Database(object):
    """The database of the runs.

    The object holds the file open.  Every event is written in a
    transaction of its own, so a run that is cut short leaves the events
    that were written, and the run is marked as unfinished.
    """

    def __init__(self, path=None, schema_dir=None, platform=None):
        self.platform = platform if platform else os.environ.get(
            "GPU_CHECK_DB_PLATFORM") or None
        self.library = load_library(self.platform)
        if self.library is None:
            raise DatabaseError("the library of the database cannot be found;"
                                " looked for %s"
                                % ", ".join(library_candidates(self.platform)))
        self._bind()
        self.path = resolve_path(path)
        directory = os.path.dirname(os.path.abspath(self.path))
        if directory and not os.path.isdir(directory):
            try:
                os.makedirs(directory, 0o700)
            except OSError as exc:
                raise DatabaseError("the directory %s cannot be made: %s"
                                    % (directory, exc.strerror or exc))
        schema = schema_dir if schema_dir else find_schema_dir()
        if schema is None:
            raise DatabaseError("the migrations of the database cannot be"
                                " found; looked for %s"
                                % ", ".join(schema_candidates()))
        self.schema_dir = schema
        error = ctypes.create_string_buffer(ERROR_MAX)
        self.handle = self.library.gdb_open(self.path.encode("utf-8"),
                                           schema.encode("utf-8"), error,
                                           ERROR_MAX)
        if not self.handle:
            raise DatabaseError(_text(error))

    # --- the library --------------------------------------------------------

    def _bind(self):
        """The shape of the functions of the library."""
        lib = self.library
        void = ctypes.c_void_p
        char = ctypes.c_char_p
        lib.gdb_open.argtypes = [char, char, char, ctypes.c_size_t]
        lib.gdb_open.restype = void
        lib.gdb_close.argtypes = [void]
        lib.gdb_close.restype = None
        lib.gdb_error.argtypes = [void]
        lib.gdb_error.restype = char
        lib.gdb_event_begin.argtypes = [void, char, char]
        lib.gdb_event_begin.restype = void
        lib.gdb_event_free.argtypes = [void]
        lib.gdb_event_free.restype = None
        lib.gdb_event_int.argtypes = [void, char, ctypes.c_longlong]
        lib.gdb_event_int.restype = ctypes.c_int
        lib.gdb_event_num.argtypes = [void, char, ctypes.c_double]
        lib.gdb_event_num.restype = ctypes.c_int
        lib.gdb_event_text.argtypes = [void, char, char]
        lib.gdb_event_text.restype = ctypes.c_int
        lib.gdb_event_commit.argtypes = [void]
        lib.gdb_event_commit.restype = ctypes.c_int
        lib.gdb_event_abort.argtypes = [void]
        lib.gdb_event_abort.restype = ctypes.c_int
        lib.gdb_batch_begin.argtypes = [void]
        lib.gdb_batch_begin.restype = ctypes.c_int
        lib.gdb_batch_end.argtypes = [void]
        lib.gdb_batch_end.restype = ctypes.c_int
        lib.gdb_snapshot_begin.argtypes = [void, char]
        lib.gdb_snapshot_begin.restype = ctypes.c_longlong
        lib.gdb_snapshot_property.argtypes = [void, ctypes.c_longlong, char,
                                              char, ctypes.POINTER(GdbValue)]
        lib.gdb_snapshot_property.restype = ctypes.c_int
        lib.gdb_snapshot_end.argtypes = [void, ctypes.c_longlong]
        lib.gdb_snapshot_end.restype = ctypes.c_int
        lib.gdb_capture.argtypes = [void, char, ctypes.c_longlong]
        lib.gdb_capture.restype = ctypes.c_int
        lib.gdb_replay.argtypes = [void]
        lib.gdb_replay.restype = ctypes.c_int
        lib.gdb_query_history.argtypes = [void, ctypes.c_int]
        lib.gdb_query_history.restype = void
        lib.gdb_query_show.argtypes = [void, ctypes.c_longlong]
        lib.gdb_query_show.restype = void
        lib.gdb_query_compare.argtypes = [void, ctypes.c_longlong,
                                          ctypes.c_longlong]
        lib.gdb_query_compare.restype = void
        lib.gdb_query_export.argtypes = [void, ctypes.c_longlong]
        lib.gdb_query_export.restype = void
        lib.gdb_query_properties.argtypes = [void, ctypes.c_longlong,
                                              ctypes.c_int, ctypes.c_int]
        lib.gdb_query_properties.restype = void
        lib.gdb_string_free.argtypes = [void]
        lib.gdb_string_free.restype = None
        lib.gdb_platform_default.argtypes = []
        lib.gdb_platform_default.restype = char
        lib.gdb_platform_names.argtypes = []
        lib.gdb_platform_names.restype = void

    # --- the file -----------------------------------------------------------

    def close(self):
        """Close the file."""
        if self.handle:
            self.library.gdb_close(self.handle)
            self.handle = None

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()
        return False

    def error(self):
        """The last error of the library."""
        if not self.handle:
            return DB_CLOSED
        message = self.library.gdb_error(self.handle)
        return message.decode("utf-8", "replace") if message else "unknown"

    # --- the events ---------------------------------------------------------

    def write_event(self, event):
        """Write one event, in a transaction of its own."""
        if not self.handle:
            raise DatabaseError(DB_CLOSED)
        handle = self.library.gdb_event_begin(self.handle,
                                              event.kind.encode("utf-8"),
                                              event.name.encode("utf-8"))
        if not handle:
            raise DatabaseError(self.error())
        try:
            for key, kind, value in events.flatten(event.payload):
                name = key.encode("utf-8")
                if kind == INT:
                    rc = self.library.gdb_event_int(handle, name, int(value))
                elif kind == NUMBER:
                    rc = self.library.gdb_event_num(handle, name, float(value))
                else:
                    rc = self.library.gdb_event_text(handle, name,
                                                     str(value).encode("utf-8"))
                if rc != 0:
                    raise DatabaseError(self.error())
        except Exception:
            self.library.gdb_event_free(handle)
            raise
        if self.library.gdb_event_commit(handle) != 0:
            raise DatabaseError(self.error())

    def snapshot(self, phase):
        """Take a snapshot of the machine.

        The provider of the platform is asked what the machine holds, and
        every answer is a property of the snapshot.  The snapshot is one
        transaction: it is either all there or none of it.
        """
        if not self.handle:
            raise DatabaseError(DB_CLOSED)
        snapshot_id = self.library.gdb_snapshot_begin(self.handle,
                                                      phase.encode("utf-8"))
        if snapshot_id <= 0:
            raise DatabaseError(self.error())
        if self.library.gdb_capture(self.handle, b"", snapshot_id) != 0:
            raise DatabaseError(self.error())
        if self.library.gdb_snapshot_end(self.handle, snapshot_id) != 0:
            raise DatabaseError(self.error())
        return snapshot_id

    def replay(self):
        """Build the state that is derived from the events again."""
        if not self.handle:
            raise DatabaseError(DB_CLOSED)
        if self.library.gdb_replay(self.handle) != 0:
            raise DatabaseError(self.error())

    # --- the questions ------------------------------------------------------

    def _answer(self, pointer):
        """The answer of the library, as a document."""
        if not pointer:
            raise DatabaseError(self.error())
        try:
            text = ctypes.string_at(pointer).decode("utf-8", "replace")
        finally:
            self.library.gdb_string_free(ctypes.c_void_p(pointer))
        try:
            return json.loads(text)
        except ValueError as exc:
            raise DatabaseError("the answer of the database is not JSON: %s"
                                % exc)

    def history(self, last=20):
        """The runs, the newest first."""
        return self._answer(self.library.gdb_query_history(self.handle,
                                                            int(last)))

    def show(self, run_id):
        """The document of a run."""
        return self._answer(self.library.gdb_query_show(self.handle,
                                                         int(run_id)))

    def compare(self, first, second):
        """Two runs, side by side."""
        return self._answer(self.library.gdb_query_compare(self.handle,
                                                            int(first),
                                                            int(second)))

    def export(self, run_id):
        """The document of a run, as the tool printed it."""
        return self._answer(self.library.gdb_query_export(self.handle,
                                                           int(run_id)))

    def properties(self, run_id, changed=False, counters=False):
        """The properties of a run."""
        return self._answer(self.library.gdb_query_properties(self.handle,
                                                               int(run_id),
                                                               1 if changed else 0,
                                                               1 if counters else 0))

    # --- the platform -------------------------------------------------------

    def platform_name(self):
        """The name of the platform the library knows."""
        if not self.library:
            return None
        name = self.library.gdb_platform_default()
        return name.decode("utf-8", "replace") if name else None

    def platform_names(self):
        """The names of the providers that are registered."""
        pointer = self.library.gdb_platform_names()
        if not pointer:
            return []
        try:
            text = ctypes.string_at(pointer).decode("utf-8", "replace")
        finally:
            self.library.gdb_string_free(ctypes.c_void_p(pointer))
        return [line for line in text.split("\n") if line]


def _text(buffer):
    """The text of a buffer the library wrote into."""
    value = buffer.value
    if isinstance(value, bytes):
        return value.decode("utf-8", "replace")
    return str(value)


class Recorder(object):
    """The subscriber that writes the events to the database.

    It is a subscriber like any other: the run does not know that the
    database is there, and the database does not change the run.
    """

    def __init__(self, database):
        self.database = database

    def __call__(self, event):
        if event.kind == "snapshot":
            # A snapshot is not an event of the run: the library takes it
            # and writes the snapshot row and the properties of it in one
            # transaction.  The event of the run says that a snapshot was
            # asked for, and the library has already made it.
            self.database.snapshot(event.payload.get("phase", ""))
            return
        self.database.write_event(event)
