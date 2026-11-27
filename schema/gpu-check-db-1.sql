-- gpu-check-db-version: 1.0.0
--
-- gpu-check database, schema version 1.
--
-- The record of a run of gpu-check is a database, not a log file.  Every
-- state change is an event; the tables that hold the current state are
-- written in the same transaction as the event that caused them, and can
-- be rebuilt from the events alone (gdb_replay does exactly that).
--
-- The shape follows the rules of the third normal form:
--
--   * every fact is in one table, and every table is about one thing;
--   * the keys are integers, and the natural key of a row is unique;
--   * a row never holds a list: a list is a row of a table of its own;
--   * a row never holds a document: a value is a column of its own type,
--     or a row of the blob table;
--   * every reference is declared, and the foreign keys are enforced.
--
-- There is nothing of FreeBSD in this file: a platform is a row of the
-- platforms table, a source of a property is a row of the sources table,
-- and a property key is a row of the property_keys table.

-- The version of this schema.  One row, always.  A reader that finds a
-- newer version refuses the file instead of guessing.
CREATE TABLE schema_version (
    id          INTEGER PRIMARY KEY CHECK (id = 1),
    version     TEXT    NOT NULL,
    major       INTEGER NOT NULL CHECK (major >= 0),
    minor       INTEGER NOT NULL CHECK (minor >= 0),
    patch       INTEGER NOT NULL CHECK (patch >= 0)
);

-- The migrations that have been applied, in the order they were applied.
CREATE TABLE migrations (
    id          INTEGER PRIMARY KEY,
    name        TEXT    NOT NULL UNIQUE,
    applied_at  TEXT    NOT NULL
);

-- What a platform is: the operating system the run happened on.  The
-- core names no platform of its own; it asks the table.
CREATE TABLE platforms (
    id          INTEGER PRIMARY KEY,
    name        TEXT    NOT NULL UNIQUE,
    description TEXT    NOT NULL DEFAULT ''
);

-- Where a fact came from: the sysctl tree, the kernel environment, the
-- loader, the module list, the device tree, the operating system.
CREATE TABLE sources (
    id          INTEGER PRIMARY KEY,
    name        TEXT    NOT NULL UNIQUE,
    description TEXT    NOT NULL DEFAULT ''
);

-- The unit of a metric: bytes, hertz, seconds, degrees, none.
CREATE TABLE units (
    id          INTEGER PRIMARY KEY,
    name        TEXT    NOT NULL UNIQUE,
    description TEXT    NOT NULL DEFAULT ''
);

-- How a check ended: the words the tool prints.
CREATE TABLE result_kinds (
    id          INTEGER PRIMARY KEY,
    name        TEXT    NOT NULL UNIQUE,
    description TEXT    NOT NULL DEFAULT ''
);

-- Why a check ended the way it did.  The reason codes are a closed list,
-- so a query can count them.
CREATE TABLE reason_codes (
    id          INTEGER PRIMARY KEY,
    name        TEXT    NOT NULL UNIQUE,
    description TEXT    NOT NULL DEFAULT ''
);

-- The ids of the checks.  A check keeps its id when its title changes.
CREATE TABLE check_ids (
    id          INTEGER PRIMARY KEY,
    name        TEXT    NOT NULL UNIQUE
);

-- The versions of the things a run depends on: the tool, the kernel, the
-- driver, the firmware, the schema of the tool.  The string is kept, and
-- so is every part of it, so nothing has to parse a version to compare it.
CREATE TABLE versions (
    id          INTEGER PRIMARY KEY,
    component   TEXT    NOT NULL,
    version     TEXT    NOT NULL,
    major       INTEGER NOT NULL CHECK (major >= 0),
    minor       INTEGER NOT NULL CHECK (minor >= 0),
    patch       INTEGER NOT NULL CHECK (patch >= 0),
    suffix      TEXT    NOT NULL DEFAULT '',
    source_id   INTEGER REFERENCES sources(id),
    UNIQUE (component, version)
);

-- The kinds of events.  A typed kind, so a query can count them.
CREATE TABLE event_kinds (
    id          INTEGER PRIMARY KEY,
    name        TEXT    NOT NULL UNIQUE
);

-- The keys of the properties.  A key belongs to one source: the same
-- word may name one thing in the sysctl tree and another in the loader.
CREATE TABLE property_keys (
    id          INTEGER PRIMARY KEY,
    source_id   INTEGER NOT NULL REFERENCES sources(id),
    key         TEXT    NOT NULL,
    UNIQUE (source_id, key)
);

