/* gdb_query.c - the questions a person asks afterwards.
 *
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Every answer is a JSON document.  The document of a run is the same
 * document a live run prints, so a run that is read back and a run that
 * just happened can be compared.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "gdb_internal.h"

/* The schema of the document of a run.  The same words the tool uses
 * when it prints one. */
#define GDB_RUN_SCHEMA		"gpu-check.v1"
#define GDB_RUN_SCHEMA_VERSION	"1.1"
#define GDB_RUN_MAJOR		1
#define GDB_RUN_MINOR		1
#define GDB_RUN_PATCH		0

/* The text of a column, or the empty text when it is null. */
static const char *
col_text(sqlite3_stmt *stmt, int column)
{
	const char *text = (const char *)sqlite3_column_text(stmt, column);

	return (text ? text : "");
}

/* A string, or null when the column is null. */
static struct gdb_json *
col_string(sqlite3_stmt *stmt, int column)
{
	if (sqlite3_column_type(stmt, column) == SQLITE_NULL)
		return (gdb_json_null());
	return (gdb_json_string(col_text(stmt, column)));
}

/* A number, or null when the column is null. */
static struct gdb_json *
col_int(sqlite3_stmt *stmt, int column)
{
	if (sqlite3_column_type(stmt, column) == SQLITE_NULL)
		return (gdb_json_null());
	return (gdb_json_int((long long)sqlite3_column_int64(stmt, column)));
}

/* The head of every answer: the schema and the version of it. */
static struct gdb_json *
answer_head(const char *schema)
{
	struct gdb_json *head = gdb_json_object();
	struct gdb_json *version = gdb_json_object();

	if (head == NULL || version == NULL) {
		gdb_json_free(head);
		gdb_json_free(version);
		return (NULL);
	}
	gdb_json_put(version, "string", gdb_json_string(GDB_RUN_SCHEMA_VERSION));
	gdb_json_put(version, "major", gdb_json_int(GDB_RUN_MAJOR));
	gdb_json_put(version, "minor", gdb_json_int(GDB_RUN_MINOR));
	gdb_json_put(version, "patch", gdb_json_int(GDB_RUN_PATCH));
	gdb_json_put(head, "schema_version", version);
	gdb_json_put(head, "tool", gdb_json_string("gpu-check"));
	gdb_json_put(head, "schema", gdb_json_string(schema));
	return (head);
}

/* --- the lists of a card -------------------------------------------------- */

/* The statements of the lists of a card.  They are constants: a
 * statement is never built at runtime. */
enum gdb_list_query {
	GDB_Q_FEATURES,
	GDB_Q_ARCH_VALUES,
	GDB_Q_WARNINGS,
	GDB_Q_LOADED,
	GDB_Q_STEPS
};

static const char *const list_queries[] = {
	"SELECT feature_index, name, available, reason, value"
	" FROM device_features WHERE device_id = ? ORDER BY ordinal",
	"SELECT value FROM device_arch_values WHERE device_id = ?"
	" ORDER BY ordinal",
	"SELECT warning FROM device_warnings WHERE device_id = ?"
	" ORDER BY ordinal",
	"SELECT module FROM device_loaded WHERE device_id = ?"
	" ORDER BY ordinal",
	"SELECT name, status, detail FROM check_steps WHERE check_row_id = ?"
	" ORDER BY ordinal"
};

/* The statement of a list of a card: the statement is a constant, and
 * the card is its only argument. */
static sqlite3_stmt *
list_stmt(struct gdb *db, enum gdb_list_query which, long long arg)
{
	sqlite3_stmt *stmt;

	stmt = gdb_prepare(db, list_queries[which]);
	if (stmt == NULL)
		return (NULL);
	sqlite3_bind_int64(stmt, 1, arg);
	return (stmt);
}

/* How a field of a row is read. */
enum gdb_field_kind {
	GDB_FIELD_TEXT,		/* the text of the column */
	GDB_FIELD_INT,		/* the number of the column */
	GDB_FIELD_BOOL,		/* the number of the column, as true or false */
	GDB_FIELD_TEXT_IF	/* the text of the column, but only when it
				 * is there: the document of a live run leaves
				 * the key out when it is not */
};

/* One field of a row: its name and how its column is read. */
struct gdb_field {
	const char *name;
	enum gdb_field_kind kind;
};

/* The fields of a row of features. */
static const struct gdb_field feature_fields[] = {
	{ "index", GDB_FIELD_INT },
	{ "name", GDB_FIELD_TEXT },
	{ "available", GDB_FIELD_BOOL },
	{ "reason", GDB_FIELD_TEXT_IF },
	{ "value", GDB_FIELD_TEXT_IF },
	{ NULL, GDB_FIELD_TEXT }
};

