/* gdb_core.c - the database of the gpu-check tool.
 *
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The file, the migrations, the events, and the state that is derived
 * from them.
 *
 * The rule of the library: no SQL is built from a string.  Every
 * statement is a constant written here, and every value that comes from
 * outside is bound to a parameter.  A table name never appears in a
 * variable, so there is nothing to inject.
 */
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "gdb_internal.h"
#include "gdb_platform.h"

/* --- the version of this library --------------------------------------- */

#define GDB_VERSION_STRING	"1.0.0"

const char *
gdb_version(void)
{
	return (GDB_VERSION_STRING);
}

int
gdb_version_major(void)
{
	return (1);
}

int
gdb_version_minor(void)
{
	return (0);
}

int
gdb_version_patch(void)
{
	return (0);
}

/* --- errors and statements ---------------------------------------------- */

void
gdb_set_error(struct gdb *db, const char *fmt, ...)
{
	va_list ap;

	va_start(ap, fmt);
	vsnprintf(db->err, sizeof(db->err), fmt, ap);
	va_end(ap);
}

const char *
gdb_error(const struct gdb *db)
{
	if (db == NULL)
		return ("the database was not opened");
	if (db->err[0] == '\0')
		return ("no error");
	return (db->err);
}

sqlite3_stmt *
gdb_prepare(struct gdb *db, const char *sql)
{
	sqlite3_stmt *stmt;
	int i;

	for (i = 0; i < db->nstmts; i++) {
		if (db->stmts[i].sql == sql ||
		    strcmp(db->stmts[i].sql, sql) == 0) {
			sqlite3_reset(db->stmts[i].stmt);
			sqlite3_clear_bindings(db->stmts[i].stmt);
			return (db->stmts[i].stmt);
		}
	}
	if (db->nstmts >= GDB_MAX_STMTS) {
		gdb_set_error(db, "too many statements are prepared");
		return (NULL);
	}
	if (sqlite3_prepare_v2(db->db, sql, -1, &stmt, NULL) != SQLITE_OK) {
		gdb_set_error(db, "the statement cannot be prepared: %s",
		    sqlite3_errmsg(db->db));
		return (NULL);
	}
	db->stmts[db->nstmts].sql = sql;
	db->stmts[db->nstmts].stmt = stmt;
	db->nstmts++;
	return (stmt);
}

void
gdb_stmt_done(struct gdb *db, sqlite3_stmt *stmt)
{
	int i;

	(void)db;
	if (stmt == NULL)
		return;
	for (i = 0; i < db->nstmts; i++) {
		if (db->stmts[i].stmt == stmt) {
			sqlite3_reset(stmt);
			sqlite3_clear_bindings(stmt);
			return;
		}
	}
	sqlite3_finalize(stmt);
}

int
gdb_exec(struct gdb *db, const char *sql)
{
	char *message = NULL;

	if (sqlite3_exec(db->db, sql, NULL, NULL, &message) != SQLITE_OK) {
		gdb_set_error(db, "the statement failed: %s",
		    message ? message : sqlite3_errmsg(db->db));
		sqlite3_free(message);
		return (-1);
	}
	sqlite3_free(message);
	return (0);
}

/* --- small helpers ------------------------------------------------------- */

/* The text of a column, or the empty text when it is null. */
static const char *
text_of(sqlite3_stmt *stmt, int column)
{
	const char *text = (const char *)sqlite3_column_text(stmt, column);

	return (text ? text : "");
}

static void
now_utc(char out[40])
{
	struct timespec ts;
	struct tm tm;

	if (clock_gettime(CLOCK_REALTIME, &ts) != 0) {
		snprintf(out, 40, "1970-01-01T00:00:00Z");
		return;
	}
	if (gmtime_r(&ts.tv_sec, &tm) == NULL) {
		snprintf(out, 40, "1970-01-01T00:00:00Z");
		return;
	}
	snprintf(out, 40, "%04d-%02d-%02dT%02d:%02d:%02d.%03ldZ",
	    tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday, tm.tm_hour,
	    tm.tm_min, tm.tm_sec, ts.tv_nsec / 1000000L);
}

/* The parts of a version.  A version that is not three numbers is zero
 * in every part, and the string is kept as it was given. */
static void
parse_version(const char *text, int *major, int *minor, int *patch)
{
	const char *p = text;

	*major = 0;
	*minor = 0;
	*patch = 0;
	if (text == NULL)
		return;
	while (*p != '\0' && !isdigit((unsigned char)*p))
		p++;
	*major = (int)strtol(p, (char **)&p, 10);
	if (*p == '.')
		p++;
	*minor = (int)strtol(p, (char **)&p, 10);
	if (*p == '.')
		p++;
	*patch = (int)strtol(p, (char **)&p, 10);
}

/* The id of a row of a lookup table, adding the row when it is not
 * there.  The two statements are prepared by the caller, where each one
 * is a constant of this file: no SQL is ever built from a string, and
 * only the name is bound. */
static long long
lookup_keep(struct gdb *db, sqlite3_stmt *insert, sqlite3_stmt *select,
    const char *name)
{
	long long id = 0;

	if (name == NULL || insert == NULL || select == NULL)
		return (0);
	sqlite3_bind_text(insert, 1, name, -1, SQLITE_STATIC);
	if (sqlite3_step(insert) != SQLITE_DONE) {
		gdb_set_error(db, "the row cannot be added: %s",
		    sqlite3_errmsg(db->db));
		gdb_stmt_done(db, insert);
		gdb_stmt_done(db, select);
		return (0);
	}
	gdb_stmt_done(db, insert);
	sqlite3_bind_text(select, 1, name, -1, SQLITE_STATIC);
	if (sqlite3_step(select) == SQLITE_ROW)
		id = (long long)sqlite3_column_int64(select, 0);
	else
		gdb_set_error(db, "the row was not found");
	gdb_stmt_done(db, select);
	return (id);
}

static long long
source_id(struct gdb *db, const char *name)
{
	sqlite3_stmt *insert;
	sqlite3_stmt *select;
	long long id;

	if (name == NULL)
		return (0);
	/* The properties come grouped by source, so the row of the source
	 * is the same for thousands of properties in a row.  It is kept
	 * until the source changes. */
	if (db->last_source_id != 0 && strcmp(db->last_source, name) == 0)
		return (db->last_source_id);
	insert = gdb_prepare(db,
	    "INSERT OR IGNORE INTO sources (name, description) VALUES (?, '')");
	select = gdb_prepare(db,
	    "SELECT id FROM sources WHERE name = ?");
	id = lookup_keep(db, insert, select, name);
	if (id != 0) {
		snprintf(db->last_source, sizeof(db->last_source), "%s", name);
		db->last_source_id = id;
	}
	return (id);
}

/* The tables that hold a name and nothing else: the id of a name is the
 * id of its row.  The statements are constants of this file: no SQL is
 * ever built from a string, and only the name is bound. */
static const char *const lookup_insert_sql[] = {
	"INSERT OR IGNORE INTO platforms (name, description) VALUES (?, '')",
	"INSERT OR IGNORE INTO result_kinds (name, description) VALUES (?, '')",
	"INSERT OR IGNORE INTO reason_codes (name, description) VALUES (?, '')",
	"INSERT OR IGNORE INTO check_ids (name) VALUES (?)",
	"INSERT OR IGNORE INTO event_kinds (name) VALUES (?)",
};

static const char *const lookup_select_sql[] = {
	"SELECT id FROM platforms WHERE name = ?",
	"SELECT id FROM result_kinds WHERE name = ?",
	"SELECT id FROM reason_codes WHERE name = ?",
	"SELECT id FROM check_ids WHERE name = ?",
	"SELECT id FROM event_kinds WHERE name = ?",
};

/* The tables of the lookups, in the order of the statements above. */
enum lookup_table {
	LOOKUP_PLATFORM = 0,
	LOOKUP_RESULT_KIND,
	LOOKUP_REASON_CODE,
	LOOKUP_CHECK_NAME,
	LOOKUP_EVENT_KIND
};

/* The id of a name in a table of names, adding the row when it is not
 * there. */
static long long
lookup_id(struct gdb *db, int which, const char *name)
{
	sqlite3_stmt *insert = gdb_prepare(db, lookup_insert_sql[which]);
	sqlite3_stmt *select = gdb_prepare(db, lookup_select_sql[which]);

	return (lookup_keep(db, insert, select, name));
}

static long long
platform_id(struct gdb *db, const char *name)
{
	return (lookup_id(db, LOOKUP_PLATFORM, name));
}

static long long
result_kind_id(struct gdb *db, const char *name)
{
	return (lookup_id(db, LOOKUP_RESULT_KIND, name));
}

static long long
reason_code_id(struct gdb *db, const char *name)
{
	return (lookup_id(db, LOOKUP_REASON_CODE, name));
}

static long long
check_name_id(struct gdb *db, const char *name)
{
	return (lookup_id(db, LOOKUP_CHECK_NAME, name));
}

static long long
event_kind_id(struct gdb *db, const char *name)
{
	return (lookup_id(db, LOOKUP_EVENT_KIND, name));
}

/* The id of a property key.  A key belongs to one source. */
static long long
property_key_id(struct gdb *db, long long src, const char *key)
{
	sqlite3_stmt *stmt;
	long long id = 0;

	stmt = gdb_prepare(db,
	    "INSERT OR IGNORE INTO property_keys (source_id, key) VALUES (?, ?)");
	if (stmt == NULL)
		return (0);
	sqlite3_bind_int64(stmt, 1, src);
	sqlite3_bind_text(stmt, 2, key, -1, SQLITE_STATIC);
	if (sqlite3_step(stmt) != SQLITE_DONE) {
		gdb_set_error(db, "the property key cannot be added: %s",
		    sqlite3_errmsg(db->db));
		gdb_stmt_done(db, stmt);
		return (0);
	}
	gdb_stmt_done(db, stmt);
	stmt = gdb_prepare(db,
	    "SELECT id FROM property_keys WHERE source_id = ? AND key = ?");
	if (stmt == NULL)
		return (0);
	sqlite3_bind_int64(stmt, 1, src);
	sqlite3_bind_text(stmt, 2, key, -1, SQLITE_STATIC);
	if (sqlite3_step(stmt) == SQLITE_ROW)
		id = (long long)sqlite3_column_int64(stmt, 0);
	gdb_stmt_done(db, stmt);
	return (id);
}

/* The id of a version row, with the parts of the version given.  The
 * parts are the ones of this call, not the ones of the text: a release
 * that reads "16.0-CURRENT" has a minor part of zero and a suffix, and
 * the caller knows that better than any reader of the text. */
static long long
version_id_parts(struct gdb *db, const char *component, const char *version,
    int major, int minor, int patch, const char *suffix)
{
	sqlite3_stmt *stmt;
	long long id = 0;

	stmt = gdb_prepare(db,
	    "INSERT OR IGNORE INTO versions (component, version, major, minor, patch,"
	    " suffix) VALUES (?, ?, ?, ?, ?, ?)");
	if (stmt == NULL)
		return (0);
	sqlite3_bind_text(stmt, 1, component, -1, SQLITE_STATIC);
	sqlite3_bind_text(stmt, 2, version, -1, SQLITE_STATIC);
	sqlite3_bind_int(stmt, 3, major);
	sqlite3_bind_int(stmt, 4, minor);
	sqlite3_bind_int(stmt, 5, patch);
	sqlite3_bind_text(stmt, 6, suffix ? suffix : "", -1, SQLITE_STATIC);
	if (sqlite3_step(stmt) != SQLITE_DONE) {
		gdb_set_error(db, "the version cannot be added: %s",
		    sqlite3_errmsg(db->db));
		gdb_stmt_done(db, stmt);
		return (0);
	}
	gdb_stmt_done(db, stmt);
	stmt = gdb_prepare(db,
	    "SELECT id FROM versions WHERE component = ? AND version = ?");
	if (stmt == NULL)
		return (0);
	sqlite3_bind_text(stmt, 1, component, -1, SQLITE_STATIC);
	sqlite3_bind_text(stmt, 2, version, -1, SQLITE_STATIC);
	if (sqlite3_step(stmt) == SQLITE_ROW)
		id = (long long)sqlite3_column_int64(stmt, 0);
	gdb_stmt_done(db, stmt);
	return (id);
}

/* The id of a version row.  The parts are worked out from the text. */
static long long
version_id(struct gdb *db, const char *component, const char *version)
{
	int major, minor, patch;

	parse_version(version, &major, &minor, &patch);
	return (version_id_parts(db, component, version, major, minor, patch, ""));
}

/* --- the events ---------------------------------------------------------- */

/* The data an event carries. */
struct gdb_data {
	int	 n;
	char	**keys;
	int	*types;
	long long*ints;
	double	*nums;
	char	**texts;
};

static void
gdb_data_free(struct gdb_data *data)
{
	int i;

	for (i = 0; i < data->n; i++) {
		free(data->keys[i]);
		free(data->texts[i]);
	}
	free(data->keys);
	free(data->types);
	free(data->ints);
	free(data->nums);
	free(data->texts);
	memset(data, 0, sizeof(*data));
}

/* The room for more rows in the payload of an event. */
static int
data_grow(struct gdb *db, struct gdb_data *data, int cap)
{
	char **keys;
	int *types;
	long long *ints;
	double *nums;
	char **texts;

	keys = realloc(data->keys, (size_t)cap * sizeof(char *));
	types = realloc(data->types, (size_t)cap * sizeof(int));
	ints = realloc(data->ints, (size_t)cap * sizeof(long long));
	nums = realloc(data->nums, (size_t)cap * sizeof(double));
	texts = realloc(data->texts, (size_t)cap * sizeof(char *));
	if (keys != NULL)
		data->keys = keys;
	if (types != NULL)
		data->types = types;
	if (ints != NULL)
		data->ints = ints;
	if (nums != NULL)
		data->nums = nums;
	if (texts != NULL)
		data->texts = texts;
	if (keys == NULL || types == NULL || ints == NULL || nums == NULL ||
	    texts == NULL) {
		gdb_set_error(db, "there is no memory for the event");
		return (-1);
	}
	return (0);
}

static int
gdb_data_load(struct gdb *db, long long event_id, struct gdb_data *data)
{
	sqlite3_stmt *stmt;
	int cap = 16;

	memset(data, 0, sizeof(*data));
	data->keys = calloc((size_t)cap, sizeof(char *));
	data->types = calloc((size_t)cap, sizeof(int));
	data->ints = calloc((size_t)cap, sizeof(long long));
	data->nums = calloc((size_t)cap, sizeof(double));
	data->texts = calloc((size_t)cap, sizeof(char *));
	if (data->keys == NULL || data->types == NULL || data->ints == NULL ||
	    data->nums == NULL || data->texts == NULL) {
		gdb_set_error(db, "there is no memory for the event");
		gdb_data_free(data);
		return (-1);
	}
	stmt = gdb_prepare(db,
	    "SELECT data_key, data_int, data_num, data_text FROM event_data"
	    " WHERE event_id = ? ORDER BY id");
	if (stmt == NULL) {
		gdb_data_free(data);
		return (-1);
	}
	sqlite3_bind_int64(stmt, 1, event_id);
	while (sqlite3_step(stmt) == SQLITE_ROW) {
		const char *key = (const char *)sqlite3_column_text(stmt, 0);

		if (data->n == cap) {
			cap *= 2;
			if (data_grow(db, data, cap) != 0) {
				gdb_stmt_done(db, stmt);
				gdb_data_free(data);
				return (-1);
			}
		}
		data->keys[data->n] = strdup(key ? key : "");
		data->texts[data->n] = NULL;
		if (sqlite3_column_type(stmt, 1) != SQLITE_NULL) {
			data->types[data->n] = 0;
			data->ints[data->n] = sqlite3_column_int64(stmt, 1);
		} else if (sqlite3_column_type(stmt, 2) != SQLITE_NULL) {
			data->types[data->n] = 1;
			data->nums[data->n] = sqlite3_column_double(stmt, 2);
		} else {
			data->types[data->n] = 2;
			data->texts[data->n] = strdup((const char *)
			    sqlite3_column_text(stmt, 3));
		}
		data->n++;
	}
	gdb_stmt_done(db, stmt);
	return (0);
}

