# The database of gpu-check (schema, events, read-back)

The record of a run of `gpu-check` is a SQLite database, not a log file. Every state change of
a run is an event; the tables that hold the current state are written in the same transaction as
the event that caused them, and they can be rebuilt from the events alone.

- Schema: [`schema/gpu-check-db-1.sql`](../schema/gpu-check-db-1.sql) (version 1.0.0),
  [`schema/gpu-check-db-2.sql`](../schema/gpu-check-db-2.sql) (version 2.0.0).
- Library: [`lib/gpu-check-db/`](../lib/gpu-check-db/) — the core, the queries and the platform
  providers.
- Manual page: [`gpu-check.db(5)`](../man/gpu-check.db.5).
- Porting contract: [`GPU-CHECK-PLATFORMS.md`](GPU-CHECK-PLATFORMS.md).

## 1. The rules the shape follows

1. Every fact is in one table, and every table is about one thing.
2. The keys are integers. The natural key of a row is unique.
3. A row never holds a list: a list is a row of a table of its own.
4. A row never holds a document: a value is a column of its own type, or a row of `blobs`.
5. Every reference is declared, and the foreign keys are enforced
   (`PRAGMA foreign_keys=ON` on every connection).
6. Nothing in the core, the schema or the outputs names an operating system. A platform is a row
   of `platforms`; the work that needs an operating system is the work of a provider.

Rule 3 and rule 4 are what the test `(n) the schema is in the third normal form` checks: it
greps the schema for a comma in a column definition and for a `JSON` column, and it fails if it
finds one.

## 2. Versioning and migrations

The version of the file is in `schema_version`: one row, always, with the version as a string and
as its three parts, so that no reader ever has to parse a version to compare it.

| file | version | what it changes |
|---|---|---|
| `schema/gpu-check-db-1.sql` | 1.0.0 | the base schema |
| `schema/gpu-check-db-2.sql` | 2.0.0 | the class of a property moves to `property_classes`, and the class is of the run and not of the key |

The migrations are applied in the order of their numbers when the file is new, and when the file
is older than they are. The names of the migrations that have been applied are in `migrations`,
in the order they were applied.

A file whose version is **newer** than the version the tool knows is refused. The refusal names
both versions: the one of the file and the one of the tool. A file that is older is migrated
forward, never refused.

Why the class of a property moved to a table of its own: a key that is busy in one run may be
quiet in the next. A class that lived with the key would say that the second run was busy as
well. The class is now a row of `property_classes` with the run in the key, so
`properties --changed` answers for the run that is asked about and not for the run that saw the
key first.

## 3. The diagram

```
                         schema_version (1 row)
                         migrations
                         platforms
                         sources ──────┬──────────────┬───────────────┐
                          │           │              │               │
                     property_keys   versions      units        event_kinds
                          │           │              │               │
                     properties      │         metric_defs            │
                          │           │              │               │
                  property_classes    │         measurements ─────────┤
                          │           │                              │
                property_values ──────┘                              │
                          │                                          │
                 observations ── snapshots                           │
                          │                                          │
                        runs ──── devices ──── device_features       │
                          │      │         ├── device_arch_values   │
                          │      │         ├── device_warnings       │
                          │      │         └── device_loaded         │
                          │      │                                    │
                          │      └── run_checks ── check_steps        │
                          │                    │                      │
                          │                    └── check_defs ── check_deps
                          │                              │      │
                          │                          check_ids    │
                          │                                         │
                          └────────────── events ────── event_data ─┘
                                         │
                                         └── blobs
```

The lines are the foreign keys. The lookup tables (`platforms`, `sources`, `units`,
`result_kinds`, `reason_codes`, `check_ids`, `event_kinds`, `versions`, `property_keys`,
`metric_defs`, `check_defs`) are the words of the vocabulary of the run; every other table holds
facts that point at them.

## 4. Why each table is the way it is

### The vocabulary

| table | what one row is | why it is a table of its own |
|---|---|---|
| `schema_version` | the version of the file | one row, `CHECK (id = 1)`, so a second row cannot be added |
| `migrations` | one migration that has been applied | the order of the migrations is the order they were applied in, and a name is unique |
| `platforms` | one operating system a run happened on | the core names no platform of its own; it asks the table |
| `sources` | one place a fact came from | the sysctl tree, the kernel environment, the loader, the module list, the device tree, the operating system. A source is named by a fact, so it cannot be a string repeated in ten columns |
| `units` | one unit of a metric | a metric has one unit, and the unit is a word with a name of its own |
| `result_kinds` | one way a check can end | the states of a check are a closed list, so a query can count them |
| `reason_codes` | one reason a check ended the way it did | a closed list, so a query can count the reasons |
| `check_ids` | the id of a check | a check keeps its id when its title changes: the title is in `check_defs`, the id is here |
| `versions` | one version of one component | the string is kept **and** every part of it, so nothing has to parse a version to compare it. `UNIQUE (component, version)` |
| `event_kinds` | one kind of event | a typed kind, so a query can count the kinds of events |

