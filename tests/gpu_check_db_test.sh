#!/bin/sh
# Copyright (c) 2026 REVYTECH, Inc.
# SPDX-License-Identifier: BSD-3-Clause
#
# gpu_check_db_test.sh - the database of the runs.
#
# The record of a run is a database, not a log file.  Every state change
# is an event, the tables that hold the current state are written in the
# same transaction as the event that caused them, and the tables can be
# built again from the events alone.  The cases below hold that:
#
#   (a) the library, the migrations and the tool are in the tree, and the
#       migrations are numbered and each one declares its version
#   (b) the migrations from empty: a new database takes every migration
#       and says which version it is
#   (c) the migration from the version before: a database that is one
#       version behind takes the new migration and keeps what it had
#   (d) a database that is newer than the tool is refused, and both
#       versions are named
#   (e) a value of a metric that nobody defined is refused
#   (f) a run that is cut short leaves the events it wrote, and the run
#       is marked as unfinished
#   (g) no SQL is built at runtime: every statement is a constant
#   (h) the core of the library holds no header of an operating system
#   (i) the library with only the fake provider builds and works
#   (j) the export of a run is the same bytes as the live document
#   (k) the questions asked afterwards are answered
#   (l) the class of a property belongs to the run and not to the key
#   (m) the events are the source of truth: the replay builds the tables
#       again and they are the same
#   (n) the schema is in the third normal form: no list in a column, no
#       document in a column, every reference declared
#   (o) a record that cannot be kept stops the run: the tool fails closed
#
# Run: sh tests/gpu_check_db_test.sh

set -u

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin
LC_ALL=C
export PATH LC_ALL

TESTSDIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$TESTSDIR/.." && pwd)
TOOL="$REPO/scripts/gpu-check"
DBDIR="$REPO/lib/gpu-check-db"
SCHEMA="$REPO/schema"
FAKELIB="$DBDIR/fake/libgpubcheckdb_fake.so"

PASSED=0
FAILED=0

ok() {
	PASSED=$((PASSED + 1))
	printf 'ok   %s\n' "$1"
}

bad() {
	FAILED=$((FAILED + 1))
	printf 'FAIL %s\n' "$1"
}

# Scratch inside the repository (tmp/ is git-ignored), not in the system
# temporary directory and not outside the repository.
mkdir -p "$REPO/tmp"
TESTROOT=$(mktemp -d "$REPO/tmp/gpu-check-db-test.XXXXXXXX") || exit 1

cleanup() {
	rm -rf "$TESTROOT"
}
trap cleanup EXIT INT TERM

# The library, the migrations and the tool are needed by every case.
if [ ! -f "$TOOL" ] || [ ! -f "$DBDIR/gdb_core.c" ] ||
	[ ! -f "$SCHEMA/gpu-check-db-1.sql" ]; then
	bad "(a) the tool, the library or the migrations are missing"
	printf 'passed: %s failed: %s\n' "$PASSED" "$FAILED"
	exit 1
fi

# The library is built here: the tests hold the tree and not a tree that
# was built before.
if [ ! -f /usr/local/include/sqlite3.h ]; then
	printf 'note: sqlite3.h is not installed: the package databases/sqlite3 is missing\n'
	printf 'note: the database cases are not run\n'
	printf 'passed: %s failed: %s\n' "$PASSED" "$FAILED"
	exit 0
fi
if ! (cd "$DBDIR/fake" && rm -f libgpubcheckdb_fake.so && make) > "$TESTROOT/build" 2>&1; then
	bad "(i) the library with only the fake provider does not build"
	cat "$TESTROOT/build"
	printf 'passed: %s failed: %s\n' "$PASSED" "$FAILED"
	exit 1
fi
if [ ! -f "$FAKELIB" ]; then
	bad "(i) the library with only the fake provider is not there"
	printf 'passed: %s failed: %s\n' "$PASSED" "$FAILED"
	exit 1
fi

# Every run of the cases uses the fake provider: the machine is not
# there, and the record of the run does not depend on one.
GPU_CHECK_DB_PLATFORM=fake
GPU_CHECK_DB_LIB="$FAKELIB"
GPU_CHECK_DB_SCHEMA="$SCHEMA"
export GPU_CHECK_DB_PLATFORM GPU_CHECK_DB_LIB GPU_CHECK_DB_SCHEMA