static const char *
data_text(const struct gdb_data *data, const char *key)
{
	int i;

	for (i = 0; i < data->n; i++) {
		if (strcmp(data->keys[i], key) == 0 && data->types[i] == 2)
			return (data->texts[i]);
	}
	return (NULL);
}

static int
data_int(const struct gdb_data *data, const char *key, long long *out)
{
	int i;

	for (i = 0; i < data->n; i++) {
		if (strcmp(data->keys[i], key) == 0 && data->types[i] == 0) {
			*out = data->ints[i];
			return (0);
		}
	}
	return (-1);
}

static int
data_num(const struct gdb_data *data, const char *key, double *out)
{
	int i;

	for (i = 0; i < data->n; i++) {
		if (strcmp(data->keys[i], key) == 0 && data->types[i] == 1) {
			*out = data->nums[i];
			return (0);
		}
	}
	return (-1);
}

static const char *
data_kind(const struct gdb_data *data, const char *key)
{
	int i;

	for (i = 0; i < data->n; i++) {
		if (strcmp(data->keys[i], key) == 0)
			return (data->types[i] == 0 ? "int" :
			    (data->types[i] == 1 ? "number" : "string"));
	}
	return (NULL);
}

/* The text of the event, or the fallback when the event has none. */
static const char *
data_text_or(const struct gdb_data *data, const char *key, const char *fallback)
{
	const char *text = data_text(data, key);

	return (text != NULL ? text : fallback);
}

/* The first of the keys the event carries a text for. */
static const char *
data_first_text(const struct gdb_data *data, const char *const *keys, int n)
{
	int i;

	for (i = 0; i < n; i++) {
		const char *text = data_text(data, keys[i]);

		if (text != NULL)
			return (text);
	}
	return (NULL);
}

/* The first of the keys the event carries a text for, or the fallback. */
static const char *
data_first_or(const struct gdb_data *data, const char *const *keys, int n,
    const char *fallback)
{
	const char *text = data_first_text(data, keys, n);

	return (text != NULL ? text : fallback);
}

/* The flag of the event: one when it is set, zero when it is not, and zero
 * when the event does not carry it at all. */
static int
data_flag(const struct gdb_data *data, const char *key)
{
	long long number = 0;

	if (data_int(data, key, &number) != 0)
		return (0);
	return (number != 0 ? 1 : 0);
}

/* --- writing an event ---------------------------------------------------- */

struct gdb_event *
gdb_event_begin(struct gdb *db, const char *kind, const char *name)
{
	struct gdb_event *event;

	if (db == NULL)
		return (NULL);
	event = calloc(1, sizeof(*event));
	if (event == NULL) {
		gdb_set_error(db, "there is no memory for the event");
		return (NULL);
	}
	event->db = db;
	snprintf(event->kind, sizeof(event->kind), "%s", kind ? kind : "");
	snprintf(event->name, sizeof(event->name), "%s", name ? name : "");
	return (event);
}

void
gdb_event_free(struct gdb_event *event)
{
	int i;

	if (event == NULL)
		return;
	for (i = 0; i < event->ndata; i++) {
		free(event->keys[i]);
		free(event->texts[i]);
	}
	free(event);
}

static int
event_set(struct gdb_event *event, const char *key, int type, long long ivalue,
    double nvalue, const char *text)
{
	int i;

	if (event == NULL || key == NULL)
		return (-1);
	for (i = 0; i < event->ndata; i++) {
		if (strcmp(event->keys[i], key) == 0)
			break;
	}
	if (i == event->ndata) {
		if (event->ndata >= GDB_MAX_DATA) {
			gdb_set_error(event->db, "the event holds too much data");
			return (-1);
		}
		event->keys[i] = strdup(key);
		event->types[i] = type;
		event->ints[i] = 0;
		event->nums[i] = 0;
		event->texts[i] = NULL;
		event->ndata++;
	} else {
		free(event->texts[i]);
		event->texts[i] = NULL;
	}
	event->types[i] = type;
	switch (type) {
	case 0:
		event->ints[i] = ivalue;
		break;
	case 1:
		event->nums[i] = nvalue;
		break;
	default:
		event->texts[i] = strdup(text ? text : "");
		break;
	}
	return (0);
}

int
gdb_event_int(struct gdb_event *event, const char *key, long long value)
{
	return (event_set(event, key, 0, value, 0.0, NULL));
}

int
gdb_event_num(struct gdb_event *event, const char *key, double value)
{
	return (event_set(event, key, 1, 0, value, NULL));
}

int
gdb_event_text(struct gdb_event *event, const char *key, const char *value)
{
	return (event_set(event, key, 2, 0, 0.0, value));
}

int
gdb_event_abort(struct gdb_event *event)
{
	gdb_event_free(event);
	return (0);
}

/* The id of the row of an event. */
static long long
insert_event_row(struct gdb *db, const char *kind, const char *name,
    long long run_id, const char *ts)
{
	sqlite3_stmt *stmt;
	long long id = 0;
	long long kind_row;

	kind_row = event_kind_id(db, kind);
	if (kind_row == 0)
		return (0);
	stmt = gdb_prepare(db,
	    "INSERT INTO events (run_id, kind_id, ts, name) VALUES (?, ?, ?, ?)");
	if (stmt == NULL)
		return (0);
	if (run_id > 0)
		sqlite3_bind_int64(stmt, 1, run_id);
	else
		sqlite3_bind_null(stmt, 1);
	sqlite3_bind_int64(stmt, 2, kind_row);
	sqlite3_bind_text(stmt, 3, ts, -1, SQLITE_STATIC);
	sqlite3_bind_text(stmt, 4, name, -1, SQLITE_STATIC);
	if (sqlite3_step(stmt) != SQLITE_DONE) {
		gdb_set_error(db, "the event cannot be added: %s",
		    sqlite3_errmsg(db->db));
		gdb_stmt_done(db, stmt);
		return (0);
	}
	id = (long long)sqlite3_last_insert_rowid(db->db);
	gdb_stmt_done(db, stmt);
	return (id);
}

/* One row of the data of an event. */
static int
insert_event_data(struct gdb *db, long long event_id, const char *key, int type,
    long long ivalue, double nvalue, const char *text)
{
	sqlite3_stmt *stmt;

	stmt = gdb_prepare(db,
	    "INSERT OR REPLACE INTO event_data (event_id, data_key, data_int,"
	    " data_num, data_text) VALUES (?, ?, ?, ?, ?)");
	if (stmt == NULL)
		return (-1);
	sqlite3_bind_int64(stmt, 1, event_id);
	sqlite3_bind_text(stmt, 2, key, -1, SQLITE_STATIC);
	switch (type) {
	case 0:
		sqlite3_bind_int64(stmt, 3, ivalue);
		sqlite3_bind_null(stmt, 4);
		sqlite3_bind_null(stmt, 5);
		break;
	case 1:
		sqlite3_bind_null(stmt, 3);
		sqlite3_bind_double(stmt, 4, nvalue);
		sqlite3_bind_null(stmt, 5);
		break;
	default:
		sqlite3_bind_null(stmt, 3);
		sqlite3_bind_null(stmt, 4);
		sqlite3_bind_text(stmt, 5, text ? text : "", -1, SQLITE_STATIC);
		break;
	}
	if (sqlite3_step(stmt) != SQLITE_DONE) {
		gdb_set_error(db, "the data of the event cannot be added: %s",
		    sqlite3_errmsg(db->db));
		gdb_stmt_done(db, stmt);
		return (-1);
	}
	gdb_stmt_done(db, stmt);
	return (0);
}

/* --- the state that is derived from the events --------------------------- */

/* The device of a run, by its number in the run. */
static long long
device_of_ordinal(struct gdb *db, long long run_id, long long ordinal)
{
	sqlite3_stmt *stmt;
	long long id = 0;

	stmt = gdb_prepare(db,
	    "SELECT id FROM devices WHERE run_id = ? AND ordinal = ?");
	if (stmt == NULL)
		return (0);
	sqlite3_bind_int64(stmt, 1, run_id);
	sqlite3_bind_int64(stmt, 2, ordinal);
	if (sqlite3_step(stmt) == SQLITE_ROW)
		id = (long long)sqlite3_column_int64(stmt, 0);
	gdb_stmt_done(db, stmt);
	return (id);
}

/* The definition of a check, by its name. */
static long long
check_def_of_name(struct gdb *db, const char *name)
{
	sqlite3_stmt *stmt;
	long long id = 0;

	stmt = gdb_prepare(db,
	    "SELECT d.id FROM check_defs d JOIN check_ids c ON c.id = d.check_id"
	    " WHERE c.name = ?");
	if (stmt == NULL)
		return (0);
	sqlite3_bind_text(stmt, 1, name, -1, SQLITE_STATIC);
	if (sqlite3_step(stmt) == SQLITE_ROW)
		id = (long long)sqlite3_column_int64(stmt, 0);
	gdb_stmt_done(db, stmt);
	return (id);
}

/* The definition of a check, by its id, added when it is not there. */
static long long
ensure_check_def(struct gdb *db, const char *name, const char *title,
    long long ordinal)
{
	sqlite3_stmt *stmt;
	long long id, name_row;

	id = check_def_of_name(db, name);
	if (id != 0)
		return (id);
	name_row = check_name_id(db, name);
	if (name_row == 0)
		return (0);
	stmt = gdb_prepare(db,
	    "INSERT OR IGNORE INTO check_defs (check_id, ordinal, title,"
	    " needs_root, needs_load, loads, is_decision)"
	    " VALUES (?, ?, ?, 0, 0, 0, 0)");
	if (stmt == NULL)
		return (0);
	sqlite3_bind_int64(stmt, 1, name_row);
	sqlite3_bind_int64(stmt, 2, ordinal > 0 ? ordinal : 1);
	sqlite3_bind_text(stmt, 3, title ? title : name, -1, SQLITE_STATIC);
	if (sqlite3_step(stmt) != SQLITE_DONE) {
		gdb_set_error(db, "the definition of the check cannot be added: %s",
		    sqlite3_errmsg(db->db));
		gdb_stmt_done(db, stmt);
		return (0);
	}
	gdb_stmt_done(db, stmt);
	return (check_def_of_name(db, name));
}

/* The definition of a metric, by its key.  Zero when it is not defined:
 * a metric that is not defined has no value. */
static long long
metric_def_of_key(struct gdb *db, const char *key)
{
	sqlite3_stmt *stmt;
	long long id = 0;

	stmt = gdb_prepare(db, "SELECT id FROM metric_defs WHERE key = ?");
	if (stmt == NULL)
		return (0);
	sqlite3_bind_text(stmt, 1, key, -1, SQLITE_STATIC);
	if (sqlite3_step(stmt) == SQLITE_ROW)
		id = (long long)sqlite3_column_int64(stmt, 0);
	gdb_stmt_done(db, stmt);
	return (id);
}

/* The value of a property that is open right now, and its row.  The
 * value is the one of this run: a run keeps its own history, so the
 * values of an earlier run never open the value of this one. */
static int
open_property_value(struct gdb *db, long long property_id, long long *row,
    long long *ivalue, double *nvalue, char **text)
{
	sqlite3_stmt *stmt;

	*row = 0;
	*ivalue = 0;
	*nvalue = 0;
	*text = NULL;
	stmt = gdb_prepare(db,
	    "SELECT id, value_int, value_num, value_text FROM property_values"
	    " WHERE property_id = ? AND run_id = ? AND closed_at IS NULL"
	    " LIMIT 1");
	if (stmt == NULL)
		return (-1);
	sqlite3_bind_int64(stmt, 1, property_id);
	sqlite3_bind_int64(stmt, 2, db->current_run);
	if (sqlite3_step(stmt) == SQLITE_ROW) {
		*row = (long long)sqlite3_column_int64(stmt, 0);
		if (sqlite3_column_type(stmt, 1) != SQLITE_NULL)
			*ivalue = (long long)sqlite3_column_int64(stmt, 1);
		else if (sqlite3_column_type(stmt, 2) != SQLITE_NULL)
			*nvalue = sqlite3_column_double(stmt, 2);
		else {
			const char *value = (const char *)
			    sqlite3_column_text(stmt, 3);

			*text = value ? strdup(value) : NULL;
		}
	}
	gdb_stmt_done(db, stmt);
	return (0);
}

/* The kind of a value: what it is in the database.  Zero is an integer,
 * one is a number, two is text. */
static int
value_kind_code(const char *kind)
{
	if (kind == NULL)
		return (2);
	if (strcmp(kind, GDB_KIND_INT) == 0 || strcmp(kind, GDB_KIND_UINT) == 0)
		return (0);
	if (strcmp(kind, GDB_KIND_NUMBER) == 0)
		return (1);
	return (2);
}

/* The blob of a value that does not fit: the text of it, hashed. */
static long long
store_blob(struct gdb *db, const char *source, const char *text)
{
	sqlite3_stmt *stmt;
	long long id = 0;
	char hash[65];
	long long src;

	src = source_id(db, source);
	if (src == 0)
		return (0);
	gdb_sha256_hex(text, strlen(text), hash);
	stmt = gdb_prepare(db,
	    "SELECT id FROM blobs WHERE source_id = ? AND sha256 = ?");
	if (stmt == NULL)
		return (0);
	sqlite3_bind_int64(stmt, 1, src);
	sqlite3_bind_text(stmt, 2, hash, -1, SQLITE_STATIC);
	if (sqlite3_step(stmt) == SQLITE_ROW)
		id = (long long)sqlite3_column_int64(stmt, 0);
	gdb_stmt_done(db, stmt);
	if (id != 0)
		return (id);
	stmt = gdb_prepare(db,
	    "INSERT INTO blobs (source_id, sha256, size, compression, event_id,"
	    " created_at, content) VALUES (?, ?, ?, 'none', NULL, ?, ?)");
	if (stmt == NULL)
		return (0);
	{
		char ts[40];

		now_utc(ts);
		sqlite3_bind_int64(stmt, 1, src);
		sqlite3_bind_text(stmt, 2, hash, -1, SQLITE_STATIC);
		sqlite3_bind_int64(stmt, 3, (long long)strlen(text));
		sqlite3_bind_text(stmt, 4, ts, -1, SQLITE_STATIC);
		sqlite3_bind_text(stmt, 5, text, -1, SQLITE_STATIC);
	}
	if (sqlite3_step(stmt) != SQLITE_DONE) {
		gdb_set_error(db, "the blob cannot be added: %s",
		    sqlite3_errmsg(db->db));
		gdb_stmt_done(db, stmt);
		return (0);
	}
	id = (long long)sqlite3_last_insert_rowid(db->db);
	gdb_stmt_done(db, stmt);
	return (id);
}

/* The property of a key.  A property is a key, so the key is the
 * whole of the lookup: the source of the key is in property_keys and
 * is not repeated here. */
static long long
property_of_key(struct gdb *db, long long key_row)
{
	sqlite3_stmt *stmt;
	long long id = 0;

	stmt = gdb_prepare(db, "SELECT id FROM properties WHERE key_id = ?");
	if (stmt == NULL)
		return (0);
	sqlite3_bind_int64(stmt, 1, key_row);
	if (sqlite3_step(stmt) == SQLITE_ROW)
		id = (long long)sqlite3_column_int64(stmt, 0);
	gdb_stmt_done(db, stmt);
	return (id);
}

/* --- the derived state, one event at a time ------------------------------ */