/* The fields of a row of steps. */
static const struct gdb_field step_fields[] = {
	{ "name", GDB_FIELD_TEXT },
	{ "status", GDB_FIELD_TEXT },
	{ "detail", GDB_FIELD_TEXT_IF },
	{ NULL, GDB_FIELD_TEXT }
};

/* A row of a list: the fields are read one by one, as the table of
 * the fields says.  Every kind of row says what it holds in that
 * table, and not in a copy of the reading of the columns. */
static struct gdb_json *
fields_row(sqlite3_stmt *stmt, void *arg)
{
	const struct gdb_field *fields = arg;
	struct gdb_json *row = gdb_json_object();
	size_t i;

	if (row == NULL)
		return (NULL);
	for (i = 0; fields[i].name != NULL; i++) {
		struct gdb_json *value;
		int column = (int)i;

		switch (fields[i].kind) {
		case GDB_FIELD_INT:
			value = gdb_json_int((long long)
			    sqlite3_column_int64(stmt, column));
			break;
		case GDB_FIELD_BOOL:
			value = gdb_json_bool(sqlite3_column_int(stmt, column));
			break;
		case GDB_FIELD_TEXT_IF:
			if (sqlite3_column_type(stmt, column) == SQLITE_NULL)
				continue;
			value = gdb_json_string(col_text(stmt, column));
			break;
		default:
			value = gdb_json_string(col_text(stmt, column));
			break;
		}
		if (gdb_json_put(row, fields[i].name, value) != 0)
			break;
	}
	return (row);
}

/* The values of one column, in the order of the statement.  The kind says
 * whether a value is a number or text. */
static struct gdb_json *
column_values(struct gdb *db, sqlite3_stmt *stmt, int as_number)
{
	struct gdb_json *array = gdb_json_array();

	if (array == NULL) {
		gdb_stmt_done(db, stmt);
		return (NULL);
	}
	while (sqlite3_step(stmt) == SQLITE_ROW) {
		struct gdb_json *value = as_number ?
		    gdb_json_int((long long)sqlite3_column_int64(stmt, 0)) :
		    gdb_json_string(col_text(stmt, 0));

		gdb_json_put(array, NULL, value);
	}
	gdb_stmt_done(db, stmt);
	return (array);
}

/* A row of a list: the caller says what a row holds. */
typedef struct gdb_json *(*gdb_row_fn)(sqlite3_stmt *stmt, void *arg);

/* A list of rows: every row of the statement is an object of the
 * document.  The statement is stepped here; the row is built by the
 * caller, so every kind of row says what it holds. */
static struct gdb_json *
row_list(struct gdb *db, sqlite3_stmt *stmt, gdb_row_fn build, void *arg)
{
	struct gdb_json *array = gdb_json_array();

	if (array == NULL) {
		gdb_stmt_done(db, stmt);
		return (NULL);
	}
	while (sqlite3_step(stmt) == SQLITE_ROW) {
		struct gdb_json *row = build(stmt, arg);

		if (row == NULL)
			break;
		gdb_json_put(array, NULL, row);
	}
	gdb_stmt_done(db, stmt);
	return (array);
}

/* The features of a card: a list is a table, and a feature is a row of
 * its own. */
static struct gdb_json *
features_of(struct gdb *db, long long device_id)
{
	sqlite3_stmt *stmt;

	stmt = list_stmt(db, GDB_Q_FEATURES, device_id);
	if (stmt == NULL)
		return (NULL);
	return (row_list(db, stmt, fields_row, (void *)feature_fields));
}

/* The architectures of the family of a card: a list is a table. */
static struct gdb_json *
arch_values_of(struct gdb *db, long long device_id)
{
	sqlite3_stmt *stmt;

	stmt = list_stmt(db, GDB_Q_ARCH_VALUES, device_id);
	if (stmt == NULL)
		return (NULL);
	return (column_values(db, stmt, 1));
}

/* The warnings of a decision: a list is a table. */
static struct gdb_json *
warnings_of(struct gdb *db, long long device_id)
{
	sqlite3_stmt *stmt;

	stmt = list_stmt(db, GDB_Q_WARNINGS, device_id);
	if (stmt == NULL)
		return (NULL);
	return (column_values(db, stmt, 0));
}

/* The modules a card loaded: a list is a table. */
static struct gdb_json *
loaded_of(struct gdb *db, long long device_id)
{
	sqlite3_stmt *stmt;

	stmt = list_stmt(db, GDB_Q_LOADED, device_id);
	if (stmt == NULL)
		return (NULL);
	return (column_values(db, stmt, 0));
}

/* The steps of a check: a list is a table. */
static struct gdb_json *
steps_of(struct gdb *db, long long check_row_id)
{
	sqlite3_stmt *stmt;

	stmt = list_stmt(db, GDB_Q_STEPS, check_row_id);
	if (stmt == NULL)
		return (NULL);
	return (row_list(db, stmt, fields_row, (void *)step_fields));
}