# The tool, with the record of the run in the database named.
run_db() {
	python3 "$TOOL" "$@" 2> "$TESTROOT/stderr"
}

# (a) the library, the migrations and the tool are in the tree, and the
# migrations are numbered and each one declares its version.
if python3 - "$SCHEMA" <<'EOF'
import glob
import os
import re
import sys

schema = sys.argv[1]
files = sorted(glob.glob(os.path.join(schema, "gpu-check-db-*.sql")))
assert files, "there is no migration"
numbers = []
for path in files:
    name = os.path.basename(path)
    number = re.match(r"^gpu-check-db-(\d+)\.sql$", name)
    assert number, name
    numbers.append(int(number.group(1)))
    text = open(path, encoding="utf-8").read()
    found = re.search(r"^-- gpu-check-db-version: (\d+)\.(\d+)\.(\d+)$",
                      text, re.M)
    assert found, "%s declares no version" % name
assert numbers == list(range(1, len(numbers) + 1)), numbers
EOF
then ok "(a) the migrations are numbered from one, and each one declares its version"
else bad "(a) the migrations are not numbered, or one declares no version"; fi

if [ -f "$REPO/man/gpu-check.db.5" ]; then
	ok "(a) the manual page of the database is in the tree"
else
	bad "(a) the manual page of the database is missing"
fi

if command -v mandoc > /dev/null 2>&1; then
	mandoc -T lint -W warning "$REPO/man/gpu-check.db.5" > "$TESTROOT/lint" 2>&1
	if [ ! -s "$TESTROOT/lint" ]; then
		ok "(a) man/gpu-check.db.5: mandoc -T lint -W warning is quiet"
	else
		bad "(a) man/gpu-check.db.5: $(tr '\n' ' ' < "$TESTROOT/lint")"
	fi
else
	printf 'note: mandoc is not installed: the man page was not linted\n'
fi

# (b) the migrations from empty: a new database takes every migration and
# says which version it is.
DB="$TESTROOT/empty.db"
run_db --fake "$REPO/tests/data/gpu-check/providers-fake/fake.json" --json \
	--db "$DB" > "$TESTROOT/empty.json" 2> "$TESTROOT/empty.err"
_empty_rc=$?
if [ "$_empty_rc" = 0 ] && [ -f "$DB" ]; then
	ok "(b) a run against a new database: rc $_empty_rc"
else
	bad "(b) a run against a new database: rc $_empty_rc $(head -c 200 "$TESTROOT/empty.err" | tr '\n' ' ')"
fi

if sqlite3 "$DB" "SELECT version || ' ' || major || '.' || minor || '.' || patch FROM schema_version WHERE id = 1;" > "$TESTROOT/version" 2>&1; then
	_version=$(cat "$TESTROOT/version")
	_migrations=$(sqlite3 "$DB" "SELECT count(*) FROM migrations;")
	if [ "$_version" = "2.0.0 2.0.0" ] && [ "$_migrations" = 2 ]; then
		ok "(b) the migrations from empty: the database is version 2.0.0 and took 2 migrations"
	else
		bad "(b) the migrations from empty: version '$_version', $_migrations migrations"
	fi
else
	bad "(b) the version of the new database cannot be read"
fi

# The migrations are recorded by name, in order.
if sqlite3 "$DB" "SELECT name FROM migrations ORDER BY id;" | tr '\n' ' ' |
	grep -q "gpu-check-db-1.sql gpu-check-db-2.sql"; then
	ok "(b) the migrations are recorded by name, in order"
else
	bad "(b) the migrations are not recorded by name, in order"
fi