static int apply_event(struct gdb *db, long long event_id, const char *kind,
    const char *name, const struct gdb_data *data);

/* The link of an event to the run it belongs to.  Every event of a run
 * but the one that starts it points at that run. */
static int
link_event_run(struct gdb *db, long long event_id, long long run_id)
{
	sqlite3_stmt *stmt;

	stmt = gdb_prepare(db, "UPDATE events SET run_id = ? WHERE id = ?");
	if (stmt == NULL)
		return (-1);
	sqlite3_bind_int64(stmt, 1, run_id);
	sqlite3_bind_int64(stmt, 2, event_id);
	if (sqlite3_step(stmt) != SQLITE_DONE) {
		gdb_set_error(db, "the event cannot be linked to the run: %s",
		    sqlite3_errmsg(db->db));
		gdb_stmt_done(db, stmt);
		return (-1);
	}
	gdb_stmt_done(db, stmt);
	return (0);
}

/* The version of the operating system of the run, and the string it was
 * read from.  The parts come from the event when they are there, and
 * from the string when they are not. */
static long long
os_version_of(struct gdb *db, const struct gdb_data *data, const char **vtext)
{
	const char *text;
	const char *suffix = "";
	int major = 0, minor = 0, patch = 0;
	long long number;

	text = data_text(data, "host.os_release.string");
	if (text == NULL)
		text = data_text(data, "os_release");
	*vtext = text;
	if (text == NULL || *text == '\0')
		return (0);
	parse_version(text, &major, &minor, &patch);
	if (data_int(data, "host.os_release.major", &number) == 0)
		major = (int)number;
	else if (data_int(data, "os_major", &number) == 0)
		major = (int)number;
	if (data_int(data, "host.os_release.minor", &number) == 0)
		minor = (int)number;
	else if (data_int(data, "os_minor", &number) == 0)
		minor = (int)number;
	if (data_int(data, "host.os_release.patch", &number) == 0)
		patch = (int)number;
	else if (data_int(data, "os_patch", &number) == 0)
		patch = (int)number;
	if (data_text(data, "host.os_release.suffix") != NULL)
		suffix = data_text(data, "host.os_release.suffix");
	else if (data_text(data, "os_suffix") != NULL)
		suffix = data_text(data, "os_suffix");
	return (version_id_parts(db, "os", text, major, minor, patch, suffix));
}

/* The row of the run, as the event carries it. */
static int
insert_run(struct gdb *db, const struct gdb_data *data, long long *run_id)
{
	sqlite3_stmt *stmt;
	long long platform, tool_version = 0, os_version = 0;
	const char *text;
	const char *vtext;
	const char *osname;
	char ts[40];
	static const char *const os_keys[] = { "host.os", "os_name", "os" };
	static const char *const arch_keys[] = { "host.arch", "arch" };

	text = data_text(data, "started_at");
	if (text == NULL) {
		now_utc(ts);
		text = ts;
	}
	platform = platform_id(db, data_text_or(data, "platform", "unknown"));
	if (platform == 0)
		return (-1);
	vtext = data_text(data, "tool_version");
	if (vtext != NULL && *vtext != '\0')
		tool_version = version_id(db, "tool", vtext);
	/* The host is the block the document holds: the name of the
	 * system, and the release with its parts. */
	osname = data_first_or(data, os_keys, 3, "");
	os_version = os_version_of(db, data, &vtext);
	stmt = gdb_prepare(db,
	    "INSERT INTO runs (started_at, ended_at, finished, tool,"
	    " tool_version_id, mode, arch, platform_id, exit_code, host_hash,"
	    " kit_commit, boot_env, fake, capture, os_name, os_version_id)"
	    " VALUES (?, NULL, 0, ?, ?, ?, ?, ?, NULL, ?, ?, ?, ?, ?, ?, ?)");
	if (stmt == NULL)
		return (-1);
	sqlite3_bind_text(stmt, 1, text, -1, SQLITE_STATIC);
	sqlite3_bind_text(stmt, 2, data_text_or(data, "tool", "gpu-check"), -1,
	    SQLITE_STATIC);
	if (tool_version > 0)
		sqlite3_bind_int64(stmt, 3, tool_version);
	else
		sqlite3_bind_null(stmt, 3);
	sqlite3_bind_text(stmt, 4, data_text_or(data, "mode", "detect"), -1,
	    SQLITE_STATIC);
	sqlite3_bind_text(stmt, 5, data_first_or(data, arch_keys, 2, "unknown"), -1,
	    SQLITE_STATIC);
	sqlite3_bind_int64(stmt, 6, platform);
	sqlite3_bind_text(stmt, 7, data_text_or(data, "host_hash", ""), -1,
	    SQLITE_STATIC);
	sqlite3_bind_text(stmt, 8, data_text_or(data, "kit_commit", ""), -1,
	    SQLITE_STATIC);
	sqlite3_bind_text(stmt, 9, data_text_or(data, "boot_env", ""), -1,
	    SQLITE_STATIC);
	sqlite3_bind_int(stmt, 10, data_flag(data, "fake"));
	sqlite3_bind_int(stmt, 11, data_flag(data, "capture"));
	sqlite3_bind_text(stmt, 12, osname, -1, SQLITE_STATIC);
	if (os_version > 0)
		sqlite3_bind_int64(stmt, 13, os_version);
	else
		sqlite3_bind_null(stmt, 13);
	if (sqlite3_step(stmt) != SQLITE_DONE) {
		gdb_set_error(db, "the run cannot be added: %s",
		    sqlite3_errmsg(db->db));
		gdb_stmt_done(db, stmt);
		return (-1);
	}
	gdb_stmt_done(db, stmt);
	*run_id = (long long)sqlite3_last_insert_rowid(db->db);
	return (0);
}

/* The state of a run that has just started. */
static int
apply_run_start(struct gdb *db, long long event_id, const struct gdb_data *data)
{
	if (insert_run(db, data, &db->current_run) != 0)
		return (-1);
	if (link_event_run(db, event_id, db->current_run) != 0)
		return (-1);
	/* The run begins with a machine that is read for the first time:
	 * there is no snapshot before it to compare it with. */
	db->snap_have_last = 0;
	db->nsnap_seen = 0;
	db->nsnap_last = 0;
	db->nsnap_changed = 0;
	return (0);
}

/* The state of a run that has just ended. */
static int
apply_run_end(struct gdb *db, const struct gdb_data *data)
{
	sqlite3_stmt *stmt;
	long long number;
	const char *text;

	/* The values that are still open are closed: the next run starts
	 * with a value of its own. */
	stmt = gdb_prepare(db,
	    "UPDATE property_values SET closed_at = datetime('now')"
	    " WHERE run_id = ? AND closed_at IS NULL");
	if (stmt != NULL) {
		sqlite3_bind_int64(stmt, 1, db->current_run);
		if (sqlite3_step(stmt) != SQLITE_DONE)
			gdb_set_error(db, "the values cannot be closed: %s",
			    sqlite3_errmsg(db->db));
		gdb_stmt_done(db, stmt);
	}
	stmt = gdb_prepare(db,
	    "UPDATE runs SET ended_at = ?, finished = 1, exit_code = ?"
	    " WHERE id = ?");
	if (stmt == NULL)
		return (-1);
	text = data_text(data, "ended_at");
	if (text == NULL) {
		char ts[40];

		now_utc(ts);
		sqlite3_bind_text(stmt, 1, ts, -1, SQLITE_STATIC);
	} else {
		sqlite3_bind_text(stmt, 1, text, -1, SQLITE_STATIC);
	}
	/* The exit status of the run: the document of the run calls it
	 * "exit", and the record calls it "exit_code". */
	if (data_int(data, "exit", &number) == 0)
		sqlite3_bind_int64(stmt, 2, number);
	else if (data_int(data, "exit_code", &number) == 0)
		sqlite3_bind_int64(stmt, 2, number);
	else
		sqlite3_bind_null(stmt, 2);
	sqlite3_bind_int64(stmt, 3, db->current_run);
	if (sqlite3_step(stmt) != SQLITE_DONE) {
		gdb_set_error(db, "the run cannot be closed: %s",
		    sqlite3_errmsg(db->db));
		gdb_stmt_done(db, stmt);
		return (-1);
	}
	gdb_stmt_done(db, stmt);
	return (0);
}

/* The state of a card. */
/* The text of a column, or null when the event did not carry it.  A
 * value that is not there is not the empty text: the document says null
 * where the database says null. */
static void
bind_text_or_null(sqlite3_stmt *stmt, int index, const char *text)
{
	if (text == NULL)
		sqlite3_bind_null(stmt, index);
	else
		sqlite3_bind_text(stmt, index, text, -1, SQLITE_STATIC);
}

/* The text of a column, or the empty text when the event did not carry
 * it.  Some columns are never null: the name of a card is the name of a
 * card, and a card without one has the empty name. */
static void
bind_text_or_empty(sqlite3_stmt *stmt, int index, const char *text)
{
	sqlite3_bind_text(stmt, index, text != NULL ? text : "", -1,
	    SQLITE_STATIC);
}

/* The row is added: the statement is stepped, and a failure is the
 * failure of the row.  Every insert of the library ends this way. */
static int
insert_done(struct gdb *db, sqlite3_stmt *stmt, const char *what)
{
	if (sqlite3_step(stmt) != SQLITE_DONE) {
		gdb_set_error(db, "the %s cannot be added: %s", what,
		    sqlite3_errmsg(db->db));
		gdb_stmt_done(db, stmt);
		return (-1);
	}
	gdb_stmt_done(db, stmt);
	return (0);
}

/* The row is added, and the row is the last one the database made: the
 * caller wants the number of it. */
static long long
insert_row_id(struct gdb *db, sqlite3_stmt *stmt, const char *what)
{
	if (insert_done(db, stmt, what) != 0)
		return (-1);
	return ((long long)sqlite3_last_insert_rowid(db->db));
}

/* How a field of an item of a list is read. */
enum gdb_item_kind {
	GDB_ITEM_TEXT,		/* the text of the field, copied */
	GDB_ITEM_NUMBER,	/* the number of the field */
	GDB_ITEM_FLAG		/* the number of the field, as true or false */
};

/* One field of an item of a list: the name of the field in the event,
 * how it is read, and where it goes in the item. */
struct gdb_item_field {
	const char		*name;
	enum gdb_item_kind	kind;
	size_t			offset;
	const char		*fallback;	/* the text it falls back on */
};

/* How the items of a list are laid out: where the ordinal of an item
 * goes, where its name goes, and the fields of the item. */
struct gdb_item_layout {
	size_t				ordinal_offset;
	size_t				name_offset;
	const struct gdb_item_field	*fields;
};

/* The statements that add a row of a table of the run.  They are
 * constants: a statement is never built at runtime. */
enum gdb_insert {
	GDB_INSERT_FEATURES,
	GDB_INSERT_STEPS
};

static const char *const insert_sql[] = {
	"INSERT INTO device_features (device_id, ordinal, feature_index,"
	" name, available, reason, value) VALUES (?, ?, ?, ?, ?, ?, ?)",
	"INSERT INTO check_steps (check_row_id, ordinal, name, status,"
	" detail) VALUES (?, ?, ?, ?, ?)"
};

/* One row of a table of the run: the row owns the item, the item has
 * its place in the list, and every field of the item is a column of
 * the row.  The fields are bound in the order of the table of the
 * fields, which is the order of the columns of the statement. */
static int
insert_row(struct gdb *db, enum gdb_insert which, const void *item,
    long long owner, const struct gdb_item_layout *layout, const char *what)
{
	sqlite3_stmt *stmt;
	const char *base = (const char *)item;
	size_t i;
	int index = 1;

	stmt = gdb_prepare(db, insert_sql[which]);
	if (stmt == NULL)
		return (-1);
	sqlite3_bind_int64(stmt, index++, owner);
	sqlite3_bind_int64(stmt, index++,
	    *(const long long *)(base + layout->ordinal_offset));
	for (i = 0; layout->fields[i].name != NULL; i++) {
		const char *slot = base + layout->fields[i].offset;

		switch (layout->fields[i].kind) {
		case GDB_ITEM_NUMBER:
			sqlite3_bind_int64(stmt, index++,
			    *(const long long *)slot);
			break;
		case GDB_ITEM_FLAG:
			sqlite3_bind_int(stmt, index++, *(const int *)slot);
			break;
		default: {
			const char *text = *(const char *const *)slot;

			bind_text_or_null(stmt, index++, text != NULL ? text :
			    layout->fields[i].fallback);
			break;
		}
		}
	}
	return (insert_done(db, stmt, what));
}

/* The rows of a list of the run: one row for every item of the list.
 * An item without a name is not a row. */
static int
insert_item_rows(struct gdb *db, enum gdb_insert which, const void *items,
    long long count, size_t size, long long owner,
    const struct gdb_item_layout *layout, const char *what)
{
	long long i;

	for (i = 0; i < count; i++) {
		const char *item = (const char *)items + (size_t)i * size;

		if (*(const char *const *)(item + layout->name_offset) == NULL)
			continue;
		if (insert_row(db, which, item, owner, layout, what) != 0)
			return (-1);
	}
	return (0);
}

/* How a column of a row is filled. */
enum gdb_bind {
	GDB_BIND_EMPTY,	/* the text of the key, or the empty text */
	GDB_BIND_NULL,	/* the text of the key, or null */
	GDB_BIND_ALT	/* the text of the first key, or of the second */
};

/* One column of a row: where it is, how it is filled, and the key of
 * the event that carries it. */
struct gdb_column {
	int		index;
	enum gdb_bind	kind;
	const char	*key;
	const char	*alt_key;
};

/* The columns of a row: the event carries the text of every column
 * under a key of its own, and the table says which key is which
 * column.  The table ends with a column whose key is not there. */
static void
bind_columns(sqlite3_stmt *stmt, const struct gdb_data *data,
    const struct gdb_column *columns)
{
	size_t i;

	for (i = 0; columns[i].key != NULL; i++) {
		const char *text = data_text(data, columns[i].key);

		switch (columns[i].kind) {
		case GDB_BIND_ALT:
			if (text == NULL)
				text = data_text(data, columns[i].alt_key);
			bind_text_or_null(stmt, columns[i].index, text);
			break;
		case GDB_BIND_EMPTY:
			bind_text_or_empty(stmt, columns[i].index, text);
			break;
		default:
			bind_text_or_null(stmt, columns[i].index, text);
			break;
		}
	}
}

/* One feature of a card, as the event carries it. */
struct gdb_feature {
	long long	ordinal;
	long long	number;
	char		*name;
	int		 available;
	char		*reason;
	char		*value;
};

/* The number of the list a key belongs to, or -1 when it is not one. */
static long long
list_number(const char *key, const char *prefix, const char *suffix)
{
	size_t plen = strlen(prefix);
	size_t slen = strlen(suffix);
	size_t len = strlen(key);
	long long number = 0;
	size_t i;

	if (len <= plen + slen)
		return (-1);
	if (strncmp(key, prefix, plen) != 0)
		return (-1);
	if (strcmp(key + len - slen, suffix) != 0)
		return (-1);
	for (i = plen; i < len - slen; i++) {
		if (key[i] < '0' || key[i] > '9')
			return (-1);
		number = number * 10 + (key[i] - '0');
	}
	return (number);
}

/* The field of a list item a key names: the key "features.3.name" is
 * the field "name" of the fourth feature.  Returns 1 when the key is
 * one of those. */
static int
list_field(const char *key, const char *prefix, long long *number, char *field,
    size_t fieldlen)
{
	size_t plen = strlen(prefix);
	size_t len = strlen(key);
	long long value = 0;
	size_t i;

	if (len <= plen + 2)
		return (0);
	if (strncmp(key, prefix, plen) != 0)
		return (0);
	for (i = plen; i < len; i++) {
		if (key[i] == '.')
			break;
		if (key[i] < '0' || key[i] > '9')
			return (0);
		value = value * 10 + (key[i] - '0');
	}
	if (i == plen || i >= len - 1)
		return (0);
	*number = value;
	snprintf(field, fieldlen, "%s", key + i + 1);
	return (1);
}