/* The rows of the checks of a card. */
static struct gdb_json *
checks_of(struct gdb *db, long long run_id, long long device_id)
{
	struct gdb_json *array = gdb_json_array();
	sqlite3_stmt *stmt;

	if (array == NULL)
		return (NULL);
	stmt = gdb_prepare(db,
	    "SELECT c.id, c.ordinal, k.name, d.title, s.name, c.reason,"
	    " c.rm_index, c.uuid_sha256"
	    " FROM run_checks c"
	    " JOIN check_defs d ON d.id = c.def_id"
	    " JOIN check_ids k ON k.id = d.check_id"
	    " JOIN result_kinds s ON s.id = c.status_id"
	    " WHERE c.run_id = ? AND c.device_id = ? ORDER BY c.ordinal");
	if (stmt == NULL) {
		gdb_json_free(array);
		return (NULL);
	}
	sqlite3_bind_int64(stmt, 1, run_id);
	sqlite3_bind_int64(stmt, 2, device_id);
	while (sqlite3_step(stmt) == SQLITE_ROW) {
		struct gdb_json *row = gdb_json_object();
		struct gdb_json *steps;

		if (row == NULL)
			break;
		gdb_json_put(row, "index", gdb_json_int(sqlite3_column_int64(stmt, 1)));
		gdb_json_put(row, "name", gdb_json_string(col_text(stmt, 2)));
		gdb_json_put(row, "title", gdb_json_string(col_text(stmt, 3)));
		gdb_json_put(row, "status", gdb_json_string(col_text(stmt, 4)));
		gdb_json_put(row, "reason", gdb_json_string(col_text(stmt, 5)));
		/* A row that has no steps says so by not having the key:
		 * the document of a live run does the same. */
		steps = steps_of(db, sqlite3_column_int64(stmt, 0));
		if (gdb_json_count(steps) > 0)
			gdb_json_put(row, "steps", steps);
		else
			gdb_json_free(steps);
		if (sqlite3_column_type(stmt, 6) != SQLITE_NULL)
			gdb_json_put(row, "rm_index",
			    gdb_json_int((long long)sqlite3_column_int64(stmt, 6)));
		if (sqlite3_column_type(stmt, 7) != SQLITE_NULL)
			gdb_json_put(row, "uuid_sha256",
			    gdb_json_string(col_text(stmt, 7)));
		gdb_json_put(array, NULL, row);
	}
	gdb_stmt_done(db, stmt);
	return (array);
}