-- The metrics the tool knows.  A metric that is not defined here has no
-- value: the tool refuses to invent one.
CREATE TABLE metric_defs (
    id          INTEGER PRIMARY KEY,
    key         TEXT    NOT NULL UNIQUE,
    unit_id     INTEGER REFERENCES units(id),
    kind        TEXT    NOT NULL CHECK (kind IN ('gauge', 'counter', 'boolean',
                                                'string', 'blob')),
    source_id   INTEGER REFERENCES sources(id),
    description TEXT    NOT NULL DEFAULT ''
);

-- The properties: what a key is, and how it behaves.  The kind is fixed
-- the first time a key is seen; a key that changes its kind later is a
-- mismatch and is stored as a blob.
--
-- A property is a key, so its key is its own: the source of the key is
-- in property_keys and is not copied here.  A copy would be a
-- transitive dependency, and a table that holds one is not in the
-- third normal form.
CREATE TABLE properties (
    id             INTEGER PRIMARY KEY,
    key_id         INTEGER NOT NULL REFERENCES property_keys(id),
    kind           TEXT    NOT NULL CHECK (kind IN ('int', 'uint', 'number',
                                                    'string', 'blob')),
    classification TEXT    NOT NULL CHECK (classification IN ('constant',
                                                             'changing',
                                                             'counter')),
    UNIQUE (key_id)
);

-- The definitions of the checks: what each one is called and what it
-- needs.  The catalogue grows as the tool grows.
CREATE TABLE check_defs (
    id          INTEGER PRIMARY KEY,
    check_id    INTEGER NOT NULL REFERENCES check_ids(id),
    ordinal     INTEGER NOT NULL CHECK (ordinal > 0),
    title       TEXT    NOT NULL,
    needs_root  INTEGER NOT NULL CHECK (needs_root IN (0, 1)),
    needs_load  INTEGER NOT NULL CHECK (needs_load IN (0, 1)),
    loads       INTEGER NOT NULL CHECK (loads IN (0, 1)),
    is_decision INTEGER NOT NULL CHECK (is_decision IN (0, 1)),
    UNIQUE (check_id)
);

-- What a check needs before it runs.  A list is a table.
CREATE TABLE check_deps (
    def_id          INTEGER NOT NULL REFERENCES check_defs(id),
    depends_on_id  INTEGER NOT NULL REFERENCES check_defs(id),
    PRIMARY KEY (def_id, depends_on_id),
    CHECK (def_id <> depends_on_id)
);

-- The runs.  A run that did not finish has finished = 0: a machine that
-- was pulled out mid-run leaves that behind.
CREATE TABLE runs (
    id              INTEGER PRIMARY KEY,
    started_at      TEXT    NOT NULL,
    ended_at        TEXT,
    finished        INTEGER NOT NULL CHECK (finished IN (0, 1)),
    tool            TEXT    NOT NULL,
    tool_version_id INTEGER REFERENCES versions(id),
    mode            TEXT    NOT NULL,
    arch            TEXT    NOT NULL,
    platform_id     INTEGER NOT NULL REFERENCES platforms(id),
    exit_code       INTEGER,
    host_hash       TEXT    NOT NULL,
    kit_commit      TEXT,
    boot_env        TEXT,
    fake            INTEGER NOT NULL CHECK (fake IN (0, 1)),
    capture         INTEGER NOT NULL CHECK (capture IN (0, 1)),
    os_name         TEXT    NOT NULL DEFAULT '',
    os_version_id   INTEGER REFERENCES versions(id)
);

-- The cards of a run.
CREATE TABLE devices (
    id              INTEGER PRIMARY KEY,
    run_id          INTEGER NOT NULL REFERENCES runs(id),
    ordinal         INTEGER NOT NULL CHECK (ordinal >= 0),
    label           TEXT    NOT NULL,
    selector        TEXT    NOT NULL,
    name            TEXT    NOT NULL,
    vendor          TEXT    NOT NULL,
    device          TEXT    NOT NULL,
    subvendor       TEXT    NOT NULL,
    subdevice       TEXT    NOT NULL,
    class           TEXT    NOT NULL,
    revision        TEXT    NOT NULL,
    provider        TEXT,
    generation_name TEXT,
    generation_source TEXT,
    board_name      TEXT,
    board_reason    TEXT,
    uuid_sha256     TEXT,
    decision_code   TEXT    NOT NULL,
    decision_reason_code TEXT,
    decision_provider TEXT,
    decision_family TEXT,
    decision_backend TEXT,
    decision_instance TEXT,
    decision_reason TEXT    NOT NULL,
    decision_next   TEXT,
    english         TEXT    NOT NULL DEFAULT '',
    UNIQUE (run_id, ordinal)
);