/* The items of a list in the event.  A list is carried as numbered
 * fields: "steps.0.name".  The items are in an array of their own, one
 * for every number of the list, and the count is the number of the
 * largest one. */
static void *
collect_list(const struct gdb_data *data, const char *prefix, size_t size,
    long long *count)
{
	void *items;
	long long largest = -1;
	int i;

	*count = 0;
	for (i = 0; i < data->n; i++) {
		long long number = -1;
		char field[32];

		if (!list_field(data->keys[i], prefix, &number, field,
		    sizeof(field)))
			continue;
		if (number > largest)
			largest = number;
	}
	if (largest < 0)
		return (NULL);
	items = calloc((size_t)largest + 1, size);
	if (items == NULL)
		return (NULL);
	*count = largest + 1;
	return (items);
}

/* The text of a field of an item of a list, copied into the item. */
static void
set_item_text(char **slot, const struct gdb_data *data, const char *key)
{
	const char *text = data_text(data, key);

	free(*slot);
	*slot = strdup(text != NULL ? text : "");
}

/* One field of a list: the number of the item it belongs to, the name of
 * the field, and the key the event carries it under. */
struct gdb_item {
	long long	number;
	char		field[32];
	const char	*key;
};

/* The field of the table the key carries. */
static const struct gdb_item_field *
item_field_of(const struct gdb_item_field *fields, const char *name)
{
	size_t i;

	for (i = 0; fields[i].name != NULL; i++)
		if (strcmp(fields[i].name, name) == 0)
			return (&fields[i]);
	return (NULL);
}

/* One field of an item: the value goes where the table says. */
static void
fill_item(void *item, const struct gdb_data *data, const char *key,
    const struct gdb_item_field *field)
{
	void *slot = (char *)item + field->offset;

	switch (field->kind) {
	case GDB_ITEM_NUMBER: {
		long long value = 0;

		if (data_int(data, key, &value) == 0)
			*(long long *)slot = value;
		break;
	}
	case GDB_ITEM_FLAG: {
		long long value = 0;

		*(int *)slot = (data_int(data, key, &value) == 0 && value) ?
		    1 : 0;
		break;
	}
	default:
		set_item_text((char **)slot, data, key);
		break;
	}
}

/* The items of a list of the event: every field of every item is
 * carried under a key of its own, and the table says which field of
 * the item is which part of it. */
static void *
collect_items(const struct gdb_data *data, const char *prefix, size_t size,
    const struct gdb_item_layout *layout, long long *count)
{
	void *items;
	long long i;

	items = collect_list(data, prefix, size, count);
	if (items == NULL)
		return (NULL);
	for (i = 0; i < data->n; i++) {
		struct gdb_item item;
		const struct gdb_item_field *field;
		char *slot;

		item.key = data->keys[i];
		if (!list_field(item.key, prefix, &item.number, item.field,
		    sizeof(item.field)))
			continue;
		slot = (char *)items + (size_t)item.number * size;
		*(long long *)(slot + layout->ordinal_offset) = item.number;
		field = item_field_of(layout->fields, item.field);
		if (field == NULL)
			continue;
		fill_item(slot, data, item.key, field);
	}
	return (items);
}

/* The fields of a feature of a card.  The order of the fields is the
 * order of the columns of the row of the feature. */
static const struct gdb_item_field feature_fields[] = {
	{ "index", GDB_ITEM_NUMBER, offsetof(struct gdb_feature, number), NULL },
	{ "name", GDB_ITEM_TEXT, offsetof(struct gdb_feature, name), NULL },
	{ "available", GDB_ITEM_FLAG, offsetof(struct gdb_feature, available),
	  NULL },
	{ "reason", GDB_ITEM_TEXT, offsetof(struct gdb_feature, reason), NULL },
	{ "value", GDB_ITEM_TEXT, offsetof(struct gdb_feature, value), NULL },
	{ NULL, GDB_ITEM_TEXT, 0, NULL }
};

/* How a feature of a card is laid out. */
static const struct gdb_item_layout feature_layout = {
	offsetof(struct gdb_feature, ordinal),
	offsetof(struct gdb_feature, name),
	feature_fields
};

/* The features of the card, as the event carries them. */
static struct gdb_feature *
collect_features(const struct gdb_data *data, long long *nfeatures)
{
	return (collect_items(data, "features.", sizeof(struct gdb_feature),
	    &feature_layout, nfeatures));
}

/* The items of a list are freed, whatever happened to them: the text of
 * an item is freed, the numbers of it are not. */
static void
free_items(void *items, long long count, size_t size,
    const struct gdb_item_field *fields)
{
	long long i;
	size_t j;

	if (items == NULL)
		return;
	for (i = 0; i < count; i++) {
		char *item = (char *)items + (size_t)i * size;

		for (j = 0; fields[j].name != NULL; j++)
			if (fields[j].kind == GDB_ITEM_TEXT)
				free(*(char **)(item + fields[j].offset));
	}
	free(items);
}

/* The features of the card are freed, whatever happened to them. */
static void
free_features(struct gdb_feature *features, long long nfeatures)
{
	free_items(features, nfeatures, sizeof(struct gdb_feature),
	    feature_fields);
}

/* The columns of the card: the event carries them under these keys. */
static const struct gdb_column device_columns[] = {
	{ 3, GDB_BIND_EMPTY, "label", NULL },
	{ 4, GDB_BIND_EMPTY, "selector", NULL },
	{ 5, GDB_BIND_EMPTY, "name", NULL },
	{ 6, GDB_BIND_EMPTY, "identity.vendor", NULL },
	{ 7, GDB_BIND_EMPTY, "identity.device", NULL },
	{ 8, GDB_BIND_EMPTY, "identity.subvendor", NULL },
	{ 9, GDB_BIND_EMPTY, "identity.subdevice", NULL },
	{ 10, GDB_BIND_EMPTY, "identity.class", NULL },
	{ 11, GDB_BIND_EMPTY, "identity.revision", NULL },
	{ 12, GDB_BIND_ALT, "provider", "decision.provider" },
	{ 13, GDB_BIND_NULL, "generation.name", NULL },
	{ 14, GDB_BIND_NULL, "generation.source", NULL },
	{ 15, GDB_BIND_NULL, "board.name", NULL },
	{ 16, GDB_BIND_NULL, "board.reason", NULL },
	{ 18, GDB_BIND_EMPTY, "decision.code", NULL },
	{ 19, GDB_BIND_NULL, "decision.reason_code", NULL },
	{ 20, GDB_BIND_NULL, "decision.provider", NULL },
	{ 21, GDB_BIND_NULL, "decision.family", NULL },
	{ 22, GDB_BIND_NULL, "decision.backend", NULL },
	{ 23, GDB_BIND_NULL, "decision.instance", NULL },
	{ 24, GDB_BIND_EMPTY, "decision.reason", NULL },
	{ 25, GDB_BIND_NULL, "decision.next", NULL },
	{ 26, GDB_BIND_EMPTY, "english", NULL },
	{ 0, GDB_BIND_EMPTY, NULL, NULL }
};

/* The card itself: the row of the card of the run. */
static int
insert_device(struct gdb *db, const struct gdb_data *data, long long ordinal)
{
	sqlite3_stmt *stmt;

	stmt = gdb_prepare(db,
	    "INSERT INTO devices (run_id, ordinal, label, selector, name,"
	    " vendor, device, subvendor, subdevice, class, revision, provider,"
	    " generation_name, generation_source, board_name, board_reason,"
	    " uuid_sha256, decision_code, decision_reason_code,"
	    " decision_provider, decision_family, decision_backend,"
	    " decision_instance, decision_reason, decision_next, english)"
	    " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,"
	    " ?, ?, ?, ?, ?, ?, ?, ?)");
	if (stmt == NULL)
		return (-1);
	sqlite3_bind_int64(stmt, 1, db->current_run);
	sqlite3_bind_int64(stmt, 2, ordinal);
	bind_columns(stmt, data, device_columns);
	/* The hash of the UUID of the card is known only when the checks
	 * are done: it comes in the event that ends the card. */
	sqlite3_bind_null(stmt, 17);
	return (insert_row_id(db, stmt, "card"));
}

/* The features of the card. */
static int
insert_device_features(struct gdb *db, long long id,
    const struct gdb_feature *features, long long nfeatures)
{
	return (insert_item_rows(db, GDB_INSERT_FEATURES, features, nfeatures,
	    sizeof(struct gdb_feature), id, &feature_layout,
	    "features of the card"));
}

/* The architectures of the family of the card. */
static int
insert_device_arch_values(struct gdb *db, long long id,
    const struct gdb_data *data)
{
	sqlite3_stmt *stmt;
	int i;

	for (i = 0; i < data->n; i++) {
		long long number = list_number(data->keys[i],
		    "generation.arch_values.", "");
		long long value = 0;

		if (number < 0)
			continue;
		if (data_int(data, data->keys[i], &value) != 0)
			continue;
		stmt = gdb_prepare(db,
		    "INSERT INTO device_arch_values (device_id, ordinal, value)"
		    " VALUES (?, ?, ?)");
		if (stmt == NULL)
			return (-1);
		sqlite3_bind_int64(stmt, 1, id);
		sqlite3_bind_int64(stmt, 2, number);
		sqlite3_bind_int64(stmt, 3, value);
		if (insert_done(db, stmt, "architectures of the card") != 0)
			return (-1);
	}
	return (0);
}

/* The tables that hold a list of text of a card, and what the failure of
 * one of them is called. */
enum text_list {
	TEXT_LIST_LOADED = 0,
	TEXT_LIST_WARNINGS
};

static const char *const text_list_insert_sql[] = {
	"INSERT INTO device_loaded (device_id, ordinal, module) VALUES (?, ?, ?)",
	"INSERT INTO device_warnings (device_id, ordinal, warning) VALUES (?, ?, ?)",
};

static const char *const text_list_what[] = {
	"modules of the card",
	"warnings of the card",
};

/* A list of text that the event carries: the modules of a card, the
 * warnings of a decision about it.  A list is a table, and the table
 * holds a row for every item of the list. */
static int
insert_text_list(struct gdb *db, long long id, const struct gdb_data *data,
    const char *prefix, int which)
{
	sqlite3_stmt *stmt;
	int i;

	for (i = 0; i < data->n; i++) {
		long long number = list_number(data->keys[i], prefix, "");

		if (number < 0 || data->types[i] != 2)
			continue;
		stmt = gdb_prepare(db, text_list_insert_sql[which]);
		if (stmt == NULL)
			return (-1);
		sqlite3_bind_int64(stmt, 1, id);
		sqlite3_bind_int64(stmt, 2, number);
		sqlite3_bind_text(stmt, 3, data->texts[i], -1, SQLITE_STATIC);
		if (insert_done(db, stmt, text_list_what[which]) != 0)
			return (-1);
	}
	return (0);
}

/* The warnings of the decision about the card. */
static int
insert_device_warnings(struct gdb *db, long long id,
    const struct gdb_data *data)
{
	return (insert_text_list(db, id, data, "decision.warnings.",
	    TEXT_LIST_WARNINGS));
}

/* The statements that link an event to the row it made.  They are
 * constants: a statement is never built at runtime. */
enum gdb_link {
	GDB_LINK_DEVICE,
	GDB_LINK_CHECK
};

static const char *const link_sql[] = {
	"UPDATE events SET device_id = ? WHERE id = ?",
	"UPDATE events SET check_row_id = ? WHERE id = ?"
};

/* The event is linked to the row it made: the row is the state the
 * event brought about, and the event says which row it is. */
static int
link_event(struct gdb *db, enum gdb_link which, long long value,
    long long event_id, const char *what)
{
	sqlite3_stmt *stmt;

	stmt = gdb_prepare(db, link_sql[which]);
	if (stmt == NULL)
		return (-1);
	sqlite3_bind_int64(stmt, 1, value);
	sqlite3_bind_int64(stmt, 2, event_id);
	if (sqlite3_step(stmt) != SQLITE_DONE) {
		gdb_set_error(db, "the event cannot be linked to the %s: %s", what,
		    sqlite3_errmsg(db->db));
		gdb_stmt_done(db, stmt);
		return (-1);
	}
	gdb_stmt_done(db, stmt);
	return (0);
}

/* The card of the run, as the event carries it. */
static int
apply_device(struct gdb *db, long long event_id, const struct gdb_data *data)
{
	struct gdb_feature *features;
	long long ordinal = 0;
	long long id, nfeatures = 0;

	data_int(data, "ordinal", &ordinal);
	features = collect_features(data, &nfeatures);
	id = insert_device(db, data, ordinal);
	if (id <= 0) {
		free_features(features, nfeatures);
		return (-1);
	}
	if (link_event(db, GDB_LINK_DEVICE, id, event_id, "card") != 0)
		goto fail;
	if (insert_device_features(db, id, features, nfeatures) != 0)
		goto fail;
	if (insert_device_arch_values(db, id, data) != 0)
		goto fail;
	if (insert_device_warnings(db, id, data) != 0)
		goto fail;
	free_features(features, nfeatures);
	return (0);
fail:
	free_features(features, nfeatures);
	return (-1);
}

/* What a card ended up with: the modules it loaded, and the hash of its
 * UUID.  These are known only when the checks of the card are done, so
 * they come in an event of their own. */
static int
apply_device_end(struct gdb *db, const struct gdb_data *data)
{
	sqlite3_stmt *stmt;
	long long ordinal = 0, number, device_id = 0;
	const char *uuid;

	if (data_int(data, "ordinal", &ordinal) != 0)
		return (-1);
	device_id = device_of_ordinal(db, db->current_run, ordinal);
	if (device_id == 0)
		return (-1);
	uuid = data_text(data, "uuid_sha256");
	if (uuid != NULL) {
		stmt = gdb_prepare(db,
		    "UPDATE devices SET uuid_sha256 = ? WHERE id = ?");
		if (stmt == NULL)
			return (-1);
		sqlite3_bind_text(stmt, 1, uuid, -1, SQLITE_STATIC);
		sqlite3_bind_int64(stmt, 2, device_id);
		if (sqlite3_step(stmt) != SQLITE_DONE) {
			gdb_set_error(db, "the hash of the card cannot be"
			    " written: %s", sqlite3_errmsg(db->db));
			gdb_stmt_done(db, stmt);
			return (-1);
		}
		gdb_stmt_done(db, stmt);
	}
	/* The modules the card loaded.  A list is a table. */
	if (insert_text_list(db, device_id, data, "loaded.",
	    TEXT_LIST_LOADED) != 0)
		return (-1);
	(void)number;
	return (0);
}