/* The cards of a run. */
static struct gdb_json *
devices_of(struct gdb *db, long long run_id)
{
	struct gdb_json *array = gdb_json_array();
	sqlite3_stmt *stmt;

	if (array == NULL)
		return (NULL);
	stmt = gdb_prepare(db,
	    "SELECT id, label, selector, name, vendor, device, subvendor,"
	    " subdevice, class, revision, generation_name, generation_source,"
	    " board_name, board_reason, uuid_sha256, decision_code,"
	    " decision_reason_code, decision_provider, decision_family,"
	    " decision_backend, decision_instance, decision_reason,"
	    " decision_next, english"
	    " FROM devices WHERE run_id = ? ORDER BY ordinal");
	if (stmt == NULL) {
		gdb_json_free(array);
		return (NULL);
	}
	sqlite3_bind_int64(stmt, 1, run_id);
	while (sqlite3_step(stmt) == SQLITE_ROW) {
		long long device_id = (long long)sqlite3_column_int64(stmt, 0);
		struct gdb_json *entry = gdb_json_object();
		struct gdb_json *identity = gdb_json_object();
		struct gdb_json *generation = gdb_json_object();
		struct gdb_json *board = gdb_json_object();
		struct gdb_json *decision = gdb_json_object();

		if (entry == NULL || identity == NULL || generation == NULL ||
		    board == NULL || decision == NULL) {
			gdb_json_free(entry);
			gdb_json_free(identity);
			gdb_json_free(generation);
			gdb_json_free(board);
			gdb_json_free(decision);
			break;
		}
		gdb_json_put(entry, "label", gdb_json_string(col_text(stmt, 1)));
		gdb_json_put(entry, "selector", gdb_json_string(col_text(stmt, 2)));
		gdb_json_put(entry, "name", gdb_json_string(col_text(stmt, 3)));
		gdb_json_put(identity, "vendor", gdb_json_string(col_text(stmt, 4)));
		gdb_json_put(identity, "device", gdb_json_string(col_text(stmt, 5)));
		gdb_json_put(identity, "subvendor", gdb_json_string(col_text(stmt, 6)));
		gdb_json_put(identity, "subdevice", gdb_json_string(col_text(stmt, 7)));
		gdb_json_put(identity, "class", gdb_json_string(col_text(stmt, 8)));
		gdb_json_put(identity, "revision", gdb_json_string(col_text(stmt, 9)));
		gdb_json_put(entry, "identity", identity);
		gdb_json_put(generation, "name", col_string(stmt, 10));
		gdb_json_put(generation, "arch_values",
		    arch_values_of(db, device_id));
		gdb_json_put(generation, "source", col_string(stmt, 11));
		gdb_json_put(entry, "generation", generation);
		gdb_json_put(board, "name", col_string(stmt, 12));
		gdb_json_put(board, "reason", col_string(stmt, 13));
		gdb_json_put(entry, "board", board);
		gdb_json_put(decision, "code", gdb_json_string(col_text(stmt, 15)));
		gdb_json_put(decision, "reason_code",
		    col_string(stmt, 16));
		gdb_json_put(decision, "provider", col_string(stmt, 17));
		gdb_json_put(decision, "family", col_string(stmt, 18));
		gdb_json_put(decision, "backend", col_string(stmt, 19));
		gdb_json_put(decision, "instance", col_string(stmt, 20));
		gdb_json_put(decision, "reason", gdb_json_string(col_text(stmt, 21)));
		gdb_json_put(decision, "next", col_string(stmt, 22));
		gdb_json_put(decision, "warnings",
		    warnings_of(db, device_id));
		gdb_json_put(entry, "decision", decision);
		gdb_json_put(entry, "features",
		    features_of(db, device_id));
		gdb_json_put(entry, "english", gdb_json_string(col_text(stmt, 23)));
		gdb_json_put(entry, "loaded",
		    loaded_of(db, device_id));
		gdb_json_put(entry, "checks", checks_of(db, run_id, device_id));
		if (sqlite3_column_type(stmt, 14) != SQLITE_NULL)
			gdb_json_put(entry, "uuid_sha256",
			    gdb_json_string(col_text(stmt, 14)));
		gdb_json_put(array, NULL, entry);
	}
	gdb_stmt_done(db, stmt);
	return (array);
}
/* The counts of the checks of a run, by the result they had. */
static struct gdb_json *
check_counts(struct gdb *db, long long run_id)
{
	static const char *kinds[] = {"pass", "fail", "not_tested", "not_available"};
	struct gdb_json *counts = gdb_json_object();
	int i;

	if (counts == NULL)
		return (NULL);
	for (i = 0; i < 4; i++) {
		sqlite3_stmt *stmt;
		long long count = 0;

		stmt = gdb_prepare(db,
		    "SELECT COUNT(*) FROM run_checks c"
		    " JOIN result_kinds k ON k.id = c.status_id"
		    " WHERE c.run_id = ? AND k.name = ?");
		if (stmt == NULL)
			break;
		sqlite3_bind_int64(stmt, 1, run_id);
		sqlite3_bind_text(stmt, 2, kinds[i], -1, SQLITE_STATIC);
		if (sqlite3_step(stmt) == SQLITE_ROW)
			count = (long long)sqlite3_column_int64(stmt, 0);
		gdb_stmt_done(db, stmt);
		gdb_json_put(counts, kinds[i], gdb_json_int(count));
	}
	return (counts);
}

/* The number of the cards of a run that got a decision. */
static long long
decision_count(struct gdb *db, long long run_id, const char *code)
{
	sqlite3_stmt *stmt;
	long long count = 0;

	stmt = gdb_prepare(db,
	    "SELECT COUNT(*) FROM devices WHERE run_id = ? AND decision_code = ?");
	if (stmt == NULL)
		return (0);
	sqlite3_bind_int64(stmt, 1, run_id);
	sqlite3_bind_text(stmt, 2, code, -1, SQLITE_STATIC);
	if (sqlite3_step(stmt) == SQLITE_ROW)
		count = (long long)sqlite3_column_int64(stmt, 0);
	gdb_stmt_done(db, stmt);
	return (count);
}

/* The providers of the registry, as the run_start event holds them. */
static struct gdb_json *
providers_of(struct gdb *db, long long run_id)
{
	struct gdb_json *array = gdb_json_array();
	sqlite3_stmt *stmt;

	if (array == NULL)
		return (NULL);
	stmt = gdb_prepare(db,
	    "SELECT d.data_text FROM event_data d"
	    " JOIN events e ON e.id = d.event_id"
	    " JOIN event_kinds k ON k.id = e.kind_id"
	    " WHERE e.run_id = ? AND k.name = 'run_start'"
	    " AND d.data_key LIKE 'providers.%' ORDER BY d.data_key");
	if (stmt == NULL) {
		gdb_json_free(array);
		return (NULL);
	}
	sqlite3_bind_int64(stmt, 1, run_id);
	while (sqlite3_step(stmt) == SQLITE_ROW)
		gdb_json_put(array, NULL, gdb_json_string(col_text(stmt, 0)));
	gdb_stmt_done(db, stmt);
	return (array);
}

/* --- the document of a run ------------------------------------------------ */