### The facts

| table | what one row is | the normal form argument |
|---|---|---|
| `runs` | one run of the tool | the key is the run. Every fact about the run that is a fact about the run and not about a card is a column here: when it started, when it ended, whether it finished, the tool and its version, the mode, the architecture, the platform, the exit status, the host as a salted hash, the commit of the test kit, the boot environment. `finished = 0` is what a machine that was pulled out in the middle of a run leaves behind |
| `devices` | one card of a run | the key is the card. `UNIQUE (run_id, ordinal)` says that the cards of a run are ordered and that the same ordinal is not used twice |
| `device_features` | one feature of one card | a list is a table. A feature has a name, a state and a reason of its own, so it cannot be a column of `devices` |
| `device_arch_values` | one architecture a family serves | a list is a table |
| `device_warnings` | one warning of a decision | a list is a table |
| `device_loaded` | one module a card loaded | a list is a table |
| `check_defs` | one check of the catalogue | what a check is called and what it needs: root, the loader, whether it loads anything, whether it is the decision. `UNIQUE (check_id)` |
| `check_deps` | one dependency between two checks | a list is a table. The key is the pair, so a dependency is said once |
| `run_checks` | one check of one card in one run | the row of a check. `UNIQUE` is not needed here: the ordinal says the order of the run |
| `check_steps` | one step of a check | a list is a table. A step has a name, a state and a detail of its own |
| `metric_defs` | one metric the tool knows | a metric that is not defined here has no value: the tool refuses to invent one. The kind is closed by a `CHECK` |
| `measurements` | one value of one metric | the value is a column of its own type, or a blob. The `CHECK` says exactly one of the four is there |
| `blobs` | one piece of a run that does not fit in a column | a blob is never parsed for a result; it is insurance. `UNIQUE (source_id, sha256)`, so the same bytes are stored once |
| `snapshots` | one state of the machine | the phase is closed by a `CHECK`: `run_start`, `run_end`. There are two of them in a run: one before the checks and one after them |
| `properties` | one key | the kind is fixed the first time a key is seen. A property *is* a key, so `UNIQUE (key_id)`: the source of the key is in `property_keys` and is not copied here, because a copy would be a transitive dependency |
| `property_classes` | the class of one key in one run | the class is of the run, not of the key. The key is the pair `(property_id, run_id)` |
| `property_values` | one value a property held | the history: a row per value, closed when the value changes. A value that does not change does not make a row |
| `observations` | one property of one snapshot | the link between a snapshot and the value of a property at that moment. The key is the pair |
| `events` | one event | the source of truth. `INTEGER PRIMARY KEY AUTOINCREMENT`, so the ids are monotonic and a row is never reused |
| `event_data` | one name and one value of an event | the payload of an event is a table and not a document. The key is the pair `(event_id, data_key)`, and the `CHECK` says exactly one of the three columns holds the value |

### The arguments that are worth writing down

**No list in a column.** The features of a card, the architectures of a family, the warnings of a
decision, the modules a card loaded, the steps of a check, the dependencies of a check and the
payload of an event are all tables. A list in a column would have to be split with a `,` at read
time, and the split would be a guess as soon as one element held a comma itself.

**No document in a column.** A value is an integer, a number or text, and the `CHECK` on
`event_data`, `property_values` and `measurements` says that exactly one of them holds the value.
A piece of a run that does not fit is a blob, with its size and its SHA-256, and it is never
parsed for a result.

**The keys are integers, the names are unique.** Every lookup table has a `UNIQUE` on its natural
key, so a name cannot be taken twice and a lookup is an index lookup and not a walk.

**The references are declared.** Every reference is a `REFERENCES` clause, and the foreign keys
are turned on for every connection. A row that points at nothing cannot be written.

**A version is a string and its parts.** `versions` holds `version`, `major`, `minor`, `patch` and
`suffix`. A consumer never parses a version string to compare it.

## 5. The events

`events` is the source of truth: every other table is derived from these rows, and these rows are
only ever added to. The id is `INTEGER PRIMARY KEY AUTOINCREMENT`, so it is monotonic and a row
that is deleted never lets another row take its number.

The kinds are a closed list, in `event_kinds`:

| kind | what it says |
|---|---|
| `run_start` | a run began: the tool, its version, the mode, the host, the platform |
| `run_end` | a run ended: the exit status is in the `exit` key of the payload |
| `device` | a card was found: its identity and the decision taken about it |
| `device_end` | the card is done |
| `check_def` | a check of the catalogue |
| `check` | a check ran: the status, the reason, the steps |
| `metric_def` | a metric of the catalogue |
| `metric` | a metric had a value |
| `property` | a property of the machine held a value |
| `property_appear` | a property was there and was not there before |
| `property_disappear` | a property was there and is not there any more |
| `snapshot` | the machine was read: the phase, `run_start` or `run_end` |
| `blob` | a piece of a run was kept as a blob |
| `type_mismatch` | a key was one kind and is another kind now |

The payload of an event is in `event_data`: one row per name and value. The names are the same
names the JSON outputs use, so a query can read a payload without knowing the layout of the
document.

The `run_start` event is written before the row of the run exists, so its `run_id` is NULL when
it is written and is filled in when the row is made. Every other event of a run points at that
run.

### The events are the only interface

There is one internal event API, and everything else is a subscriber of it:

- the document builder (`events.DocumentBuilder`) builds the JSON document;
- the JSON-lines writer (`events.JsonLinesWriter`) writes the stream;
- the recorder (`db.Recorder`) writes the database.

The table, the `--json` output and the `--jsonl` output of a run are therefore the same run seen
three ways, and they cannot drift: they are made of the same events. The test `(j) the export of a
run is the same bytes as the live document` holds the tool to it.

## 6. The derived state, and the replay

The tables that hold the current state are written in the same transaction as the event that
caused them. The `snapshot` event is a request: the recorder catches it and reads the machine.

`gdb_replay()` reads the events of a run in the order of their ids and writes the derived tables
again, into a database of its own. The test `(m) the replay builds the tables again, and they
are the same` builds the tables twice — once as the run went, once from the events — and compares
them. If the two ever differ, the derived state is not derived from the events, and the test
fails.

## 7. The properties

### What is collected

The provider walks the machine and answers with properties: a source, a key and a value. The
FreeBSD provider walks:

- the whole sysctl tree, through `sysctl(3)` — never the text of `sysctl -a`, which is a
  human-readable rendering of a tree and not the tree;
- the `hw` and `dev.nvidia` trees;
- the kernel environment and the loader tunables, through `kenv(2)`;
- the name of the system and the kernel, through `uname(2)`;
- the modules of the loader, with their versions, through `kldstat(2)`;
- the devices of the PCI tree, through `devinfo(3)` or `pciconf(8)`.

A provider that is not allowed to read a tree says so and goes on: a run of an unprivileged user
on a machine with `security.bsd.unprivileged_kenv_read=0` still records everything else.

### The kinds are fixed the first time a key is seen

A key is an integer, a number or text, and the kind is fixed when the key is first seen. A key
that is another kind later is a mismatch: the value is kept as a blob, and the event
`type_mismatch` names both kinds. The kind of a key never changes, so a query may rely on it.

### The class of a key, and the counters

A key is `constant`, `changing` or a `counter`. A counter is a gauge that only goes up, and it is
left out of "changed" unless it is asked for (`--counters`).

The class is worked out from the values of the run: a key that never changed is constant, a key
that changed and only went up is a counter, a key that changed in any other way is changing. The
class belongs to the run, so the same key can be a counter in one run and constant in the next.

A key that was not there and is there now is the event `property_appear`; a key that was there
and is not there any more is `property_disappear`. Both are events, and both are in the
`properties --changed` answer.

### The machine is read twice in a run, not before and after every check

The ticket asked for a capture before and after every check. That was measured on this host and
it does not fit: the whole tree of the machine is 37,225 properties, a capture of it is 8.1
seconds, and thirteen checks with a capture on each side is 58 captures — about two minutes of
capturing and about 100 MB of observations for a run that takes twelve seconds without the
database.

So a run reads the machine twice: once at `run_start`, before the checks, and once at `run_end`,
after them. The difference between the two is what the run changed, which is what a capture
before and after every check would have told us, at a fifteenth of the cost. The `snapshots`
table therefore has two phases and not four, and it has no column that points at a check.

The first capture of a run has nothing to be compared with, so it makes no `property_appear` and
no `property_disappear` event: there is no "before" to have changed.

## 8. The indexes, and what they cost

The indexes the queries use:

| index | the query it serves |
|---|---|
| `ix_events_run_ts` | the events of a run, in time |
| `ix_events_kind` | the events of one kind |
| `ix_runs_started` | the history, newest first |
| `ix_run_checks_run` | the checks of a run, in order |
| `ix_run_checks_check` | the runs of one check |
| `ix_run_checks_check_ts` | the runs of one check, oldest first: the history of a check over time |
| `ix_measurements_run` | the measurements of a run |
| `ix_property_values_property` | the value history of a property |
| `ix_property_values_run` | the values of a run, by the property that holds the key |
| `ix_property_values_open` | the value that is open now |
| `ix_property_values_open_run` | the value that is open now, of one run (partial: `closed_at IS NULL`) |
| `ix_property_classes_run` | the classes of a run |
| `ix_observations_value` | the observations of a value |
| `ix_event_data_event` | the payload of an event |
| `ix_device_features_device`, `ix_device_loaded_device`, `ix_check_steps_row` | the lists of a card, of a check |

The unique indexes of the schema are indexes too: `properties (key_id)`,
`property_keys (source_id, key)`, `sources (name)`, `property_values` and the rest.

The ticket names two indexes: `(run_id, key)` and `(check_id, ts)`. In this schema the key is a
row of `property_keys` and the id of a check is a row of `check_ids`, so an index cannot hold
the key text or the name of the check without making the row that points at it hold a copy of
what it points at — a transitive dependency, and the schema would not be in the third normal
form. The indexes are therefore on the pointer, and the name is one lookup away:

| the ticket asks for | the index here | the path |
|---|---|---|
| `(run_id, key)` | `ix_property_values_run (run_id, property_id)` | the value of a key in a run: the values of the run by the property, the property by its key, the key by its source and its text. Every step is an index lookup |
| `(check_id, ts)` | `ix_run_checks_check_ts (def_id, started_at)` | the runs of one check, oldest first: the rows of the run by the definition of the check, the definition by the id of the check |

Two lookups decide the cost of a run, and both of them were measured on this host (see
[`REPORT-DB.md`](../../../../tmp/2456-db/REPORT-DB.md) for the numbers):

1. the lookup of the property of a key, by its source and its key. The tables are crossed in the
   order of the lookup — the source by its name, the key by its source and its key, the property
   by its source and its key — so every step is an index lookup and the cost does not grow with
   the number of properties;
2. the comparison of two snapshots of the properties. The two lists of property ids are sorted
   and walked in step, so the cost is the size of the lists and not their product.

The statements are prepared once and reused: `gdb_prepare()` keeps the statement of a piece of
SQL and gives it back the next time the same piece is asked for. Every statement in the library
is a literal — the test `(g) no SQL is built at runtime: every statement is a constant` greps the
source for a statement that is built with `printf` or `strcat` and fails if it finds one.

## 9. The database of a run

| | |
|---|---|
| `--db PATH` | the file to write to |
| (no flag, as root) | `/var/db/gpu-check/` |
| (no flag, as a person) | `$XDG_STATE_HOME/gpu-check/`, or `~/.local/state/gpu-check/` |
| `--no-db` | keep no record; the run works exactly as before |

The file is written in the write-ahead log mode, so a reader may read it while a run is writing
to it. Every event is its own transaction, and a snapshot of the properties is one transaction,
so a snapshot is either whole or not there at all.

A run that cannot write its record stops and says why: the tool is fail-closed, and `--no-db` is
the way to opt out. `--db` and `--no-db` together are a usage error.

The test `(f) a run that was cut short keeps its 1 events, and the run is unfinished` kills a run
in the middle and then reads the file: the events that were written are there, and the run is
marked as not finished.

## 10. The read-back commands

| command | what it answers |
|---|---|
| `gpu-check history [--last N]` | the runs that are recorded, the newest first |
| `gpu-check show RUN` | one run: the cards and the rows of their checks |
| `gpu-check compare RUN RUN` | two runs, and what ended differently in them |
| `gpu-check export RUN --json` | the document a run printed when it was made |
| `gpu-check properties RUN [--changed] [--counters]` | the properties of a run, and the ones that changed in it |

Every command prints an aligned table, and every command takes `--json` and `--jsonl`. The
documents answer against the schemas that are registered in
[`schema/samples.json`](../schema/samples.json):

- [`schema/gpu-check-history-1.schema.json`](../schema/gpu-check-history-1.schema.json)
- [`schema/gpu-check-compare-1.schema.json`](../schema/gpu-check-compare-1.schema.json)
- [`schema/gpu-check-properties-1.schema.json`](../schema/gpu-check-properties-1.schema.json)

`gpu-check export RUN --json` is the same document, byte for byte, as the `--json` of the run
when it was made.

## 11. The tests

The suite is [`tests/gpu_check_db_test.sh`](../tests/gpu_check_db_test.sh). It covers the
migrations from empty and from the version before, the refusal of a newer file, the refusal of a
value of a metric that nobody defined, the crash-safety of a run, the absence of a statement
built at runtime, the absence of an operating-system header in the core of the library, the
replay, the third normal form, the read-back commands and the errors of the tool.

The tests were written before the code, and the first run of each of them failed.