/* The definition of a check: what it is called and what it needs. */
static int
insert_check_def(struct gdb *db, const char *name, long long name_row,
    const struct gdb_data *data)
{
	sqlite3_stmt *stmt;
	long long ordinal = 0, number;

	data_int(data, "ordinal", &ordinal);
	if (ordinal <= 0)
		ordinal = 1;
	stmt = gdb_prepare(db,
	    "INSERT INTO check_defs (check_id, ordinal, title, needs_root,"
	    " needs_load, loads, is_decision) VALUES (?, ?, ?, ?, ?, ?, ?)"
	    " ON CONFLICT(check_id) DO UPDATE SET ordinal = excluded.ordinal,"
	    " title = excluded.title, needs_root = excluded.needs_root,"
	    " needs_load = excluded.needs_load, loads = excluded.loads,"
	    " is_decision = excluded.is_decision");
	if (stmt == NULL)
		return (-1);
	sqlite3_bind_int64(stmt, 1, name_row);
	sqlite3_bind_int64(stmt, 2, ordinal);
	sqlite3_bind_text(stmt, 3, data_text(data, "title") ?
	    data_text(data, "title") : name, -1, SQLITE_STATIC);
	sqlite3_bind_int(stmt, 4, (data_int(data, "needs_root", &number) == 0 &&
	    number) ? 1 : 0);
	sqlite3_bind_int(stmt, 5, (data_int(data, "needs_load", &number) == 0 &&
	    number) ? 1 : 0);
	sqlite3_bind_int(stmt, 6, (data_int(data, "loads", &number) == 0 &&
	    number) ? 1 : 0);
	sqlite3_bind_int(stmt, 7, (data_int(data, "is_decision", &number) == 0 &&
	    number) ? 1 : 0);
	if (sqlite3_step(stmt) != SQLITE_DONE) {
		gdb_set_error(db, "the definition of the check cannot be added: %s",
		    sqlite3_errmsg(db->db));
		gdb_stmt_done(db, stmt);
		return (-1);
	}
	gdb_stmt_done(db, stmt);
	return (0);
}

/* What a check needs before it runs: a list is a table. */
static int
insert_check_deps(struct gdb *db, long long def_id, const struct gdb_data *data)
{
	sqlite3_stmt *stmt;
	int i;

	for (i = 0; i < data->n; i++) {
		const char *key = data->keys[i];
		const char *dep;
		long long dep_id;

		if (strncmp(key, "depends_on.", 11) != 0)
			continue;
		dep = data->texts[i];
		if (dep == NULL || *dep == '\0')
			continue;
		dep_id = check_def_of_name(db, dep);
		if (dep_id == 0) {
			dep_id = ensure_check_def(db, dep, dep, 1);
			if (dep_id == 0)
				continue;
		}
		stmt = gdb_prepare(db,
		    "INSERT OR IGNORE INTO check_deps (def_id, depends_on_id)"
		    " VALUES (?, ?)");
		if (stmt == NULL)
			return (-1);
		sqlite3_bind_int64(stmt, 1, def_id);
		sqlite3_bind_int64(stmt, 2, dep_id);
		if (sqlite3_step(stmt) != SQLITE_DONE) {
			gdb_set_error(db, "the dependency cannot be added: %s",
			    sqlite3_errmsg(db->db));
			gdb_stmt_done(db, stmt);
			return (-1);
		}
		gdb_stmt_done(db, stmt);
	}
	return (0);
}

/* The catalogue of the checks. */
static int
apply_check_def(struct gdb *db, const struct gdb_data *data)
{
	const char *name = data_text(data, "check_id");
	long long name_row, def_id;

	if (name == NULL)
		return (0);
	name_row = check_name_id(db, name);
	if (name_row == 0)
		return (-1);
	if (insert_check_def(db, name, name_row, data) != 0)
		return (-1);
	def_id = check_def_of_name(db, name);
	if (def_id == 0)
		return (-1);
	return (insert_check_deps(db, def_id, data));
}

/* One step of a check, as the event carries it. */
struct gdb_step {
	long long	ordinal;
	char		*name;
	char		*status;
	char		*detail;
};

/* The fields of a step of a check.  The order of the fields is the
 * order of the columns of the row of the step. */
static const struct gdb_item_field step_fields[] = {
	{ "name", GDB_ITEM_TEXT, offsetof(struct gdb_step, name), NULL },
	{ "status", GDB_ITEM_TEXT, offsetof(struct gdb_step, status),
	  "not_reached" },
	{ "detail", GDB_ITEM_TEXT, offsetof(struct gdb_step, detail), NULL },
	{ NULL, GDB_ITEM_TEXT, 0, NULL }
};

/* How a step of a check is laid out. */
static const struct gdb_item_layout step_layout = {
	offsetof(struct gdb_step, ordinal),
	offsetof(struct gdb_step, name),
	step_fields
};

/* The steps of the check, as the event carries them. */
static struct gdb_step *
collect_steps(const struct gdb_data *data, long long *nsteps)
{
	return (collect_items(data, "steps.", sizeof(struct gdb_step),
	    &step_layout, nsteps));
}

/* The steps are freed, whatever happened to them. */
static void
free_steps(struct gdb_step *steps, long long nsteps)
{
	free_items(steps, nsteps, sizeof(struct gdb_step), step_fields);
}

/* The row of the check in the run. */
static long long
insert_run_check(struct gdb *db, const struct gdb_data *data, long long def_id,
    long long status_id, long long device_id)
{
	sqlite3_stmt *stmt;
	long long ordinal = 0, number, code_id = 0;
	const char *code;

	/* The place of the check in the registry is the place of its
	 * row, so a row means the same thing in every run. */
	stmt = gdb_prepare(db, "SELECT ordinal FROM check_defs WHERE id = ?");
	if (stmt == NULL)
		return (-1);
	sqlite3_bind_int64(stmt, 1, def_id);
	if (sqlite3_step(stmt) == SQLITE_ROW)
		ordinal = (long long)sqlite3_column_int64(stmt, 0);
	gdb_stmt_done(db, stmt);
	stmt = gdb_prepare(db,
	    "INSERT INTO run_checks (run_id, device_id, def_id, ordinal,"
	    " status_id, reason_code_id, reason, started_at, ended_at,"
	    " rm_index, uuid_sha256) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)");
	if (stmt == NULL)
		return (-1);
	sqlite3_bind_int64(stmt, 1, db->current_run);
	if (device_id > 0)
		sqlite3_bind_int64(stmt, 2, device_id);
	else
		sqlite3_bind_null(stmt, 2);
	sqlite3_bind_int64(stmt, 3, def_id);
	sqlite3_bind_int64(stmt, 4, ordinal);
	sqlite3_bind_int64(stmt, 5, status_id);
	code = data_text(data, "reason_code");
	if (code != NULL && *code != '\0')
		code_id = reason_code_id(db, code);
	if (code_id > 0)
		sqlite3_bind_int64(stmt, 6, code_id);
	else
		sqlite3_bind_null(stmt, 6);
	sqlite3_bind_text(stmt, 7, data_text(data, "reason") ?
	    data_text(data, "reason") : "", -1, SQLITE_STATIC);
	sqlite3_bind_text(stmt, 8, data_text(data, "started_at") ?
	    data_text(data, "started_at") : "", -1, SQLITE_STATIC);
	sqlite3_bind_text(stmt, 9, data_text(data, "ended_at") ?
	    data_text(data, "ended_at") : "", -1, SQLITE_STATIC);
	if (data_int(data, "rm_index", &number) == 0)
		sqlite3_bind_int64(stmt, 10, number);
	else
		sqlite3_bind_null(stmt, 10);
	bind_text_or_null(stmt, 11, data_text(data, "uuid_sha256"));
	return (insert_row_id(db, stmt, "row of the check"));
}

/* The steps of the check. */
static int
insert_check_steps(struct gdb *db, long long row, const struct gdb_step *steps,
    long long nsteps)
{
	return (insert_item_rows(db, GDB_INSERT_STEPS, steps, nsteps,
	    sizeof(struct gdb_step), row, &step_layout, "step of the check"));
}

/* What a check did. */
static int
apply_check(struct gdb *db, long long event_id, const struct gdb_data *data)
{
	const char *name = data_text(data, "name");
	const char *status = data_text(data, "status");
	long long def_id, status_id, device_id = 0, number, row;
	struct gdb_step *steps;
	long long nsteps = 0;

	if (name == NULL || status == NULL)
		return (-1);
	def_id = check_def_of_name(db, name);
	if (def_id == 0)
		def_id = ensure_check_def(db, name, name, 0);
	if (def_id == 0)
		return (-1);
	status_id = result_kind_id(db, status);
	if (status_id == 0)
		return (-1);
	if (data_int(data, "device_ordinal", &number) == 0 && number >= 0)
		device_id = device_of_ordinal(db, db->current_run, number);
	steps = collect_steps(data, &nsteps);
	row = insert_run_check(db, data, def_id, status_id, device_id);
	if (row <= 0) {
		free_steps(steps, nsteps);
		return (-1);
	}
	if (link_event(db, GDB_LINK_CHECK, row, event_id, "check") != 0)
		goto fail;
	if (insert_check_steps(db, row, steps, nsteps) != 0)
		goto fail;
	free_steps(steps, nsteps);
	return (0);
fail:
	free_steps(steps, nsteps);
	return (-1);
}

/* The catalogue of the metrics. */
static int
apply_metric_def(struct gdb *db, const struct gdb_data *data)
{
	sqlite3_stmt *stmt;
	const char *key = data_text(data, "key");
	long long unit = 0, source = 0;

	if (key == NULL)
		return (0);
	if (data_text(data, "unit") != NULL) {
		sqlite3_stmt *insert = gdb_prepare(db,
		    "INSERT OR IGNORE INTO units (name, description) VALUES (?, '')");
		sqlite3_stmt *select = gdb_prepare(db,
		    "SELECT id FROM units WHERE name = ?");

		unit = lookup_keep(db, insert, select, data_text(data, "unit"));
	}
	if (data_text(data, "source") != NULL)
		source = source_id(db, data_text(data, "source"));
	stmt = gdb_prepare(db,
	    "INSERT OR IGNORE INTO metric_defs (key, unit_id, kind, source_id,"
	    " description) VALUES (?, ?, ?, ?, ?)");
	if (stmt == NULL)
		return (-1);
	sqlite3_bind_text(stmt, 1, key, -1, SQLITE_STATIC);
	if (unit > 0)
		sqlite3_bind_int64(stmt, 2, unit);
	else
		sqlite3_bind_null(stmt, 2);
	sqlite3_bind_text(stmt, 3, data_text(data, "kind") ?
	    data_text(data, "kind") : "gauge", -1, SQLITE_STATIC);
	if (source > 0)
		sqlite3_bind_int64(stmt, 4, source);
	else
		sqlite3_bind_null(stmt, 4);
	sqlite3_bind_text(stmt, 5, data_text(data, "description") ?
	    data_text(data, "description") : "", -1, SQLITE_STATIC);
	if (sqlite3_step(stmt) != SQLITE_DONE) {
		gdb_set_error(db, "the metric cannot be defined: %s",
		    sqlite3_errmsg(db->db));
		gdb_stmt_done(db, stmt);
		return (-1);
	}
	gdb_stmt_done(db, stmt);
	return (0);
}

/* The value of a metric. */
static int
apply_metric(struct gdb *db, long long event_id, const struct gdb_data *data)
{
	sqlite3_stmt *stmt;
	const char *key = data_text(data, "key");
	long long metric_id, device_id = 0, number;
	const char *kind;

	if (key == NULL)
		return (0);
	metric_id = metric_def_of_key(db, key);
	if (metric_id == 0) {
		gdb_set_error(db, "the metric %s is not defined: a value without a"
		    " definition is refused", key);
		return (-1);
	}
	if (data_int(data, "device_ordinal", &number) == 0 && number >= 0)
		device_id = device_of_ordinal(db, db->current_run, number);
	kind = data_kind(data, "value");
	stmt = gdb_prepare(db,
	    "INSERT INTO measurements (run_id, metric_def_id, device_id,"
	    " check_row_id, observed_at, value_int, value_num, value_text,"
	    " blob_id) VALUES (?, ?, ?, NULL, ?, ?, ?, ?, NULL)");
	if (stmt == NULL)
		return (-1);
	sqlite3_bind_int64(stmt, 1, db->current_run);
	sqlite3_bind_int64(stmt, 2, metric_id);
	if (device_id > 0)
		sqlite3_bind_int64(stmt, 3, device_id);
	else
		sqlite3_bind_null(stmt, 3);
	sqlite3_bind_text(stmt, 4, data_text(data, "observed_at") ?
	    data_text(data, "observed_at") : "", -1, SQLITE_STATIC);
	if (kind != NULL && strcmp(kind, "int") == 0) {
		sqlite3_bind_int64(stmt, 5, data_int(data, "value", &number) == 0 ?
		    number : 0);
		sqlite3_bind_null(stmt, 6);
		sqlite3_bind_null(stmt, 7);
	} else if (kind != NULL && strcmp(kind, "number") == 0) {
		double nvalue = 0;

		sqlite3_bind_null(stmt, 5);
		sqlite3_bind_double(stmt, 6, data_num(data, "value", &nvalue) == 0 ?
		    nvalue : 0.0);
		sqlite3_bind_null(stmt, 7);
	} else {
		sqlite3_bind_null(stmt, 5);
		sqlite3_bind_null(stmt, 6);
		sqlite3_bind_text(stmt, 7, data_text(data, "value") ?
		    data_text(data, "value") : "", -1, SQLITE_STATIC);
	}
	if (sqlite3_step(stmt) != SQLITE_DONE) {
		gdb_set_error(db, "the measurement cannot be added: %s",
		    sqlite3_errmsg(db->db));
		gdb_stmt_done(db, stmt);
		return (-1);
	}
	gdb_stmt_done(db, stmt);
	stmt = gdb_prepare(db, "UPDATE events SET metric_id = ? WHERE id = ?");
	if (stmt == NULL)
		return (-1);
	sqlite3_bind_int64(stmt, 1, metric_id);
	sqlite3_bind_int64(stmt, 2, event_id);
	if (sqlite3_step(stmt) != SQLITE_DONE) {
		gdb_set_error(db, "the event cannot be linked to the metric: %s",
		    sqlite3_errmsg(db->db));
		gdb_stmt_done(db, stmt);
		return (-1);
	}
	gdb_stmt_done(db, stmt);
	return (0);
}

/* The kind a key was first seen with.  It is fixed: a key that is
* another kind later is a mismatch. */
static int
property_kind_of(struct gdb *db, long long property_id, char *known,
	size_t knownsz)
{
	sqlite3_stmt *stmt;

	stmt = gdb_prepare(db, "SELECT kind FROM properties WHERE id = ?");
	if (stmt == NULL)
		return (-1);
	sqlite3_bind_int64(stmt, 1, property_id);
	known[0] = '\0';
	if (sqlite3_step(stmt) == SQLITE_ROW)
		snprintf(known, knownsz, "%s",
			(const char *)sqlite3_column_text(stmt, 0));
	gdb_stmt_done(db, stmt);
	return (0);
}

/* A key that is another kind now: the value is kept as a blob, and the
* event says which kinds the key had. */
static int
apply_property_mismatch(struct gdb *db, long long event_id,
	const struct gdb_data *data, long long property_id, const char *known,
	const char *kind)
{
	sqlite3_stmt *stmt;
	const char *source = data_text(data, "source");
	const char *key = data_text(data, "key");
	const char *text = data_text(data, "value");
	long long blob, open_row = 0;
	double onvalue = 0;
	long long oivalue = 0;
	char *otext = NULL;
	struct gdb_event *mismatch;
	char observed[40];

	mismatch = gdb_event_begin(db, "type_mismatch", key);
	if (mismatch != NULL) {
		gdb_event_text(mismatch, "source", source);
		gdb_event_text(mismatch, "key", key);
		gdb_event_text(mismatch, "first_kind", known);
		gdb_event_text(mismatch, "second_kind", kind);
		gdb_event_commit(mismatch);
	}
	blob = store_blob(db, source, text ? text : "");
	if (blob == 0)
		return (-1);
	if (open_property_value(db, property_id, &open_row, &oivalue, &onvalue,
		&otext) != 0)
		return (-1);
	if (open_row != 0) {
		stmt = gdb_prepare(db,
			"UPDATE property_values SET closed_at = datetime('now')"
			" WHERE id = ?");
		if (stmt == NULL) {
			free(otext);
			return (-1);
		}
		sqlite3_bind_int64(stmt, 1, open_row);
		if (sqlite3_step(stmt) != SQLITE_DONE) {
			gdb_set_error(db, "the value cannot be closed: %s",
				sqlite3_errmsg(db->db));
			gdb_stmt_done(db, stmt);
			free(otext);
			return (-1);
		}
		gdb_stmt_done(db, stmt);
	}
	free(otext);
	stmt = gdb_prepare(db,
		"INSERT INTO property_values (property_id, run_id, event_id,"
		" value_int, value_num, value_text, blob_id, observed_at, closed_at)"
		" VALUES (?, ?, ?, NULL, NULL, NULL, ?, ?, NULL)");
	if (stmt == NULL)
		return (-1);
	now_utc(observed);
	sqlite3_bind_int64(stmt, 1, property_id);
	sqlite3_bind_int64(stmt, 2, db->current_run);
	sqlite3_bind_int64(stmt, 3, event_id);
	sqlite3_bind_int64(stmt, 4, blob);
	sqlite3_bind_text(stmt, 5, observed, -1, SQLITE_STATIC);
	if (sqlite3_step(stmt) != SQLITE_DONE) {
		gdb_set_error(db, "the value cannot be added: %s",
			sqlite3_errmsg(db->db));
		gdb_stmt_done(db, stmt);
		return (-1);
	}
	gdb_stmt_done(db, stmt);
	return (0);
}