# (c) the migration from the version before: a database that is one
# version behind takes the new migration and keeps what it had.
OLD="$TESTROOT/old.db"
if sqlite3 "$OLD" < "$SCHEMA/gpu-check-db-1.sql" > "$TESTROOT/old.err" 2>&1; then
	sqlite3 "$OLD" "INSERT INTO schema_version (id, version, major, minor, patch)
	    VALUES (1, '1.0.0', 1, 0, 0);
	    INSERT INTO migrations (name, applied_at)
	    VALUES ('gpu-check-db-1.sql', '2026-11-26T00:00:00.000Z');
	    INSERT INTO platforms (id, name, description) VALUES (1, 'fake', 'a machine that is not there');
	    INSERT INTO sources (id, name, description) VALUES (1, 'sysctl', 'the sysctl tree');
	    INSERT INTO property_keys (id, source_id, key) VALUES (1, 1, 'old.key');
	    INSERT INTO properties (id, key_id, kind, classification)
	    VALUES (1, 1, 'int', 'counter');
	    INSERT INTO runs (id, started_at, finished, tool, mode, arch, platform_id,
	    host_hash, fake, capture) VALUES (1, '2026-11-26T00:00:00.000Z', 1,
	    'gpu-check', 'detect', 'arm64', 1, '', 1, 0);
	    INSERT INTO property_values (id, property_id, run_id, value_int, observed_at)
	    VALUES (1, 1, 1, 7, '2026-11-26T00:00:00.000Z');" >> "$TESTROOT/old.err" 2>&1
	run_db --fake "$REPO/tests/data/gpu-check/providers-fake/fake.json" --json \
		--db "$OLD" > "$TESTROOT/old.json" 2> "$TESTROOT/oldrun.err"
	_old_rc=$?
	_old_version=$(sqlite3 "$OLD" "SELECT version FROM schema_version WHERE id = 1;")
	_old_classes=$(sqlite3 "$OLD" "SELECT count(*) FROM property_classes WHERE property_id = 1 AND run_id = 1 AND classification = 'counter';")
	_old_column=$(sqlite3 "$OLD" "SELECT count(*) FROM pragma_table_info('properties') WHERE name = 'classification';")
	if [ "$_old_rc" = 0 ] && [ "$_old_version" = "2.0.0" ] &&
		[ "$_old_classes" = 1 ] && [ "$_old_column" = 0 ]; then
		ok "(c) the migration from the version before: the database moved to 2.0.0 and kept its class"
	else
		bad "(c) the migration from the version before: rc $_old_rc, version '$_old_version', $_old_classes classes, $_old_column columns left"
	fi
else
	bad "(c) the version before cannot be made: $(head -c 200 "$TESTROOT/old.err" | tr '\n' ' ')"
fi

# (d) a database that is newer than the tool is refused, and both
# versions are named.
NEW="$TESTROOT/newer.db"
cp "$DB" "$NEW"
sqlite3 "$NEW" "UPDATE schema_version SET version = '3.0.0', major = 3, minor = 0, patch = 0 WHERE id = 1;"
run_db --fake "$REPO/tests/data/gpu-check/providers-fake/fake.json" --json \
	--db "$NEW" > "$TESTROOT/newer.json" 2> "$TESTROOT/newer.err"
_new_rc=$?
if [ "$_new_rc" = 2 ] && grep -q "3.0.0" "$TESTROOT/newer.json" &&
	grep -q "2.0.0" "$TESTROOT/newer.json" &&
	python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get('status')=='error' else 1)" "$TESTROOT/newer.json"; then
	ok "(d) a database that is newer than the tool is refused, and both versions are named"
else
	bad "(d) a database that is newer than the tool: rc $_new_rc $(head -c 200 "$TESTROOT/newer.json" | tr '\n' ' ')"
fi

# (e) a value of a metric that nobody defined is refused.
if python3 - "$REPO" "$TESTROOT" "$SCHEMA" "$FAKELIB" <<'EOF'
import os
import sys

repo, root, schema, library = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
os.environ["GPU_CHECK_DB_PLATFORM"] = "fake"
os.environ["GPU_CHECK_DB_LIB"] = library
os.environ["GPU_CHECK_DB_SCHEMA"] = schema
sys.path.insert(0, os.path.join(repo, "lib", "gpu-check"))
from gpu_check import db, events

path = os.path.join(root, "metric.db")
database = db.Database(path, platform="fake")
database.write_event(events.Event("run_start", "run_start", {
    "host": {"arch": "arm64", "os": "FreeBSD",
             "os_release": {"string": "16.0-CURRENT", "major": 16,
                            "minor": 0, "patch": 0}},
    "mode": "detect", "fake": True, "capture": False, "providers": [],
    "tool": "gpu-check", "tool_version": "1.1", "schema": "gpu-check.v1",
    "platform": "fake"}))