/* The document of a run: the same document a live run prints. */
static char *
build_run_document(struct gdb *db, long long run_id)
{
	struct gdb_json *doc = answer_head(GDB_RUN_SCHEMA);
	struct gdb_json *host = gdb_json_object();
	struct gdb_json *release = gdb_json_object();
	struct gdb_json *registry = gdb_json_object();
	struct gdb_json *summary = gdb_json_object();
	sqlite3_stmt *stmt;

	if (doc == NULL || host == NULL || release == NULL || registry == NULL ||
	    summary == NULL) {
		gdb_json_free(doc);
		gdb_json_free(host);
		gdb_json_free(release);
		gdb_json_free(registry);
		gdb_json_free(summary);
		return (NULL);
	}
	stmt = gdb_prepare(db,
	    "SELECT r.started_at, r.ended_at, r.finished, r.mode, r.arch,"
	    " r.exit_code, r.fake, r.capture, r.host_hash, p.name,"
	    " r.os_name, v.version, v.major, v.minor, v.patch, v.suffix"
	    " FROM runs r JOIN platforms p ON p.id = r.platform_id"
	    " LEFT JOIN versions v ON v.id = r.os_version_id"
	    " WHERE r.id = ?");
	if (stmt == NULL) {
		gdb_json_free(doc);
		gdb_json_free(host);
		gdb_json_free(release);
		gdb_json_free(registry);
		gdb_json_free(summary);
		return (NULL);
	}
	sqlite3_bind_int64(stmt, 1, run_id);
	if (sqlite3_step(stmt) != SQLITE_ROW) {
		gdb_set_error(db, "there is no run %lld in this database", run_id);
		gdb_stmt_done(db, stmt);
		gdb_json_free(doc);
		gdb_json_free(host);
		gdb_json_free(release);
		gdb_json_free(registry);
		gdb_json_free(summary);
		return (NULL);
	}
	gdb_json_put(host, "arch", gdb_json_string(col_text(stmt, 4)));
	/* The name of the system, and the name of the platform it came
	 * from when the run did not say. */
	if (col_text(stmt, 10)[0] != '\0')
		gdb_json_put(host, "os", gdb_json_string(col_text(stmt, 10)));
	else
		gdb_json_put(host, "os", gdb_json_string(col_text(stmt, 9)));
	gdb_json_put(release, "string", gdb_json_string(col_text(stmt, 11)));
	gdb_json_put(release, "major", gdb_json_int(sqlite3_column_int(stmt, 12)));
	gdb_json_put(release, "minor", gdb_json_int(sqlite3_column_int(stmt, 13)));
	gdb_json_put(release, "patch", gdb_json_int(sqlite3_column_int(stmt, 14)));
	/* The suffix of the release, when it has one: a live run says so
	 * the same way. */
	if (col_text(stmt, 15)[0] != '\0')
		gdb_json_put(release, "suffix", gdb_json_string(col_text(stmt, 15)));
	gdb_json_put(host, "os_release", release);
	gdb_json_put(doc, "host", host);
	gdb_json_put(doc, "mode", gdb_json_string(col_text(stmt, 3)));
	gdb_json_put(doc, "fake", gdb_json_bool(sqlite3_column_int(stmt, 6)));
	gdb_json_put(doc, "capture", gdb_json_bool(sqlite3_column_int(stmt, 7)));
	gdb_json_put(registry, "providers", providers_of(db, run_id));
	gdb_json_put(doc, "registry", registry);
	gdb_json_put(doc, "devices", devices_of(db, run_id));
	{
		sqlite3_stmt *count;

		count = gdb_prepare(db,
		    "SELECT COUNT(*) FROM devices WHERE run_id = ?");
		if (count != NULL) {
			sqlite3_bind_int64(count, 1, run_id);
			gdb_json_put(summary, "devices",
			    gdb_json_int(sqlite3_step(count) == SQLITE_ROW ?
			    (long long)sqlite3_column_int64(count, 0) : 0));
			gdb_stmt_done(db, count);
		}
	}
	gdb_json_put(summary, "supported",
	    gdb_json_int(decision_count(db, run_id, "supported")));
	gdb_json_put(summary, "refused",
	    gdb_json_int(decision_count(db, run_id, "refused")));
	gdb_json_put(summary, "no_provider",
	    gdb_json_int(decision_count(db, run_id, "no_provider")));
	gdb_json_put(summary, "checks", check_counts(db, run_id));
	gdb_json_put(doc, "summary", summary);
	if (sqlite3_column_type(stmt, 5) == SQLITE_NULL)
		gdb_json_put(doc, "exit", gdb_json_null());
	else
		gdb_json_put(doc, "exit",
		    gdb_json_int((long long)sqlite3_column_int64(stmt, 5)));
	gdb_stmt_done(db, stmt);
	return (gdb_json_render(doc));
}

char *
gdb_query_show(struct gdb *db, long long run_id)
{
	if (db == NULL)
		return (NULL);
	return (build_run_document(db, run_id));
}