/* The class of the property in this run starts as constant: it is
* worked out again when the value changes. */
static int
init_property_class(struct gdb *db, long long property_id)
{
	sqlite3_stmt *stmt;

	stmt = gdb_prepare(db, "INSERT OR IGNORE INTO property_classes"
		" (property_id, run_id, classification) VALUES (?, ?, 'constant')");
	if (stmt == NULL)
		return (-1);
	sqlite3_bind_int64(stmt, 1, property_id);
	sqlite3_bind_int64(stmt, 2, db->current_run);
	if (sqlite3_step(stmt) != SQLITE_DONE) {
		gdb_set_error(db, "the classification cannot be written: %s",
			sqlite3_errmsg(db->db));
		gdb_stmt_done(db, stmt);
		return (-1);
	}
	gdb_stmt_done(db, stmt);
	return (0);
}

/* Is the value of the event the value the property holds? */
static int
value_is_same(const struct gdb_data *data, int code, long long oivalue,
	double onvalue, const char *otext)
{
	long long number;
	double nvalue;
	const char *text;

	if (code == 0)
		return (data_int(data, "value", &number) == 0 && number == oivalue);
	if (code == 1)
		return (data_num(data, "value", &nvalue) == 0 && nvalue == onvalue);
	text = data_text(data, "value");
	return (text != NULL && otext != NULL && strcmp(text, otext) == 0);
}

/* The value the property holds now: a new row of the history. */
static int
insert_property_value(struct gdb *db, long long event_id, long long property_id,
	int code, const struct gdb_data *data)
{
	sqlite3_stmt *stmt;
	char observed[40];
	long long number;
	double nvalue;

	stmt = gdb_prepare(db,
		"INSERT INTO property_values (property_id, run_id, event_id,"
		" value_int, value_num, value_text, blob_id, observed_at, closed_at)"
		" VALUES (?, ?, ?, ?, ?, ?, NULL, ?, NULL)");
	if (stmt == NULL)
		return (-1);
	now_utc(observed);
	sqlite3_bind_int64(stmt, 1, property_id);
	sqlite3_bind_int64(stmt, 2, db->current_run);
	sqlite3_bind_int64(stmt, 3, event_id);
	if (code == 0) {
		sqlite3_bind_int64(stmt, 4, data_int(data, "value", &number) == 0 ?
			number : 0);
		sqlite3_bind_null(stmt, 5);
		sqlite3_bind_null(stmt, 6);
	} else if (code == 1) {
		sqlite3_bind_null(stmt, 4);
		sqlite3_bind_double(stmt, 5, data_num(data, "value", &nvalue) == 0 ?
			nvalue : 0.0);
		sqlite3_bind_null(stmt, 6);
	} else {
		sqlite3_bind_null(stmt, 4);
		sqlite3_bind_null(stmt, 5);
		sqlite3_bind_text(stmt, 6, data_text(data, "value") ?
			data_text(data, "value") : "", -1, SQLITE_STATIC);
	}
	sqlite3_bind_text(stmt, 7, observed, -1, SQLITE_STATIC);
	if (sqlite3_step(stmt) != SQLITE_DONE) {
		gdb_set_error(db, "the value cannot be added: %s",
			sqlite3_errmsg(db->db));
		gdb_stmt_done(db, stmt);
		return (-1);
	}
	gdb_stmt_done(db, stmt);
	return (0);
}

/* The value of a property. */
static int
apply_property(struct gdb *db, long long event_id, const struct gdb_data *data)
{
	sqlite3_stmt *stmt;
	const char *source = data_text(data, "source");
	const char *key = data_text(data, "key");
	const char *kind = data_text(data, "kind");
	const char *vkind = data_kind(data, "value");
	long long src, key_row, property_id, open_row = 0, oivalue = 0;
	double onvalue = 0;
	char *otext = NULL;
	char known[32];
	int code;

	if (source == NULL || key == NULL || vkind == NULL)
		return (-1);
	if (kind == NULL)
		kind = vkind;
	src = source_id(db, source);
	if (src == 0)
		return (-1);
	key_row = property_key_id(db, src, key);
	if (key_row == 0)
		return (-1);
	property_id = property_of_key(db, key_row);
	if (property_id == 0) {
		stmt = gdb_prepare(db,
			"INSERT OR IGNORE INTO properties (key_id, kind)"
			" VALUES (?, ?)");
		if (stmt == NULL)
			return (-1);
		sqlite3_bind_int64(stmt, 1, key_row);
		sqlite3_bind_text(stmt, 2, kind, -1, SQLITE_STATIC);
		if (sqlite3_step(stmt) != SQLITE_DONE) {
			gdb_set_error(db, "the property cannot be added: %s",
				sqlite3_errmsg(db->db));
			gdb_stmt_done(db, stmt);
			return (-1);
		}
		gdb_stmt_done(db, stmt);
		property_id = property_of_key(db, key_row);
		if (property_id == 0)
			return (-1);
	} else {
		if (property_kind_of(db, property_id, known, sizeof(known)) != 0)
			return (-1);
		if (known[0] != '\0' && strcmp(known, kind) != 0)
			return (apply_property_mismatch(db, event_id, data, property_id,
				known, kind));
	}
	if (init_property_class(db, property_id) != 0)
		return (-1);
	code = value_kind_code(vkind);
	if (open_property_value(db, property_id, &open_row, &oivalue, &onvalue,
		&otext) != 0)
		return (-1);
	if (open_row != 0) {
		if (value_is_same(data, code, oivalue, onvalue, otext)) {
			free(otext);
			return (0);
		}
		stmt = gdb_prepare(db,
			"UPDATE property_values SET closed_at = datetime('now')"
			" WHERE id = ?");
		if (stmt == NULL) {
			free(otext);
			return (-1);
		}
		sqlite3_bind_int64(stmt, 1, open_row);
		if (sqlite3_step(stmt) != SQLITE_DONE) {
			gdb_set_error(db, "the value cannot be closed: %s",
				sqlite3_errmsg(db->db));
			gdb_stmt_done(db, stmt);
			free(otext);
			return (-1);
		}
		gdb_stmt_done(db, stmt);
	}
	free(otext);
	return (insert_property_value(db, event_id, property_id, code, data));
}

/* A blob that a run kept. */
static int
apply_blob(struct gdb *db, long long event_id, const struct gdb_data *data)
{
	sqlite3_stmt *stmt;
	const char *source = data_text(data, "source");
	const char *sha = data_text(data, "sha256");
	long long src, number;
	char ts[40];

	if (source == NULL || sha == NULL)
		return (-1);
	src = source_id(db, source);
	if (src == 0)
		return (-1);
	now_utc(ts);
	stmt = gdb_prepare(db,
	    "INSERT OR IGNORE INTO blobs (source_id, sha256, size, compression,"
	    " event_id, created_at, content) VALUES (?, ?, ?, ?, ?, ?, ?)");
	if (stmt == NULL)
		return (-1);
	sqlite3_bind_int64(stmt, 1, src);
	sqlite3_bind_text(stmt, 2, sha, -1, SQLITE_STATIC);
	if (data_int(data, "size", &number) == 0)
		sqlite3_bind_int64(stmt, 3, number);
	else
		sqlite3_bind_int64(stmt, 3, 0);
	sqlite3_bind_text(stmt, 4, data_text(data, "compression") ?
	    data_text(data, "compression") : "none", -1, SQLITE_STATIC);
	sqlite3_bind_int64(stmt, 5, event_id);
	sqlite3_bind_text(stmt, 6, ts, -1, SQLITE_STATIC);
	sqlite3_bind_text(stmt, 7, data_text(data, "content") ?
	    data_text(data, "content") : "", -1, SQLITE_STATIC);
	if (sqlite3_step(stmt) != SQLITE_DONE) {
		gdb_set_error(db, "the blob cannot be added: %s",
		    sqlite3_errmsg(db->db));
		gdb_stmt_done(db, stmt);
		return (-1);
	}
	gdb_stmt_done(db, stmt);
	return (0);
}

/* The state of a snapshot. */
static int
apply_snapshot(struct gdb *db, const struct gdb_data *data)
{
	sqlite3_stmt *stmt;
	const char *phase = data_text(data, "phase");
	char ts[40];

	if (phase == NULL)
		return (-1);
	now_utc(ts);
	stmt = gdb_prepare(db,
	    "INSERT INTO snapshots (run_id, phase, ts) VALUES (?, ?, ?)");
	if (stmt == NULL)
		return (-1);
	sqlite3_bind_int64(stmt, 1, db->current_run);
	sqlite3_bind_text(stmt, 2, phase, -1, SQLITE_STATIC);
	sqlite3_bind_text(stmt, 3, ts, -1, SQLITE_STATIC);
	if (sqlite3_step(stmt) != SQLITE_DONE) {
		gdb_set_error(db, "the snapshot cannot be added: %s",
		    sqlite3_errmsg(db->db));
		gdb_stmt_done(db, stmt);
		return (-1);
	}
	gdb_stmt_done(db, stmt);
	return (0);
}

/* The state that follows from one event. */
static int
apply_event(struct gdb *db, long long event_id, const char *kind,
    const char *name, const struct gdb_data *data)
{
	(void)name;

	if (strcmp(kind, "run_start") == 0)
		return (apply_run_start(db, event_id, data));
	if (strcmp(kind, "run_end") == 0)
		return (apply_run_end(db, data));
	if (strcmp(kind, "device") == 0)
		return (apply_device(db, event_id, data));
	if (strcmp(kind, "device_end") == 0)
		return (apply_device_end(db, data));
	if (strcmp(kind, "check_def") == 0)
		return (apply_check_def(db, data));
	if (strcmp(kind, "check") == 0)
		return (apply_check(db, event_id, data));
	if (strcmp(kind, "metric_def") == 0)
		return (apply_metric_def(db, data));
	if (strcmp(kind, "metric") == 0)
		return (apply_metric(db, event_id, data));
	if (strcmp(kind, "property") == 0)
		return (apply_property(db, event_id, data));
	if (strcmp(kind, "blob") == 0)
		return (apply_blob(db, event_id, data));
	if (strcmp(kind, "snapshot") == 0)
		return (apply_snapshot(db, data));
	/* The other kinds carry no state of their own: they are the
	 * record of something that happened. */
	return (0);
}

/* --- committing an event ------------------------------------------------- */

int
gdb_batch_begin(struct gdb *db)
{
	if (db == NULL)
		return (-1);
	if (db->in_txn)
		return (0);
	if (gdb_exec(db, "BEGIN IMMEDIATE") != 0)
		return (-1);
	db->in_txn = 1;
	db->in_batch = 1;
	return (0);
}

int
gdb_batch_end(struct gdb *db)
{
	if (db == NULL)
		return (-1);
	if (!db->in_txn)
		return (0);
	if (gdb_exec(db, "COMMIT") != 0) {
		gdb_exec(db, "ROLLBACK");
		db->in_txn = 0;
		db->in_batch = 0;
		return (-1);
	}
	db->in_txn = 0;
	db->in_batch = 0;
	return (0);
}

int
gdb_event_commit(struct gdb_event *event)
{
	struct gdb *db;
	long long event_id;
	char ts[40];
	int i, own_txn = 0;

	if (event == NULL)
		return (-1);
	db = event->db;
	if (!db->in_txn) {
		if (gdb_exec(db, "BEGIN IMMEDIATE") != 0) {
			gdb_event_free(event);
			return (-1);
		}
		db->in_txn = 1;
		own_txn = 1;
	}
	now_utc(ts);
	event_id = insert_event_row(db, event->kind, event->name,
	    strcmp(event->kind, "run_start") == 0 ? 0 : db->current_run, ts);
	if (event_id == 0)
		goto fail;
	for (i = 0; i < event->ndata; i++) {
		if (insert_event_data(db, event_id, event->keys[i],
		    event->types[i], event->ints[i], event->nums[i],
		    event->texts[i]) != 0)
			goto fail;
	}
	{
		/* The data of the event is the data that was just written:
		 * it is taken from the event itself and not read back from
		 * the database, which is one query less for every event of
		 * a run.  The event is not freed until this is done, so the
		 * text of it is still there. */
		struct gdb_data written;

		written.n = event->ndata;
		written.keys = event->keys;
		written.types = event->types;
		written.ints = event->ints;
		written.nums = event->nums;
		written.texts = event->texts;
		if (apply_event(db, event_id, event->kind, event->name,
		    &written) != 0)
			goto fail;
	}
	if (own_txn) {
		if (gdb_exec(db, "COMMIT") != 0) {
			gdb_exec(db, "ROLLBACK");
			db->in_txn = 0;
			gdb_event_free(event);
			return (-1);
		}
		db->in_txn = 0;
	}
	gdb_event_free(event);
	return (0);
fail:
	if (own_txn) {
		gdb_exec(db, "ROLLBACK");
		db->in_txn = 0;
	} else {
		/* The batch is broken: nothing more goes into it. */
		gdb_exec(db, "ROLLBACK");
		db->in_txn = 0;
		db->in_batch = 0;
	}
	gdb_event_free(event);
	return (-1);
}

/* --- the snapshots of the properties -------------------------------------- */

static int
snapshot_list_add(long long **list, int *count, int *cap, long long value)
{
	if (*count == *cap) {
		long long *grown;
		int want = (*cap == 0) ? 64 : *cap * 2;

		grown = realloc(*list, (size_t)want * sizeof(long long));
		if (grown == NULL)
			return (-1);
		*list = grown;
		*cap = want;
	}
	(*list)[(*count)++] = value;
	return (0);
}

long long
gdb_snapshot_begin(struct gdb *db, const char *phase)
{
	sqlite3_stmt *stmt;
	struct gdb_event *event;
	long long id = 0;

	if (db == NULL)
		return (0);
	if (gdb_batch_begin(db) != 0)
		return (0);
	event = gdb_event_begin(db, "snapshot", phase ? phase : "run_start");
	if (event == NULL)
		return (0);
	gdb_event_text(event, "phase", phase ? phase : "run_start");
	if (gdb_event_commit(event) != 0)
		return (0);
	stmt = gdb_prepare(db,
	    "SELECT id FROM snapshots WHERE run_id = ? ORDER BY id DESC LIMIT 1");
	if (stmt == NULL)
		return (0);
	sqlite3_bind_int64(stmt, 1, db->current_run);
	if (sqlite3_step(stmt) == SQLITE_ROW)
		id = (long long)sqlite3_column_int64(stmt, 0);
	gdb_stmt_done(db, stmt);
	/* The properties of the snapshot before this one are what this
	 * one is compared with. */
	db->nsnap_seen = 0;
	db->nsnap_changed = 0;
	db->current_snapshot = id;
	return (id);
}