refused = False
try:
    database.write_event(events.Event("metric", "not.a.metric",
                                      {"key": "not.a.metric", "value": 1,
                                       "kind": "int"}))
except db.DatabaseError as exc:
    refused = "not defined" in str(exc)
assert refused, "a metric that is not defined was not refused"
database.close()
EOF
then ok "(e) a value of a metric that nobody defined is refused"
else bad "(e) a value of a metric that nobody defined was not refused"; fi

# (f) a run that is cut short leaves the events it wrote, and the run is
# marked as unfinished.
cat > "$TESTROOT/cut.py" <<'EOF'
import os
import sys
import time

sys.path.insert(0, sys.argv[1])
from gpu_check import db, events

database = db.Database(sys.argv[2], platform="fake")
database.write_event(events.Event("run_start", "run_start", {
    "host": {"arch": "arm64", "os": "FreeBSD",
             "os_release": {"string": "16.0-CURRENT", "major": 16,
                            "minor": 0, "patch": 0}},
    "mode": "detect", "fake": True, "capture": False, "providers": [],
    "tool": "gpu-check", "tool_version": "1.1", "schema": "gpu-check.v1",
    "platform": "fake"}))
sys.stdout.write("ready\n")
sys.stdout.flush()
time.sleep(300)
EOF
CUT="$TESTROOT/cut.db"
python3 "$TESTROOT/cut.py" "$REPO/lib/gpu-check" "$CUT" > "$TESTROOT/cut.out" 2>&1 &
_cut_pid=$!
_waited=0
while [ ! -s "$TESTROOT/cut.out" ] && [ "$_waited" -lt 50 ]; do
	sleep 0.1
	_waited=$((_waited + 1))
done
kill -9 "$_cut_pid" 2> /dev/null
wait "$_cut_pid" 2> /dev/null
_cut_events=$(sqlite3 "$CUT" "SELECT count(*) FROM events;" 2> /dev/null)
_cut_finished=$(sqlite3 "$CUT" "SELECT finished FROM runs WHERE id = 1;" 2> /dev/null)
_cut_ended=$(sqlite3 "$CUT" "SELECT count(*) FROM runs WHERE ended_at IS NOT NULL;" 2> /dev/null)
if [ "${_cut_events:-0}" -ge 1 ] && [ "${_cut_finished:-x}" = "0" ] &&
	[ "${_cut_ended:-1}" = "0" ]; then
	ok "(f) a run that was cut short keeps its $_cut_events events, and the run is unfinished"
else
	bad "(f) a run that was cut short: $_cut_events events, finished '$_cut_finished', $_cut_ended ended"
fi

# (g) no SQL is built at runtime: every statement is a constant.
if python3 - "$DBDIR" <<'EOF'
import os
import re
import sys

dbdir = sys.argv[1]
core = ["gdb_core.c", "gdb_query.c", "gdb_json.c", "gdb_sha256.c",
        "gdb_platform.c"]
sql_words = re.compile(r"\b(SELECT|INSERT|UPDATE|DELETE|CREATE|DROP|ALTER)\b")
builders = ("printf", "sprintf", "snprintf", "strcat", "strncat", "strcpy",
            "strncpy", "strlcat", "strlcpy")
