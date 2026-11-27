/* gdb.h - the database of the gpu-check tool.
 *
 * Copyright (c) 2026 REVYTECH, Inc.
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The record of a run of gpu-check is a database.  This is the core of
 * that database: it opens the file, applies the migrations, appends the
 * events, writes the state that is derived from them, and answers the
 * questions a person asks afterwards (history, show, compare, export,
 * properties).
 *
 * Two rules hold everywhere in this library:
 *
 *   1. Nothing of an operating system is here.  The core names no
 *      platform, calls no syscall of one, and includes no header of one.
 *      What a machine can be asked is the work of a platform provider
 *      (gdb_platform.h), and a provider registers itself.
 *
 *   2. No SQL is ever built from a string.  Every statement is a
 *      constant, and every value that comes from outside is bound.
 */
#ifndef GDB_H
#define GDB_H

#include <stddef.h>

/* The kinds of value a property or a metric can hold. */
#define GDB_KIND_INT	"int"
#define GDB_KIND_UINT	"uint"
#define GDB_KIND_NUMBER	"number"
#define GDB_KIND_STRING	"string"
#define GDB_KIND_BLOB	"blob"

/* One value: its kind and what it holds.  A value is one of the four,
 * never a list and never a document. */
struct gdb_value {
	const char	*kind;
	long long	ivalue;
	double		nvalue;
	const char	*text;
};

struct gdb;
struct gdb_event;

/* The version of this library.  The parts are numbers, so nothing has to
 * parse a version to compare it. */
const char	*gdb_version(void);
int		 gdb_version_major(void);
int		 gdb_version_minor(void);
int		 gdb_version_patch(void);

/* Open the database, or fail.  The path is the file itself.  The schema
 * directory holds the numbered migrations; they are applied when the
 * file is new, and when the file is older than the migrations.  A file
 * that is newer than this library understands is refused, and the error
 * says which version the file is and which version this is. */
struct gdb	*gdb_open(const char *path, const char *schema_dir,
			     char *errbuf, size_t errlen);
void		 gdb_close(struct gdb *db);
const char	*gdb_error(const struct gdb *db);

/* Begin an event.  The event is the source of truth: the state that is
 * derived from it is written in the same transaction. */
struct gdb_event *gdb_event_begin(struct gdb *db, const char *kind,
				   const char *name);
void		 gdb_event_free(struct gdb_event *event);
int		 gdb_event_int(struct gdb_event *event, const char *key,
			      long long value);
int		 gdb_event_num(struct gdb_event *event, const char *key,
			      double value);
int		 gdb_event_text(struct gdb_event *event, const char *key,
			       const char *value);
int		 gdb_event_commit(struct gdb_event *event);
int		 gdb_event_abort(struct gdb_event *event);

/* A batch of events in one transaction.  A snapshot of the properties is
 * one batch: it is either all there or none of it. */
int		 gdb_batch_begin(struct gdb *db);
int		 gdb_batch_end(struct gdb *db);

/* A snapshot of the properties: the state of the machine at one point of
 * the run.  There is one at the start of the run, before the checks have
 * run, and one at the end, after they have run. */
long long	 gdb_snapshot_begin(struct gdb *db, const char *phase);
int		 gdb_snapshot_property(struct gdb *db, long long snapshot_id,
				     const char *source, const char *key,
				     const struct gdb_value *value);
int		 gdb_snapshot_end(struct gdb *db, long long snapshot_id);

/* The questions.  Each answer is a JSON document that the caller owns
 * and frees with gdb_string_free.  A NULL answer is an error, and
 * gdb_error says why. */
char		*gdb_query_history(struct gdb *db, int last);
char		*gdb_query_show(struct gdb *db, long long run_id);
char		*gdb_query_compare(struct gdb *db, long long first,
			       long long second);
char		*gdb_query_export(struct gdb *db, long long run_id);
char		*gdb_query_properties(struct gdb *db, long long run_id,
				  int changed, int counters);

/* Ask the platform provider what the machine holds, and record every
 * answer as a property of the snapshot being taken.  The provider with
 * that name does the asking; the core names no platform of its own.
 * The name may be NULL, and then the provider that was built in is
 * used. */
int		 gdb_capture(struct gdb *db, const char *platform,
		      long long snapshot_id);

/* Throw the derived tables away and build them again from the events.
 * This is what proves that the events are the source of truth. */
int		 gdb_replay(struct gdb *db);

void		 gdb_string_free(char *text);

#endif /* GDB_H */