/* The value a property holds now: the row of the property, the row of
 * the value that is open, and what the value is. */
struct gdb_current {
	long long	property_id;
	long long	value_id;
	int		kind;		/* 0 int, 1 number, 2 text */
	int		have;		/* there is a value at all */
	long long	ivalue;
	double		nvalue;
	char		*text;
};

static void
current_free(struct gdb_current *current)
{
	free(current->text);
	current->text = NULL;
}

/* The value a property holds now, by its source and its key.  It is the
 * value of this run: an earlier run has a history of its own. */
/* The property of a key: the id of the row, and nothing else.  The key
 * is found through the source and the key itself, both of which have an
 * index of their own, so the lookup does not walk the tree of the
 * properties. */
static long long
property_of_source_key(struct gdb *db, const char *source, const char *key)
{
	sqlite3_stmt *stmt;
	long long id = 0;

	/* The tables are crossed in the order of the lookup: the source by
	 * its name, the key by its source and its key, the property by its
	 * source and its key.  Every step is an index lookup, so the cost
	 * of the lookup does not grow with the number of properties. */
	stmt = gdb_prepare(db,
	    "SELECT p.id FROM sources s"
	    " CROSS JOIN property_keys k ON k.source_id = s.id AND k.key = ?"
	    " CROSS JOIN properties p ON p.key_id = k.id"
	    " WHERE s.name = ?");
	if (stmt == NULL)
		return (0);
	sqlite3_bind_text(stmt, 1, key, -1, SQLITE_STATIC);
	sqlite3_bind_text(stmt, 2, source, -1, SQLITE_STATIC);
	if (sqlite3_step(stmt) == SQLITE_ROW)
		id = (long long)sqlite3_column_int64(stmt, 0);
	gdb_stmt_done(db, stmt);
	return (id);
}

static int
current_value(struct gdb *db, const char *source, const char *key,
    struct gdb_current *out)
{
	sqlite3_stmt *stmt;
	long long property_id;

	memset(out, 0, sizeof(*out));
	property_id = property_of_source_key(db, source, key);
	if (property_id <= 0)
		return (0);
	/* The value that is open now: the one that has not been closed.
	 * The index of the open values is (property_id, run_id), so the
	 * row is found and not looked for. */
	stmt = gdb_prepare(db,
	    "SELECT id, value_int, value_num, value_text FROM property_values"
	    " WHERE property_id = ? AND run_id = ? AND closed_at IS NULL"
	    " LIMIT 1");
	if (stmt == NULL)
		return (-1);
	sqlite3_bind_int64(stmt, 1, property_id);
	sqlite3_bind_int64(stmt, 2, db->current_run);
	if (sqlite3_step(stmt) == SQLITE_ROW) {
		out->property_id = property_id;
		out->value_id = (long long)sqlite3_column_int64(stmt, 0);
		out->have = 1;
		if (sqlite3_column_type(stmt, 1) != SQLITE_NULL) {
			out->kind = 0;
			out->ivalue = (long long)sqlite3_column_int64(stmt, 1);
		} else if (sqlite3_column_type(stmt, 2) != SQLITE_NULL) {
			out->kind = 1;
			out->nvalue = sqlite3_column_double(stmt, 2);
		} else {
			const char *text = (const char *)
			    sqlite3_column_text(stmt, 3);

			out->kind = 2;
			out->text = strdup(text ? text : "");
		}
	}
	gdb_stmt_done(db, stmt);
	return (0);
}

/* The link between a snapshot and the value a property had in it. */
static int
record_observation(struct gdb *db, long long snapshot_id, long long property_id,
    long long value_id)
{
	sqlite3_stmt *stmt;

	if (snapshot_id <= 0 || property_id <= 0 || value_id <= 0)
		return (0);
	stmt = gdb_prepare(db,
	    "INSERT OR REPLACE INTO observations (snapshot_id, property_id,"
	    " value_id) VALUES (?, ?, ?)");
	if (stmt == NULL)
		return (-1);
	sqlite3_bind_int64(stmt, 1, snapshot_id);
	sqlite3_bind_int64(stmt, 2, property_id);
	sqlite3_bind_int64(stmt, 3, value_id);
	if (sqlite3_step(stmt) != SQLITE_DONE) {
		gdb_set_error(db, "the observation cannot be added: %s",
		    sqlite3_errmsg(db->db));
		gdb_stmt_done(db, stmt);
		return (-1);
	}
	gdb_stmt_done(db, stmt);
	return (0);
}

/* Is the value the one the property already holds? */
static int
value_matches(const struct gdb_current *current, const char *kind,
    const struct gdb_value *value)
{
	/* A property that has no value yet has no value to match: the
	 * zeroes of an empty row are not the number zero. */
	if (!current->have)
		return (0);
	if (current->kind == 0 &&
	    (strcmp(kind, GDB_KIND_INT) == 0 ||
	    strcmp(kind, GDB_KIND_UINT) == 0))
		return (current->ivalue == value->ivalue);
	if (current->kind == 1 && strcmp(kind, GDB_KIND_NUMBER) == 0)
		return (current->nvalue == value->nvalue);
	if (current->kind == 2) {
		const char *text = value->text ? value->text : "";

		return (current->text != NULL &&
		    strcmp(current->text, text) == 0);
	}
	return (0);
}

/* What the snapshot saw: the property, and the value it holds. */
static void
snapshot_note_current(struct gdb *db, long long snapshot_id,
    const struct gdb_current *current, int changed)
{
	snapshot_list_add(&db->snap_seen, &db->nsnap_seen, &db->cap_snap_seen,
	    current->property_id);
	if (changed)
		snapshot_list_add(&db->snap_changed, &db->nsnap_changed,
		    &db->cap_snap_changed, current->property_id);
	record_observation(db, snapshot_id, current->property_id,
	    current->value_id);
}

/* What the snapshot saw after the event: the property holds the value of
 * the event now. */
static void
snapshot_note_after_event(struct gdb *db, long long snapshot_id,
    const char *source, const char *key)
{
	struct gdb_current current;

	if (current_value(db, source, key, &current) != 0 ||
	    current.property_id <= 0) {
		current_free(&current);
		return;
	}
	snapshot_note_current(db, snapshot_id, &current, 1);
	current_free(&current);
}

/* The event of a property that holds a value it did not hold before. */
static int
emit_property_event(struct gdb *db, long long snapshot_id, const char *source,
    const char *key, const char *kind, const struct gdb_value *value)
{
	struct gdb_event *event;

	event = gdb_event_begin(db, "property", key);
	if (event == NULL)
		return (-1);
	gdb_event_text(event, "source", source);
	gdb_event_text(event, "key", key);
	gdb_event_text(event, "kind", kind);
	gdb_event_int(event, "snapshot", snapshot_id);
	if (strcmp(kind, GDB_KIND_INT) == 0 || strcmp(kind, GDB_KIND_UINT) == 0)
		gdb_event_int(event, "value", value->ivalue);
	else if (strcmp(kind, GDB_KIND_NUMBER) == 0)
		gdb_event_num(event, "value", value->nvalue);
	else
		gdb_event_text(event, "value", value->text ? value->text : "");
	return (gdb_event_commit(event));
}

int
gdb_snapshot_property(struct gdb *db, long long snapshot_id, const char *source,
    const char *key, const struct gdb_value *value)
{
	struct gdb_current current;
	const char *kind;

	if (db == NULL || source == NULL || key == NULL || value == NULL)
		return (-1);
	kind = value->kind ? value->kind : GDB_KIND_STRING;
	if (current_value(db, source, key, &current) == 0 &&
	    current.property_id > 0 && current.have) {
		if (value_matches(&current, kind, value)) {
			/* Nothing happened: the value is what it was, so
			 * there is no event.  The snapshot saw it all the
			 * same. */
			snapshot_note_current(db, snapshot_id, &current, 0);
			current_free(&current);
			return (0);
		}
		current_free(&current);
	}
	if (emit_property_event(db, snapshot_id, source, key, kind, value) != 0)
		return (-1);
	/* The value the property holds now is the one of the event. */
	snapshot_note_after_event(db, snapshot_id, source, key);
	return (0);
}

/* The classification of a property in one run: constant, changing or
 * counter.  It is worked out from the values the property has had in
 * this run, and in no other: a key that is busy in one run may be quiet
 * in the next. */
static void
classify_property(struct gdb *db, long long property_id, long long run_id)
{
	sqlite3_stmt *stmt;
	int distinct = 0, rising = 1, kind_int = 1;
	long long previous = 0;
	double nprevious = 0.0;
	char last[1024];
	int first = 1;

	last[0] = '\0';
	stmt = gdb_prepare(db,
	    "SELECT value_int, value_num, value_text FROM property_values"
	    " WHERE property_id = ? AND run_id = ? ORDER BY id");
	if (stmt == NULL)
		return;
	sqlite3_bind_int64(stmt, 1, property_id);
	sqlite3_bind_int64(stmt, 2, run_id);
	while (sqlite3_step(stmt) == SQLITE_ROW) {
		if (sqlite3_column_type(stmt, 0) != SQLITE_NULL) {
			long long value = sqlite3_column_int64(stmt, 0);

			if (first) {
				previous = value;
				first = 0;
				distinct = 1;
				continue;
			}
			if (value != previous) {
				distinct = 2;
				if (value < previous)
					rising = 0;
				previous = value;
			}
		} else if (sqlite3_column_type(stmt, 1) != SQLITE_NULL) {
			double value = sqlite3_column_double(stmt, 1);

			kind_int = 0;
			if (first) {
				nprevious = value;
				first = 0;
				distinct = 1;
				continue;
			}
			if (value != nprevious) {
				distinct = 2;
				if (value < nprevious)
					rising = 0;
				nprevious = value;
			}
		} else {
			const char *text = (const char *)
			    sqlite3_column_text(stmt, 2);

			kind_int = 0;
			if (text == NULL)
				text = "";
			if (first) {
				first = 0;
				distinct = 1;
				snprintf(last, sizeof(last), "%s", text);
				continue;
			}
			if (strcmp(text, last) != 0)
				distinct = 2;
			snprintf(last, sizeof(last), "%s", text);
		}
	}
	gdb_stmt_done(db, stmt);
	stmt = gdb_prepare(db, "INSERT OR REPLACE INTO property_classes"
	    " (property_id, run_id, classification) VALUES (?, ?, ?)");
	if (stmt == NULL)
		return;
	sqlite3_bind_int64(stmt, 1, property_id);
	sqlite3_bind_int64(stmt, 2, run_id);
	sqlite3_bind_text(stmt, 3, (distinct == 1) ? "constant" :
	    ((kind_int && rising) ? "counter" : "changing"), -1, SQLITE_STATIC);
	if (sqlite3_step(stmt) != SQLITE_DONE)
		gdb_set_error(db, "the classification cannot be written: %s",
		    sqlite3_errmsg(db->db));
	gdb_stmt_done(db, stmt);
}

/* The ids of a snapshot, sorted, so that two of them can be walked in
 * step with one pass instead of one pass each. */
static int
compare_ids(const void *a, const void *b)
{
	long long left = *(const long long *)a;
	long long right = *(const long long *)b;

	if (left < right)
		return (-1);
	if (left > right)
		return (1);
	return (0);
}

/* The event of a property that came or went. */
static void
emit_property_seen(struct gdb *db, const char *kind, long long property_id)
{
	struct gdb_event *event;
	sqlite3_stmt *stmt;
	char source[64], key[256];

	stmt = gdb_prepare(db,
	    "SELECT s.name, k.key FROM properties p"
	    " JOIN property_keys k ON k.id = p.key_id"
	    " JOIN sources s ON s.id = k.source_id WHERE p.id = ?");
	if (stmt == NULL)
		return;
	sqlite3_bind_int64(stmt, 1, property_id);
	source[0] = '\0';
	key[0] = '\0';
	if (sqlite3_step(stmt) == SQLITE_ROW) {
		snprintf(source, sizeof(source), "%s",
		    (const char *)sqlite3_column_text(stmt, 0));
		snprintf(key, sizeof(key), "%s",
		    (const char *)sqlite3_column_text(stmt, 1));
	}
	gdb_stmt_done(db, stmt);
	if (key[0] == '\0')
		return;
	event = gdb_event_begin(db, kind, key);
	if (event == NULL)
		return;
	gdb_event_text(event, "source", source);
	gdb_event_text(event, "key", key);
	gdb_event_commit(event);
}

int
gdb_snapshot_end(struct gdb *db, long long snapshot_id)
{
	int i;

	(void)snapshot_id;
	if (db == NULL)
		return (-1);
	/* The properties that came and the ones that went are events.  The
	 * two lists are sorted and walked in step, so the cost of the
	 * comparison is the size of the lists and not their product.
	 *
	 * The first snapshot of a run has nothing to be compared with: the
	 * machine is read for the first time, and nothing has come or
	 * gone.  The whole tree would otherwise be an event of its own
	 * for every key of it. */
	if (db->snap_have_last) {
		if (db->nsnap_seen > 1)
			qsort(db->snap_seen, (size_t)db->nsnap_seen,
			    sizeof(long long), compare_ids);
		if (db->nsnap_last > 1)
			qsort(db->snap_last, (size_t)db->nsnap_last,
			    sizeof(long long), compare_ids);
		{
			int a = 0;
			int b = 0;

			while (a < db->nsnap_seen || b < db->nsnap_last) {
				if (a < db->nsnap_seen &&
				    (b >= db->nsnap_last ||
				    db->snap_seen[a] < db->snap_last[b])) {
					emit_property_seen(db, "property_appear",
					    db->snap_seen[a]);
					a++;
				} else if (b < db->nsnap_last &&
				    (a >= db->nsnap_seen ||
				    db->snap_last[b] < db->snap_seen[a])) {
					emit_property_seen(db, "property_disappear",
					    db->snap_last[b]);
					b++;
				} else {
					a++;
					b++;
				}
			}
		}
	}
	db->snap_have_last = 1;
	/* The properties of this snapshot are now the ones of the next
	 * comparison. */
	for (i = 0; i < db->nsnap_changed; i++)
		classify_property(db, db->snap_changed[i], db->current_run);
	db->nsnap_changed = 0;
	{
		long long *swap = db->snap_last;

		db->snap_last = db->snap_seen;
		db->snap_seen = swap;
		db->nsnap_last = db->nsnap_seen;
		db->cap_snap_last = db->cap_snap_seen;
		db->nsnap_seen = 0;
		db->cap_snap_seen = 0;
	}
	return (gdb_batch_end(db));
}

/* --- the migrations ------------------------------------------------------ */

/* The version a migration file declares. */
static int
migration_version(const char *path, char *out, size_t outlen)
{
	FILE *handle;
	char line[256];

	out[0] = '\0';
	handle = fopen(path, "r");
	if (handle == NULL)
		return (-1);
	while (fgets(line, sizeof(line), handle) != NULL) {
		if (strncmp(line, "-- gpu-check-db-version:", 24) == 0) {
			const char *p = line + 24;
			size_t len;

			while (*p == ' ' || *p == '\t')
				p++;
			len = strcspn(p, "\r\n");
			if (len >= outlen)
				len = outlen - 1;
			memcpy(out, p, len);
			out[len] = '\0';
			break;
		}
	}
	fclose(handle);
	return (out[0] == '\0' ? -1 : 0);
}

/* The whole of a file, as text. */
static char *
read_file(const char *path)
{
	FILE *handle;
	char *data;
	long size;

	handle = fopen(path, "rb");
	if (handle == NULL)
		return (NULL);
	if (fseek(handle, 0, SEEK_END) != 0) {
		fclose(handle);
		return (NULL);
	}
	size = ftell(handle);
	if (size < 0) {
		fclose(handle);
		return (NULL);
	}
	rewind(handle);
	data = malloc((size_t)size + 1);
	if (data == NULL) {
		fclose(handle);
		return (NULL);
	}
	if (size > 0 && fread(data, 1, (size_t)size, handle) != (size_t)size) {
		free(data);
		fclose(handle);
		return (NULL);
	}
	data[size] = '\0';
	fclose(handle);
	return (data);
}