problems = []
for name in core:
    path = os.path.join(dbdir, name)
    text = open(path, encoding="utf-8").read()
    # The tables of statements that are only strings: an array of
    # literals, and the text of a migration file.  Both are constants
    # of the tree, and neither is built at runtime.
    arrays = set()
    for match in re.finditer(r"static const char \*const (\w+)\[\]\s*=\s*\{(.*?)\};",
                              text, re.S):
        arrays.add(match.group(1))
        rest = re.sub(r'"(?:[^"\\]|\\.)*"', "", match.group(2))
        rest = re.sub(r"/\*.*?\*/", "", rest, flags=re.S)
        if rest.strip(" \t\n\r,"):
            problems.append("%s: the array %s holds something that is not a "
                            "string" % (name, match.group(1)))
    files = set(re.findall(r"(\w+)\s*=\s*read_file\s*\(", text))
    # Every statement is a string literal: the argument of gdb_prepare
    # and of gdb_exec is a literal, a member of an array of literals, or
    # the text of a migration file.
    for match in re.finditer(r"\b(?:gdb_prepare|gdb_exec)\s*\(\s*db\s*,", text):
        rest = text[match.end():]
        if rest.lstrip().startswith('"'):
            continue
        name_match = re.match(r"\s*(\w+)", rest)
        if name_match is None:
            problems.append("%s: the SQL is not a literal" % name)
            continue
        word = name_match.group(1)
        if word in arrays or word in files:
            continue
        problems.append("%s: the SQL is not a literal: %s" % (name, word))
    # No SQL is built with a function that writes into a string.
    for number, line in enumerate(text.splitlines(), 1):
        if sql_words.search(line) and any(one in line for one in builders):
            problems.append("%s:%d: SQL is built at runtime" % (name, number))
assert not problems, problems
EOF
then ok "(g) no SQL is built at runtime: every statement is a constant"
else bad "(g) SQL is built at runtime, or a statement is not a constant"; fi

# (h) the core of the library holds no header of an operating system.
if python3 - "$DBDIR" <<'EOF'
import os
import re
import sys

dbdir = sys.argv[1]
core = ["gdb_core.c", "gdb_query.c", "gdb_json.c", "gdb_sha256.c",
        "gdb_platform.c", "gdb.h", "gdb_internal.h"]
headers = re.compile(r"#include\s+<(sys/|machine/|dev/|net/|netinet/|"
                     r"osreldate\.h|sysctl\.h|kldstat\.h|kenv\.h|pciconf\.h)")
calls = re.compile(r"\b(sysctl|kenv|kldstat|pciconf|getpcidev|system|popen|"
                   r"fork|execve|execl)\s*\(")
problems = []
for name in core:
    path = os.path.join(dbdir, name)
    for number, line in enumerate(open(path, encoding="utf-8"), 1):
        if headers.search(line):
            problems.append("%s:%d: %s" % (name, number, line.strip()))
        if calls.search(line):
            problems.append("%s:%d: %s" % (name, number, line.strip()))
assert not problems, problems
EOF
then ok "(h) the core of the library holds no header of an operating system"
else bad "(h) the core of the library holds a header of an operating system"; fi

# (i) the library with only the fake provider builds and works.
if [ -f "$FAKELIB" ] &&
	! nm -D "$FAKELIB" 2> /dev/null | grep -q "gdb_platform_freebsd"; then
	ok "(i) the library with only the fake provider holds no provider of an operating system"
else
	bad "(i) the library with only the fake provider holds a provider of an operating system"
fi

# (j) the export of a run is the same bytes as the live document.
run_db export 1 --db "$DB" --json > "$TESTROOT/export.json" 2> "$TESTROOT/export.err"
if cmp -s "$TESTROOT/empty.json" "$TESTROOT/export.json"; then
	ok "(j) the export of a run is the same bytes as the live document"
else
	bad "(j) the export of a run is not the same bytes as the live document"
fi

# (k) the questions asked afterwards are answered.
run_db history --db "$DB" > "$TESTROOT/history.txt" 2>&1
if grep -q "^1 " "$TESTROOT/history.txt" && grep -q "arm64" "$TESTROOT/history.txt"; then
	ok "(k) the history says which runs there are"
else
	bad "(k) the history says nothing: $(head -c 200 "$TESTROOT/history.txt" | tr '\n' ' ')"
fi

run_db show 1 --db "$DB" > "$TESTROOT/show.txt" 2>&1
if grep -q "^run 1:" "$TESTROOT/show.txt" && grep -q "cards" "$TESTROOT/show.txt"; then
	ok "(k) the run is shown again"
else
	bad "(k) the run is not shown again: $(head -c 200 "$TESTROOT/show.txt" | tr '\n' ' ')"
fi

# Two runs, and the comparison of the two.
run_db --fake "$REPO/tests/data/gpu-check/providers-fake/fake.json" --json \
	--db "$DB" > "$TESTROOT/second.json" 2> "$TESTROOT/second.err"