char *
gdb_query_export(struct gdb *db, long long run_id)
{
	return (gdb_query_show(db, run_id));
}

/* --- the history ---------------------------------------------------------- */

/* The runs, the newest first. */
char *
gdb_query_history(struct gdb *db, int last)
{
	struct gdb_json *doc = answer_head("gpu-check-history.v1");
	struct gdb_json *runs = gdb_json_array();
	sqlite3_stmt *stmt;

	if (doc == NULL || runs == NULL) {
		gdb_json_free(doc);
		gdb_json_free(runs);
		return (NULL);
	}
	stmt = gdb_prepare(db,
	    "SELECT r.id, r.started_at, r.ended_at, r.finished, r.mode, r.arch,"
	    " r.exit_code, r.host_hash, p.name,"
	    " (SELECT COUNT(*) FROM devices d WHERE d.run_id = r.id),"
	    " (SELECT COUNT(*) FROM events e WHERE e.run_id = r.id),"
	    " (SELECT COUNT(*) FROM run_checks c WHERE c.run_id = r.id)"
	    " FROM runs r JOIN platforms p ON p.id = r.platform_id"
	    " ORDER BY r.id DESC LIMIT ?");
	if (stmt == NULL) {
		gdb_json_free(doc);
		gdb_json_free(runs);
		return (NULL);
	}
	sqlite3_bind_int(stmt, 1, last > 0 ? last : 20);
	while (sqlite3_step(stmt) == SQLITE_ROW) {
		long long id = (long long)sqlite3_column_int64(stmt, 0);
		struct gdb_json *row = gdb_json_object();

		if (row == NULL)
			break;
		gdb_json_put(row, "id", gdb_json_int(id));
		gdb_json_put(row, "started_at", gdb_json_string(col_text(stmt, 1)));
		gdb_json_put(row, "ended_at", col_string(stmt, 2));
		gdb_json_put(row, "finished",
		    gdb_json_bool(sqlite3_column_int(stmt, 3)));
		gdb_json_put(row, "mode", gdb_json_string(col_text(stmt, 4)));
		gdb_json_put(row, "arch", gdb_json_string(col_text(stmt, 5)));
		gdb_json_put(row, "exit_code", col_int(stmt, 6));
		gdb_json_put(row, "platform", gdb_json_string(col_text(stmt, 8)));
		gdb_json_put(row, "host_hash", gdb_json_string(col_text(stmt, 7)));
		gdb_json_put(row, "devices",
		    gdb_json_int((long long)sqlite3_column_int64(stmt, 9)));
		gdb_json_put(row, "events",
		    gdb_json_int((long long)sqlite3_column_int64(stmt, 10)));
		gdb_json_put(row, "checks",
		    gdb_json_int((long long)sqlite3_column_int64(stmt, 11)));
		gdb_json_put(row, "check_results", check_counts(db, id));
		gdb_json_put(runs, NULL, row);
	}
	gdb_stmt_done(db, stmt);
	gdb_json_put(doc, "runs", runs);
	return (gdb_json_render(doc));
}

/* --- the properties ------------------------------------------------------- */

/* The values a property had in a run, and how many there were. */
static struct gdb_json *
values_of(struct gdb *db, long long property_id, long long run_id,
    int *distinct)
{
	struct gdb_json *array = gdb_json_array();
	sqlite3_stmt *stmt;
	char last[1024];
	int count = 0;

	*distinct = 0;
	last[0] = '\0';
	if (array == NULL)
		return (NULL);
	stmt = gdb_prepare(db,
	    "SELECT COALESCE(CAST(value_int AS TEXT),"
	    " CAST(value_num AS TEXT), value_text) FROM property_values"
	    " WHERE property_id = ? AND run_id = ? ORDER BY id");
	if (stmt == NULL) {
		gdb_json_free(array);
		return (NULL);
	}
	sqlite3_bind_int64(stmt, 1, property_id);
	sqlite3_bind_int64(stmt, 2, run_id);
	while (sqlite3_step(stmt) == SQLITE_ROW) {
		const char *value = col_text(stmt, 0);

		if (count > 0 && strcmp(value, last) == 0)
			continue;
		gdb_json_put(array, NULL, gdb_json_string(value));
		snprintf(last, sizeof(last), "%s", value);
		count++;
	}
	gdb_stmt_done(db, stmt);
	*distinct = count;
	return (array);
}

/* The properties of a run: the ones that changed, and the ones that did
 * not.  A counter is left out unless it is asked for. */