/* The version of the schema that is in the file.  One when the file has
 * a version, zero when it has none: a file with no version is a file
 * that is not a database of this tool yet. */
static int
read_db_version(struct gdb *db, char *out, size_t outlen, int *major, int *minor,
    int *patch)
{
	sqlite3_stmt *stmt;
	int found = 0;

	out[0] = '\0';
	*major = *minor = *patch = 0;
	stmt = gdb_prepare(db,
	    "SELECT version, major, minor, patch FROM schema_version WHERE id = 1");
	if (stmt == NULL)
		return (0);
	if (sqlite3_step(stmt) == SQLITE_ROW) {
		const char *version = (const char *)sqlite3_column_text(stmt, 0);

		if (version != NULL)
			snprintf(out, outlen, "%s", version);
		*major = sqlite3_column_int(stmt, 1);
		*minor = sqlite3_column_int(stmt, 2);
		*patch = sqlite3_column_int(stmt, 3);
		found = 1;
	}
	gdb_stmt_done(db, stmt);
	return (found);
}

/* Is a migration already applied? */
static int
migration_applied(struct gdb *db, const char *name)
{
	sqlite3_stmt *stmt;
	int found = 0;

	stmt = gdb_prepare(db, "SELECT id FROM migrations WHERE name = ?");
	if (stmt == NULL)
		return (0);
	sqlite3_bind_text(stmt, 1, name, -1, SQLITE_STATIC);
	if (sqlite3_step(stmt) == SQLITE_ROW)
		found = 1;
	gdb_stmt_done(db, stmt);
	return (found);
}

/* Apply one migration.  The text that is run is the file of the
 * migration itself: the schema is the only thing that is ever run as
 * SQL, and it is a file of the tree, not a string that is built here. */
static int
apply_migration(struct gdb *db, const char *path, const char *name)
{
	char *migration_text;
	char ts[40];
	sqlite3_stmt *stmt;

	migration_text = read_file(path);
	if (migration_text == NULL) {
		gdb_set_error(db, "the migration %s cannot be read", name);
		return (-1);
	}
	if (gdb_exec(db, migration_text) != 0) {
		free(migration_text);
		return (-1);
	}
	free(migration_text);
	now_utc(ts);
	stmt = gdb_prepare(db,
	    "INSERT OR IGNORE INTO migrations (name, applied_at) VALUES (?, ?)");
	if (stmt == NULL)
		return (-1);
	sqlite3_bind_text(stmt, 1, name, -1, SQLITE_STATIC);
	sqlite3_bind_text(stmt, 2, ts, -1, SQLITE_STATIC);
	if (sqlite3_step(stmt) != SQLITE_DONE) {
		gdb_set_error(db, "the migration cannot be recorded: %s",
		    sqlite3_errmsg(db->db));
		gdb_stmt_done(db, stmt);
		return (-1);
	}
	gdb_stmt_done(db, stmt);
	return (0);
}

/* The version the migrations of a directory add up to: the version of the
 * last migration in it. */
static int
migration_target(const char *schema_dir, char *target, size_t target_len,
    int *tmajor, int *tminor, int *tpatch)
{
	char path[1024];
	int seq;

	target[0] = '\0';
	for (seq = 1; seq < 1000; seq++) {
		char version[64];

		snprintf(path, sizeof(path), "%s/gpu-check-db-%d.sql", schema_dir,
		    seq);
		if (migration_version(path, version, sizeof(version)) != 0)
			break;
		snprintf(target, target_len, "%s", version);
		parse_version(target, tmajor, tminor, tpatch);
	}
	return (target[0] != '\0' ? 0 : -1);
}

/* Is the database newer than the tool understands? */
static int
version_is_newer(int major, int minor, int patch, int tmajor, int tminor,
    int tpatch)
{
	if (major != tmajor)
		return (major > tmajor);
	if (minor != tminor)
		return (minor > tminor);
	return (patch > tpatch);
}

/* The migrations of the schema directory that have not been applied yet,
 * each in a transaction of its own. */
static int
apply_migrations(struct gdb *db, const char *schema_dir)
{
	char path[1024];
	int seq;

	for (seq = 1; seq < 1000; seq++) {
		char name[64];
		char version[64];

		snprintf(path, sizeof(path), "%s/gpu-check-db-%d.sql", schema_dir,
		    seq);
		snprintf(name, sizeof(name), "gpu-check-db-%d.sql", seq);
		if (migration_version(path, version, sizeof(version)) != 0)
			break;
		if (migration_applied(db, name))
			continue;
		if (gdb_exec(db, "BEGIN IMMEDIATE") != 0)
			return (-1);
		db->in_txn = 1;
		if (apply_migration(db, path, name) != 0) {
			gdb_exec(db, "ROLLBACK");
			db->in_txn = 0;
			return (-1);
		}
		if (gdb_exec(db, "COMMIT") != 0) {
			gdb_exec(db, "ROLLBACK");
			db->in_txn = 0;
			return (-1);
		}
		db->in_txn = 0;
	}
	return (0);
}

/* The version of the file is the version of the last migration. */
static int
write_schema_version(struct gdb *db, const char *target, int tmajor, int tminor,
    int tpatch)
{
	sqlite3_stmt *stmt;

	stmt = gdb_prepare(db,
	    "INSERT INTO schema_version (id, version, major, minor, patch)"
	    " VALUES (1, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET"
	    " version = excluded.version, major = excluded.major,"
	    " minor = excluded.minor, patch = excluded.patch");
	if (stmt == NULL)
		return (-1);
	sqlite3_bind_text(stmt, 1, target, -1, SQLITE_STATIC);
	sqlite3_bind_int(stmt, 2, tmajor);
	sqlite3_bind_int(stmt, 3, tminor);
	sqlite3_bind_int(stmt, 4, tpatch);
	if (sqlite3_step(stmt) != SQLITE_DONE) {
		gdb_set_error(db, "the version cannot be written: %s",
		    sqlite3_errmsg(db->db));
		gdb_stmt_done(db, stmt);
		return (-1);
	}
	gdb_stmt_done(db, stmt);
	return (0);
}

/* The migrations of the schema directory, in order.  The file of the
 * number n is gpu-check-db-n.sql. */
static int
migrate(struct gdb *db, const char *schema_dir)
{
	char dbversion[64], target[64];
	int major = 0, minor = 0, patch = 0;
	int tmajor = 0, tminor = 0, tpatch = 0;
	int have_db;

	if (schema_dir == NULL) {
		gdb_set_error(db, "there is no directory of migrations");
		return (-1);
	}
	/* The version the migrations of this directory add up to. */
	if (migration_target(schema_dir, target, sizeof(target), &tmajor, &tminor,
	    &tpatch) != 0) {
		gdb_set_error(db, "there is no migration in %s", schema_dir);
		return (-1);
	}
	have_db = read_db_version(db, dbversion, sizeof(dbversion), &major, &minor,
	    &patch);
	if (have_db && dbversion[0] == '\0')
		snprintf(dbversion, sizeof(dbversion), "%d.%d.%d", major, minor,
		    patch);
	if (have_db && version_is_newer(major, minor, patch, tmajor, tminor,
	    tpatch)) {
		gdb_set_error(db, "the database is version %s and this"
		    " tool understands version %s: the database is newer"
		    " than the tool", dbversion, target);
		return (-1);
	}
	if (apply_migrations(db, schema_dir) != 0)
		return (-1);
	return (write_schema_version(db, target, tmajor, tminor, tpatch));
}

/* --- the replay ---------------------------------------------------------- */

/* Throw the derived tables away and build them again from the events.
 * This is what proves that the events are the source of truth. */
int
gdb_replay(struct gdb *db)
{
	static const char *const clears[] = {
		/* The links the events hold to the rows that are derived
		 * from them are let go first: the rows are about to go,
		 * and every event links itself again when it is applied.
		 *
		 * The order of the deletes is the order of the foreign
		 * keys: a row that is still pointed at is not taken away
		 * before the rows that point at it are gone. */
		"UPDATE events SET run_id = NULL, device_id = NULL",
		"UPDATE events SET check_row_id = NULL, metric_id = NULL",
		"DELETE FROM observations",
		"DELETE FROM measurements",
		"DELETE FROM property_values",
		"DELETE FROM property_classes",
		"DELETE FROM check_steps",
		"DELETE FROM snapshots",
		"DELETE FROM run_checks",
		"DELETE FROM device_features",
		"DELETE FROM device_warnings",
		"DELETE FROM device_arch_values",
		"DELETE FROM device_loaded",
		"DELETE FROM devices",
		"DELETE FROM properties",
		"DELETE FROM property_keys",
		"DELETE FROM blobs",
		"DELETE FROM check_deps",
		"DELETE FROM check_defs",
		"DELETE FROM metric_defs",
		"DELETE FROM runs"
	};
	sqlite3_stmt *stmt;
	long long last = 0;
	size_t i;

	if (db == NULL)
		return (-1);
	if (gdb_exec(db, "BEGIN IMMEDIATE") != 0)
		return (-1);
	db->in_txn = 1;
	for (i = 0; i < sizeof(clears) / sizeof(clears[0]); i++) {
		if (gdb_exec(db, clears[i]) != 0)
			goto fail;
	}
	for (;;) {
		struct gdb_data loaded;
		char *kind;
		char name[160];

		stmt = gdb_prepare(db,
		    "SELECT e.id, k.name, e.name FROM events e"
		    " JOIN event_kinds k ON k.id = e.kind_id"
		    " WHERE e.id > ? ORDER BY e.id LIMIT 1");
		if (stmt == NULL)
			goto fail;
		sqlite3_bind_int64(stmt, 1, last);
		if (sqlite3_step(stmt) != SQLITE_ROW) {
			gdb_stmt_done(db, stmt);
			break;
		}
		last = (long long)sqlite3_column_int64(stmt, 0);
		kind = strdup(text_of(stmt, 1));
		snprintf(name, sizeof(name), "%s", text_of(stmt, 2));
		gdb_stmt_done(db, stmt);
		if (kind == NULL)
			goto fail;
		if (gdb_data_load(db, last, &loaded) != 0) {
			free(kind);
			goto fail;
		}
		/* The link of the event to its run, the way the commit
		 * leaves it: the event that starts the run links itself,
		 * every other event belongs to the run that is running. */
		if (strcmp(kind, "run_start") != 0 && db->current_run > 0 &&
		    link_event_run(db, last, db->current_run) != 0) {
			gdb_data_free(&loaded);
			free(kind);
			goto fail;
		}
		if (apply_event(db, last, kind, name, &loaded) != 0) {
			gdb_data_free(&loaded);
			free(kind);
			goto fail;
		}
		gdb_data_free(&loaded);
		free(kind);
	}
	if (gdb_exec(db, "COMMIT") != 0)
		goto fail;
	db->in_txn = 0;
	return (0);
fail:
	gdb_exec(db, "ROLLBACK");
	db->in_txn = 0;
	return (-1);
}

/* --- the platform provider ------------------------------------------------ */

/* The answer of a provider, on its way to the database. */
struct gdb_capture {
	struct gdb	*db;
	long long	 snapshot_id;
	int		 failed;
	char		*errmsg;
	size_t		 errlen;
};

/* One property of the machine, on its way to the database. */
static int
capture_emit(void *ctx, const char *source, const char *key,
    const struct gdb_value *value)
{
	struct gdb_capture *capture = ctx;

	if (capture->failed)
		return (-1);
	if (gdb_snapshot_property(capture->db, capture->snapshot_id, source,
	    key, value) != 0) {
		capture->failed = 1;
		/* The reason the property could not be kept is kept
		 * too: a failure that says nothing is a failure that
		 * cannot be found. */
		if (capture->errmsg != NULL && capture->errlen > 0) {
			const char *message = gdb_error(capture->db);

			snprintf(capture->errmsg, capture->errlen, "%s",
			    message != NULL ? message : "the property was refused");
		}
		return (-1);
	}
	return (0);
}

/* Ask the platform provider what the machine holds. */
int
gdb_capture(struct gdb *db, const char *platform, long long snapshot_id)
{
	const struct gdb_platform_ops *ops;
	struct gdb_capture capture;
	void *handle;
	char err[GDB_ERR_MAX];
	char reason[GDB_ERR_MAX];
	int rc;

	if (db == NULL)
		return (-1);
	err[0] = '\0';
	reason[0] = '\0';
	if (platform == NULL || platform[0] == '\0')
		platform = gdb_platform_default();
	ops = gdb_platform_find(platform);
	if (ops == NULL) {
		gdb_set_error(db, "there is no platform provider named %s",
		    platform ? platform : "the default one");
		return (-1);
	}
	handle = ops->open ? ops->open(err, sizeof(err)) : NULL;
	if (handle == NULL && err[0] != '\0') {
		gdb_set_error(db, "the platform %s cannot be opened: %s",
		    platform, err);
		return (-1);
	}
	capture.db = db;
	capture.snapshot_id = snapshot_id;
	capture.failed = 0;
	capture.errmsg = reason;
	capture.errlen = sizeof(reason);
	rc = ops->snapshot(handle, capture_emit, &capture, err, sizeof(err));
	if (ops->close != NULL)
		ops->close(handle);
	if (rc != 0) {
		/* The reason the provider gives comes first; the reason
		 * the database gives is what is under it. */
		if (err[0] == '\0' && reason[0] != '\0')
			snprintf(err, sizeof(err), "%s", reason);
		gdb_set_error(db, "the platform %s cannot be read: %s", platform,
		    err[0] != '\0' ? err : "the provider failed");
		return (-1);
	}
	return (0);
}

/* --- opening and closing ------------------------------------------------- */

struct gdb *
gdb_open(const char *path, const char *schema_dir, char *errbuf, size_t errlen)
{
	struct gdb *db;
	char err[GDB_ERR_MAX];

	db = calloc(1, sizeof(*db));
	if (db == NULL) {
		if (errbuf != NULL && errlen > 0)
			snprintf(errbuf, errlen, "there is no memory for the database");
		return (NULL);
	}
	db->schema_dir = schema_dir ? strdup(schema_dir) : NULL;
	if (sqlite3_open_v2(path, &db->db,
	    SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, NULL) != SQLITE_OK) {
		snprintf(err, sizeof(err), "the database %s cannot be opened: %s",
		    path, sqlite3_errmsg(db->db));
		goto fail;
	}
	sqlite3_busy_timeout(db->db, 5000);
	if (gdb_exec(db, "PRAGMA foreign_keys = ON") != 0)
		goto fail;
	if (gdb_exec(db, "PRAGMA journal_mode = WAL") != 0)
		goto fail;
	if (gdb_exec(db, "PRAGMA synchronous = NORMAL") != 0)
		goto fail;
	if (migrate(db, schema_dir) != 0)
		goto fail;
	db->is_new = 0;
	if (errbuf != NULL && errlen > 0)
		errbuf[0] = '\0';
	return (db);
fail:
	snprintf(err, sizeof(err), "%s", gdb_error(db));
	if (errbuf != NULL && errlen > 0)
		snprintf(errbuf, errlen, "%s", err);
	sqlite3_close(db->db);
	free(db->schema_dir);
	free(db);
	return (NULL);
}

void
gdb_close(struct gdb *db)
{
	int i;

	if (db == NULL)
		return;
	for (i = 0; i < db->nstmts; i++)
		sqlite3_finalize(db->stmts[i].stmt);
	sqlite3_close(db->db);
	free(db->schema_dir);
	free(db->snap_seen);
	free(db->snap_last);
	free(db);
}

void
gdb_string_free(char *text)
{
	free(text);
}