-- The features of a card.  A list is a table, and a feature is a row of
-- its own: a feature has a name, a state and a reason.
CREATE TABLE device_features (
    id          INTEGER PRIMARY KEY,
    device_id   INTEGER NOT NULL REFERENCES devices(id),
    ordinal     INTEGER NOT NULL CHECK (ordinal >= 0),
    feature_index INTEGER NOT NULL CHECK (feature_index > 0),
    name        TEXT    NOT NULL,
    available   INTEGER NOT NULL CHECK (available IN (0, 1)),
    reason      TEXT,
    value       TEXT
);

-- The architectures a family serves.  A list is a table.
CREATE TABLE device_arch_values (
    id          INTEGER PRIMARY KEY,
    device_id   INTEGER NOT NULL REFERENCES devices(id),
    ordinal     INTEGER NOT NULL CHECK (ordinal >= 0),
    value       INTEGER NOT NULL CHECK (value >= 0)
);

-- The warnings of a decision.  A list is a table.
CREATE TABLE device_warnings (
    id          INTEGER PRIMARY KEY,
    device_id   INTEGER NOT NULL REFERENCES devices(id),
    ordinal     INTEGER NOT NULL CHECK (ordinal >= 0),
    warning     TEXT    NOT NULL
);

-- The modules a card loaded.  A list is a table.
CREATE TABLE device_loaded (
    id          INTEGER PRIMARY KEY,
    device_id   INTEGER NOT NULL REFERENCES devices(id),
    ordinal     INTEGER NOT NULL CHECK (ordinal >= 0),
    module      TEXT    NOT NULL
);

-- What a check did in a run.  The row of a check of a card.
CREATE TABLE run_checks (
    id              INTEGER PRIMARY KEY,
    run_id          INTEGER NOT NULL REFERENCES runs(id),
    device_id       INTEGER REFERENCES devices(id),
    def_id          INTEGER NOT NULL REFERENCES check_defs(id),
    ordinal         INTEGER NOT NULL CHECK (ordinal > 0),
    status_id       INTEGER NOT NULL REFERENCES result_kinds(id),
    reason_code_id  INTEGER REFERENCES reason_codes(id),
    reason          TEXT    NOT NULL DEFAULT '',
    started_at      TEXT,
    ended_at        TEXT,
    rm_index        INTEGER,
    uuid_sha256     TEXT
);

-- The steps of a check.  A list is a table, and a step has a name, a
-- state and a detail of its own.
CREATE TABLE check_steps (
    id              INTEGER PRIMARY KEY,
    check_row_id    INTEGER NOT NULL REFERENCES run_checks(id),
    ordinal         INTEGER NOT NULL CHECK (ordinal >= 0),
    name            TEXT    NOT NULL,
    status          TEXT    NOT NULL CHECK (status IN ('pass', 'fail',
                                                       'not_reached')),
    detail          TEXT
);

-- The events.  The source of truth: everything else is derived from
-- these rows, and these rows are only ever added to.
CREATE TABLE events (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id          INTEGER REFERENCES runs(id),
    kind_id         INTEGER NOT NULL REFERENCES event_kinds(id),
    ts              TEXT    NOT NULL,
    name            TEXT    NOT NULL,
    device_id       INTEGER REFERENCES devices(id),
    check_row_id    INTEGER REFERENCES run_checks(id),
    metric_id       INTEGER REFERENCES metric_defs(id)
);

-- What an event carried.  A row per name and value, so the payload of an
-- event is a table and not a document.
CREATE TABLE event_data (
    id              INTEGER PRIMARY KEY,
    event_id        INTEGER NOT NULL REFERENCES events(id),
    data_key        TEXT    NOT NULL,
    data_int        INTEGER,
    data_num        REAL,
    data_text       TEXT,
    UNIQUE (event_id, data_key),
    CHECK ((data_int IS NOT NULL) + (data_num IS NOT NULL)
           + (data_text IS NOT NULL) = 1)
);