char *
gdb_query_properties(struct gdb *db, long long run_id, int changed, int counters)
{
	struct gdb_json *doc = answer_head("gpu-check-properties.v1");
	struct gdb_json *array = gdb_json_array();
	sqlite3_stmt *stmt;

	if (doc == NULL || array == NULL) {
		gdb_json_free(doc);
		gdb_json_free(array);
		return (NULL);
	}
	gdb_json_put(doc, "run", gdb_json_int(run_id));
	stmt = gdb_prepare(db,
	    "SELECT p.id, s.name, k.key, p.kind,"
	    " COALESCE(c.classification, 'constant')"
	    " FROM properties p"
	    " JOIN property_keys k ON k.id = p.key_id"
	    " JOIN sources s ON s.id = k.source_id"
	    " LEFT JOIN property_classes c ON c.property_id = p.id"
	    " AND c.run_id = ?"
	    " WHERE EXISTS (SELECT 1 FROM property_values v"
	    " WHERE v.property_id = p.id AND v.run_id = ?)"
	    " ORDER BY s.name, k.key");
	if (stmt == NULL) {
		gdb_json_free(doc);
		gdb_json_free(array);
		return (NULL);
	}
	sqlite3_bind_int64(stmt, 1, run_id);
	sqlite3_bind_int64(stmt, 2, run_id);
	while (sqlite3_step(stmt) == SQLITE_ROW) {
		long long property_id = (long long)sqlite3_column_int64(stmt, 0);
		const char *classification = col_text(stmt, 4);
		struct gdb_json *entry;
		struct gdb_json *values;
		int distinct = 0;

		if (!counters && strcmp(classification, "counter") == 0)
			continue;
		values = values_of(db, property_id, run_id, &distinct);
		if (changed && distinct < 2)
			continue;
		entry = gdb_json_object();
		if (entry == NULL)
			break;
		gdb_json_put(entry, "source", gdb_json_string(col_text(stmt, 1)));
		gdb_json_put(entry, "key", gdb_json_string(col_text(stmt, 2)));
		gdb_json_put(entry, "kind", gdb_json_string(col_text(stmt, 3)));
		gdb_json_put(entry, "classification",
		    gdb_json_string(classification));
		gdb_json_put(entry, "changed", gdb_json_bool(distinct > 1));
		gdb_json_put(entry, "values", values);
		gdb_json_put(array, NULL, entry);
	}
	gdb_stmt_done(db, stmt);
	gdb_json_put(doc, "properties", array);
	return (gdb_json_render(doc));
}

/* --- the comparison ------------------------------------------------------- */

/* The value every property had at the end of a run. */
struct gdb_map_entry {
	char			*source;
	char			*key;
	char			*value;
	struct gdb_map_entry	*next;
};

struct gdb_map {
	struct gdb_map_entry	*head;
};

static void
map_put(struct gdb_map *map, const char *source, const char *key,
    const char *value)
{
	struct gdb_map_entry *entry;

	for (entry = map->head; entry != NULL; entry = entry->next) {
		if (strcmp(entry->source, source) == 0 &&
		    strcmp(entry->key, key) == 0) {
			free(entry->value);
			entry->value = strdup(value);
			return;
		}
	}
	entry = calloc(1, sizeof(*entry));
	if (entry == NULL)
		return;
	entry->source = strdup(source);
	entry->key = strdup(key);
	entry->value = strdup(value);
	entry->next = map->head;
	map->head = entry;
}

/* The value of a property, by its source and its key. */
static const char *
map_lookup(struct gdb_map *map, const char *source, const char *key)
{
	struct gdb_map_entry *entry;

	for (entry = map->head; entry != NULL; entry = entry->next) {
		if (strcmp(entry->source, source) == 0 &&
		    strcmp(entry->key, key) == 0)
			return (entry->value);
	}
	return (NULL);
}

static void
map_free(struct gdb_map *map)
{
	struct gdb_map_entry *entry;

	if (map == NULL)
		return;
	entry = map->head;
	while (entry != NULL) {
		struct gdb_map_entry *next = entry->next;

		free(entry->source);
		free(entry->key);
		free(entry->value);
		free(entry);
		entry = next;
	}
	free(map);
}

static struct gdb_map *
property_map(struct gdb *db, long long run_id)
{
	struct gdb_map *map;
	sqlite3_stmt *stmt;

	map = calloc(1, sizeof(*map));
	if (map == NULL)
		return (NULL);
	stmt = gdb_prepare(db,
	    "SELECT s.name, k.key,"
	    " COALESCE(CAST(v.value_int AS TEXT), CAST(v.value_num AS TEXT),"
	    " v.value_text)"
	    " FROM property_values v"
	    " JOIN properties p ON p.id = v.property_id"
	    " JOIN property_keys k ON k.id = p.key_id"
	    " JOIN sources s ON s.id = k.source_id"
	    " WHERE v.run_id = ? ORDER BY v.id");
	if (stmt == NULL) {
		free(map);
		return (NULL);
	}
	sqlite3_bind_int64(stmt, 1, run_id);
	while (sqlite3_step(stmt) == SQLITE_ROW)
		map_put(map, col_text(stmt, 0), col_text(stmt, 1), col_text(stmt, 2));
	gdb_stmt_done(db, stmt);
	return (map);
}