run_db compare 1 2 --db "$DB" > "$TESTROOT/compare.txt" 2>&1
if grep -q "run 1 against run 2" "$TESTROOT/compare.txt"; then
	ok "(k) two runs are compared against each other"
else
	bad "(k) two runs are not compared: $(head -c 200 "$TESTROOT/compare.txt" | tr '\n' ' ')"
fi

run_db properties 1 --db "$DB" --changed --counters > "$TESTROOT/properties.txt" 2>&1
if grep -q "vm.stats.count" "$TESTROOT/properties.txt" &&
	grep -q "counter" "$TESTROOT/properties.txt"; then
	ok "(k) the properties of a run are asked for, and the counter is named"
else
	bad "(k) the properties of a run are not asked for: $(head -c 200 "$TESTROOT/properties.txt" | tr '\n' ' ')"
fi

# The JSON of every question holds the schema it names.
if python3 - "$REPO" "$TESTROOT" <<'EOF'
import json
import os
import subprocess
import sys

repo, root = sys.argv[1], sys.argv[2]
db = os.path.join(root, "empty.db")
env = dict(os.environ)
for name, args, out in (("history", ["history"], "q-history.json"),
                         ("compare", ["compare", "1", "2"], "q-compare.json"),
                         ("properties", ["properties", "1"], "q-properties.json")):
    path = os.path.join(root, out)
    with open(path, "w", encoding="utf-8") as handle:
        subprocess.check_call([sys.executable,
                                os.path.join(repo, "scripts", "gpu-check")] +
                               args + ["--db", db, "--json"], stdout=handle,
                               env=env)
    document = json.load(open(path, encoding="utf-8"))
    assert document["schema"] == "gpu-check-%s.v1" % name, document["schema"]
EOF
then ok "(k) every question says which schema it answers"
else bad "(k) a question does not say which schema it answers"; fi

# (l) the class of a property belongs to the run and not to the key.
run_db properties 1 --db "$DB" --changed --counters > "$TESTROOT/p1.txt" 2>&1
run_db properties 2 --db "$DB" --changed --counters > "$TESTROOT/p2.txt" 2>&1
if grep -q "counter" "$TESTROOT/p1.txt" && grep -q "counter" "$TESTROOT/p2.txt"; then
	ok "(l) the class of a property is the class of the run"
else
	bad "(l) the class of a property is not the class of the run"
fi

# The value history of a property is the history of the run.
_run2_values=$(sqlite3 "$DB" "SELECT count(*) FROM property_values WHERE run_id = 2 AND property_id = (SELECT id FROM properties WHERE key_id = (SELECT id FROM property_keys WHERE key = 'vm.stats.count'));")
if [ "${_run2_values:-0}" -ge 1 ]; then
	ok "(l) the values of a property in the second run are the values of that run"
else
	bad "(l) the values of a property in the second run are not there"
fi

# (m) the events are the source of truth: the replay builds the tables
# again and they are the same.
if python3 - "$REPO" "$DB" <<'EOF'
import json
import os
import sys

repo, path = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(repo, "lib", "gpu-check"))
from gpu_check import db

database = db.Database(path, platform="fake")
before = database.export(1)
counts_before = database.history(100)["runs"][0]["events"]
database.replay()
after = database.export(1)
counts_after = database.history(100)["runs"][0]["events"]
database.close()
assert before == after, "the document changed after the replay"
assert counts_before == counts_after, (counts_before, counts_after)
EOF
then ok "(m) the replay builds the tables again, and they are the same"
else bad "(m) the replay does not build the same tables"; fi

# (n) the schema is in the third normal form: no list in a column, no
# document in a column, every reference declared.
if python3 - "$SCHEMA" <<'EOF'
import glob
import os
import re
import sys

schema = sys.argv[1]
forbidden = {"depends_on", "providers", "features", "warnings", "loaded",
             "steps", "values", "payload", "json", "data", "items", "list",
             "csv", "tags"}