-- The blobs: the pieces of a run that are too big, or too odd, to be a
-- column.  A blob is never parsed for a result; it is insurance.
CREATE TABLE blobs (
    id              INTEGER PRIMARY KEY,
    source_id       INTEGER NOT NULL REFERENCES sources(id),
    sha256          TEXT    NOT NULL,
    size            INTEGER NOT NULL CHECK (size >= 0),
    compression     TEXT    NOT NULL DEFAULT 'none',
    event_id        INTEGER REFERENCES events(id),
    created_at      TEXT    NOT NULL,
    content         BLOB,
    UNIQUE (source_id, sha256)
);

-- The measurements: the value of a metric, at a moment, for a card.
CREATE TABLE measurements (
    id              INTEGER PRIMARY KEY,
    run_id          INTEGER NOT NULL REFERENCES runs(id),
    metric_def_id   INTEGER NOT NULL REFERENCES metric_defs(id),
    device_id       INTEGER REFERENCES devices(id),
    check_row_id    INTEGER REFERENCES run_checks(id),
    observed_at     TEXT    NOT NULL,
    value_int       INTEGER,
    value_num       REAL,
    value_text      TEXT,
    blob_id         INTEGER REFERENCES blobs(id),
    CHECK ((value_int IS NOT NULL) + (value_num IS NOT NULL)
           + (value_text IS NOT NULL) + (blob_id IS NOT NULL) = 1)
);

-- The state of the machine at one point of the run.  There is one at
-- the start of the run, before the checks have run, and one at the end,
-- after they have run: the difference between the two is what the run
-- changed.
CREATE TABLE snapshots (
    id              INTEGER PRIMARY KEY,
    run_id          INTEGER NOT NULL REFERENCES runs(id),
    phase           TEXT    NOT NULL CHECK (phase IN ('run_start', 'run_end')),
    ts              TEXT    NOT NULL
);

-- The value history of a property: one row per value, closed when the
-- value changes.  A value that does not change does not make a row.
CREATE TABLE property_values (
    id              INTEGER PRIMARY KEY,
    property_id     INTEGER NOT NULL REFERENCES properties(id),
    run_id          INTEGER NOT NULL REFERENCES runs(id),
    event_id        INTEGER REFERENCES events(id),
    value_int       INTEGER,
    value_num       REAL,
    value_text      TEXT,
    blob_id         INTEGER REFERENCES blobs(id),
    observed_at     TEXT    NOT NULL,
    closed_at       TEXT,
    CHECK ((value_int IS NOT NULL) + (value_num IS NOT NULL)
           + (value_text IS NOT NULL) + (blob_id IS NOT NULL) = 1)
);

-- What a snapshot saw.  The link between a snapshot and the value of a
-- property at that moment.
CREATE TABLE observations (
    snapshot_id     INTEGER NOT NULL REFERENCES snapshots(id),
    property_id     INTEGER NOT NULL REFERENCES properties(id),
    value_id        INTEGER NOT NULL REFERENCES property_values(id),
    PRIMARY KEY (snapshot_id, property_id)
);

-- The indexes the queries use.
CREATE INDEX ix_events_run_ts ON events (run_id, ts);
CREATE INDEX ix_events_kind ON events (kind_id, id);
CREATE INDEX ix_runs_started ON runs (started_at);
CREATE INDEX ix_run_checks_run ON run_checks (run_id, ordinal);
CREATE INDEX ix_run_checks_check ON run_checks (def_id, ordinal);
-- The history of one check over time: the runs a check was in, oldest
-- first.  The id of the check is in check_ids and the check of a run
-- points at its definition, so the index is on the pointer and the name
-- of the check is one lookup away.  Copying the name into the row that
-- points at it would be a transitive dependency, and the schema is in
-- the third normal form.
CREATE INDEX ix_run_checks_check_ts ON run_checks (def_id, started_at);
CREATE INDEX ix_measurements_run ON measurements (run_id, observed_at);
CREATE INDEX ix_property_values_property ON property_values (property_id, id);
CREATE INDEX ix_property_values_run ON property_values (run_id, property_id);
CREATE INDEX ix_property_values_open ON property_values (property_id)
    WHERE closed_at IS NULL;
CREATE INDEX ix_observations_value ON observations (value_id);
CREATE INDEX ix_event_data_event ON event_data (event_id);
CREATE INDEX ix_device_features_device ON device_features (device_id, ordinal);
CREATE INDEX ix_device_loaded_device ON device_loaded (device_id, ordinal);
CREATE INDEX ix_check_steps_row ON check_steps (check_row_id, ordinal);