/* The text of a column, or nothing when the column is null. */
static const char *
col_text_or_null(sqlite3_stmt *stmt, int column)
{
	if (sqlite3_column_type(stmt, column) == SQLITE_NULL)
		return (NULL);
	return (col_text(stmt, column));
}

/* Do the two texts differ?  Two texts that are not there are the same. */
static int
text_differs(const char *a, const char *b)
{
	if (a == NULL || b == NULL)
		return (a != b);
	return (strcmp(a, b) != 0);
}

/* The text of a value in the document, or null. */
static struct gdb_json *
json_text_or_null(const char *text)
{
	return (text == NULL ? gdb_json_null() : gdb_json_string(text));
}

/* The checks that ended differently in the two runs. */
static long long
compare_checks(struct gdb *db, struct gdb_json *checks, long long first,
    long long second)
{
	sqlite3_stmt *stmt;
	long long changed = 0;

	stmt = gdb_prepare(db,
	    "SELECT k.name, MAX(CASE WHEN c.run_id = ?1 THEN s.name END),"
	    " MAX(CASE WHEN c.run_id = ?2 THEN s.name END)"
	    " FROM run_checks c"
	    " JOIN check_defs d ON d.id = c.def_id"
	    " JOIN check_ids k ON k.id = d.check_id"
	    " JOIN result_kinds s ON s.id = c.status_id"
	    " WHERE c.run_id IN (?1, ?2) GROUP BY k.name ORDER BY k.name");
	if (stmt == NULL)
		return (0);
	sqlite3_bind_int64(stmt, 1, first);
	sqlite3_bind_int64(stmt, 2, second);
	while (sqlite3_step(stmt) == SQLITE_ROW) {
		const char *a = col_text_or_null(stmt, 1);
		const char *b = col_text_or_null(stmt, 2);
		struct gdb_json *row;

		if (!text_differs(a, b))
			continue;
		changed++;
		row = gdb_json_object();
		if (row == NULL)
			break;
		gdb_json_put(row, "name", gdb_json_string(col_text(stmt, 0)));
		gdb_json_put(row, "first", col_string(stmt, 1));
		gdb_json_put(row, "second", col_string(stmt, 2));
		gdb_json_put(row, "changed", gdb_json_bool(1));
		gdb_json_put(checks, NULL, row);
	}
	gdb_stmt_done(db, stmt);
	return (changed);
}

/* The properties that are not the same in the two runs. */
static long long
compare_properties(struct gdb *db, struct gdb_json *properties, long long first,
    long long second)
{
	struct gdb_map *a = property_map(db, first);
	struct gdb_map *b = property_map(db, second);
	struct gdb_map_entry *entry;
	long long changed = 0;

	if (a != NULL && b != NULL) {
		for (entry = b->head; entry != NULL; entry = entry->next) {
			const char *left = map_lookup(a, entry->source,
			    entry->key);
			const char *right = entry->value;
			struct gdb_json *row;

			if (left != NULL && strcmp(left, right) == 0)
				continue;
			changed++;
			row = gdb_json_object();
			if (row == NULL)
				break;
			gdb_json_put(row, "source",
			    gdb_json_string(entry->source));
			gdb_json_put(row, "key",
			    gdb_json_string(entry->key));
			gdb_json_put(row, "first", json_text_or_null(left));
			gdb_json_put(row, "second", gdb_json_string(right));
			gdb_json_put(properties, NULL, row);
		}
	}
	map_free(a);
	map_free(b);
	return (changed);
}

/* Two runs, side by side. */
char *
gdb_query_compare(struct gdb *db, long long first, long long second)
{
	struct gdb_json *doc = answer_head("gpu-check-compare.v1");
	struct gdb_json *runs = gdb_json_object();
	struct gdb_json *checks = gdb_json_array();
	struct gdb_json *properties = gdb_json_array();
	struct gdb_json *summary = gdb_json_object();
	long long checks_changed;
	long long properties_changed;

	if (doc == NULL || runs == NULL || checks == NULL || properties == NULL ||
	    summary == NULL) {
		gdb_json_free(doc);
		gdb_json_free(runs);
		gdb_json_free(checks);
		gdb_json_free(properties);
		gdb_json_free(summary);
		return (NULL);
	}
	gdb_json_put(runs, "first", gdb_json_int(first));
	gdb_json_put(runs, "second", gdb_json_int(second));
	gdb_json_put(doc, "runs", runs);
	checks_changed = compare_checks(db, checks, first, second);
	gdb_json_put(doc, "checks", checks);
	properties_changed = compare_properties(db, properties, first, second);
	gdb_json_put(doc, "properties", properties);
	gdb_json_put(summary, "checks_changed", gdb_json_int(checks_changed));
	gdb_json_put(summary, "properties_changed",
	    gdb_json_int(properties_changed));
	gdb_json_put(doc, "summary", summary);
	return (gdb_json_render(doc));
}