problems = []
references = 0
for path in sorted(glob.glob(os.path.join(schema, "gpu-check-db-*.sql"))):
    text = open(path, encoding="utf-8").read()
    references += len(re.findall(r"\bREFERENCES\b", text))
    for number, line in enumerate(text.splitlines(), 1):
        match = re.match(r"\s{4}([a-z_][a-z0-9_]*)\s+[A-Z]", line)
        if match and match.group(1) in forbidden:
            problems.append("%s:%d: %s" % (os.path.basename(path), number,
                                           line.strip()))
        if re.search(r"\bJSON\b", line):
            problems.append("%s:%d: %s" % (os.path.basename(path), number,
                                           line.strip()))
assert references >= 20, "the schema declares %d references" % references
assert not problems, problems
EOF
then ok "(n) the schema is in the third normal form: no list in a column, no document in a column"
else bad "(n) the schema is not in the third normal form"; fi

# The foreign keys are enforced.
if grep -q "PRAGMA foreign_keys = ON" "$DBDIR/gdb_core.c"; then
	ok "(n) the library turns the foreign keys on"
else
	bad "(n) the library does not turn the foreign keys on"
fi

# (o) a record that cannot be kept stops the run: the tool fails closed.
run_db --fake "$REPO/tests/data/gpu-check/providers-fake/fake.json" --json \
	--db "/proc/gpu-check-cannot-be-made/x.db" > "$TESTROOT/closed.json" 2>&1
_closed_rc=$?
if [ "$_closed_rc" = 2 ] && grep -q "cannot be kept" "$TESTROOT/closed.json"; then
	ok "(o) a record that cannot be kept stops the run"
else
	bad "(o) a record that cannot be kept: rc $_closed_rc $(head -c 200 "$TESTROOT/closed.json" | tr '\n' ' ')"
fi

# --no-db keeps no record at all: the file of the record is never made.
NOSTATE="$TESTROOT/nostate"
mkdir -p "$NOSTATE"
( XDG_STATE_HOME="$NOSTATE"; export XDG_STATE_HOME
  run_db --fake "$REPO/tests/data/gpu-check/providers-fake/fake.json" --json \
	--no-db ) > "$TESTROOT/nodb.json" 2> "$TESTROOT/nodb.err"
_nodb_rc=$?
if [ "$_nodb_rc" = 0 ] && [ ! -f "$NOSTATE/gpu-check/gpu-check.db" ] &&
	[ -z "$(find "$NOSTATE" -type f 2> /dev/null)" ]; then
	ok "(o) --no-db keeps no record, and the run still works"
else
	bad "(o) --no-db: rc $_nodb_rc, files under the state directory: $(find "$NOSTATE" -type f 2> /dev/null | tr '\n' ' ')"
fi

# --db and --no-db cannot be given together: one names the file of the
# record, the other keeps no record.
run_db --fake "$REPO/tests/data/gpu-check/providers-fake/fake.json" --json \
	--no-db --db "$TESTROOT/both.db" > "$TESTROOT/both.json" 2> "$TESTROOT/both.err"
_both_rc=$?
if [ "$_both_rc" = 2 ] &&
	grep -q "cannot be given together" "$TESTROOT/stderr"; then
	ok "(o) --db and --no-db cannot be given together"
else
	bad "(o) --db and --no-db together: rc $_both_rc $(head -c 200 "$TESTROOT/stderr" | tr '\n' ' ')"
fi

# The default database of a person is in the state directory of that
# person, and the file is the one the tool names.
STATE="$TESTROOT/state"
mkdir -p "$STATE"
( XDG_STATE_HOME="$STATE"; export XDG_STATE_HOME
  run_db --fake "$REPO/tests/data/gpu-check/providers-fake/fake.json" \
	--json ) > "$TESTROOT/state.json" 2> "$TESTROOT/state.err"
_state_rc=$?
if [ "$_state_rc" = 0 ] && [ -f "$STATE/gpu-check/gpu-check.db" ]; then
	ok "(o) the default database of a person is in the state directory of that person"
else
	bad "(o) the default database of a person: rc $_state_rc $(head -c 200 "$TESTROOT/state.err" | tr '\n' ' ')"
fi

printf 'passed: %s failed: %s\n' "$PASSED" "$FAILED"
if [ "$FAILED" -gt 0 ]; then
	exit 1
fi
exit 0
